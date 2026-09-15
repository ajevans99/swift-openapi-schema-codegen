import Foundation
import JSONSchemaCodegenCore
import OpenAPISchema
import OrderedJSON

extension OpenAPICodeGenerator {
  /// Generates only explicitly selected operations; no schema or HTTP network access occurs.
  public func generate(
    _ document: OpenAPIJSONDocument, operationIDs: [String]
  ) throws -> GeneratedOpenAPIClient {
    guard !operationIDs.isEmpty else {
      throw OpenAPICodegenError(diagnostics: [
        .init(
          severity: .error, operationID: "", pointer: "/paths",
          message: "Select at least one operation.")
      ])
    }
    let result = try plan(document, operationIDs: operationIDs)
    let errors = result.diagnostics.filter { $0.severity == .error }
    guard errors.isEmpty else { throw OpenAPICodegenError(diagnostics: errors) }
    guard SwiftNames.allocate([options.namespace]) == [options.namespace],
      !["Self", "self", "Type", "Protocol", "JSONValue", "JSONClient", "HTTPFields"].contains(
        options.namespace)
    else {
      throw OpenAPICodegenError(diagnostics: [
        .init(severity: .error, operationID: "", pointer: "", message: "Invalid Swift namespace.")
      ])
    }
    let roots = result.operations.flatMap(\.roots)
    let schemaDocument = SchemaDocument(
      source: try normalizedDocument(document, schemaPointers: roots.map(\.pointer)).serialized(),
      retrievalURI: document.sourceURI ?? URL(string: "https://codegen.invalid/openapi.json")!,
      logicalName: "openapi.json")
    let shared: GeneratedSharedSchemas
    do {
      shared = try SchemaGenerator(
        options: .init(
          output: .models, recursiveObjects: options.recursiveObjects)
      ).generateShared(
        document: schemaDocument, schemaPointers: roots.map(\.pointer), rootNames: roots.map(\.name)
      )
    } catch let error as SchemaGenerationError {
      throw OpenAPICodegenError(diagnostics: [
        .init(
          severity: .error, operationID: operationIDs.joined(separator: ","),
          pointer: error.pointer, message: error.message)
      ])
    }
    let parsers = shared.roots.map { root in
      """
      public static var `\(root.name)Schema`: some JSONSchemaComponent<`\(root.name)`> {
        \(root.expression)
      }
      public static func `\(root.name)JSON`(_ value: `\(root.name)`) throws -> JSONValue {
        let json = try (\(root.encodingExpression))(value)
        _ = try `\(root.name)Schema`.parseAndValidate(json)
        return json
      }
      """
    }.joined(separator: "\n")
    let operations = result.operations.map(operationSource).joined(separator: "\n")
    let methods = result.operations.map { operation in
      """
      public func `\(operation.name)`(_ input: Operations.`\(operation.name)`.Input\(operation.parameters.isEmpty && operation.bodyRoot == nil ? " = .init()" : "")) async throws -> Operations.`\(operation.name)`.Output {
        let prepared = try Operations.`\(operation.name)`.request(input)
        let response = try await runtime.send(
          Operations.`\(operation.name)`.descriptor,
          path: prepared.path, query: prepared.query, body: prepared.body,
          contentType: \(literal(operation.bodyMediaType ?? "application/json")))
        return try Operations.`\(operation.name)`.decode(response)
      }
      """
    }.joined(separator: "\n")
    let source = """
      // Generated from explicitly selected OpenAPI 3.1 operations. Do not edit.
      import Foundation
      import HTTPTypes
      import JSONSchema
      import JSONSchemaBuilder
      import OpenAPIRuntime
      import OpenAPIJSONRuntime

      public enum `\(options.namespace)` {
        public enum Models {
          \(shared.declarations.joined(separator: "\n"))
          \(parsers)
        }
        public enum Operations {
          \(operations)
        }
        public struct Client: Sendable {
          public let runtime: JSONClient
          public init(runtime: JSONClient) { self.runtime = runtime }
          public init(
            serverURL: URL, transport: any ClientTransport,
            credentials: (any JSONCredentialProvider)? = nil,
            maximumResponseBodyBytes: Int = 16 * 1024 * 1024
          ) throws {
            runtime = try JSONClient(
              serverURL: serverURL, transport: transport, credentials: credentials,
              maximumResponseBodyBytes: maximumResponseBodyBytes)
          }
          \(methods)
        }
      }

      """
    return GeneratedOpenAPIClient(
      source: source,
      operationNames: Dictionary(uniqueKeysWithValues: result.operations.map { ($0.id, $0.name) }),
      diagnostics: result.diagnostics)
  }

  private func operationSource(_ operation: OperationPlan) -> String {
    var fields = operation.parameters.map {
      (name: $0.field, type: "Models.`\($0.root)`", optional: !$0.view.required)
    }
    if let body = operation.bodyRoot {
      fields.append(
        (
          name: "body", type: "Models.`\(body)`",
          optional: operation.view.requestBody?.required != true
        ))
    }
    let properties = fields.map {
      "public let `\($0.name)`: \($0.type)\($0.optional ? "?" : "")"
    }.joined(separator: "\n")
    let arguments = fields.map {
      "`\($0.name)`: \($0.type)\($0.optional ? "? = nil" : "")"
    }.joined(separator: ", ")
    let assignments = fields.map { "self.`\($0.name)` = `\($0.name)`" }.joined(separator: "\n")
    let parameterValues = operation.parameters.map { parameter in
      let append = """
        \(parameter.view.location).append(JSONParameter(
          name: \(literal(parameter.view.name)),
          value: try Models.`\(parameter.root)JSON`(value),
          style: .\(parameter.style), explode: \(parameter.explode)))
        """
      if parameter.view.required {
        return "do { let value = input.`\(parameter.field)`; \(append) }"
      }
      return "if let value = input.`\(parameter.field)` { \(append) }"
    }.joined(separator: "\n")
    let bodyValue: String
    if let root = operation.bodyRoot {
      bodyValue =
        operation.view.requestBody?.required == true
        ? "let body: JSONValue? = try Models.`\(root)JSON`(input.body)"
        : "let body: JSONValue? = try input.body.map { try Models.`\(root)JSON`($0) }"
    } else {
      bodyValue = "let body: JSONValue? = nil"
    }
    let responseCases = operation.responses.map { response in
      var values: [String] = []
      if Int(response.view.status) == nil { values.append("status: Int") }
      if let root = response.root { values.append("body: Models.`\(root)`") }
      values.append("headers: HTTPFields")
      return "case `\(response.caseName)`(\(values.joined(separator: ", ")))"
    }.joined(separator: "\n")
    let orderedResponses = operation.responses.sorted {
      func order(_ value: String) -> String {
        value == "default" ? "2" : (Int(value) == nil ? "1" : "0") + value
      }
      return order($0.view.status) < order($1.view.status)
    }
    var decoding = orderedResponses.map { response in
      let condition: String
      var values: [String] = []
      if let status = Int(response.view.status) {
        condition = "case \(status):"
      } else if response.view.status == "default" {
        condition = "default:"
        values.append("status: response.status")
      } else {
        let range = Int(response.view.status.prefix(1))! * 100
        condition = "case \(range)..<\(range + 100):"
        values.append("status: response.status")
      }
      let parsing: String
      if let root = response.root, let media = response.mediaType {
        parsing =
          "let body = try Models.`\(root)Schema`.parseAndValidate(response.json(mediaTypes: [\(literal(media))]))"
        values.append("body: body")
      } else {
        parsing = "try response.requireEmptyBody()"
      }
      values.append("headers: response.headers")
      return """
        \(condition)
          \(parsing)
          return .`\(response.caseName)`(\(values.joined(separator: ", ")))
        """
    }.joined(separator: "\n")
    if !operation.responses.contains(where: { $0.view.status == "default" }) {
      decoding += "\ndefault: throw JSONClientError.unexpectedStatus(response.status)"
    }
    let accepted = Array(Set(operation.responses.compactMap(\.mediaType))).sorted().map(literal)
      .joined(separator: ", ")
    return """
      public enum `\(operation.name)` {
        public struct Input: Sendable {
          \(properties)
          public init(\(arguments)) {
            \(assignments)
          }
        }
        public enum Output: Sendable {
          \(responseCases)
        }
        public static var descriptor: JSONOperation {
          JSONOperation(
            id: \(literal(operation.id)), method: .\(operation.view.method),
            path: \(literal(operation.view.path)),
            security: \(operation.securitySource), acceptedMediaTypes: [\(accepted)])
        }
        public static func request(_ input: Input) throws -> (path: [JSONParameter], query: [JSONParameter], body: JSONValue?) {
          \(operation.parameters.contains(where: { $0.view.location == "path" }) ? "var" : "let") path: [JSONParameter] = []
          \(operation.parameters.contains(where: { $0.view.location == "query" }) ? "var" : "let") query: [JSONParameter] = []
          \(parameterValues)
          \(bodyValue)
          return (path, query, body)
        }
        public static func decode(_ response: JSONResponse) throws -> Output {
          switch response.status {
          \(decoding)
          }
        }
      }
      """
  }

  private func normalizedDocument(
    _ document: OpenAPIJSONDocument, schemaPointers: [String]
  ) throws -> JSONValue {
    var schemaLocations = Set<String>()
    func collect(_ pointer: String) throws {
      guard schemaLocations.insert(pointer).inserted,
        let object = try document.value(at: pointer).value.object
      else { return }
      if let reference = object["$ref"]?.string, let target = localPointer(reference) {
        try collect(target)
      }
      for keyword in ["properties", "patternProperties", "$defs", "dependentSchemas"] {
        for key in (object[keyword]?.object ?? [:]).keys {
          try collect(pointer + "/" + keyword + "/" + escapePointer(key))
        }
      }
      for keyword in [
        "items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "contains",
        "not", "if", "then", "else", "propertyNames", "contentSchema",
      ] where object[keyword] != nil {
        try collect(pointer + "/" + keyword)
      }
      for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
        for index in (object[keyword]?.array ?? []).indices {
          try collect(pointer + "/" + keyword + "/\(index)")
        }
      }
    }
    for pointer in schemaPointers { try collect(pointer) }
    // Normalize only explicit schema dialect declarations, never nullable/discriminator semantics.
    func normalize(_ value: JSONValue, pointer: String) -> JSONValue {
      switch value {
      case .object(var object):
        for key in object.keys {
          if schemaLocations.contains(pointer), key == "$schema",
            object[key]?.string == "https://spec.openapis.org/oas/3.1/dialect/base"
          {
            object[key] = .string("https://json-schema.org/draft/2020-12/schema")
          } else if let child = object[key] {
            object[key] = normalize(child, pointer: pointer + "/" + escapePointer(key))
          }
        }
        return .object(object)
      case .array(let array):
        return .array(
          array.enumerated().map { normalize($0.element, pointer: pointer + "/\($0.offset)") })
      default: return value
      }
    }
    return normalize(document.rawValue, pointer: "")
  }
}
