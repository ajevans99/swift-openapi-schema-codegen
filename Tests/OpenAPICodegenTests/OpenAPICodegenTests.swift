import CustomDump
import OpenAPICodegen
import OpenAPISchema
import OrderedJSON
import Testing

@Test func unsupportedContentIsLocated() throws {
  let document = try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Test","version":"1"},
       "paths":{"/events":{"get":{"operationId":"events","responses":{"200":{
         "description":"OK","content":{"text/event-stream":{"schema":{"type":"string"}}}
       }}}}}}
      """))
  let diagnostics = try OpenAPICodeGenerator().compatibility(of: document)
  #expect(
    diagnostics.contains {
      $0.severity == .error
        && $0.pointer == "/paths/~1events/get/responses/200/content/text~1event-stream"
    })
  expectNoDifference(try document.operations().count, 1)
}

private func document(schema: String = #"{"type":"string"}"#, extra: String = "") throws
  -> OpenAPIJSONDocument
{
  try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Test","version":"1"}\(extra),
       "paths":{"/test":{"get":{"operationId":"test","responses":{"200":{
         "description":"OK","content":{"application/json":{"schema":\(schema)}}
       }}}}}}
      """))
}

@Test func legacyNullableRequiresExplicitPolicy() throws {
  let source = try document(schema: #"{"type":"string","nullable":true,"x-custom":true}"#)
  let strict = try OpenAPICodeGenerator().compatibility(of: source)
  #expect(strict.contains { $0.severity == .error && $0.pointer.hasSuffix("/nullable") })
  let annotations = OpenAPICodeGenerator(options: .init(legacyNullable: .annotationOnly))
  #expect(try annotations.compatibility(of: source).allSatisfy { $0.severity == .warning })
  let generated = try annotations.generate(source, operationIDs: ["test"])
  #expect(generated.source.contains(#""nullable": .boolean(true)"#))
}

@Test func deterministicCollisionSafeOperationNames() throws {
  let source = try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Test","version":"1"},"paths":{
        "/a":{"get":{"operationId":"get-item","responses":{"204":{"description":"OK"}}}},
        "/b":{"get":{"operationId":"get_item","responses":{"204":{"description":"OK"}}}},
        "/c":{"get":{"operationId":"Models","responses":{"204":{"description":"OK"}}}},
        "/d":{"get":{"operationId":"init","responses":{"204":{"description":"OK"}}}}
      }}
      """))
  let generator = OpenAPICodeGenerator()
  let all = try generator.generate(
    source, operationIDs: ["get-item", "get_item", "Models", "init"])
  expectNoDifference(
    all.operationNames,
    ["get-item": "getItem", "get_item": "getItem_2", "Models": "Models_2", "init": "init_2"])
  expectNoDifference(
    try generator.generate(source, operationIDs: ["get_item"]).operationNames["get_item"],
    all.operationNames["get_item"])
  expectNoDifference(
    try generator.generate(source, operationIDs: ["get-item", "get_item", "Models", "init"]).source,
    all.source)
}

@Test func operationSelectionAndInvalidNamespace() throws {
  let source = try document()
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator().generate(source, operationIDs: [])
  }
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator().generate(source, operationIDs: ["missing"])
  }
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator(options: .init(namespace: "Bad}Code")).generate(
      source, operationIDs: ["test"])
  }
}

@Test func unsupportedShapesStayLocated() throws {
  let source = try OpenAPIJSONDocument(
    rawValue: .parse(
      """
      {"openapi":"3.1.0","info":{"title":"Test","version":"1"},"paths":{
        "/test":{"get":{"operationId":"test",
          "parameters":[{"name":"filter","in":"query","style":"deepObject","schema":{"type":"object"}}],
          "responses":{"200":{"description":"OK","content":{"application/json":{"schema":{"type":"string"}}}}}
        }}
      }}
      """))
  let diagnostics = try OpenAPICodeGenerator().compatibility(of: source)
  #expect(diagnostics.contains { $0.pointer == "/paths/~1test/get/parameters/0/style" })
  #expect(diagnostics.contains { $0.pointer == "/paths/~1test/get/parameters/0/schema" })
  #expect(throws: OpenAPICodegenError.self) {
    try OpenAPICodeGenerator().generate(source, operationIDs: ["test"])
  }
  expectNoDifference(try source.operations().count, 1)
}

@Test func normalizationDoesNotRewriteConstPayloads() throws {
  let source = try document(
    schema: """
      {"$schema":"https://spec.openapis.org/oas/3.1/dialect/base",
       "const":{"$schema":"https://spec.openapis.org/oas/3.1/dialect/base"}}
      """)
  let generated = try OpenAPICodeGenerator().generate(source, operationIDs: ["test"])
  #expect(generated.source.contains("https://spec.openapis.org/oas/3.1/dialect/base"))
  #expect(generated.source.contains("https://json-schema.org/draft/2020-12/schema"))
}
