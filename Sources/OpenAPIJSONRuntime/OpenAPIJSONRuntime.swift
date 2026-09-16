import Foundation
import HTTPTypes
import JSONSchema
import OpenAPIRuntime

/// Located generation errors are separate from transport, schema, and HTTP failures.
public enum JSONClientError: Error, Sendable, Equatable {
  case invalidBaseURL
  case invalidParameter(String)
  case invalidPathTemplate(String)
  case invalidHeader(String)
  case credentialCollision(String)
  case missingCredentials(String)
  case unexpectedStatus(Int)
  case unexpectedContentType(String?)
  case missingBody
  case unexpectedBody
  case invalidUTF8
  case invalidResponseLimit
}

public struct JSONSecurityScheme: Sendable, Equatable {
  public enum Placement: Sendable, Equatable {
    case bearer
    case basic
    case header(String)
    case query(String)
  }

  public let name: String
  public let placement: Placement
  public let scopes: [String]

  public init(name: String, placement: Placement, scopes: [String] = []) {
    self.name = name
    self.placement = placement
    self.scopes = scopes
  }
}

/// One alternative is an AND of schemes; the outer array on an operation is an OR.
public struct JSONSecurityAlternative: Sendable, Equatable {
  public let schemes: [JSONSecurityScheme]

  public init(schemes: [JSONSecurityScheme]) {
    self.schemes = schemes
  }
}

/// Return raw credential values keyed by scheme name, or nil to try another alternative.
/// Bearer/basic prefixes are applied by the runtime. A basic value is already base64 encoded.
public protocol JSONCredentialProvider: Sendable {
  func credentials(for alternative: JSONSecurityAlternative) async throws -> [String: String]?
}

public struct JSONOperation: Sendable {
  public let id: String
  public let method: HTTPRequest.Method
  public let path: String
  public let security: [JSONSecurityAlternative]
  public let acceptedMediaTypes: [String]

  public init(
    id: String, method: HTTPRequest.Method, path: String,
    security: [JSONSecurityAlternative] = [], acceptedMediaTypes: [String] = ["application/json"]
  ) {
    self.id = id
    self.method = method
    self.path = path
    self.security = security
    self.acceptedMediaTypes = acceptedMediaTypes
  }
}

public struct JSONParameter: Sendable {
  public enum Style: Sendable {
    case simple
    case form
    case spaceDelimited
    case pipeDelimited
  }

  public let name: String
  public let value: JSONValue
  public let style: Style
  public let explode: Bool

  public init(name: String, value: JSONValue, style: Style, explode: Bool) {
    self.name = name
    self.value = value
    self.style = style
    self.explode = explode
  }
}

/// The body is deliberately buffered with a limit: this runtime is JSON-only, not streaming.
public struct JSONResponse: Sendable {
  public let status: Int
  public let headers: HTTPFields
  public let body: [UInt8]

  public init(status: Int, headers: HTTPFields = [:], body: [UInt8] = []) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public func json(mediaTypes: [String] = ["application/json"]) throws -> JSONValue {
    guard !body.isEmpty else { throw JSONClientError.missingBody }
    try Self.validateContentType(headers, mediaTypes: mediaTypes)
    guard let text = String(bytes: body, encoding: .utf8) else {
      throw JSONClientError.invalidUTF8
    }
    return try JSONValue.parse(text)
  }

  /// Checks JSON response headers without consuming a potentially streaming body.
  public static func validateContentType(
    _ headers: HTTPFields, mediaTypes: [String] = ["application/json"]
  ) throws {
    let header = headers[.contentType]
    let mediaType = header?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespaces).lowercased()
    guard let mediaType, mediaTypes.contains(where: { $0.lowercased() == mediaType }) else {
      throw JSONClientError.unexpectedContentType(header)
    }
  }

  public func requireEmptyBody() throws {
    guard body.isEmpty else { throw JSONClientError.unexpectedBody }
  }
}

/// Uses Apple's actual ClientTransport protocol, so existing transport adapters can be injected.
public struct JSONClient: Sendable {
  public let serverURL: URL
  public let transport: any ClientTransport
  public let credentials: (any JSONCredentialProvider)?
  public let maximumResponseBodyBytes: Int

  public init(
    serverURL: URL, transport: any ClientTransport,
    credentials: (any JSONCredentialProvider)? = nil,
    maximumResponseBodyBytes: Int = 16 * 1024 * 1024
  ) throws {
    guard let parts = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.host != nil, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil
    else { throw JSONClientError.invalidBaseURL }
    guard maximumResponseBodyBytes >= 0 else { throw JSONClientError.invalidResponseLimit }
    self.serverURL = serverURL
    self.transport = transport
    self.credentials = credentials
    self.maximumResponseBodyBytes = maximumResponseBodyBytes
  }

  /// Prepare is also usable without execution, for deterministic request inspection.
  public func prepare(
    _ operation: JSONOperation, path: [JSONParameter] = [], query: [JSONParameter] = [],
    body: JSONValue? = nil, contentType: String = "application/json"
  ) async throws -> (HTTPRequest, HTTPBody?) {
    var template = operation.path
    var seenPath = Set<String>()
    for parameter in path {
      guard parameter.style == .simple, seenPath.insert(parameter.name).inserted,
        template.contains("{\(parameter.name)}")
      else { throw JSONClientError.invalidParameter(parameter.name) }
      let values = try Self.scalars(parameter)
      let value = values.map(Self.percentEncode).joined(separator: ",")
      guard value != ".", value != ".." else {
        throw JSONClientError.invalidParameter(parameter.name)
      }
      template = template.replacingOccurrences(of: "{\(parameter.name)}", with: value)
    }
    guard template.hasPrefix("/"), !template.hasPrefix("//"),
      !template.contains("{"), !template.contains("}"),
      !template.contains("?"), !template.contains("#"),
      !template.utf8.contains(where: { $0 <= 32 || $0 == 127 }),
      !template.contains("\\")
    else { throw JSONClientError.invalidPathTemplate(operation.path) }
    var queryItems: [(String, String)] = []
    for parameter in query {
      guard parameter.style != .simple else {
        throw JSONClientError.invalidParameter(parameter.name)
      }
      let values = try Self.scalars(parameter)
      if parameter.style == .form && parameter.explode {
        queryItems += values.map { (Self.percentEncode(parameter.name), Self.percentEncode($0)) }
      } else {
        let separator: String
        switch parameter.style {
        case .form: separator = ","
        case .spaceDelimited: separator = "%20"
        case .pipeDelimited: separator = "%7C"
        case .simple: throw JSONClientError.invalidParameter(parameter.name)
        }
        queryItems.append(
          (
            Self.percentEncode(parameter.name),
            values.map(Self.percentEncode).joined(separator: separator)
          ))
      }
    }
    var headers = HTTPFields()
    let accepts = operation.acceptedMediaTypes.joined(separator: ", ")
    guard !accepts.utf8.contains(where: { $0 < 32 || $0 == 127 }),
      !contentType.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw JSONClientError.invalidHeader("Content-Type/Accept") }
    if !accepts.isEmpty { headers[.accept] = accepts }
    if body != nil { headers[.contentType] = contentType }
    try await authorize(operation, headers: &headers, query: &queryItems)
    if !queryItems.isEmpty {
      template += "?" + queryItems.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
    }
    return (
      HTTPRequest(
        method: operation.method, scheme: nil, authority: nil, path: template, headerFields: headers
      ),
      try body.map { HTTPBody(try $0.serialized()) }
    )
  }

  /// An optional response validator runs after transport headers arrive, before body iteration.
  public func send(
    _ operation: JSONOperation, path: [JSONParameter] = [], query: [JSONParameter] = [],
    body: JSONValue? = nil, contentType: String = "application/json",
    validateResponse: (@Sendable (HTTPResponse) throws -> Void)? = nil
  ) async throws -> JSONResponse {
    try Task.checkCancellation()
    let (request, requestBody) = try await prepare(
      operation, path: path, query: query, body: body, contentType: contentType)
    let (response, responseBody) = try await transport.send(
      request, body: requestBody, baseURL: serverURL, operationID: operation.id)
    if let validateResponse {
      try Task.checkCancellation()
      try validateResponse(response)
    }
    let bytes =
      try await responseBody.mapAsync {
        try await [UInt8](collecting: $0, upTo: maximumResponseBodyBytes)
      } ?? []
    try Task.checkCancellation()
    return JSONResponse(status: response.status.code, headers: response.headerFields, body: bytes)
  }

  private func authorize(
    _ operation: JSONOperation, headers: inout HTTPFields, query: inout [(String, String)]
  ) async throws {
    guard !operation.security.isEmpty else { return }
    for alternative in operation.security {
      if alternative.schemes.isEmpty { return }
      guard let values = try await credentials?.credentials(for: alternative) else { continue }
      guard Set(values.keys) == Set(alternative.schemes.map(\.name)) else {
        throw JSONClientError.missingCredentials(operation.id)
      }
      for scheme in alternative.schemes {
        guard let value = values[scheme.name], !value.isEmpty,
          !value.utf8.contains(where: { $0 < 32 || $0 == 127 })
        else { throw JSONClientError.invalidHeader(scheme.name) }
        switch scheme.placement {
        case .query(let name):
          let encoded = Self.percentEncode(name)
          guard !query.contains(where: { $0.0 == encoded }) else {
            throw JSONClientError.credentialCollision(name)
          }
          query.append((encoded, Self.percentEncode(value)))
        case .bearer, .basic, .header:
          let name: String
          let headerValue: String
          switch scheme.placement {
          case .bearer:
            name = "Authorization"
            headerValue = "Bearer " + value
          case .basic:
            name = "Authorization"
            headerValue = "Basic " + value
          case .header(let field):
            name = field
            headerValue = value
          case .query: preconditionFailure("Query credentials handled above")
          }
          guard let field = HTTPField.Name(name) else { throw JSONClientError.invalidHeader(name) }
          guard headers[field] == nil else { throw JSONClientError.credentialCollision(name) }
          headers[field] = headerValue
        }
      }
      return
    }
    throw JSONClientError.missingCredentials(operation.id)
  }

  private static func scalars(_ parameter: JSONParameter) throws -> [String] {
    func scalar(_ value: JSONValue) throws -> String {
      if let string = value.string { return string }
      if value.boolean != nil || value.numberLiteral != nil {
        return try value.serialized()
      }
      throw JSONClientError.invalidParameter(parameter.name)
    }
    if let array = parameter.value.array { return try array.map(scalar) }
    return [try scalar(parameter.value)]
  }

  private static func percentEncode(_ string: String) -> String {
    string.utf8.map { byte in
      switch byte {
      case 65...90, 97...122, 48...57, 45, 46, 95, 126:
        return String(UnicodeScalar(byte))
      default:
        return String(format: "%%%02X", byte)
      }
    }.joined()
  }
}

extension Optional {
  fileprivate func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    switch self {
    case .none: return nil
    case .some(let value): return try await transform(value)
    }
  }
}
