#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
destination="$root/.build/openapi-corpus"
revision=4bb21ba8e9213c3d955b69dc3f76dd7537439828
mkdir -p "$destination"
curl -fsSL "https://raw.githubusercontent.com/openai/openai-openapi/$revision/openapi.json" -o "$destination/openapi.json"
curl -fsSL "https://raw.githubusercontent.com/openai/openai-openapi/$revision/LICENSE" -o "$destination/LICENSE"
cd "$destination"
printf '%s\n' \
  "3d6223349eadfd937624b9e6b8abf596ec2f680a1a367889cf6a6f924e568127  openapi.json" \
  "bcba3de214851cce46ed5af42d6698044616eeace887c3231bc7a20474ab639e  LICENSE" \
  | shasum -a 256 -c -
