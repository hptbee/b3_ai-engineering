#!/usr/bin/env bash
# Deterministic helper checks for /autodev and /review-loop (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot | diff-scope | new-run | resolve-run | list-runs | prune
set -euo pipefail

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|new-run|resolve-run|list-runs|prune [options]" >&2
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
      [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]] && continue
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
        [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]] && continue
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
      if [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]]; then
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
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --prev-sha) PREV_SHA="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "DIFF_SCOPE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    [[ -n "$BASE_SHA" ]] || { echo "DIFF_SCOPE_FAIL: missing --base-sha"; exit 1; }

    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    NUMSTAT_OUT="$(git -C "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA")" || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed"; exit 1; }
    UNTRACKED_OUT="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" || { echo "DIFF_SCOPE_FAIL: git ls-files failed"; exit 1; }

    REVIEW_ARR=()
    NOISE_ARR=()
    TOTAL_LINES=0

    while IFS=$'\t' read -r add del raw_path; do
      [[ -n "${raw_path:-}" ]] || continue
      p="$(norm_path "$raw_path")"
      [[ -z "$p" ]] && continue
      [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]] && continue
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
      [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]] && continue
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
      DELTA_OUT="$(git -C "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA")" || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed"; exit 1; }
      DELTA_ARR=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        [[ "$p" == ".b3/autodev" || "$p" == ".b3/autodev/"* ]] && continue
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
    elif [[ "$FILE_COUNT" -le 50 && "$TOTAL_LINES" -le 2000 ]]; then
      SIZE_CLASS="LARGE"
    else
      SIZE_CLASS="VERY_LARGE"
    fi

    printf 'size_class=%s\nfiles=%s\nlines=%s\nreview_files=%s\nnoise_files=%s\n' "$SIZE_CLASS" "$FILE_COUNT" "$TOTAL_LINES" "$RF_OUT" "$NF_OUT"
    if $HAS_PREV; then
      printf 'delta_files=%s\n' "$DF_OUT"
    fi
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

    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    RUNS_DIR="${AUTODEV_DIR}/runs"
    mkdir -p "$RUNS_DIR"

    BASE_ID="${TS}-${CLEAN_SLUG}"
    CANDIDATE="$BASE_ID"
    SUFFIX=2
    while [[ -e "${RUNS_DIR}/${CANDIDATE}" ]]; do
      CANDIDATE="${BASE_ID}-${SUFFIX}"
      SUFFIX=$((SUFFIX + 1))
    done

    mkdir -p "${RUNS_DIR}/${CANDIDATE}"
    printf '%s\n' "$CANDIDATE" > "${AUTODEV_DIR}/CURRENT"
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
    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    RUNS_DIR="${AUTODEV_DIR}/runs"

    if [[ -n "$RUN_ID" ]]; then
      RUN_ID="$(trim_str "$RUN_ID")"
      valid_run_id "$RUN_ID" || { echo "RESOLVE_FAIL: invalid run id '$RUN_ID'"; exit 1; }
      [[ -d "${RUNS_DIR}/${RUN_ID}" ]] || { echo "RESOLVE_FAIL: run not found '$RUN_ID'"; exit 1; }
      printf '.b3/autodev/runs/%s\n' "$RUN_ID"
      exit 0
    fi

    CUR_FILE="${AUTODEV_DIR}/CURRENT"
    if [[ -f "$CUR_FILE" ]]; then
      CUR_ID="$(read_current_run_id "$AUTODEV_DIR")"
      valid_run_id "$CUR_ID" || { echo "RESOLVE_FAIL: CURRENT contains invalid run id '$CUR_ID'"; exit 1; }
      [[ -d "${RUNS_DIR}/${CUR_ID}" ]] || { echo "RESOLVE_FAIL: CURRENT points to missing run '$CUR_ID'"; exit 1; }
      printf '.b3/autodev/runs/%s\n' "$CUR_ID"
      exit 0
    fi

    if [[ -f "${AUTODEV_DIR}/progress.md" ]]; then
      printf '.b3/autodev\n'
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
    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    RUNS_DIR="${AUTODEV_DIR}/runs"
    CUR_ID="$(read_current_run_id "$AUTODEV_DIR")"

    RUN_NAMES=()
    if [[ -d "$RUNS_DIR" ]]; then
      while IFS= read -r d; do
        [[ -n "$d" ]] && RUN_NAMES+=("$d")
      done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)
    fi

    if [[ ${#RUN_NAMES[@]} -eq 0 ]]; then
      if [[ -f "${AUTODEV_DIR}/progress.md" ]]; then
        ST="$(read_run_status "$AUTODEV_DIR")"
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

    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    RUNS_DIR="${AUTODEV_DIR}/runs"
    if [[ ! -d "$RUNS_DIR" ]]; then
      echo "PRUNE_OK: 0 removed"
      exit 0
    fi

    CUR_ID="$(read_current_run_id "$AUTODEV_DIR")"
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
