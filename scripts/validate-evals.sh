#!/usr/bin/env bash
# Minimal eval fixture validator — schema presence, uniqueness, and safe artifact checks (not semantic scoring).
# Usage: ./scripts/validate-evals.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVALS="${ROOT}/evals"
ERRORS=0
COUNT=0
SEEN_IDS=$'\n'
SEEN_ID_LIST=()
SEEN_ID_FILES=()
TRIMMED_VAL=""

if [[ ! -d "$EVALS" ]]; then
  echo "error: evals directory not found: $EVALS" >&2
  exit 1
fi

trim_yaml_value() {
  local raw="$1"
  raw="${raw%$'\r'}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "$raw" == \#* ]]; then
    TRIMMED_VAL=""
    return
  fi
  if [[ "$raw" == \"*\" && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
  elif [[ "$raw" == \'*\' && ${#raw} -ge 2 ]]; then
    raw="${raw:1:${#raw}-2}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
  fi
  TRIMMED_VAL="$raw"
}

require_nonempty_key() {
  local file="$1"
  local key="$2"
  local seen="$3"
  local val="$4"
  if [[ "$seen" -eq 0 ]]; then
    echo "error: $file missing required key: $key" >&2
    ERRORS=$((ERRORS + 1))
    return 1
  fi
  if [[ -z "$val" ]]; then
    echo "error: $file empty value for required key: $key" >&2
    ERRORS=$((ERRORS + 1))
    return 1
  fi
  return 0
}

while IFS= read -r -d '' f; do
  COUNT=$((COUNT + 1))

  seen_id=0; val_id=""
  seen_artifact=0; val_artifact=""
  seen_intent=0; val_intent=""
  seen_expected_bucket=0; val_expected_bucket=""
  seen_expected_outcome=0; val_expected_outcome=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      id:*)
        if [[ $seen_id -eq 0 ]]; then
          seen_id=1
          trim_yaml_value "${line#id:}"
          val_id="$TRIMMED_VAL"
        fi
        ;;
      artifact:*)
        if [[ $seen_artifact -eq 0 ]]; then
          seen_artifact=1
          trim_yaml_value "${line#artifact:}"
          val_artifact="$TRIMMED_VAL"
        fi
        ;;
      intent:*)
        if [[ $seen_intent -eq 0 ]]; then
          seen_intent=1
          trim_yaml_value "${line#intent:}"
          val_intent="$TRIMMED_VAL"
        fi
        ;;
      expected_bucket:*)
        if [[ $seen_expected_bucket -eq 0 ]]; then
          seen_expected_bucket=1
          trim_yaml_value "${line#expected_bucket:}"
          val_expected_bucket="$TRIMMED_VAL"
        fi
        ;;
      expected_outcome:*)
        if [[ $seen_expected_outcome -eq 0 ]]; then
          seen_expected_outcome=1
          trim_yaml_value "${line#expected_outcome:}"
          val_expected_outcome="$TRIMMED_VAL"
        fi
        ;;
    esac
  done < "$f"

  if require_nonempty_key "$f" "id" "$seen_id" "$val_id"; then
    if [[ "$SEEN_IDS" == *$'\n'"${val_id}"$'\n'* ]]; then
      first_file=""
      if [[ ${#SEEN_ID_LIST[@]} -gt 0 ]]; then
        for idx in "${!SEEN_ID_LIST[@]}"; do
          if [[ "${SEEN_ID_LIST[$idx]}" == "$val_id" ]]; then
            first_file="${SEEN_ID_FILES[$idx]}"
            break
          fi
        done
      fi
      echo "error: $f duplicate id '${val_id}' (already seen in ${first_file})" >&2
      ERRORS=$((ERRORS + 1))
    else
      SEEN_IDS="${SEEN_IDS}${val_id}"$'\n'
      SEEN_ID_LIST+=("$val_id")
      SEEN_ID_FILES+=("$f")
    fi
  fi

  require_nonempty_key "$f" "artifact" "$seen_artifact" "$val_artifact" || true
  require_nonempty_key "$f" "intent" "$seen_intent" "$val_intent" || true

  rel="${f#"${EVALS}/"}"
  if [[ "$rel" != */* ]]; then
    echo "error: $f fixture must be under a known evals/<category>/ directory" >&2
    ERRORS=$((ERRORS + 1))
  else
    category="${rel%%/*}"
    if [[ "$category" == "skills" ]]; then
      require_nonempty_key "$f" "expected_bucket" "$seen_expected_bucket" "$val_expected_bucket" || true
    elif [[ "$category" == "agents" ]]; then
      require_nonempty_key "$f" "expected_bucket" "$seen_expected_bucket" "$val_expected_bucket" || true
    elif [[ "$category" == "review-loop" ]]; then
      require_nonempty_key "$f" "expected_outcome" "$seen_expected_outcome" "$val_expected_outcome" || true
    elif [[ "$category" == "workflows" ]]; then
      require_nonempty_key "$f" "expected_outcome" "$seen_expected_outcome" "$val_expected_outcome" || true
    elif [[ "$category" == "commands" ]]; then
      require_nonempty_key "$f" "expected_outcome" "$seen_expected_outcome" "$val_expected_outcome" || true
    elif [[ "$category" == "rules" ]]; then
      require_nonempty_key "$f" "expected_outcome" "$seen_expected_outcome" "$val_expected_outcome" || true
    else
      echo "error: $f unknown eval category directory: $category" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if [[ -n "$val_artifact" ]]; then
    if [[ "$val_artifact" == /* || "$val_artifact" == *\\* || "$val_artifact" =~ ^[A-Za-z]: || "$val_artifact" == ".." || "$val_artifact" == "../"* || "$val_artifact" == *"/.." || "$val_artifact" == *"/../"* ]]; then
      echo "error: $f unsafe artifact path: $val_artifact" >&2
      ERRORS=$((ERRORS + 1))
    elif [[ ! -f "${ROOT}/${val_artifact}" ]]; then
      echo "error: $f artifact is not a regular file: $val_artifact" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(find "$EVALS" -name '*.yaml' -print0)

echo "validated $COUNT fixture(s)"

if [[ $COUNT -eq 0 ]]; then
  echo "error: no eval fixtures found in $EVALS" >&2
  ERRORS=$((ERRORS + 1))
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS error(s)" >&2
  exit 1
fi

echo "ok"
