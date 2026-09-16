import Foundation
import GeneratedAPI
import HTTPTypes
import JSONSchema
import JSONSchemaBuilder
import OpenAPIJSONRuntime
import OpenAPIRuntime

func profileConsumer() async throws {
  let transport = MockTransport()
  let client = try Profiled.Client(
    serverURL: URL(string: "https://example.test/v1")!, transport: transport,
    credentials: TestCredentials())
  let exact = try JSONValue.parse("123456789012345678901234567890.123456789")
  let absent = Profiled.Models.Message(
    message_text: "Hello", additionalProperties: ["exact": exact])
  let disabled = Profiled.Models.Message(
    message_text: "Hello", stream: false, additionalProperties: [:])
  let enabled = Profiled.Models.Message(
    message_text: "Hello", stream: true, additionalProperties: [:])

  // This is an additional client invariant, not a mutation of the original schema.
  let original = try Profiled.Models.createMessageBodyJSON(enabled)
  try check(original.object?["stream"] == .boolean(true), "Original schema still permits true")
  await transport.set(body: #"{"message-text":"Reply","stream":true}"#)
  for value in [absent, disabled] {
    let encoded = try Profiled.Models.createMessageBodyJSON(value)
    guard case .status200(let reply, _) = try await client.createMessage(.init(body: value)) else {
      throw CheckFailure(message: "Profiled JSON success")
    }
    try check(
      reply.message_text == "Reply" && reply.stream == true,
      "Request constraint does not change response schema")
    let capture = await transport.captures.last!
    try check(capture.method == .post, "Profiled POST")
    try check(capture.url.absoluteString == "https://example.test/v1/messages", "Profiled URL")
    try check(capture.headers[.accept] == "application/json", "Only selected JSON Accept")
    try check(capture.headers[.contentType] == "application/json", "Selected request media")
    try check(capture.headers[.authorization] != nil, "Profiled authorization")
    try check(
      capture.body == Array((try encoded.serialized()).utf8), "Original keys and exact body")
  }
  let before = await transport.captures.count
  for invalid in [enabled, .init(message_text: "", additionalProperties: [:])] {
    do {
      _ = try await client.createMessage(.init(body: invalid))
      throw CheckFailure(message: "Invalid profiled request reached transport")
    } catch is ParseAndValidateIssue {}
  }
  try check(await transport.captures.count == before, "Both constraints fail before transport")

  let probe = ResponseReadProbe()
  let unreadClient = try Profiled.Client(
    serverURL: URL(string: "https://example.test/v1")!,
    transport: UnreadSSETransport(probe: probe), credentials: TestCredentials())
  do {
    _ = try await unreadClient.createMessage(.init(body: absent))
    throw CheckFailure(message: "Unread SSE response accepted")
  } catch JSONClientError.unexpectedContentType("text/event-stream") {}
  try check(await probe.reads == 0, "SSE rejected without requesting a response chunk")

  await transport.set(contentType: "text/event-stream", body: "data: {}")
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "SSE response accepted")
  } catch JSONClientError.unexpectedContentType("text/event-stream") {}
  await transport.set(body: #"{"message-text":""}"#)
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "Original response validation bypassed")
  } catch is ParseAndValidateIssue {}
  await transport.set(status: 201, body: #"{"message-text":"Range"}"#)
  guard
    case .status2XX(let code, let ranged, _) = try await client.createMessage(.init(body: absent))
  else {
    throw CheckFailure(message: "Profile preserves range responses")
  }
  try check(code == 201 && ranged.message_text == "Range", "Profiled range payload")
  await transport.set(status: 204, contentType: "text/event-stream", body: "")
  guard case .status204 = try await client.createMessage(.init(body: absent)) else {
    throw CheckFailure(message: "Profile preserves bodyless responses")
  }
  await transport.set(status: 204, contentType: "text/event-stream", body: "data: {}")
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "Profile accepted unexpected body")
  } catch JSONClientError.unexpectedBody {}
  await transport.set(status: 500, contentType: "text/event-stream", body: "data: {}")
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "Profile accepted undocumented status")
  } catch JSONClientError.unexpectedStatus(500) {}
  do {
    _ = try await unreadClient.fallbackMessage()
    throw CheckFailure(message: "Default response accepted unread SSE")
  } catch JSONClientError.unexpectedContentType("text/event-stream") {}
  try check(await probe.reads == 0, "Default response headers precede body iteration")
  await transport.set(status: 500, body: #"{"message-text":"Default"}"#)
  guard case .defaultResponse(let status, let fallback, _) = try await client.fallbackMessage()
  else {
    throw CheckFailure(message: "Profile lost default response")
  }
  try check(status == 500 && fallback.message_text == "Default", "Profiled default payload")
  await transport.set(status: 204, contentType: "text/event-stream", body: "")
  guard case .status204 = try await client.fallbackMessage() else {
    throw CheckFailure(message: "Profile exact bodyless status must precede default JSON")
  }
  await transport.setFailure(true)
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "Profile swallowed transport error")
  } catch MockFailure.transport {}
  await transport.setFailure(false, cancellation: true)
  do {
    _ = try await client.createMessage(.init(body: absent))
    throw CheckFailure(message: "Profile swallowed cancellation")
  } catch is CancellationError {}
  print(
    "Authored profile: omitted/false streaming, pre-send constraints, typed reply, SSE refusal and propagation passed."
  )
}
