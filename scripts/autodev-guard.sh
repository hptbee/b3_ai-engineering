#!/usr/bin/env bash
# Deterministic helper checks for /autodev (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot
set -euo pipefail

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot [options]" >&2
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
      for part in "${parts[@]}"; do
        t="$(trim_str "$part")"
        [[ -n "$t" ]] && CRIT_FLAT+=("$t")
      done
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

    COMMITTED_OUT="$(git -C "$REPO_ROOT" diff --name-only "$APPROACH_AT" HEAD)" || { echo "GIT_ERROR: git diff failed"; exit 1; }
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
      WT_OUT="$(git -C "$REPO_ROOT" diff --name-only "$APPROACH_AT")" || { echo "GIT_ERROR: git diff working tree failed"; exit 1; }
      CA_OUT="$(git -C "$REPO_ROOT" diff --cached --name-only)" || { echo "GIT_ERROR: git diff cached failed"; exit 1; }
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

    STAGED_OUT="$(git -C "$REPO_ROOT" diff --cached --name-only)" || { echo "GIT_ERROR: git diff cached failed"; exit 1; }
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

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
