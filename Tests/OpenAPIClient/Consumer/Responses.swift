import Foundation
import GeneratedAPI
import HTTPTypes
import JSONSchema
import JSONSchemaBuilder
import OpenAPIJSONRuntime

typealias API = OpenAIResponsesAPI

func responsesConsumer() async throws {
  guard CommandLine.arguments.count == 2 else {
    throw CheckFailure(message: "Pass the authored Responses reply fixture path.")
  }
  let reply = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
  let transport = MockTransport()
  let client = try API.Client(
    serverURL: URL(string: "https://example.test/v1")!, transport: transport,
    credentials: TestCredentials())
  func submission(
    stream: Bool?? = nil, temperature: Double?? = nil,
    extras: [String: JSONValue] = [:]
  ) -> API.Models.CreateResponse {
    .init(
      temperature: temperature,
      model: .openapiJsonModelIdsShared(.string("gpt-5.5")),
      tools: [
        .functionTool(
          .init(
            type: .function, name: "lookup", parameters: ["type": .string("object")], strict: nil))
      ],
      input: .string("Hello"), instructions: .some(nil), stream: stream,
      unmodeledProperties: extras)
  }
  let input = API.Operations.createResponse.Input(body: submission())
  let clock = ContinuousClock()
  let start = clock.now
  let json = try API.Models.createResponseBodyJSON(input.body)
  print("Cold request schema encoding/validation: \(start.duration(to: clock.now))")
  try check(json.object?["stream"] == nil, "Omitted stream")
  try check(json.object?["instructions"] == .null, "Explicit nullable instructions")
  try check(json.object?["input"] == .string("Hello"), "Typed simple text request")
  try check(
    json.object?["tools"]?.array?.first?.object?["name"] == .string("lookup"),
    "Typed function tool")
  await transport.set(body: reply)
  let responseStart = clock.now
  guard case .status200(let body, _) = try await client.createResponse(input) else {
    throw CheckFailure(message: "Expected typed Responses 200")
  }
  print("Cold response decoding: \(responseStart.duration(to: clock.now))")
  try check(body.id == "resp_recording", "Typed response ID")
  guard let item = body.output.first, case .outputMessage(let message) = item,
    let fragment = message.content.first, case .outputText(let content) = fragment
  else { throw CheckFailure(message: "Expected typed output message and text content") }
  try check(
    content.text == "Hello \u{4e16}\u{754c}" && content.logprobs.isEmpty,
    "Typed Unicode output and required logprobs")
  let capture = await transport.captures.last!
  try check(capture.method == .post, "Responses POST")
  try check(capture.url.absoluteString == "https://example.test/v1/responses", "Responses URL")
  try check(
    capture.headers[.authorization] == "Bearer fixture-token", "Responses bearer credentials")
  try check(capture.headers[.contentType] == "application/json", "Responses Content-Type")
  try check(capture.headers[.accept] == "application/json", "Nonstreaming Accept")
  try check(capture.body == Array((try json.serialized()).utf8), "Exact serialized request")
  _ = try await client.createResponse(.init(body: submission(stream: false)))
  let before = await transport.captures.count
  for invalid in [
    submission(stream: true), submission(stream: .some(nil)), submission(temperature: 3),
  ] {
    do {
      _ = try await client.createResponse(.init(body: invalid))
      throw CheckFailure(message: "Invalid Responses request reached transport")
    } catch is ParseAndValidateIssue {}
  }
  try check(await transport.captures.count == before, "Responses invalid requests fail pre-send")
  do {
    _ = try await client.createResponse(
      .init(body: submission(extras: ["input": .string("other")])))
    throw CheckFailure(message: "Responses accepted an unknown-field collision")
  } catch {
    guard
      String(describing: error).hasSuffix(
        "Additional property collides with a modeled JSON key: input")
    else { throw error }
  }
  try check(await transport.captures.count == before, "Responses collisions fail pre-send")
  let probe = ResponseReadProbe()
  let sseClient = try API.Client(
    serverURL: URL(string: "https://example.test/v1")!,
    transport: UnreadSSETransport(probe: probe), credentials: TestCredentials())
  do {
    _ = try await sseClient.createResponse(input)
    throw CheckFailure(message: "Responses accepted unread SSE")
  } catch JSONClientError.unexpectedContentType("text/event-stream") {}
  try check(await probe.reads == 0, "Responses rejects SSE before any body chunks")
  for status in [429, 503] {
    await transport.set(
      status: status,
      body:
        #"{"error":{"message":"slow","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}}"#
    )
    let output = try await client.createResponse(input)
    switch (status, output) {
    case (429, .status429(let error, _)), (503, .status503(let error, _)):
      try check(error.error.message == "slow", "Typed JSON error response")
    default:
      throw CheckFailure(message: "Expected typed \(status) JSON error")
    }
  }
  let original = try JSONValue.parse(reply)
  var invalidResponse = original.object!
  invalidResponse.removeValue(forKey: "id")
  await transport.set(body: try JSONValue.object(invalidResponse).serialized())
  do {
    _ = try await client.createResponse(input)
    throw CheckFailure(message: "Responses bypassed original response schema validation")
  } catch is ParseAndValidateIssue {}
  await transport.setFailure(true)
  do {
    _ = try await client.createResponse(input)
    throw CheckFailure(message: "Responses swallowed transport error")
  } catch MockFailure.transport {}
  await transport.setFailure(false, cancellation: true)
  do {
    _ = try await client.createResponse(input)
    throw CheckFailure(message: "Responses swallowed cancellation")
  } catch is CancellationError {}

  let roundTrip = try API.Models.createResponseResponse200JSON(body)
  try check(roundTrip == original, "Response must round trip the complete JSONValue")
  var requestObject = json.object!
  requestObject["future_integer"] = original.object?["future_integer"]
  requestObject["future_decimal"] = original.object?["future_decimal"]
  requestObject["future_null"] = .null
  requestObject["future_nested"] = .object([
    "values": .array([original.object!["future_decimal"]!, .null])
  ])
  let parsed = try API.Models.createResponseBodySchema.parseAndValidate(.object(requestObject))
  let requestRoundTrip = try API.Models.createResponseBodyJSON(parsed)
  try check(
    requestRoundTrip == .object(requestObject),
    "Request must round trip the complete JSONValue including implicit additional properties")
  print(
    "Pristine generated Responses: typed request/reply, tools, constraints, exact extras and transport passed."
  )
}

try await responsesConsumer()
