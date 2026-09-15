#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OPENAPI_CODEGEN_PATH="$root"
jobs="${SWIFT_JOBS:-4}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "SWIFT_JOBS must be a positive integer." >&2
  exit 1
fi
corpus="$root/.build/openapi-corpus/openapi.json"
if [[ ! -f "$corpus" ]]; then
  echo "Missing pinned fixture. Run bash Tests/OpenAPIClient/fetch-openai.sh explicitly first." >&2
  exit 1
fi
printf '%s\n' \
  "3d6223349eadfd937624b9e6b8abf596ec2f680a1a367889cf6a6f924e568127  $corpus" \
  "bcba3de214851cce46ed5af42d6698044616eeace887c3231bc7a20474ab639e  $root/.build/openapi-corpus/LICENSE" \
  | shasum -a 256 -c -
work="$root/.build/openapi-consumer"
mkdir -p "$work/Sources/GeneratedAPI" "$work/Sources/Consumer"
cp "$root/Tests/OpenAPIClient/Consumer/Package.swift" "$work/Package.swift"
cp "$root/Tests/OpenAPIClient/Consumer/main.swift" "$work/Sources/Consumer/main.swift"
swift build --package-path "$root" --jobs "$jobs" --product openapi-json-codegen
bin="$(swift build --package-path "$root" --show-bin-path)/openapi-json-codegen"
"$bin" "$root/Tests/OpenAPIClient/Fixtures/operations.json" \
  --operation createWidget --operation optionalBody --namespace Authored \
  --output "$work/Sources/GeneratedAPI/Authored.swift"
"$bin" "$corpus" --operation listModels --operation retrieveModel --namespace OpenAI \
  --output "$work/Sources/GeneratedAPI/OpenAI.swift"
"$bin" "$corpus" --report > "$root/.build/openapi-corpus/compatibility.tsv"
"$bin" "$corpus" --report --check-models \
  --operation listModels --operation retrieveModel \
  > "$root/.build/openapi-corpus/models-compatibility.tsv"
swift run --package-path "$work" --jobs "$jobs" Consumer
echo "Generated public API consumer passed."
