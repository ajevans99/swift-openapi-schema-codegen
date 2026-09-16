import CustomDump
import OpenAPICodegen
import OpenAPISchema
import OrderedJSON
import Testing

private let mediaDocument = """
  {"openapi":"3.1.0","info":{"title":"Profile","version":"1"},"paths":{
    "/events":{"post":{"operationId":"events","requestBody":{"required":true,"content":{
      "application/json":{"schema":{"type":"object","required":["message"],"properties":{
        "message":{"type":"string","minLength":1},"stream":{"type":"boolean"}}}}
    }},"responses":{"200":{"description":"OK","content":{
      "application/json":{"schema":{"type":"object","properties":{"reply":{"type":"string"}}}},
      "text/event-stream":{"schema":{"type":"string","format":"binary"}}
    }}}}}
  }}
  """

private func profile(
  id: String = "events", media: String = "application/json",
  constraint: String = #"{"properties":{"stream":{"const":false}}}"#
) throws -> OpenAPIOperationProfile {
  try OpenAPIOperationProfile(
    source: """
      {"version":1,"operations":{"\(id)":{
        "requestMediaType":"application/json","responseMediaType":"\(media)",
        "requestConstraint":\(constraint)
      }}}
      """)
}

@Test func profileNarrowingIsExplicitAndPreservesDocument() throws {
  let document = try OpenAPIJSONDocument(rawValue: .parse(mediaDocument))
  let original = document.rawValue
  let strict = try OpenAPICodeGenerator().compatibility(of: document)
  #expect(strict.contains { $0.severity == .error && $0.pointer.hasSuffix("text~1event-stream") })
  let generator = OpenAPICodeGenerator(options: .init(profile: try profile()))
  let diagnostics = try generator.compatibility(of: document)
  #expect(diagnostics.allSatisfy { $0.severity == .warning })
  #expect(diagnostics.contains { $0.pointer.hasSuffix("text~1event-stream") })
  let generated = try generator.generate(document, operationIDs: ["events"])
  #expect(generated.source.contains("RuntimeComponent(rawSchema:"))
  #expect(generated.source.contains(#"\"stream\":{\"const\":false}"#))
  #expect(generated.source.contains("minLength"))
  expectNoDifference(document.rawValue, original)
  expectNoDifference(try OpenAPICodeGenerator().compatibility(of: document), strict)
}

@Test func profileRejectsUnknownOperationsAndMedia() throws {
  let document = try OpenAPIJSONDocument(rawValue: .parse(mediaDocument))
  for value in [try profile(id: "missing"), try profile(media: "application/problem+json")] {
    #expect(throws: OpenAPICodegenError.self) {
      try OpenAPICodeGenerator(options: .init(profile: value)).generate(
        document, operationIDs: ["events"])
    }
  }
}

@Test func profileRejectsInvalidConfigurationAndConstraints() throws {
  for source in [
    #"{"version":2,"operations":{}}"#,
    #"{"version":1,"operations":{},"unknown":true}"#,
    #"{"version":1,"operations":{"events":{"responseMediaType":"application/json","typo":true}}}"#,
    #"{"version":1,"operations":{"events":{"responseMediaType":"text/event-stream"}}}"#,
    #"{"version":1,"operations":{"events":{"responseMediaType":"application/*+json"}}}"#,
    #"{"version":1,"operations":{"events":{"responseMediaType":"application/json","requestMediaType":"application/json"}}}"#,
    #"{"version":1,"operations":{"events":{"responseMediaType":"application/json","requestConstraint":false}}}"#,
  ] {
    #expect(throws: OpenAPICodegenError.self) { try OpenAPIOperationProfile(source: source) }
  }
  for constraint in [
    "null", "1", #"{"properties":[]}"#, #"{"properties":{"stream":null}}"#,
    #"{"properties":{"stream":{"constant":false}}}"#, #"{"$ref":"other.json"}"#,
  ] {
    #expect(throws: OpenAPICodegenError.self) { try profile(constraint: constraint) }
  }
}

@Test func programmaticProfilesHaveTheSameChecks() throws {
  let document = try OpenAPIJSONDocument(rawValue: .parse(mediaDocument))
  let profile = OpenAPIOperationProfile(operations: [
    "events": .init(
      requestMediaType: "application/json", responseMediaType: "application/json",
      requestConstraint: .object(["properties": .null]))
  ])
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator(options: .init(profile: profile)).compatibility(of: document)
  }
}

@Test func profileConstraintDataIsNotTreatedAsSchema() throws {
  _ = try profile(constraint: #"{"const":{"properties":[],"$ref":"literal","unknown":true}}"#)
}

@Test func profilePreservationPolicyIsExplicitAndBoolean() throws {
  let enabled = try OpenAPIOperationProfile(
    source: """
      {"version":1,"preserveUnknownFields":true,
       "operations":{"events":{"responseMediaType":"application/json"}}}
      """)
  expectNoDifference(enabled.preserveUnknownFields, true)
  expectNoDifference(try profile().preserveUnknownFields, false)
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPIOperationProfile(
      source: """
        {"version":1,"preserveUnknownFields":"true",
         "operations":{"events":{"responseMediaType":"application/json"}}}
        """)
  }
}

@Test func preservationGeneratesStorageWithReleasedCore() throws {
  let document = try OpenAPIJSONDocument(rawValue: .parse(mediaDocument))
  let preserving = OpenAPIOperationProfile(
    operations: try profile().operations, preserveUnknownFields: true)
  let result = try OpenAPICodeGenerator(options: .init(profile: preserving))
    .generate(document, operationIDs: ["events"])
  #expect(result.source.contains("unmodeledProperties"))
  let discarding = try OpenAPICodeGenerator(options: .init(profile: try profile()))
    .generate(document, operationIDs: ["events"])
  #expect(!discarding.source.contains("unmodeledProperties"))
}

@Test func selectedMediaKeepsSchemaRefusals() throws {
  let source = mediaDocument.replacingOccurrences(
    of: #""reply":{"type":"string"}"#,
    with: #""reply":{"type":"string","format":"binary"}"#)
  let document = try OpenAPIJSONDocument(rawValue: .parse(source))
  let diagnostics = try OpenAPICodeGenerator(options: .init(profile: try profile()))
    .compatibility(of: document)
  #expect(
    diagnostics.contains {
      $0.severity == .error
        && $0.pointer
          == "/paths/~1events/post/responses/200/content/application~1json/schema/properties/reply/format"
    })
}

@Test func profileSelectsRequestMediaWithoutInspectingExcludedSchemas() throws {
  let source = mediaDocument.replacingOccurrences(
    of: #""required":true,"content":{"#,
    with:
      #""required":true,"content":{"multipart/form-data":{"schema":{"type":"string","format":"binary"}},"#
  )
  let document = try OpenAPIJSONDocument(rawValue: .parse(source))
  let strict = try OpenAPICodeGenerator().compatibility(of: document)
  #expect(
    strict.contains {
      $0.severity == .error
        && $0.pointer == "/paths/~1events/post/requestBody/content/multipart~1form-data"
    })
  let result = try OpenAPICodeGenerator(options: .init(profile: try profile()))
    .generate(document, operationIDs: ["events"])
  #expect(result.diagnostics.allSatisfy { $0.severity == .warning })
  #expect(
    result.diagnostics.contains {
      $0.pointer == "/paths/~1events/post/requestBody/content/multipart~1form-data"
    })
}

@Test func profilesSelectExactDeclaredJSONSuffixMedia() throws {
  let media = "application/vnd.example+json"
  let source = mediaDocument.replacingOccurrences(of: "application/json", with: media)
  let document = try OpenAPIJSONDocument(rawValue: .parse(source))
  let selected = OpenAPIOperationProfile(operations: [
    "events": .init(
      requestMediaType: media, responseMediaType: media, requestConstraint: .boolean(true))
  ])
  let result = try OpenAPICodeGenerator(options: .init(profile: selected))
    .generate(document, operationIDs: ["events"])
  #expect(result.diagnostics.allSatisfy { $0.severity == .warning })
  #expect(result.source.contains(#"contentType: "application/vnd.example+json""#))
  #expect(result.source.contains(#"mediaTypes: ["application/vnd.example+json"]"#))
}

@Test func profileCannotSelectMissingRequestOrResponseMedia() throws {
  let source = try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Empty","version":"1"},"paths":{
        "/events":{"post":{"operationId":"events","responses":{"204":{"description":"OK"}}}}
      }}
      """))
  let diagnostics = try OpenAPICodeGenerator(options: .init(profile: try profile()))
    .compatibility(of: source)
  #expect(diagnostics.contains { $0.message.contains("without a request body") })
  #expect(diagnostics.contains { $0.message.contains("only bodyless responses") })
}

@Test func legacyRecursionWarningsAreLocatedAndDoNotInspectData() throws {
  let value = try JSONValue.parse(
    """
    {"openapi":"3.1.0","info":{"title":"Legacy keys","version":"1"},"paths":{
      "/test":{"get":{"operationId":"test","responses":{"200":{"description":"OK","content":{
        "application/json":{"schema":{"$ref":"#/components/schemas/Filter"}}
      }}}}}
    },"components":{"schemas":{"Filter":{
      "$recursiveAnchor":true,
      "oneOf":[{"type":"string"},{"$recursiveRef":"#"}],
      "properties":{"$recursiveRef":{"type":"string"}},
      "default":{"$recursiveRef":"literal"},
      "examples":[{"$recursiveAnchor":true}]
    }}}}
    """)
  let document = try OpenAPIJSONDocument(rawValue: value)
  let diagnostics = try OpenAPICodeGenerator().compatibility(of: document)
  let warnings = diagnostics.filter { $0.message.hasPrefix("Legacy $recursive") }
  expectNoDifference(
    warnings.map(\.pointer).sorted(),
    [
      "/components/schemas/Filter/$recursiveAnchor",
      "/components/schemas/Filter/oneOf/1/$recursiveRef",
    ])
  #expect(warnings.allSatisfy { $0.severity == .warning && $0.message.contains("oneOf") })
  expectNoDifference(document.rawValue, value)
}

@Test func profilesComposeWithOperationSelectionAndModelReports() throws {
  let source = mediaDocument.replacingOccurrences(
    of: #""paths":{"#,
    with:
      #""paths":{"/other":{"get":{"operationId":"other","responses":{"204":{"description":"OK"}}}},"#
  )
  let document = try OpenAPIJSONDocument(rawValue: .parse(source))
  let generator = OpenAPICodeGenerator(options: .init(profile: try profile()))
  #expect(
    try generator.compatibility(of: document, checkModels: true).allSatisfy {
      $0.severity == .warning
    })
  expectNoDifference(
    try generator.generate(document, operationIDs: ["other"]).operationNames,
    ["other": "other"])
}

@Test func profileDiagnosticsLocateEscapedConstraintKeys() throws {
  do {
    _ = try profile(constraint: #"{"properties":{"a/b~c":{"invalid":false}}}"#)
    Issue.record("Invalid constraint was accepted.")
  } catch let error as OpenAPICodegenError {
    expectNoDifference(
      error.diagnostics.first?.pointer,
      "/operations/events/requestConstraint/properties/a~1b~0c/invalid")
  }
}

@Test func profileHelperNamesDoNotChangeDefaultOperationNames() throws {
  let plain = try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Naming","version":"1"},"paths":{
        "/test":{"get":{"operationId":"RuntimeComponent","responses":{"204":{"description":"OK"}}}}
      }}
      """))
  expectNoDifference(
    try OpenAPICodeGenerator().generate(plain, operationIDs: ["RuntimeComponent"])
      .operationNames["RuntimeComponent"],
    "RuntimeComponent")
  let source = mediaDocument.replacingOccurrences(of: "events", with: "RuntimeComponent")
  let document = try OpenAPIJSONDocument(rawValue: .parse(source))
  let generator = OpenAPICodeGenerator(options: .init(profile: try profile(id: "RuntimeComponent")))
  let generated = try generator.generate(document, operationIDs: ["RuntimeComponent"])
  expectNoDifference(generated.operationNames["RuntimeComponent"], "RuntimeComponent_2")
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator(
      options: .init(namespace: "RuntimeComponent", profile: try profile(id: "RuntimeComponent"))
    ).generate(document, operationIDs: ["RuntimeComponent"])
  }
}
