import Foundation
import GeneratedAPI
import HTTPTypes
import JSONSchema
import JSONSchemaBuilder
import OpenAPIJSONRuntime
import OpenAPIRuntime

struct CheckFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
  guard condition else { throw CheckFailure(message: message) }
}

enum MockFailure: Error { case transport }

actor MockTransport: ClientTransport {
  struct Capture: Sendable {
    let path: String?
    let url: URL
    let method: HTTPRequest.Method
    let headers: HTTPFields
    let body: [UInt8]?
  }
  var captures: [Capture] = []
  var status = 200
  var contentType = "application/json"
  var response = "{}"
  var fails = false
  var cancels = false

  func set(status: Int = 200, contentType: String = "application/json", body: String) {
    self.status = status
    self.contentType = contentType
    response = body
  }

  func setFailure(_ value: Bool, cancellation: Bool = false) {
    fails = value
    cancels = cancellation
  }

  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
    -> (HTTPResponse, HTTPBody?)
  {
    var bytes: [UInt8]?
    if let body { bytes = try await [UInt8](collecting: body, upTo: 1024 * 1024) }
    let base =
      baseURL.absoluteString.hasSuffix("/")
      ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
    guard let url = URL(string: base + (request.path ?? "")) else {
      throw CheckFailure(message: "Invalid URL")
    }
    captures.append(
      .init(
        path: request.path, url: url, method: request.method, headers: request.headerFields,
        body: bytes))
    if cancels { throw CancellationError() }
    if fails { throw MockFailure.transport }
    return (
      HTTPResponse(status: .init(code: status), headerFields: [.contentType: contentType]),
      response.isEmpty ? nil : HTTPBody(response)
    )
  }
}

struct TestCredentials: JSONCredentialProvider {
  func credentials(for alternative: JSONSecurityAlternative) async throws -> [String: String]? {
    Dictionary(uniqueKeysWithValues: alternative.schemes.map { ($0.name, "fixture-token") })
  }
}

func authoredConsumer() async throws {
  let transport = MockTransport()
  let client = try Authored.Client(
    serverURL: URL(string: "https://example.test/v1")!, transport: transport,
    credentials: TestCredentials())
  let number = try JSONValue.parse("123456789012345678901234567890.123456789")
  func submission(
    name: String = "Widget", extras: [String: String?] = ["extra": "value", "null-extra": nil]
  ) -> Authored.Models.Submission {
    .init(
      display_name: name, state: .init(rawValue: "cafe\u{301}")!, reason: nil, comment: .some(nil),
      mode: .text(.init(kind: "text", text: "hello")), payload: number, additionalProperties: extras
    )
  }
  let input = Authored.Operations.createWidget.Input(
    id: "a/b", limit: 3, tags: ["x,y", "z z"], codes: [1, 2], body: submission())
  let json = try Authored.Models.createWidgetBodyJSON(input.body)
  try check(json.object?["display-name"] == .string("Widget"), "Original field key")
  try check(
    json.object?["reason"] == .null && json.object?["comment"] == .null,
    "Required and optional explicit null")
  try check(
    json.object?["extra"] == .string("value") && json.object?["null-extra"] == .null,
    "Flattened extras")
  try check(
    json.object?["payload"]?.numberLiteral?.rawValue == number.numberLiteral?.rawValue,
    "Exact number")
  try check(
    Array((json.object?["state"]?.string ?? "").utf8) == Array("cafe\u{301}".utf8),
    "Exact enum scalar identity")
  let composed = Authored.Models.State(rawValue: "caf\u{e9}")!
  let decomposed = Authored.Models.State(rawValue: "cafe\u{301}")!
  try check(composed != decomposed, "Unicode-distinct enum cases")
  await transport.set(body: try json.serialized())
  let response = try await client.createWidget(input)
  func shared(_ model: Authored.Models.Submission) -> String { model.display_name }
  guard case .status200(let body, _) = response else {
    throw CheckFailure(message: "Exact before range")
  }
  try check(shared(body) == shared(input.body), "Request/response nominal sharing")
  let capture = await transport.captures.last!
  try check(capture.method == .post, "POST method")
  try check(
    capture.url.absoluteString
      == "https://example.test/v1/widgets/a%2Fb?limit=3&tags=x%2Cy&tags=z%20z&codes=1%7C2",
    "Full URL preserves server base path")
  try check(
    capture.headers[HTTPField.Name("authorization")!] == "Bearer fixture-token",
    "Case-insensitive injected auth")
  try check(capture.headers[.contentType] == "application/json", "Content-Type")
  try check(
    capture.headers[.accept] == "application/json, application/problem+json",
    "Declared Accept variants")
  try check(capture.body == Array((try json.serialized()).utf8), "Serialized JSON request")

  let before = await transport.captures.count
  for invalid in [
    Authored.Operations.createWidget.Input(id: "x", body: submission(name: "")),
    Authored.Operations.createWidget.Input(
      id: "x", body: submission(extras: ["display-name": "collision"])),
    Authored.Operations.createWidget.Input(id: "x", limit: 6, body: submission()),
  ] {
    do {
      _ = try await client.createWidget(invalid)
      throw CheckFailure(message: "Invalid request reached transport")
    } catch is CheckFailure {
      throw CheckFailure(message: "Expected schema/encoding failure")
    } catch {}
  }
  let unauthenticated = try Authored.Client(
    serverURL: URL(string: "https://example.test/v1")!, transport: transport)
  do {
    _ = try await unauthenticated.createWidget(input)
    throw CheckFailure(message: "Missing credentials accepted")
  } catch JSONClientError.missingCredentials {}
  try check(await transport.captures.count == before, "Failures happen before send")

  await transport.set(status: 201, body: try json.serialized())
  guard case .status2XX(let code, let ranged, _) = try await client.createWidget(input) else {
    throw CheckFailure(message: "Range response")
  }
  try check(code == 201 && shared(ranged) == "Widget", "Range status and body")
  await transport.set(
    status: 400, contentType: "application/problem+json; charset=utf-8",
    body: #"{"message":"bad","code":42}"#)
  guard case .defaultResponse(let status, let failure, _) = try await client.createWidget(input)
  else {
    throw CheckFailure(message: "Default error response")
  }
  try check(status == 400 && failure.code == 42, "Typed error decode")
  await transport.set(status: 204, body: "")
  guard case .status204 = try await client.createWidget(input) else {
    throw CheckFailure(message: "204 before range")
  }

  _ = try await client.optionalBody(.init())
  try check(await transport.captures.last?.body == nil, "Absent optional body")
  _ = try await client.optionalBody(.init(body: .some(nil)))
  try check(
    await transport.captures.last?.body == Array("null".utf8), "Explicit null optional body")
  await transport.set(contentType: "text/html", body: "{}")
  do {
    _ = try await client.createWidget(input)
    throw CheckFailure(message: "Wrong media accepted")
  } catch JSONClientError.unexpectedContentType {}
  await transport.set(body: #"{"display-name":1}"#)
  do {
    _ = try await client.createWidget(input)
    throw CheckFailure(message: "Invalid response accepted")
  } catch is CheckFailure { throw CheckFailure(message: "Expected schema failure") } catch {}
  await transport.setFailure(true)
  do {
    _ = try await client.createWidget(input)
    throw CheckFailure(message: "Transport error swallowed")
  } catch MockFailure.transport {}
  await transport.setFailure(false, cancellation: true)
  do {
    _ = try await client.createWidget(input)
    throw CheckFailure(message: "Cancellation swallowed")
  } catch is CancellationError {}
  print(
    "Authored POST: encoding, validation, nominal sharing, auth, URL, media, exact/range/default and propagation passed."
  )
}

func openAIConsumer() async throws {
  let transport = MockTransport()
  let client = try OpenAI.Client(
    serverURL: URL(string: "https://example.test/v1")!, transport: transport,
    credentials: TestCredentials())
  let model =
    #"{"id":"model-test","created":123,"object":"model","owned_by":"fixture","shutdown_date":null}"#
  await transport.set(body: #"{"object":"list","data":["# + model + "]}")
  guard case .status200(let list, _) = try await client.listModels() else {
    throw CheckFailure(message: "List success")
  }
  func sameModel(_ value: OpenAI.Models.retrieveModelResponse200) throws -> JSONValue {
    try OpenAI.Models.retrieveModelResponse200JSON(value)
  }
  let fromList = try sameModel(list.data[0])
  func typed(_ model: OpenAI.Models.Model) throws -> OpenAI.Models.ModelObject {
    guard case .object(let fields) = model else {
      throw CheckFailure(message: "Valid Model object did not yield typed payload")
    }
    return fields
  }
  let listFields = try typed(list.data[0])
  try check(listFields.id == "model-test" && listFields.created == 123, "Typed Models fields")
  try check(
    listFields.owned_by == "fixture" && listFields.object.rawValue == "model", "Typed Models enum")
  await transport.set(body: model)
  guard case .status200(let retrieved, _) = try await client.retrieveModel(.init(model: "model/a"))
  else {
    throw CheckFailure(message: "Retrieve success")
  }
  try check(try sameModel(retrieved) == fromList, "Models response item sharing")
  let retrievedFields: OpenAI.Models.ModelObject = try typed(retrieved)
  try check(retrievedFields.id == listFields.id, "Shared list/retrieve object payload")
  let constructed = OpenAI.Models.Model.object(
    .init(
      id: "constructed", created: 456, object: .model, owned_by: "fixture",
      shutdown_date: .some(nil)))
  try check(
    try sameModel(constructed).object?["shutdown_date"] == .null, "Constructed typed Model encoding"
  )
  do {
    _ = try sameModel(.nonObject(.object([:])))
    throw CheckFailure(message: "Nonobject case accepted object")
  } catch is CheckFailure {
    throw CheckFailure(message: "Expected nonobject encoder rejection")
  } catch {}
  let request = await transport.captures.last!
  try check(request.url.absoluteString == "https://example.test/v1/models/model%2Fa", "Models URL")
  try check(request.headers[.authorization] == "Bearer fixture-token", "Models credentials")
  for allowed in ["null", "true", "42", "\"other\"", "[]"] {
    await transport.set(body: allowed)
    guard case .status200(let value, _) = try await client.retrieveModel(.init(model: "model-test"))
    else {
      throw CheckFailure(message: "Allowed nonobject response")
    }
    try check(try sameModel(value) == JSONValue.parse(allowed), "Original nonobject validity")
  }
  for invalid in ["{}", #"{"id":123,"created":0,"object":"model","owned_by":"fixture"}"#] {
    await transport.set(body: invalid)
    do {
      _ = try await client.retrieveModel(.init(model: "model-test"))
      throw CheckFailure(message: "Invalid object fell through nonobject branch")
    } catch is CheckFailure {
      throw CheckFailure(message: "Expected Model object validation failure")
    } catch {}
  }
  await transport.set(status: 500, body: "{}")
  do {
    _ = try await client.listModels()
    throw CheckFailure(message: "Unspecified status accepted")
  } catch JSONClientError.unexpectedStatus(500) {}
  print(
    "Pinned OpenAI: typed Model/ModelObject sharing, object/nonobject validation, constructed encoding, list/retrieve mock execution passed."
  )
}

try await authoredConsumer()
try await openAIConsumer()
