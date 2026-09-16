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

The manifest uses released remote dependencies:

| Dependency | Minimum version | Release revision |
| --- | --- | --- |
| `swift-openapi-schema` | 0.2.0 | Importer requirement unchanged |
| `swift-json-schema-codegen` | 0.3.0 | `2937926f4def9885ced02b31bcb0155248c612ef` |
| `swift-json-schema` | 0.14.1 | `1514dd27fd55dbd36eec40c60e40ac8bfe0a22f4` |
| Apple's `swift-openapi-runtime` | 1.12.1 | |
| `swift-http-types` | 1.5.1 | |

These are `from:` version requirements, not branch or bootstrap-revision pins.
`Package.resolved` records the resolved dependency versions. The released generic
core supports opt-in unknown-field preservation, and the released JSON Schema
runtime includes the strict-2020-12 projection parity correction. No conditional
API bridge, sibling checkout, local override, or SwiftPM edit mode is required.
SwiftPM may update transitive pins when switching toolchains: CustomDump's
Swift 6.1 and Swift 6.4 manifests use different IssueReporting package identities.
CI permits this normal resolution instead of forcing a lock graph from another
toolchain.

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
rather than overwriting a field. Under the default discard policy, the mapper
does not reconstruct unknown fields discarded by a schema projection.
JSONValue/JSONNumberLiteral
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

By default, every selected body/response must have exactly one JSON media type or be an
explicitly bodyless response. SSE, multipart, binary, mixed JSON/SSE, and multiple
media alternatives remain visible **located generation refusals**; they are not
silently removed from the import catalog.

### Explicit JSON operation profiles

`--profile profile.json` opts selected operations into a documented JSON-only
client subset. This is not whole-operation support and does not enable SSE,
multipart, or binary transport. The profile chooses an exact declared request
media type and one exact declared response media type for every nonempty response.
Bodyless responses are preserved. Other declarations produce located exclusion
warnings; only the selected JSON schema closure is checked and generated.
The original document is neither stripped nor rewritten.
The optional top-level `preserveUnknownFields` boolean defaults to `false`.
When enabled, all models in the shared namespace retain otherwise-unmodeled,
schema-allowed fields as exact `JSONValue` entries rather than discarding them.
It changes model projection, not schema validity; typed additional properties
retain their existing representation. Preservation works with the default
released dependencies and needs no development override. Omitting the option
retains the strict defaults and existing discard projection.

```json
{
  "version": 1,
  "operations": {
    "createResponse": {
      "requestMediaType": "application/json",
      "responseMediaType": "application/json",
      "requestConstraint": {
        "properties": { "stream": { "const": false } }
      }
    }
  }
}
```

```sh
swift run openapi-json-codegen api.json --operation createResponse \
  --profile profile.json --namespace OpenAIResponsesAPI --output Generated.swift
```

Programmatically use `OpenAPICodegenOptions(profile:)` with
`OpenAPIOperationProfile(source:)`, or construct its operation map directly.
Unknown operations, undeclared/non-JSON media, unknown configuration keys, and
invalid constraints are located errors. Profiles may contain settings for other
known operations; only explicitly selected operations are emitted.

Version 1 intentionally supports a small additional-constraint vocabulary:
boolean schemas, `properties` with recursively supported schemas, and `const`
with any JSON value. Other keywords are rejected, not silently ignored. These
limits apply only to the separate profile, never the original operation schemas.
Request media selection requires an additional request constraint. Operations
without a request body omit both fields.

The generated `request(_:)` first encodes and validates against the original
schema, then independently validates the same JSON against the profile constraint,
before credentials or transport execute. `properties.stream.const: false`
permits omission or `false`, rejects any other supplied value, and adds no
requirement that the property be present. Optional absent request bodies remain
absent. The typed body retains the original schema's API; a constructed `true`
is rejected during request preparation rather than changing the original model
or schema. Model-only encoders and response parsing do not apply request policy.
Profiled clients also validate response headers **before requesting any body
chunks**, so an unexpected open-ended SSE response cannot hang JSON body collection.
The generated `validateResponseHeaders(_:)` helper uses the same
exact-status-before-range-before-default dispatch as decoding. Bodyless and
undocumented statuses retain their existing decoder rules. For a declared JSON
response, invalid/missing Content-Type now takes precedence over empty/oversized
body errors; this early rejection is intentional and opt-in. Original JSON/schema
validation still runs after collection, and cancellation remains an error.
Non-profiled clients retain their existing behavior.

This uses the additive `JSONClient.send(..., validateResponse:)` runtime hook and
`JSONResponse.validateContentType(_:mediaTypes:)`. Profile-generated source
requires the matching `OpenAPIJSONRuntime` from this package.

**Responses acceptance:** `Tests/OpenAPIClient/responses.sh` exercises the pristine,
preserving nonstreaming `createResponse` slice with default released remote
dependencies. Its checks cover typed text/function-tool requests and replies,
complete unknown-field request/response JSONValue round trips, omitted/false
stream acceptance and true/null pre-send rejection, unread SSE refusal, typed
429/503 errors, original schema failures, and transport/cancellation propagation.
Release-based generation and the actual recording consumer pass with all
development overrides unset. Generation emitted 5,248,100 bytes in 21.241 seconds;
the fresh consumer completed in 3.36 seconds with approximately 52 MB maximum RSS.
See the [acceptance report](Tests/OpenAPIClient/README.md) for exact source hashes,
bounded measurements, and reproduction commands. No generated-source patch or
schema rewrite is part of acceptance.

The released runtime preserves strict 2020-12 behavior rather than activating
2019-09 recursion. Located warnings identify both legacy keys.
In the pristine `CompoundFilter`, the legacy-reference-only `oneOf` branch is
unconstrained: a valid comparison item matches both branches and is rejected,
whereas arbitrary strings or malformed nested compound objects can be accepted.
This is not recursive-filter support or a repair of the upstream schema.
Selected-slice acceptance is not downstream SDK migration, whole-operation
support, or a full generic all-operations guarantee.

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
The latest completed default HTTP/annotation report has **323 errors across 63
operations and 6,802 warnings**. Strict `createResponse` has **2 errors and 320
warnings**; its JSON profile has **0 errors and 205 warnings**. These are static
policy counts, not release-based compilation or runtime proof.
`--check-models` reports the first generic generation failure for each eligible
operation; it does not compile every generated combination. Operations already
refused by HTTP/annotation policy skip this additional generation pass. Importer
envelope/checked-view errors are distinct thrown failures, not compatibility
warnings. Strict structural OpenAPI validation is separately available through
`OpenAPIJSONDocument.validate()`; it is not a proof of embedded-schema semantics
or client representability.

## End-to-end acceptance

See [the pinned corpus and integration harnesses](Tests/OpenAPIClient/README.md).
Both harnesses generate a separate `GeneratedAPI` module and compile an external
recording consumer rather than relying only on source snapshots. `smoke.sh`
covers the existing small consumer; `responses.sh` separately covers the actual
preserving, nonstreaming Responses slice.

```sh
# Default remote dependencies; do not set these to empty strings:
unset OPENAPI_SCHEMA_PATH JSON_SCHEMA_CODEGEN_PATH JSON_SCHEMA_RUNTIME_PATH
bash Tests/OpenAPIClient/fetch-openai.sh
bash Tests/OpenAPIClient/smoke.sh
bash Tests/OpenAPIClient/responses.sh
```

The fetch step explicitly downloads and checksum-verifies the pinned MIT-licensed
OpenAI corpus and license. Both acceptance scripts require that prefetch;
generation itself is offline, although SwiftPM may fetch dependencies normally.
The Responses harness additionally requires Python 3 and `ps` for its bounded
process runner. Generation is limited to **120 seconds / 1.5 GiB**; the normal
`--jobs 1` build and direct consumer execution share a **600-second / 3 GiB**
bound. It does not use `swift run Consumer` or special solver flags.

Responses source is written to
`.build/openapi-corpus/OpenAIResponsesAPI-released.swift`, with
`responses-released-*` provenance, dependency graphs, metrics, and reports in
that directory. Its consumer package is under `.build/responses-consumer`.
The ordinary default works with Swift 6.1. On an installed Swift 6.4 toolchain,
`SWIFT_BUILD_SYSTEM=native` optionally selects the native build backend; it is
not required production setup.

The complete document is preserved. Neither harness claims all-operations SDK
support. A previous exhaustive generic-model scan was stopped and remains
**incomplete**.

## Optional coordinated dependency development

These explicit overrides are developer-only conveniences, not prerequisites for
profiles, unknown-field preservation, or actual Responses acceptance:

```sh
OPENAPI_SCHEMA_PATH=/path/to/swift-openapi-schema swift test
JSON_SCHEMA_CODEGEN_PATH=/path/to/swift-json-schema-codegen swift test
JSON_SCHEMA_RUNTIME_PATH=/path/to/swift-json-schema swift test
```

An empty override is an error. With all three unset, SwiftPM uses the released
remote dependencies. An override does not publish or update a release.
`JSON_SCHEMA_RUNTIME_PATH` selects the JSON Schema runtime, including transitive
consumers of that package identity; it is not `OpenAPIJSONRuntime` or the generic
generator override.

For local runtime worktrees only, SwiftPM derives identity from the directory
basename. Use basename `swift-json-schema` to avoid duplicate runtime modules.
If necessary, create an ignored alias under `.build/` pointing to the unchanged
runtime checkout; check an existing alias before reusing it. Record resolved
paths and source/manifest hashes, including untracked source files, and inspect
both generator and consumer graphs with `swift package show-dependencies --format
json`. SwiftPM may warn about the local/remote identity conflict, and a future
version may reject it. This alias caution does not apply to the default remote
release setup.

## License

[MIT](LICENSE), preserving the original Austin Evans copyright. The separately
downloaded OpenAI fixture retains its own upstream MIT license and provenance.
