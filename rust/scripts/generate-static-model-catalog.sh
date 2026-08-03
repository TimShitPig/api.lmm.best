#!/usr/bin/env bash
# Regenerate the frozen legacy openAIModelsMap without adding Go to the Rust runtime.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
legacy_root="$repo_root/go"
controller_dir="$legacy_root/controller"
output="$repo_root/rust/apps/lmm-api-rs/assets/legacy-static-model-catalog.json"
test_file="$controller_dir/catalog_dump_generated_test.go"

cleanup() { rm -f -- "$test_file"; }
trap cleanup EXIT

if [[ -e "$test_file" ]]; then
  printf 'refusing to overwrite %s\n' "$test_file" >&2
  exit 1
fi

cat >"$test_file" <<'EOF'
package controller

import (
  "encoding/json"
  "os"
  "sort"
  "testing"
  "github.com/QuantumNous/new-api/relaykit/dto"
)

func TestDumpFrozenStaticModelCatalog(t *testing.T) {
  keys := make([]string, 0, len(openAIModelsMap))
  for key := range openAIModelsMap { keys = append(keys, key) }
  sort.Strings(keys)
  models := make([]dto.OpenAIModels, 0, len(keys))
  for _, key := range keys { models = append(models, openAIModelsMap[key]) }
  encoder := json.NewEncoder(os.Stdout)
  encoder.SetEscapeHTML(false)
  if err := encoder.Encode(models); err != nil { t.Fatal(err) }
}
EOF

mkdir -p -- "$(dirname -- "$output")"
cd -- "$legacy_root"
go test ./controller -run '^TestDumpFrozenStaticModelCatalog$' -count=1 -v 2>&1 \
  | sed -n '/^\[/{p;}' >"$output"

jq -e 'type == "array" and length > 0' "$output" >/dev/null
jq -S . "$output" >"$output.tmp"
mv -- "$output.tmp" "$output"
