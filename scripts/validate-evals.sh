#!/usr/bin/env bash
# Minimal eval fixture validator — schema presence only, not semantic scoring.
# Usage: ./scripts/validate-evals.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS="${ROOT}/evals"
ERRORS=0
COUNT=0

require_key() {
  local file="$1"
  local key="$2"
  if ! grep -q "^${key}:" "$file"; then
    echo "error: $file missing required key: $key" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

while IFS= read -r -d '' f; do
  COUNT=$((COUNT + 1))
  require_key "$f" "id"
  require_key "$f" "artifact"
  require_key "$f" "intent"

  if [[ "$f" == *"/skills/"* ]]; then
    require_key "$f" "expected_bucket"
  elif [[ "$f" == *"/review-loop/"* ]]; then
    require_key "$f" "expected_outcome"
  elif [[ "$f" == *"/rules/"* ]]; then
    require_key "$f" "expected_outcome"
  fi
done < <(find "$EVALS" -name '*.yaml' -print0)

echo "validated $COUNT fixture(s)"

if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS error(s)" >&2
  exit 1
fi

echo "ok"
