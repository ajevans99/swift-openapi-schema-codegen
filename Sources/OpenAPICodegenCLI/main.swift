import ArgumentParser
import Foundation
import OpenAPICodegen
import OpenAPISchema

@main
struct OpenAPICodegenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "openapi-json-codegen",
    abstract: "Generate JSON-only operations from an offline OpenAPI 3.1 JSON document.")

  @Argument(help: "Path to a pinned local OpenAPI JSON file.")
  var input: String

  @Option(name: .long, help: "Operation ID to include. Repeat to select multiple operations.")
  var operation: [String] = []

  @Flag(help: "Print located compatibility diagnostics without emitting Swift.")
  var report = false

  @Flag(
    help:
      "With --report, also check model generation for operations without HTTP/annotation blockers.")
  var checkModels = false

  @Flag(help: "Explicitly retain legacy nullable as an inert annotation (never enables null).")
  var legacyNullableAnnotationsOnly = false

  @Option(help: "Generated Swift namespace.")
  var namespace = "API"

  @Option(help: "Generated Swift destination. Required unless --report is selected.")
  var output: String?

  mutating func run() throws {
    let url = URL(fileURLWithPath: input)
    let document = try OpenAPIJSONDocument(data: Data(contentsOf: url), sourceURI: url)
    let generator = OpenAPICodeGenerator(
      options: .init(
        namespace: namespace,
        legacyNullable: legacyNullableAnnotationsOnly ? .annotationOnly : .reject))
    if !report {
      guard let output else { throw ValidationError("Specify --output for generated Swift.") }
      let generated = try generator.generate(document, operationIDs: operation)
      for diagnostic in generated.diagnostics {
        FileHandle.standardError.write(
          Data(
            "\(diagnostic.severity.rawValue)\t\(diagnostic.operationID)\t#\(diagnostic.pointer)\t\(diagnostic.message)\n"
              .utf8))
      }
      try generated.source.write(toFile: output, atomically: true, encoding: .utf8)
      return
    }
    var diagnostics = try generator.compatibility(
      of: document, operationIDs: operation.isEmpty ? nil : operation)
    if checkModels {
      for view in try document.operations() {
        let id = view.operationID ?? view.method.uppercased() + " " + view.path
        guard operation.isEmpty || operation.contains(id),
          !diagnostics.contains(where: { $0.operationID == id && $0.severity == .error })
        else { continue }
        FileHandle.standardError.write(
          Data("Checking models: \(id)#\(view.source.location.pointer)\n".utf8))
        do {
          _ = try generator.generate(document, operationIDs: [id])
        } catch let error as OpenAPICodegenError {
          diagnostics += error.diagnostics
        }
      }
    }
    for diagnostic in diagnostics {
      print(
        "\(diagnostic.severity.rawValue)\t\(diagnostic.operationID)\t#\(diagnostic.pointer)\t\(diagnostic.message)"
      )
    }
    let errors = diagnostics.filter { $0.severity == .error }
    print(
      "operations=\(try document.operations().count) errors=\(errors.count) warnings=\(diagnostics.count - errors.count)"
    )
  }
}
