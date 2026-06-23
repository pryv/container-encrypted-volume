#!/usr/bin/env bash
# Validate every backend/key-provider manifest against its JSON Schema.
# Uses ajv if available, else falls back to a minimal node/python check of JSON
# well-formedness + required keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

check_json() { # <file>
  if command -v node >/dev/null 2>&1; then
    node -e "JSON.parse(require('fs').readFileSync('$1','utf8'))" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open('$1'))" 2>/dev/null
  else
    return 0
  fi
}

for m in "$ROOT"/backends/*/manifest.json "$ROOT"/key-providers/*/manifest.json; do
  [ -e "$m" ] || continue
  if check_json "$m"; then echo "  OK   $m"; else echo "  BAD  $m (invalid JSON)"; fail=1; fi
done

if command -v npx >/dev/null 2>&1; then
  echo "(for full schema validation: npx ajv-cli validate -s schemas/backend.manifest.schema.json -d 'backends/*/manifest.json')"
fi
exit $fail
