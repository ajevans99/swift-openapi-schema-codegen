import OrderedJSON

/// An explicit client subset, separate from the original OpenAPI document.
public struct OpenAPIOperationProfile: Sendable {
  public struct Operation: Sendable {
    public let requestMediaType: String?
    public let responseMediaType: String
    public let requestConstraint: JSONValue?

    public init(
      requestMediaType: String? = nil, responseMediaType: String,
      requestConstraint: JSONValue? = nil
    ) {
      self.requestMediaType = requestMediaType
      self.responseMediaType = responseMediaType
      self.requestConstraint = requestConstraint
    }
  }

  public let operations: [String: Operation]
  public let preserveUnknownFields: Bool

  public init(operations: [String: Operation], preserveUnknownFields: Bool = false) {
    self.operations = operations
    self.preserveUnknownFields = preserveUnknownFields
  }

  /// Version 1 constraints support boolean schemas, `properties`, and `const`.
  /// Unknown configuration and constraint keywords are errors, never annotations.
  public init(source: String) throws {
    let value = try JSONValue.parse(source)
    guard let object = value.object else {
      throw Self.failure("", "", "Expected a profile object.")
    }
    try Self.checkKeys(
      value, allowed: ["version", "operations", "preserveUnknownFields"], operation: "", pointer: ""
    )
    guard object["version"] == .integer(1) else {
      throw Self.failure("", "/version", "Expected profile version 1.")
    }
    if let preserve = object["preserveUnknownFields"], preserve.boolean == nil {
      throw Self.failure("", "/preserveUnknownFields", "Expected a boolean preservation policy.")
    }
    self.preserveUnknownFields = object["preserveUnknownFields"]?.boolean ?? false
    guard let entries = object["operations"]?.object, !entries.isEmpty else {
      throw Self.failure("", "/operations", "Expected a nonempty operation profile map.")
    }
    var operations: [String: Operation] = [:]
    for (id, entry) in entries {
      let pointer = "/operations/" + escapePointer(id)
      guard let fields = entry.object else {
        throw Self.failure(id, pointer, "Expected an operation profile object.")
      }
      try Self.checkKeys(
        entry, allowed: ["requestMediaType", "responseMediaType", "requestConstraint"],
        operation: id, pointer: pointer)
      guard let response = fields["responseMediaType"]?.string else {
        throw Self.failure(id, pointer + "/responseMediaType", "Expected a JSON media type string.")
      }
      if let request = fields["requestMediaType"], request.string == nil {
        throw Self.failure(id, pointer + "/requestMediaType", "Expected a JSON media type string.")
      }
      operations[id] = Operation(
        requestMediaType: fields["requestMediaType"]?.string, responseMediaType: response,
        requestConstraint: fields["requestConstraint"])
    }
    self.operations = operations
    try validate()
  }

  func validate() throws {
    guard !operations.isEmpty else {
      throw Self.failure("", "/operations", "Expected a nonempty operation profile map.")
    }
    for id in operations.keys.sorted() {
      let operation = operations[id]!
      let pointer = "/operations/" + escapePointer(id)
      for (field, media) in [
        ("requestMediaType", operation.requestMediaType),
        ("responseMediaType", Optional(operation.responseMediaType)),
      ] {
        if let media, !isJSONMediaType(media) {
          throw Self.failure(
            id, pointer + "/" + field, "Profile media must be an exact JSON media type.")
        }
      }
      guard (operation.requestMediaType == nil) == (operation.requestConstraint == nil) else {
        throw Self.failure(
          id, pointer + "/requestConstraint",
          "A selected request media type and an additional request constraint must be supplied together."
        )
      }
      if let constraint = operation.requestConstraint {
        try Self.checkConstraint(constraint, operation: id, pointer: pointer + "/requestConstraint")
      }
    }
  }

  private static func checkConstraint(
    _ value: JSONValue, operation: String, pointer: String
  ) throws {
    if value.boolean != nil { return }
    guard let object = value.object else {
      throw failure(operation, pointer, "Expected a boolean or object request constraint schema.")
    }
    try checkKeys(value, allowed: ["properties", "const"], operation: operation, pointer: pointer)
    if let properties = object["properties"] {
      guard let fields = properties.object else {
        throw failure(operation, pointer + "/properties", "Expected a property-to-schema map.")
      }
      for (key, schema) in fields {
        try checkConstraint(
          schema, operation: operation, pointer: pointer + "/properties/" + escapePointer(key))
      }
    }
  }

  private static func checkKeys(
    _ value: JSONValue, allowed: Set<String>, operation: String, pointer: String
  ) throws {
    for key in (value.object ?? [:]).keys where !allowed.contains(key) {
      throw failure(
        operation, pointer + "/" + escapePointer(key), "Unsupported profile keyword '\(key)'.")
    }
  }

  private static func failure(_ operation: String, _ pointer: String, _ message: String)
    -> OpenAPICodegenError
  {
    OpenAPICodegenError(diagnostics: [
      .init(
        severity: .error, operationID: operation, pointer: pointer, message: "Profile: " + message)
    ])
  }
}

func isJSONMediaType(_ media: String) -> Bool {
  let type = media.lowercased()
  return type == "application/json"
    || (type.hasPrefix("application/") && type.hasSuffix("+json")
      && !type.contains("*") && !type.contains(";") && !type.contains(where: \.isWhitespace))
}
