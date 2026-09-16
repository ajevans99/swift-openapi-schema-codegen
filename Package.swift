// swift-tools-version: 6.1
import Foundation
import PackageDescription

let genericCore: Package.Dependency
if let path = ProcessInfo.processInfo.environment["JSON_SCHEMA_CODEGEN_PATH"] {
  precondition(!path.isEmpty, "JSON_SCHEMA_CODEGEN_PATH must name a generic codegen checkout.")
  genericCore = .package(name: "swift-json-schema-codegen", path: path)
} else {
  genericCore = .package(
    url: "https://github.com/ajevans99/swift-json-schema-codegen.git",
    from: "0.3.0")
}

let foundation: Package.Dependency
if let path = ProcessInfo.processInfo.environment["OPENAPI_SCHEMA_PATH"] {
  precondition(!path.isEmpty, "OPENAPI_SCHEMA_PATH must name an importer checkout.")
  foundation = .package(name: "swift-openapi-schema", path: path)
} else {
  foundation = .package(
    url: "https://github.com/ajevans99/swift-openapi-schema.git",
    from: "0.2.0")
}

let schemaRuntime: Package.Dependency
if let path = ProcessInfo.processInfo.environment["JSON_SCHEMA_RUNTIME_PATH"] {
  precondition(!path.isEmpty, "JSON_SCHEMA_RUNTIME_PATH must name a JSON Schema runtime checkout.")
  schemaRuntime = .package(name: "swift-json-schema", path: path)
} else {
  schemaRuntime = .package(
    url: "https://github.com/ajevans99/swift-json-schema.git",
    from: "0.14.1")
}

let package = Package(
  name: "swift-openapi-schema-codegen",
  platforms: [
    .macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10),
    .macCatalyst(.v17), .visionOS(.v1),
  ],
  products: [
    .library(name: "OpenAPICodegen", targets: ["OpenAPICodegen"]),
    .library(name: "OpenAPIJSONRuntime", targets: ["OpenAPIJSONRuntime"]),
    .executable(name: "openapi-json-codegen", targets: ["OpenAPICodegenCLI"]),
  ],
  dependencies: [
    genericCore,
    foundation,
    schemaRuntime,
    .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.1"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.5.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
  ],
  targets: [
    .target(
      name: "OpenAPIJSONRuntime",
      dependencies: [
        .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]),
    .target(
      name: "OpenAPICodegen",
      dependencies: [
        .product(name: "JSONSchemaCodegenCore", package: "swift-json-schema-codegen"),
        .product(name: "OpenAPISchema", package: "swift-openapi-schema"),
      ]),
    .executableTarget(
      name: "OpenAPICodegenCLI",
      dependencies: [
        "OpenAPICodegen",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "OpenAPIJSONRuntimeTests",
      dependencies: [
        "OpenAPIJSONRuntime",
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]),
    .testTarget(
      name: "OpenAPICodegenTests",
      dependencies: [
        "OpenAPICodegen",
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]),
  ]
)
