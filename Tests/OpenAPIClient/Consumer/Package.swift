// swift-tools-version: 6.1
import Foundation
import PackageDescription

guard let codegen = ProcessInfo.processInfo.environment["OPENAPI_CODEGEN_PATH"],
  !codegen.isEmpty
else {
  fatalError("Set OPENAPI_CODEGEN_PATH to this repository's root directory.")
}

let package = Package(
  name: "OpenAPIClientConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "swift-openapi-schema-codegen", path: codegen)
  ],
  targets: [
    .target(
      name: "GeneratedAPI",
      dependencies: [
        .product(name: "OpenAPIJSONRuntime", package: "swift-openapi-schema-codegen")
      ]),
    .executableTarget(name: "Consumer", dependencies: ["GeneratedAPI"]),
  ]
)
