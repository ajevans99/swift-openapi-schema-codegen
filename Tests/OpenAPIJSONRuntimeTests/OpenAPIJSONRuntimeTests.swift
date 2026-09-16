import CustomDump
import Foundation
import HTTPTypes
import JSONSchema
import OpenAPIJSONRuntime
import OpenAPIRuntime
import Testing

private struct UnusedTransport: ClientTransport {
  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
    -> (HTTPResponse, HTTPBody?)
  {
    Issue.record("prepare must not execute transport")
    throw JSONClientError.unexpectedStatus(0)
  }
}

@Test func parameterPreparation() async throws {
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test/v1")), transport: UnusedTransport())
  let (request, body) = try await client.prepare(
    JSONOperation(id: "retrieve", method: .get, path: "/models/{id}"),
    path: [.init(name: "id", value: .string("a/b é"), style: .simple, explode: false)],
    query: [
      .init(
        name: "tag", value: .array([.string("a,b"), .string("c d")]), style: .form, explode: true),
      .init(
        name: "items", value: .array([.integer(1), .integer(2)]), style: .form, explode: false),
    ])
  expectNoDifference(request.path, "/models/a%2Fb%20%C3%A9?tag=a%2Cb&tag=c%20d&items=1,2")
  #expect(body == nil)
}

@Test func mediaTypeAndEmptyBody() throws {
  let response = JSONResponse(
    status: 200, headers: [.contentType: "application/json; charset=utf-8"],
    body: Array("null".utf8))
  expectNoDifference(try response.json(), .null)
  #expect(throws: JSONClientError.unexpectedBody) { try response.requireEmptyBody() }
  #expect(throws: JSONClientError.unexpectedContentType("text/html")) {
    try JSONResponse(status: 200, headers: [.contentType: "text/html"], body: Array("{}".utf8))
      .json()
  }
}

private actor Recorder: ClientTransport {
  struct Capture: Sendable {
    let request: HTTPRequest
    let bytes: [UInt8]?
    let baseURL: URL
    let operationID: String
  }
  private(set) var captured: Capture?
  var response: String
  init(response: String = "{}") { self.response = response }
  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
    -> (HTTPResponse, HTTPBody?)
  {
    let bytes: [UInt8]?
    if let body { bytes = try await [UInt8](collecting: body, upTo: 1024) } else { bytes = nil }
    captured = Capture(request: request, bytes: bytes, baseURL: baseURL, operationID: operationID)
    return (
      HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
      HTTPBody(response)
    )
  }
}

private struct Credentials: JSONCredentialProvider {
  let values: [String: String]
  func credentials(for alternative: JSONSecurityAlternative) async throws -> [String: String]? {
    guard alternative.schemes.allSatisfy({ values[$0.name] != nil }) else { return nil }
    return Dictionary(uniqueKeysWithValues: alternative.schemes.map { ($0.name, values[$0.name]!) })
  }
}

@Test func transportAndSecurityInjection() async throws {
  let transport = Recorder()
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test/v1")), transport: transport,
    credentials: Credentials(values: ["key": "test/value", "token": "test-only"]))
  let operation = JSONOperation(
    id: "post", method: .post, path: "/widgets",
    security: [
      .init(schemes: [.init(name: "missing", placement: .basic)]),
      .init(schemes: [
        .init(name: "token", placement: .bearer),
        .init(name: "key", placement: .query("api_key")),
      ]),
    ])
  let number = try JSONValue.parse("123456789012345678901234567890123456789")
  let result = try await client.send(operation, body: number)
  let captured = try #require(await transport.captured)
  expectNoDifference(captured.request.path, "/widgets?api_key=test%2Fvalue")
  expectNoDifference(captured.request.headerFields[.authorization], "Bearer test-only")
  expectNoDifference(captured.request.headerFields[.contentType], "application/json")
  expectNoDifference(captured.baseURL.absoluteString, "https://example.test/v1")
  expectNoDifference(captured.operationID, "post")
  expectNoDifference(captured.bytes, Array("123456789012345678901234567890123456789".utf8))
  expectNoDifference(try result.json(), .object([:]))
}

@Test func bodyLimitAndFailurePropagation() async throws {
  let transport = Recorder(response: "12345")
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: transport,
    maximumResponseBodyBytes: 4)
  await #expect(throws: (any Error).self) {
    try await client.send(JSONOperation(id: "limit", method: .get, path: "/"))
  }
}

@Test func exactResponseLimitBoundary() async throws {
  let transport = Recorder(response: "1234")
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: transport,
    maximumResponseBodyBytes: 4)
  let response = try await client.send(JSONOperation(id: "boundary", method: .get, path: "/"))
  expectNoDifference(response.body, Array("1234".utf8))
}

@Test func credentialCollisionsAndAnonymousAlternative() async throws {
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: UnusedTransport(),
    credentials: Credentials(values: ["key": "test"]))
  let operation = JSONOperation(
    id: "collision", method: .get, path: "/",
    security: [
      .init(schemes: [.init(name: "key", placement: .query("key"))])
    ])
  await #expect(throws: JSONClientError.credentialCollision("key")) {
    try await client.prepare(
      operation,
      query: [
        .init(name: "key", value: .string("existing"), style: .form, explode: true)
      ])
  }
  let anonymous = JSONOperation(
    id: "anonymous", method: .get, path: "/",
    security: [
      .init(schemes: [.init(name: "missing", placement: .bearer)]),
      .init(schemes: []),
    ])
  let (request, _) = try await client.prepare(anonymous)
  #expect(request.headerFields[.authorization] == nil)
}

@Test func missingAndInvalidCredentials() async throws {
  let transport = Recorder()
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: transport)
  let operation = JSONOperation(
    id: "auth", method: .get, path: "/",
    security: [
      .init(schemes: [.init(name: "token", placement: .bearer)])
    ])
  await #expect(throws: JSONClientError.missingCredentials("auth")) {
    try await client.prepare(operation)
  }
  let invalid = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: transport,
    credentials: Credentials(values: ["token": "bad\r\nheader"]))
  await #expect(throws: JSONClientError.invalidHeader("token")) {
    try await invalid.prepare(operation)
  }
}

@Test func encodingStylesAndUnsafePaths() async throws {
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: UnusedTransport())
  let operation = JSONOperation(id: "styles", method: .get, path: "/{id}")
  let (request, _) = try await client.prepare(
    operation,
    path: [
      .init(
        name: "id", value: .array([.string("a,b"), .string("c")]), style: .simple, explode: true)
    ],
    query: [
      .init(
        name: "spaces", value: .array([.string("a b"), .string("c")]), style: .spaceDelimited,
        explode: false),
      .init(
        name: "pipes", value: .array([.string("a|b"), .string("c")]), style: .pipeDelimited,
        explode: false),
    ])
  expectNoDifference(request.path, "/a%2Cb,c?spaces=a%20b%20c&pipes=a%7Cb%7Cc")
  await #expect(throws: JSONClientError.invalidParameter("id")) {
    try await client.prepare(
      operation, path: [.init(name: "id", value: .string(".."), style: .simple, explode: false)])
  }
  #expect(throws: JSONClientError.invalidBaseURL) {
    try JSONClient(
      serverURL: #require(URL(string: "https://user:password@example.test")),
      transport: UnusedTransport())
  }
}

@Test func cancellationDoesNotExecuteTransport() async throws {
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")), transport: UnusedTransport())
  let task = Task {
    try Task.checkCancellation()
    try await Task.sleep(for: .seconds(10))
    return try await client.send(JSONOperation(id: "cancelled", method: .get, path: "/"))
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

private enum BodyProbeError: Error { case read }

private actor BodyProbe {
  private(set) var reads = 0
  func read() throws -> ArraySlice<UInt8>? {
    reads += 1
    throw BodyProbeError.read
  }
}

private struct UnreadBodyTransport: ClientTransport {
  let probe: BodyProbe
  let contentType: String
  var cancelAfterHeaders = false

  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
    -> (HTTPResponse, HTTPBody?)
  {
    if cancelAfterHeaders {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error>(unfolding: {
      try await probe.read()
    })
    return (
      HTTPResponse(status: .ok, headerFields: [.contentType: contentType]),
      HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    )
  }
}

@Test func responseValidationRunsBeforeRequestingAnyBodyChunks() async throws {
  let probe = BodyProbe()
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")),
    transport: UnreadBodyTransport(probe: probe, contentType: "text/event-stream"))
  let operation = JSONOperation(id: "profiled", method: .post, path: "/messages")
  await #expect(throws: JSONClientError.unexpectedContentType("text/event-stream")) {
    try await client.send(
      operation,
      validateResponse: {
        try JSONResponse.validateContentType($0.headerFields)
      })
  }
  let readsBeforeCollection = await probe.reads
  expectNoDifference(readsBeforeCollection, 0)

  // Without the opt-in hook, send still leaves media policy to the decoder.
  await #expect(throws: BodyProbeError.read) {
    try await client.send(operation)
  }
  let readsAfterCollection = await probe.reads
  expectNoDifference(readsAfterCollection, 1)
}

@Test func acceptedResponseHeadersStillPropagateBodyErrors() async throws {
  let probe = BodyProbe()
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")),
    transport: UnreadBodyTransport(
      probe: probe, contentType: "APPLICATION/PROBLEM+JSON; charset=utf-8"))
  await #expect(throws: BodyProbeError.read) {
    try await client.send(
      JSONOperation(id: "profiled", method: .get, path: "/"),
      validateResponse: {
        try JSONResponse.validateContentType(
          $0.headerFields, mediaTypes: ["application/problem+json"])
      })
  }
  let reads = await probe.reads
  expectNoDifference(reads, 1)
}

@Test func cancellationAfterHeadersPrecedesProfileValidation() async throws {
  let probe = BodyProbe()
  let client = try JSONClient(
    serverURL: #require(URL(string: "https://example.test")),
    transport: UnreadBodyTransport(
      probe: probe, contentType: "text/event-stream", cancelAfterHeaders: true))
  let task = Task {
    try await client.send(
      JSONOperation(id: "cancelled", method: .get, path: "/"),
      validateResponse: { try JSONResponse.validateContentType($0.headerFields) })
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  let reads = await probe.reads
  expectNoDifference(reads, 0)
}
