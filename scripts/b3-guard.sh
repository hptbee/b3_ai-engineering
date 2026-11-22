#!/usr/bin/env bash
# Deterministic helper checks for /b3-ship and /b3-review-loop (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot | diff-scope | mechanical-check | check-wave | new-run | resolve-run | list-runs | prune
set -euo pipefail

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|mechanical-check|check-wave|new-run|resolve-run|list-runs|prune [options]" >&2
  exit 1
fi
shift

norm_path() {
  local p="$1"
  p="${p//$'\r'/}"
  p="${p//\\//}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p#./}"
  while [[ "$p" == */ && "$p" != "/" ]]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

trim_str() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

split_csv_lines() {
  local raw
  raw="$(trim_str "$1")"
  [[ -z "$raw" || "$raw" == "[]" || "$raw" == "none" ]] && return 0
  if [[ "$raw" == \[*\] ]]; then
    raw="${raw#[}"
    raw="${raw%]}"
  fi
  local as_paths="${2:-false}"
  local IFS=','
  local part trimmed
  for part in $raw; do
    if [[ "$as_paths" == "true" ]]; then
      trimmed="$(norm_path "$part")"
    else
      trimmed="$(trim_str "$part")"
    fi
    [[ -z "$trimmed" || "$trimmed" == "none" ]] && continue
    printf '%s\n' "$trimmed"
  done
}

path_in_list() {
  local candidate="$1"
  shift
  local pat
  for pat in "$@"; do
    [[ -z "$pat" ]] && continue
    if [[ "$candidate" == "$pat" || "$candidate" == "$pat/"* ]]; then
      return 0
    fi
  done
  return 1
}

valid_run_id() {
  local LC_ALL=C
  local id="$1"
  [[ -n "$id" ]] || return 1
  [[ "$id" != *".."* && "$id" != *"/"* && "$id" != *"\\"* ]] || return 1
  [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]
}

sanitize_slug() {
  local LC_ALL=C
  local raw
  raw="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ ${#raw} -gt 40 ]]; then
    raw="${raw:0:40}"
    raw="$(printf '%s' "$raw" | LC_ALL=C sed -E 's/-+$//')"
  fi
  printf '%s' "$raw"
}

read_current_run_id() {
  local cur_file="$1/CURRENT"
  [[ -f "$cur_file" ]] || return 0
  trim_str "$(cat "$cur_file")"
}

read_run_status() {
  local prog="$1/progress.md"
  if [[ ! -f "$prog" ]]; then
    printf 'unknown'
    return 0
  fi
  local st
  st="$(awk '/^-[[:space:]]*run_status:[[:space:]]*/{sub(/^-[[:space:]]*run_status:[[:space:]]*/, ""); gsub(/\r$/, ""); print; exit}' "$prog")"
  st="$(trim_str "$st")"
  if [[ -n "$st" ]]; then
    printf '%s' "$st"
  else
    printf 'unknown'
  fi
}

is_noise_file() {
  local leaf="${1##*/}"
  case "$leaf" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lockb|packages.lock.json|Cargo.lock|poetry.lock) return 0 ;;
    *.min.js|*.min.css|*.snap|*.Designer.cs|*.g.cs|*.map) return 0 ;;
    *) return 1 ;;
  esac
}

find_leftover_tag() {
  local LC_ALL=C
  local ln="$1"
  if [[ "$ln" =~ (^|[^a-zA-Z0-9_])debugger([^a-zA-Z0-9_]|$) ]]; then
    printf 'debugger'
  elif [[ "$ln" =~ \.only\( ]]; then
    printf '.only('
  elif [[ "$ln" == *"@ts-ignore"* ]]; then
    printf '@ts-ignore'
  elif [[ "$ln" == *"eslint-disable"* ]]; then
    printf 'eslint-disable'
  elif [[ "$ln" =~ (^|[^a-zA-Z0-9_])(TODO|FIXME)[[:space:]]*:?[[:space:]]*$ ]]; then
    printf 'empty-todo'
  fi
}

resolve_auto_base_sha() {
  local root="$1"
  shift
  local -a ignored=("$@")
  local diff_out un_out line p
  diff_out="$(git -C "$root" diff --no-renames --name-only HEAD 2>/dev/null || true)"
  un_out="$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null || true)"
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -z "$p" ]] && continue
    [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
    if [[ ${#ignored[@]} -gt 0 ]] && path_in_list "$p" "${ignored[@]}"; then continue; fi
    printf '%s' "HEAD"
    return 0
  done < <(printf '%s\n%s\n' "$diff_out" "$un_out")

  local head_sha ref mb
  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$head_sha" ]]; then
    for ref in origin/HEAD origin/main origin/master main master; do
      if git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        mb="$(git -C "$root" merge-base "$ref" HEAD 2>/dev/null || true)"
        if [[ -n "$mb" && "$mb" != "$head_sha" ]]; then
          printf '%s' "$mb"
          return 0
        fi
      fi
    done
  fi
  printf '%s' "HEAD"
}

resolve_auto_base_for_target() {
  local root="$1"
  local target_commit_sha="$2"
  local ref mb
  for ref in origin/HEAD origin/main origin/master main master HEAD; do
    if git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      mb="$(git -C "$root" merge-base "$ref" "$target_commit_sha" 2>/dev/null || true)"
      if [[ -n "$mb" && "$mb" != "$target_commit_sha" ]]; then
        printf '%s' "$mb"
        return 0
      fi
    fi
  done
  printf '%s' "$target_commit_sha"
}

case "$CMD" in
  fingerprint)
    DEPENDS_ON=""
    SCOPE=""
    CRITERIA=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --depends-on) DEPENDS_ON="${2:-}"; shift 2 ;;
        --scope) SCOPE="${2:-}"; shift 2 ;;
        --criterion) CRITERIA+=("${2:-}"); shift 2 ;;
        *) echo "FINGERPRINT_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    SCOPE="$(trim_str "$SCOPE")"
    if [[ -z "$SCOPE" ]]; then
      echo "FINGERPRINT_FAIL: missing --scope"
      exit 1
    fi
    if [[ ${#CRITERIA[@]} -lt 1 ]]; then
      echo "FINGERPRINT_FAIL: missing --criterion"
      exit 1
    fi

    CRIT_FLAT=()
    for c in "${CRITERIA[@]}"; do
      IFS=';' read -ra parts <<< "$c"
      if [[ ${#parts[@]} -gt 0 ]]; then
        for part in "${parts[@]}"; do
          t="$(trim_str "$part")"
          [[ -n "$t" ]] && CRIT_FLAT+=("$t")
        done
      fi
    done
    if [[ ${#CRIT_FLAT[@]} -lt 1 ]]; then
      echo "FINGERPRINT_FAIL: empty criteria"
      exit 1
    fi

    DEP_LIST=()
    while IFS= read -r d; do
      [[ -n "$d" ]] && DEP_LIST+=("$d")
    done < <(split_csv_lines "$DEPENDS_ON" false | LC_ALL=C sort -u)

    DEP_TEXT="[]"
    if [[ ${#DEP_LIST[@]} -gt 0 ]]; then
      DEP_TEXT="$(IFS=','; echo "${DEP_LIST[*]}")"
    fi

    CRIT_TEXT=""
    for i in "${!CRIT_FLAT[@]}"; do
      if [[ "$i" -eq 0 ]]; then
        CRIT_TEXT="${CRIT_FLAT[$i]}"
      else
        CRIT_TEXT="${CRIT_TEXT}; ${CRIT_FLAT[$i]}"
      fi
    done
    printf 'depends_on=%s|scope=%s|acceptance_criteria=%s\n' "$DEP_TEXT" "$SCOPE" "$CRIT_TEXT"
    ;;

  check-freshness)
    REPO_ROOT="."
    APPROACH_AT=""
    TASK_BASE=""
    WATCHED=""
    OWNED=""
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --approach-at-sha) APPROACH_AT="${2:-}"; shift 2 ;;
        --task-base-sha) TASK_BASE="${2:-}"; shift 2 ;;
        --watched-paths) WATCHED="${2:-}"; shift 2 ;;
        --owned-files) OWNED="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "FRESHNESS_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    [[ -n "$APPROACH_AT" ]] || { echo "FRESHNESS_FAIL: missing --approach-at-sha"; exit 1; }
    [[ -n "$TASK_BASE" ]] || { echo "FRESHNESS_FAIL: missing --task-base-sha"; exit 1; }

    WATCHED_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && WATCHED_ARR+=("$p"); done < <(split_csv_lines "$WATCHED" true | LC_ALL=C sort -u)
    [[ ${#WATCHED_ARR[@]} -gt 0 ]] || { echo "FRESHNESS_FAIL: missing --watched-paths"; exit 1; }

    OWNED_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && OWNED_ARR+=("$p"); done < <(split_csv_lines "$OWNED" true | LC_ALL=C sort -u)

    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$TASK_BASE" HEAD 2>/dev/null; then
      echo "STALE: HEAD is not a descendant of task_base"
      exit 2
    fi

    COMMITTED_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" HEAD)" || { echo "GIT_ERROR: git diff failed"; exit 1; }
    COMMITTED_HITS=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
      if path_in_list "$p" "${WATCHED_ARR[@]}"; then
        COMMITTED_HITS+=("$p")
      fi
    done <<< "$COMMITTED_OUT"

    if [[ ${#COMMITTED_HITS[@]} -gt 0 ]]; then
      HITS_STR="$(printf '%s\n' "${COMMITTED_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      echo "STALE: committed change in watched_paths (${HITS_STR//,/, })"
      exit 2
    fi

    RO_ARR=()
    for p in "${WATCHED_ARR[@]}"; do
      if [[ ${#OWNED_ARR[@]} -eq 0 ]] || ! path_in_list "$p" "${OWNED_ARR[@]}"; then
        RO_ARR+=("$p")
      fi
    done

    if [[ ${#RO_ARR[@]} -gt 0 ]]; then
      WT_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT")" || { echo "GIT_ERROR: git diff working tree failed"; exit 1; }
      CA_OUT="$(git -C "$REPO_ROOT" diff --no-renames --cached --name-only)" || { echo "GIT_ERROR: git diff cached failed"; exit 1; }
      UN_OUT="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" || { echo "GIT_ERROR: git ls-files failed"; exit 1; }
      RO_HITS=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then
          continue
        fi
        if path_in_list "$p" "${RO_ARR[@]}"; then
          RO_HITS+=("$p")
        fi
      done < <(printf '%s\n%s\n%s\n' "$WT_OUT" "$CA_OUT" "$UN_OUT")

      if [[ ${#RO_HITS[@]} -gt 0 ]]; then
        HITS_STR="$(printf '%s\n' "${RO_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        echo "STALE: uncommitted change in read_only_deps (${HITS_STR//,/, })"
        exit 2
      fi
    fi

    echo "FRESH"
    ;;

  precommit)
    REPO_ROOT="."
    ALLOWED=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --allowed-paths) ALLOWED="${2:-}"; shift 2 ;;
        *) echo "PRECOMMIT_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    ALLOWED_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && ALLOWED_ARR+=("$p"); done < <(split_csv_lines "$ALLOWED" true | LC_ALL=C sort -u)

    STAGED_OUT="$(git -C "$REPO_ROOT" diff --no-renames --cached --name-only)" || { echo "GIT_ERROR: git diff cached failed"; exit 1; }
    STAGED_ARR=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -n "$p" ]] && STAGED_ARR+=("$p")
    done <<< "$STAGED_OUT"

    if [[ ${#STAGED_ARR[@]} -lt 1 ]]; then
      echo "PRECOMMIT_FAIL: nothing staged"
      exit 1
    fi

    CP_HITS=()
    for p in "${STAGED_ARR[@]}"; do
      if [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]]; then
        CP_HITS+=("$p")
      elif [[ "$p" == ".b3" || "$p" == ".b3/"* ]]; then
        if [[ ${#ALLOWED_ARR[@]} -eq 0 ]] || ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          CP_HITS+=("$p")
        fi
      fi
    done
    if [[ ${#CP_HITS[@]} -gt 0 ]]; then
      HITS_STR="$(printf '%s\n' "${CP_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      echo "PRECOMMIT_FAIL: checkpoint staged (${HITS_STR//,/, })"
      exit 1
    fi

    [[ ${#ALLOWED_ARR[@]} -gt 0 ]] || { echo "PRECOMMIT_FAIL: missing --allowed-paths"; exit 1; }

    BAD_HITS=()
    for p in "${STAGED_ARR[@]}"; do
      if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
        BAD_HITS+=("$p")
      fi
    done
    if [[ ${#BAD_HITS[@]} -gt 0 ]]; then
      HITS_STR="$(printf '%s\n' "${BAD_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      echo "PRECOMMIT_FAIL: undeclared staged path (${HITS_STR//,/, })"
      exit 1
    fi

    echo "PRECOMMIT_OK"
    ;;

  snapshot)
    REPO_ROOT="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "SNAPSHOT_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    SHA="$(git -C "$REPO_ROOT" stash create 2>/dev/null)" || { echo "SNAPSHOT_FAIL: git stash create failed"; exit 1; }
    SHA="$(trim_str "$SHA")"
    if [[ -z "$SHA" ]]; then
      SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || { echo "SNAPSHOT_FAIL: git rev-parse HEAD failed"; exit 1; }
      SHA="$(trim_str "$SHA")"
    fi
    OBJ_TYPE="$(git -C "$REPO_ROOT" cat-file -t "$SHA" 2>/dev/null || true)"
    if [[ "$OBJ_TYPE" != "commit" ]]; then
      echo "SNAPSHOT_FAIL: invalid snapshot commit '$SHA'"
      exit 1
    fi
    printf '%s\n' "$SHA"
    ;;

  diff-scope)
    REPO_ROOT="."
    BASE_SHA=""
    PREV_SHA=""
    TARGET_REF=""
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --prev-sha) PREV_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "DIFF_SCOPE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! TARGET_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}" 2>/dev/null)"; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$TARGET_COMMIT_SHA")"
      if [[ -z "$TARGET_COMMIT_SHA" ]]; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
    fi

    BASE_SHA="$(trim_str "$BASE_SHA")"
    if [[ -z "$BASE_SHA" || "$BASE_SHA" == "auto" ]]; then
      if [[ -n "$TARGET_REF" ]]; then
        BASE_SHA="$(resolve_auto_base_for_target "$REPO_ROOT" "$TARGET_COMMIT_SHA")"
      elif [[ ${#IGNORE_ARR[@]} -gt 0 ]]; then
        BASE_SHA="$(resolve_auto_base_sha "$REPO_ROOT" "${IGNORE_ARR[@]}")"
      else
        BASE_SHA="$(resolve_auto_base_sha "$REPO_ROOT")"
      fi
    fi

    if [[ -n "$TARGET_REF" ]]; then
      NUMSTAT_OUT="$(git -C "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed"; exit 1; }
      UNTRACKED_OUT=""
    else
      NUMSTAT_OUT="$(git -C "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA")" || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed"; exit 1; }
      UNTRACKED_OUT="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" || { echo "DIFF_SCOPE_FAIL: git ls-files failed"; exit 1; }
    fi

    REVIEW_ARR=()
    NOISE_ARR=()
    TOTAL_LINES=0

    while IFS=$'\t' read -r add del raw_path; do
      [[ -n "${raw_path:-}" ]] || continue
      p="$(norm_path "$raw_path")"
      [[ -z "$p" ]] && continue
      [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        NOISE_ARR+=("$p")
        continue
      fi
      REVIEW_ARR+=("$p")
      [[ "$add" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + add))
      [[ "$del" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + del))
    done <<< "$NUMSTAT_OUT"

    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        NOISE_ARR+=("$p")
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! path_in_list "$p" "${REVIEW_ARR[@]}"; then
        REVIEW_ARR+=("$p")
        if [[ -f "${REPO_ROOT}/${p}" ]]; then
          lc="$(wc -l < "${REPO_ROOT}/${p}" | tr -d ' ')"
          TOTAL_LINES=$((TOTAL_LINES + lc))
        fi
      fi
    done <<< "$UNTRACKED_OUT"

    PREV_SHA="$(trim_str "$PREV_SHA")"
    HAS_PREV=false
    DF_OUT="none"
    if [[ -n "$PREV_SHA" ]]; then
      HAS_PREV=true
      if [[ -n "$TARGET_REF" ]]; then
        DELTA_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed"; exit 1; }
      else
        DELTA_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA")" || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed"; exit 1; }
      fi
      DELTA_ARR=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
        if is_noise_file "$p"; then continue; fi
        DELTA_ARR+=("$p")
      done < <(printf '%s\n%s\n' "$DELTA_OUT" "$UNTRACKED_OUT")
      if [[ ${#DELTA_ARR[@]} -gt 0 ]]; then
        DF_OUT="$(printf '%s\n' "${DELTA_ARR[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      fi
    fi

    if [[ ${#REVIEW_ARR[@]} -eq 0 && ${#NOISE_ARR[@]} -eq 0 ]]; then
      echo "EMPTY_DIFF"
      exit 2
    fi

    FILE_COUNT=0
    RF_OUT="none"
    if [[ ${#REVIEW_ARR[@]} -gt 0 ]]; then
      RF_SORTED="$(printf '%s\n' "${REVIEW_ARR[@]}" | LC_ALL=C sort -u)"
      FILE_COUNT="$(printf '%s\n' "$RF_SORTED" | wc -l | tr -d ' ')"
      RF_OUT="$(printf '%s\n' "$RF_SORTED" | paste -sd ',' -)"
    fi

    NF_OUT="none"
    if [[ ${#NOISE_ARR[@]} -gt 0 ]]; then
      NF_OUT="$(printf '%s\n' "${NOISE_ARR[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    fi

    if [[ "$FILE_COUNT" -eq 0 ]]; then
      SIZE_CLASS="NOISE_ONLY"
    elif [[ "$FILE_COUNT" -le 8 && "$TOTAL_LINES" -le 300 ]]; then
      SIZE_CLASS="SMALL"
    elif [[ "$FILE_COUNT" -le 20 && "$TOTAL_LINES" -le 800 ]]; then
      SIZE_CLASS="MEDIUM"
    elif [[ "$FILE_COUNT" -lt 50 && "$TOTAL_LINES" -lt 2000 ]]; then
      SIZE_CLASS="LARGE"
    else
      SIZE_CLASS="VERY_LARGE"
    fi

    printf 'size_class=%s\nfiles=%s\nlines=%s\nreview_files=%s\nnoise_files=%s\n' "$SIZE_CLASS" "$FILE_COUNT" "$TOTAL_LINES" "$RF_OUT" "$NF_OUT"
    if $HAS_PREV; then
      printf 'delta_files=%s\n' "$DF_OUT"
    fi
    ;;

  mechanical-check)
    REPO_ROOT="."
    BASE_SHA=""
    TARGET_REF=""
    ALLOWED=""
    IGNORE_DIRTY=""
    OBSOLETES=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --allowed-paths) ALLOWED="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --obsoletes) OBSOLETES="${2:-}"; shift 2 ;;
        *) echo "MECHANICAL_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    ALLOWED_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && ALLOWED_ARR+=("$p"); done < <(split_csv_lines "$ALLOWED" true | LC_ALL=C sort -u)
    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)
    OBS_ARR=()
    while IFS= read -r tok; do [[ -n "$tok" ]] && OBS_ARR+=("$tok"); done < <(split_csv_lines "$OBSOLETES" false)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! TARGET_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}" 2>/dev/null)"; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$TARGET_COMMIT_SHA")"
      if [[ -z "$TARGET_COMMIT_SHA" ]]; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
    fi

    BASE_SHA="$(trim_str "$BASE_SHA")"
    if [[ -z "$BASE_SHA" || "$BASE_SHA" == "auto" ]]; then
      if [[ -n "$TARGET_REF" ]]; then
        BASE_SHA="$(resolve_auto_base_for_target "$REPO_ROOT" "$TARGET_COMMIT_SHA")"
      elif [[ ${#IGNORE_ARR[@]} -gt 0 ]]; then
        BASE_SHA="$(resolve_auto_base_sha "$REPO_ROOT" "${IGNORE_ARR[@]}")"
      else
        BASE_SHA="$(resolve_auto_base_sha "$REPO_ROOT")"
      fi
    fi

    if [[ -n "$TARGET_REF" ]]; then
      CH_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "MECHANICAL_FAIL: git diff --name-only failed"; exit 1; }
      UN_OUT=""
    else
      CH_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA")" || { echo "MECHANICAL_FAIL: git diff --name-only failed"; exit 1; }
      UN_OUT="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" || { echo "MECHANICAL_FAIL: git ls-files failed"; exit 1; }
    fi

    ALL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      [[ "$p" == ".b3/ship" || "$p" == ".b3/ship/"* ]] && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      ALL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$CH_OUT" "$UN_OUT")

    SCOPE_CREEP=()
    if [[ ${#ALLOWED_ARR[@]} -gt 0 && ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          SCOPE_CREEP+=("$p")
        fi
      done
    fi

    if [[ -n "$TARGET_REF" ]]; then
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "MECHANICAL_FAIL: git diff -U0 failed"; exit 1; }
    else
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA")" || { echo "MECHANICAL_FAIL: git diff -U0 failed"; exit 1; }
    fi
    LEFTOVER_HITS=()
    CUR_FILE=""
    CUR_LINE=0
    SKIP_FILE=true
    IN_HUNK=false
    while IFS= read -r ln; do
      ln="${ln%$'\r'}"
      if [[ "$ln" == "diff --git "* ]]; then
        CUR_FILE=""
        SKIP_FILE=true
        IN_HUNK=false
        continue
      fi
      if ! $IN_HUNK && [[ "$ln" == "+++ "* ]]; then
        if [[ "$ln" == "+++ /dev/null" ]]; then
          CUR_FILE=""
          SKIP_FILE=true
        else
          cand="${ln#+++ }"
          cand="${cand#b/}"
          CUR_FILE="$(norm_path "$cand")"
          SKIP_FILE=false
          if [[ -z "$CUR_FILE" || "$CUR_FILE" == ".b3/ship" || "$CUR_FILE" == ".b3/ship/"* || "$CUR_FILE" == *.md ]]; then
            SKIP_FILE=true
          elif is_noise_file "$CUR_FILE"; then
            SKIP_FILE=true
          elif [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$CUR_FILE" "${IGNORE_ARR[@]}"; then
            SKIP_FILE=true
          fi
        fi
        continue
      fi
      if [[ "$ln" =~ ^@@\ -[0-9,]+\ \+([0-9]+)(,[0-9]+)?\ @@ ]]; then
        CUR_LINE="${BASH_REMATCH[1]}"
        IN_HUNK=true
        continue
      fi
      if ! $IN_HUNK || $SKIP_FILE; then continue; fi
      if [[ "$ln" == "+"* ]]; then
        body="${ln#+}"
        tag="$(find_leftover_tag "$body")"
        if [[ -n "$tag" && ${#LEFTOVER_HITS[@]} -lt 10 ]]; then
          LEFTOVER_HITS+=("${CUR_FILE}:${CUR_LINE}:${tag}")
        fi
        CUR_LINE=$((CUR_LINE + 1))
      fi
    done <<< "$DIFF_U0"

    UN_SORTED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -n "$p" ]] && UN_SORTED+=("$p")
    done < <(printf '%s\n' "$UN_OUT" | LC_ALL=C sort -u)

    if [[ ${#UN_SORTED[@]} -gt 0 ]]; then
      for u in "${UN_SORTED[@]}"; do
        [[ ${#LEFTOVER_HITS[@]} -ge 10 ]] && break
        [[ "$u" == ".b3/ship" || "$u" == ".b3/ship/"* || "$u" == *.md ]] && continue
        is_noise_file "$u" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
        [[ -f "${REPO_ROOT}/${u}" ]] || continue
        lno=0
        while IFS= read -r fl || [[ -n "$fl" ]]; do
          lno=$((lno + 1))
          fl="${fl%$'\r'}"
          tag="$(find_leftover_tag "$fl")"
          if [[ -n "$tag" && ${#LEFTOVER_HITS[@]} -lt 10 ]]; then
            LEFTOVER_HITS+=("${u}:${lno}:${tag}")
          fi
        done < "${REPO_ROOT}/${u}"
      done
    fi

    OBS_HITS=()
    if [[ ${#OBS_ARR[@]} -gt 0 ]]; then
      for tok in "${OBS_ARR[@]}"; do
        norm_tok="$(norm_path "$tok")"
        exists_path=false
        if [[ -n "$norm_tok" ]]; then
          if [[ -n "$TARGET_REF" ]]; then
            if git -C "$REPO_ROOT" cat-file -e "${TARGET_COMMIT_SHA}:${norm_tok}" 2>/dev/null; then
              exists_path=true
            fi
          elif [[ -e "${REPO_ROOT}/${norm_tok}" ]]; then
            exists_path=true
          fi
        fi
        set +e
        if [[ -n "$TARGET_REF" ]]; then
          grep_out="$(git -C "$REPO_ROOT" grep -l -F -e "$tok" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3/ship' 2>/dev/null)"
        else
          grep_out="$(git -C "$REPO_ROOT" grep -l -F -e "$tok" -- . ':(exclude).b3/ship' 2>/dev/null)"
        fi
        grep_code=$?
        set -e
        if [[ "$grep_code" -gt 1 ]]; then
          echo "MECHANICAL_FAIL: git grep failed for obsolete '$tok'"
          exit 1
        fi
        grep_count=0
        if [[ "$grep_code" -eq 0 && -n "$grep_out" ]]; then
          grep_count="$(printf '%s\n' "$grep_out" | wc -l | tr -d ' ')"
        fi
        if $exists_path && [[ "$grep_count" -gt 0 ]]; then
          OBS_HITS+=("${tok}(exists+${grep_count}f)")
        elif $exists_path; then
          OBS_HITS+=("${tok}(exists)")
        elif [[ "$grep_count" -gt 0 ]]; then
          OBS_HITS+=("${tok}(${grep_count}f)")
        fi
      done
    fi

    SC_OUT="none"
    if [[ ${#SCOPE_CREEP[@]} -gt 0 ]]; then
      SC_OUT="$(printf '%s\n' "${SCOPE_CREEP[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    fi
    LO_OUT="none"
    if [[ ${#LEFTOVER_HITS[@]} -gt 0 ]]; then
      LO_OUT="$(IFS=','; echo "${LEFTOVER_HITS[*]}")"
    fi
    OB_OUT="none"
    if [[ ${#OBS_HITS[@]} -gt 0 ]]; then
      OB_OUT="$(printf '%s\n' "${OBS_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    fi

    printf 'scope_creep=%s\nleftovers=%s\nobsolete_hits=%s\n' "$SC_OUT" "$LO_OUT" "$OB_OUT"
    if [[ "$SC_OUT" == "none" && "$LO_OUT" == "none" && "$OB_OUT" == "none" ]]; then
      echo "MECHANICAL_OK"
      exit 0
    fi
    echo "MECHANICAL_FINDINGS"
    exit 2
    ;;

  check-wave)
    WAVE_SPECS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --wave-specs) WAVE_SPECS="${2:-}"; shift 2 ;;
        *) echo "WAVE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    WAVE_SPECS="$(trim_str "$WAVE_SPECS")"
    [[ -n "$WAVE_SPECS" ]] || { echo "WAVE_FAIL: missing --wave-specs"; exit 1; }

    TASK_IDS=()
    TASK_PATHS_PACKED=()
    TOTAL_PATHS=0
    IFS=';' read -ra ENTRIES <<< "$WAVE_SPECS"
    if [[ ${#ENTRIES[@]} -gt 0 ]]; then
      for entry in "${ENTRIES[@]}"; do
        trim_e="$(trim_str "$entry")"
        [[ -z "$trim_e" ]] && continue
        if [[ "$trim_e" != *"="* ]]; then
          echo "WAVE_FAIL: invalid entry '$trim_e' (expected TaskId=path1,path2)"
          exit 1
        fi
        tid="$(trim_str "${trim_e%%=*}")"
        raw_csv="${trim_e#*=}"
        [[ -n "$tid" ]] || { echo "WAVE_FAIL: empty task id in '$trim_e'"; exit 1; }
        if [[ ${#TASK_IDS[@]} -gt 0 ]]; then
          for prev_t in "${TASK_IDS[@]}"; do
            if [[ "$prev_t" == "$tid" ]]; then
              echo "WAVE_FAIL: duplicate task id '$tid'"
              exit 1
            fi
          done
        fi
        p_arr=()
        while IFS= read -r p; do [[ -n "$p" ]] && p_arr+=("$p"); done < <(split_csv_lines "$raw_csv" true | LC_ALL=C sort -u)
        if [[ ${#p_arr[@]} -lt 1 ]]; then
          echo "WAVE_FAIL: task '$tid' has no owned paths"
          exit 1
        fi
        TASK_IDS+=("$tid")
        packed="$(printf '%s\n' "${p_arr[@]}" | paste -sd '|' -)"
        TASK_PATHS_PACKED+=("$packed")
        TOTAL_PATHS=$((TOTAL_PATHS + ${#p_arr[@]}))
      done
    fi
    [[ ${#TASK_IDS[@]} -gt 0 ]] || { echo "WAVE_FAIL: no tasks in --wave-specs"; exit 1; }

    CONFLICTS=()
    n_tasks="${#TASK_IDS[@]}"
    for ((i = 0; i < n_tasks; i++)); do
      for ((j = i + 1; j < n_tasks; j++)); do
        ti="${TASK_IDS[$i]}"
        tj="${TASK_IDS[$j]}"
        IFS='|' read -ra pi_arr <<< "${TASK_PATHS_PACKED[$i]}"
        IFS='|' read -ra pj_arr <<< "${TASK_PATHS_PACKED[$j]}"
        for pi in "${pi_arr[@]}"; do
          for pj in "${pj_arr[@]}"; do
            if [[ "$pi" == "$pj" ]]; then
              CONFLICTS+=("${pi}(${ti},${tj})")
            elif [[ "$pi" == "." || "$pj" == "." || "$pi" == "$pj/"* || "$pj" == "$pi/"* ]]; then
              CONFLICTS+=("${pi}<->${pj}(${ti},${tj})")
            fi
          done
        done
      done
    done

    if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
      C_STR="$(printf '%s\n' "${CONFLICTS[@]}" | LC_ALL=C sort -u | awk 'NR>1{printf ", "} {printf "%s", $0}')"
      echo "WAVE_CONFLICT: ${C_STR}"
      exit 2
    fi
    printf 'WAVE_OK: disjoint (%d tasks, %d paths)\n' "$n_tasks" "$TOTAL_PATHS"
    exit 0
    ;;

  new-run)
    REPO_ROOT="."
    SLUG=""
    TS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --slug) SLUG="${2:-}"; shift 2 ;;
        --timestamp) TS="${2:-}"; shift 2 ;;
        *) echo "NEW_RUN_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    SLUG="$(trim_str "$SLUG")"
    [[ -n "$SLUG" ]] || { echo "NEW_RUN_FAIL: missing --slug"; exit 1; }
    CLEAN_SLUG="$(sanitize_slug "$SLUG")"
    [[ -n "$CLEAN_SLUG" ]] || { echo "NEW_RUN_FAIL: slug has no alphanumeric characters"; exit 1; }

    if [[ -z "$TS" ]]; then
      TS="$(date +%Y%m%d-%H%M)"
    else
      TS="$(trim_str "$TS")"
    fi
    if [[ ! "$TS" =~ ^[0-9]{8}-[0-9]{4}$ ]]; then
      echo "NEW_RUN_FAIL: invalid timestamp '$TS' (expected YYYYMMDD-HHMM)"
      exit 1
    fi

    SHIP_DIR="${REPO_ROOT}/.b3/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    mkdir -p "$RUNS_DIR"

    BASE_ID="${TS}-${CLEAN_SLUG}"
    CANDIDATE="$BASE_ID"
    SUFFIX=2
    while [[ -e "${RUNS_DIR}/${CANDIDATE}" ]]; do
      CANDIDATE="${BASE_ID}-${SUFFIX}"
      SUFFIX=$((SUFFIX + 1))
    done

    mkdir -p "${RUNS_DIR}/${CANDIDATE}"
    printf '%s\n' "$CANDIDATE" > "${SHIP_DIR}/CURRENT"
    printf '%s\n' "$CANDIDATE"
    ;;

  resolve-run)
    REPO_ROOT="."
    RUN_ID=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        *) echo "RESOLVE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    SHIP_DIR="${REPO_ROOT}/.b3/ship"
    RUNS_DIR="${SHIP_DIR}/runs"

    if [[ -n "$RUN_ID" ]]; then
      RUN_ID="$(trim_str "$RUN_ID")"
      valid_run_id "$RUN_ID" || { echo "RESOLVE_FAIL: invalid run id '$RUN_ID'"; exit 1; }
      [[ -d "${RUNS_DIR}/${RUN_ID}" ]] || { echo "RESOLVE_FAIL: run not found '$RUN_ID'"; exit 1; }
      printf '.b3/ship/runs/%s\n' "$RUN_ID"
      exit 0
    fi

    CUR_FILE="${SHIP_DIR}/CURRENT"
    if [[ -f "$CUR_FILE" ]]; then
      CUR_ID="$(read_current_run_id "$SHIP_DIR")"
      valid_run_id "$CUR_ID" || { echo "RESOLVE_FAIL: CURRENT contains invalid run id '$CUR_ID'"; exit 1; }
      [[ -d "${RUNS_DIR}/${CUR_ID}" ]] || { echo "RESOLVE_FAIL: CURRENT points to missing run '$CUR_ID'"; exit 1; }
      printf '.b3/ship/runs/%s\n' "$CUR_ID"
      exit 0
    fi

    if [[ -f "${SHIP_DIR}/progress.md" ]]; then
      printf '.b3/ship\n'
      exit 0
    fi

    echo "NO_ACTIVE_RUN"
    exit 1
    ;;

  list-runs)
    REPO_ROOT="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "LIST_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    SHIP_DIR="${REPO_ROOT}/.b3/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    CUR_ID="$(read_current_run_id "$SHIP_DIR")"

    RUN_NAMES=()
    if [[ -d "$RUNS_DIR" ]]; then
      while IFS= read -r d; do
        [[ -n "$d" ]] && RUN_NAMES+=("$d")
      done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)
    fi

    if [[ ${#RUN_NAMES[@]} -eq 0 ]]; then
      if [[ -f "${SHIP_DIR}/progress.md" ]]; then
        ST="$(read_run_status "$SHIP_DIR")"
        printf '* legacy [%s]\n' "$ST"
      else
        echo "NO_RUNS"
      fi
      exit 0
    fi

    for id in "${RUN_NAMES[@]}"; do
      ST="$(read_run_status "${RUNS_DIR}/${id}")"
      MARK="  "
      if [[ -n "$CUR_ID" && "$id" == "$CUR_ID" ]]; then
        MARK="* "
      fi
      printf '%s%s [%s]\n' "$MARK" "$id" "$ST"
    done
    ;;

  prune)
    REPO_ROOT="."
    KEEP=10
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --keep) KEEP="${2:-}"; shift 2 ;;
        *) echo "PRUNE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    if [[ ! "$KEEP" =~ ^[0-9]+$ ]]; then
      echo "PRUNE_FAIL: --keep must be >= 0"
      exit 1
    fi

    SHIP_DIR="${REPO_ROOT}/.b3/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    if [[ ! -d "$RUNS_DIR" ]]; then
      echo "PRUNE_OK: 0 removed"
      exit 0
    fi

    CUR_ID="$(read_current_run_id "$SHIP_DIR")"
    RUN_NAMES=()
    while IFS= read -r d; do
      [[ -n "$d" ]] && RUN_NAMES+=("$d")
    done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)

    PASS_COUNT=0
    PRUNED=()
    if [[ ${#RUN_NAMES[@]} -gt 0 ]]; then
      for id in "${RUN_NAMES[@]}"; do
        ST="$(read_run_status "${RUNS_DIR}/${id}")"
        if [[ "$ST" == "PASS" ]]; then
          PASS_COUNT=$((PASS_COUNT + 1))
          if [[ $PASS_COUNT -gt $KEEP && "$id" != "$CUR_ID" ]]; then
            rm -rf "${RUNS_DIR:?}/${id}"
            PRUNED+=("$id")
          fi
        fi
      done
    fi

    if [[ ${#PRUNED[@]} -eq 0 ]]; then
      echo "PRUNE_OK: 0 removed"
    else
      for p in "${PRUNED[@]}"; do
        printf 'pruned: %s\n' "$p"
      done
      printf 'PRUNE_OK: %d removed\n' "${#PRUNED[@]}"
    fi
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
