import Foundation
import HTTPTypes
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

enum UnreadResponseError: Error { case bodyRead }

actor ResponseReadProbe {
  var reads = 0
  func read() throws -> ArraySlice<UInt8>? {
    reads += 1
    throw UnreadResponseError.bodyRead
  }
}

struct UnreadSSETransport: ClientTransport {
  let probe: ResponseReadProbe
  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
    -> (HTTPResponse, HTTPBody?)
  {
    let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error>(unfolding: {
      try await probe.read()
    })
    return (
      HTTPResponse(status: .ok, headerFields: [.contentType: "text/event-stream"]),
      HTTPBody(stream, length: .unknown, iterationBehavior: .single)
    )
  }
}
