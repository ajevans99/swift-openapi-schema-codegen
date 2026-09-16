# OpenAPI client acceptance corpus

The acceptance scripts require Swift **6.1+**, Bash, `curl`, and `shasum`
(Perl's Digest::SHA). The actual Responses harness additionally requires
**Python 3 and `ps`** for its bounded process runner. Minimal Linux containers
may need these tools installed separately.

Run from the repository root:

```sh
# Default released remote dependencies; empty overrides are errors:
unset OPENAPI_SCHEMA_PATH JSON_SCHEMA_CODEGEN_PATH JSON_SCHEMA_RUNTIME_PATH

# Explicit checksum-pinned download, separate from generation:
bash Tests/OpenAPIClient/fetch-openai.sh

swift test
bash Tests/OpenAPIClient/smoke.sh
bash Tests/OpenAPIClient/responses.sh
```

Neither acceptance script fetches a spec. Prefetch the pinned corpus and license
with `fetch-openai.sh`; the harnesses verify checksums before generation.
Generation is offline, although SwiftPM may fetch package dependencies normally.
Generated Swift, consumer packages, and reports live under `.build/`, not source
fixtures. No live OpenAI requests or real credentials are used.

## Released dependency baseline

The default manifest uses these released remote requirements:

| Dependency | Requirement | Release revision |
| --- | --- | --- |
| `swift-openapi-schema` | from 0.2.0 | Importer requirement unchanged |
| `swift-json-schema-codegen` | from 0.3.0 | `2937926f4def9885ced02b31bcb0155248c612ef` |
| `swift-json-schema` | from 0.14.1 | `1514dd27fd55dbd36eec40c60e40ac8bfe0a22f4` |

`Package.resolved` records the resolved graph. The historical immutable
generic-core bootstrap revision is no longer a dependency requirement.
`preserveUnknownFields: true` works with these released dependencies: no
conditional API bridge or local override is needed. The JSON Schema release
includes the strict-2020-12 projection parity correction, not 2019-09 recursion.

### Verified release-based local result

The pristine profile generates and the actual recording consumer **passes**
with all development overrides unset. Both dependency graphs resolve the
released versions above; their checkout revisions and clean source bytes are
checked against each graph's own lockfile, then fingerprinted before and after
execution. Independent consumer resolution can select another compatible
SwiftSyntax version; the generator/runtime/importer release revisions must
agree across both graphs.
Local validation used Apple Swift 6.4/macOS with normal compiler flags.

| Measurement | Result |
| --- | --- |
| Generation, capped at 120 s / 1.5 GiB | 21.241 s; 942,032 KiB sampled aggregate peak RSS |
| Generated Swift | 5,248,100 bytes; 426 private exact-output parser factories |
| Request/200 root expression size; maximum root | 94 bytes each; 382 bytes |
| Consumer-only corrective build and run, capped at 600 s / 3 GiB | 9.649 s; 487,792 KiB sampled aggregate peak RSS; exit 0 |
| Fresh consumer execution | 3.36 s; 51,822,592 bytes maximum RSS |
| Cold request validation / first client request and response decode | 0.213 s / 0.553 s |

The initial normal build compiled the generated module but rejected an authored
collision test's reference to a private generated error type. That attempt ended
after 40.627 seconds with 2,003,936 KiB sampled aggregate peak RSS. Correcting only
the authored assertion to check the collision error's description allowed the
consumer-only retry above to pass; there was no generated edit or regeneration.
These are warm local measurements, not fresh-clone or cross-platform guarantees.

Current generated SHA-256:
`90009fda885fea03bc79e3aa6ae6d94c178e9997d8c2aad2783dfe426d15ba9e`.
The profile SHA-256 remains
`1803bc8ac09aece484b9442173b91a69bf16c18815999c2b154d47d63b77a929`.
The reviewed closed-object preservation fix intentionally changes generated
bytes from the historical development artifact below. All 33 package tests,
ten Python harness guards, and the prior authored/Models/profile consumer pass
with released dependencies. Keep release-run provenance and metrics separate
from historical files.

## Two separate harnesses

### Small compiled consumer: `smoke.sh`

The existing smoke harness generates the actual `listModels` and `retrieveModel`
operations, plus authored `createWidget`, `optionalBody`, and profiled
`createMessage` fixtures. It compiles a separate `GeneratedAPI` module and
executes an external recording consumer, checking public API accessibility and
nominal sharing rather than only source snapshots.

It defaults to four concurrent build jobs to bound SwiftSyntax compilation.
Set `SWIFT_JOBS` to another positive integer if needed. It builds with SwiftPM
and launches the resulting executable directly; it does not retry or suppress
consumer failures.

### Actual Responses acceptance: `responses.sh`

This separate, larger harness generates pristine official `createResponse` using
`Fixtures/responses-profile.json`, including `preserveUnknownFields: true`.
It uses the default remote dependencies with all three development overrides
unset. It does not replace the smoke test, rewrite the schema, patch generated
Swift, or substitute a raw fallback.

```sh
bash Tests/OpenAPIClient/responses.sh

# Optional backend selection when using an installed Swift 6.4 toolchain:
SWIFT_BUILD_SYSTEM=native bash Tests/OpenAPIClient/responses.sh
```

The ordinary default works with Swift 6.1; the backend override is optional.
The Python 3 / `ps` runner bounds generation to **120 seconds / 1.5 GiB** and
the combined normal **`--jobs 1` build plus direct consumer execution** to
**600 seconds / 3 GiB**. No `swift run Consumer` or special solver/acceptance
flags are used. A timeout, resource-limit termination, build error, or consumer
failure is not passing acceptance.

Outputs:

* `.build/openapi-corpus/OpenAIResponsesAPI-released.swift`: generated source.
* `.build/openapi-corpus/responses-released-*`: provenance, generator/consumer
  dependency graphs, metrics, logs, and compatibility reports.
* `.build/responses-consumer`: the separate generated-module/consumer package.

`Consumer/Responses.swift` checks typed text/function-tool requests and typed
200/429/503 responses, Unicode replies, original keys and complete request bytes,
URL/auth/headers, omitted/false versus true/null `stream`, original request and
response schema failures, zero body reads on SSE, transport errors/cancellation,
unknown/declared-key collision refusal, and complete request/response JSONValue
equality including nested unknown precise/huge numbers and explicit nulls. Source generation alone does not prove
these runtime checks passed; retain the actual consumer exit status and metrics.

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
The small fixtures are independently authored, not replacement OpenAI schemas.

## Coverage and limits

The pinned OpenAPI 3.1.0 document contains **215 paths, 338 operations, and 1,852
component schemas**. The foundation independently verifies lossless import/export,
the checked catalog, and strict structural OpenAPI validation. These facts do not
mean all embedded schemas or operations can become clients.

Actual list items and retrieve responses share `Model` and its `ModelObject`
payload. The corpus's Model has no explicit object type, so the generated enum
exposes `.object(ModelObject)` and `.nonObject(JSONValue)`. The small consumer
accesses typed fields and the finite object enum, constructs/encodes a Model,
rejects invalid object responses without fallback, preserves allowed nonobjects,
and rejects an object placed in the nonobject case.

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
and invalid headers/base URLs. Earlier standalone unit and small-consumer runs
passed with Apple Swift **6.4** on macOS and Swift **6.1.3** on Linux
(`swift:6.1.3-noble`), in Swift 6 language mode, using remote dependencies.
CI runs unit, small-consumer, and bounded actual Responses acceptance on macOS
and Ubuntu with Swift **6.1.3**. The local results above are separate from those
hosted jobs.

### Profile semantics and early SSE refusal

Strict defaults remain unchanged: selected bodies/responses require one JSON
media type or an explicitly bodyless response. A profile opts into a JSON-only
subset, not whole-operation, SSE, multipart, or binary support. The pristine SSE
declaration remains a located exclusion warning; only the selected JSON schema
closure is analyzed and generated. The original document is not stripped.

The profile selects exact declared JSON request/response media. Request media
selection requires an additional request constraint; bodyless operations omit
both request fields. Version 1 constraints support boolean schemas, `properties`
recursively, and `const` with any JSON value; other profile keywords are errors.
These restrictions do not narrow the original schema vocabulary.

`properties.stream.const: false` permits omission or `false` and rejects other
supplied values without requiring the property. Generated request preparation
encodes and validates against the original schema, then independently validates
the profile constraint before credentials or transport. Optional absent bodies
stay absent. Schema-only encoders and response validation do not apply request
policy. `preserveUnknownFields` defaults to `false`; enabling it preserves
otherwise-unmodeled, schema-allowed fields as exact JSONValue entries across the
shared namespace without changing validity or typed additional properties.

The authored `createMessage` profile verifies omitted/false `stream` sends,
true fails before transport, an empty message still fails original validation,
keys/extras encode unchanged, and JSON responses stay typed. Profiled clients
validate response headers **before requesting any body chunks**. The SSE probe
throws if iteration is requested, proving unread-body refusal rather than a
body-size-limit fallback. Exact status takes precedence over range and default;
bodyless and undocumented-status decoder rules remain intact. For declared JSON
responses, missing/wrong Content-Type intentionally precedes empty/oversized body
errors. Original validation still follows collection, and cancellation propagates.
Non-profiled clients retain their existing response behavior.

### Strict 2020-12 and the legacy CompoundFilter oddity

The pristine `CompoundFilter` contains `$recursiveAnchor: true` and
`#/components/schemas/CompoundFilter/properties/filters/items/oneOf/1/$recursiveRef`
with value `"#"`. Both legacy keywords are inert under strict 2020-12 and receive
located warnings; the runtime does not activate 2019-09 recursion. Active dynamic
references remain unsupported by static projection.

The legacy-reference-only `oneOf` branch is therefore unconstrained. Empty filters
are accepted; a valid comparison item matches both branches and is rejected.
Arbitrary strings or malformed nested compound objects can be accepted, while
missing required root filters are rejected. This is unchanged upstream validity,
**not recursive-filter support or a repaired schema**. Isolated filter-validator
observations are separate from actual Responses consumer acceptance.

## Compatibility reports

The latest completed HTTP/annotation reports are:

| Selection | Errors | Warnings |
| --- | --- | --- |
| Full corpus, default policy | 323 across 63 operations | 6,802 |
| Strict `createResponse` | 2 | 320 |
| JSON-profiled `createResponse` | 0 | 205 |
| `listModels` | 0 | 5 |
| `retrieveModel` | 0 | 4 |

Strict `createResponse` refuses the declared SSE response and the multiple
JSON/SSE media alternatives. Profiling does not hide the SSE declaration.
Multipart/binary endpoints, legacy nullable annotations, unsupported parameter
shapes/styles, and other complete-corpus blockers remain located entries.

`smoke.sh` writes `.build/openapi-corpus/compatibility.tsv` and the bounded
Models generation report `.build/openapi-corpus/models-compatibility.tsv`.
Selected reports can also be reproduced without overrides:

```sh
swift run openapi-json-codegen .build/openapi-corpus/openapi.json \
  --report --check-models --operation listModels --operation retrieveModel \
  > .build/openapi-corpus/models-compatibility.tsv

swift run openapi-json-codegen .build/openapi-corpus/openapi.json \
  --operation createResponse \
  --profile Tests/OpenAPIClient/Fixtures/responses-profile.json --report
```

Counts enumerate diagnostic occurrences; shared-schema annotations may recur
per operation. Warnings describe retained metadata and are not blockers.
`--check-models` reports the first generic failure for each otherwise eligible
operation and does not compile every generated combination. The CLI prints
model-check operations and source pointers to stderr to expose progress.
Static reports are not model-representability, compilation, or runtime proof.

A previous full-catalog generic-model scan was stopped after more than eight
minutes of CPU work and remains **incomplete**. Unchecked operations are not
classified as supported. Neither selected-slice acceptance nor successful source
generation guarantees a full generic all-operations SDK, whole-operation support,
or downstream SDK migration.

## Bounded historical evidence — not release acceptance

Before the upstream releases, a frozen development generic-core candidate plus a
local strict-2020-12 runtime parity patch generated, compiled, and passed the
actual Responses recording consumer. No generated Swift or schema was edited.
Earlier bounded generation/compile failures were investigation results, not
passing acceptance or evidence that unchecked operations were supported.

The **historical** source was 5,263,626 bytes, SHA-256
`1e0f6a8dc0042f104ec8b4889c76352781ee582f39938935c40443655bee707e`.
Its profile SHA-256 was
`1803bc8ac09aece484b9442173b91a69bf16c18815999c2b154d47d63b77a929`.

| Historical measurement | Result |
| --- | --- |
| Generation, capped at 120 s / 1.5 GiB | 22.109 s; 663,360 KiB sampled aggregate peak RSS |
| Normal one-job build | 29.79 s |
| Combined build/run, capped at 600 s / 3 GiB | 47.086 s; 1,411,536 KiB sampled aggregate peak RSS; exit 0 |
| Fresh consumer execution | 3.37 s; 51,986,432 bytes maximum RSS |
| Cold request validation / first client request and response decode | 0.218 s / 0.547 s |

These Apple Swift 6.4/macOS warm-build observations are neither fresh-clone nor
cross-platform guarantees. Historical evidence is under `.build/openapi-corpus/`
as `OpenAIResponsesAPI-runtime.swift` and `responses-runtime-*` provenance,
dependency-graph, inventory, and metrics files. Both historical dependency graphs
used fixed local runtime source, not the released remote graph. An upstream base
commit alone does not identify those patched prerequisites.

Do not relabel the `1e0f…` artifact or these timings as a new release run.
Current release-based results are recorded separately above.
Preserve the original spec, license, profile, generator revision, resolved graph,
input fingerprints, output hash, and exit status together for each new run.

## Optional developer overrides

`OPENAPI_SCHEMA_PATH`, `JSON_SCHEMA_CODEGEN_PATH`, and `JSON_SCHEMA_RUNTIME_PATH`
remain explicit, optional developer-only overrides. Unset them for default
remote acceptance; setting an empty value is an error. An override is not a
published release and is not required for actual Responses or preservation.
`JSON_SCHEMA_RUNTIME_PATH` selects the JSON Schema runtime and transitive uses
of that identity, not `OpenAPIJSONRuntime`.

Only when using local runtime worktrees, use basename `swift-json-schema` because
SwiftPM derives local package identity from that basename. An ignored canonical
alias under `.build/` can point to a differently named, unchanged checkout; inspect
an existing alias before reuse. Record resolved paths and source/manifest hashes,
including untracked source, and inspect both generator and consumer graphs with
`swift package show-dependencies --format json`. SwiftPM may warn about a
local/remote identity conflict; a future version may reject it. None of this
alias wiring belongs in production release setup.
