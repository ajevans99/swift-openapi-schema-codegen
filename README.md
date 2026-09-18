# Swift OpenAPI Schema Codegen

Generate a small, typed Swift client from selected operations in an
[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0) JSON document.

This package is useful when you have an OpenAPI document but only want Swift code
for a few JSON endpoints. The generator runs locally and produces:

- Swift models for the selected schemas
- typed operation inputs and responses
- client methods that use Apple's `OpenAPIRuntime.ClientTransport`
- request and response validation against the original schemas

It is an experimental, JSON-focused generator rather than a complete OpenAPI or
OpenAI SDK.

## From OpenAPI to Swift

Given an OpenAPI operation like this:

```json
{
  "openapi": "3.1.0",
  "info": { "title": "Widgets", "version": "1" },
  "paths": {
    "/widgets/{id}": {
      "get": {
        "operationId": "getWidget",
        "parameters": [
          {
            "name": "id",
            "in": "path",
            "required": true,
            "schema": { "type": "string" }
          }
        ],
        "responses": {
          "200": {
            "description": "A widget",
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/Widget" }
              }
            }
          },
          "404": {
            "description": "Not found"
          }
        }
      }
    }
  },
  "components": {
    "schemas": {
      "Widget": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "name": { "type": "string" }
        },
        "required": ["id", "name"],
        "additionalProperties": false
      }
    }
  }
}
```

select the operation and generate a Swift file:

```sh
swift run openapi-json-codegen widgets.json \
  --operation getWidget \
  --namespace WidgetsAPI \
  --output WidgetsAPI.swift
```

The generated file has this general shape:

```swift
enum WidgetsAPI {
  enum Models {
    struct Widget: Sendable {
      let id: String
      let name: String
    }
  }

  enum Operations {
    enum getWidget {
      struct Input: Sendable {
        let id: String
      }

      enum Output: Sendable {
        case status200(body: Models.Widget, headers: HTTPFields)
        case status404(headers: HTTPFields)
      }
    }
  }

  struct Client {
    func getWidget(
      _ input: Operations.getWidget.Input
    ) async throws -> Operations.getWidget.Output
  }
}
```

Add the generated file to a target that depends on `OpenAPIJSONRuntime`, then use
it with any `OpenAPIRuntime.ClientTransport`:

```swift
let client = try WidgetsAPI.Client(
  serverURL: URL(string: "https://example.test/v1")!,
  transport: transport
)

let output = try await client.getWidget(.init(id: "widget-123"))

switch output {
case .status200(let widget, _):
  print(widget.name)
case .status404:
  print("Widget not found")
}
```

The transport performs the actual HTTP request. The generated client handles
path and query encoding, JSON serialization, schema validation, credentials,
and response decoding.

## Try the repository example

The repository includes an authored OpenAPI document with a JSON `POST`
operation:

```sh
swift run openapi-json-codegen \
  Tests/OpenAPIClient/Fixtures/operations.json \
  --operation createWidget \
  --namespace ExampleAPI \
  --output .build/ExampleAPI.swift
```

Open `.build/ExampleAPI.swift` to inspect the generated models, operation input,
status-specific output, and client method.

For a complete executable example using a recording transport instead of a live
server, see
[`Tests/OpenAPIClient/Consumer/main.swift`](Tests/OpenAPIClient/Consumer/main.swift).
It constructs generated request models, executes generated client methods, and
checks the decoded responses.

## Package products

| Product | Purpose |
| --- | --- |
| `openapi-json-codegen` | Command-line source generator and compatibility reporter |
| `OpenAPICodegen` | Programmatic operation analysis and source generation |
| `OpenAPIJSONRuntime` | Request preparation, credentials, transport, and response decoding |

To use the runtime from another Swift package, add this repository at a verified
commit and depend on its product:

```swift
.package(
  url: "https://github.com/ajevans99/swift-openapi-schema-codegen.git",
  revision: "<verified-commit-sha>"
)
```

```swift
.product(
  name: "OpenAPIJSONRuntime",
  package: "swift-openapi-schema-codegen"
)
```

There is no tagged release of this package yet.

## Supported scope

The default generator focuses on selected JSON operations:

- OpenAPI 3.1 JSON documents
- local JSON Pointer schema references
- path and query scalar parameters and scalar arrays
- JSON request and response bodies
- exact, ranged, and default HTTP responses
- bearer, basic, and header/query API-key credentials
- shared nominal models across selected operations

It does not generate streaming, multipart, binary, cookie/header parameter,
external-reference, callback, or webhook clients. Unsupported features produce
located diagnostics instead of being silently omitted:

```sh
swift run openapi-json-codegen api.json --report
```

## JSON operation profiles

Some operations declare several media types even when an application only wants
the JSON variant. An explicit profile can select one declared JSON request and
response media type without modifying the original OpenAPI document:

```json
{
  "version": 1,
  "operations": {
    "createResponse": {
      "requestMediaType": "application/json",
      "responseMediaType": "application/json",
      "requestConstraint": {
        "properties": {
          "stream": { "const": false }
        }
      }
    }
  }
}
```

```sh
swift run openapi-json-codegen api.json \
  --operation createResponse \
  --profile profile.json \
  --namespace ResponsesAPI \
  --output ResponsesAPI.swift
```

Profiles remain JSON-only: they do not add SSE, multipart, or binary transport.
The optional top-level `preserveUnknownFields` setting retains otherwise
unmodeled, schema-allowed fields as `JSONValue` entries. Invalid profile choices
and unsupported constraints are reported as located errors.

See [`Tests/OpenAPIClient/README.md`](Tests/OpenAPIClient/README.md) for the
larger OpenAI corpus, profile acceptance tests, compatibility results, and
reproduction commands.

## Development

Requires Swift 6.1 or later. Supported platforms are macOS 14+, iOS 17+, tvOS
17+, watchOS 10+, Mac Catalyst 17+, visionOS 1+, and Linux.

```sh
swift package resolve
swift test
swift run openapi-json-codegen --help
```

The default manifest uses released remote dependencies:

| Dependency | Minimum version |
| --- | --- |
| `swift-openapi-schema` | 0.2.0 |
| `swift-json-schema-codegen` | 0.3.0 |
| `swift-json-schema` | 0.14.1 |
| Apple's `swift-openapi-runtime` | 1.12.1 |
| `swift-http-types` | 1.5.1 |

For coordinated dependency development, local checkouts can be selected
explicitly:

```sh
OPENAPI_SCHEMA_PATH=/path/to/swift-openapi-schema swift test
JSON_SCHEMA_CODEGEN_PATH=/path/to/swift-json-schema-codegen swift test
JSON_SCHEMA_RUNTIME_PATH=/path/to/swift-json-schema swift test
```

These overrides are optional and are not required to generate profiled clients.

## License

MIT. See [LICENSE](LICENSE).
