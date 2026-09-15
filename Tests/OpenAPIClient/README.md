# OpenAPI client acceptance corpus

The acceptance scripts require Bash, `curl`, and `shasum` (Perl's Digest::SHA),
in addition to Swift. These are available on the CI runners; minimal Linux
containers may need `curl` installed separately.
The smoke harness defaults to four concurrent build jobs to bound SwiftSyntax
compiler resource use. Set `SWIFT_JOBS` to another positive integer if needed.

Run from the repository root:

```sh
# Explicit one-time artifact download, separate from generation:
bash Tests/OpenAPIClient/fetch-openai.sh

# Uses the released importer and pinned remote generic core by default:
swift test
bash Tests/OpenAPIClient/smoke.sh

# Optional local importer integration:
OPENAPI_SCHEMA_PATH=/path/to/swift-openapi-schema \
  bash Tests/OpenAPIClient/smoke.sh
```

The smoke script does not fetch a spec. It verifies both artifact and license
checksums before generating from the existing artifact. SwiftPM may fetch package
dependencies normally.
Generated Swift, package builds, and reports live under `.build/`, not source
fixtures. The small POST fixture in `Fixtures/operations.json` is authored here.

## Pin and licensing

Repository: https://github.com/openai/openai-openapi

Revision: `4bb21ba8e9213c3d955b69dc3f76dd7537439828`

| File | SHA-256 |
| --- | --- |
| `openapi.json` | `3d6223349eadfd937624b9e6b8abf596ec2f680a1a367889cf6a6f924e568127` |
| `LICENSE` | `bcba3de214851cce46ed5af42d6698044616eeace887c3231bc7a20474ab639e` |

The upstream corpus is **MIT licensed, Copyright (c) OpenAI**. The explicit
download script retains the upstream license alongside the artifact.
No upstream spec/schema excerpt is hand-rewritten or vendored as a smaller
replacement. Its original document and pointers are used for selected closures.

## Verified scope

The pinned OpenAPI 3.1.0 document contains **215 paths, 338 operations, and 1,852
component schemas**. The foundation independently verifies lossless import/export,
the checked catalog, and strict structural OpenAPI validation. These facts do not
mean all embedded schemas or operations can become clients.

The compiled consumer selects actual `listModels` and `retrieveModel` operations,
as well as authored `createWidget` and `optionalBody` operations. All HTTP execution
uses an injectable recording mock. No live OpenAI requests or real credentials
are used.

Actual list items and retrieve responses share `Model` and its `ModelObject`
payload. The corpus's Model has no explicit object type, so the generated enum
exposes `.object(ModelObject)` and `.nonObject(JSONValue)`. The consumer accesses
typed fields and the finite object enum, constructs/encodes a Model, rejects
invalid object responses without fallback, preserves allowed nonobjects, and
rejects an object placed in the nonobject case.

The authored POST checks original field keys, typed enums with canonically
distinct Unicode strings, nullable required fields and optional explicit null,
flattened typed extras, exact-number JSONValue payloads, semantic unions,
request/response nominal sharing, parameter inheritance/override, percent
encoding, and server base paths. Invalid constructed requests, extra-key
collisions, and missing credentials fail before transport. It exercises typed
200/range/default errors, empty 204 responses, unsupported media, malformed
responses, transport failures, and cancellation.

Runtime tests additionally check the exact configured response limit boundary,
over-limit failure, credential OR/AND alternatives/collisions, anonymous security,
and invalid headers/base URLs.

Standalone unit tests and the compiled consumer pass with Apple Swift **6.4**
on macOS and Swift **6.1.3** on Linux (`swift:6.1.3-noble`), in Swift 6 language
mode. Both runs use remote dependencies without importer overrides. CI repeats
unit and compiled-consumer coverage on macOS and Ubuntu with Swift **6.1.3**.

## Compatibility reports

`smoke.sh` writes the full HTTP/annotation report to
`.build/openapi-corpus/compatibility.tsv` and the bounded Models generation report
to `.build/openapi-corpus/models-compatibility.tsv`. To rerun that selected pass:

```sh
swift run openapi-json-codegen \
  .build/openapi-corpus/openapi.json --report --check-models \
  --operation listModels --operation retrieveModel \
  > .build/openapi-corpus/models-compatibility.tsv
```

Selected closures have these important outcomes:

| Operation | Outcome or located blocker |
| --- | --- |
| `listModels` | JSON GET surface generated and compiled; vendor annotations remain inert |
| `retrieveModel` | JSON GET surface generated and compiled; same component identity as list items |
| `createResponse` | `#/paths/~1responses/post/responses/200/content/text~1event-stream`: unsupported SSE |
| `createResponse` | `#/paths/~1responses/post/responses/200/content/application~1json`: multiple JSON/SSE media alternatives |

The completed default-policy full-corpus scan currently reports **323 error
diagnostics across 63 operations**, and **6,760 annotation/metadata warnings**.
The actual Models closures have no errors (five list warnings and four retrieve
warnings). These are located diagnostic counts, not a full generated-SDK support
matrix. The strict structural foundation validation passes the corpus; client
representation and HTTP policy are deliberately narrower.

The non-streaming Responses slice is deliberately not generated by deleting
the SSE alternative or changing `stream` semantics. Multipart/binary endpoints,
legacy nullable annotations, unsupported parameter shapes/styles, and other
complete-corpus blockers remain explicit, located report entries.

Reports enumerate diagnostic occurrences; shared-schema annotations may recur
per operation. Warnings describe retained metadata and are not blockers.
`--check-models` adds one located generic model failure per otherwise eligible
operation, where any occurs. Successful source generation is not a compiled
all-operations SDK guarantee, and this milestone does not claim full OpenAI SDK
support.

An exploratory full-catalog generic model pass was stopped after more than eight
minutes of CPU work. It was **incomplete**, not a successful compatibility result;
unchecked operations are not classified as supported. The completed full-corpus
report covers HTTP/annotation policy, while generic model generation and
cross-module compilation are checked on the selected closures above. The CLI
prints each model-check operation and source pointer to stderr so subsequent
long-running checks expose progress.
