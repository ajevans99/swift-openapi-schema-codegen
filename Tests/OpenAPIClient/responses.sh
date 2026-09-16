#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
export OPENAPI_CODEGEN_PATH="$root"
if [[ ${JSON_SCHEMA_CODEGEN_PATH+x} || ${JSON_SCHEMA_RUNTIME_PATH+x} || ${OPENAPI_SCHEMA_PATH+x} ]]; then
  echo "Release acceptance requires all development dependency overrides to be unset." >&2
  exit 1
fi
python="${PYTHON:-python3}"
build_flags=()
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
  build_flags=(--build-system "$SWIFT_BUILD_SYSTEM")
fi
corpus="$root/.build/openapi-corpus"
printf '%s\n' \
  "3d6223349eadfd937624b9e6b8abf596ec2f680a1a367889cf6a6f924e568127  $corpus/openapi.json" \
  "bcba3de214851cce46ed5af42d6698044616eeace887c3231bc7a20474ab639e  $corpus/LICENSE" \
  | shasum -a 256 -c -

swift build ${build_flags[@]+"${build_flags[@]}"} --jobs 1 --product openapi-json-codegen
bin="$(swift build ${build_flags[@]+"${build_flags[@]}"} --show-bin-path)/openapi-json-codegen"
work="$root/.build/responses-consumer"
mkdir -p "$work/Sources/GeneratedAPI" "$work/Sources/Consumer"
cp Tests/OpenAPIClient/Consumer/Package.swift "$work/Package.swift"
cp Tests/OpenAPIClient/Consumer/Responses.swift "$work/Sources/Consumer/main.swift"
cp Tests/OpenAPIClient/Consumer/Support.swift "$work/Sources/Consumer/Support.swift"
swift package show-dependencies --format json > "$corpus/responses-released-generator-dependencies.json"
swift package --package-path "$work" show-dependencies --format json > "$corpus/responses-released-consumer-dependencies.json"
provenance=(
  "$python" Tests/OpenAPIClient/provenance.py --root "$root"
  --graph "$corpus/responses-released-generator-dependencies.json"
  --graph "$corpus/responses-released-consumer-dependencies.json"
)
inputs="$corpus/responses-released-inputs.json"
"${provenance[@]}" --output "$inputs"
artifact="$corpus/OpenAIResponsesAPI-released.swift"
"$python" Tests/OpenAPIClient/bounded.py --seconds 120 --rss-kib 1572864 \
  --prefix "$corpus/responses-released-generation" -- \
  "$bin" "$corpus/openapi.json" --operation createResponse \
  --profile Tests/OpenAPIClient/Fixtures/responses-profile.json \
  --namespace OpenAIResponsesAPI --output "$artifact"
"${provenance[@]}" --output "$inputs" --verify
cp "$artifact" "$work/Sources/GeneratedAPI/OpenAIResponsesAPI.swift"
fingerprints="$corpus/responses-released-provenance.json"
"${provenance[@]}" --output "$fingerprints" --artifact "$artifact"
"$python" Tests/OpenAPIClient/bounded.py --seconds 600 --rss-kib 3145728 \
  --prefix "$corpus/responses-released-consumer" -- bash -c '
    set -euo pipefail
    work="$1"; shift
    swift build --package-path "$work" "$@" --jobs 1 --product Consumer
    consumer="$(swift build --package-path "$work" "$@" --show-bin-path)/Consumer"
    "$consumer" Tests/OpenAPIClient/Fixtures/response.json
  ' responses-consumer "$work" ${build_flags[@]+"${build_flags[@]}"}
cmp "$artifact" "$work/Sources/GeneratedAPI/OpenAIResponsesAPI.swift"
"${provenance[@]}" --output "$fingerprints" --artifact "$artifact" --verify
"$bin" "$corpus/openapi.json" --operation createResponse --report \
  > "$corpus/responses-released-strict-compatibility.tsv"
"$bin" "$corpus/openapi.json" --operation createResponse --report \
  --profile Tests/OpenAPIClient/Fixtures/responses-profile.json \
  > "$corpus/responses-released-profile-compatibility.tsv"
shasum -a 256 "$artifact"
echo "Pristine release-based Responses consumer passed."
