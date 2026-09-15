# Swift OpenAPI Schema Codegen

An **experimental, standalone Swift package** generating selected JSON-only
operations from an offline OpenAPI 3.1 JSON document. It is not a full OpenAI SDK
and does not replace Apple's Swift OpenAPI Generator.

This repository extracts the tested OpenAPI integration from
[swift-json-schema-codegen](https://github.com/ajevans99/swift-json-schema-codegen).
The generic shared nominal-model graph, JSONValue encoding, and schema generation
remain in that upstream dependency; they are not copied into this package.
OpenAPI document import comes from
[swift-openapi-schema](https://github.com/ajevans99/swift-openapi-schema).

## Dependencies and development

Requires **Swift 6.1+**. Supported platforms are macOS 14+, iOS 17+, tvOS 17+,
watchOS 10+, Mac Catalyst 17+, visionOS 1+, and Linux.

The manifest uses released `swift-openapi-schema` **0.2.0+**,
`swift-json-schema` **0.14.0+**, Apple's `swift-openapi-runtime` **1.12.1+**, and
`swift-http-types` **1.5.1+**. The generic `swift-json-schema-codegen` prerequisite
is pinned to an immutable published Git revision in `Package.swift`, not an
unpublished tag or moving branch. It is not yet a released generic-core version.
The bootstrap pin is
[`52e0d18170d10e02925622b86f8f8918a2ef7f8f`](https://github.com/ajevans99/swift-json-schema-codegen/commit/52e0d18170d10e02925622b86f8f8918a2ef7f8f).
`Package.resolved` records the verified dependency versions. No sibling checkout,
local override, or SwiftPM edit mode is required.
SwiftPM may update transitive pins when switching toolchains: CustomDump's
Swift 6.1 and Swift 6.4 manifests use different IssueReporting package identities.
CI permits this normal resolution instead of forcing a lock graph from another
toolchain; the generic core revision and foundation version requirement stay fixed.

```sh
git clone https://github.com/ajevans99/swift-openapi-schema-codegen.git
cd swift-openapi-schema-codegen
swift package resolve
swift test
swift run openapi-json-codegen --help

# Optional release-mode executable (no global installation required):
swift build -c release --product openapi-json-codegen
.build/release/openapi-json-codegen --help
```

The public products retain their original names:

| Product | Purpose |
| --- | --- |
| `OpenAPICodegen` | Offline operation analysis and Swift source generation |
| `OpenAPIJSONRuntime` | JSON request/response helpers using Apple's `ClientTransport` |
| `openapi-json-codegen` | Command-line generator and compatibility reports |

To use the libraries in another Swift package, add this repository as a dependency
pinned to a verified commit (there is **no release of this package yet**):

```swift
.package(
  url: "https://github.com/ajevans99/swift-openapi-schema-codegen.git",
  revision: "<verified-commit-sha>"
)
```

Then add the product to your target:

```swift
.product(name: "OpenAPIJSONRuntime", package: "swift-openapi-schema-codegen")
```

Use `OpenAPICodegen` instead for programmatic generation. See the
[compiled consumer manifest](Tests/OpenAPIClient/Consumer/Package.swift) for the
separate generated-module layout. Its local package-under-test path is only a
test-harness input, not a production dependency.

For coordinated importer development only, an explicit optional override remains:

```sh
OPENAPI_SCHEMA_PATH=/path/to/swift-openapi-schema swift test
```

An empty override is an error. With no override, SwiftPM resolves the released
remote importer. CI and standalone acceptance use no development overrides.

## Generate and execute

Generation requires explicit operation selection and performs **no network I/O**.
Schema/Reference Object resolution is delegated to the importer and generic
schema core, not a second OpenAPI parser.

```sh
swift run openapi-json-codegen api.json \
  --operation listModels --operation retrieveModel \
  --namespace MyAPI --output Generated.swift
```

Add `Generated.swift` to a target depending on `OpenAPIJSONRuntime`. It includes
the schema builder dependency required by generated parsers. Generated code
exposes:

* `MyAPI.Models`: shared nominal models, named root aliases, parsers, encoders,
  and validating `<root>JSON` functions.
* `MyAPI.Operations.<operation>.Input` and `.Output`: typed parameters/bodies
  and status-specific responses, with `descriptor`, `request(_:)`, and
  `decode(_:)` entry points for separate preparation/decoding.
* `MyAPI.Client`: methods accepting the operation input and returning its output.

```swift
let client = try MyAPI.Client(
  serverURL: URL(string: "https://example.test/v1")!,
  transport: transport,
  credentials: credentials
)
let output = try await client.retrieveModel(.init(model: "model-id"))
switch output {
case .status200(let model, let headers):
  // Use the typed model and the original response headers.
  consume(model, headers)
}
```

`transport` is an **actual `OpenAPIRuntime.ClientTransport`** implementation,
using `HTTPTypes.HTTPRequest`/`HTTPResponse` and `HTTPBody`. Existing conforming
transports can be supplied directly. The compiled acceptance consumer uses a
recording mock implementing that same protocol. No separate networking
implementation, live API call, credential storage, automatic retry, middleware
pipeline, or streaming support is included.

Supply the server URL explicitly; importer server metadata is not automatically
chosen or template-expanded. Its base path is passed intact to `ClientTransport`,
along with the operation's relative path, following that protocol's contract.
Parameter values are UTF-8 percent encoded, including slashes in path parameters.

## Request and response guarantees

All generated requests map models to `JSONValue` using the generic shared-model
graph and OrderedJSON serialization, then **parse and validate the resulting
value before sending it**. This catches invalid constructed values, not just
malformed wire responses. There is no synthesized `Codable` or new JSON serializer.

Original JSON keys, optional absence versus explicit null (`T??`), required-nullable
arguments, typed flattened extras, semantic union payloads, and exact string-enum
Unicode scalar identity are preserved. Conflicting extra/declared keys fail,
rather than overwriting a field. The mapper does not reconstruct unknown fields
deliberately discarded by a schema projection. JSONValue/JSONNumberLiteral
payloads retain exact number tokens; existing projected `Int`/`Double` fields
retain those types' representable-value limits rather than promising lexical
number round trips. Nonfinite constructed Double values fail encoding.

Component reuse is based on schema provenance and compatible specialization,
not structural equality or a copy of the model per operation. Reference
refinements can correctly produce different model types.

Schemas such as the pinned OpenAI `Model` specify object properties without
`type: object`. Shared mode preserves this original validity with a nominal
`Model.object(ModelObject)` / `Model.nonObject(JSONValue)` representation.
Valid objects yield typed fields; invalid objects cannot fall through. Allowed
nonobjects remain valid, and constructing `.nonObject` with an object is an
encoding error. It never silently adds an object-only validation constraint.

Responses select **exact status before range before default**. Exact JSON media
types (including declared `application/*+json`) are checked case-insensitively,
ignoring Content-Type parameters. Missing/wrong media, missing JSON bodies,
unexpected bodies for empty responses, and undocumented statuses throw explicit
errors. Response headers remain case-insensitive `HTTPFields`; typed response
header validation is not included.

JSON responses are buffered with a configurable maximum, default
**16 MiB (16 * 1024 * 1024 bytes)**. Set
`maximumResponseBodyBytes` on `JSONClient` or the generated client initializer.
The exact boundary is accepted; over-limit collection fails. Transport errors,
collection errors, schema failures, and cancellation propagate to the caller.

Security alternatives retain OpenAPI OR/AND semantics. A
`JSONCredentialProvider` supplies values by declared scheme name for one
`JSONSecurityAlternative`, or returns `nil` to try another alternative. It receives
required scopes as metadata; it is responsible for selecting credentials with
those scopes. Bearer/basic credentials and header/query API keys are supported.
The runtime supplies the Bearer/Basic prefix (basic values are already base64
encoded), rejects control characters and injection collisions, and fails missing
required credentials before `send`. An empty requirement permits anonymous access.
OAuth2/OpenID Connect token acquisition and scope verification are not implemented.

## Intentional limits and diagnostics

Supported parameter shapes are nonnullable scalars and scalar arrays:
path `simple`, query `form` (exploded or delimited), and non-exploded array
`spaceDelimited`/`pipeDelimited`. Schema refinements are still validated before
encoding. Header/cookie parameters, complex objects, `deepObject`,
`allowReserved`, other style combinations, and nullable parameters are refused.

Every selected body/response must have exactly one JSON media type or be an
explicitly bodyless response. SSE, multipart, binary, mixed JSON/SSE, and multiple
media alternatives remain visible **located generation refusals**; they are not
silently removed from the import catalog.

This first integration supports local JSON Pointer schema references. External
operation schemas, embedded `$id` resources, and anchor/dynamic-anchor references
are conservatively refused here even where the underlying libraries support
more. Callbacks and webhooks remain in the lossless imported document but are
not path operations in the initial catalog.

Legacy `nullable` is an error by default. `--legacy-nullable-annotations-only`
is an explicit compatibility policy that retains it as an inert annotation and
emits a warning; it **never activates OpenAPI 3.0 nullability semantics**.
Vendor extensions and `discriminator` produce located annotation warnings.
Discriminator metadata never overrides oneOf exclusivity, anyOf ordering, or
the original full validation schema.

```sh
# HTTP policy + selected schema-closure annotation diagnostics:
swift run openapi-json-codegen api.json --report

# Also run generic model generation for otherwise eligible operations:
swift run openapi-json-codegen api.json \
  --report --check-models
```

Reports are TSV and end with counts of **diagnostics**, not unsupported operations.
`--check-models` reports the first generic generation failure for each eligible
operation; it does not compile every generated combination. Operations already
refused by HTTP/annotation policy skip this additional generation pass. Importer
envelope/checked-view errors are distinct thrown failures, not compatibility
warnings. Strict structural OpenAPI validation is separately available through
`OpenAPIJSONDocument.validate()`; it is not a proof of embedded-schema semantics
or client representability.

## End-to-end acceptance

See [the pinned corpus and integration harness](Tests/OpenAPIClient/README.md).
The harness generates a separate `GeneratedAPI` module and compiles an external
consumer, proving public initializer/nominal sharing and real mock transport
execution rather than only source snapshots.

```sh
bash Tests/OpenAPIClient/fetch-openai.sh
bash Tests/OpenAPIClient/smoke.sh
```

The fetch step explicitly downloads and checksum-verifies the pinned MIT-licensed
OpenAI corpus and license. Generation itself is offline. The harness preserves
the complete document and emits reports under `.build/`; it does not claim
all-operations SDK support. A previous exhaustive generic-model scan was stopped
and remains **incomplete**.

## License

[MIT](LICENSE), preserving the original Austin Evans copyright. The separately
downloaded OpenAI fixture retains its own upstream MIT license and provenance.
