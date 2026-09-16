import Foundation
import JSONSchemaCodegenCore
import OpenAPISchema
import OrderedJSON

public struct OpenAPICodegenDiagnostic: Sendable, Equatable {
  public enum Severity: String, Sendable {
    case warning
    case error
  }

  public let severity: Severity
  public let operationID: String
  public let pointer: String
  public let message: String

  public init(severity: Severity, operationID: String, pointer: String, message: String) {
    self.severity = severity
    self.operationID = operationID
    self.pointer = pointer
    self.message = message
  }
}

public struct OpenAPICodegenError: Error, Sendable, CustomStringConvertible {
  public let diagnostics: [OpenAPICodegenDiagnostic]

  public var description: String {
    diagnostics.map { "\($0.operationID)#\($0.pointer): \($0.message)" }.joined(separator: "\n")
  }
}

/// Compatibility policy never changes the original JSON Schema validation rules.
public struct OpenAPICodegenOptions: Sendable {
  public enum LegacyNullablePolicy: Sendable {
    case reject
    /// Keep legacy nullable as an inert annotation, with a located warning.
    case annotationOnly
  }

  public var namespace: String
  public var legacyNullable: LegacyNullablePolicy
  public var recursiveObjects: RecursiveObjectStrategy
  public var profile: OpenAPIOperationProfile?

  public init(
    namespace: String = "API", legacyNullable: LegacyNullablePolicy = .reject,
    recursiveObjects: RecursiveObjectStrategy = .valueTypes,
    profile: OpenAPIOperationProfile? = nil
  ) {
    self.namespace = namespace
    self.legacyNullable = legacyNullable
    self.recursiveObjects = recursiveObjects
    self.profile = profile
  }
}

public struct GeneratedOpenAPIClient: Sendable {
  public let source: String
  public let operationNames: [String: String]
  public let diagnostics: [OpenAPICodegenDiagnostic]
}

struct OperationPlan {
  struct Parameter {
    let view: OpenAPIParameterView
    let field: String
    let root: String
    let style: String
    let explode: Bool
  }
  struct Response {
    let view: OpenAPIResponseView
    let root: String?
    let caseName: String
    let mediaType: String?
  }
  let view: OpenAPIOperationView
  let id: String
  let name: String
  var parameters: [Parameter] = []
  var bodyRoot: String?
  var bodyMediaType: String?
  var requestConstraint: JSONValue?
  var isProfiled = false
  var responses: [Response] = []
  var securitySource = "[]"
  var roots: [(name: String, pointer: String)] = []
}

/// Offline operation lowering layered on the lossless OpenAPI importer and generic model core.
public struct OpenAPICodeGenerator: Sendable {
  public let options: OpenAPICodegenOptions

  public init(options: OpenAPICodegenOptions = .init()) {
    self.options = options
  }

  /// Returns located representability diagnostics without removing operations from the catalog.
  public func compatibility(
    of document: OpenAPIJSONDocument, operationIDs: [String]? = nil,
    checkModels: Bool = false
  ) throws -> [OpenAPICodegenDiagnostic] {
    let planned = try plan(document, operationIDs: operationIDs)
    var diagnostics = planned.diagnostics
    if checkModels {
      for operation in planned.operations
      where !planned.diagnostics.contains(where: {
        $0.operationID == operation.id && $0.severity == .error
      }) {
        do {
          _ = try generate(document, operationIDs: [operation.id])
        } catch let error as OpenAPICodegenError {
          diagnostics += error.diagnostics
        }
      }
    }
    return diagnostics
  }

  func plan(
    _ document: OpenAPIJSONDocument, operationIDs: [String]?
  ) throws -> (operations: [OperationPlan], diagnostics: [OpenAPICodegenDiagnostic]) {
    try options.profile?.validate()
    let catalog = try document.operations()
    let ids = catalog.map { $0.operationID ?? $0.method.uppercased() + " " + $0.path }
    let names = SwiftNames.allocate(
      ids,
      reserved: options.profile == nil
        ? SwiftNames.operationReserved
        : SwiftNames.operationReserved.union(["RuntimeComponent", "HTTPResponse"]))
    var diagnostics: [OpenAPICodegenDiagnostic] = []
    var operations: [OperationPlan] = []
    for id in (options.profile?.operations.keys.sorted() ?? []) {
      if !ids.contains(id) {
        diagnostics.append(
          .init(
            severity: .error, operationID: id, pointer: "/operations/" + escapePointer(id),
            message: "Profile operation does not exist in the document."))
      }
    }
    if let selected = operationIDs {
      for id in selected where !ids.contains(id) {
        diagnostics.append(
          .init(
            severity: .error, operationID: id, pointer: "/paths", message: "Operation not found."))
      }
    }
    for (index, view) in catalog.enumerated() {
      let id = ids[index]
      guard operationIDs == nil || operationIDs!.contains(id) else { continue }
      func emit(
        _ pointer: String, _ message: String, severity: OpenAPICodegenDiagnostic.Severity = .error
      ) {
        diagnostics.append(
          .init(severity: severity, operationID: id, pointer: pointer, message: message))
      }
      var result = OperationPlan(view: view, id: id, name: names[index])
      let profile = options.profile?.operations[id]
      result.requestConstraint = profile?.requestConstraint
      result.isProfiled = profile != nil
      var selectedSchemas = view.parameters.compactMap(\.schema)
      for key in (view.source.value.object ?? [:]).keys where key.hasPrefix("x-") {
        emit(
          view.source.location.pointer + "/" + escapePointer(key),
          "Vendor annotation retained without codegen semantics.", severity: .warning)
      }
      if ids.filter({ $0 == id }).count > 1 {
        emit(view.source.location.pointer + "/operationId", "Duplicate operation identifier.")
      }
      if let dialect = document.rawValue.object?["jsonSchemaDialect"]?.string,
        ![
          "https://spec.openapis.org/oas/3.1/dialect/base",
          "https://json-schema.org/draft/2020-12/schema",
        ].contains(dialect)
      {
        emit("/jsonSchemaDialect", "Unsupported schema dialect: \(dialect).")
      }
      if !view.path.hasPrefix("/") || view.path.contains("?") || view.path.contains("#")
        || view.path.hasPrefix("//") || view.path.contains(where: \.isWhitespace)
        || view.path.contains("\\")
      {
        emit(view.pathItem.location.pointer, "Unsupported path template.")
      }
      let fields = SwiftNames.allocate(view.parameters.map(\.name), reserved: ["body"])
      for (parameterIndex, parameter) in view.parameters.enumerated() {
        let pointer = parameter.target.location.pointer
        guard parameter.location == "path" || parameter.location == "query" else {
          emit(
            pointer + "/in", "Only path and query parameters are supported in this JSON milestone.")
          continue
        }
        guard let schema = parameter.schema, parameter.content.isEmpty else {
          emit(pointer, "Parameters must declare a scalar/array schema, not content.")
          continue
        }
        let object = parameter.target.value.object ?? [:]
        let style = object["style"]?.string ?? (parameter.location == "path" ? "simple" : "form")
        let explode = object["explode"]?.boolean ?? (style == "form")
        if object["allowReserved"]?.boolean == true {
          emit(
            pointer + "/allowReserved",
            "allowReserved is not supported; values are percent encoded.")
        }
        if parameter.location == "path" {
          if style != "simple" || !parameter.required {
            emit(pointer, "Path parameters must be required and use simple style.")
          }
          if !view.path.contains("{\(parameter.name)}") {
            emit(pointer + "/name", "Path parameter has no matching template placeholder.")
          }
        } else if !["form", "spaceDelimited", "pipeDelimited"].contains(style)
          || (style != "form" && explode)
        {
          emit(pointer + "/style", "Unsupported query style/explode combination.")
        }
        do {
          let shape = try parameterShape(schema.value, document: document)
          if shape == "unsupported" || (style != "form" && style != "simple" && shape != "array") {
            emit(
              schema.location.pointer,
              "Only nonnullable scalar or scalar-array parameters are supported.")
          }
        } catch {
          emit(schema.location.pointer, "Cannot resolve parameter shape: \(error)")
        }
        let root = "\(result.name)Parameter\(parameterIndex + 1)"
        result.parameters.append(
          .init(
            view: parameter, field: fields[parameterIndex], root: root, style: style,
            explode: explode))
        result.roots.append((root, schema.location.pointer))
      }
      let placeholders = view.path.split(separator: "{").dropFirst().compactMap {
        $0.split(separator: "}", maxSplits: 1).first.map(String.init)
      }
      for placeholder in placeholders
      where !view.parameters.contains(where: {
        $0.location == "path" && $0.name == placeholder
      }) {
        emit(view.source.location.pointer, "Missing path parameter '\(placeholder)'.")
      }
      let expanded = view.parameters.filter { $0.location == "path" }.reduce(view.path) {
        $0.replacingOccurrences(of: "{\($1.name)}", with: "parameter")
      }
      if expanded.contains("{") || expanded.contains("}")
        || expanded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
      {
        emit(view.pathItem.location.pointer, "Malformed or unsafe path template.")
      }
      if let body = view.requestBody {
        if profile != nil && profile?.requestMediaType == nil {
          emit(
            body.target.location.pointer,
            "Profile must explicitly select the request media and constraint.")
        }
        if body.content.isEmpty {
          emit(
            body.target.location.pointer + "/content", "Request bodies require one JSON media type."
          )
        }
        if let media = jsonMedia(
          body.content, selected: profile?.requestMediaType,
          pointer: body.target.location.pointer + "/content", emit: emit
        ), let schema = media.schema {
          result.bodyRoot = "\(result.name)Body"
          result.bodyMediaType = media.mediaType
          result.roots.append((result.bodyRoot!, schema.location.pointer))
          selectedSchemas.append(schema)
        }
      } else if profile?.requestMediaType != nil {
        emit(
          view.source.location.pointer,
          "Profile selects request media for an operation without a request body.")
      }
      for response in view.responses {
        let status = response.status
        guard status == "default" || validStatus(status) else {
          emit(response.source.location.pointer, "Unsupported response status '\(status)'.")
          continue
        }
        let caseName = status == "default" ? "defaultResponse" : "status\(status)"
        if response.content.isEmpty {
          result.responses.append(
            .init(view: response, root: nil, caseName: caseName, mediaType: nil))
        } else if let media = jsonMedia(
          response.content, selected: profile?.responseMediaType,
          pointer: response.target.location.pointer + "/content", emit: emit
        ), let schema = media.schema {
          let root = "\(result.name)Response\(status == "default" ? "Default" : status)"
          result.responses.append(
            .init(view: response, root: root, caseName: caseName, mediaType: media.mediaType))
          result.roots.append((root, schema.location.pointer))
          selectedSchemas.append(schema)
        }
        if response.target.value.object?["headers"]?.object?.isEmpty == false {
          emit(
            response.target.location.pointer + "/headers",
            "Response headers are retained as HTTPFields, not typed or schema-validated.",
            severity: .warning)
        }
        if response.target.value.object?["links"]?.object?.isEmpty == false {
          emit(
            response.target.location.pointer + "/links", "Response links are metadata only.",
            severity: .warning)
        }
      }
      if result.responses.isEmpty {
        emit(view.source.location.pointer + "/responses", "No supported responses.")
      }
      if profile != nil && view.responses.allSatisfy({ $0.content.isEmpty }) {
        emit(
          view.source.location.pointer + "/responses",
          "Profile selects response media for an operation with only bodyless responses.")
      }
      result.securitySource = security(view.security, document: document, emit: emit)
      var visited = Set<String>()
      let schemas =
        profile == nil
        ? view.parameters.compactMap(\.schema)
          + (view.requestBody?.content.compactMap(\.schema) ?? [])
          + view.responses.flatMap { $0.content.compactMap(\.schema) }
        : selectedSchemas
      for schema in schemas {
        if schema.location.sourceURI != document.sourceURI {
          emit(
            schema.location.pointer,
            "External operation schemas are retained by the importer but are not supported by this codegen integration."
          )
          continue
        }
        do {
          try inspectSchema(
            schema, document: document, visited: &visited, emit: emit)
        } catch {
          emit(schema.location.pointer, "Schema closure cannot be inspected: \(error)")
        }
      }
      if !view.servers.isEmpty {
        emit(
          view.servers[0].location.pointer,
          "Server metadata is retained by the importer; supply an explicit serverURL at runtime.",
          severity: .warning)
      }
      operations.append(result)
    }
    return (operations, diagnostics)
  }

  private func validStatus(_ status: String) -> Bool {
    if status.count == 3, let code = Int(status), (100...599).contains(code) { return true }
    return ["1XX", "2XX", "3XX", "4XX", "5XX"].contains(status)
  }

  private func jsonMedia(
    _ media: [OpenAPIMediaTypeView],
    selected: String? = nil, pointer: String,
    emit: (String, String, OpenAPICodegenDiagnostic.Severity) -> Void
  ) -> OpenAPIMediaTypeView? {
    if let selected {
      guard let choice = media.first(where: { $0.mediaType == selected }) else {
        emit(pointer, "Profile selects undeclared media type '\(selected)'.", .error)
        return nil
      }
      for value in media where value.mediaType != selected {
        emit(
          value.source.location.pointer,
          "Excluded from this explicit JSON client profile; the original declaration is unchanged.",
          .warning)
      }
      return jsonMedia([choice], pointer: pointer, emit: emit)
    }
    for value in media {
      if !isJSONMediaType(value.mediaType) {
        emit(
          value.source.location.pointer,
          "Unsupported content type '\(value.mediaType)' (JSON only).", .error)
      }
      if value.schema == nil {
        emit(value.source.location.pointer, "JSON media types require a schema.", .error)
      }
      if value.source.value.object?["encoding"] != nil {
        emit(
          value.source.location.pointer + "/encoding", "Media encoding objects are not supported.",
          .error)
      }
    }
    guard media.count == 1 else {
      if let first = media.first {
        emit(
          first.source.location.pointer, "Select exactly one JSON media type per body/response.",
          .error)
      }
      return nil
    }
    return media.first
  }

  private func parameterShape(
    _ value: JSONValue, document: OpenAPIJSONDocument, visited: Set<String> = []
  ) throws -> String {
    guard let object = value.object else { return "unsupported" }
    if let ref = object["$ref"]?.string {
      guard !visited.contains(ref), let pointer = localPointer(ref) else { return "unsupported" }
      return try parameterShape(
        document.value(at: pointer).value, document: document, visited: visited.union([ref]))
    }
    guard let type = object["type"]?.string else {
      if let values = object["enum"]?.array, !values.isEmpty,
        values.allSatisfy({ $0.string != nil || $0.numberLiteral != nil || $0.boolean != nil })
      {
        return "scalar"
      }
      return "unsupported"
    }
    if ["string", "integer", "number", "boolean"].contains(type) { return "scalar" }
    if type == "array", let item = object["items"],
      try parameterShape(item, document: document, visited: visited) == "scalar"
    {
      return "array"
    }
    return "unsupported"
  }

  private func inspectSchema(
    _ schema: OpenAPILocatedValue, document: OpenAPIJSONDocument, visited: inout Set<String>,
    emit: (String, String, OpenAPICodegenDiagnostic.Severity) -> Void
  ) throws {
    let pointer = schema.location.pointer
    guard visited.insert(pointer).inserted, let object = schema.value.object else { return }
    if object["nullable"] != nil {
      emit(
        pointer + "/nullable",
        options.legacyNullable == .reject
          ? "Legacy nullable is not JSON Schema 2020-12. Choose annotationOnly explicitly to retain it without activating nullability."
          : "Legacy nullable retained as an inert annotation; it does not permit null.",
        options.legacyNullable == .reject ? .error : .warning)
    }
    for key in object.keys where key.hasPrefix("x-") {
      emit(
        pointer + "/" + escapePointer(key), "Vendor annotation retained without codegen semantics.",
        .warning)
    }
    if object["discriminator"] != nil {
      emit(
        pointer + "/discriminator",
        "Discriminator retained as metadata; oneOf/anyOf validation is unchanged.", .warning)
    }
    for keyword in ["$recursiveAnchor", "$recursiveRef"] where object[keyword] != nil {
      emit(
        pointer + "/" + keyword,
        "Legacy \(keyword) is retained unchanged and has no recursion semantics in JSON Schema 2020-12. A branch containing only legacy keywords is unconstrained; oneOf can reject values matching another branch. This does not enable 2019-09 or repair recursive filters.",
        .warning)
    }
    if object["format"]?.string == "binary" {
      emit(
        pointer + "/format", "Binary schemas are not supported in this JSON-only milestone.", .error
      )
    }
    if object["$id"] != nil {
      emit(
        pointer + "/$id",
        "Embedded schema resources are not supported by this local-pointer operation integration.",
        .error)
    }
    for keyword in ["$ref", "$dynamicRef"] {
      if let ref = object[keyword]?.string {
        if let target = localPointer(ref) {
          try inspectSchema(
            document.value(at: target), document: document, visited: &visited, emit: emit)
        } else {
          emit(
            pointer + "/" + keyword,
            "Only local JSON Pointer schema references are supported by this integration.", .error)
        }
      }
    }
    for keyword in ["properties", "patternProperties", "$defs", "dependentSchemas"] {
      for key in (object[keyword]?.object ?? [:]).keys {
        try inspectSchema(
          document.value(at: pointer + "/" + keyword + "/" + escapePointer(key)),
          document: document, visited: &visited, emit: emit)
      }
    }
    for keyword in [
      "items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "contains",
      "not", "if", "then", "else", "propertyNames", "contentSchema",
    ] where object[keyword] != nil {
      try inspectSchema(
        document.value(at: pointer + "/" + keyword), document: document, visited: &visited,
        emit: emit)
    }
    for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
      for index in (object[keyword]?.array ?? []).indices {
        try inspectSchema(
          document.value(at: pointer + "/" + keyword + "/\(index)"),
          document: document, visited: &visited, emit: emit)
      }
    }
  }

  private func security(
    _ requirements: [OpenAPILocatedValue], document: OpenAPIJSONDocument,
    emit: (String, String, OpenAPICodegenDiagnostic.Severity) -> Void
  ) -> String {
    var alternatives: [String] = []
    for requirement in requirements {
      var schemes: [String] = []
      for (name, scopes) in requirement.value.object ?? [:] {
        let pointer = "/components/securitySchemes/" + escapePointer(name)
        do {
          let target = try document.resolveReferenceObject(document.value(at: pointer))
          let object = target.value.object ?? [:]
          let placement: String
          switch object["type"]?.string {
          case "http":
            switch object["scheme"]?.string?.lowercased() {
            case "bearer": placement = ".bearer"
            case "basic": placement = ".basic"
            default:
              emit(target.location.pointer, "Unsupported HTTP security scheme.", .error)
              continue
            }
          case "oauth2", "openIdConnect": placement = ".bearer"
          case "apiKey":
            guard let key = object["name"]?.string, let location = object["in"]?.string,
              ["header", "query"].contains(location)
            else {
              emit(target.location.pointer, "Only header/query API keys are supported.", .error)
              continue
            }
            placement = ".\(location)(\(literal(key)))"
          default:
            emit(target.location.pointer, "Unsupported security scheme.", .error)
            continue
          }
          let scopeStrings = (scopes.array ?? []).compactMap(\.string).map(literal).joined(
            separator: ", ")
          schemes.append(
            "JSONSecurityScheme(name: \(literal(name)), placement: \(placement), scopes: [\(scopeStrings)])"
          )
        } catch {
          emit(
            requirement.location.pointer, "Cannot resolve security scheme '\(name)': \(error)",
            .error)
        }
      }
      alternatives.append("JSONSecurityAlternative(schemes: [\(schemes.joined(separator: ", "))])")
    }
    return "[" + alternatives.joined(separator: ", ") + "]"
  }
}

func localPointer(_ reference: String) -> String? {
  guard reference.hasPrefix("#"),
    let pointer = String(reference.dropFirst()).removingPercentEncoding,
    pointer.isEmpty || pointer.hasPrefix("/")
  else { return nil }
  return pointer
}

func escapePointer(_ value: String) -> String {
  value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

/// Scalar escapes avoid Swift interpolation and preserve canonically distinct JSON strings.
func literal(_ value: String) -> String {
  "\""
    + value.unicodeScalars.map { scalar in
      switch scalar.value {
      case 34: return "\\\""
      case 92: return "\\\\"
      case 32...126: return String(scalar)
      default: return "\\u{\(String(scalar.value, radix: 16))}"
      }
    }.joined() + "\""
}

enum SwiftNames {
  static let operationReserved: Set<String> = [
    "Models", "Operations", "Client", "Type", "Protocol", "Input", "Output",
    "JSONParameter", "JSONOperation", "JSONResponse", "HTTPFields", "JSONValue",
    "runtime", "init", "deinit", "subscript",
  ]

  static func allocate(_ values: [String], reserved: Set<String> = []) -> [String] {
    var used = reserved
    return values.map { value in
      let words = value.split(whereSeparator: { !$0.isASCII || !$0.isLetter && !$0.isNumber })
      var base = words.enumerated().map { index, word in
        index == 0 ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
      }.joined()
      if base.isEmpty { base = "operation" }
      if base.first?.isNumber == true { base = "_" + base }
      if base == "self" || base == "Self" { base = "_" + base }
      var result = base
      var suffix = 2
      while !used.insert(result).inserted {
        result = "\(base)_\(suffix)"
        suffix += 1
      }
      return result
    }
  }
}
