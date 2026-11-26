#!/usr/bin/env bash
# Deterministic helper checks for /b3-ship and /b3-review-loop (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot | diff-scope | mechanical-check | check-wave | new-run | resolve-run | list-runs | prune | verify-run | verify-check | symbol-check | check-worktree | review-inventory | review-ledger | evidence-check | merge-policy-check | context-cache
set -euo pipefail

_B3_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_CLEANUP_FILES=()
_cleanup_tmp() {
  if [[ ${#_CLEANUP_FILES[@]} -gt 0 ]]; then
    local f
    for f in "${_CLEANUP_FILES[@]}"; do
      [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
  fi
}
trap _cleanup_tmp EXIT

_TMP_FILE=""
make_temp_file() {
  local _mtf_prefix="$1" _mtf_var="${2:-}" _mtf_f
  _mtf_f="$(mktemp "${TMPDIR:-/tmp}/${_mtf_prefix}.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/${_mtf_prefix}.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$_mtf_f")
  _TMP_FILE="$_mtf_f"
  if [[ -n "$_mtf_var" ]]; then
    printf -v "$_mtf_var" '%s' "$_mtf_f"
  fi
}

_GIT_STDOUT=""
_GIT_STDERR=""
_B3_GIT_ERR_FILE=""
make_temp_file "b3-git-err" _B3_GIT_ERR_FILE

_run_git_cmd_core() {
  local root="$1" idx_file="$2" stdin_mode="$3" stdin_val="$4"
  shift 4
  local rc=0
  _GIT_STDOUT=""
  _GIT_STDERR=""
  local -a _lit_args=(--literal-pathspecs)
  local _ga=""
  for _ga in "$@"; do
    [[ "$_ga" == "--" ]] && break
    if [[ "$_ga" == "grep" ]]; then _lit_args=(); break; fi
  done
  if [[ "$stdin_mode" == "quiet" ]]; then
    if [[ -n "$idx_file" ]]; then
      if _GIT_STDOUT="$(GIT_INDEX_FILE="$idx_file" git -C "$root" ${_lit_args[@]+"${_lit_args[@]}"} -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" 2>/dev/null)"; then rc=0; else rc=$?; fi
    else
      if _GIT_STDOUT="$(git -C "$root" ${_lit_args[@]+"${_lit_args[@]}"} -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" 2>/dev/null)"; then rc=0; else rc=$?; fi
    fi
    return $rc
  elif [[ "$stdin_mode" == "file" ]]; then
    if _GIT_STDOUT="$(git -C "$root" ${_lit_args[@]+"${_lit_args[@]}"} -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" < "$stdin_val" 2>"$_B3_GIT_ERR_FILE")"; then rc=0; else rc=$?; fi
  elif [[ -n "$idx_file" ]]; then
    if _GIT_STDOUT="$(GIT_INDEX_FILE="$idx_file" git -C "$root" ${_lit_args[@]+"${_lit_args[@]}"} -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" 2>"$_B3_GIT_ERR_FILE")"; then rc=0; else rc=$?; fi
  else
    if _GIT_STDOUT="$(git -C "$root" ${_lit_args[@]+"${_lit_args[@]}"} -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" 2>"$_B3_GIT_ERR_FILE")"; then rc=0; else rc=$?; fi
  fi
  if [[ $rc -ne 0 && -f "$_B3_GIT_ERR_FILE" ]]; then
    _GIT_STDERR="$(< "$_B3_GIT_ERR_FILE")"
  fi
  return $rc
}

run_git_cmd() { local root="$1"; shift; _run_git_cmd_core "$root" "" "none" "" "$@"; }
run_git_cmd_quiet() { local root="$1"; shift; _run_git_cmd_core "$root" "" "quiet" "" "$@"; }
run_git_cmd_with_index() { local root="$1" idx_file="$2"; shift 2; _run_git_cmd_core "$root" "$idx_file" "none" "" "$@"; }
run_git_cmd_from_file() { local root="$1" stdin_file="$2"; shift 2; _run_git_cmd_core "$root" "" "file" "$stdin_file" "$@"; }

_REPO_CASE_INSENSITIVE="false"
detect_repo_case_insensitive() {
  local root="$1" v=""
  _REPO_CASE_INSENSITIVE="$_B3_IS_CASE_INSENSITIVE_FS"
  if [[ -n "$root" && -d "$root" ]] && run_git_cmd_quiet "$root" config --bool core.ignorecase; then
    v="$(printf '%s' "$_GIT_STDOUT" | tr -d '\r\n ' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$v" == "true" ]]; then
      _REPO_CASE_INSENSITIVE="true"
      return 0
    elif [[ "$v" == "false" ]]; then
      _REPO_CASE_INSENSITIVE="false"
      return 0
    fi
  fi
}

has_ascii_cntrl() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  local cleaned="${s//[$'\x01'-$'\x1f'$'\x7f']/}"
  [[ "$cleaned" != "$s" ]]
}

is_valid_literal_git_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  if has_ascii_cntrl "$p"; then
    return 1
  fi
  [[ "$p" != /* ]] || return 1
  local rem="$p" seg
  while true; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    if [[ -z "$seg" || "$seg" == "." || "$seg" == ".." ]]; then
      return 1
    fi
    [[ -n "$rem" ]] || break
  done
  return 0
}

_GIT_PATHS_Z=()
run_git_paths_z() {
  local root="$1" mode="$2" fail_pfx="$3" idx_file="$4"
  shift 4
  [[ "${1:-}" == "--" ]] && shift
  _GIT_PATHS_Z=()
  local z_tmp rc=0
  make_temp_file "b3-gpz" z_tmp
  if [[ -n "$idx_file" ]]; then
    if GIT_INDEX_FILE="$idx_file" git -C "$root" --literal-pathspecs -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" >"$z_tmp" 2>"$_B3_GIT_ERR_FILE"; then rc=0; else rc=$?; fi
  else
    if git -C "$root" --literal-pathspecs -c core.quotepath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ "$@" >"$z_tmp" 2>"$_B3_GIT_ERR_FILE"; then rc=0; else rc=$?; fi
  fi
  if [[ $rc -ne 0 ]]; then
    _GIT_STDERR=""
    [[ -f "$_B3_GIT_ERR_FILE" ]] && _GIT_STDERR="$(< "$_B3_GIT_ERR_FILE")"
    rm -f "$z_tmp" 2>/dev/null || true
    echo "${fail_pfx}: git ${1:-cmd} failed: $(git_err_detail)"
    return 1
  fi

  local -a toks=()
  local tok=""
  while IFS= read -r -d '' tok; do
    toks+=("$tok")
  done < "$z_tmp"
  rm -f "$z_tmp" 2>/dev/null || true

  local n=${#toks[@]} i=0 seen=$'\x1f'
  _add_lit_z() {
    local pv="$1"
    [[ ${#pv} -gt 1 && "$pv" == */ ]] && pv="${pv%/}"
    if ! is_valid_literal_git_path "$pv"; then
      echo "${fail_pfx}: unsupported_literal_git_path"
      return 1
    fi
    if [[ "$seen" != *$'\x1f'"${pv}"$'\x1f'* ]]; then
      seen+="${pv}"$'\x1f'
      _GIT_PATHS_Z+=("$pv")
    fi
    return 0
  }

  case "$mode" in
    names|ls-tree-z)
      for ((i = 0; i < n; i++)); do
        _add_lit_z "${toks[$i]}" || return 1
      done
      ;;
    name-status-z)
      local st="" p1="" p2=""
      while ((i < n)); do
        st="${toks[$i]}"; i=$((i + 1))
        if [[ -z "$st" ]] || has_ascii_cntrl "$st"; then
          echo "${fail_pfx}: git_parser_failed(name-status)"
          return 1
        fi
        if ((i >= n)); then
          echo "${fail_pfx}: git_parser_failed(name-status)"
          return 1
        fi
        p1="${toks[$i]}"; i=$((i + 1))
        _add_lit_z "$p1" || return 1
        if [[ "$st" == R* || "$st" == C* ]]; then
          if ((i >= n)); then
            echo "${fail_pfx}: git_parser_failed(name-status-rename)"
            return 1
          fi
          p2="${toks[$i]}"; i=$((i + 1))
          _add_lit_z "$p2" || return 1
        fi
      done
      ;;
    status-z)
      local rec="" xy="" p1="" p2=""
      while ((i < n)); do
        rec="${toks[$i]}"; i=$((i + 1))
        if [[ ${#rec} -lt 4 || "${rec:2:1}" != " " ]]; then
          echo "${fail_pfx}: git_parser_failed(status-z)"
          return 1
        fi
        xy="${rec:0:2}"
        p1="${rec:3}"
        [[ ${#p1} -gt 1 && "$p1" == */ ]] && p1="${p1%/}"
        _add_lit_z "$p1" || return 1
        if [[ "$xy" == *R* || "$xy" == *C* ]]; then
          if ((i >= n)); then
            echo "${fail_pfx}: git_parser_failed(status-z-rename)"
            return 1
          fi
          p2="${toks[$i]}"; i=$((i + 1))
          [[ ${#p2} -gt 1 && "$p2" == */ ]] && p2="${p2%/}"
          _add_lit_z "$p2" || return 1
        fi
      done
      ;;
    ls-tree-full-z|ls-files-stage-z)
      local rec="" p=""
      for ((i = 0; i < n; i++)); do
        rec="${toks[$i]}"
        if [[ "$rec" != *$'\t'* ]]; then
          echo "${fail_pfx}: git_parser_failed(${mode})"
          return 1
        fi
        p="${rec#*$'\t'}"
        _add_lit_z "$p" || return 1
      done
      ;;
    *)
      echo "${fail_pfx}: unsupported_git_paths_mode(${mode})"
      return 1
      ;;
  esac
  return 0
}

git_err_detail() {
  local d
  d="$(trim_str "$_GIT_STDERR")"
  [[ -n "$d" ]] || d="$(trim_str "$_GIT_STDOUT")"
  printf '%s' "$d"
}

hash_git_stdin_file() {
  local root="$1" in_file="$2" prefix="${3:-GIT_ERROR}" desc="${4:-failed}" h_out
  if ! run_git_cmd_from_file "$root" "$in_file" hash-object --stdin; then
    echo "${prefix}: git hash-object ${desc}: $(git_err_detail)"
    return 1
  fi
  h_out="$(trim_str "$_GIT_STDOUT")"
  if [[ ! "$h_out" =~ ^[0-9a-f]{40}$ ]]; then
    echo "${prefix}: git hash-object ${desc}: $h_out"
    return 1
  fi
  printf '%s' "$h_out"
}

hash_git_text() {
  local root="$1" text="$2" prefix="${3:-GIT_ERROR}" desc="${4:-failed}" tmp_h rc=0
  make_temp_file "b3-txth" tmp_h
  printf '%s' "$text" > "$tmp_h"
  hash_git_stdin_file "$root" "$tmp_h" "$prefix" "$desc" || rc=$?
  rm -f "$tmp_h" 2>/dev/null || true
  return $rc
}

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|mechanical-check|check-wave|new-run|resolve-run|list-runs|prune|verify-run|verify-check|symbol-check|check-worktree|review-inventory|review-ledger|evidence-check|merge-policy-check|context-cache [options]" >&2
  exit 1
fi
shift

_B3_IS_WINDOWS=false
_B3_IS_MACOS=false
_B3_IS_CASE_INSENSITIVE_FS=false
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    _B3_IS_WINDOWS=true
    _B3_IS_CASE_INSENSITIVE_FS=true
    ;;
  Darwin*)
    _B3_IS_MACOS=true
    _B3_IS_CASE_INSENSITIVE_FS=true
    ;;
esac

norm_path() {
  local p="$1"
  p="${p//$'\r'/}"
  p="${p//\\//}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  while [[ "$p" == ./* ]]; do
    p="${p#./}"
  done
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

normalize_cmd_str() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | LC_ALL=C awk 'BEGIN{out=""} {gsub(/\r/, ""); if ($0 != "") out = (out == "" ? $0 : out " " $0)} END{printf "%s", out}')"
  trim_str "$cleaned"
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
  local _had_noglob=false
  case "$-" in
    *f*) _had_noglob=true ;;
  esac
  set -f
  local -a parts=()
  IFS=',' read -r -d '' -a parts < <(printf '%s\0' "$raw") || true
  if [[ ${#parts[@]} -gt 0 ]]; then
    local part trimmed
    for part in "${parts[@]}"; do
      if [[ "$as_paths" == "true" ]]; then
        trimmed="$(norm_path "$part")"
      else
        trimmed="$(trim_str "$part")"
      fi
      [[ -z "$trimmed" || "$trimmed" == "none" ]] && continue
      printf '%s\n' "$trimmed"
    done
  fi
  if ! $_had_noglob; then set +f; fi
}

now_epoch_ms() {
  local rt="${EPOCHREALTIME:-}"
  if [[ -n "$rt" && "$rt" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    local sec="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[2]}000"
    printf '%s' "$(( 10#$sec * 1000 + 10#${frac:0:3} ))"
    return 0
  fi
  local dms
  dms="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$dms" =~ ^[0-9]+$ ]]; then
    printf '%s' "$dms"
    return 0
  fi
  printf '%s' "$(( $(date +%s) * 1000 ))"
}

_CHECKED_CSV_PATHS=()
split_path_csv_checked() {
  local raw_csv="$1"
  local err_prefix="$2"
  local reject_dot="${3:-false}"
  local dot_msg="${4:-}"
  _CHECKED_CSV_PATHS=()
  [[ -n "$raw_csv" ]] || return 0
  local LC_ALL=C
  if has_ascii_cntrl "$raw_csv"; then
    echo "${err_prefix}: invalid path control character"
    exit 1
  fi
  local cleaned
  cleaned="$(trim_str "$raw_csv")"
  if [[ -z "$cleaned" || "$cleaned" == "[]" || "$cleaned" == "none" ]]; then
    return 0
  fi
  if [[ "$cleaned" == \[*\] ]]; then
    cleaned="${cleaned#[}"
    cleaned="${cleaned%]}"
  fi
  local _had_ng=false
  case "$-" in *f*) _had_ng=true ;; esac
  set -f
  local -a parts=()
  IFS=',' read -r -d '' -a parts < <(printf '%s\0' "$cleaned") || true
  if ! $_had_ng; then set +f; fi
  local part tok slash item prev seen re_dotdot='(^|/)\.\.(/|$)'
  local -a raw_items=()
  if [[ ${#parts[@]} -gt 0 ]]; then
    for part in "${parts[@]}"; do
      tok="$(trim_str "$part")"
      [[ -z "$tok" || "$tok" == "none" ]] && continue
      if [[ "$tok" == *'*'* || "$tok" == *'?'* ]]; then
        echo "${err_prefix}: invalid glob in path '$tok'"
        exit 1
      fi
      slash="${tok//\\//}"
      if [[ "$slash" == *:* || "$slash" == /* || "$slash" =~ $re_dotdot ]]; then
        echo "${err_prefix}: invalid path '$tok'"
        exit 1
      fi
      if [[ "$slash" == "." || "$slash" == "./" ]]; then
        item="."
      else
        item="$(norm_path "$tok")"
      fi
      [[ -n "$item" ]] || continue
      if [[ "$reject_dot" == "true" && "$item" == "." ]]; then
        if [[ -n "$dot_msg" ]]; then
          echo "$dot_msg"
        else
          echo "${err_prefix}: invalid ignore-dirty path '.'"
        fi
        exit 1
      fi
      seen="false"
      if [[ ${#raw_items[@]} -gt 0 ]]; then
        for prev in "${raw_items[@]}"; do
          if [[ "$prev" == "$item" ]]; then seen="true"; break; fi
        done
      fi
      [[ "$seen" == "true" ]] || raw_items+=("$item")
    done
  fi
  if [[ ${#raw_items[@]} -gt 0 ]]; then
    local srt
    while IFS= read -r srt; do
      [[ -n "$srt" ]] && _CHECKED_CSV_PATHS+=("$srt")
    done < <(printf '%s\n' "${raw_items[@]}" | LC_ALL=C sort -u)
  fi
}

path_in_list() {
  local candidate="$1"
  shift
  [[ -n "$candidate" ]] || return 1
  local pat
  for pat in "$@"; do
    [[ -z "$pat" ]] && continue
    if [[ "$pat" == "." || "$candidate" == "$pat" || "$candidate" == "$pat/"* ]]; then
      return 0
    fi
  done
  return 1
}

ownership_path_match() {
  local candidate="$1"
  local packed="$2"
  [[ -n "$candidate" && -n "$packed" ]] || return 1
  local cmp_cand="$candidate"
  local cmp_packed="$packed"
  if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
    cmp_cand="$(printf '%s' "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    cmp_packed="$(printf '%s' "$packed" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  local -a pats=()
  IFS='|' read -ra pats <<< "$cmp_packed"
  local pat
  if [[ ${#pats[@]} -gt 0 ]]; then
    for pat in "${pats[@]}"; do
      [[ -z "$pat" ]] && continue
      if [[ "$pat" == "." || "$cmp_cand" == "$pat" || "$cmp_cand" == "$pat/"* ]]; then
        return 0
      fi
    done
  fi
  return 1
}

parse_wave_paths() {
  local raw_in="$1"
  local check_protected="${2:-false}"
  local reject_dot="${3:-false}"
  local error_prefix="${4:-WAVE_FAIL}"
  _WAVE_PARSED_PATHS=()
  _WAVE_EXPLICIT_EMPTY=false
  local cleaned
  cleaned="$(trim_str "$raw_in")"
  if [[ "$cleaned" == "[]" || "$cleaned" == "none" ]]; then
    _WAVE_EXPLICIT_EMPTY=true
    return 0
  fi
  if [[ -z "$cleaned" ]]; then
    return 0
  fi
  if [[ "$cleaned" == \[*\] ]]; then
    cleaned="${cleaned#[}"
    cleaned="${cleaned%]}"
  fi
  local _had_noglob=false
  case "$-" in
    *f*) _had_noglob=true ;;
  esac
  set -f
  local -a parts=()
  IFS=',' read -r -d '' -a parts < <(printf '%s\0' "$cleaned") || true
  if ! $_had_noglob; then set +f; fi
  if [[ ${#parts[@]} -eq 0 ]]; then
    return 0
  fi
  local LC_ALL=C
  local part tok slash norm seg rem low_p
  local re_dotdot='(^|/)\.\.(/|$)'
  local re_b3='^\.b3(/|$)'
  local re_git='(^|/)\.git(/|$)'
  local re_gitmodules='(^|/)\.gitmodules$'
  local prev seen
  for part in "${parts[@]}"; do
    if has_ascii_cntrl "$part"; then
      tok="$(trim_str "$part")"
      [[ -n "$tok" ]] || tok="$part"
      echo "${error_prefix}: invalid path '$tok'"
      exit 1
    fi
    tok="$(trim_str "$part")"
    [[ -z "$tok" || "$tok" == "none" ]] && continue
    slash="${tok//\\//}"
    if [[ "$slash" == *"|"* || "$slash" == *:* || "$slash" == /* || "$slash" == *"//"* || "$slash" =~ $re_dotdot || "$slash" == *'*'* || "$slash" == *'?'* ]]; then
      echo "${error_prefix}: invalid path '$tok'"
      exit 1
    fi
    if [[ "$slash" == "." || "$slash" == "./" ]]; then
      norm="."
    else
      if [[ "$slash" == *"/./"* || "$slash" == *"/." ]]; then
        echo "${error_prefix}: invalid path '$tok'"
        exit 1
      fi
      norm="$slash"
      if [[ "$norm" == ./* ]]; then
        norm="${norm#./}"
      fi
      while [[ "$norm" == */ ]]; do
        norm="${norm%/}"
      done
      if [[ -z "$norm" || "$norm" == "." || "$norm" == ".." ]]; then
        echo "${error_prefix}: invalid path '$tok'"
        exit 1
      fi
      rem="$norm"
      while true; do
        if [[ "$rem" == */* ]]; then
          seg="${rem%%/*}"
          rem="${rem#*/}"
        else
          seg="$rem"
          rem=""
        fi
        if [[ -z "$seg" || "$seg" == "." || "$seg" == ".." || "$seg" == *. || "$seg" == *" " ]]; then
          echo "${error_prefix}: invalid path '$tok'"
          exit 1
        fi
        [[ -n "$rem" ]] || break
      done
    fi
    if [[ "$check_protected" == "true" ]]; then
      low_p="$(printf '%s' "$norm" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      if [[ "$low_p" =~ $re_b3 || "$low_p" =~ $re_git || "$low_p" =~ $re_gitmodules ]]; then
        echo "${error_prefix}: protected path '$norm' cannot be worker-owned"
        exit 1
      fi
    fi
    if [[ "$reject_dot" == "true" && "$norm" == "." ]]; then
      echo "${error_prefix}: protected path '.' cannot be worker-owned in parallel partition"
      exit 1
    fi
    seen="false"
    if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
      for prev in "${_WAVE_PARSED_PATHS[@]}"; do
        if [[ "$prev" == "$norm" ]]; then
          seen="true"
          break
        fi
      done
    fi
    if [[ "$seen" != "true" ]]; then
      _WAVE_PARSED_PATHS+=("$norm")
    fi
  done
}

parse_wave_task_map() {
  local specs="$1"
  local root="$2"
  local err_prefix="$3"
  local spec_label="$4"
  local empty_arg_label="$5"
  local check_protected="$6"
  local reject_dot="$7"
  local allow_empty="$8"
  local allowed_packed="${9:-}"

  _WTM_IDS=()
  _WTM_PACKED=()
  _WTM_LOW_PACKED=()
  _WTM_TOTAL_PATHS=0

  local repo_exists="false"
  if [[ -n "$root" && -d "$root" ]]; then
    repo_exists="true"
  fi
  local entry_label="entry"
  local dup_suffix=""
  if [[ "$spec_label" != "WaveSpecs" ]]; then
    entry_label="${spec_label} entry"
    dup_suffix=" in ${spec_label}"
  fi

  local _had_noglob_wtm=false
  case "$-" in
    *f*) _had_noglob_wtm=true ;;
  esac
  set -f
  local -a entries=()
  IFS=';' read -r -d '' -a entries < <(printf '%s\0' "$specs") || true
  if ! $_had_noglob_wtm; then set +f; fi

  local entry trim_e tid raw_csv prev_t wp packed low_packed
  if [[ ${#entries[@]} -gt 0 ]]; then
    for entry in "${entries[@]}"; do
      trim_e="$(trim_str "$entry")"
      [[ -z "$trim_e" ]] && continue
      if [[ "$trim_e" != *"="* ]]; then
        echo "${err_prefix}: invalid ${entry_label} '$trim_e' (expected TaskId=path1,path2)"
        exit 1
      fi
      tid="$(trim_str "${trim_e%%=*}")"
      raw_csv="${trim_e#*=}"
      [[ -n "$tid" ]] || { echo "${err_prefix}: empty task id in '$trim_e'"; exit 1; }
      if ! is_valid_wave_task_id "$tid"; then
        echo "${err_prefix}: invalid task id '$tid'"
        exit 1
      fi
      if [[ ${#_WTM_IDS[@]} -gt 0 ]]; then
        for prev_t in "${_WTM_IDS[@]}"; do
          if [[ "$prev_t" == "$tid" ]]; then
            echo "${err_prefix}: duplicate task id '$tid'${dup_suffix}"
            exit 1
          fi
        done
      fi
      if [[ -n "$allowed_packed" && "$allowed_packed" != *"|${tid}|"* ]]; then
        echo "${err_prefix}: unknown task id '$tid' in ${spec_label}"
        exit 1
      fi
      parse_wave_paths "$raw_csv" "$check_protected" "$reject_dot" "$err_prefix"
      if [[ ${#_WAVE_PARSED_PATHS[@]} -lt 1 ]] && ! [[ "$allow_empty" == "true" && "$_WAVE_EXPLICIT_EMPTY" == "true" ]]; then
        echo "${err_prefix}: task '$tid' has no owned paths"
        exit 1
      fi
      if [[ "$repo_exists" == "true" && ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
        for wp in "${_WAVE_PARSED_PATHS[@]}"; do
          if ! check_wave_path_containment "$root" "$wp"; then
            echo "${err_prefix}: unsafe symlink or junction alias in path '$wp'"
            exit 1
          fi
        done
      fi
      _WTM_IDS+=("$tid")
      packed=""
      low_packed=""
      if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
        packed="$(IFS='|'; printf '%s' "${_WAVE_PARSED_PATHS[*]}")"
        if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
          low_packed="$(printf '%s' "$packed" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        else
          low_packed="$packed"
        fi
      fi
      _WTM_PACKED+=("$packed")
      _WTM_LOW_PACKED+=("$low_packed")
      _WTM_TOTAL_PATHS=$((_WTM_TOTAL_PATHS + ${#_WAVE_PARSED_PATHS[@]}))
    done
  fi
  [[ ${#_WTM_IDS[@]} -gt 0 ]] || { echo "${err_prefix}: no tasks in ${empty_arg_label}"; exit 1; }
}

check_wave_path_containment() {
  local root="$1"
  local norm="$2"
  [[ -n "$root" && -d "$root" ]] || return 0
  [[ -n "$norm" && "$norm" != "." ]] || return 0
  local canon_root
  canon_root="$(canon_repo_root "$root")" || return 1
  local target_full
  target_full="$(resolve_target_path "$canon_root" "$norm")" || return 1
  [[ -n "$target_full" ]] || return 1
  local target_trim="${target_full%/}"
  [[ -L "$target_trim" ]] && return 1
  if ! _path_within_or_equal "$target_full" "$canon_root"; then
    return 1
  fi
  local cr_cmp="$canon_root" tf_cmp="$target_full"
  if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
    cr_cmp="$(printf '%s' "$cr_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    tf_cmp="$(printf '%s' "$tf_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  [[ "$tf_cmp" == "$cr_cmp" ]] && return 1

  local rem="$norm" seg_cur="${canon_root%/}" seg canon_seg seg_cur_cmp canon_seg_cmp
  while [[ -n "$rem" ]]; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    [[ -z "$seg" || "$seg" == "." ]] && continue
    if [[ "$seg" == ".." ]]; then
      return 1
    fi
    seg_cur="${seg_cur}/${seg}"
    seg_cur="${seg_cur%/}"
    if [[ -L "$seg_cur" ]]; then
      return 1
    fi
    if [[ -d "$seg_cur" ]]; then
      canon_seg="$(cd -P "$seg_cur" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
      canon_seg="$(normalize_abs_for_repo "$canon_seg")"
      if ! _path_within_or_equal "$canon_seg" "$canon_root"; then
        return 1
      fi
      seg_cur_cmp="$seg_cur"
      canon_seg_cmp="$canon_seg"
      if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
        seg_cur_cmp="$(printf '%s' "$seg_cur_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        canon_seg_cmp="$(printf '%s' "$canon_seg_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      fi
      if [[ "$canon_seg_cmp" != "$seg_cur_cmp" ]]; then
        return 1
      fi
    fi
  done
  if [[ -d "$target_trim" ]]; then
    local child_sym
    child_sym="$(find "$target_trim" -mindepth 1 \( -name .git -prune \) -o -type l -print 2>/dev/null | head -n 1 || true)"
    if [[ -n "$child_sym" ]]; then
      return 1
    fi
  fi
  return 0
}

is_valid_wave_task_id() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

wave_paths_overlap_cmp() {
  local a="$1" b="$2"
  if [[ "$a" == "$b" ]]; then
    _WAVE_OV="equal"
  elif [[ "$a" == "." || "$b" == "." || "$a" == "$b/"* || "$b" == "$a/"* ]]; then
    _WAVE_OV="prefix"
  else
    _WAVE_OV="none"
  fi
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

is_binary_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local n
  n="$(dd if="$f" bs=8192 count=1 2>/dev/null | LC_ALL=C tr -cd '\000' | wc -c | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]]
}

assert_valid_git_rev() {
  local root="$1" rev="$2" kind="$3" prefix="$4" opt="$5" sha=""
  if [[ -z "$rev" || "$rev" == -* ]]; then
    echo "${prefix}: invalid ${opt} '${rev}'"
    exit 1
  fi
  if ! run_git_cmd_quiet "$root" rev-parse --verify --quiet "${rev}^{${kind}}"; then
    echo "${prefix}: invalid ${opt} '${rev}'"
    exit 1
  fi
  sha="$(trim_str "$_GIT_STDOUT")"
  if [[ -z "$sha" ]]; then
    echo "${prefix}: invalid ${opt} '${rev}'"
    exit 1
  fi
  _VALID_REV_SHA="$sha"
}

snapshot_preflight() {
  local root="$1" prefix="$2" p sub
  local -a ch_paths=() un_paths=()
  run_git_paths_z "$root" "names" "$prefix" "" -- diff --no-ext-diff --no-renames --diff-filter=d --name-only -z HEAD -- || return 1
  [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && ch_paths=("${_GIT_PATHS_Z[@]}")
  run_git_paths_z "$root" "names" "$prefix" "" -- ls-files --others --exclude-standard -z || return 1
  [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && un_paths=("${_GIT_PATHS_Z[@]}")
  for p in ${ch_paths[@]+"${ch_paths[@]}"} ${un_paths[@]+"${un_paths[@]}"}; do
    [[ -n "$p" ]] || continue
    if is_secret_path "$p"; then
      echo "${prefix}: sensitive path cannot be snapshotted ($p)"
      return 1
    fi
  done
  local st_tmp rc=0 rec
  make_temp_file "b3-stage-z" st_tmp
  if git -C "$root" -c core.quotepath=false ls-files --stage -z >"$st_tmp" 2>"$_B3_GIT_ERR_FILE"; then rc=0; else rc=$?; fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$st_tmp" 2>/dev/null || true
    echo "${prefix}: unable to inspect submodules"
    return 1
  fi
  while IFS= read -r -d '' rec; do
    [[ "$rec" == 160000\ * ]] || continue
    [[ "$rec" == *$'\t'* ]] || continue
    p="${rec#*$'\t'}"
    if ! is_valid_literal_git_path "$p"; then
      rm -f "$st_tmp" 2>/dev/null || true
      echo "${prefix}: unsupported_literal_git_path"
      return 1
    fi
    sub="${root}/${p}"
    [[ -e "${sub}/.git" ]] || continue
    if ! run_git_paths_z "$sub" "status-z" "$prefix" "" -- status --porcelain --untracked-files=all --ignore-submodules=none -z; then
      rm -f "$st_tmp" 2>/dev/null || true
      return 1
    fi
    if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then
      rm -f "$st_tmp" 2>/dev/null || true
      echo "${prefix}: dirty submodule cannot be snapshotted ($p)"
      return 1
    fi
  done < "$st_tmp"
  rm -f "$st_tmp" 2>/dev/null || true
}

run_snapshot_chunked_cmd() {
  local root="$1" tmp_idx="$2"
  shift 2
  local -a prefix_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      prefix_args+=("--")
      shift
      break
    fi
    prefix_args+=("$1")
    shift
  done
  [[ $# -eq 0 ]] && return 0
  local -a chunk=()
  local item=""
  for item in "$@"; do
    chunk+=("$item")
    if [[ ${#chunk[@]} -ge 50 ]]; then
      run_git_cmd_with_index "$root" "$tmp_idx" "${prefix_args[@]}" "${chunk[@]}" || return 1
      chunk=()
    fi
  done
  if [[ ${#chunk[@]} -gt 0 ]]; then
    run_git_cmd_with_index "$root" "$tmp_idx" "${prefix_args[@]}" "${chunk[@]}" || return 1
  fi
  return 0
}

stage_non_secret_tracked() {
  local root="$1" tmp_idx="$2" p="" ts="" skip="false"
  shift 2
  run_git_paths_z "$root" "names" "GIT_ERROR" "$tmp_idx" -- diff --no-ext-diff --no-renames --name-only -z -- || return 1
  local -a non_secret_tracked=()
  for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
    [[ -n "$p" ]] || continue
    skip="false"
    for ts in "$@"; do
      if [[ "$p" == "$ts" ]]; then
        skip="true"
        break
      fi
    done
    if [[ "$skip" != "true" ]]; then
      non_secret_tracked+=("$p")
    fi
  done
  if [[ ${#non_secret_tracked[@]} -gt 0 ]]; then
    run_snapshot_chunked_cmd "$root" "$tmp_idx" add -u -- "${non_secret_tracked[@]}" || return 1
  fi
  return 0
}

build_working_tree_oid() {
  local root="$1" prefix="$2" exclude_sensitive="${3:-false}" real_idx_raw="" real_idx="" tmp_idx="" tree_sha=""
  local has_head="false" p=""
  local -a tracked_secrets=()
  local -a unborn_staged_secrets=()
  local -a untracked_to_add=()
  if run_git_cmd_quiet "$root" rev-parse --verify --quiet HEAD; then
    has_head="true"
  fi
  if [[ "$exclude_sensitive" == "true" ]]; then
    if [[ "$has_head" == "true" ]]; then
      run_git_paths_z "$root" "names" "$prefix" "" -- diff --no-ext-diff --no-renames --diff-filter=d --name-only -z HEAD -- || return 1
      for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$p" ]] || continue
        if is_secret_path "$p"; then
          tracked_secrets+=("$p")
        fi
      done
    else
      run_git_paths_z "$root" "names" "$prefix" "" -- ls-files --cached -z || return 1
      for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$p" ]] || continue
        if is_secret_path "$p"; then
          unborn_staged_secrets+=("$p")
        fi
      done
    fi
  else
    snapshot_preflight "$root" "$prefix" || return 1
  fi
  run_git_paths_z "$root" "names" "$prefix" "" -- ls-files --others --exclude-standard -z || return 1
  for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
    [[ -n "$p" ]] || continue
    case "$p" in
      .b3/ship|.b3/ship/*|.b3/research-ship|.b3/research-ship/*|.b3/autodev|.b3/autodev/*) continue ;;
    esac
    if [[ "$exclude_sensitive" == "true" ]] && is_secret_path "$p"; then
      continue
    fi
    untracked_to_add+=("$p")
  done
  if ! run_git_cmd "$root" rev-parse --git-path index; then
    echo "${prefix}: failed to locate git index"
    exit 1
  fi
  real_idx_raw="$(trim_str "$_GIT_STDOUT")"
  real_idx="$(resolve_target_path "$root" "$real_idx_raw")"
  make_temp_file "b3-snap-idx" tmp_idx
  if [[ -f "$real_idx" ]]; then
    cp -p "$real_idx" "$tmp_idx"
  else
    rm -f "$tmp_idx"
  fi
  if ! {
    { [[ ${#unborn_staged_secrets[@]} -eq 0 ]] || run_snapshot_chunked_cmd "$root" "$tmp_idx" rm -r --cached --ignore-unmatch -q -- "${unborn_staged_secrets[@]}"; } &&
    if [[ "$exclude_sensitive" == "true" && ${#tracked_secrets[@]} -gt 0 ]]; then
      stage_non_secret_tracked "$root" "$tmp_idx" "${tracked_secrets[@]}" &&
      run_snapshot_chunked_cmd "$root" "$tmp_idx" reset -q HEAD -- "${tracked_secrets[@]}"
    else
      run_git_cmd_with_index "$root" "$tmp_idx" add -u
    fi &&
    { [[ ${#untracked_to_add[@]} -eq 0 ]] || run_snapshot_chunked_cmd "$root" "$tmp_idx" add -- "${untracked_to_add[@]}"; }
  }; then
    echo "${prefix}: snapshot stage failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" rm -r --cached --ignore-unmatch --quiet -- .b3/ship .b3/research-ship .b3/autodev; then
    echo "${prefix}: git rm checkpoint failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" write-tree; then
    echo "${prefix}: git write-tree failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  tree_sha="$(trim_str "$_GIT_STDOUT")"
  rm -f "$tmp_idx"
  if [[ -z "$tree_sha" ]]; then
    echo "${prefix}: git write-tree returned empty SHA"
    exit 1
  fi
  _WT_TREE_OID="$tree_sha"
}

is_noise_file() {
  local leaf
  leaf="$(printf '%s' "${1##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$leaf" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lockb|packages.lock.json|cargo.lock|poetry.lock) return 0 ;;
    *.min.js|*.min.css|*.snap|*.designer.cs|*.g.cs|*.map) return 0 ;;
    *) return 1 ;;
  esac
}

find_leftover_tag_var() {
  local LC_ALL=C
  local ln="$1"
  _LO_TAG=""
  if [[ "$ln" =~ (^|[^a-zA-Z0-9_])debugger([^a-zA-Z0-9_]|$) ]]; then
    _LO_TAG="deb""ugger"
  elif [[ "$ln" =~ \.only\( ]]; then
    _LO_TAG=".on""ly("
  elif [[ "$ln" == *"@ts-ignore"* ]]; then
    _LO_TAG="@ts-""ignore"
  elif [[ "$ln" == *"eslint-disable"* ]]; then
    _LO_TAG="eslint-""disable"
  elif [[ "$ln" =~ (^|[^a-zA-Z0-9_])(TODO|FIXME)[[:space:]]*:?[[:space:]]*$ ]]; then
    _LO_TAG="empty-todo"
  fi
}

resolve_auto_base_sha() {
  local root="$1"
  shift
  local -a ignored=("$@")
  local head_sha="" p="" has_head="false"
  local -a cands=()
  if run_git_cmd_quiet "$root" rev-parse --verify --quiet HEAD; then
    head_sha="$(trim_str "$_GIT_STDOUT")"
    [[ -n "$head_sha" ]] && has_head="true"
  fi
  if [[ "$has_head" == "true" ]]; then
    run_git_paths_z "$root" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --name-only -z HEAD -- || return 1
    [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && cands+=("${_GIT_PATHS_Z[@]}")
  fi
  run_git_paths_z "$root" "names" "GIT_ERROR" "" -- ls-files --others --exclude-standard -z || return 1
  [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && cands+=("${_GIT_PATHS_Z[@]}")
  for p in ${cands[@]+"${cands[@]}"}; do
    [[ -z "$p" ]] && continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ignored[@]} -gt 0 ]] && path_in_list "$p" "${ignored[@]}"; then continue; fi
    printf '%s' "HEAD"
    return 0
  done

  local ref mb=""
  if [[ -n "$head_sha" ]]; then
    for ref in origin/HEAD origin/main origin/master main master; do
      if run_git_cmd_quiet "$root" rev-parse --verify --quiet "$ref"; then
        if run_git_cmd_quiet "$root" merge-base "$ref" HEAD; then
          mb="$(trim_str "$_GIT_STDOUT")"
        else
          mb=""
        fi
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
  local ref mb=""
  for ref in origin/HEAD origin/main origin/master main master HEAD; do
    if run_git_cmd_quiet "$root" rev-parse --verify --quiet "$ref"; then
      if run_git_cmd_quiet "$root" merge-base "$ref" "$target_commit_sha"; then
        mb="$(trim_str "$_GIT_STDOUT")"
      else
        mb=""
      fi
      if [[ -n "$mb" && "$mb" != "$target_commit_sha" ]]; then
        printf '%s' "$mb"
        return 0
      fi
    fi
  done
  if run_git_cmd_quiet "$root" rev-parse --verify --quiet "${target_commit_sha}^"; then
    local par=""
    par="$(trim_str "$_GIT_STDOUT")"
    if [[ -n "$par" ]]; then
      printf '%s' "$par"
      return 0
    fi
  fi
  printf '%s' "$target_commit_sha"
}

_SCOPE_TARGET_REF=""
_SCOPE_TARGET_SHA=""
_SCOPE_BASE_SHA=""
resolve_scope_target_and_base() {
  local root="$1" target_raw="$2" base_raw="$3" prefix="$4" base_kind="${5:-object}"
  shift 5
  local -a ign=("$@")
  _SCOPE_TARGET_REF="$(trim_str "$target_raw")"
  _SCOPE_TARGET_SHA=""
  if [[ -n "$_SCOPE_TARGET_REF" ]]; then
    if [[ "$_SCOPE_TARGET_REF" == *$'\n'* || "$_SCOPE_TARGET_REF" == *$'\r'* ]]; then
      echo "${prefix}: invalid --target-ref '${_SCOPE_TARGET_REF}'"
      exit 1
    fi
    assert_valid_git_rev "$root" "$_SCOPE_TARGET_REF" "commit" "$prefix" "--target-ref"
    _SCOPE_TARGET_SHA="$_VALID_REV_SHA"
  fi
  local b_sha
  b_sha="$(trim_str "$base_raw")"
  if [[ -z "$b_sha" || "$b_sha" == "auto" ]]; then
    if [[ -n "$_SCOPE_TARGET_REF" ]]; then
      b_sha="$(resolve_auto_base_for_target "$root" "$_SCOPE_TARGET_SHA")"
    elif [[ ${#ign[@]} -gt 0 ]]; then
      b_sha="$(resolve_auto_base_sha "$root" "${ign[@]}")"
    else
      b_sha="$(resolve_auto_base_sha "$root")"
    fi
  fi
  assert_valid_git_rev "$root" "$b_sha" "$base_kind" "$prefix" "--base-sha"
  if [[ "$base_kind" == "commit" ]]; then
    _SCOPE_BASE_SHA="$_VALID_REV_SHA"
  else
    _SCOPE_BASE_SHA="$b_sha"
  fi
}

is_checkpoint_dir() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == ".b3/ship" || "$lp" == ".b3/ship/"* || "$lp" == ".b3/research-ship" || "$lp" == ".b3/research-ship/"* || "$lp" == ".b3/autodev" || "$lp" == ".b3/autodev/"* ]]
}

is_md_file() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == *.md ]]
}

resolve_namespace_dir() {
  local root="$1"
  local ns="${2:-ship}"
  ns="$(trim_str "$ns")"
  [[ -n "$ns" ]] || ns="ship"
  case "$ns" in
    ship) printf '%s' "${root}/.b3/ship" ;;
    research-ship) printf '%s' "${root}/.b3/research-ship" ;;
    *) echo "INVALID_NAMESPACE: $ns" >&2; return 1 ;;
  esac
}

check_contained_repo_path() {
  local LC_ALL=C
  local root="$1"
  local raw="$2"
  [[ -n "$raw" ]] || return 1
  if has_ascii_cntrl "$raw"; then return 1; fi
  if [[ "$raw" == *" " ]]; then return 1; fi
  local trimmed canon_root
  trimmed="$(trim_str "$raw")"
  [[ -n "$trimmed" ]] || return 1
  if [[ "$trimmed" == *:* ]]; then return 1; fi
  local raw_slash="${trimmed//\\//}"
  if [[ "$raw_slash" == */ ]]; then return 1; fi
  local p
  p="$(norm_path "$trimmed")"
  local re_dotdot='(^|/)\.\.(/|$)'
  if [[ -z "$p" || "$p" == "." || "$p" == /* || "$p" == ~* || "$p" == *:* || "$p" =~ $re_dotdot || "$p" == *'*'* || "$p" == *'?'* || "$p" == *'['* ]]; then
    return 1
  fi
  local check_rem="$p" check_seg
  while true; do
    if [[ "$check_rem" == */* ]]; then
      check_seg="${check_rem%%/*}"
      check_rem="${check_rem#*/}"
    else
      check_seg="$check_rem"
      check_rem=""
    fi
    if [[ -z "$check_seg" || "$check_seg" == *. || "$check_seg" == *" " ]]; then
      return 1
    fi
    [[ -n "$check_rem" ]] || break
  done
  local p_low re_git='(^|/)\.git(/|$)'
  p_low="$(printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$p_low" =~ $re_git ]]; then
    return 1
  fi
  canon_root="$(canon_repo_root "$root")" || return 1
  local rem="${p#./}" seg_cur="${canon_root%/}" seg canon_seg seg_cur_cmp canon_seg_cmp
  while [[ -n "$rem" ]]; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    [[ -z "$seg" || "$seg" == "." ]] && continue
    if [[ "$seg" == ".." ]]; then return 1; fi
    seg_cur="${seg_cur}/${seg}"
    seg_cur="${seg_cur%/}"
    if [[ -L "$seg_cur" ]]; then
      return 1
    fi
    if [[ -d "$seg_cur" ]]; then
      canon_seg="$(cd -P "$seg_cur" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
      canon_seg="$(normalize_abs_for_repo "$canon_seg")"
      if ! _path_within_or_equal "$canon_seg" "$canon_root"; then
        return 1
      fi
      seg_cur_cmp="$seg_cur"
      canon_seg_cmp="$canon_seg"
      if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
        seg_cur_cmp="$(printf '%s' "$seg_cur_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        canon_seg_cmp="$(printf '%s' "$canon_seg_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      fi
      if [[ "$canon_seg_cmp" != "$seg_cur_cmp" ]]; then
        return 1
      fi
    fi
  done
  local full canon_dir probe next_probe re_winroot='^[A-Za-z]:/$'
  full="$(resolve_target_path "$canon_root" "$p")" || return 1
  [[ -n "$full" ]] || return 1
  if ! _path_within_or_equal "$full" "$canon_root"; then
    return 1
  fi
  probe="$(dirname "$full")"
  [[ "$probe" =~ ^[A-Za-z]:$ ]] && probe="${probe}/"
  while [[ -n "$probe" && "$probe" != "/" && ! "$probe" =~ $re_winroot && ! -d "$probe" ]]; do
    next_probe="$(dirname "$probe")"
    [[ "$next_probe" =~ ^[A-Za-z]:$ ]] && next_probe="${next_probe}/"
    [[ "$next_probe" == "$probe" ]] && break
    probe="$next_probe"
  done
  [[ -d "$probe" ]] || return 1
  canon_dir="$(cd -P "$probe" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  canon_dir="$(normalize_abs_for_repo "$canon_dir")"
  if ! _path_within_or_equal "$canon_dir" "$canon_root"; then
    return 1
  fi
  _CONTAINED_REL="$p"
  _CONTAINED_FULL="${canon_root%/}/${p}"
  return 0
}

compute_file_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print tolower($NF)}'
  else
    return 1
  fi
}

parse_merge_policy_json() {
  local pol_src="${1:--}"
  local _node_code='
const fs = require("fs");
let raw;
try { raw = fs.readFileSync(0, "utf8").replace(/^\uFEFF/, ""); } catch (e) { process.exit(2); }
let obj;
try { obj = JSON.parse(raw); } catch (e) { process.exit(2); }
if (!obj || typeof obj !== "object" || Array.isArray(obj)) process.exit(2);
let autoMerge = "disabled";
if (Object.prototype.hasOwnProperty.call(obj, "auto_merge")) {
  if (typeof obj.auto_merge !== "string" || /[\x00-\x1F\x7F]/.test(obj.auto_merge)) process.exit(2);
  const am = obj.auto_merge.trim();
  if (am !== "disabled" && am !== "authorized") {
    process.stdout.write("invalid_auto_merge=" + am + "\n");
    process.exit(3);
  }
  autoMerge = am;
}
let allowProt = false;
if (Object.prototype.hasOwnProperty.call(obj, "allow_protected_paths")) {
  if (typeof obj.allow_protected_paths !== "boolean") process.exit(2);
  allowProt = obj.allow_protected_paths;
}
let reqCi = true;
if (Object.prototype.hasOwnProperty.call(obj, "require_ci")) {
  if (typeof obj.require_ci !== "boolean") process.exit(2);
  reqCi = obj.require_ci;
}
let reqRev = true;
if (Object.prototype.hasOwnProperty.call(obj, "require_review")) {
  if (typeof obj.require_review !== "boolean") process.exit(2);
  reqRev = obj.require_review;
}
let prot = [];
if (Object.prototype.hasOwnProperty.call(obj, "protected_paths")) {
  if (!Array.isArray(obj.protected_paths)) process.exit(2);
  for (const x of obj.protected_paths) {
    if (typeof x !== "string" || /[\r\n\0]/.test(x)) process.exit(2);
    prot.push(x);
  }
}
let allowedBranches = [];
if (Object.prototype.hasOwnProperty.call(obj, "allowed_target_branches")) {
  if (!Array.isArray(obj.allowed_target_branches)) process.exit(2);
  for (const bp of obj.allowed_target_branches) {
    if (typeof bp !== "string" || /[\x00-\x1F\x7F\s]/.test(bp)) process.exit(2);
    const bt = bp.trim();
    if (!bt || bt.startsWith("-") || bt.includes("..")) process.exit(2);
    allowedBranches.push(bt);
  }
}
process.stdout.write("auto_merge=" + autoMerge + "\n");
process.stdout.write("allow_protected_paths=" + (allowProt ? "true" : "false") + "\n");
process.stdout.write("require_ci=" + (reqCi ? "true" : "false") + "\n");
process.stdout.write("require_review=" + (reqRev ? "true" : "false") + "\n");
for (const p of prot) process.stdout.write("protected_path=" + p + "\n");
for (const b of allowedBranches) process.stdout.write("allowed_target_branch=" + b + "\n");
'
  if command -v node >/dev/null 2>&1; then
    if [[ "$pol_src" == "-" ]]; then
      node -e "$_node_code"
    else
      node -e "$_node_code" < "$pol_src"
    fi
    return $?
  fi
  local py_cmd=""
  if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    py_cmd="python3"
  elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    py_cmd="python"
  fi
  if [[ -n "$py_cmd" ]]; then
    local _py_code='
import json, sys
try:
    raw = sys.stdin.read().lstrip("\ufeff")
    obj = json.loads(raw)
except Exception:
    sys.exit(2)
if not isinstance(obj, dict):
    sys.exit(2)
auto_merge = obj.get("auto_merge", "disabled")
if not isinstance(auto_merge, str) or any(ord(c) < 32 or ord(c) == 127 for c in auto_merge):
    sys.exit(2)
auto_merge = auto_merge.strip()
if auto_merge not in ("disabled", "authorized"):
    print("invalid_auto_merge=" + auto_merge)
    sys.exit(3)
for bkey, default in (("allow_protected_paths", False), ("require_ci", True), ("require_review", True)):
    if bkey in obj and not isinstance(obj[bkey], bool):
        sys.exit(2)
prot = obj.get("protected_paths", [])
if not isinstance(prot, list):
    sys.exit(2)
for p in prot:
    if not isinstance(p, str) or any(c in p for c in ("\r", "\n", "\x00")):
        sys.exit(2)
allowed_br = obj.get("allowed_target_branches", [])
if not isinstance(allowed_br, list):
    sys.exit(2)
for bp in allowed_br:
    if not isinstance(bp, str) or any(ord(c) <= 32 or ord(c) == 127 for c in bp):
        sys.exit(2)
    bt = bp.strip()
    if not bt or bt.startswith("-") or ".." in bt:
        sys.exit(2)
print("auto_merge=" + auto_merge)
print("allow_protected_paths=" + ("true" if obj.get("allow_protected_paths", False) else "false"))
print("require_ci=" + ("true" if obj.get("require_ci", True) else "false"))
print("require_review=" + ("true" if obj.get("require_review", True) else "false"))
for p in prot:
    print("protected_path=" + p)
for b in allowed_br:
    print("allowed_target_branch=" + b.strip())
'
    if [[ "$pol_src" == "-" ]]; then
      "$py_cmd" -c "$_py_code"
    else
      "$py_cmd" -c "$_py_code" < "$pol_src"
    fi
    return $?
  fi
  return 2
}

_POL_AUTO_MERGE="disabled"
_POL_ALLOW_PROT="false"
_POL_REQ_CI="true"
_POL_REQ_REV="true"
_POL_PROT_ARR=()
_POL_ALLOWED_BR=()
load_merge_policy_from_source() {
  local src="$1" raw_txt="${2:-}" err_pfx="${3:-MERGE_BLOCKED}"
  local parsed_pol="" pol_rc=0 pline raw_pp _bad_am _seen_pp="|" _seen_br="|" _br_v
  _POL_AUTO_MERGE="disabled"
  _POL_ALLOW_PROT="false"
  _POL_REQ_CI="true"
  _POL_REQ_REV="true"
  _POL_PROT_ARR=()
  _POL_ALLOWED_BR=()
  set +e
  if [[ "$src" == "-" ]]; then
    parsed_pol="$(printf '%s' "$raw_txt" | parse_merge_policy_json "-")"
    pol_rc=$?
  else
    parsed_pol="$(parse_merge_policy_json "$src")"
    pol_rc=$?
  fi
  set -e
  if [[ $pol_rc -eq 3 ]]; then
    _bad_am="${parsed_pol#invalid_auto_merge=}"
    _bad_am="${_bad_am%%$'\n'*}"
    _bad_am="${_bad_am%$'\r'}"
    echo "${err_pfx}: invalid_auto_merge=${_bad_am}"
    exit 1
  elif [[ $pol_rc -ne 0 ]]; then
    echo "${err_pfx}: invalid_policy_json"
    exit 1
  fi
  while IFS= read -r pline; do
    pline="${pline%$'\r'}"
    case "$pline" in
      auto_merge=*) _POL_AUTO_MERGE="${pline#auto_merge=}" ;;
      allow_protected_paths=*) _POL_ALLOW_PROT="${pline#allow_protected_paths=}" ;;
      require_ci=*) _POL_REQ_CI="${pline#require_ci=}" ;;
      require_review=*) _POL_REQ_REV="${pline#require_review=}" ;;
      protected_path=*)
        raw_pp="${pline#protected_path=}"
        if ! normalize_merge_policy_path "$raw_pp"; then
          echo "${err_pfx}: invalid_policy_json"
          exit 1
        fi
        if [[ "$_seen_pp" != *"|${_MP_NORM_PATH}|"* ]]; then
          _seen_pp+="${_MP_NORM_PATH}|"
          _POL_PROT_ARR+=("$_MP_NORM_PATH")
        fi
        ;;
      allowed_target_branch=*)
        _br_v="${pline#allowed_target_branch=}"
        if [[ "$_seen_br" != *"|${_br_v}|"* ]]; then
          _seen_br+="${_br_v}|"
          _POL_ALLOWED_BR+=("$_br_v")
        fi
        ;;
    esac
  done <<< "$parsed_pol"
}

branch_pattern_match() {
  local br="$1"
  shift
  local pat
  [[ -n "$br" ]] || return 1
  for pat in "$@"; do
    [[ -n "$pat" ]] || continue
    if B3_BR="$br" B3_PAT="$pat" LC_ALL=C awk '
      BEGIN {
        b = ENVIRON["B3_BR"]
        p = ENVIRON["B3_PAT"]
        rx = "^"
        for (i = 1; i <= length(p); i++) {
          c = substr(p, i, 1)
          if (c == "*") rx = rx ".*"
          else if (index(".^$+?|()[]{}\\", c) > 0) rx = rx "\\" c
          else rx = rx c
        }
        rx = rx "$"
        exit (b ~ rx ? 0 : 1)
      }'; then
      return 0
    fi
  done
  return 1
}

GH_SCHEMA=""; GH_MODE=""; GH_REPO=""; GH_PR_NUMBER=""; GH_BASE_REPO=""; GH_HEAD_REPO=""
GH_SAME_REPO=""; GH_DEFAULT_BRANCH=""; GH_PR_STATE=""; GH_PR_MERGED=""; GH_PR_DRAFT=""
GH_BASE_REF=""; GH_PR_BASE_SHA=""; GH_LIVE_TARGET_SHA=""
GH_HEAD_REF=""; GH_HEAD_SHA=""; GH_POLICY_AUTH_REF=""; GH_POLICY_AUTH_SHA=""
GH_MERGEABLE=""; GH_MERGEABLE_STATE=""; GH_CI_STATUS=""
GH_MERGED_AT="none"; GH_MERGE_COMMIT_SHA="none"; GH_PR_COMMITS="0"
GH_COMPARE_STATUS=""; GH_COMPARE_BEHIND="-1"
GH_PR_CHANGED_FILES=()

invoke_b3_github_verify() {
  local mode="$1" root_dir="$2" explicit_repo="$3" pr_num="$4" err_pfx="$5"
  local adapter="${_B3_GUARD_DIR}/b3-github-verify.sh"
  if [[ ! -f "$adapter" ]]; then
    echo "${err_pfx}: github_adapter_missing"
    exit 1
  fi
  GH_SCHEMA=""; GH_MODE=""; GH_REPO=""; GH_PR_NUMBER=""; GH_BASE_REPO=""; GH_HEAD_REPO=""
  GH_SAME_REPO=""; GH_DEFAULT_BRANCH=""; GH_PR_STATE=""; GH_PR_MERGED=""; GH_PR_DRAFT=""
  GH_BASE_REF=""; GH_PR_BASE_SHA=""; GH_LIVE_TARGET_SHA=""
  GH_HEAD_REF=""; GH_HEAD_SHA=""; GH_POLICY_AUTH_REF=""; GH_POLICY_AUTH_SHA=""
  GH_MERGEABLE=""; GH_MERGEABLE_STATE=""; GH_CI_STATUS=""
  GH_MERGED_AT="none"; GH_MERGE_COMMIT_SHA="none"; GH_PR_COMMITS="0"
  GH_COMPARE_STATUS=""; GH_COMPARE_BEHIND="-1"
  GH_PR_CHANGED_FILES=()

  local exp_trim raw_out rc=0
  exp_trim="$(trim_str "$explicit_repo")"
  set +e
  if [[ -n "$exp_trim" ]]; then
    raw_out="$(bash "$adapter" --mode "$mode" --repo-root "$root_dir" --repo "$exp_trim" --pr-number "$pr_num" 2>&1)"
  else
    raw_out="$(bash "$adapter" --mode "$mode" --repo-root "$root_dir" --pr-number "$pr_num" 2>&1)"
  fi
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    local first_ln detail
    first_ln="${raw_out%%$'\n'*}"
    first_ln="${first_ln%$'\r'}"
    detail="${first_ln#GH_VERIFY_UNAVAILABLE: }"
    detail="${detail#GH_VERIFY_ERROR: }"
    detail="$(trim_str "$detail")"
    [[ -n "$detail" ]] || detail="unknown"
    if [[ $rc -eq 2 ]]; then
      echo "PROVIDER_UNAVAILABLE: github_verification_failed(${detail})"
      exit 2
    fi
    case "$detail" in
      origin_remote_missing|origin_remote_not_github|repo_mismatch|invalid_repo)
        echo "${err_pfx}: ${detail}"
        exit 1
        ;;
    esac
    echo "${err_pfx}: github_verification_failed(${detail})"
    exit 1
  fi
  local seen_keys="|" ln k v
  while IFS= read -r ln; do
    ln="${ln%$'\r'}"
    [[ -n "$ln" ]] || continue
    if [[ "$ln" != *"="* ]]; then
      echo "${err_pfx}: github_verification_failed(malformed_adapter_output)"
      exit 1
    fi
    k="${ln%%=*}"
    v="${ln#*=}"
    if [[ "$k" == "pr_changed_file" ]]; then
      [[ -n "$v" ]] && GH_PR_CHANGED_FILES+=("$v")
      continue
    fi
    case "$seen_keys" in
      *"|${k}|"*) echo "${err_pfx}: github_verification_failed(duplicate_adapter_key)"; exit 1 ;;
    esac
    seen_keys+="${k}|"
    case "$k" in
      schema) GH_SCHEMA="$v" ;;
      mode) GH_MODE="$v" ;;
      repo) GH_REPO="$v" ;;
      pr_number) GH_PR_NUMBER="$v" ;;
      base_repo) GH_BASE_REPO="$v" ;;
      head_repo) GH_HEAD_REPO="$v" ;;
      same_repo) GH_SAME_REPO="$v" ;;
      default_branch) GH_DEFAULT_BRANCH="$v" ;;
      pr_state) GH_PR_STATE="$v" ;;
      pr_merged) GH_PR_MERGED="$v" ;;
      pr_draft) GH_PR_DRAFT="$v" ;;
      base_ref) GH_BASE_REF="$v" ;;
      pr_base_sha) GH_PR_BASE_SHA="$v" ;;
      live_target_sha) GH_LIVE_TARGET_SHA="$v" ;;
      head_ref) GH_HEAD_REF="$v" ;;
      head_sha) GH_HEAD_SHA="$v" ;;
      policy_authority_ref) GH_POLICY_AUTH_REF="$v" ;;
      policy_authority_sha) GH_POLICY_AUTH_SHA="$v" ;;
      mergeable) GH_MERGEABLE="$v" ;;
      mergeable_state) GH_MERGEABLE_STATE="$v" ;;
      gh_ci_status) GH_CI_STATUS="$v" ;;
      merged_at) GH_MERGED_AT="$v" ;;
      merge_commit_sha) GH_MERGE_COMMIT_SHA="$v" ;;
      pr_commits) GH_PR_COMMITS="$v" ;;
      compare_status) GH_COMPARE_STATUS="$v" ;;
      compare_behind_by) GH_COMPARE_BEHIND="$v" ;;
    esac
  done <<< "$raw_out"
  if [[ ( "$GH_SCHEMA" != "b3-gh-verify-v2" && "$GH_SCHEMA" != "b3-gh-verify-v1" ) || "$GH_MODE" != "$mode" ]]; then
    echo "${err_pfx}: github_verification_failed(invalid_adapter_schema)"
    exit 1
  fi
}

_MP_NORM_PATH=""
normalize_merge_policy_path() {
  local LC_ALL=C
  local raw="$1"
  _MP_NORM_PATH=""
  [[ -n "$raw" ]] || return 1
  if has_ascii_cntrl "$raw"; then return 1; fi
  local s="${raw//\\//}"
  if [[ "$s" == "." || "$s" == "./" ]]; then
    _MP_NORM_PATH="."
    return 0
  fi
  if [[ "$s" == */ ]]; then
    s="${s%/}"
  fi
  if [[ "$s" == *:* || "$s" == /* || "$s" == ~* || "$s" == *'*'* || "$s" == *'?'* ]]; then
    return 1
  fi
  if ! is_valid_literal_git_path "$s"; then
    return 1
  fi
  _MP_NORM_PATH="$s"
  return 0
}

protected_path_match_ci() {
  local cand="$1"
  shift
  [[ -n "$cand" ]] || return 1
  local c_cmp="$cand" p p_cmp
  if [[ "${_MP_CASE_INSENSITIVE:-true}" == "true" ]]; then
    c_cmp="$(printf '%s' "$cand" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    if [[ "${_MP_CASE_INSENSITIVE:-true}" == "true" ]]; then
      p_cmp="$(printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    else
      p_cmp="$p"
    fi
    if [[ "$p_cmp" == "." || "$c_cmp" == "." || "$c_cmp" == "$p_cmp" || "$c_cmp" == "$p_cmp/"* || "$p_cmp" == "$c_cmp/"* ]]; then
      return 0
    fi
  done
  return 1
}

_LS_REMOTE_STATUS=""
_LS_REMOTE_SHA=""
git_ls_remote_ref() {
  local root="$1" full_ref="$2" out="" rc=0 line to_bin="" to_low=""
  _LS_REMOTE_STATUS="UNREACHABLE"
  _LS_REMOTE_SHA=""
  if [[ -x /usr/bin/timeout ]]; then
    to_bin="/usr/bin/timeout"
  else
    to_bin="$(command -v timeout 2>/dev/null || true)"
    to_low="$(printf '%s' "$to_bin" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [[ "$to_low" == */system32/* || "$to_low" == *\\system32\\* || "$to_low" == *windowsapps* ]] && to_bin=""
  fi
  if [[ -n "$to_bin" ]]; then
    if out="$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS="" SSH_ASKPASS="" "$to_bin" 8 git -C "$root" -c credential.helper= ls-remote --exit-code origin "$full_ref" 2>/dev/null)"; then rc=0; else rc=$?; fi
  else
    if out="$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS="" SSH_ASKPASS="" git -C "$root" -c credential.helper= ls-remote --exit-code origin "$full_ref" 2>/dev/null)"; then rc=0; else rc=$?; fi
  fi
  if [[ $rc -eq 2 ]]; then
    _LS_REMOTE_STATUS="MISSING"
    return 0
  fi
  if [[ $rc -eq 0 && -n "$out" ]]; then
    while IFS= read -r line; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^([0-9a-f]{40})$'\t' ]]; then
        _LS_REMOTE_STATUS="OK"
        _LS_REMOTE_SHA="${BASH_REMATCH[1]}"
        return 0
      fi
    done <<< "$out"
  fi
  return 0
}

_check_paths_covered_ci_mode() {
  local cand="$1" packed="$2" ci_mode="$3"
  local save_ci="$_B3_IS_CASE_INSENSITIVE_FS"
  _B3_IS_CASE_INSENSITIVE_FS="$ci_mode"
  local rc=0
  if ownership_path_match "$cand" "$packed"; then rc=0; else rc=1; fi
  _B3_IS_CASE_INSENSITIVE_FS="$save_ci"
  return $rc
}

assert_single_verify_receipt_matches_target() {
  local root="$1" rec_path="$2" ign_csv="$3" head_sha="$4" ci_mode="$5"
  shift 5
  local -a req_paths=("$@")
  if [[ -z "$head_sha" || ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "MERGE_BLOCKED: ci_evidence_invalid(invalid_head_sha)"
    exit 1
  fi
  local vr_rc=0
  set +e
  run_verify_check "$root" "$rec_path" "$ign_csv" "" "" "$head_sha"
  vr_rc=$?
  set -e
  if [[ $vr_rc -ne 0 ]]; then
    printf 'MERGE_BLOCKED: ci_evidence_invalid(%s)\n' "${_VR_MSG:-unknown}"
    exit 1
  fi
  if [[ "$_VR_REL_PATHS" != "ALL" ]]; then
    if [[ ${#req_paths[@]} -eq 0 ]]; then
      echo "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)"
      exit 1
    fi
    local -a rec_arr=()
    local rp cp
    while IFS= read -r rp; do [[ -n "$rp" ]] && rec_arr+=("$rp"); done < <(split_csv_lines "$_VR_REL_PATHS" true)
    local rec_packed=""
    [[ ${#rec_arr[@]} -gt 0 ]] && rec_packed="$(IFS='|'; printf '%s' "${rec_arr[*]}")"
    for cp in "${req_paths[@]}"; do
      if [[ -z "$rec_packed" ]] || ! _check_paths_covered_ci_mode "$cp" "$rec_packed" "$ci_mode"; then
        printf 'MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: %s)\n' "$cp"
        exit 1
      fi
    done
  fi
}

assert_local_ci_evidence() {
  local root="$1" head_sha="$2" rec_path="$3" led_meta_out="$4" ign_csv="$5" caller_ci="$6" req_ci="$7" ci_mode="$8"
  shift 8
  local -a chg_paths=("$@")
  local rec_trim
  rec_trim="$(trim_str "$rec_path")"
  if [[ -n "$rec_trim" ]]; then
    assert_single_verify_receipt_matches_target "$root" "$rec_trim" "$ign_csv" "$head_sha" "$ci_mode" ${chg_paths[@]+"${chg_paths[@]}"}
    return 0
  fi
  if [[ "$req_ci" != "true" ]]; then
    return 0
  fi
  if [[ -n "$led_meta_out" ]]; then
    local has_units=false has_all=false
    local -a unit_recs=() cov_arr=()
    local mline ur rp
    while IFS= read -r mline; do
      if [[ "$mline" == META_UNIT_RECEIPT=* ]]; then
        has_units=true
        unit_recs+=("${mline#META_UNIT_RECEIPT=}")
      fi
    done <<< "$led_meta_out"
    if $has_units; then
      for entry in "${unit_recs[@]}"; do
        local uid="${entry%%|*}"
        ur="${entry#*|}"
        if [[ -z "$ur" || "$ur" == "none" ]]; then
          printf 'MERGE_BLOCKED: ci_evidence_invalid(ledger_unit_missing_verify_receipt:%s)\n' "$uid"
          exit 1
        fi
        local vr_u=0
        set +e
        run_verify_check "$root" "$ur" "$ign_csv" "" "" "$head_sha"
        vr_u=$?
        set -e
        if [[ $vr_u -ne 0 ]]; then
          printf 'MERGE_BLOCKED: ci_evidence_invalid(%s)\n' "${_VR_MSG:-unknown}"
          exit 1
        fi
        if [[ "$_VR_REL_PATHS" == "ALL" ]]; then
          has_all=true
        else
          while IFS= read -r rp; do [[ -n "$rp" ]] && cov_arr+=("$rp"); done < <(split_csv_lines "$_VR_REL_PATHS" true)
        fi
      done
      if ! $has_all; then
        if [[ ${#chg_paths[@]} -eq 0 ]]; then
          echo "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)"
          exit 1
        fi
        local cov_packed=""
        [[ ${#cov_arr[@]} -gt 0 ]] && cov_packed="$(IFS='|'; printf '%s' "${cov_arr[*]}")"
        local cp
        for cp in "${chg_paths[@]}"; do
          if [[ -z "$cov_packed" ]] || ! _check_paths_covered_ci_mode "$cp" "$cov_packed" "$ci_mode"; then
            printf 'MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: %s)\n' "$cp"
            exit 1
          fi
        done
      fi
      return 0
    fi
  fi
  if [[ "$caller_ci" == "PASS" ]]; then
    echo "MERGE_BLOCKED: ci_evidence_unverified(caller_reported_ci_cannot_authorize)"
    exit 1
  fi
  echo "MERGE_BLOCKED: ci_evidence_missing"
  exit 1
}

is_secret_path() {
  local leaf="${1##*/}"
  leaf="$(printf '%s' "$leaf" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ -n "$leaf" ]] || return 1
  if [[ "$leaf" == ".env" ]]; then return 0; fi
  if [[ "$leaf" == .env.* ]]; then
    if [[ "$leaf" =~ ^\.env\.(example|sample|template)$ ]]; then return 1; fi
    return 0
  fi
  if [[ "$leaf" =~ \.(pem|key|p12|pfx)$ ]]; then return 0; fi
  case "$leaf" in
    id_rsa|id_ed25519|credentials.json) return 0 ;;
  esac
  return 1
}

resolve_git_dir() {
  local root="$1"
  local gd=""
  if run_git_cmd "$root" rev-parse --git-dir; then
    gd="$(trim_str "$_GIT_STDOUT")"
  fi
  [[ -n "$gd" ]] || return 1
  if [[ "$gd" != /* && ! "$gd" =~ ^[A-Za-z]: ]]; then
    gd="${root}/${gd}"
  fi
  printf '%s' "$gd"
}

check_git_mid_operation() {
  local root="$1"
  local git_dir marker
  git_dir="$(resolve_git_dir "$root")" || return 0
  for marker in MERGE_HEAD REBASE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [[ -e "${git_dir}/${marker}" ]]; then
      printf '%s' "$marker"
      return 0
    fi
  done
}

upper_drive_path() {
  local p="$1"
  local LC_ALL=C
  if [[ "$p" =~ ^[a-z]: ]]; then
    local drv
    drv="$(printf '%s' "${p:0:1}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    printf '%s' "${drv}${p:1}"
  else
    printf '%s' "$p"
  fi
}

canon_repo_root() {
  local raw="$1"
  [[ -n "$raw" && -d "$raw" ]] || return 1
  local res
  res="$(cd -P "$raw" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  res="$(norm_path "$res")"
  res="$(upper_drive_path "$res")"
  if [[ "$res" =~ ^[A-Za-z]:$ ]]; then
    res="${res}/"
  fi
  printf '%s' "$res"
}

normalize_abs_for_repo() {
  local p="$1"
  p="${p//$'\r'/}"
  p="${p//\\//}"
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    local re_msys='^/([A-Za-z])(/.*)?$'
    if [[ "$p" =~ $re_msys ]]; then
      if command -v cygpath >/dev/null 2>&1; then
        local cp
        cp="$(cygpath -m "$p" 2>/dev/null || true)"
        if [[ -n "$cp" ]]; then
          p="$cp"
        else
          p="${BASH_REMATCH[1]}:${BASH_REMATCH[2]:-/}"
        fi
      else
        p="${BASH_REMATCH[1]}:${BASH_REMATCH[2]:-/}"
      fi
    elif [[ "$p" == /* ]] && command -v cygpath >/dev/null 2>&1; then
      local cp
      cp="$(cygpath -m "$p" 2>/dev/null || true)"
      [[ -n "$cp" ]] && p="$cp"
    fi
    p="$(upper_drive_path "$p")"
  fi
  local re_winroot='^[A-Za-z]:/$'
  while [[ "$p" == */ && "$p" != "/" && ! "$p" =~ $re_winroot ]]; do
    p="${p%/}"
  done
  printf '%s' "$p"
}

resolve_target_path() {
  local root="$1"
  local p
  p="$(trim_str "$2")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if [[ "$p" == /* || "$p" =~ ^[A-Za-z]: ]]; then
    normalize_abs_for_repo "$p"
  else
    while [[ "$p" == ./* ]]; do
      p="${p#./}"
    done
    local r="${root%/}"
    normalize_abs_for_repo "${r}/${p}"
  fi
}

_path_within_or_equal() {
  local cand="$1"
  local root="$2"
  local cand_cmp="$cand"
  local root_cmp="$root"
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    cand_cmp="$(printf '%s' "$cand" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    root_cmp="$(printf '%s' "$root" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  if [[ "$root_cmp" == "/" ]]; then
    [[ "$cand_cmp" == /* ]]
    return $?
  fi
  local root_base="${root_cmp%/}"
  [[ "$cand_cmp" == "$root_cmp" || "$cand_cmp" == "$root_base/"* ]]
}

is_dir_link_or_junction() {
  local root="$1"
  local sub_rel="$2"
  local canon_root
  canon_root="$(canon_repo_root "$root")" || return 1
  local target="${canon_root%/}/${sub_rel}"
  [[ -L "$target" ]] && return 0
  if [[ -d "$target" ]]; then
    local canon_sub t_cmp c_cmp
    canon_sub="$(cd -P "$target" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 0
    canon_sub="$(normalize_abs_for_repo "$canon_sub")"
    t_cmp="$target"
    c_cmp="$canon_sub"
    if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
      t_cmp="$(printf '%s' "$t_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      c_cmp="$(printf '%s' "$c_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    fi
    [[ "$c_cmp" != "$t_cmp" ]] && return 0
  fi
  return 1
}

check_safe_repo_path_segments() {
  local LC_ALL=C
  local raw="$1"
  local block_git="${2:-true}"
  [[ -n "$raw" ]] || return 1
  if has_ascii_cntrl "$raw"; then
    return 1
  fi
  local s="${raw//\\//}"
  if [[ "$s" == *:* || "$s" == /* || "$s" == */ || "$s" == ~* || "$s" == *'*'* || "$s" == *'?'* ]]; then
    return 1
  fi
  local rem="$s" seg
  while true; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    if [[ -z "$seg" || "$seg" == "." || "$seg" == ".." || "$seg" == *. || "$seg" == *" " ]]; then
      return 1
    fi
    [[ -n "$rem" ]] || break
  done
  if [[ "$block_git" == "true" ]]; then
    local s_low re_git_any='(^|/)\.git(/|$)'
    s_low="$(printf '%s' "$s" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$s_low" =~ $re_git_any ]]; then
      return 1
    fi
  fi
  return 0
}

_SAFE_FULL=""
_SAFE_REL=""
validate_repo_write_path() {
  _SAFE_FULL=""
  _SAFE_REL=""
  local LC_ALL=C
  local raw_root="$1"
  local raw_arg="$2"
  [[ -n "$raw_arg" ]] || return 1
  if has_ascii_cntrl "$raw_arg" || [[ "$raw_arg" == *" " ]]; then
    return 1
  fi
  local root
  root="$(canon_repo_root "$raw_root")" || return 1
  local p
  p="$(trim_str "$raw_arg")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if [[ "$p" == "." || "$p" == ~* || "$p" == */ ]]; then
    return 1
  fi

  local raw_tail="$p"
  if [[ "$_B3_IS_WINDOWS" == "true" && "$p" =~ ^[A-Za-z]:/ ]]; then
    raw_tail="${p:3}"
  elif [[ "$p" == /* ]]; then
    raw_tail="${p#/}"
  fi
  if ! check_safe_repo_path_segments "$raw_tail" false; then
    return 1
  fi

  local full
  full="$(resolve_target_path "$root" "$p")" || return 1
  [[ -n "$full" ]] || return 1

  local root_cmp="$root" full_cmp="$full"
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    root_cmp="$(printf '%s' "$root" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    full_cmp="$(printf '%s' "$full" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi

  local prefix prefix_cmp rel
  if [[ "$root_cmp" == "/" ]]; then
    if [[ "$full_cmp" == "/" || "$full_cmp" != /* ]]; then
      return 1
    fi
    rel="${full:1}"
  else
    local root_base="${root%/}"
    local root_base_cmp="${root_cmp%/}"
    prefix="${root_base}/"
    prefix_cmp="${root_base_cmp}/"
    if [[ "$full_cmp" == "$root_cmp" || "$full_cmp" == "$root_base_cmp" || "$full_cmp" == "$prefix_cmp" || "$full_cmp" != "$prefix_cmp"* ]]; then
      return 1
    fi
    rel="${full:${#prefix}}"
  fi

  if ! check_safe_repo_path_segments "$rel" true; then
    return 1
  fi

  local rem="$rel" seg_cur="${root%/}" seg canon_seg seg_cur_cmp canon_seg_cmp
  while [[ -n "$rem" ]]; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    [[ -z "$seg" || "$seg" == "." ]] && continue
    if [[ "$seg" == ".." ]]; then
      return 1
    fi
    seg_cur="${seg_cur}/${seg}"
    seg_cur="${seg_cur%/}"
    if [[ -L "$seg_cur" ]]; then
      return 1
    fi
    if [[ -d "$seg_cur" ]]; then
      canon_seg="$(cd -P "$seg_cur" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
      canon_seg="$(normalize_abs_for_repo "$canon_seg")"
      if ! _path_within_or_equal "$canon_seg" "$root"; then
        return 1
      fi
      seg_cur_cmp="$seg_cur"
      canon_seg_cmp="$canon_seg"
      if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
        seg_cur_cmp="$(printf '%s' "$seg_cur_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        canon_seg_cmp="$(printf '%s' "$canon_seg_cmp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      fi
      if [[ "$canon_seg_cmp" != "$seg_cur_cmp" ]]; then
        return 1
      fi
    fi
  done

  local anc next_anc re_winroot='^[A-Za-z]:/$'
  anc="$(dirname "$full")"
  [[ "$anc" =~ ^[A-Za-z]:$ ]] && anc="${anc}/"
  while [[ -n "$anc" && "$anc" != "/" && ! "$anc" =~ $re_winroot && ! -d "$anc" ]]; do
    next_anc="$(dirname "$anc")"
    [[ "$next_anc" =~ ^[A-Za-z]:$ ]] && next_anc="${next_anc}/"
    [[ "$next_anc" == "$anc" ]] && break
    anc="$next_anc"
  done
  if [[ -d "$anc" ]]; then
    local canon_anc
    canon_anc="$(cd -P "$anc" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
    canon_anc="$(normalize_abs_for_repo "$canon_anc")"
    if ! _path_within_or_equal "$canon_anc" "$root"; then
      return 1
    fi
  fi

  local full_clean="${root%/}/${rel}"
  _SAFE_FULL="$full_clean"
  _SAFE_REL="$rel"
  return 0
}

remove_dir_tree_safely() {
  local dir="$1"
  while [[ "$dir" == */ && "$dir" != "/" ]]; do
    dir="${dir%/}"
  done
  if [[ -L "$dir" ]]; then
    echo "PRUNE_FAIL: refusing recursive delete of link path: $dir"
    exit 1
  fi
  if [[ ! -e "$dir" ]]; then
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    rm -f "$dir"
    return 0
  fi
  local entry base ps_exe win_path
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    base="${entry##*/}"
    [[ "$base" == "." || "$base" == ".." ]] && continue
    if [[ -L "$entry" ]]; then
      if [[ "$_B3_IS_WINDOWS" == "true" ]] && [[ -d "$entry" || ! -e "$entry" ]]; then
        ps_exe=""
        win_path=""
        if command -v powershell.exe >/dev/null 2>&1; then
          ps_exe="powershell.exe"
        elif command -v powershell >/dev/null 2>&1; then
          ps_exe="powershell"
        elif command -v pwsh >/dev/null 2>&1; then
          ps_exe="pwsh"
        elif [[ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
          ps_exe="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        fi
        if [[ -n "$ps_exe" ]] && command -v cygpath >/dev/null 2>&1; then
          win_path="$(cygpath -w "$entry" 2>/dev/null || true)"
        fi
        if [[ -n "$ps_exe" && -n "$win_path" ]]; then
          B3_WIN_PATH="$win_path" "$ps_exe" -NoProfile -NonInteractive -Command '[System.IO.Directory]::Delete($env:B3_WIN_PATH, $false)' >/dev/null 2>&1 || rm -f "$entry"
        else
          rm -f "$entry"
        fi
      else
        rm -f "$entry"
      fi
    elif [[ -d "$entry" ]]; then
      remove_dir_tree_safely "$entry"
    else
      rm -f "$entry"
    fi
  done
  rmdir "$dir"
}

write_atomic_lf_file() {
  local dest="$1"
  local content="$2"
  if [[ -d "$dest" || -L "$dest" ]]; then
    echo "WRITE_ERROR: refusing to write over directory or link: $dest"
    exit 1
  fi
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  if ! tmp="$(mktemp "${parent}/.b3-tmp.XXXXXX" 2>/dev/null)"; then
    local try=0 cand=""
    tmp=""
    while [[ $try -lt 16 ]]; do
      cand="${parent}/.b3-tmp.$$.${RANDOM}.${try}"
      if ( set -C; : > "$cand" ) 2>/dev/null; then
        tmp="$cand"
        break
      fi
      try=$((try + 1))
    done
    if [[ -z "$tmp" ]]; then
      echo "WRITE_ERROR: failed to create temp file in $parent"
      exit 1
    fi
  fi
  _CLEANUP_FILES+=("$tmp")
  printf '%s' "$content" | LC_ALL=C tr -d '\r' > "$tmp"
  mv -f "$tmp" "$dest"
}

resolve_symlink_oid() {
  local root="$1"
  local rel_p="$2"
  local full="${root}/${rel_p}"
  local sha
  if [[ -L "$full" ]]; then
    local tgt
    tgt="$(readlink "$full")"
    hash_git_text "$root" "$tgt" "GIT_ERROR" "symlink failed for ${rel_p}" || return 1
    return 0
  elif [[ -f "$full" ]]; then
    if ! run_git_cmd "$root" hash-object -- "$rel_p"; then
      echo "GIT_ERROR: git hash-object failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object failed for ${rel_p}: $sha"
      return 1
    fi
    printf '%s' "$sha"
    return 0
  fi
  return 2
}

resolve_submodule_entry() {
  local root="$1"
  local rel_p="$2"
  local fallback_oid="${3:-}"
  local depth="${4:-0}"
  local sub_full="${root}/${rel_p}"
  local zero_oid="0000000000000000000000000000000000000000"
  local has_fb=false
  if [[ -n "$fallback_oid" && "$fallback_oid" != "$zero_oid" && "$fallback_oid" =~ ^[0-9a-f]{40}$ ]]; then
    has_fb=true
  fi

  if [[ -d "$sub_full" && -e "${sub_full}/.git" ]]; then
    local sub_head="" has_head=false sh_out
    if run_git_cmd "$sub_full" rev-parse HEAD; then
      sh_out="$(trim_str "$_GIT_STDOUT")"
      if [[ "$sh_out" =~ ^[0-9a-f]{40}$ ]]; then
        sub_head="$sh_out"
        has_head=true
      fi
    fi
    if ! $has_head; then
      if $has_fb; then sub_head="$fallback_oid"; else sub_head="UNBORN"; fi
    fi

    local st_tmp_sub rc_sub=0
    make_temp_file "b3-sub-st" st_tmp_sub
    if git -C "$sub_full" -c core.quotepath=false status --porcelain -uall --ignore-submodules=none -z >"$st_tmp_sub" 2>"$_B3_GIT_ERR_FILE"; then rc_sub=0; else rc_sub=$?; fi
    if [[ $rc_sub -ne 0 ]]; then
      _GIT_STDERR=""; [[ -f "$_B3_GIT_ERR_FILE" ]] && _GIT_STDERR="$(< "$_B3_GIT_ERR_FILE")"
      rm -f "$st_tmp_sub" 2>/dev/null || true
      echo "GIT_ERROR: submodule status failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local -a st_lines=()
    local raw_st=""
    while IFS= read -r -d '' raw_st; do
      [[ -n "$raw_st" ]] && st_lines+=("$raw_st")
    done < "$st_tmp_sub"
    rm -f "$st_tmp_sub" 2>/dev/null || true

    if [[ ${#st_lines[@]} -eq 0 ]]; then
      printf '160000 commit %s' "$sub_head"
      return 0
    fi

    local dirty_buf="" sl
    while IFS= read -r sl; do
      [[ -n "$sl" ]] && dirty_buf="${dirty_buf}S ${sl}"$'\n'
    done < <(printf '%s\n' "${st_lines[@]}" | LC_ALL=C sort)

    local -a s_cands=()
    local sp_seen="|" sp
    if $has_head; then
      run_git_paths_z "$sub_full" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --name-only --ignore-submodules=none -z HEAD -- || return 1
      for sp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        if [[ -n "$sp" && "$sp_seen" != *"|${sp}|"* ]]; then sp_seen+="${sp}|"; s_cands+=("$sp"); fi
      done
    fi
    run_git_paths_z "$sub_full" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --cached --name-only -z -- || return 1
    for sp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
      if [[ -n "$sp" && "$sp_seen" != *"|${sp}|"* ]]; then sp_seen+="${sp}|"; s_cands+=("$sp"); fi
    done
    run_git_paths_z "$sub_full" "names" "GIT_ERROR" "" -- ls-files --others --exclude-standard -z || return 1
    for sp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
      if [[ -n "$sp" && "$sp_seen" != *"|${sp}|"* ]]; then sp_seen+="${sp}|"; s_cands+=("$sp"); fi
    done

    if [[ ${#s_cands[@]} -gt 0 ]]; then
      local sp_full f_sha n_tag
      while IFS= read -r sp; do
        [[ -n "$sp" ]] || continue
        sp_full="${sub_full}/${sp}"
        if [[ -L "$sp_full" ]]; then
          local l_sha="" rc_l=0
          if l_sha="$(resolve_symlink_oid "$sub_full" "$sp")"; then
            dirty_buf="${dirty_buf}C ${sp} 120000:${l_sha}"$'\n'
          else
            rc_l=$?
            if [[ $rc_l -eq 1 ]]; then echo "$l_sha"; return 1; fi
            dirty_buf="${dirty_buf}C ${sp} DELETED"$'\n'
          fi
        elif [[ -f "$sp_full" ]]; then
          if ! run_git_cmd "$sub_full" hash-object -- "$sp"; then
            echo "GIT_ERROR: submodule hash-object failed for ${rel_p}/${sp}: $(git_err_detail)"
            return 1
          fi
          f_sha="$(trim_str "$_GIT_STDOUT")"
          if [[ ! "$f_sha" =~ ^[0-9a-f]{40}$ ]]; then
            echo "GIT_ERROR: submodule hash-object failed for ${rel_p}/${sp}: $f_sha"
            return 1
          fi
          dirty_buf="${dirty_buf}C ${sp} ${f_sha}"$'\n'
        elif [[ -d "$sp_full" ]]; then
          if [[ -e "${sp_full}/.git" ]]; then
            if [[ "$depth" -ge 5 ]]; then
              echo "GIT_ERROR: nested submodule depth exceeded for ${rel_p}/${sp}"
              return 1
            fi
            local nested_val="" rc_n=0
            if nested_val="$(resolve_submodule_entry "$sub_full" "$sp" "" $((depth + 1)))"; then
              n_tag="$nested_val"
            else
              rc_n=$?
              if [[ $rc_n -eq 1 ]]; then echo "$nested_val"; return 1; fi
              n_tag="DIR"
            fi
          else
            n_tag="DIR"
          fi
          dirty_buf="${dirty_buf}D ${sp} ${n_tag}"$'\n'
        else
          dirty_buf="${dirty_buf}C ${sp} DELETED"$'\n'
        fi
      done < <(printf '%s\n' "${s_cands[@]}" | LC_ALL=C sort -u)
    fi

    local d_sha
    d_sha="$(hash_git_text "$root" "$dirty_buf" "GIT_ERROR" "submodule digest failed for ${rel_p}")" || { echo "$d_sha"; return 1; }
    printf '160000 commit %s+dirty:%s' "$sub_head" "$d_sha"
    return 0
  fi

  if $has_fb; then
    printf '160000 commit %s' "$fallback_oid"
    return 0
  fi
  return 2
}

compute_tree_fingerprint() {
  local root="$1"
  local rel_csv="$2"
  local ign_csv="$3"
  local target_commit_sha="${4:-}"
  local target_trim
  target_trim="$(trim_str "$target_commit_sha")"
  local head_sha
  if [[ -n "$target_trim" ]]; then
    if [[ "$target_trim" == -* ]]; then
      echo "GIT_ERROR: invalid target commit sha: $target_trim"
      return 1
    fi
    if ! run_git_cmd "$root" rev-parse --verify "${target_trim}^{commit}"; then
      echo "GIT_ERROR: git rev-parse ${target_trim} failed: $(git_err_detail)"
      return 1
    fi
    head_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git rev-parse ${target_trim} failed: $head_sha"
      return 1
    fi
  else
    if ! run_git_cmd "$root" rev-parse HEAD; then
      echo "GIT_ERROR: git rev-parse HEAD failed: $(git_err_detail)"
      return 1
    fi
    head_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"
      return 1
    fi
  fi

  local -a ign_arr=()
  while IFS= read -r p; do [[ -n "$p" ]] && ign_arr+=("$p"); done < <(split_csv_lines "$ign_csv" true | LC_ALL=C sort -u)

  local -a clean_rel=()
  local -a raw_rel=()
  while IFS= read -r p; do [[ -n "$p" ]] && raw_rel+=("$p"); done < <(split_csv_lines "$rel_csv" true)
  if [[ ${#raw_rel[@]} -gt 0 ]]; then
    while IFS= read -r np; do
      [[ -n "$np" ]] || continue
      is_checkpoint_dir "$np" && continue
      if [[ ${#ign_arr[@]} -gt 0 ]] && path_in_list "$np" "${ign_arr[@]}"; then continue; fi
      clean_rel+=("$np")
    done < <(printf '%s\n' "${raw_rel[@]}" | LC_ALL=C sort -u)
    if [[ ${#clean_rel[@]} -eq 0 ]]; then
      echo "TREE_FP_FAIL: relevant paths resolved to empty after exclusions"
      return 1
    fi
  fi

  local paths_csv="ALL" clean_ign_csv="" clean_rel_csv=""
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    paths_csv="$(printf '%s\n' "${clean_rel[@]}" | paste -sd ',' -)"
    clean_rel_csv="$paths_csv"
  fi
  if [[ ${#ign_arr[@]} -gt 0 ]]; then
    clean_ign_csv="$(printf '%s\n' "${ign_arr[@]}" | paste -sd ',' -)"
  fi

  local tree_ref="HEAD"
  if [[ -n "$target_trim" ]]; then
    tree_ref="$head_sha"
  fi

  local ls_out="" diff_head_raw="" diff_cached_raw="" diff_idx_wt_raw="" untracked="" resolved_lines=""
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    run_git_cmd "$root" ls-tree -r "$tree_ref" -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
  else
    run_git_cmd "$root" ls-tree -r "$tree_ref" || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
  fi

  if [[ -z "$target_trim" ]]; then
    local is_win_os=false
    case "$(uname -s 2>/dev/null || printf '')" in
      MINGW*|MSYS*|CYGWIN*) is_win_os=true ;;
    esac
    local core_filemode=false
    if run_git_cmd_quiet "$root" config --bool core.filemode; then
      [[ "$(trim_str "$_GIT_STDOUT")" == "true" ]] && core_filemode=true
    else
      ! $is_win_os && core_filemode=true
    fi

    if [[ ${#clean_rel[@]} -gt 0 ]]; then
      run_git_cmd "$root" diff --no-ext-diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
      diff_head_raw="$_GIT_STDOUT"
      run_git_cmd "$root" diff --no-ext-diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
      diff_cached_raw="$_GIT_STDOUT"
      run_git_cmd "$root" diff --no-ext-diff --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
      diff_idx_wt_raw="$_GIT_STDOUT"
      run_git_paths_z "$root" "names" "GIT_ERROR" "" ls-files --others --exclude-standard -z -- "${clean_rel[@]}" || return 1
    else
      run_git_cmd "$root" diff --no-ext-diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD -- || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
      diff_head_raw="$_GIT_STDOUT"
      run_git_cmd "$root" diff --no-ext-diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none -- || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
      diff_cached_raw="$_GIT_STDOUT"
      run_git_cmd "$root" diff --no-ext-diff --raw --no-renames --no-abbrev --ignore-submodules=none -- || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
      diff_idx_wt_raw="$_GIT_STDOUT"
      run_git_paths_z "$root" "names" "GIT_ERROR" "" ls-files --others --exclude-standard -z || return 1
    fi
    untracked=""
    if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then
      untracked="$(printf '%s\n' "${_GIT_PATHS_Z[@]}")"
    fi

    local tasks_raw
    tasks_raw="$({
      printf '__HEAD__\n%s\n' "$diff_head_raw"
      printf '__CACHED__\n%s\n' "$diff_cached_raw"
      printf '__IDXWT__\n%s\n' "$diff_idx_wt_raw"
      printf '__UNTRACKED__\n%s\n' "$untracked"
    } | LC_ALL=C awk -v ign_csv="$clean_ign_csv" -v rel_csv="$clean_rel_csv" '
      function norm_p(s) {
        gsub(/\r/, "", s)
        gsub(/\\/, "/", s)
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        sub(/^\.\//, "", s)
        while (length(s) > 1 && substr(s, length(s), 1) == "/") s = substr(s, 1, length(s) - 1)
        return s
      }
      function is_cp(s) {
        return (s ~ /^\.b3\/(ship|research-ship|autodev)(\/|$)/)
      }
      function in_list(s, arr, n,    i, pat) {
        for (i = 1; i <= n; i++) {
          pat = arr[i]
          if (pat == "") continue
          if (pat == "." || s == pat || index(s, pat "/") == 1) return 1
        }
        return 0
      }
      function accept_path(fp) {
        if (fp == "" || is_cp(fp)) return 0
        if (n_ign > 0 && in_list(fp, ign_arr, n_ign)) return 0
        if (n_rel > 0 && !in_list(fp, rel_arr, n_rel)) return 0
        return 1
      }
      function parse_raw(line, out_m, out_o,    ti, meta, nmp, mp, fp, nm, noid) {
        if (substr(line, 1, 1) != ":" || substr(line, 1, 2) == "::") return
        ti = index(line, "\t")
        if (ti < 3) return
        meta = substr(line, 2, ti - 2)
        nmp = split(meta, mp, /[ \t]+/)
        if (nmp < 5) return
        nm = mp[2]; noid = mp[4]
        if (length(nm) != 6 || nm !~ /^[0-9]+$/ || length(noid) != 40 || noid !~ /^[0-9a-f]+$/) return
        fp = norm_p(substr(line, ti + 1))
        if (!accept_path(fp)) return
        if ((fp in out_m) && nm == "000000" && out_m[fp] != "000000") return
        out_m[fp] = nm
        out_o[fp] = noid
      }
      BEGIN {
        split("", ign_arr); split("", rel_arr)
        split("", h_m); split("", h_o); split("", c_m); split("", c_o); split("", iw); split("", untr)
        n_ign = (ign_csv == "" ? 0 : split(ign_csv, ign_arr, ","))
        n_rel = (rel_csv == "" ? 0 : split(rel_csv, rel_arr, ","))
        sec = ""
      }
      { gsub(/\r$/, "", $0) }
      $0 == "__HEAD__" || $0 == "__CACHED__" || $0 == "__IDXWT__" || $0 == "__UNTRACKED__" { sec = $0; next }
      $0 == "" { next }
      sec == "__HEAD__" { parse_raw($0, h_m, h_o); next }
      sec == "__CACHED__" { parse_raw($0, c_m, c_o); next }
      sec == "__IDXWT__" {
        if (substr($0, 1, 1) != ":" || substr($0, 1, 2) == "::") next
        ti = index($0, "\t")
        if (ti < 3) next
        fp = norm_p(substr($0, ti + 1))
        if (accept_path(fp)) iw[fp] = 1
        next
      }
      sec == "__UNTRACKED__" {
        fp = norm_p($0)
        if (accept_path(fp)) untr[fp] = 1
        next
      }
      END {
        z = "0000000000000000000000000000000000000000"
        for (fp in h_m) {
          m = h_m[fp]; oid = h_o[fp]
          if (m == "000000") continue
          if (m == "160000") {
            fb = (oid != z ? oid : ((fp in c_m && c_m[fp] == "160000" && c_o[fp] != z) ? c_o[fp] : "-"))
            printf "SUB\t%s\t%s\n", fb, fp
            continue
          }
          if (m == "120000") {
            if (oid != z) continue
            if ((fp in c_m) && c_m[fp] == "120000" && c_o[fp] != z && !(fp in iw)) continue
            printf "LINK\t-\t%s\n", fp
            continue
          }
          if (oid != z) continue
          if ((fp in c_m) && c_m[fp] == m && c_o[fp] != z && !(fp in iw)) continue
          printf "BLOB\t%s\t%s\n", m, fp
        }
        for (fp in untr) {
          if (!(fp in h_m) || h_m[fp] == "000000") {
            printf "UNTR\t-\t%s\n", fp
          }
        }
      }
    ')"

    local kind arg p full_p res_val rc_r=0 w_sha l_sha u_mode
    while IFS=$'\t' read -r kind arg p; do
      [[ -n "$kind" && -n "$p" ]] || continue
      full_p="${root}/${p}"
      case "$kind" in
        SUB)
          [[ "$arg" == "-" ]] && arg=""
          if res_val="$(resolve_submodule_entry "$root" "$p" "$arg")"; then
            resolved_lines="${resolved_lines}${p}"$'\t'"${res_val}"$'\n'
          else
            rc_r=$?
            if [[ $rc_r -eq 1 ]]; then echo "$res_val"; return 1; fi
            resolved_lines="${resolved_lines}${p}"$'\t'"DELETED"$'\n'
          fi
          ;;
        LINK)
          if l_sha="$(resolve_symlink_oid "$root" "$p")"; then
            resolved_lines="${resolved_lines}${p}"$'\t'"120000 blob ${l_sha}"$'\n'
          else
            rc_r=$?
            if [[ $rc_r -eq 1 ]]; then echo "$l_sha"; return 1; fi
            resolved_lines="${resolved_lines}${p}"$'\t'"DELETED"$'\n'
          fi
          ;;
        BLOB)
          if [[ -f "$full_p" ]]; then
            if ! run_git_cmd "$root" hash-object -- "$p"; then
              echo "GIT_ERROR: git hash-object failed for ${p}: $(git_err_detail)"
              return 1
            fi
            w_sha="$(trim_str "$_GIT_STDOUT")"
            if [[ ! "$w_sha" =~ ^[0-9a-f]{40}$ ]]; then
              echo "GIT_ERROR: git hash-object failed for ${p}: $w_sha"
              return 1
            fi
            resolved_lines="${resolved_lines}${p}"$'\t'"${arg} blob ${w_sha}"$'\n'
          else
            resolved_lines="${resolved_lines}${p}"$'\t'"DELETED"$'\n'
          fi
          ;;
        UNTR)
          if [[ -L "$full_p" ]]; then
            if l_sha="$(resolve_symlink_oid "$root" "$p")"; then
              resolved_lines="${resolved_lines}${p}"$'\t'"120000 blob ${l_sha}"$'\n'
            else
              rc_r=$?
              if [[ $rc_r -eq 1 ]]; then echo "$l_sha"; return 1; fi
            fi
          elif [[ -f "$full_p" ]]; then
            if ! run_git_cmd "$root" hash-object -- "$p"; then
              echo "GIT_ERROR: git hash-object failed for ${p}: $(git_err_detail)"
              return 1
            fi
            w_sha="$(trim_str "$_GIT_STDOUT")"
            if [[ ! "$w_sha" =~ ^[0-9a-f]{40}$ ]]; then
              echo "GIT_ERROR: git hash-object failed for ${p}: $w_sha"
              return 1
            fi
            u_mode="100644"
            if ! $is_win_os && $core_filemode && [[ -x "$full_p" ]]; then u_mode="100755"; fi
            resolved_lines="${resolved_lines}${p}"$'\t'"${u_mode} blob ${w_sha}"$'\n'
          elif [[ -d "$full_p" && -e "${full_p}/.git" ]]; then
            if res_val="$(resolve_submodule_entry "$root" "$p" "")"; then
              resolved_lines="${resolved_lines}${p}"$'\t'"${res_val}"$'\n'
            else
              rc_r=$?
              if [[ $rc_r -eq 1 ]]; then echo "$res_val"; return 1; fi
            fi
          fi
          ;;
      esac
    done <<< "$tasks_raw"
  fi

  local tmp_fp tree_hash
  make_temp_file "b3-tree-fp" tmp_fp

  {
    printf 'PATHS=%s\n' "$paths_csv"
    {
      printf '__LS__\n%s\n' "$ls_out"
      printf '__HEAD__\n%s\n' "$diff_head_raw"
      printf '__CACHED__\n%s\n' "$diff_cached_raw"
      printf '__IDXWT__\n%s\n' "$diff_idx_wt_raw"
      printf '__RESOLVED__\n%s' "$resolved_lines"
    } | LC_ALL=C awk -v ign_csv="$clean_ign_csv" -v rel_csv="$clean_rel_csv" '
      function norm_p(s) {
        gsub(/\r/, "", s)
        gsub(/\\/, "/", s)
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        sub(/^\.\//, "", s)
        while (length(s) > 1 && substr(s, length(s), 1) == "/") s = substr(s, 1, length(s) - 1)
        return s
      }
      function is_cp(s) {
        return (s ~ /^\.b3\/(ship|research-ship|autodev)(\/|$)/)
      }
      function in_list(s, arr, n,    i, pat) {
        for (i = 1; i <= n; i++) {
          pat = arr[i]
          if (pat == "") continue
          if (pat == "." || s == pat || index(s, pat "/") == 1) return 1
        }
        return 0
      }
      function accept_path(fp) {
        if (fp == "" || is_cp(fp)) return 0
        if (n_ign > 0 && in_list(fp, ign_arr, n_ign)) return 0
        if (n_rel > 0 && !in_list(fp, rel_arr, n_rel)) return 0
        return 1
      }
      function entry_type(m) {
        if (m == "160000") return "commit"
        if (m == "000000") return "deleted"
        if (m == "040000") return "tree"
        return "blob"
      }
      function parse_raw(line, out_m, out_o,    ti, meta, nmp, mp, fp, nm, noid) {
        if (substr(line, 1, 1) != ":" || substr(line, 1, 2) == "::") return
        ti = index(line, "\t")
        if (ti < 3) return
        meta = substr(line, 2, ti - 2)
        nmp = split(meta, mp, /[ \t]+/)
        if (nmp < 5) return
        nm = mp[2]; noid = mp[4]
        if (length(nm) != 6 || nm !~ /^[0-9]+$/ || length(noid) != 40 || noid !~ /^[0-9a-f]+$/) return
        fp = norm_p(substr(line, ti + 1))
        if (!accept_path(fp)) return
        if ((fp in out_m) && nm == "000000" && out_m[fp] != "000000") return
        out_m[fp] = nm
        out_o[fp] = noid
      }
      BEGIN {
        split("", ign_arr); split("", rel_arr)
        split("", eff); split("", h_m); split("", h_o); split("", c_m); split("", c_o); split("", iw); split("", res)
        n_ign = (ign_csv == "" ? 0 : split(ign_csv, ign_arr, ","))
        n_rel = (rel_csv == "" ? 0 : split(rel_csv, rel_arr, ","))
        sec = ""
      }
      { gsub(/\r$/, "", $0) }
      $0 == "__LS__" || $0 == "__HEAD__" || $0 == "__CACHED__" || $0 == "__IDXWT__" || $0 == "__RESOLVED__" { sec = $0; next }
      $0 == "" { next }
      sec == "__LS__" {
        ti = index($0, "\t")
        if (ti < 2) next
        meta = substr($0, 1, ti - 1)
        nm = split(meta, mp, /[ \t]+/)
        if (nm < 3 || length(mp[1]) != 6 || mp[1] !~ /^[0-9]+$/ || (mp[2] != "blob" && mp[2] != "commit") || length(mp[3]) != 40 || mp[3] !~ /^[0-9a-f]+$/) next
        fp = norm_p(substr($0, ti + 1))
        if (!accept_path(fp)) next
        eff[fp] = mp[1] " " mp[2] " " mp[3]
        next
      }
      sec == "__HEAD__" { parse_raw($0, h_m, h_o); next }
      sec == "__CACHED__" { parse_raw($0, c_m, c_o); next }
      sec == "__IDXWT__" {
        if (substr($0, 1, 1) != ":" || substr($0, 1, 2) == "::") next
        ti = index($0, "\t")
        if (ti < 3) next
        fp = norm_p(substr($0, ti + 1))
        if (accept_path(fp)) iw[fp] = 1
        next
      }
      sec == "__RESOLVED__" {
        ti = index($0, "\t")
        if (ti < 2) next
        fp = substr($0, 1, ti - 1)
        res[fp] = substr($0, ti + 1)
        next
      }
      END {
        z = "0000000000000000000000000000000000000000"
        for (fp in h_m) {
          m = h_m[fp]; oid = h_o[fp]
          if (m == "000000") {
            delete eff[fp]
          } else if (fp in res) {
            if (res[fp] == "DELETED") delete eff[fp]
            else eff[fp] = res[fp]
          } else if (oid != z) {
            eff[fp] = m " blob " oid
          } else if ((fp in c_m) && c_m[fp] == m && c_o[fp] != z && !(fp in iw)) {
            eff[fp] = m " blob " c_o[fp]
          } else {
            delete eff[fp]
          }
        }
        for (fp in res) {
          if (!(fp in h_m) || h_m[fp] == "000000") {
            if (res[fp] == "DELETED") delete eff[fp]
            else eff[fp] = res[fp]
          }
        }
        for (fp in c_m) {
          cm = c_m[fp]
          has_e = (fp in eff)
          c_entry = cm " " entry_type(cm) " " c_o[fp]
          if ((cm == "000000" && has_e) || (cm != "000000" && (!has_e || eff[fp] != c_entry))) {
            printf "I\t%s\t%s\n", fp, c_entry
          }
        }
        for (fp in eff) {
          printf "E\t%s\t%s\n", fp, eff[fp]
        }
      }
    ' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | LC_ALL=C awk -F '\t' '{ printf "%s %s %s\n", $1, $3, $2 }'
  } > "$tmp_fp"

  if ! tree_hash="$(hash_git_stdin_file "$root" "$tmp_fp" "GIT_ERROR" "manifest failed")"; then
    rm -f "$tmp_fp"
    echo "$tree_hash"
    return 1
  fi
  rm -f "$tmp_fp"
  printf '%s\n%s\n%s\n' "$head_sha" "$tree_hash" "$paths_csv"
}

run_verify_check() {
  local root="$1"
  local receipt_arg="$2"
  local ign_csv="$3"
  local expected_cmd_arg="${4:-}"
  local req_rel_arg="${5:-}"
  local target_commit_sha="${6:-}"
  _VR_MSG=""
  _VR_REL_PATHS=""
  local canon_r
  if ! canon_r="$(canon_repo_root "$root")"; then
    _VR_MSG="VERIFY_CHECK_FAIL: invalid --repo-root"
    return 1
  fi
  root="$canon_r"
  local trim_arg
  trim_arg="$(trim_str "$receipt_arg")"
  if [[ -z "$trim_arg" ]]; then
    _VR_MSG="VERIFY_MISSING: empty receipt path"
    return 1
  fi
  if ! check_contained_repo_path "$root" "$trim_arg"; then
    _VR_MSG="VERIFY_CORRUPT: invalid receipt_path"
    return 1
  fi
  local full_receipt="$_CONTAINED_FULL" disp_path="$_CONTAINED_REL"
  if [[ ! -f "$full_receipt" ]]; then
    _VR_MSG="VERIFY_MISSING: $disp_path"
    return 1
  fi

  local _v_schema="" _v_task_id="" _v_scope="" _v_head_sha="" _v_tree_hash="" _v_relevant_paths="" _v_exit_code="" _v_status="" _v_command="" _v_log_path="" _v_timestamp_utc="" _v_duration_ms="" _has_duration_ms="false"
  local _seen_keys="|"
  local raw_line ln k v
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ln="$(trim_str "$raw_line")"
    [[ -z "$ln" ]] && continue
    if [[ "$ln" != *"="* ]]; then
      _VR_MSG="VERIFY_CORRUPT: malformed line in receipt"
      return 1
    fi
    k="$(trim_str "${ln%%=*}")"
    [[ -n "$k" ]] || { _VR_MSG="VERIFY_CORRUPT: malformed line in receipt"; return 1; }
    v="$(trim_str "${ln#*=}")"
    if [[ "$_seen_keys" == *"|${k}|"* ]]; then
      _VR_MSG="VERIFY_CORRUPT: duplicate field '$k'"
      return 1
    fi
    _seen_keys="${_seen_keys}${k}|"
    case "$k" in
      schema) _v_schema="$v" ;;
      task_id) _v_task_id="$v" ;;
      scope) _v_scope="$v" ;;
      head_sha) _v_head_sha="$v" ;;
      tree_hash) _v_tree_hash="$v" ;;
      relevant_paths) _v_relevant_paths="$v" ;;
      exit_code) _v_exit_code="$v" ;;
      status) _v_status="$v" ;;
      duration_ms) _v_duration_ms="$v"; _has_duration_ms="true" ;;
      command) _v_command="$v" ;;
      log_path) _v_log_path="$v" ;;
      timestamp_utc) _v_timestamp_utc="$v" ;;
    esac
  done < "$full_receipt"

  [[ -n "$_v_schema" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'schema'"; return 1; }
  [[ -n "$_v_task_id" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'task_id'"; return 1; }
  [[ -n "$_v_scope" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'scope'"; return 1; }
  [[ -n "$_v_head_sha" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'head_sha'"; return 1; }
  [[ -n "$_v_tree_hash" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'tree_hash'"; return 1; }
  [[ -n "$_v_relevant_paths" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'relevant_paths'"; return 1; }
  [[ -n "$_v_exit_code" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'exit_code'"; return 1; }
  [[ -n "$_v_status" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'status'"; return 1; }
  [[ -n "$_v_command" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'command'"; return 1; }
  [[ -n "$_v_log_path" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'log_path'"; return 1; }
  [[ -n "$_v_timestamp_utc" ]] || { _VR_MSG="VERIFY_CORRUPT: missing field 'timestamp_utc'"; return 1; }

  local LC_ALL=C
  if [[ "$_v_schema" != "b3-verify-v1" ]]; then
    _VR_MSG="VERIFY_CORRUPT: unsupported schema '$_v_schema'"
    return 1
  fi
  if [[ ! "$_v_head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid head_sha"
    return 1
  fi
  if [[ ! "$_v_tree_hash" =~ ^[0-9a-f]{40}$ ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid tree_hash"
    return 1
  fi
  if [[ ! "$_v_exit_code" =~ ^-?[0-9]{1,9}$ ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid exit_code"
    return 1
  fi
  if [[ "$_v_status" != "PASS" && "$_v_status" != "FAIL" ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid status '$_v_status'"
    return 1
  fi
  if [[ ! "$_v_timestamp_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid timestamp_utc"
    return 1
  fi
  if [[ "$_has_duration_ms" == "true" && ! "$_v_duration_ms" =~ ^[0-9]+$ ]]; then
    _VR_MSG="VERIFY_CORRUPT: invalid duration_ms"
    return 1
  fi

  if [[ "$_v_log_path" != "none" ]]; then
    local lp_slash
    lp_slash="${_v_log_path//\\//}"
    lp_slash="$(trim_str "$lp_slash")"
    if [[ -z "$lp_slash" || "$lp_slash" == "." || "$lp_slash" == /* || "$lp_slash" == ~* || "$lp_slash" =~ ^[A-Za-z]: || "$lp_slash" =~ (^|/)\.\.(/|$) ]]; then
      _VR_MSG="VERIFY_CORRUPT: invalid log_path"
      return 1
    fi
    if ! validate_repo_write_path "$root" "$lp_slash"; then
      _VR_MSG="VERIFY_CORRUPT: invalid log_path"
      return 1
    fi
    if [[ ! -f "$_SAFE_FULL" ]]; then
      _VR_MSG="VERIFY_CORRUPT: missing log_path"
      return 1
    fi
  fi

  if [[ "$_v_exit_code" -ne 0 || "$_v_status" != "PASS" ]]; then
    _VR_MSG="VERIFY_FAILED_RECEIPT: exit=$_v_exit_code status=$_v_status"
    return 1
  fi

  local rel_for_fp=""
  local -a rp_arr=()
  if [[ "$_v_relevant_paths" != "ALL" ]]; then
    local _raw_vrel
    _raw_vrel="$(trim_str "$_v_relevant_paths")"
    if [[ "$_raw_vrel" == \[*\] ]]; then
      _raw_vrel="${_raw_vrel#[}"; _raw_vrel="${_raw_vrel%]}"
    fi
    if [[ "$_raw_vrel" == *'*'* || "$_raw_vrel" == *'?'* ]]; then
      _VR_MSG="VERIFY_CORRUPT: invalid relevant_paths"
      return 1
    fi
    local rp re_dotdot_vr='(^|/)\.\.(/|$)'
    while IFS= read -r rp; do [[ -n "$rp" ]] && rp_arr+=("$rp"); done < <(split_csv_lines "$_v_relevant_paths" true)
    if [[ ${#rp_arr[@]} -lt 1 ]]; then
      _VR_MSG="VERIFY_CORRUPT: invalid relevant_paths"
      return 1
    fi
    for rp in "${rp_arr[@]}"; do
      if is_checkpoint_dir "$rp" || [[ "$rp" == *:* || "$rp" == /* || "$rp" =~ $re_dotdot_vr ]]; then
        _VR_MSG="VERIFY_CORRUPT: invalid relevant_paths"
        return 1
      fi
    done
    rel_for_fp="$_v_relevant_paths"
  fi

  if [[ -n "$(trim_str "$expected_cmd_arg")" ]]; then
    local norm_exp
    norm_exp="$(normalize_cmd_str "$expected_cmd_arg")"
    if [[ "$_v_command" != "$norm_exp" ]]; then
      _VR_MSG="VERIFY_MISMATCH: command mismatch"
      return 1
    fi
  fi

  if [[ -n "$(trim_str "$req_rel_arg")" ]]; then
    local _raw_rrel re_dotdot_rq='(^|/)\.\.(/|$)'
    _raw_rrel="$(trim_str "$req_rel_arg")"
    if [[ "$_raw_rrel" == \[*\] ]]; then
      _raw_rrel="${_raw_rrel#[}"; _raw_rrel="${_raw_rrel%]}"
    fi
    if [[ "$_raw_rrel" == *'*'* || "$_raw_rrel" == *'?'* ]]; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid relevant_paths"
      return 1
    fi
    local -a req_arr=()
    local rq
    while IFS= read -r rq; do
      [[ -n "$rq" ]] || continue
      if is_checkpoint_dir "$rq" || [[ "$rq" == *:* || "$rq" == /* || "$rq" =~ $re_dotdot_rq ]]; then
        _VR_MSG="VERIFY_CHECK_FAIL: invalid relevant_paths"
        return 1
      fi
      req_arr+=("$rq")
    done < <(split_csv_lines "$req_rel_arg" true)
    if [[ ${#req_arr[@]} -lt 1 ]]; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid relevant_paths"
      return 1
    fi
    if [[ "$_v_relevant_paths" != "ALL" ]]; then
      local -a uncovered=()
      for rq in "${req_arr[@]}"; do
        if ! path_in_list "$rq" "${rp_arr[@]}"; then
          uncovered+=("$rq")
        fi
      done
      if [[ ${#uncovered[@]} -gt 0 ]]; then
        local sorted_unc
        sorted_unc="$(printf '%s\n' "${uncovered[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        _VR_MSG="VERIFY_SCOPE_MISMATCH: uncovered path ($sorted_unc)"
        return 1
      fi
    fi
  fi

  local target_trim
  target_trim="$(trim_str "$target_commit_sha")"
  local fp_out cur_head cur_tree cur_paths
  if ! fp_out="$(compute_tree_fingerprint "$root" "$rel_for_fp" "$ign_csv" "$target_trim")"; then
    _VR_MSG="$fp_out"
    return 1
  fi
  {
    IFS= read -r cur_head
    IFS= read -r cur_tree
    IFS= read -r cur_paths
  } <<< "$fp_out"

  if [[ -n "$target_trim" ]]; then
    if [[ "$cur_head" != "$_v_head_sha" ]]; then
      _VR_MSG="VERIFY_STALE: head_sha=${_v_head_sha:0:12} target=${cur_head:0:12}"
      return 2
    fi
  elif [[ "$cur_head" != "$_v_head_sha" ]]; then
    if ! run_git_cmd "$root" merge-base --is-ancestor "$_v_head_sha" "$cur_head"; then
      _VR_MSG="VERIFY_STALE: receipt=${_v_tree_hash:0:12} current=${cur_tree:0:12}"
      return 2
    fi
  fi
  if [[ "$cur_tree" != "$_v_tree_hash" ]]; then
    _VR_MSG="VERIFY_STALE: receipt=${_v_tree_hash:0:12} current=${cur_tree:0:12}"
    return 2
  fi

  _VR_MSG="VERIFY_VALID: task=$_v_task_id scope=$_v_scope tree=${_v_tree_hash:0:12}"
  _VR_REL_PATHS="$_v_relevant_paths"
  return 0
}

is_test_path() {
  local low
  low="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$low" =~ (^|/)(tests?|__tests__)/|\.(test|spec)\. ]]
}

is_code_path() {
  local low
  low="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$low" =~ \.(js|jsx|ts|tsx|mjs|cjs|py|go|cs|java|rs|ps1|sh)$ ]]
}

has_destructive_sql() {
  case "$1" in
    *[Dd][Rr][Oo][Pp]*|*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*) ;;
    *) return 1 ;;
  esac
  local low
  low="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$low" =~ (^|[^a-z0-9_])(drop[[:space:]]+table|drop[[:space:]]+database|truncate[[:space:]]+table)([^a-z0-9_]|$) ]]
}

is_skip_symbol() {
  case "$1" in
    main|init|constructor|render|setup|teardown|default|handler|index|test|describe) return 0 ;;
    *) return 1 ;;
  esac
}

get_code_ext_lower() {
  local low
  low="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$low" =~ (\.[a-z0-9]+)$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

extract_symbol_decl_ext() {
  local LC_ALL=C
  local ext="$1"
  local line_body="$2"
  local sym_name=""
  local is_exp="0"

  local re_js1 re_js2 re_py re_go1 re_go2 re_cs re_rs re_ps1 re_sh2
  case "$ext" in
    .js|.jsx|.ts|.tsx|.mjs|.cjs)
      re_js1='^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})'
      re_js2='^[[:space:]]*(export[[:space:]]+)?(const|let)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})[[:space:]]*=[[:space:]]*(async[[:space:]]+)?(\([^)]*\)[[:space:]]*=>|function([^a-zA-Z0-9_]|$))'
      if [[ "$line_body" =~ $re_js1 ]]; then
        [[ -n "${BASH_REMATCH[1]:-}" ]] && is_exp="1"
        sym_name="${BASH_REMATCH[5]:-}"
      elif [[ "$line_body" =~ $re_js2 ]]; then
        [[ -n "${BASH_REMATCH[1]:-}" ]] && is_exp="1"
        sym_name="${BASH_REMATCH[3]:-}"
      fi
      ;;
    .py)
      re_py='^[[:space:]]*(async[[:space:]]+)?(def|class)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})'
      if [[ "$line_body" =~ $re_py ]]; then
        sym_name="${BASH_REMATCH[3]:-}"
        [[ "${sym_name:0:1}" != "_" ]] && is_exp="1"
      fi
      ;;
    .go)
      re_go1='^func[[:space:]]+(\([^)]+\)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]{2,})[[:space:]]*\('
      re_go2='^type[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})[[:space:]]+'
      if [[ "$line_body" =~ $re_go1 ]]; then
        sym_name="${BASH_REMATCH[2]:-}"
        [[ "${sym_name:0:1}" =~ ^[A-Z]$ ]] && is_exp="1"
      elif [[ "$line_body" =~ $re_go2 ]]; then
        sym_name="${BASH_REMATCH[1]:-}"
        [[ "${sym_name:0:1}" =~ ^[A-Z]$ ]] && is_exp="1"
      fi
      ;;
    .cs|.java)
      re_cs='^[[:space:]]*(public|private|internal|protected)[[:space:]]+((static|async|virtual|override|sealed|abstract)[[:space:]]+)*(class|interface|struct|record|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})'
      if [[ "$line_body" =~ $re_cs ]]; then
        sym_name="${BASH_REMATCH[5]:-}"
        [[ "${BASH_REMATCH[1]:-}" == "public" ]] && is_exp="1"
      fi
      ;;
    .rs)
      re_rs='^[[:space:]]*(pub(\([^)]*\))?[[:space:]]+)?(async[[:space:]]+)?(fn|struct|enum|trait)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{2,})'
      if [[ "$line_body" =~ $re_rs ]]; then
        [[ -n "${BASH_REMATCH[1]:-}" ]] && is_exp="1"
        sym_name="${BASH_REMATCH[5]:-}"
      fi
      ;;
    .ps1|.sh)
      re_ps1='^[[:space:]]*function[[:space:]]+([A-Za-z_][A-Za-z0-9_-]{2,})'
      re_sh2='^([A-Za-z_][A-Za-z0-9_]{2,})\(\)[[:space:]]*[{]'
      if [[ "$line_body" =~ $re_ps1 ]]; then
        sym_name="${BASH_REMATCH[1]:-}"
        is_exp="0"
      elif [[ "$ext" == ".sh" && "$line_body" =~ $re_sh2 ]]; then
        sym_name="${BASH_REMATCH[1]:-}"
        is_exp="0"
      fi
      ;;
  esac

  [[ -n "$sym_name" ]] || return 1
  if is_skip_symbol "$sym_name"; then return 1; fi
  _SYM_NAME="$sym_name"
  _SYM_EXP="$is_exp"
  return 0
}

resolve_canonical_git_common_dir() {
  local dir="$1"
  local gd=""
  if run_git_cmd "$dir" rev-parse --git-common-dir; then
    gd="$(trim_str "$_GIT_STDOUT")"
  fi
  [[ -n "$gd" ]] || return 1
  if [[ "$gd" != /* && ! "$gd" =~ ^[A-Za-z]: ]]; then
    gd="${dir}/${gd}"
  fi
  if [[ -d "$gd" ]]; then
    local abs
    abs="$(cd -P "$gd" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
    normalize_abs_for_repo "$abs"
  else
    normalize_abs_for_repo "$gd"
  fi
}

resolve_canonical_git_dir() {
  local dir="$1"
  local gd=""
  if run_git_cmd "$dir" rev-parse --git-dir; then
    gd="$(trim_str "$_GIT_STDOUT")"
  fi
  [[ -n "$gd" ]] || return 1
  if [[ "$gd" != /* && ! "$gd" =~ ^[A-Za-z]: ]]; then
    gd="${dir}/${gd}"
  fi
  if [[ -d "$gd" ]]; then
    local abs
    abs="$(cd -P "$gd" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
    normalize_abs_for_repo "$abs"
  else
    normalize_abs_for_repo "$gd"
  fi
}

paths_equal_fs() {
  local a b
  a="$(norm_path "$1")"
  b="$(norm_path "$2")"
  if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
    a="$(printf '%s' "$a" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    b="$(printf '%s' "$b" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  [[ "$a" == "$b" ]]
}

worktree_roots_overlap() {
  local a="$1" b="$2"
  if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
    a="$(printf '%s' "$a" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    b="$(printf '%s' "$b" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  [[ "$a" == "$b" ]] && return 0
  local a_base="${a%/}" b_base="${b%/}"
  [[ -n "$a_base" && -n "$b_base" ]] || return 1
  [[ "$a" == "$b_base/"* || "$b" == "$a_base/"* ]]
}

_normalize_logical_abs_path() {
  local raw="$1"
  local p
  p="$(trim_str "$raw")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  local abs=""
  if [[ "$p" == /* || "$p" =~ ^[A-Za-z]: ]]; then
    abs="$p"
  else
    local pwd_l
    pwd_l="$(pwd -L 2>/dev/null || pwd)"
    pwd_l="${pwd_l//\\//}"
    abs="${pwd_l%/}/${p}"
  fi
  local prefix="/" rest=""
  if [[ "$abs" =~ ^([A-Za-z]:)(.*)$ ]]; then
    prefix="${BASH_REMATCH[1]}/"
    rest="${BASH_REMATCH[2]#/}"
  else
    prefix="/"
    rest="${abs#/}"
  fi
  local -a segs=()
  local rem="$rest" seg n_segs
  while [[ -n "$rem" ]]; do
    if [[ "$rem" == */* ]]; then
      seg="${rem%%/*}"
      rem="${rem#*/}"
    else
      seg="$rem"
      rem=""
    fi
    if [[ -z "$seg" || "$seg" == "." ]]; then
      continue
    fi
    if [[ "$seg" == ".." ]]; then
      n_segs=${#segs[@]}
      if [[ $n_segs -gt 0 ]]; then
        unset 'segs[$((n_segs - 1))]'
        if [[ ${#segs[@]} -gt 0 ]]; then
          segs=("${segs[@]}")
        fi
      fi
      continue
    fi
    segs+=("$seg")
  done
  if [[ ${#segs[@]} -eq 0 ]]; then
    printf '%s' "$prefix"
  else
    local joined
    joined="$(IFS='/'; printf '%s' "${segs[*]}")"
    if [[ "$prefix" == "/" ]]; then
      printf '/%s' "$joined"
    else
      printf '%s%s' "$prefix" "$joined"
    fi
  fi
}

find_symlink_in_hierarchy() {
  local abs_path="$1"
  [[ -n "$abs_path" ]] || return 1
  local clean="$abs_path"
  while [[ "$clean" == */ && "$clean" != "/" && ! "$clean" =~ ^[A-Za-z]:/$ ]]; do
    clean="${clean%/}"
  done
  if [[ "$clean" == "/" || "$clean" =~ ^[A-Za-z]:/?$ ]]; then
    return 1
  fi
  local cur="" rest=""
  if [[ "$clean" =~ ^([A-Za-z]:)(.*)$ ]]; then
    cur="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]#/}"
  else
    cur=""
    rest="${clean#/}"
  fi
  local seg
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == */* ]]; then
      seg="${rest%%/*}"
      rest="${rest#*/}"
    else
      seg="$rest"
      rest=""
    fi
    [[ -z "$seg" || "$seg" == "." ]] && continue
    cur="${cur}/${seg}"
    if [[ "$_B3_IS_MACOS" == "true" && ( "$cur" == "/var" || "$cur" == "/tmp" ) ]]; then
      continue
    fi
    if [[ -L "$cur" ]]; then
      printf '%s' "$cur"
      return 0
    fi
    if [[ "$_B3_IS_WINDOWS" == "true" && -d "$cur" && "$seg" != *"~"* ]]; then
      local _par_dir _par_c _cur_c _exp_c _got_c
      _par_dir="$(dirname "$cur")"
      [[ "$_par_dir" =~ ^[A-Za-z]:$ ]] && _par_dir="${_par_dir}/"
      if [[ -d "$_par_dir" ]]; then
        _par_c="$(cd -P "$_par_dir" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || _par_c=""
        _cur_c="$(cd -P "$cur" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || _cur_c=""
        if [[ -n "$_par_c" && -n "$_cur_c" ]]; then
          _par_c="$(normalize_abs_for_repo "$_par_c")"
          _cur_c="$(normalize_abs_for_repo "$_cur_c")"
          _exp_c="$(printf '%s' "${_par_c%/}/${seg}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          _got_c="$(printf '%s' "$_cur_c" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          if [[ "$_exp_c" != "$_got_c" ]]; then
            printf '%s' "$cur"
            return 0
          fi
        fi
      fi
    fi
  done
  return 1
}

_WT_LOGICAL=""
_WT_TOP_NORM=""
_WT_COMMON_DIR=""
_WT_GIT_DIR=""
_WT_HEAD=""
check_worktree_identity() {
  local raw_path="$1"
  local missing_code="$2"
  local not_git_code="$3"
  local require_head="${4:-false}"
  _WT_LOGICAL=""
  _WT_TOP_NORM=""
  _WT_COMMON_DIR=""
  _WT_GIT_DIR=""
  _WT_HEAD=""

  local logical sym_hit
  logical="$(_normalize_logical_abs_path "$raw_path")" || {
    echo "WORKTREE_UNSAFE: ${missing_code}(${raw_path})"
    exit 2
  }
  sym_hit="$(find_symlink_in_hierarchy "$logical" || true)"
  if [[ -n "$sym_hit" ]]; then
    echo "WORKTREE_UNSAFE: unsafe_reparse_root(${sym_hit})"
    exit 2
  fi
  if [[ ! -d "$logical" ]]; then
    echo "WORKTREE_UNSAFE: ${missing_code}(${raw_path})"
    exit 2
  fi
  local dot_git="${logical%/}/.git"
  if [[ -L "$dot_git" ]] || { [[ -d "$dot_git" ]] && is_dir_link_or_junction "$logical" ".git"; }; then
    echo "WORKTREE_UNSAFE: unsafe_reparse_root(${dot_git})"
    exit 2
  fi
  local top_raw=""
  if run_git_cmd "$logical" rev-parse --show-toplevel; then
    top_raw="$(trim_str "$_GIT_STDOUT")"
  fi
  if [[ -z "$top_raw" ]]; then
    if [[ "$not_git_code" == "not_a_git_repo" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
    else
      echo "WORKTREE_UNSAFE: ${not_git_code}(${raw_path})"
    fi
    exit 2
  fi
  local head_raw=""
  if [[ "$require_head" == "true" ]]; then
    if run_git_cmd "$logical" rev-parse HEAD; then
      head_raw="$(trim_str "$_GIT_STDOUT")"
    fi
    if [[ ! "$head_raw" =~ ^[0-9a-f]{40}$ ]]; then
      echo "WORKTREE_UNSAFE: unborn_or_invalid_head"
      exit 2
    fi
  fi
  local top_logical top_sym_hit top_dot_git
  top_logical="$(_normalize_logical_abs_path "$top_raw")" || top_logical="$top_raw"
  top_sym_hit="$(find_symlink_in_hierarchy "$top_logical" || true)"
  if [[ -n "$top_sym_hit" ]]; then
    echo "WORKTREE_UNSAFE: unsafe_reparse_root(${top_sym_hit})"
    exit 2
  fi
  top_dot_git="${top_logical%/}/.git"
  if [[ -L "$top_dot_git" ]] || { [[ -d "$top_dot_git" ]] && is_dir_link_or_junction "$top_logical" ".git"; }; then
    echo "WORKTREE_UNSAFE: unsafe_reparse_root(${top_dot_git})"
    exit 2
  fi
  local top_norm common_dir git_dir
  top_norm="$(canon_repo_root "$top_logical" 2>/dev/null || norm_path "$top_logical")"
  common_dir="$(resolve_canonical_git_common_dir "$logical" || true)"
  git_dir="$(resolve_canonical_git_dir "$logical" || true)"
  if [[ -z "$common_dir" || -z "$git_dir" ]]; then
    if [[ "$not_git_code" == "not_a_git_repo" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
    else
      echo "WORKTREE_UNSAFE: ${not_git_code}(${raw_path})"
    fi
    exit 2
  fi
  _WT_LOGICAL="$logical"
  _WT_TOP_NORM="$top_norm"
  _WT_COMMON_DIR="$common_dir"
  _WT_GIT_DIR="$git_dir"
  _WT_HEAD="$head_raw"
}



normalize_size_class() {
  local raw
  raw="$(printf '%s' "$(trim_str "$1")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
  case "$raw" in
    SMALL) printf 'S' ;;
    MEDIUM) printf 'M' ;;
    LARGE) printf 'L' ;;
    VERY_LARGE) printf 'XL' ;;
    XS|S|M|L|XL|XXL|NOISE_ONLY|CLEAN_AFTER_FIX|EMPTY_DIFF) printf '%s' "$raw" ;;
    *) return 1 ;;
  esac
}

_B3_RISK_AWK_LIB='
function norm_p(s) {
  gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
  gsub(/\\/, "/", s)
  sub(/^\.\//, "", s)
  while (length(s) > 1 && substr(s, length(s), 1) == "/") s = substr(s, 1, length(s) - 1)
  return s
}
function sort_arr(arr, n,   i, j, tmp) {
  for (i = 2; i <= n; i++) {
    tmp = arr[i]; j = i - 1
    while (j >= 1 && arr[j] > tmp) { arr[j + 1] = arr[j]; j-- }
    arr[j + 1] = tmp
  }
}
function is_ckpt(p,   lp) { lp = tolower(p); return (lp ~ /^\.b3\/(ship|research-ship|autodev)(\/|$)/) }
function is_ignored(p,   i) {
  for (i = 1; i <= n_ign; i++) {
    if (ign[i] == "." || p == ign[i] || (ign[i] != "" && index(p, ign[i] "/") == 1)) return 1
  }
  return 0
}
function leaf_low(p,   n, s) { n = split(p, s, "/"); return tolower(s[n]) }
function is_noise_p(p,   ll) {
  ll = leaf_low(p)
  if (ll == "package-lock.json" || ll == "pnpm-lock.yaml" || ll == "yarn.lock" || ll == "bun.lockb" || ll == "packages.lock.json" || ll == "cargo.lock" || ll == "poetry.lock") return 1
  return (ll ~ /\.(min\.js|min\.css|snap|designer\.cs|g\.cs|map)$/)
}
function is_secret_p(p,   ll) {
  ll = leaf_low(p)
  if (ll == ".env") return 1
  if (substr(ll, 1, 5) == ".env." && ll !~ /^\.env\.(example|sample|template)$/) return 1
  if (ll ~ /\.(pem|key|p12|pfx)$/) return 1
  return (ll == "id_rsa" || ll == "id_ed25519" || ll == "credentials.json")
}
function is_doc_asset(p,   lp) { lp = tolower(p); return (lp ~ /\.(md|mdx|txt|rst|adoc|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|pdf)$/ || lp ~ /(^|\/)evals\/.*\.ya?ml$/) }
function is_test_p(p) { return (tolower(p) ~ /(^|\/)(tests?|__tests__)\/|\.(test|spec)\./) }
function is_code_p(p) { return (tolower(p) ~ /\.(js|jsx|ts|tsx|mjs|cjs|py|go|cs|java|rs|ps1|sh)$/) }
function is_gen_p(p) { return (tolower(p) ~ /\.generated\.|\.pb\.|(^|\/)(generated|gen)(\/|$)|\.(g|designer)\.cs$/) }
function is_contract_p(p,   lp) {
  lp = tolower(p)
  if (is_doc_asset(lp) || is_test_p(lp) || is_noise_p(lp)) return 0
  return (lp ~ /(^|\/)(openapi|swagger|proto|graphql|contracts?|schemas?|interfaces?|shared-types|api-types)(\/|$|\.)|\.(proto|graphql|gql|sql)$|(^|\/)(package\.json|pnpm-workspace\.yaml|go\.mod|cargo\.toml|pyproject\.toml)$|\.(csproj|sln)$/)
}
function raw_group(p,   n, s) {
  n = split(p, s, "/")
  if (n >= 3) return s[1] "/" s[2]
  if (n == 2) return s[1]
  return "root"
}
function add_sig(p, sig) {
  if (p == "" || sig == "") return
  if (!(p SUBSEP sig in fsig_seen)) {
    fsig_seen[p SUBSEP sig] = 1
    fsig_list[p] = (p in fsig_list ? fsig_list[p] "," sig : sig)
  }
}
function scan_path_sigs(p,   lp) {
  lp = tolower(p)
  if (is_gen_p(lp)) add_sig(p, "generated_code")
  if (is_doc_asset(lp) || is_test_p(lp)) return
  if (is_secret_p(lp) || lp ~ /(^|\/)(auth|authn|authz|oauth|oidc|jwt|rbac|acl|sessions?|security|crypto|cipher|secrets?|tokens?|credentials?|permissions?|polic(y|ies))(\/|$|[^\/]*\.)/) add_sig(p, "auth_security")
  if (lp ~ /(^|\/)(b3-guard|install[^\/]*|sync[^\/]*)\.(ps1|sh)$/) add_sig(p, "fs_git_security")
  if (lp ~ /(^|\/)(migrations?|schema|prisma|alembic|flyway|liquibase|db|database|persistence|repositories|efcore)(\/|$)|\.sql$/) add_sig(p, "db_migration_tx")
  if (lp ~ /(^|\/)(openapi|swagger|proto|graphql|contracts?|api|routes?|controllers?|endpoints?|schemas?|interfaces?|public)(\/|$)|\.(proto|graphql|gql)$|(^|\/)(contracts?|shared-types|api-types)\.[^\/]+$/) add_sig(p, "public_api_contract")
  if (lp ~ /(^|\/)(cache|redis|queue|worker|lock|mutex|concurrency|scheduler|state|store)(\/|$)/) add_sig(p, "concurrency_state_cache")
  if (lp ~ /(^|\/)(render|renderer|shader|three|canvas|scene|webgl|engine|query|queries|indexer|serializer|stream)(\/|$)/) add_sig(p, "perf_hot_path")
}
function scan_line_sigs(p, ll) {
  if (ll ~ /verifytoken|jwt\.|bcrypt|argon2|pbkdf2|crypto\.|\[authorize|allowanonymous|eval\(|execsync|child_process|dangerouslysetinnerhtml|rejectunauthorized[ \t]*:[ \t]*false|chmod[ \t]+777/) add_sig(p, "auth_security")
  if (ll ~ /git_index_file|reparsepoint|symboliclink|junction|rm[ \t]+-rf|remove-item.*-recurse|git[ \t]+push|git[ \t]+reset[ \t]+--hard/) add_sig(p, "fs_git_security")
  if (ll ~ /(^|[^a-z0-9_])(drop[ \t]+table|drop[ \t]+database|alter[ \t]+table|truncate[ \t]+table|begin[ \t]+transaction|isolationlevel|savechanges|migrate\()/) {
    add_sig(p, "db_migration_tx")
    if (ll ~ /(^|[^a-z0-9_])(drop[ \t]+table|drop[ \t]+database|truncate[ \t]+table)([^a-z0-9_]|$)/) add_sig(p, "_db_destructive")
  }
  if (ll ~ /(^|[^a-z0-9_])(mutex|semaphore|concurrentdictionary|channel<|promise\.all|abortcontroller|imemorycache|distributedcache)/) add_sig(p, "concurrency_state_cache")
  if (ll ~ /(^|[^a-z0-9_])(useframe|requestanimationframe|instancedmesh|webglrenderer|asnotracking)/) add_sig(p, "perf_hot_path")
  if (ll ~ /(^|[^a-z0-9_])(json\.stringify|json\.parse)/) add_sig(p, "_json_serde")
  if (ll ~ /(^|[^a-z0-9_])(for[ \t]*\(|while[ \t]*\(|foreach|readline|createreadstream|createwritestream|readable|writable|transform|stream|buffer|uint8array|arraybuffer|chunk|ndjson|jsonl|batch|bulk|maxbuffer)|\.map\(|\.flatmap\(|\.reduce\(|1024[ \t]*\*/) add_sig(p, "_serde_hot_ctx")
  if ((p SUBSEP "_json_serde" in fsig_seen) && (p SUBSEP "_serde_hot_ctx" in fsig_seen)) add_sig(p, "perf_hot_path")
}
function eval_subset(paths_arr, np,   i, p, k, ns, parts, s, has_destr, has_csig, code_fc, code_lc, n_cg, cg_seen, sig_seen, sig_arr, n_sig, max_sev, sp_seen, sp_arr, n_sp, cross_hi, grp, r_lbl, r_sigs, r_sp, db_s, c_s) {
  split("", cg_seen); split("", sig_seen); split("", sig_arr); split("", sp_seen); split("", sp_arr)
  has_destr = 0; has_csig = 0; code_fc = 0; code_lc = 0; n_cg = 0; n_sig = 0; n_sp = 0
  for (i = 1; i <= np; i++) {
    p = paths_arr[i]
    if (p == "") continue
    if (!(p in fsig_list)) scan_path_sigs(p)
    if (p in fsig_list) {
      ns = split(fsig_list[p], parts, ",")
      for (k = 1; k <= ns; k++) {
        s = parts[k]
        if (s == "_db_destructive") { has_destr = 1; continue }
        if (substr(s, 1, 1) == "_") continue
        if (s != "" && !(s in sig_seen)) { sig_seen[s] = 1; sig_arr[++n_sig] = s }
        if (s == "public_api_contract" || s == "db_migration_tx") has_csig = 1
      }
    }
    if (!(is_doc_asset(p) || is_test_p(p) || is_gen_p(p) || is_noise_p(p))) {
      grp = raw_group(p)
      if (!(grp in cg_seen)) { cg_seen[grp] = 1; n_cg++ }
      if (is_code_p(p) || is_contract_p(p)) {
        code_fc++
        if (p in flines) code_lc += flines[p]
      }
    }
  }
  cross_hi = 0
  if (n_cg >= 4 && has_csig) {
    if (!("cross_module_blast" in sig_seen)) { sig_seen["cross_module_blast"] = 1; sig_arr[++n_sig] = "cross_module_blast" }
    cross_hi = 1
  } else if (n_cg >= 3) {
    if (!("cross_module_blast" in sig_seen)) { sig_seen["cross_module_blast"] = 1; sig_arr[++n_sig] = "cross_module_blast" }
  }
  max_sev = 1
  for (i = 1; i <= n_sig; i++) {
    s = sig_arr[i]
    if (s == "auth_security" || s == "fs_git_security") {
      if (max_sev < 4) max_sev = 4
      if (!("b3-security-reviewer" in sp_seen)) { sp_seen["b3-security-reviewer"] = 1; sp_arr[++n_sp] = "b3-security-reviewer" }
    } else if (s == "db_migration_tx") {
      db_s = (has_destr ? 4 : 3)
      if (max_sev < db_s) max_sev = db_s
      if (!("b3-architecture-reviewer" in sp_seen)) { sp_seen["b3-architecture-reviewer"] = 1; sp_arr[++n_sp] = "b3-architecture-reviewer" }
      if (has_destr && !("b3-security-reviewer" in sp_seen)) { sp_seen["b3-security-reviewer"] = 1; sp_arr[++n_sp] = "b3-security-reviewer" }
    } else if (s == "public_api_contract") {
      if (max_sev < 3) max_sev = 3
      if (!("b3-architecture-reviewer" in sp_seen)) { sp_seen["b3-architecture-reviewer"] = 1; sp_arr[++n_sp] = "b3-architecture-reviewer" }
    } else if (s == "concurrency_state_cache") {
      if (max_sev < 3) max_sev = 3
      if (!("b3-architecture-reviewer" in sp_seen)) { sp_seen["b3-architecture-reviewer"] = 1; sp_arr[++n_sp] = "b3-architecture-reviewer" }
      if (!("b3-performance-reviewer" in sp_seen)) { sp_seen["b3-performance-reviewer"] = 1; sp_arr[++n_sp] = "b3-performance-reviewer" }
    } else if (s == "perf_hot_path") {
      if (max_sev < 3) max_sev = 3
      if (!("b3-performance-reviewer" in sp_seen)) { sp_seen["b3-performance-reviewer"] = 1; sp_arr[++n_sp] = "b3-performance-reviewer" }
    } else if (s == "generated_code") {
      if (max_sev < 2) max_sev = 2
    } else if (s == "cross_module_blast") {
      c_s = (cross_hi ? 3 : 2)
      if (max_sev < c_s) max_sev = c_s
      if (cross_hi && !("b3-architecture-reviewer" in sp_seen)) { sp_seen["b3-architecture-reviewer"] = 1; sp_arr[++n_sp] = "b3-architecture-reviewer" }
    }
  }
  if (max_sev < 2 && (code_fc > 1 || code_lc > 100)) {
    sig_arr[++n_sig] = "general_code_change"
    max_sev = 2
  }
  r_lbl = (max_sev == 4 ? "CRITICAL" : (max_sev == 3 ? "HIGH" : (max_sev == 2 ? "MEDIUM" : "LOW")))
  if (n_sig > 0) {
    sort_arr(sig_arr, n_sig)
    r_sigs = sig_arr[1]; for (i = 2; i <= n_sig; i++) r_sigs = r_sigs "," sig_arr[i]
  } else r_sigs = "none"
  if (n_sp > 0) {
    sort_arr(sp_arr, n_sp)
    r_sp = sp_arr[1]; for (i = 2; i <= n_sp; i++) r_sp = r_sp "," sp_arr[i]
  } else r_sp = "none"
  _EV_RISK = r_lbl; _EV_SIGS = r_sigs; _EV_SPECS = r_sp
}
function is_oversized(fc, lc) {
  return (lc > 5000 || (fc > 100 && lc > 1000))
}
function eval_l1_dispatch(cf_csv, rec_specs, pr_risk, rev_arr, n_rev,   i, nsp, sarr, seen, l1, nl1, all_docs) {
  split("", seen); split("", l1); nl1 = 0
  if (cf_csv != "" && cf_csv != "none") { seen["b3-architecture-reviewer"] = 1; l1[++nl1] = "b3-architecture-reviewer" }
  if (rec_specs != "" && rec_specs != "none") {
    nsp = split(rec_specs, sarr, ",")
    for (i = 1; i <= nsp; i++) {
      if ((sarr[i] == "b3-architecture-reviewer" || sarr[i] == "b3-security-reviewer" || sarr[i] == "b3-performance-reviewer") && !(sarr[i] in seen)) {
        seen[sarr[i]] = 1; l1[++nl1] = sarr[i]
      }
    }
  }
  if (nl1 > 0) {
    sort_arr(l1, nl1)
    _L1_SPECS = l1[1]; for (i = 2; i <= nl1; i++) _L1_SPECS = _L1_SPECS "," l1[i]
    _L1_SKIP = "none"
  } else {
    _L1_SPECS = "none"
    all_docs = (n_rev > 0 ? 1 : 0)
    for (i = 1; i <= n_rev; i++) {
      if (!is_doc_asset(rev_arr[i])) { all_docs = 0; break }
    }
    if (all_docs) _L1_SKIP = "low-risk-docs-only"
    else if (pr_risk == "LOW") _L1_SKIP = "low-risk-isolated-no-contracts"
    else _L1_SKIP = "no-contract-or-arch-signals"
  }
}
function tshirt_sz(f, l) {
  if (f == 0) return "NOISE_ONLY"
  if (f <= 3 && l <= 100) return "XS"
  if (f <= 8 && l <= 300) return "S"
  if (f <= 20 && l <= 800) return "M"
  if (f < 50 && l < 2000) return "L"
  if (f <= 100 && l <= 5000) return "XL"
  return "XXL"
}
'

eval_risk_for_csv_awk() {
  local paths_csv="$1" fsig_file="${2:-}" flines_file="${3:-}"
  LC_ALL=C awk -v paths_csv="$paths_csv" -v fsig_f="$fsig_file" -v flines_f="$flines_file" "$_B3_RISK_AWK_LIB"'
  BEGIN {
    split("", fsig_list); split("", flines); split("", ign); n_ign = 0
    if (fsig_f != "") {
      while ((getline ln < fsig_f) > 0) {
        sub(/\r$/, "", ln)
        t = index(ln, "\t")
        if (t > 1) fsig_list[substr(ln, 1, t - 1)] = substr(ln, t + 1)
      }
      close(fsig_f)
    }
    if (flines_f != "") {
      while ((getline ln < flines_f) > 0) {
        sub(/\r$/, "", ln)
        t = index(ln, "\t")
        if (t > 1) flines[substr(ln, 1, t - 1)] = substr(ln, t + 1) + 0
      }
      close(flines_f)
    }
    np = split(paths_csv, raw_p, ",")
    n_use = 0
    for (i = 1; i <= np; i++) {
      p = norm_p(raw_p[i])
      if (p != "" && p != "none") arr[++n_use] = p
    }
    eval_subset(arr, n_use)
    printf "%s\n%s\n%s\n", _EV_RISK, _EV_SIGS, _EV_SPECS
  }'
}

eval_l1_dispatch_awk() {
  local cf_csv="$1" rec_specs="$2" pr_risk="$3" rev_csv="$4"
  LC_ALL=C awk -v cf_csv="$cf_csv" -v rec_specs="$rec_specs" -v pr_risk="$pr_risk" -v rev_csv="$rev_csv" "$_B3_RISK_AWK_LIB"'
  BEGIN {
    split("", rarr); nr = 0
    if (rev_csv != "" && rev_csv != "none") {
      n = split(rev_csv, raw_r, ",")
      for (i = 1; i <= n; i++) {
        p = norm_p(raw_r[i])
        if (p != "" && p != "none") rarr[++nr] = p
      }
    }
    eval_l1_dispatch(cf_csv, rec_specs, pr_risk, rarr, nr)
    printf "%s\n%s\n", _L1_SPECS, _L1_SKIP
  }'
}

run_scope_engine() {
  local root="$1" base_sha="$2" target_commit="$3" ign_csv="$4" max_conc="$5" prefix="$6"
  local fsig_out_file="${7:-}" flines_out_file="${8:-}" need_units="${9:-true}"
  local ns_tmp st_tmp df_tmp unt_tmp raw_u_tmp ov_tmp imp_tmp fsig_use flines_use root_slash
  make_temp_file "b3-ns" ns_tmp
  make_temp_file "b3-st" st_tmp
  make_temp_file "b3-df" df_tmp
  make_temp_file "b3-unt" unt_tmp
  make_temp_file "b3-ru" raw_u_tmp
  make_temp_file "b3-ov" ov_tmp
  make_temp_file "b3-imp" imp_tmp
  if [[ -n "$fsig_out_file" ]]; then
    fsig_use="$fsig_out_file"
  else
    make_temp_file "b3-fsi" fsig_use
  fi
  if [[ -n "$flines_out_file" ]]; then
    flines_use="$flines_out_file"
  else
    make_temp_file "b3-fli" flines_use
  fi
  : > "$raw_u_tmp"; : > "$ov_tmp"; : > "$imp_tmp"; : > "$fsig_use"; : > "$flines_use"

  if [[ -n "$target_commit" ]]; then
    run_git_cmd "$root" diff --no-ext-diff --no-renames --numstat "$base_sha" "$target_commit" -- || { echo "${prefix}: git diff --numstat failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$ns_tmp"
    run_git_cmd "$root" diff --no-ext-diff --no-renames --name-status "$base_sha" "$target_commit" -- || { echo "${prefix}: git diff --name-status failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$st_tmp"
    run_git_cmd "$root" diff --no-ext-diff --no-renames -U0 "$base_sha" "$target_commit" -- || { echo "${prefix}: git diff -U0 failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$df_tmp"
    : > "$unt_tmp"
  else
    run_git_cmd "$root" diff --no-ext-diff --no-renames --numstat "$base_sha" -- || { echo "${prefix}: git diff --numstat failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$ns_tmp"
    run_git_cmd "$root" diff --no-ext-diff --no-renames --name-status "$base_sha" -- || { echo "${prefix}: git diff --name-status failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$st_tmp"
    run_git_cmd "$root" diff --no-ext-diff --no-renames -U0 "$base_sha" -- || { echo "${prefix}: git diff -U0 failed: $(git_err_detail)"; return 1; }
    printf '%s\n' "$_GIT_STDOUT" > "$df_tmp"
    run_git_cmd "$root" ls-files --others --exclude-standard || { echo "${prefix}: git ls-files failed: $(git_err_detail)"; return 1; }
    local u_raw="$_GIT_STDOUT" line p
    : > "$unt_tmp"
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      if [[ -f "${root}/${p}" ]] && ! is_binary_file "${root}/${p}"; then
        printf '1\t%s\n' "$p" >> "$unt_tmp"
      else
        printf '0\t%s\n' "$p" >> "$unt_tmp"
      fi
    done <<< "$u_raw"
  fi

  local clamped_conc="$max_conc"
  [[ "$clamped_conc" =~ ^[0-9]+$ ]] || clamped_conc=4
  [[ "$clamped_conc" -lt 1 ]] && clamped_conc=1
  [[ "$clamped_conc" -gt 4 ]] && clamped_conc=4
  root_slash="${root%/}"
  root_slash="${root_slash//\\//}"

  local pass1_out
  if ! pass1_out="$(LC_ALL=C awk \
    -v ign_csv="$ign_csv" \
    -v root_dir="$root_slash" \
    -v ns_f="$ns_tmp" \
    -v st_f="$st_tmp" \
    -v unt_f="$unt_tmp" \
    -v df_f="$df_tmp" \
    -v max_conc="$clamped_conc" \
    -v need_units="$need_units" \
    -v fsig_out="$fsig_use" \
    -v flines_out="$flines_use" \
    -v raw_u_f="$raw_u_tmp" \
    -v ov_f="$ov_tmp" \
    "$_B3_RISK_AWK_LIB"'
  BEGIN {
    split("", ign); split("", fsig_list); split("", fsig_seen); split("", flines)
    split("", rev_seen); split("", noise_seen); split("", rev_arr); split("", noise_arr); split("", ch_map)
    n_ign = (ign_csv == "" ? 0 : split(ign_csv, raw_i, ","))
    for (i = 1; i <= n_ign; i++) ign[i] = norm_p(raw_i[i])
    n_rev = 0; n_noise = 0; total_lines = 0

    while ((getline ln < st_f) > 0) {
      sub(/\r$/, "", ln)
      t = index(ln, "\t")
      if (t > 1) {
        cch = toupper(substr(ln, 1, 1))
        if (cch != "A" && cch != "M" && cch != "D") cch = "M"
        fp = norm_p(substr(ln, t + 1))
        if (fp != "" && !is_ckpt(fp) && !is_ignored(fp)) ch_map[fp] = cch
      }
    }
    close(st_f)

    while ((getline ln < ns_f) > 0) {
      sub(/\r$/, "", ln)
      if (ln == "") continue
      t1 = index(ln, "\t")
      if (t1 < 1) continue
      rem = substr(ln, t1 + 1)
      t2 = index(rem, "\t")
      if (t2 < 1) continue
      a = substr(ln, 1, t1 - 1)
      d = substr(rem, 1, t2 - 1)
      fp = norm_p(substr(rem, t2 + 1))
      if (fp == "" || is_ckpt(fp) || is_ignored(fp)) continue
      scan_path_sigs(fp)
      if (is_noise_p(fp)) {
        if (!(fp in noise_seen)) { noise_seen[fp] = 1; noise_arr[++n_noise] = fp }
        continue
      }
      if (!(fp in rev_seen)) { rev_seen[fp] = 1; rev_arr[++n_rev] = fp }
      lc = 0
      if (a ~ /^[0-9]+$/) lc += a + 0
      if (d ~ /^[0-9]+$/) lc += d + 0
      flines[fp] = lc
      total_lines += lc
      if (!(is_doc_asset(fp) || is_test_p(fp))) scan_set[fp] = 1
    }
    close(ns_f)

    while ((getline ln < unt_f) > 0) {
      sub(/\r$/, "", ln)
      t = index(ln, "\t")
      if (t < 1) continue
      is_txt = (substr(ln, 1, t - 1) == "1")
      fp = norm_p(substr(ln, t + 1))
      if (fp == "" || is_ckpt(fp) || is_ignored(fp)) continue
      scan_path_sigs(fp)
      if (is_noise_p(fp)) {
        if (!(fp in noise_seen)) { noise_seen[fp] = 1; noise_arr[++n_noise] = fp }
        continue
      }
      if (!(fp in rev_seen)) {
        rev_seen[fp] = 1; rev_arr[++n_rev] = fp; ch_map[fp] = "U"
        lc = 0
        if (is_txt) {
          full = root_dir "/" fp
          do_scan = !(is_doc_asset(fp) || is_test_p(fp))
          while ((getline uln < full) > 0) {
            sub(/\r$/, "", uln)
            lc++
            if (do_scan) scan_line_sigs(fp, tolower(uln))
          }
          close(full)
        }
        flines[fp] = lc
        total_lines += lc
      }
    }
    close(unt_f)

    hdr_old = ""; cur_p = ""; cur_s = 0; in_hunk = 0
    while ((getline dl < df_f) > 0) {
      sub(/\r$/, "", dl)
      if (substr(dl, 1, 11) == "diff --git ") { hdr_old = ""; cur_p = ""; cur_s = 0; in_hunk = 0; continue }
      if (!in_hunk) {
        if (substr(dl, 1, 4) == "--- ") {
          hdr_old = (dl != "--- /dev/null" && length(dl) > 6 ? norm_p(substr(dl, 7)) : "")
          continue
        }
        if (substr(dl, 1, 4) == "+++ ") {
          cur_p = (dl != "+++ /dev/null" && length(dl) > 6 ? norm_p(substr(dl, 7)) : hdr_old)
          cur_s = (cur_p != "" && (cur_p in scan_set) ? 1 : 0)
          continue
        }
        if (substr(dl, 1, 3) == "@@ ") {
          in_hunk = 1
          continue
        }
        continue
      }
      if (substr(dl, 1, 3) == "@@ ") { continue }
      if (cur_s && (substr(dl, 1, 1) == "+" || substr(dl, 1, 1) == "-")) {
        scan_line_sigs(cur_p, tolower(substr(dl, 2)))
      }
    }
    close(df_f)

    if (fsig_out != "") {
      for (p in fsig_list) printf "%s\t%s\n", p, fsig_list[p] > fsig_out
      close(fsig_out)
    }
    if (flines_out != "") {
      for (p in flines) printf "%s\t%d\n", p, flines[p] > flines_out
      close(flines_out)
    }

    if (n_rev == 0 && n_noise == 0) {
      print "IS_EMPTY=true"
      exit 0
    }

    sort_arr(rev_arr, n_rev)
    sort_arr(noise_arr, n_noise)

    cnt_a = 0; cnt_m = 0; cnt_d = 0; cnt_u = 0
    split("", c_arr); nc = 0; split("", t_arr); nt = 0; split("", g_arr); ng = 0; split("", g_seen)
    for (i = 1; i <= n_rev; i++) {
      fp = rev_arr[i]
      ct = (fp in ch_map ? ch_map[fp] : "M")
      if (ct == "A") cnt_a++; else if (ct == "D") cnt_d++; else if (ct == "U") cnt_u++; else cnt_m++
      if (is_contract_p(fp)) c_arr[++nc] = fp
      if (is_test_p(fp)) t_arr[++nt] = fp
      if (is_gen_p(fp) && !(fp in g_seen)) { g_seen[fp] = 1; g_arr[++ng] = fp }
    }
    for (i = 1; i <= n_noise; i++) {
      fp = noise_arr[i]
      if (is_gen_p(fp) && !(fp in g_seen)) { g_seen[fp] = 1; g_arr[++ng] = fp }
    }
    sort_arr(g_arr, ng)

    sz = tshirt_sz(n_rev, total_lines)
    if (n_rev > 0) eval_subset(rev_arr, n_rev)
    else eval_subset(noise_arr, n_noise)
    pr_risk = _EV_RISK; pr_sigs = _EV_SIGS; pr_specs = _EV_SPECS

    rf_out = (n_rev > 0 ? rev_arr[1] : "none"); for (i = 2; i <= n_rev; i++) rf_out = rf_out "," rev_arr[i]
    nf_out = (n_noise > 0 ? noise_arr[1] : "none"); for (i = 2; i <= n_noise; i++) nf_out = nf_out "," noise_arr[i]
    cf_out = (nc > 0 ? c_arr[1] : "none"); for (i = 2; i <= nc; i++) cf_out = cf_out "," c_arr[i]
    gf_out = (ng > 0 ? g_arr[1] : "none"); for (i = 2; i <= ng; i++) gf_out = gf_out "," g_arr[i]
    tf_out = (nt > 0 ? t_arr[1] : "none"); for (i = 2; i <= nt; i++) tf_out = tf_out "," t_arr[i]

    split("", nt_grps); n_ntg = 0; split("", grp_files); split("", all_grps); n_ag = 0
    for (i = 1; i <= n_rev; i++) {
      fp = rev_arr[i]
      if (is_test_p(fp)) continue
      g = raw_group(fp)
      if (!(g in nt_grps)) { nt_grps[g] = 1; nt_garr[++n_ntg] = g }
      if (!(g in grp_files)) all_grps[++n_ag] = g
      grp_files[g] = (g in grp_files ? grp_files[g] "\t" fp : fp)
    }
    sort_arr(nt_garr, n_ntg)
    for (i = 1; i <= n_rev; i++) {
      fp = rev_arr[i]
      if (!is_test_p(fp)) continue
      g = raw_group(fp)
      assigned = g
      if (!(g in nt_grps)) {
        tok = ""
        nsg = split(fp, segs, "/")
        if (nsg >= 3 && tolower(segs[1]) ~ /^(tests?|__tests__)$/) tok = segs[2]
        else {
          lf = segs[nsg]
          if (match(tolower(lf), /\.(test|spec)\.[^.\/]+$/)) tok = substr(lf, 1, RSTART - 1)
        }
        if (tok != "") {
          mc = 0; mgrp = ""
          for (j = 1; j <= n_ntg; j++) {
            cand = nt_garr[j]
            if (cand == tok || (length(cand) > length(tok) + 1 && substr(cand, length(cand) - length(tok)) == "/" tok)) {
              mc++; mgrp = cand
            }
          }
          if (mc == 1) assigned = mgrp
        }
      }
      if (!(assigned in grp_files)) all_grps[++n_ag] = assigned
      grp_files[assigned] = (assigned in grp_files ? grp_files[assigned] "\t" fp : fp)
    }
    sort_arr(all_grps, n_ag)

    eval_l1_dispatch(cf_out, pr_specs, pr_risk, rev_arr, n_rev)
    printf "IS_EMPTY=false\nSIZE_CLASS=%s\nFILES=%d\nLINES=%d\nRISK_LEVEL=%s\nRISK_SIGNALS=%s\nREC_SPECS=%s\nL1_SPECS=%s\nL1_SKIP=%s\nREVIEW_FILES=%s\nNOISE_FILES=%s\nCHANGE_TYPES=A:%d,M:%d,D:%d,U:%d\nCONTRACT_FILES=%s\nGENERATED_FILES=%s\nTEST_FILES=%s\nMAX_CONC=%d\n", sz, n_rev, total_lines, pr_risk, pr_sigs, pr_specs, _L1_SPECS, _L1_SKIP, rf_out, nf_out, cnt_a, cnt_m, cnt_d, cnt_u, cf_out, gf_out, tf_out, max_conc

    if (need_units != "true" || n_rev == 0) {
      split_rec = ((sz == "L" || sz == "XL" || sz == "XXL") && (n_ag >= 2 || total_lines > 800) ? "true" : "false")
      printf "SPLIT_REC=%s\nUNIT_COUNT=0\n", split_rec
      exit 0
    }

    has_ov = 0
    for (u = 1; u <= n_ag; u++) {
      g = all_grps[u]
      nu = split(grp_files[g], u_arr, "\t")
      ulines = 0
      for (k = 1; k <= nu; k++) if (u_arr[k] in flines) ulines += flines[u_arr[k]]
      if (is_oversized(nu, ulines)) {
        has_ov = 1
        for (k = 1; k <= nu; k++) {
          if (!is_test_p(u_arr[k])) printf "%s\n", u_arr[k] > ov_f
        }
      }
    }
    close(ov_f)

    need_cap = ((sz == "L" || sz == "XL") && n_ag > 4 ? 1 : 0)
    if (!has_ov && !need_cap) {
      split_rec = ((sz == "L" || sz == "XL" || sz == "XXL") && (n_ag >= 2 || total_lines > 800) ? "true" : "false")
      printf "SPLIT_REC=%s\nUNIT_COUNT=%d\n", split_rec, n_ag
      for (u = 1; u <= n_ag; u++) {
        g = all_grps[u]
        nu = split(grp_files[g], u_arr, "\t")
        sort_arr(u_arr, nu)
        ulines = 0; ucsv = u_arr[1]
        if (u_arr[1] in flines) ulines += flines[u_arr[1]]
        for (k = 2; k <= nu; k++) {
          ucsv = ucsv "," u_arr[k]
          if (u_arr[k] in flines) ulines += flines[u_arr[k]]
        }
        eval_subset(u_arr, nu)
        uid = sprintf("U%02d", u)
        printf "UNIT\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", uid, g, nu, ulines, _EV_RISK, _EV_SPECS, _EV_SIGS, ucsv
      }
      exit 0
    }

    for (u = 1; u <= n_ag; u++) {
      g = all_grps[u]
      nu = split(grp_files[g], u_arr, "\t")
      sort_arr(u_arr, nu)
      line_out = g
      for (k = 1; k <= nu; k++) line_out = line_out "\t" u_arr[k]
      printf "%s\n", line_out > raw_u_f
    }
    close(raw_u_f)
    printf "NEED_PART=1\nNEED_IMP=%d\n", has_ov
  }')"; then
    echo "${prefix}: scope engine awk failed"
    return 1
  fi

  local need_part=0 need_imp=0 out_buf="" ln_p sz_val="" tot_lines_val=0
  while IFS= read -r ln_p; do
    case "$ln_p" in
      NEED_PART=1) need_part=1 ;;
      NEED_IMP=*) need_imp="${ln_p#NEED_IMP=}" ;;
      SIZE_CLASS=*) sz_val="${ln_p#SIZE_CLASS=}"; out_buf+="${ln_p}"$'\n' ;;
      LINES=*) tot_lines_val="${ln_p#LINES=}"; out_buf+="${ln_p}"$'\n' ;;
      *) out_buf+="${ln_p}"$'\n' ;;
    esac
  done <<< "$pass1_out"

  if [[ "$need_part" -eq 1 ]]; then
    if [[ "$need_imp" -eq 1 && -s "$ov_tmp" ]]; then
      while IFS= read -r cand_fp; do
        [[ -n "$cand_fp" ]] || continue
        if [[ -n "$target_commit" ]]; then
          if run_git_cmd "$root" show "${target_commit}:${cand_fp}"; then
            printf '%s\n' "$_GIT_STDOUT" | LC_ALL=C awk -v fp="$cand_fp" '
            {
              rest = $0
              while (match(rest, /["\047]\.\.?\/[^"\047\r\n]+["\047]/)) {
                sp = substr(rest, RSTART + 1, RLENGTH - 2)
                printf "%s\t%s\n", fp, sp
                rest = substr(rest, RSTART + RLENGTH)
              }
            }' >> "$imp_tmp"
          fi
        else
          local full_cand="${root_slash}/${cand_fp}"
          if [[ -f "$full_cand" ]] && ! is_binary_file "$full_cand"; then
            LC_ALL=C awk -v fp="$cand_fp" '
            {
              rest = $0
              while (match(rest, /["\047]\.\.?\/[^"\047\r\n]+["\047]/)) {
                sp = substr(rest, RSTART + 1, RLENGTH - 2)
                printf "%s\t%s\n", fp, sp
                rest = substr(rest, RSTART + RLENGTH)
              }
            }' "$full_cand" >> "$imp_tmp"
          fi
        fi
      done < "$ov_tmp"
    fi

    local pass2_out
    if ! pass2_out="$(LC_ALL=C awk \
      -v sz="$sz_val" \
      -v total_lines="$tot_lines_val" \
      -v fsig_f="$fsig_use" \
      -v flines_f="$flines_use" \
      -v raw_u_f="$raw_u_tmp" \
      -v imp_f="$imp_tmp" \
      "$_B3_RISK_AWK_LIB"'
    function basename_aw(p,   n, s) { n = split(p, s, "/"); return s[n] }
    function dirname_aw(p,   i) {
      for (i = length(p); i >= 1; i--) if (substr(p, i, 1) == "/") return substr(p, 1, i - 1)
      return ""
    }
    function strip_ext_any(s) { sub(/\.[^.]+$/, "", s); return s }
    function ext_of(p,   lf, i) {
      lf = basename_aw(p)
      for (i = length(lf); i >= 1; i--) {
        if (substr(lf, i, 1) == ".") {
          if (i < length(lf)) return tolower(substr(lf, i + 1))
          return "noext"
        }
      }
      return "noext"
    }
    function feat_token(p,   lf, stem, lstem, sp, nw, w, end_i, out_s, k, layer_re) {
      lf = basename_aw(p); stem = lf; sub(/\.[^.]+$/, "", stem)
      lstem = tolower(stem)
      if (match(lstem, /\.(test|spec|generated|pb|g|designer)$/)) stem = substr(stem, 1, RSTART - 1)
      gsub(/[-_.]+/, " ", stem)
      while (match(stem, /[a-z0-9][A-Z]/)) stem = substr(stem, 1, RSTART) " " substr(stem, RSTART + 1)
      sp = tolower(stem); gsub(/^[ \t]+|[ \t]+$/, "", sp)
      if (sp == "") return "misc"
      nw = split(sp, w, /[ \t]+/)
      if (nw < 1 || w[1] == "") return "misc"
      layer_re = "^(controllers?|services?|repositor(y|ies)|repo|handlers?|models?|types?|schemas?|utils?|helpers?|views?|components?|slice|store|routes?|router|api|client|impl|dtos?|spec|test)$"
      end_i = nw
      while (end_i > 1 && w[end_i] ~ layer_re) end_i--
      out_s = w[1]
      for (k = 2; k <= end_i; k++) out_s = out_s "-" w[k]
      return out_s
    }
    function stem_no_ext(p,   lp) {
      lp = tolower(p); sub(/\.(tsx|ts|jsx|js|mjs|cjs|py|go|rs|cpp|hpp|c|h|cs|java|proto|graphql|gql)$/, "", lp); return lp
    }
    function resolve_rel_imp(from_f, rel_spec,   cl, dp, raw_d, n_d, stk, depth, ns, segs, i, joined) {
      cl = rel_spec; gsub(/\\/, "/", cl); sub(/[?#].*$/, "", cl); gsub(/^[ \t]+|[ \t]+$/, "", cl)
      if (cl == "" || (substr(cl, 1, 2) != "./" && substr(cl, 1, 3) != "../")) return ""
      dp = dirname_aw(from_f); depth = 0
      if (dp != "") {
        n_d = split(dp, raw_d, "/")
        for (i = 1; i <= n_d; i++) if (raw_d[i] != "") stk[++depth] = raw_d[i]
      }
      ns = split(cl, segs, "/")
      for (i = 1; i <= ns; i++) {
        if (segs[i] == "" || segs[i] == ".") continue
        if (segs[i] == "..") { if (depth > 0) depth--; else return "" }
        else stk[++depth] = segs[i]
      }
      if (depth == 0) return ""
      joined = stk[1]; for (i = 2; i <= depth; i++) joined = joined "/" stk[i]
      return stem_no_ext(joined)
    }
    function top_seg_of(g,   sl) {
      if (g == "root" || substr(g, 1, 1) == "(") return g
      sl = index(g, "/")
      return (sl > 0 ? substr(g, 1, sl - 1) : g)
    }
    function join_uniq_tsv(a_tsv, b_tsv, sort_flag,   na, nb, a_arr, b_arr, seen, out_a, n_o, i, res) {
      split("", seen); split("", out_a); n_o = 0
      if (a_tsv != "") {
        na = split(a_tsv, a_arr, "\t")
        for (i = 1; i <= na; i++) if (a_arr[i] != "" && !(a_arr[i] in seen)) { seen[a_arr[i]] = 1; out_a[++n_o] = a_arr[i] }
      }
      if (b_tsv != "") {
        nb = split(b_tsv, b_arr, "\t")
        for (i = 1; i <= nb; i++) if (b_arr[i] != "" && !(b_arr[i] in seen)) { seen[b_arr[i]] = 1; out_a[++n_o] = b_arr[i] }
      }
      if (n_o == 0) return ""
      if (sort_flag) sort_arr(out_a, n_o)
      res = out_a[1]; for (i = 2; i <= n_o; i++) res = res "\t" out_a[i]
      return res
    }
    function has_contract_tsv(ftsv,   a, n, i) {
      n = split(ftsv, a, "\t")
      for (i = 1; i <= n; i++) if (is_contract_p(a[i])) return 1
      return 0
    }
    function score_bucket(idx, grp, mem, ftsv, fts, arr_g, arr_m, arr_f, arr_ft, arr_fc, arr_lc, arr_rk, arr_sp, arr_sg, arr_csv, arr_top, arr_f0,   fa, nf, k, lc) {
      nf = split(ftsv, fa, "\t")
      sort_arr(fa, nf)
      lc = 0
      for (k = 1; k <= nf; k++) if (fa[k] in flines) lc += flines[fa[k]]
      eval_subset(fa, nf)
      arr_g[idx] = grp; arr_m[idx] = mem; arr_ft[idx] = fts
      arr_f[idx] = fa[1]; arr_csv[idx] = fa[1]
      for (k = 2; k <= nf; k++) { arr_f[idx] = arr_f[idx] "\t" fa[k]; arr_csv[idx] = arr_csv[idx] "," fa[k] }
      arr_f0[idx] = (nf > 0 ? fa[1] : "")
      arr_fc[idx] = nf; arr_lc[idx] = lc
      arr_rk[idx] = _EV_RISK; arr_sp[idx] = _EV_SPECS; arr_sg[idx] = _EV_SIGS
      arr_top[idx] = top_seg_of(grp)
    }
    function attach_tests_aw(parent_g, b_cnt, b_grp, b_mem, b_files, b_fts, t_arr, nt,   i, tf, ass, pfx, trem, psl, tseg, tf_lf, tf_st, l_tf, mc, mi, j, nrf, rf_a, k, rf_st, hit, tfeat, nft, ft_a, nex, ex_a, tgrp, ex_f) {
      split("", ex_a); nex = 0
      for (i = 1; i <= nt; i++) {
        tf = t_arr[i]; ass = 0
        if (parent_g != "root") {
          pfx = parent_g "/"
          if (index(tf, pfx) == 1) {
            trem = substr(tf, length(pfx) + 1)
            psl = index(trem, "/")
            if (psl > 0) {
              tseg = pfx substr(trem, 1, psl - 1)
              for (j = 1; j <= b_cnt; j++) if (b_grp[j] == tseg) { ass = j; break }
            }
          }
        }
        if (ass == 0) {
          tf_lf = basename_aw(tf); tf_st = strip_ext_any(tf_lf); l_tf = tolower(tf_st)
          if (match(l_tf, /\.(test|spec)$/)) l_tf = substr(l_tf, 1, RSTART - 1)
          mc = 0; mi = 0
          for (j = 1; j <= b_cnt; j++) {
            nrf = split(b_files[j], rf_a, "\t"); hit = 0
            for (k = 1; k <= nrf; k++) {
              rf_st = tolower(strip_ext_any(basename_aw(rf_a[k])))
              if (rf_st == l_tf) { hit = 1; break }
            }
            if (hit) { mc++; mi = j }
          }
          if (mc == 0) {
            tfeat = feat_token(tf)
            for (j = 1; j <= b_cnt; j++) {
              nft = split(b_fts[j], ft_a, "\t")
              for (k = 1; k <= nft; k++) if (ft_a[k] == tfeat) { mc++; mi = j; break }
            }
          }
          if (mc == 1) ass = mi
        }
        if (ass > 0) b_files[ass] = (b_files[ass] != "" ? b_files[ass] "\t" tf : tf)
        else ex_a[++nex] = tf
      }
      if (nex > 0) {
        tgrp = (parent_g == "root" ? "(tests)" : parent_g "/(tests)")
        b_cnt++
        b_grp[b_cnt] = tgrp; b_mem[b_cnt] = tgrp; b_fts[b_cnt] = ""
        ex_f = ex_a[1]; for (i = 2; i <= nex; i++) ex_f = ex_f "\t" ex_a[i]
        b_files[b_cnt] = ex_f
      }
      return b_cnt
    }
    function coalesce_tiny_aw(n_in, in_g, in_m, in_f, in_ft, out_g, out_m, out_f, out_ft, out_fc, out_lc, out_rk, out_sp, out_sg, out_csv, out_top, out_f0,   i, tiny_i, tiny_l, j, best_j, best_sc, cf, cl, sc, mg, mm, mf, mft, lo, hi, k) {
      split("", out_g); split("", out_m); split("", out_f); split("", out_ft)
      split("", out_fc); split("", out_lc); split("", out_rk); split("", out_sp); split("", out_sg); split("", out_csv); split("", out_top); split("", out_f0)
      for (i = 1; i <= n_in; i++) {
        score_bucket(i, in_g[i], in_m[i], in_f[i], in_ft[i], out_g, out_m, out_f, out_ft, out_fc, out_lc, out_rk, out_sp, out_sg, out_csv, out_top, out_f0)
      }
      while (n_in > 4) {
        tiny_i = 0; tiny_l = 999999999
        for (i = 1; i <= n_in; i++) {
          if (out_fc[i] < 2 && out_lc[i] < 200 && out_rk[i] != "CRITICAL" && !has_contract_tsv(out_f[i])) {
            if (out_lc[i] < tiny_l) { tiny_l = out_lc[i]; tiny_i = i }
          }
        }
        if (tiny_i == 0) break
        best_j = 0; best_sc = 999999999999
        for (j = 1; j <= n_in; j++) {
          if (j == tiny_i) continue
          cf = out_fc[tiny_i] + out_fc[j]; cl = out_lc[tiny_i] + out_lc[j]
          if (is_oversized(cf, cl)) continue
          sc = cl
          if (out_rk[j] != out_rk[tiny_i]) sc += 100000
          if (out_rk[j] == "CRITICAL") sc += 500000
          if (sc < best_sc) { best_sc = sc; best_j = j }
        }
        if (best_j == 0) break
        mg = (length(out_g[best_j]) >= length(out_g[tiny_i]) ? out_g[best_j] : out_g[tiny_i])
        mm = join_uniq_tsv(out_m[tiny_i], out_m[best_j], 0)
        mf = out_f[tiny_i] "\t" out_f[best_j]
        mft = join_uniq_tsv(out_ft[tiny_i], out_ft[best_j], 0)
        lo = (tiny_i < best_j ? tiny_i : best_j)
        hi = (tiny_i > best_j ? tiny_i : best_j)
        for (k = hi; k < n_in; k++) {
          out_g[k] = out_g[k+1]; out_m[k] = out_m[k+1]; out_f[k] = out_f[k+1]; out_ft[k] = out_ft[k+1]
          out_fc[k] = out_fc[k+1]; out_lc[k] = out_lc[k+1]; out_rk[k] = out_rk[k+1]; out_sp[k] = out_sp[k+1]
          out_sg[k] = out_sg[k+1]; out_csv[k] = out_csv[k+1]; out_top[k] = out_top[k+1]; out_f0[k] = out_f0[k+1]
        }
        for (k = lo; k < n_in - 1; k++) {
          out_g[k] = out_g[k+1]; out_m[k] = out_m[k+1]; out_f[k] = out_f[k+1]; out_ft[k] = out_ft[k+1]
          out_fc[k] = out_fc[k+1]; out_lc[k] = out_lc[k+1]; out_rk[k] = out_rk[k+1]; out_sp[k] = out_sp[k+1]
          out_sg[k] = out_sg[k+1]; out_csv[k] = out_csv[k+1]; out_top[k] = out_top[k+1]; out_f0[k] = out_f0[k+1]
        }
        n_in -= 2
        n_in++
        score_bucket(n_in, mg, mm, mf, mft, out_g, out_m, out_f, out_ft, out_fc, out_lc, out_rk, out_sp, out_sg, out_csv, out_top, out_f0)
      }
      return n_in
    }
    function uf_find(x, pa,   r) {
      r = x
      while (pa[r] != r) { pa[r] = pa[pa[r]]; r = pa[r] }
      return r
    }
    function uf_union(a, b, pa,   ra, rb) {
      ra = uf_find(a, pa); rb = uf_find(b, pa)
      if (ra != rb) { if (ra < rb) pa[rb] = ra; else pa[ra] = rb }
    }
    function expand_oversized_iter(init_g, init_m, init_f, init_fc, init_lc,   st_top, st_g, st_m, st_f, st_ft, st_dp, st_fc, st_lc, st_rk, st_sp, st_sg, st_csv, st_top_seg, st_f0, ug, um, uf, uft, udp, ufc, ulc, uf_arr, nuf, i, f, fl, nnt, nt, nt_a, t_a, raw_g, base_g, pfx, dir_map, dkeys, n_dk, has_dp, rem, psl, ck, sb_cnt, sb_g, sb_m, sb_f, sb_ft, k, fts_seen, sb_f_arr, nsf, ftv, c_cnt, cg, cm, cf, cft, cfc, clc, crk, csp, csg, ccsv, ctop, cf0, ncon, con_a, nreg, reg_a, b2_cnt, b2_g, b2_m, b2_f, b2_ft, cgrp, p_arr, f_toks, file_exts, stem_m, feat_1st, rf, sk, d_sk, nic, tgt_s, n_ed, ed_a, ed_b, comp_xext, comp_f, comp_idxs, comp_ft, comp_fts_seen, ri, sub_g, nft_t, sorted_ft, st_r, c_fa, c_nf, c_nl, ext_map, ext_keys, n_ek, c_idx_arr, n_ci, ix_v, ex_v, ext_sg, c2_cnt, c2g, c2m, c2f, c2ft, c2fc, c2lc, c2rk, c2sp, c2sg, c2csv, c2top, c2f0) {
      st_top = 1
      st_g[1] = init_g; st_m[1] = init_m; st_f[1] = init_f; st_ft[1] = ""; st_dp[1] = 0
      st_fc[1] = init_fc; st_lc[1] = init_lc
      while (st_top > 0) {
        ug = st_g[st_top]; um = st_m[st_top]; uf = st_f[st_top]; uft = st_ft[st_top]; udp = st_dp[st_top]
        ufc = st_fc[st_top]; ulc = st_lc[st_top]
        if (udp < 0) {
          fin_cnt++
          fin_g[fin_cnt] = ug; fin_m[fin_cnt] = um; fin_f[fin_cnt] = uf; fin_ft[fin_cnt] = uft
          fin_fc[fin_cnt] = ufc; fin_lc[fin_cnt] = ulc
          fin_rk[fin_cnt] = st_rk[st_top]; fin_sp[fin_cnt] = st_sp[st_top]; fin_sg[fin_cnt] = st_sg[st_top]
          fin_csv[fin_cnt] = st_csv[st_top]; fin_top[fin_cnt] = st_top_seg[st_top]; fin_f0[fin_cnt] = st_f0[st_top]
          st_top--
          continue
        }
        st_top--

        nuf = split(uf, uf_arr, "\t")
        for (i = 1; i <= nuf; i++) {
          f = uf_arr[i]
          fl = (f in flines ? flines[f] : 0)
          if (fl > 5000) {
            _PART_ERR = sprintf("PARTITION_INCOMPLETE: single file \047%s\047 (%dL) exceeds max unit bound (5000L); refactor or split PR", f, fl)
            return 1
          }
        }

        split("", nt_a); split("", t_a); nnt = 0; nt = 0
        for (i = 1; i <= nuf; i++) {
          if (is_test_p(uf_arr[i])) t_a[++nt] = uf_arr[i]
          else nt_a[++nnt] = uf_arr[i]
        }
        raw_g = ug; base_g = raw_g
        sub(/\/\((root|contracts)\)$/, "", base_g)
        pfx = (base_g == "root" || substr(base_g, 1, 1) == "(" ? "" : base_g "/")

        if (udp < 4) {
          split("", dir_map); split("", dkeys); n_dk = 0; has_dp = 0
          for (i = 1; i <= nnt; i++) {
            f = nt_a[i]
            rem = (pfx != "" && index(f, pfx) == 1 ? substr(f, length(pfx) + 1) : (pfx == "" ? f : ""))
            psl = (rem != "" ? index(rem, "/") : 0)
            if (psl > 0) {
              has_dp = 1
              ck = (pfx != "" ? pfx substr(rem, 1, psl - 1) : substr(rem, 1, psl - 1))
            } else if (is_contract_p(f)) {
              ck = (base_g == "root" ? "(contracts)" : base_g "/(contracts)")
            } else {
              ck = (base_g == "root" ? "(root)" : base_g "/(root)")
            }
            if (!(ck in dir_map)) dkeys[++n_dk] = ck
            dir_map[ck] = (ck in dir_map ? dir_map[ck] "\t" f : f)
          }
          if (has_dp && n_dk >= 2) {
            sort_arr(dkeys, n_dk)
            split("", sb_g); split("", sb_m); split("", sb_f); split("", sb_ft); sb_cnt = 0
            for (k = 1; k <= n_dk; k++) {
              ck = dkeys[k]; sb_cnt++
              sb_g[sb_cnt] = ck; sb_m[sb_cnt] = ck; sb_f[sb_cnt] = dir_map[ck]
              nsf = split(dir_map[ck], sb_f_arr, "\t")
              split("", fts_seen); sb_ft[sb_cnt] = ""
              for (i = 1; i <= nsf; i++) {
                ftv = feat_token(sb_f_arr[i])
                if (!(ftv in fts_seen)) { fts_seen[ftv] = 1; sb_ft[sb_cnt] = (sb_ft[sb_cnt] == "" ? ftv : sb_ft[sb_cnt] "\t" ftv) }
              }
            }
            sb_cnt = attach_tests_aw(base_g, sb_cnt, sb_g, sb_m, sb_f, sb_ft, t_a, nt)
            c_cnt = coalesce_tiny_aw(sb_cnt, sb_g, sb_m, sb_f, sb_ft, cg, cm, cf, cft, cfc, clc, crk, csp, csg, ccsv, ctop, cf0)
            for (k = c_cnt; k >= 1; k--) {
              st_top++
              st_g[st_top] = cg[k]; st_m[st_top] = cm[k]; st_f[st_top] = cf[k]; st_ft[st_top] = cft[k]
              st_fc[st_top] = cfc[k]; st_lc[st_top] = clc[k]
              if (is_oversized(cfc[k], clc[k])) {
                st_dp[st_top] = udp + 1
              } else {
                st_dp[st_top] = -1
                st_rk[st_top] = crk[k]; st_sp[st_top] = csp[k]; st_sg[st_top] = csg[k]
                st_csv[st_top] = ccsv[k]; st_top_seg[st_top] = ctop[k]; st_f0[st_top] = cf0[k]
              }
            }
            continue
          }
        }

        split("", con_a); split("", reg_a); ncon = 0; nreg = 0
        for (i = 1; i <= nnt; i++) {
          if (is_contract_p(nt_a[i])) con_a[++ncon] = nt_a[i]
          else reg_a[++nreg] = nt_a[i]
        }
        split("", b2_g); split("", b2_m); split("", b2_f); split("", b2_ft); b2_cnt = 0
        if (ncon > 0 && nreg > 0) {
          cgrp = (base_g == "root" || substr(base_g, 1, 1) == "(" ? "(contracts)" : base_g "/(contracts)")
          b2_cnt++; b2_g[1] = cgrp; b2_m[1] = cgrp; b2_ft[1] = "contracts"
          b2_f[1] = con_a[1]; for (i = 2; i <= ncon; i++) b2_f[1] = b2_f[1] "\t" con_a[i]
        } else if (ncon > 0) {
          for (i = 1; i <= ncon; i++) reg_a[++nreg] = con_a[i]
        }

        if (nreg > 0) {
          split("", p_arr); split("", f_toks); split("", file_exts); split("", stem_m); split("", feat_1st)
          split("", ed_a); split("", ed_b); n_ed = 0
          for (i = 0; i < nreg; i++) {
            p_arr[i] = i
            rf = reg_a[i + 1]
            ftv = feat_token(rf)
            f_toks[i] = ftv
            file_exts[i] = ext_of(rf)
            sk = stem_no_ext(rf)
            if (!(sk in stem_m)) stem_m[sk] = i
            if (length(sk) > 6 && substr(sk, length(sk) - 5) == "/index") {
              d_sk = substr(sk, 1, length(sk) - 6)
              if (d_sk != "" && !(d_sk in stem_m)) stem_m[d_sk] = i
            }
          }
          for (i = 0; i < nreg; i++) {
            ftv = f_toks[i]
            if (ftv in feat_1st) uf_union(feat_1st[ftv], i, p_arr)
            else feat_1st[ftv] = i
            rf = reg_a[i + 1]
            nic = (rf in imp_cnt ? imp_cnt[rf] : 0)
            for (k = 1; k <= nic; k++) {
              tgt_s = resolve_rel_imp(rf, imp_spec[rf SUBSEP k])
              if (tgt_s != "" && (tgt_s in stem_m)) {
                uf_union(i, stem_m[tgt_s], p_arr)
                n_ed++; ed_a[n_ed] = i; ed_b[n_ed] = stem_m[tgt_s]
              }
            }
          }
          split("", comp_xext)
          for (k = 1; k <= n_ed; k++) {
            if (file_exts[ed_a[k]] != file_exts[ed_b[k]]) {
              comp_xext[uf_find(ed_a[k], p_arr)] = 1
            }
          }
          split("", comp_f); split("", comp_idxs); split("", comp_ft); split("", comp_fts_seen)
          for (i = 0; i < nreg; i++) {
            ri = uf_find(i, p_arr)
            rf = reg_a[i + 1]
            comp_f[ri] = (ri in comp_f ? comp_f[ri] "\t" rf : rf)
            comp_idxs[ri] = (ri in comp_idxs ? comp_idxs[ri] "\t" i : "" i)
            if (!(ri SUBSEP f_toks[i] in comp_fts_seen)) {
              comp_fts_seen[ri SUBSEP f_toks[i]] = 1
              comp_ft[ri] = (ri in comp_ft ? comp_ft[ri] "\t" f_toks[i] : f_toks[i])
            }
          }
          for (i = 0; i < nreg; i++) {
            if (!(i in comp_f)) continue
            nft_t = split(comp_ft[i], sorted_ft, "\t")
            sort_arr(sorted_ft, nft_t)
            st_r = sorted_ft[1]; for (k = 2; k <= nft_t; k++) st_r = st_r "\t" sorted_ft[k]
            sub_g = (base_g == "root" || substr(base_g, 1, 1) == "(" ? sorted_ft[1] : base_g "/" sorted_ft[1])
            c_nf = split(comp_f[i], c_fa, "\t")
            c_nl = 0
            for (k = 1; k <= c_nf; k++) if (c_fa[k] in flines) c_nl += flines[c_fa[k]]
            if (is_oversized(c_nf, c_nl) && c_nf >= 2 && !(i in comp_xext)) {
              split("", ext_map); split("", ext_keys); n_ek = 0
              n_ci = split(comp_idxs[i], c_idx_arr, "\t")
              for (k = 1; k <= n_ci; k++) {
                ix_v = c_idx_arr[k] + 0
                ex_v = file_exts[ix_v]
                if (!(ex_v in ext_map)) ext_keys[++n_ek] = ex_v
                ext_map[ex_v] = (ex_v in ext_map ? ext_map[ex_v] "\t" reg_a[ix_v + 1] : reg_a[ix_v + 1])
              }
              if (n_ek >= 2) {
                sort_arr(ext_keys, n_ek)
                for (k = 1; k <= n_ek; k++) {
                  ext_sg = sub_g "(" ext_keys[k] ")"
                  b2_cnt++; b2_g[b2_cnt] = ext_sg; b2_m[b2_cnt] = ext_sg; b2_f[b2_cnt] = ext_map[ext_keys[k]]; b2_ft[b2_cnt] = st_r
                }
                continue
              }
            }
            b2_cnt++; b2_g[b2_cnt] = sub_g; b2_m[b2_cnt] = sub_g; b2_f[b2_cnt] = comp_f[i]; b2_ft[b2_cnt] = st_r
          }
        }

        if (b2_cnt >= 2) {
          b2_cnt = attach_tests_aw(base_g, b2_cnt, b2_g, b2_m, b2_f, b2_ft, t_a, nt)
          c2_cnt = coalesce_tiny_aw(b2_cnt, b2_g, b2_m, b2_f, b2_ft, c2g, c2m, c2f, c2ft, c2fc, c2lc, c2rk, c2sp, c2sg, c2csv, c2top, c2f0)
          for (k = 1; k <= c2_cnt; k++) {
            if (is_oversized(c2fc[k], c2lc[k])) {
              _PART_ERR = sprintf("PARTITION_INCOMPLETE: oversized unit \047%s\047 (%df, %dL) cannot be cohesively partitioned without arbitrary LOC splitting", c2g[k], c2fc[k], c2lc[k])
              return 1
            }
            fin_cnt++
            fin_g[fin_cnt] = c2g[k]; fin_m[fin_cnt] = c2m[k]; fin_f[fin_cnt] = c2f[k]; fin_ft[fin_cnt] = c2ft[k]
            fin_fc[fin_cnt] = c2fc[k]; fin_lc[fin_cnt] = c2lc[k]; fin_rk[fin_cnt] = c2rk[k]; fin_sp[fin_cnt] = c2sp[k]
            fin_sg[fin_cnt] = c2sg[k]; fin_csv[fin_cnt] = c2csv[k]; fin_top[fin_cnt] = c2top[k]; fin_f0[fin_cnt] = c2f0[k]
          }
          continue
        }

        _PART_ERR = sprintf("PARTITION_INCOMPLETE: oversized unit \047%s\047 (%df, %dL) cannot be cohesively partitioned without arbitrary LOC splitting", raw_g, ufc, ulc)
        return 1
      }
      return 0
    }
    function merge_cohesive_to_cap(   bi, bj, btop, bcrit, brisk, blines, bfiles, bga, bgb, i, j, cf, cl, dt, dc, dr, ga, gb, bet, mm, ma, m_cnt, mg, mf, mft, k) {
      while (fin_cnt > 4) {
        bi = 0; bj = 0; btop = 9; bcrit = 9; brisk = 9; blines = 999999999; bfiles = 999999999; bga = ""; bgb = ""
        for (i = 1; i <= fin_cnt; i++) {
          for (j = i + 1; j <= fin_cnt; j++) {
            cf = fin_fc[i] + fin_fc[j]; cl = fin_lc[i] + fin_lc[j]
            if (is_oversized(cf, cl)) continue
            dt = (fin_top[i] == fin_top[j] ? 0 : 1)
            dc = ((fin_rk[i] == "CRITICAL") != (fin_rk[j] == "CRITICAL") ? 1 : 0)
            dr = (fin_rk[i] == fin_rk[j] ? 0 : 1)
            ga = (fin_g[i] <= fin_g[j] ? fin_g[i] : fin_g[j])
            gb = (ga == fin_g[i] ? fin_g[j] : fin_g[i])
            bet = 0
            if (dt < btop) bet = 1
            else if (dt == btop) {
              if (dc < bcrit) bet = 1
              else if (dc == bcrit) {
                if (dr < brisk) bet = 1
                else if (dr == brisk) {
                  if (cl < blines) bet = 1
                  else if (cl == blines) {
                    if (cf < bfiles) bet = 1
                    else if (cf == bfiles) {
                      if (ga < bga || (ga == bga && gb < bgb)) bet = 1
                    }
                  }
                }
              }
            }
            if (bet) {
              bi = i; bj = j; btop = dt; bcrit = dc; brisk = dr; blines = cl; bfiles = cf; bga = ga; bgb = gb
            }
          }
        }
        if (bi == 0) {
          _PART_ERR = sprintf("PARTITION_INCOMPLETE: cannot bound %s PR to <= 4 cohesive units without exceeding unit bounds", sz)
          return 1
        }
        mm = join_uniq_tsv(fin_m[bi], fin_m[bj], 1)
        m_cnt = split(mm, ma, "\t")
        mg = (m_cnt == 2 ? ma[1] "+" ma[2] : ma[1] "+" (m_cnt - 1) "more")
        mf = fin_f[bi] "\t" fin_f[bj]
        mft = join_uniq_tsv(fin_ft[bi], fin_ft[bj], 0)
        for (k = bj; k < fin_cnt; k++) {
          fin_g[k] = fin_g[k+1]; fin_m[k] = fin_m[k+1]; fin_f[k] = fin_f[k+1]; fin_ft[k] = fin_ft[k+1]
          fin_fc[k] = fin_fc[k+1]; fin_lc[k] = fin_lc[k+1]; fin_rk[k] = fin_rk[k+1]; fin_sp[k] = fin_sp[k+1]
          fin_sg[k] = fin_sg[k+1]; fin_csv[k] = fin_csv[k+1]; fin_top[k] = fin_top[k+1]; fin_f0[k] = fin_f0[k+1]
        }
        for (k = bi; k < fin_cnt - 1; k++) {
          fin_g[k] = fin_g[k+1]; fin_m[k] = fin_m[k+1]; fin_f[k] = fin_f[k+1]; fin_ft[k] = fin_ft[k+1]
          fin_fc[k] = fin_fc[k+1]; fin_lc[k] = fin_lc[k+1]; fin_rk[k] = fin_rk[k+1]; fin_sp[k] = fin_sp[k+1]
          fin_sg[k] = fin_sg[k+1]; fin_csv[k] = fin_csv[k+1]; fin_top[k] = fin_top[k+1]; fin_f0[k] = fin_f0[k+1]
        }
        fin_cnt -= 2
        fin_cnt++
        score_bucket(fin_cnt, mg, mm, mf, mft, fin_g, fin_m, fin_f, fin_ft, fin_fc, fin_lc, fin_rk, fin_sp, fin_sg, fin_csv, fin_top, fin_f0)
      }
      return 0
    }
    function sort_fin_units(   i, j, tg, tm, tf, tft, tfc, tlc, trk, tsp, tsg, tcsv, ttop, tf0) {
      for (i = 2; i <= fin_cnt; i++) {
        tg = fin_g[i]; tm = fin_m[i]; tf = fin_f[i]; tft = fin_ft[i]; tfc = fin_fc[i]; tlc = fin_lc[i]
        trk = fin_rk[i]; tsp = fin_sp[i]; tsg = fin_sg[i]; tcsv = fin_csv[i]; ttop = fin_top[i]; tf0 = fin_f0[i]
        j = i - 1
        while (j >= 1 && (fin_g[j] > tg || (fin_g[j] == tg && fin_f0[j] > tf0))) {
          fin_g[j+1] = fin_g[j]; fin_m[j+1] = fin_m[j]; fin_f[j+1] = fin_f[j]; fin_ft[j+1] = fin_ft[j]
          fin_fc[j+1] = fin_fc[j]; fin_lc[j+1] = fin_lc[j]; fin_rk[j+1] = fin_rk[j]; fin_sp[j+1] = fin_sp[j]
          fin_sg[j+1] = fin_sg[j]; fin_csv[j+1] = fin_csv[j]; fin_top[j+1] = fin_top[j]; fin_f0[j+1] = fin_f0[j]
          j--
        }
        fin_g[j+1] = tg; fin_m[j+1] = tm; fin_f[j+1] = tf; fin_ft[j+1] = tft; fin_fc[j+1] = tfc; fin_lc[j+1] = tlc
        fin_rk[j+1] = trk; fin_sp[j+1] = tsp; fin_sg[j+1] = tsg; fin_csv[j+1] = tcsv; fin_top[j+1] = ttop; fin_f0[j+1] = tf0
      }
    }
    BEGIN {
      split("", fsig_list); split("", flines); split("", ign); n_ign = 0
      split("", imp_cnt); split("", imp_spec)
      if (fsig_f != "") {
        while ((getline ln < fsig_f) > 0) {
          sub(/\r$/, "", ln); t = index(ln, "\t")
          if (t > 1) fsig_list[substr(ln, 1, t - 1)] = substr(ln, t + 1)
        }
        close(fsig_f)
      }
      if (flines_f != "") {
        while ((getline ln < flines_f) > 0) {
          sub(/\r$/, "", ln); t = index(ln, "\t")
          if (t > 1) flines[substr(ln, 1, t - 1)] = substr(ln, t + 1) + 0
        }
        close(flines_f)
      }
      if (imp_f != "") {
        while ((getline ln < imp_f) > 0) {
          sub(/\r$/, "", ln); t = index(ln, "\t")
          if (t > 1) {
            fp = substr(ln, 1, t - 1); sp = substr(ln, t + 1)
            imp_cnt[fp] = (fp in imp_cnt ? imp_cnt[fp] + 1 : 1)
            imp_spec[fp SUBSEP imp_cnt[fp]] = sp
          }
        }
        close(imp_f)
      }
      fin_cnt = 0; _PART_ERR = ""
      while ((getline ln < raw_u_f) > 0) {
        sub(/\r$/, "", ln)
        t = index(ln, "\t")
        if (t < 2) continue
        rg = substr(ln, 1, t - 1)
        rf_tsv = substr(ln, t + 1)
        score_bucket(0, rg, rg, rf_tsv, "", tmp_g, tmp_m, tmp_f, tmp_ft, tmp_fc, tmp_lc, tmp_rk, tmp_sp, tmp_sg, tmp_csv, tmp_top, tmp_f0)
        if (is_oversized(tmp_fc[0], tmp_lc[0])) {
          if (expand_oversized_iter(rg, rg, rf_tsv, tmp_fc[0], tmp_lc[0]) != 0) {
            printf "PART_ERR=%s\n", _PART_ERR
            exit 0
          }
        } else {
          fin_cnt++
          fin_g[fin_cnt] = tmp_g[0]; fin_m[fin_cnt] = tmp_m[0]; fin_f[fin_cnt] = tmp_f[0]; fin_ft[fin_cnt] = ""
          fin_fc[fin_cnt] = tmp_fc[0]; fin_lc[fin_cnt] = tmp_lc[0]; fin_rk[fin_cnt] = tmp_rk[0]; fin_sp[fin_cnt] = tmp_sp[0]
          fin_sg[fin_cnt] = tmp_sg[0]; fin_csv[fin_cnt] = tmp_csv[0]; fin_top[fin_cnt] = tmp_top[0]; fin_f0[fin_cnt] = tmp_f0[0]
        }
      }
      close(raw_u_f)

      if ((sz == "L" || sz == "XL") && fin_cnt > 4) {
        if (merge_cohesive_to_cap() != 0) {
          printf "PART_ERR=%s\n", _PART_ERR
          exit 0
        }
      }

      sort_fin_units()
      split_rec = ((sz == "L" || sz == "XL" || sz == "XXL") && (fin_cnt >= 2 || total_lines + 0 > 800) ? "true" : "false")
      printf "SPLIT_REC=%s\nUNIT_COUNT=%d\n", split_rec, fin_cnt
      for (u = 1; u <= fin_cnt; u++) {
        uid = sprintf("U%02d", u)
        printf "UNIT\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", uid, fin_g[u], fin_fc[u], fin_lc[u], fin_rk[u], fin_sp[u], fin_sg[u], fin_csv[u]
      }
    }')"; then
      echo "${prefix}: partition engine awk failed"
      return 1
    fi
    out_buf+="$pass2_out"$'\n'
  fi

  printf '%s' "$out_buf"
  rm -f "$ns_tmp" "$st_tmp" "$df_tmp" "$unt_tmp" "$raw_u_tmp" "$ov_tmp" "$imp_tmp" 2>/dev/null || true
  [[ -n "$fsig_out_file" ]] || rm -f "$fsig_use" 2>/dev/null || true
  [[ -n "$flines_out_file" ]] || rm -f "$flines_use" 2>/dev/null || true
}

parse_scope_engine_output() {
  local raw="$1" sline
  _SE_IS_EMPTY="true"
  _SE_PART_ERR=""
  _SE_SIZE_CLASS=""
  _SE_FILES="0"
  _SE_LINES="0"
  _SE_RISK_LEVEL="LOW"
  _SE_RISK_SIGNALS="none"
  _SE_REC_SPECS="none"
  _SE_L1_SPECS="none"
  _SE_L1_SKIP="none"
  _SE_REVIEW_FILES="none"
  _SE_NOISE_FILES="none"
  _SE_CHANGE_TYPES=""
  _SE_CONTRACT_FILES="none"
  _SE_GENERATED_FILES="none"
  _SE_TEST_FILES="none"
  _SE_SPLIT_REC="false"
  _SE_MAX_CONC="4"
  _SE_UNIT_COUNT="0"
  _SE_UNITS=()
  while IFS= read -r sline; do
    case "$sline" in
      IS_EMPTY=*) _SE_IS_EMPTY="${sline#IS_EMPTY=}" ;;
      PART_ERR=*) _SE_PART_ERR="${sline#PART_ERR=}" ;;
      SIZE_CLASS=*) _SE_SIZE_CLASS="${sline#SIZE_CLASS=}" ;;
      FILES=*) _SE_FILES="${sline#FILES=}" ;;
      LINES=*) _SE_LINES="${sline#LINES=}" ;;
      RISK_LEVEL=*) _SE_RISK_LEVEL="${sline#RISK_LEVEL=}" ;;
      RISK_SIGNALS=*) _SE_RISK_SIGNALS="${sline#RISK_SIGNALS=}" ;;
      REC_SPECS=*) _SE_REC_SPECS="${sline#REC_SPECS=}" ;;
      L1_SPECS=*) _SE_L1_SPECS="${sline#L1_SPECS=}" ;;
      L1_SKIP=*) _SE_L1_SKIP="${sline#L1_SKIP=}" ;;
      REVIEW_FILES=*) _SE_REVIEW_FILES="${sline#REVIEW_FILES=}" ;;
      NOISE_FILES=*) _SE_NOISE_FILES="${sline#NOISE_FILES=}" ;;
      CHANGE_TYPES=*) _SE_CHANGE_TYPES="${sline#CHANGE_TYPES=}" ;;
      CONTRACT_FILES=*) _SE_CONTRACT_FILES="${sline#CONTRACT_FILES=}" ;;
      GENERATED_FILES=*) _SE_GENERATED_FILES="${sline#GENERATED_FILES=}" ;;
      TEST_FILES=*) _SE_TEST_FILES="${sline#TEST_FILES=}" ;;
      SPLIT_REC=*) _SE_SPLIT_REC="${sline#SPLIT_REC=}" ;;
      MAX_CONC=*) _SE_MAX_CONC="${sline#MAX_CONC=}" ;;
      UNIT_COUNT=*) _SE_UNIT_COUNT="${sline#UNIT_COUNT=}" ;;
      UNIT$'\t'*) _SE_UNITS+=("$sline") ;;
    esac
  done <<< "$raw"
}

compute_scope_paths_hash() {
  local root="$1" target_sha="$2" paths_csv="$3" ign_csv="$4"
  local -a ign_arr=() raw_p=() clean_p=()
  while IFS= read -r p; do [[ -n "$p" ]] && ign_arr+=("$p"); done < <(split_csv_lines "$ign_csv" true | LC_ALL=C sort -u)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ign_arr[@]} -gt 0 ]] && path_in_list "$p" "${ign_arr[@]}"; then continue; fi
    clean_p+=("$p")
  done < <(split_csv_lines "$paths_csv" true)
  if [[ ${#clean_p[@]} -eq 0 ]]; then
    printf 'none'
    return 0
  fi
  local sorted_csv
  sorted_csv="$(printf '%s\n' "${clean_p[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
  if [[ -z "$target_sha" ]]; then
    local fp_out h1 h2 h3
    fp_out="$(compute_tree_fingerprint "$root" "$sorted_csv" "$ign_csv")" || return 1
    { IFS= read -r h1; IFS= read -r h2; IFS= read -r h3; } <<< "$fp_out"
    printf '%s' "$h2"
    return 0
  fi
  local -a s_arr=()
  while IFS= read -r p; do [[ -n "$p" ]] && s_arr+=("$p"); done < <(printf '%s\n' "${clean_p[@]}" | LC_ALL=C sort -u)
  if ! run_git_cmd "$root" ls-tree -r "$target_sha" -- "${s_arr[@]}"; then
    echo "GIT_ERROR: git ls-tree target paths failed: $(git_err_detail)" >&2
    return 1
  fi
  local ls_sorted h_out
  ls_sorted="$(printf '%s\n' "$_GIT_STDOUT" | LC_ALL=C awk '{ sub(/\r$/, ""); if (NF > 0) print }' | LC_ALL=C sort -u)"
  if ! h_out="$(hash_git_text "$root" "PATHS=${sorted_csv}"$'\n'"${ls_sorted}"$'\n' "GIT_ERROR" "target paths failed")"; then
    printf '%s\n' "$h_out" >&2
    return 1
  fi
  printf '%s' "$h_out"
}

default_max_passes() {
  local sz_norm u="${2:-1}" scaled
  sz_norm="$(normalize_size_class "$1" 2>/dev/null || printf '%s' "$1")"
  case "$sz_norm" in
    L|XL) printf '12' ;;
    XXL)
      [[ "$u" =~ ^[0-9]+$ ]] || u=1
      u="$((10#$u))"
      [[ "$u" -lt 1 ]] && u=1
      scaled="$(( (5 * u + 1) / 2 + 2 ))"
      if [[ "$scaled" -lt 24 ]]; then scaled=24; fi
      printf '%s' "$scaled"
      ;;
    *) printf '5' ;;
  esac
}

size_rank() {
  local norm
  norm="$(normalize_size_class "${1:-}" 2>/dev/null || true)"
  case "$norm" in
    XS) echo 0 ;;
    S) echo 1 ;;
    M) echo 2 ;;
    L) echo 3 ;;
    XL) echo 4 ;;
    XXL) echo 5 ;;
    *) echo -1 ;;
  esac
}
is_waiver_attempt() {
  local rat
  rat="$(printf '%s' "$(trim_str "${1:-}")" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$rat" == waiver:* ]]
}

is_valid_high_skip_rationale() {
  local rat
  rat="$(trim_str "${1:-}")"
  [[ -n "$rat" ]] || return 1
  local low
  low="$(printf '%s' "$rat" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$low" != "none" ]] || return 1
  if is_waiver_attempt "$rat"; then return 1; fi
  [[ ${#rat} -ge 15 ]] || return 1
  printf '%s\n' "$low" | LC_ALL=C awk '
  { s = (NR == 1 ? $0 : s "\n" $0) }
  END {
    n = length(s)
    run = 1
    for (i = 2; i <= n; i++) {
      if (substr(s, i, 1) == substr(s, i - 1, 1)) {
        run++
        if (run >= 4) exit 1
      } else {
        run = 1
      }
    }
    rest = s
    cnt = 0
    while (match(rest, /[a-z][a-z][a-z]+/)) {
      w = substr(rest, RSTART, RLENGTH)
      if (!(w in seen)) { seen[w] = 1; cnt++ }
      rest = substr(rest, RSTART + RLENGTH)
    }
    exit (cnt >= 2 ? 0 : 1)
  }'
}

run_review_ledger_check_sub() {
  local _rc_root="$1"
  local _rc_full="$2"
  local _rc_rel="$3"
  local _rc_ign="$4"
  local _rc_emit_meta="${5:-false}"
  (
    _CLEANUP_FILES=()
    trap _cleanup_tmp EXIT
    make_temp_file "b3-git-err-sub" _B3_GIT_ERR_FILE
    [[ -f "$_rc_full" ]] || { echo "LEDGER_MISSING: $_rc_rel"; exit 1; }

    L_SCHEMA=""; L_BASE=""; L_HEAD=""; L_TREF=""; L_TSHA=""; L_SNAP=""; L_SIZE=""; L_NLSIZE=""; L_RISK=""; L_RSIG=""; L_RSPEC=""
    L_L1SPEC=""; L_L1SKIP=""; L_PCHAIN=""; L_HAS_CHAIN="false"; L_RIND=""
    L_CFILES=""; L_GFILES=""; L_MCONC=""; L_MPASS=""; L_PUSED=""; L_BSTAT=""; L_CSTAT=""; L_CHASH=""; L_UCNT=""
    L_SEEN_KEYS=""
    U_ROWS=()
    P_ROWS=()
    while IFS= read -r rawln || [[ -n "$rawln" ]]; do
      ln="$(trim_str "${rawln%$'\r'}")"
      [[ -z "$ln" || "$ln" == \#* ]] && continue
      if [[ "$ln" == \|* ]]; then
        inner="${ln#|}"; inner="${inner%|}"
        c_cnt=0; c0=""; c1=""; c2=""; c3=""; c4=""; c5=""; c6=""; c7=""; c8=""; c9=""; c10=""; c11=""
        while IFS= read -r col; do
          tc="$(trim_str "$col")"
          case "$c_cnt" in
            0) c0="$tc" ;; 1) c1="$tc" ;; 2) c2="$tc" ;; 3) c3="$tc" ;; 4) c4="$tc" ;; 5) c5="$tc" ;;
            6) c6="$tc" ;; 7) c7="$tc" ;; 8) c8="$tc" ;; 9) c9="$tc" ;; 10) c10="$tc" ;; 11) c11="$tc" ;;
          esac
          c_cnt=$((c_cnt + 1))
        done < <(printf '%s\n' "$inner" | LC_ALL=C awk -F'|' '{for(i=1;i<=NF;i++) print $i}')
        [[ "$c_cnt" -eq 12 ]] || { echo "LEDGER_CORRUPT: malformed unit row column count"; exit 1; }
        [[ "$c0" == "unit_id" || "$c0" == "---" ]] && continue
        [[ "$c0" =~ ^U[0-9]{2,}$ ]] || { echo "LEDGER_CORRUPT: invalid unit_id '$c0'"; exit 1; }
        [[ "$c2" =~ ^[0-9]+$ && "$c3" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: invalid unit row numeric field"; exit 1; }
        U_ROWS+=("${c0}|${c1}|${c2}|${c3}|${c4}|${c5}|${c6}|${c7}|${c8}|${c9}|${c10}|${c11}")
        continue
      fi
      if [[ "$ln" == pass\|* ]]; then
        _re_pass='^pass\|[0-9]+\|[^|]+\|[^|]+\|[0-9]+\|([0-9a-f]{40}|none)\|[0-9a-f]{40}$'
        [[ "$ln" =~ $_re_pass ]] || { printf "LEDGER_CORRUPT: malformed pass log entry '%s'\n" "$ln"; exit 1; }
        P_ROWS+=("$ln")
        continue
      fi
      [[ "$ln" == *"="* ]] || { echo "LEDGER_CORRUPT: unexpected line '$ln'"; exit 1; }
      lk="$(trim_str "${ln%%=*}")"; lv="$(trim_str "${ln#*=}")"
      case "$L_SEEN_KEYS" in *"|${lk}|"*) echo "LEDGER_CORRUPT: duplicate key '$lk'"; exit 1 ;; esac
      L_SEEN_KEYS+="|${lk}|"
      case "$lk" in
        schema) L_SCHEMA="$lv" ;; base_sha) L_BASE="$lv" ;; head_sha) L_HEAD="$lv" ;; target_ref) L_TREF="$lv" ;;
        target_sha) L_TSHA="$lv" ;; snapshot_sha) L_SNAP="$lv" ;; size_class) L_SIZE="$lv" ;; normalized_legacy_size) L_NLSIZE="$lv" ;;
        risk_level) L_RISK="$lv" ;; risk_signals) L_RSIG="$lv" ;; recommended_specialists) L_RSPEC="$lv" ;;
        l1_specialists) L_L1SPEC="$lv" ;; l1_skip_rationale) L_L1SKIP="$lv" ;; pass_chain) L_PCHAIN="$lv"; L_HAS_CHAIN="true" ;;
        review_independence) L_RIND="$lv" ;;
        contract_files) L_CFILES="$lv" ;; generated_files) L_GFILES="$lv" ;; max_concurrency) L_MCONC="$lv" ;;
        max_passes) L_MPASS="$lv" ;; passes_used) L_PUSED="$lv" ;; budget_status) L_BSTAT="$lv" ;;
        cross_unit_status) L_CSTAT="$lv" ;; cross_unit_tree_hash) L_CHASH="$lv" ;; unit_count) L_UCNT="$lv" ;;
      esac
    done < "$_rc_full"

    for rv in "$L_SCHEMA" "$L_BASE" "$L_HEAD" "$L_TREF" "$L_SNAP" "$L_SIZE" "$L_NLSIZE" "$L_RISK" "$L_RSIG" "$L_RSPEC" "$L_CFILES" "$L_GFILES" "$L_MCONC" "$L_MPASS" "$L_PUSED" "$L_BSTAT" "$L_CSTAT" "$L_CHASH" "$L_UCNT"; do
      [[ -n "$rv" ]] || { echo "LEDGER_CORRUPT: missing required ledger key"; exit 1; }
    done
    [[ "$L_SCHEMA" == "b3-review-ledger-v1" ]] || { echo "LEDGER_CORRUPT: unsupported schema '$L_SCHEMA'"; exit 1; }
    [[ "$L_BASE" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid base_sha"; exit 1; }
    [[ "$L_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid head_sha"; exit 1; }
    if [[ -z "$L_TSHA" ]]; then
      if [[ "$L_TREF" == "working_tree" ]]; then
        L_TSHA="none"
      elif [[ "$L_TREF" =~ ^[0-9a-f]{40}$ ]]; then
        L_TSHA="$L_TREF"
      else
        echo "LEDGER_CORRUPT: missing target_sha for symbolic target_ref"; exit 1
      fi
    fi
    if [[ "$L_TREF" == "working_tree" ]]; then
      [[ "$L_TSHA" == "none" ]] || { echo "LEDGER_CORRUPT: invalid target_sha"; exit 1; }
    else
      [[ "$L_TSHA" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid target_sha"; exit 1; }
    fi
    [[ "$L_MPASS" =~ ^[0-9]+$ && "$L_PUSED" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: invalid pass counter"; exit 1; }
    L_MPASS="$((10#$L_MPASS))"
    L_PUSED="$((10#$L_PUSED))"
    if [[ "$L_HAS_CHAIN" != "true" || -z "$L_PCHAIN" ]]; then
      echo "LEDGER_CORRUPT: missing pass_chain"
      exit 1
    fi
    [[ "$L_PCHAIN" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid pass_chain"; exit 1; }
    if [[ -z "$L_RIND" ]]; then
      echo "LEDGER_CORRUPT: missing review_independence"
      exit 1
    fi
    if [[ "$L_RIND" != "UNKNOWN" && "$L_RIND" != "INDEPENDENT" && "$L_RIND" != "SINGLE_AGENT_LIMIT" ]]; then
      echo "LEDGER_CORRUPT: invalid review_independence '$L_RIND'"
      exit 1
    fi
    [[ -z "$L_L1SPEC" ]] && L_L1SPEC="none"
    [[ -z "$L_L1SKIP" ]] && L_L1SKIP="none"
    ORIG_RAW_SIZE="$L_SIZE"
    NORM_SIZE="$(normalize_size_class "$ORIG_RAW_SIZE")" || { echo "LEDGER_CORRUPT: invalid size_class '$ORIG_RAW_SIZE'"; exit 1; }
    [[ "$L_UCNT" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: unit_count mismatch"; exit 1; }
    L_UCNT="$((10#$L_UCNT))"
    [[ "$L_UCNT" -eq ${#U_ROWS[@]} ]] || { echo "LEDGER_CORRUPT: unit_count mismatch"; exit 1; }
    L_SIZE="$NORM_SIZE"
    TARGET_COMMIT_SHA=""
    [[ "$L_TREF" != "working_tree" ]] && TARGET_COMMIT_SHA="$L_TSHA"

    # Verify pass chain
    cur="$(init_pass_chain "$_rc_root" "$L_BASE")" || exit 1
    sum=0; idx=0
    if [[ ${#P_ROWS[@]} -gt 0 ]]; then
      for row in "${P_ROWS[@]}"; do
        IFS='|' read -r _pt p_seq p_scope p_kind p_delta p_ref p_hash <<< "$row"
        p_seq="$((10#$p_seq))"
        p_delta="$((10#$p_delta))"
        expect_seq=$((idx + 1))
        if [[ "$p_seq" -ne "$expect_seq" || "$p_delta" -lt 1 ]]; then
          printf 'LEDGER_CORRUPT: passes_used tamper detected (invalid sequence or delta at index %s)\n' "$expect_seq"
          exit 1
        fi
        sum=$((sum + p_delta))
        cur="$(step_pass_chain "$_rc_root" "$cur" "$p_seq" "$p_scope" "$p_kind" "$p_delta" "$p_ref")" || exit 1
        if [[ "$cur" != "$p_hash" ]]; then
          printf 'LEDGER_CORRUPT: passes_used tamper detected (chain hash mismatch at seq %s)\n' "$p_seq"
          exit 1
        fi
        idx=$((idx + 1))
      done
    fi
    if [[ "$sum" -ne "$L_PUSED" || "$cur" != "$L_PCHAIN" ]]; then
      printf 'LEDGER_CORRUPT: passes_used tamper detected (passes=%s log_sum=%s)\n' "$L_PUSED" "$sum"
      exit 1
    fi

    if [[ "$L_MPASS" -le 0 ]]; then
      printf 'LEDGER_INCOMPLETE: unbounded or invalid max_passes (%s)\n' "$L_MPASS"
      exit 2
    fi
    if [[ "$L_BSTAT" == "EXHAUSTED" || "$L_PUSED" -gt "$L_MPASS" ]]; then
      printf 'LEDGER_INCOMPLETE: budget exhausted (passes=%s/%s)\n' "$L_PUSED" "$L_MPASS"
      exit 2
    fi
    REV_CNT_CHK=0
    if [[ ${#U_ROWS[@]} -gt 0 ]]; then
      for ur in "${U_ROWS[@]}"; do
        IFS='|' read -r _0 _1 _2 _3 _4 _5 _6 ust_chk _rest <<< "$ur"
        [[ "$ust_chk" == "REVIEWED" ]] && REV_CNT_CHK=$((REV_CNT_CHK + 1))
      done
    fi
    MIN_REQ_PASSES="$REV_CNT_CHK"
    [[ "$L_CSTAT" == "REVIEWED" ]] && MIN_REQ_PASSES=$((MIN_REQ_PASSES + 1))
    if [[ "$L_PUSED" -lt "$MIN_REQ_PASSES" ]]; then
      printf 'LEDGER_INCOMPLETE: passes_used (%s) below minimum reviewed passes (%s)\n' "$L_PUSED" "$MIN_REQ_PASSES"
      exit 2
    fi
    if [[ ( "$L_SIZE" == "L" || "$L_SIZE" == "XL" ) && "$L_UCNT" -gt 4 ]]; then
      printf 'LEDGER_INCOMPLETE: %s PR exceeds max 4 units (%s)\n' "$L_SIZE" "$L_UCNT"
      exit 2
    fi
    if [[ ${#U_ROWS[@]} -gt 0 ]]; then
      for ur in "${U_ROWS[@]}"; do
        IFS='|' read -r uid_b _gb ufc_b ulc_b _rest <<< "$ur"
        ufc_b="$((10#$ufc_b))"
        ulc_b="$((10#$ulc_b))"
        if [[ "$ulc_b" -gt 5000 || ( "$ufc_b" -gt 100 && "$ulc_b" -gt 1000 ) ]]; then
          printf 'LEDGER_INCOMPLETE: oversized unit %s (%sf, %sL)\n' "$uid_b" "$ufc_b" "$ulc_b"
          exit 2
        fi
      done
    fi
    if [[ "$L_TREF" != "working_tree" ]]; then
      if ! run_git_cmd_quiet "$_rc_root" rev-parse --verify --quiet "${L_TREF}^{commit}"; then
        printf "LEDGER_STALE: target_ref '%s' cannot be resolved\n" "$L_TREF"
        exit 2
      fi
      _CHK_TR_SHA="$(trim_str "$_GIT_STDOUT")"
      if [[ ! "$_CHK_TR_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        printf "LEDGER_STALE: target_ref '%s' cannot be resolved\n" "$L_TREF"
        exit 2
      fi
      if [[ "$_CHK_TR_SHA" != "$L_TSHA" ]]; then
        printf "LEDGER_STALE: target_ref '%s' moved (%s->%s)\n" "$L_TREF" "$L_TSHA" "$_CHK_TR_SHA"
        exit 2
      fi
      if [[ "$L_HEAD" != "$_CHK_TR_SHA" ]]; then
        printf "LEDGER_STALE: head_sha moved (%s->%s)\n" "$L_HEAD" "$_CHK_TR_SHA"
        exit 2
      fi
    else
      if ! run_git_cmd_quiet "$_rc_root" rev-parse --verify --quiet "HEAD^{commit}"; then
        echo "LEDGER_STALE: HEAD cannot be resolved"
        exit 2
      fi
      _CHK_HD_SHA="$(trim_str "$_GIT_STDOUT")"
      if [[ ! "$_CHK_HD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "LEDGER_STALE: HEAD cannot be resolved"
        exit 2
      fi
      if [[ "$_CHK_HD_SHA" != "$L_HEAD" ]]; then
        printf "LEDGER_STALE: head_sha moved (%s->%s)\n" "$L_HEAD" "$_CHK_HD_SHA"
        exit 2
      fi
    fi

    make_temp_file "b3-fsig" FSIG_TMP
    make_temp_file "b3-fln" FLINES_TMP
    : > "$FSIG_TMP"; : > "$FLINES_TMP"

    LIVE_OUT=""
    if ! LIVE_OUT="$(run_scope_engine "$_rc_root" "$L_BASE" "$TARGET_COMMIT_SHA" "$_rc_ign" "$L_MCONC" "LEDGER_FAIL" "$FSIG_TMP" "$FLINES_TMP" "false")"; then
      printf '%s\n' "$LIVE_OUT"
      exit 1
    fi
    parse_scope_engine_output "$LIVE_OUT"
    LIVE_EMPTY="$_SE_IS_EMPTY"; LIVE_SIZE="$_SE_SIZE_CLASS"; LIVE_RISK="$_SE_RISK_LEVEL"
    LIVE_RF="$_SE_REVIEW_FILES"; LIVE_CF="$_SE_CONTRACT_FILES"
    if [[ "$LIVE_EMPTY" == "true" ]]; then
      echo "LEDGER_INCOMPLETE: empty diff target"
      exit 2
    fi

    LIVE_RANK="$(size_rank "$LIVE_SIZE")"
    LED_RANK="$(size_rank "$L_SIZE")"
    if [[ "$LIVE_RANK" -gt "$LED_RANK" ]]; then
      printf 'LEDGER_STALE: size_class escalated (%s->%s)\n' "$L_SIZE" "$LIVE_SIZE"
      exit 2
    fi

    if [[ "$L_RIND" == "SINGLE_AGENT_LIMIT" && ( "$LIVE_RISK" == "HIGH" || "$LIVE_RISK" == "CRITICAL" ) ]]; then
      echo "LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk"
      exit 2
    fi
    if [[ "$L_RIND" == "UNKNOWN" && ( "$LIVE_RISK" == "HIGH" || "$LIVE_RISK" == "CRITICAL" ) ]]; then
      echo "LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk"
      exit 2
    fi

    if [[ "$LIVE_RF" != "none" ]]; then
      ASS_CSV=""
      if [[ ${#U_ROWS[@]} -gt 0 ]]; then
        for ur in "${U_ROWS[@]}"; do
          IFS='|' read -r _0 _1 _2 _3 _4 _5 _6 _7 _8 _9 _10 fcsv <<< "$ur"
          ASS_CSV+=",${fcsv}"
        done
      fi
      UNCOV="$(LC_ALL=C awk -v lrf="$LIVE_RF" -v acsv="$ASS_CSV" '
      BEGIN {
        n1 = split(acsv, a, ",")
        for (i = 1; i <= n1; i++) if (a[i] != "") seen[a[i]] = 1
        n2 = split(lrf, b, ",")
        nu = 0
        for (i = 1; i <= n2; i++) if (b[i] != "" && !(b[i] in seen)) u[++nu] = b[i]
        if (nu > 0) {
          for (i = 2; i <= nu; i++) { t = u[i]; j = i - 1; while (j >= 1 && u[j] > t) { u[j + 1] = u[j]; j-- } u[j + 1] = t }
          out = u[1]; for (i = 2; i <= nu; i++) out = out "," u[i]
          print out
        }
      }')"
      if [[ -n "$UNCOV" ]]; then
        printf 'LEDGER_INCOMPLETE: uncovered files (%s)\n' "$UNCOV"
        exit 2
      fi
    fi

    if [[ ${#U_ROWS[@]} -gt 0 ]]; then
      for ur in "${U_ROWS[@]}"; do
      IFS='|' read -r uid grp ufc ulc urisk uspec urat ust ufind urec uhash ufcsv <<< "$ur"
      [[ "$ust" == "BLOCKED" ]] && { printf 'LEDGER_BLOCKED: unit %s\n' "$uid"; exit 2; }
      [[ "$ust" == "STALE" ]] && { printf 'LEDGER_STALE: unit %s\n' "$uid"; exit 2; }
      [[ "$ust" == "REVIEWED" ]] || { printf 'LEDGER_INCOMPLETE: unit %s status=%s\n' "$uid" "$ust"; exit 2; }
      if LC_ALL=C awk -v f="$ufind" 'BEGIN { exit !(f ~ /(^|[^A-Za-z0-9_])(OPEN|FIXED|CONFIRMED|NEW|INVESTIGATING)([^A-Za-z0-9_]|$)/) }'; then
        printf 'LEDGER_INCOMPLETE: unresolved findings in %s (%s)\n' "$uid" "$ufind"
        exit 2
      fi

      LU_RISK="$(eval_risk_for_csv_awk "$ufcsv" "$FSIG_TMP" "$FLINES_TMP")"
      { IFS= read -r LU_LVL; IFS= read -r LU_SIG; IFS= read -r LU_SP; } <<< "$LU_RISK"
      if [[ "$L_RIND" == "SINGLE_AGENT_LIMIT" && ( "$LU_LVL" == "HIGH" || "$LU_LVL" == "CRITICAL" ) ]]; then
        echo "LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk"
        exit 2
      fi
      if [[ "$L_RIND" == "UNKNOWN" && ( "$LU_LVL" == "HIGH" || "$LU_LVL" == "CRITICAL" ) ]]; then
        echo "LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk"
        exit 2
      fi
      if [[ "$LU_LVL" != "$urisk" ]]; then
        printf 'LEDGER_STALE: unit %s risk changed (%s->%s)\n' "$uid" "$urisk" "$LU_LVL"
        exit 2
      fi
      if [[ "$LU_SP" != "none" ]]; then
        MISS_SP="$(LC_ALL=C awk -v req="$LU_SP" -v got="$uspec" '
        BEGIN {
          n1 = split(got, a, ","); for (i = 1; i <= n1; i++) if (a[i] != "" && a[i] != "none") g[a[i]] = 1
          n2 = split(req, b, ","); nm = 0
          for (i = 1; i <= n2; i++) if (b[i] != "" && !(b[i] in g)) m[++nm] = b[i]
          if (nm > 0) { out = m[1]; for (i = 2; i <= nm; i++) out = out "," m[i]; print out }
        }')"
        if [[ -n "$MISS_SP" ]]; then
          if [[ "$LU_LVL" == "CRITICAL" ]]; then
            if is_waiver_attempt "$urat"; then
              printf 'LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected on %s (missing %s; self-declared waivers are disabled without trusted owner approval)\n' "$uid" "$MISS_SP"
              exit 2
            fi
            printf 'LEDGER_INCOMPLETE: mandatory CRITICAL specialist (%s) required on %s (waivers disabled without trusted owner approval)\n' "$MISS_SP" "$uid"
            exit 2
          elif [[ "$LU_LVL" == "HIGH" ]]; then
            if ! is_valid_high_skip_rationale "$urat"; then
              printf 'LEDGER_INCOMPLETE: missing specialist (%s) or valid HIGH skip rationale on %s\n' "$MISS_SP" "$uid"
              exit 2
            fi
          else
            rat_t="$(trim_str "$urat")"
            if [[ "$rat_t" == "none" || ${#rat_t} -lt 5 ]] || is_waiver_attempt "$rat_t"; then
              printf 'LEDGER_INCOMPLETE: missing specialist (%s) or rationale on %s\n' "$MISS_SP" "$uid"
              exit 2
            fi
          fi
        fi
      fi

      COMB_U="$ufcsv"
      [[ "$LIVE_CF" != "none" ]] && COMB_U="${ufcsv},${LIVE_CF}"
      CUR_UHASH="$(compute_scope_paths_hash "$_rc_root" "$TARGET_COMMIT_SHA" "$COMB_U" "$_rc_ign")" || exit 1
      if [[ "$CUR_UHASH" != "$uhash" ]]; then
        printf 'LEDGER_STALE: unit %s invalidated (files or shared contracts changed)\n' "$uid"
        exit 2
      fi

      IFS=$'\t' read -r LIVE_UFC LIVE_ULC < <(unit_counts_from_flines_awk "$ufcsv" "$FLINES_TMP")
      if [[ "$LIVE_ULC" -gt 5000 || ( "$LIVE_UFC" -gt 100 && "$LIVE_ULC" -gt 1000 ) ]]; then
        printf 'LEDGER_INCOMPLETE: oversized unit %s (%sf, %sL)\n' "$uid" "$LIVE_UFC" "$LIVE_ULC"
        exit 2
      fi

      HAS_CODE="$(LC_ALL=C awk -v c="$ufcsv" "$_B3_RISK_AWK_LIB"'BEGIN{n=split(c,a,",");hc=0;for(i=1;i<=n;i++){if(a[i]!="" && !(is_doc_asset(a[i])||is_test_p(a[i]))){hc=1;break}}print hc}')"
      if [[ "$urec" == "none" ]]; then
        if [[ "$HAS_CODE" == "1" && ( "$urisk" == "HIGH" || "$urisk" == "CRITICAL" ) ]]; then
          printf 'LEDGER_INCOMPLETE: missing verify_receipt for %s unit %s\n' "$urisk" "$uid"
          exit 2
        fi
      else
        if run_verify_check "$_rc_root" "$urec" "$_rc_ign" "" "$ufcsv" "$TARGET_COMMIT_SHA"; then
          :
        else
          vrc=$?
          if [[ $vrc -eq 2 ]]; then
            printf 'LEDGER_STALE: unit %s receipt invalid (%s)\n' "$uid" "$_VR_MSG"
          else
            printf 'LEDGER_INCOMPLETE: unit %s receipt invalid (%s)\n' "$uid" "$_VR_MSG"
          fi
          exit 2
        fi
      fi
    done
    fi

    if [[ ( "$L_SIZE" == "L" || "$L_SIZE" == "XL" || "$L_SIZE" == "XXL" ) && "$L_UCNT" -gt 1 ]]; then
      [[ "$L_CSTAT" == "BLOCKED" ]] && { echo "LEDGER_BLOCKED: cross_unit blocked"; exit 2; }
      [[ "$L_CSTAT" == "STALE" ]] && { echo "LEDGER_STALE: cross_unit stale"; exit 2; }
      [[ "$L_CSTAT" == "REVIEWED" ]] || { printf 'LEDGER_INCOMPLETE: cross_unit_status=%s\n' "$L_CSTAT"; exit 2; }
      CU_PATHS="$LIVE_CF"
      [[ "$CU_PATHS" == "none" ]] && CU_PATHS="$LIVE_RF"
      CUR_CU_HASH="$(compute_scope_paths_hash "$_rc_root" "$TARGET_COMMIT_SHA" "$CU_PATHS" "$_rc_ign")" || exit 1
      if [[ "$CUR_CU_HASH" != "$L_CHASH" ]]; then
        echo "LEDGER_STALE: cross_unit invalidated"
        exit 2
      fi
    fi

    rm -f "$FSIG_TMP" "$FLINES_TMP" 2>/dev/null || true
    NORM_TAG=""
    [[ "$ORIG_RAW_SIZE" != "$L_SIZE" ]] && NORM_TAG=" normalized_from=${ORIG_RAW_SIZE}"
    printf 'LEDGER_GATE_PASS: size=%s risk=%s units=%s/%s cross_unit=%s review_independence=%s%s\n' "$L_SIZE" "$L_RISK" "$L_UCNT" "$L_UCNT" "$L_CSTAT" "$L_RIND" "$NORM_TAG"
    if [[ "$_rc_emit_meta" == "true" ]]; then
      printf 'META_BASE_SHA=%s\n' "$L_BASE"
      printf 'META_HEAD_SHA=%s\n' "$L_HEAD"
      printf 'META_TARGET_REF=%s\n' "$L_TREF"
      printf 'META_TARGET_SHA=%s\n' "$L_TSHA"
      printf 'META_REVIEW_INDEPENDENCE=%s\n' "$L_RIND"
      if [[ ${#U_ROWS[@]} -gt 0 ]]; then
        for ur in "${U_ROWS[@]}"; do
          IFS='|' read -r u_id _1 _2 _3 _4 _5 _6 _7 _8 u_rec _10 _11 <<< "$ur"
          printf 'META_UNIT_RECEIPT=%s|%s\n' "$u_id" "$u_rec"
        done
      fi
    fi
    exit 0
  )
}

unit_counts_from_flines_awk() {
  local paths_csv="$1" flines_file="$2"
  LC_ALL=C awk -v paths_csv="$paths_csv" -v flines_f="$flines_file" "$_B3_RISK_AWK_LIB"'
  BEGIN {
    split("", flines); split("", seen); split("", ign); n_ign = 0
    if (flines_f != "") {
      while ((getline ln < flines_f) > 0) {
        sub(/\r$/, "", ln); t = index(ln, "\t")
        if (t > 1) flines[substr(ln, 1, t - 1)] = substr(ln, t + 1) + 0
      }
      close(flines_f)
    }
    np = split(paths_csv, raw_p, ","); cnt = 0; lines = 0
    for (i = 1; i <= np; i++) {
      p = norm_p(raw_p[i])
      if (p != "" && p != "none" && !(p in seen)) {
        seen[p] = 1; cnt++
        if (p in flines) lines += flines[p]
      }
    }
    printf "%d\t%d\n", cnt, lines
  }'
}

init_pass_chain() {
  local root="$1" base_sha="$2"
  hash_git_text "$root" "b3-pass-v1|init|${base_sha}|0"$'\n' "LEDGER_FAIL"
}

step_pass_chain() {
  local root="$1" prev="$2" seq="$3" scope_id="$4" kind="$5" delta="$6" ref_sha="$7"
  hash_git_text "$root" "b3-pass-v1|step|${prev}|${seq}|${scope_id}|${kind}|${delta}|${ref_sha}"$'\n' "LEDGER_FAIL"
}

_LEDGER_TXT=""
serialize_review_ledger() {
  local ur pr r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11
  _LEDGER_TXT="# B3 Review Coverage Ledger"$'\n'
  _LEDGER_TXT+="schema=b3-review-ledger-v1"$'\n'
  _LEDGER_TXT+="base_sha=${L_BASE}"$'\n'
  _LEDGER_TXT+="head_sha=${L_HEAD}"$'\n'
  _LEDGER_TXT+="target_ref=${L_TREF}"$'\n'
  _LEDGER_TXT+="target_sha=${L_TSHA}"$'\n'
  _LEDGER_TXT+="snapshot_sha=${L_SNAP}"$'\n'
  _LEDGER_TXT+="size_class=${L_SIZE}"$'\n'
  _LEDGER_TXT+="normalized_legacy_size=${L_NLSIZE}"$'\n'
  _LEDGER_TXT+="risk_level=${L_RISK}"$'\n'
  _LEDGER_TXT+="risk_signals=${L_RSIG}"$'\n'
  _LEDGER_TXT+="recommended_specialists=${L_RSPEC}"$'\n'
  _LEDGER_TXT+="l1_specialists=${L_L1SPEC}"$'\n'
  _LEDGER_TXT+="l1_skip_rationale=${L_L1SKIP}"$'\n'
  _LEDGER_TXT+="contract_files=${L_CFILES}"$'\n'
  _LEDGER_TXT+="generated_files=${L_GFILES}"$'\n'
  _LEDGER_TXT+="max_concurrency=${L_MCONC}"$'\n'
  _LEDGER_TXT+="max_passes=${L_MPASS}"$'\n'
  _LEDGER_TXT+="passes_used=${L_PUSED}"$'\n'
  _LEDGER_TXT+="pass_chain=${L_PCHAIN}"$'\n'
  _LEDGER_TXT+="budget_status=${L_BSTAT}"$'\n'
  _LEDGER_TXT+="review_independence=${L_RIND}"$'\n'
  _LEDGER_TXT+="cross_unit_status=${L_CSTAT}"$'\n'
  _LEDGER_TXT+="cross_unit_tree_hash=${L_CHASH}"$'\n'
  _LEDGER_TXT+="unit_count=${L_UCNT}"$'\n\n## Units\n| unit_id | group | files_cnt | lines_cnt | risk | specialists | rationale | status | findings | verify_receipt | unit_tree_hash | files_csv |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
  if [[ ${#U_ROWS[@]} -gt 0 ]]; then
    for ur in "${U_ROWS[@]}"; do
      IFS='|' read -r r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 <<< "$ur"
      _LEDGER_TXT+="| ${r0} | ${r1} | ${r2} | ${r3} | ${r4} | ${r5} | ${r6} | ${r7} | ${r8} | ${r9} | ${r10} | ${r11} |"$'\n'
    done
  fi
  _LEDGER_TXT+=$'\n## Pass Log\n'
  if [[ ${#P_ROWS[@]} -gt 0 ]]; then
    for pr in "${P_ROWS[@]}"; do
      _LEDGER_TXT+="${pr}"$'\n'
    done
  fi
}

has_control_chars() {
  local s="$1"
  has_ascii_cntrl "$s"
}

join_csv() {
  local IFS=','
  printf '%s' "$*"
}

is_valid_context_scope_id() {
  local LC_ALL=C
  local s="$1"
  [[ -n "$s" && ${#s} -ge 1 && ${#s} -le 80 ]] || return 1
  [[ "$s" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  if [[ "$s" == "." || "$s" == /* || "$s" == */ || "$s" == *"//"* ]]; then
    return 1
  fi
  local re_dotdot='(^|/)\.\.(/|$)' re_dot='(^|/)\.(/|$)'
  if [[ "$s" =~ $re_dotdot || "$s" =~ $re_dot ]]; then
    return 1
  fi
  return 0
}

_CP_REL=""
_CP_FULL=""
check_checkpoint_file_path() {
  local LC_ALL=C
  local root="$1" raw="$2"
  _CP_REL=""
  _CP_FULL=""
  [[ -n "$raw" ]] || return 2
  if has_ascii_cntrl "$raw"; then return 2; fi
  if [[ "$raw" == *" " ]]; then return 2; fi
  local trimmed
  trimmed="$(trim_str "$raw")"
  [[ -n "$trimmed" ]] || return 2
  if [[ "$trimmed" == *:* ]]; then return 2; fi
  local raw_slash="${trimmed//\\//}"
  if [[ -z "$raw_slash" || "$raw_slash" == */ ]]; then return 2; fi
  local p
  p="$(norm_path "$trimmed")"
  local re_dotdot='(^|/)\.\.(/|$)' re_dot='(^|/)\.(/|$)' re_cp='^\.b3/(ship|research-ship)/.+$'
  if [[ -z "$p" || "$p" == "." || "$p" == /* || "$p" == ~* || "$p" == *:* || "$p" == *"//"* || "$p" =~ $re_dotdot || "$p" =~ $re_dot ]]; then
    return 2
  fi
  local check_rem="$p" check_seg
  while true; do
    if [[ "$check_rem" == */* ]]; then
      check_seg="${check_rem%%/*}"
      check_rem="${check_rem#*/}"
    else
      check_seg="$check_rem"
      check_rem=""
    fi
    if [[ -z "$check_seg" || "$check_seg" == *. || "$check_seg" == *" " ]]; then
      return 2
    fi
    [[ -n "$check_rem" ]] || break
  done
  if [[ ! "$p" =~ $re_cp ]]; then
    return 2
  fi
  if is_secret_path "$p"; then
    return 2
  fi
  if ! check_contained_repo_path "$root" "$p"; then
    _CP_REL="$p"
    return 3
  fi
  if [[ -d "$_CONTAINED_FULL" || -L "$_CONTAINED_FULL" ]]; then
    _CP_REL="$_CONTAINED_REL"
    _CP_FULL="$_CONTAINED_FULL"
    return 3
  fi
  _CP_REL="$_CONTAINED_REL"
  _CP_FULL="$_CONTAINED_FULL"
  return 0
}

_CTX_PATHS=()
_CTX_BAD_TOKEN=""
_IGN_PATHS=()
split_strict_paths() {
  local LC_ALL=C
  local root="$1" csv="$2" allow_empty="${3:-true}" block_b3_and_secrets="${4:-true}"
  _CTX_PATHS=()
  _CTX_BAD_TOKEN=""
  if [[ -z "$csv" ]]; then
    if [[ "$allow_empty" == "true" ]]; then return 0; fi
    _CTX_BAD_TOKEN="<empty>"
    return 1
  fi
  if has_ascii_cntrl "$csv"; then
    _CTX_BAD_TOKEN="$csv"
    return 1
  fi
  local cleaned
  cleaned="$(trim_str "$csv")"
  if [[ "$allow_empty" == "true" && ( -z "$cleaned" || "$csv" == "none" || "$csv" == "[]" ) ]]; then
    return 0
  fi
  if [[ -z "$cleaned" ]]; then
    _CTX_BAD_TOKEN="<empty>"
    return 1
  fi
  local had_noglob=false
  [[ "$-" == *f* ]] && had_noglob=true
  set -f
  local -a raw_parts=()
  IFS=',' read -r -a raw_parts <<< "$csv" || true
  if ! $had_noglob; then set +f; fi
  if [[ "$csv" == *, ]]; then
    raw_parts+=("")
  fi

  local -a collected=()
  local raw_p tok rel rel_low
  local re_dot='(^|/)\.(/|$)' re_git_any='(^|/)\.git(/|$)' re_b3_root='^\.b3(/|$)'
  for raw_p in "${raw_parts[@]}"; do
    tok="${raw_p#"${raw_p%%[! ]*}"}"
    if [[ -z "$tok" ]]; then
      _CTX_BAD_TOKEN="<empty>"
      return 1
    fi
    if [[ "$tok" == "none" || "$tok" == -* || "$tok" == *:* || "$tok" == *'*'* || "$tok" == *'?'* || "$tok" == *'['* || "$tok" == *']'* ]]; then
      _CTX_BAD_TOKEN="$tok"
      return 1
    fi
    if ! check_contained_repo_path "$root" "$tok"; then
      _CTX_BAD_TOKEN="$tok"
      return 1
    fi
    rel="$_CONTAINED_REL"
    rel_low="$(printf '%s' "$rel" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ -z "$rel" || "$rel" == "." || "$rel" == -* || "$rel" == *"//"* || "$rel" =~ $re_dot || "$rel_low" =~ $re_git_any ]]; then
      _CTX_BAD_TOKEN="$tok"
      return 1
    fi
    if [[ "$block_b3_and_secrets" == "true" ]]; then
      if [[ "$rel_low" =~ $re_b3_root ]] || is_secret_path "$rel"; then
        _CTX_BAD_TOKEN="$tok"
        return 1
      fi
    fi
    collected+=("$rel")
  done
  if [[ ${#collected[@]} -eq 0 ]]; then
    if [[ "$allow_empty" == "true" ]]; then return 0; fi
    _CTX_BAD_TOKEN="<empty>"
    return 1
  fi
  local sorted_item
  while IFS= read -r sorted_item; do
    [[ -n "$sorted_item" ]] && _CTX_PATHS+=("$sorted_item")
  done < <(printf '%s\n' "${collected[@]}" | LC_ALL=C sort -u)
  return 0
}

ignore_overlaps_paths() {
  [[ ${#_IGN_PATHS[@]} -gt 0 && $# -gt 0 ]] || return 1
  local p ign
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    for ign in "${_IGN_PATHS[@]}"; do
      [[ -n "$ign" ]] || continue
      if [[ "$p" == "$ign" || "$p" == "$ign/"* || "$ign" == "$p/"* ]]; then
        return 0
      fi
    done
  done
  return 1
}

validate_strict_utf8_file() {
  local f="$1"
  od -An -v -tx1 "$f" | LC_ALL=C awk '
    BEGIN {
      for (i = 0; i < 16; i++) {
        h = substr("0123456789abcdef", i + 1, 1)
        hx[h] = i
        hx[toupper(h)] = i
      }
      need = 0; lo = 128; hi = 191; bad = 0
    }
    {
      for (i = 1; i <= NF; i++) {
        s = $i
        if (length(s) != 2) { bad = 1; exit 1 }
        c1 = substr(s, 1, 1); c2 = substr(s, 2, 1)
        if (!(c1 in hx) || !(c2 in hx)) { bad = 1; exit 1 }
        b = hx[c1] * 16 + hx[c2]
        if (need > 0) {
          if (b < lo || b > hi) { bad = 1; exit 1 }
          need--
          lo = 128; hi = 191
        } else if (b <= 127) {
          continue
        } else if (b >= 194 && b <= 223) {
          need = 1; lo = 128; hi = 191
        } else if (b == 224) {
          need = 2; lo = 160; hi = 191
        } else if ((b >= 225 && b <= 236) || b == 238 || b == 239) {
          need = 2; lo = 128; hi = 191
        } else if (b == 237) {
          need = 2; lo = 128; hi = 159
        } else if (b == 240) {
          need = 3; lo = 144; hi = 191
        } else if (b >= 241 && b <= 243) {
          need = 3; lo = 128; hi = 191
        } else if (b == 244) {
          need = 3; lo = 128; hi = 143
        } else {
          bad = 1; exit 1
        }
      }
    }
    END {
      if (bad || need != 0) exit 1
      exit 0
    }
  '
}

_COMMIT_SHA=""
resolve_strict_commit_sha() {
  local LC_ALL=C
  local root="$1" rev="$2"
  _COMMIT_SHA=""
  local r
  r="$(trim_str "$rev")"
  [[ -n "$r" ]] || return 1
  if [[ "$r" == -* || "$r" =~ [[:space:]] ]]; then return 1; fi
  if ! run_git_cmd "$root" rev-parse --verify --quiet "${r}^{commit}"; then
    return 1
  fi
  local sha
  sha="$(trim_str "$_GIT_STDOUT")"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  _COMMIT_SHA="$sha"
  return 0
}

check_graph_index_fresh() {
  local root="$1" graph_sha="$2" live_head="$3"
  shift 3
  if [[ "$graph_sha" != "$live_head" ]]; then
    return 1
  fi
  if [[ $# -gt 0 ]]; then
    local p
    local -a _probe_cands=()
    run_git_paths_z "$root" "names" "CONTEXT_ERROR" "" -- diff --no-ext-diff --no-renames --name-only --ignore-submodules=none -z "$graph_sha" -- "$@" || exit 1
    [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _probe_cands+=("${_GIT_PATHS_Z[@]}")
    run_git_paths_z "$root" "names" "CONTEXT_ERROR" "" -- diff --no-ext-diff --no-renames --cached --name-only --ignore-submodules=none -z "$graph_sha" -- "$@" || exit 1
    [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _probe_cands+=("${_GIT_PATHS_Z[@]}")
    run_git_paths_z "$root" "names" "CONTEXT_ERROR" "" -- ls-files --others --exclude-standard -z -- "$@" || exit 1
    [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _probe_cands+=("${_GIT_PATHS_Z[@]}")
    for p in ${_probe_cands[@]+"${_probe_cands[@]}"}; do
      [[ -n "$p" ]] || continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#_IGN_PATHS[@]} -gt 0 ]] && path_in_list "$p" "${_IGN_PATHS[@]}"; then continue; fi
      return 1
    done
    return 0
  fi

  local st_tmp rc=0
  make_temp_file "b3-st-z" st_tmp
  if git -C "$root" -c core.quotepath=false status --porcelain --untracked-files=all --ignore-submodules=none -z >"$st_tmp" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$st_tmp"
    echo "CONTEXT_ERROR: git status failed"
    exit 1
  fi
  local rec orig_rec xy p1 p2 p1_ign p2_ign fresh_rc=0
  while IFS= read -r -d '' rec; do
    [[ -n "$rec" ]] || continue
    if [[ ${#rec} -lt 4 ]]; then
      fresh_rc=1
      break
    fi
    xy="${rec:0:2}"
    p1="${rec:3}"
    while [[ "$p1" == */ && "$p1" != "/" ]]; do p1="${p1%/}"; done
    if [[ -z "$p1" ]]; then
      fresh_rc=1
      break
    fi
    p1_ign=false
    if is_checkpoint_dir "$p1" || { [[ ${#_IGN_PATHS[@]} -gt 0 ]] && path_in_list "$p1" "${_IGN_PATHS[@]}"; }; then
      p1_ign=true
    fi
    if [[ "$xy" == *R* || "$xy" == *C* ]]; then
      if ! IFS= read -r -d '' orig_rec; then
        fresh_rc=1
        break
      fi
      p2="$orig_rec"
      while [[ "$p2" == */ && "$p2" != "/" ]]; do p2="${p2%/}"; done
      if [[ -z "$p2" ]]; then
        fresh_rc=1
        break
      fi
      p2_ign=false
      if is_checkpoint_dir "$p2" || { [[ ${#_IGN_PATHS[@]} -gt 0 ]] && path_in_list "$p2" "${_IGN_PATHS[@]}"; }; then
        p2_ign=true
      fi
      if ! $p1_ign || ! $p2_ign; then
        fresh_rc=1
        break
      fi
    else
      if ! $p1_ign; then
        fresh_rc=1
        break
      fi
    fi
  done < "$st_tmp"
  rm -f "$st_tmp"
  return $fresh_rc
}

get_effective_repo_path_state() {
  local root="$1" rel_p="$2" fail_pfx="${3:-MECHANICAL_FAIL}"
  local canon_r full l_sha h_sha sub_val
  if ! canon_r="$(canon_repo_root "$root")"; then
    printf 'UNSAFE_REPARSE'
    return 0
  fi
  if ! check_wave_path_containment "$canon_r" "$rel_p"; then
    full="${canon_r%/}/${rel_p}"
    if [[ -L "$full" ]]; then
      local parent_rel
      parent_rel="$(dirname "$rel_p")"
      if [[ "$parent_rel" == "." ]] || check_wave_path_containment "$canon_r" "$parent_rel"; then
        if l_sha="$(resolve_symlink_oid "$canon_r" "$rel_p")"; then
          printf '120000:%s' "$l_sha"
          return 0
        fi
      fi
    fi
    printf 'UNSAFE_REPARSE'
    return 0
  fi
  full="${canon_r%/}/${rel_p}"
  if run_git_cmd_quiet "$canon_r" rev-parse --verify --quiet HEAD; then
    if run_git_paths_z "$canon_r" "names" "$fail_pfx" "" -- diff --no-ext-diff --cached --no-renames --name-only -z HEAD -- "$rel_p"; then
      if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then
        local _iw_hit=false _cadel_hit=false _ex_now=false
        run_git_paths_z "$canon_r" "names" "$fail_pfx" "" -- diff --no-ext-diff --no-renames --name-only -z -- "$rel_p" || return 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _iw_hit=true
        run_git_paths_z "$canon_r" "names" "$fail_pfx" "" -- diff --no-ext-diff --cached --no-renames --diff-filter=D --name-only -z -- "$rel_p" || return 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _cadel_hit=true
        [[ -e "$full" || -L "$full" ]] && _ex_now=true
        if $_iw_hit || ( $_cadel_hit && $_ex_now ); then
          printf 'INDEX_WT_DIVERGED'
          return 0
        fi
      fi
    else
      return 1
    fi
  fi
  if [[ ! -e "$full" && ! -L "$full" ]]; then
    printf 'DELETED'
    return 0
  fi
  if [[ -L "$full" ]]; then
    if l_sha="$(resolve_symlink_oid "$canon_r" "$rel_p")"; then
      printf '120000:%s' "$l_sha"
      return 0
    fi
    printf 'UNSAFE_REPARSE'
    return 0
  fi
  if [[ -f "$full" ]]; then
    if ! run_git_cmd "$canon_r" hash-object -- "$rel_p"; then
      echo "${fail_pfx}: git hash-object failed for ${rel_p}: $(git_err_detail)" >&2
      return 1
    fi
    h_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$h_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "${fail_pfx}: git hash-object failed for ${rel_p}: $h_sha" >&2
      return 1
    fi
    printf 'blob:%s' "$h_sha"
    return 0
  fi
  if [[ -d "$full" ]]; then
    if [[ -e "${full}/.git" ]]; then
      if sub_val="$(resolve_submodule_entry "$canon_r" "$rel_p" "")"; then
        printf 'sub:%s' "$sub_val"
        return 0
      fi
    fi
    printf 'DIR'
    return 0
  fi
  printf 'DELETED'
  return 0
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

    split_path_csv_checked "$WATCHED" "FRESHNESS_FAIL" "false"
    WATCHED_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && WATCHED_ARR=("${_CHECKED_CSV_PATHS[@]}")
    [[ ${#WATCHED_ARR[@]} -gt 0 ]] || { echo "FRESHNESS_FAIL: missing --watched-paths"; exit 1; }

    split_path_csv_checked "$OWNED" "FRESHNESS_FAIL" "false"
    OWNED_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && OWNED_ARR=("${_CHECKED_CSV_PATHS[@]}")

    split_path_csv_checked "$IGNORE_DIRTY" "FRESHNESS_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    assert_valid_git_rev "$REPO_ROOT" "$(trim_str "$APPROACH_AT")" "commit" "FRESHNESS_FAIL" "--approach-at-sha"
    RES_APPROACH_SHA="$_VALID_REV_SHA"
    assert_valid_git_rev "$REPO_ROOT" "$(trim_str "$TASK_BASE")" "commit" "FRESHNESS_FAIL" "--task-base-sha"
    RES_TASK_BASE_SHA="$_VALID_REV_SHA"
    assert_valid_git_rev "$REPO_ROOT" "HEAD" "commit" "FRESHNESS_FAIL" "HEAD"
    RES_HEAD_SHA="$_VALID_REV_SHA"

    MB_RC=0
    if run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$RES_TASK_BASE_SHA" "$RES_HEAD_SHA"; then MB_RC=0; else MB_RC=$?; fi
    if [[ $MB_RC -eq 1 ]]; then
      echo "STALE: HEAD is not a descendant of task_base"
      exit 2
    elif [[ $MB_RC -ne 0 ]]; then
      echo "FRESHNESS_FAIL: git merge-base failed: $(git_err_detail)"
      exit 1
    fi

    MB_APP_RC=0
    if run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$RES_APPROACH_SHA" "$RES_HEAD_SHA"; then MB_APP_RC=0; else MB_APP_RC=$?; fi
    if [[ $MB_APP_RC -eq 1 ]]; then
      echo "STALE: HEAD is not a descendant of approach_at_sha"
      exit 2
    elif [[ $MB_APP_RC -ne 0 ]]; then
      echo "FRESHNESS_FAIL: git merge-base failed: $(git_err_detail)"
      exit 1
    fi

    run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --name-only -z "$RES_APPROACH_SHA" "$RES_HEAD_SHA" -- || exit 1
    COMMITTED_HITS=()
    for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if path_in_list "$p" "${WATCHED_ARR[@]}"; then
        COMMITTED_HITS+=("$p")
      fi
    done

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
      _RO_CANDS=()
      run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --name-only -z "$RES_APPROACH_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RO_CANDS+=("${_GIT_PATHS_Z[@]}")
      run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --cached --name-only -z -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RO_CANDS+=("${_GIT_PATHS_Z[@]}")
      run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- ls-files --others --exclude-standard -z || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RO_CANDS+=("${_GIT_PATHS_Z[@]}")
      RO_HITS=()
      for p in ${_RO_CANDS[@]+"${_RO_CANDS[@]}"}; do
        [[ -z "$p" ]] && continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then
          continue
        fi
        if [[ ${#OWNED_ARR[@]} -gt 0 ]] && path_in_list "$p" "${OWNED_ARR[@]}"; then
          continue
        fi
        if path_in_list "$p" "${RO_ARR[@]}"; then
          RO_HITS+=("$p")
        fi
      done

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
    REQUIRE_RECEIPT=""
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --allowed-paths) ALLOWED="${2:-}"; shift 2 ;;
        --require-verify-receipt) REQUIRE_RECEIPT="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "PRECOMMIT_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    MID_OP="$(check_git_mid_operation "$REPO_ROOT")"
    if [[ -n "$MID_OP" ]]; then
      echo "PRECOMMIT_FAIL: git operation in progress ($MID_OP)"
      exit 1
    fi

    split_path_csv_checked "$ALLOWED" "PRECOMMIT_FAIL" "false"
    ALLOWED_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && ALLOWED_ARR=("${_CHECKED_CSV_PATHS[@]}")

    split_path_csv_checked "$IGNORE_DIRTY" "PRECOMMIT_FAIL" "true"
    IGN_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGN_ARR=("${_CHECKED_CSV_PATHS[@]}")

    run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --cached --name-only -z -- || exit 1
    STAGED_ARR=()
    [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && STAGED_ARR=("${_GIT_PATHS_Z[@]}")

    if [[ ${#STAGED_ARR[@]} -lt 1 ]]; then
      echo "PRECOMMIT_FAIL: nothing staged"
      exit 1
    fi

    CP_HITS=()
    for p in "${STAGED_ARR[@]}"; do
      p_low="$(printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      if is_checkpoint_dir "$p"; then
        CP_HITS+=("$p")
      elif [[ "$p_low" == ".b3" || "$p_low" == ".b3/"* ]]; then
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

    SECRET_HITS=()
    for p in "${STAGED_ARR[@]}"; do
      if is_secret_path "$p"; then
        exact_ok=false
        for a in "${ALLOWED_ARR[@]}"; do
          if [[ "$p" == "$a" ]]; then exact_ok=true; break; fi
        done
        if ! $exact_ok; then SECRET_HITS+=("$p"); fi
      fi
    done
    if [[ ${#SECRET_HITS[@]} -gt 0 ]]; then
      HITS_STR="$(printf '%s\n' "${SECRET_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      echo "PRECOMMIT_FAIL: secret path staged without exact allow (${HITS_STR//,/, })"
      exit 1
    fi

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

    REQUIRE_RECEIPT="$(trim_str "$REQUIRE_RECEIPT")"
    if [[ -n "$REQUIRE_RECEIPT" ]]; then
      WT_MM=()
      run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --ignore-submodules=none --name-only -z -- "${STAGED_ARR[@]}" || exit 1
      for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do [[ -n "$p" ]] && WT_MM+=("$p"); done
      run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --cached --diff-filter=D --name-only -z -- || exit 1
      for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$p" ]] || continue
        if [[ -e "${REPO_ROOT}/${p}" ]]; then
          WT_MM+=("$p")
        fi
      done
      if [[ ${#WT_MM[@]} -gt 0 ]]; then
        MM_STR="$(printf '%s\n' "${WT_MM[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        echo "PRECOMMIT_FAIL: staged content differs from working tree (${MM_STR//,/, })"
        exit 1
      fi

      if [[ ${#IGN_ARR[@]} -gt 0 ]]; then
        STAGED_IGN=()
        for p in "${STAGED_ARR[@]}"; do
          if path_in_list "$p" "${IGN_ARR[@]}"; then
            STAGED_IGN+=("$p")
          fi
        done
        if [[ ${#STAGED_IGN[@]} -gt 0 ]]; then
          SI_STR="$(printf '%s\n' "${STAGED_IGN[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
          echo "PRECOMMIT_FAIL: staged path excluded by ignore-dirty-paths (${SI_STR//,/, })"
          exit 1
        fi
      fi

      set +e
      run_verify_check "$REPO_ROOT" "$REQUIRE_RECEIPT" "$IGNORE_DIRTY"
      VR_CODE=$?
      set -e
      if [[ $VR_CODE -ne 0 ]]; then
        echo "PRECOMMIT_FAIL: verification receipt check failed (${_VR_MSG})"
        exit 1
      fi

      if [[ "$_VR_REL_PATHS" != "ALL" ]]; then
        REC_ARR=()
        while IFS= read -r rp; do [[ -n "$rp" ]] && REC_ARR+=("$rp"); done < <(split_csv_lines "$_VR_REL_PATHS" true | LC_ALL=C sort -u)
        OUTSIDE_ARR=()
        for p in "${STAGED_ARR[@]}"; do
          if [[ ${#REC_ARR[@]} -eq 0 ]] || ! path_in_list "$p" "${REC_ARR[@]}"; then
            OUTSIDE_ARR+=("$p")
          fi
        done
        if [[ ${#OUTSIDE_ARR[@]} -gt 0 ]]; then
          OUT_STR="$(printf '%s\n' "${OUTSIDE_ARR[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
          echo "PRECOMMIT_FAIL: staged path outside receipt scope (${OUT_STR//,/, })"
          exit 1
        fi
      fi

      SCOPE_ALL=false
      SCOPE_ARR=()
      if [[ "$_VR_REL_PATHS" == "ALL" ]]; then
        SCOPE_ALL=true
      else
        while IFS= read -r rp; do
          [[ -n "$rp" ]] || continue
          [[ "$rp" == "." ]] && SCOPE_ALL=true
          SCOPE_ARR+=("$rp")
        done < <(split_csv_lines "$_VR_REL_PATHS" true | LC_ALL=C sort -u)
      fi
      UNSTAGED_SCOPE=()
      _UNSTAGED_CANDS=()
      if $SCOPE_ALL; then
        run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --ignore-submodules=none --name-only -z -- || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _UNSTAGED_CANDS+=("${_GIT_PATHS_Z[@]}")
        run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- ls-files --others --exclude-standard -z || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _UNSTAGED_CANDS+=("${_GIT_PATHS_Z[@]}")
      else
        run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- diff --no-ext-diff --no-renames --ignore-submodules=none --name-only -z -- "${SCOPE_ARR[@]}" || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _UNSTAGED_CANDS+=("${_GIT_PATHS_Z[@]}")
        run_git_paths_z "$REPO_ROOT" "names" "GIT_ERROR" "" -- ls-files --others --exclude-standard -z -- "${SCOPE_ARR[@]}" || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _UNSTAGED_CANDS+=("${_GIT_PATHS_Z[@]}")
      fi
      for p in ${_UNSTAGED_CANDS[@]+"${_UNSTAGED_CANDS[@]}"}; do
        [[ -n "$p" ]] || continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGN_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGN_ARR[@]}"; then continue; fi
        if ! $SCOPE_ALL; then
          [[ ${#SCOPE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${SCOPE_ARR[@]}" || continue
        fi
        UNSTAGED_SCOPE+=("$p")
      done
      if [[ ${#UNSTAGED_SCOPE[@]} -gt 0 ]]; then
        UN_STR="$(printf '%s\n' "${UNSTAGED_SCOPE[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        echo "PRECOMMIT_FAIL: unstaged changes in receipt scope (${UN_STR//,/, })"
        exit 1
      fi
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
    assert_valid_git_rev "$REPO_ROOT" "HEAD" "commit" "SNAPSHOT_FAIL" "HEAD"
    HEAD_SHA="$_VALID_REV_SHA"
    assert_valid_git_rev "$REPO_ROOT" "HEAD" "tree" "SNAPSHOT_FAIL" "HEAD^{tree}"
    HEAD_TREE="$_VALID_REV_SHA"
    build_working_tree_oid "$REPO_ROOT" "SNAPSHOT_FAIL"
    CUR_TREE="$_WT_TREE_OID"
    if [[ "$CUR_TREE" == "$HEAD_TREE" ]]; then
      SHA="$HEAD_SHA"
    else
      if ! run_git_cmd "$REPO_ROOT" commit-tree "$CUR_TREE" -p "$HEAD_SHA" -m "b3-snapshot"; then
        echo "SNAPSHOT_FAIL: git commit-tree failed: $(git_err_detail)"
        exit 1
      fi
      SHA="$(trim_str "$_GIT_STDOUT")"
    fi
    OBJ_TYPE=""
    if run_git_cmd "$REPO_ROOT" cat-file -t "$SHA"; then
      OBJ_TYPE="$(trim_str "$_GIT_STDOUT")"
    fi
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
    split_path_csv_checked "$IGNORE_DIRTY" "DIFF_SCOPE_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    resolve_scope_target_and_base "$REPO_ROOT" "$TARGET_REF" "$BASE_SHA" "DIFF_SCOPE_FAIL" "object" ${IGNORE_ARR[@]+"${IGNORE_ARR[@]}"}
    TARGET_REF="$_SCOPE_TARGET_REF"
    TARGET_COMMIT_SHA="$_SCOPE_TARGET_SHA"
    BASE_SHA="$_SCOPE_BASE_SHA"

    SCOPE_OUT=""
    if ! SCOPE_OUT="$(run_scope_engine "$REPO_ROOT" "$BASE_SHA" "$TARGET_COMMIT_SHA" "$IGNORE_DIRTY" 4 "DIFF_SCOPE_FAIL" "" "" "false")"; then
      printf '%s\n' "$SCOPE_OUT"
      exit 1
    fi

    parse_scope_engine_output "$SCOPE_OUT"
    IS_EMPTY="$_SE_IS_EMPTY"; SIZE_CLASS="$_SE_SIZE_CLASS"; FILE_COUNT="$_SE_FILES"; TOTAL_LINES="$_SE_LINES"
    RF_OUT="$_SE_REVIEW_FILES"; NF_OUT="$_SE_NOISE_FILES"; RISK_LEVEL="$_SE_RISK_LEVEL"; RISK_SIGNALS="$_SE_RISK_SIGNALS"; REC_SPECS="$_SE_REC_SPECS"

    PREV_SHA="$(trim_str "$PREV_SHA")"
    HAS_PREV=false
    DF_OUT="none"
    if [[ -n "$PREV_SHA" ]]; then
      HAS_PREV=true
      assert_valid_git_rev "$REPO_ROOT" "$PREV_SHA" "commit" "DIFF_SCOPE_FAIL" "--prev-sha"
      if [[ -n "$TARGET_REF" ]]; then
        DELTA_END="$TARGET_COMMIT_SHA"
      else
        build_working_tree_oid "$REPO_ROOT" "DIFF_SCOPE_FAIL"
        DELTA_END="$_WT_TREE_OID"
      fi
      run_git_paths_z "$REPO_ROOT" "names" "DIFF_SCOPE_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z "$PREV_SHA" "$DELTA_END" -- || exit 1
      DELTA_ARR=()
      for p in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -z "$p" ]] && continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
        if is_noise_file "$p"; then continue; fi
        DELTA_ARR+=("$p")
      done
      if [[ ${#DELTA_ARR[@]} -gt 0 ]]; then
        DF_OUT="$(printf '%s\n' "${DELTA_ARR[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      fi
    fi

    if [[ "$IS_EMPTY" == "true" ]]; then
      if ! $HAS_PREV || [[ "$DF_OUT" == "none" ]]; then
        echo "EMPTY_DIFF"
        exit 2
      fi
      CL_RISK="$(eval_risk_for_csv_awk "$DF_OUT")"
      { IFS= read -r C_LVL; IFS= read -r C_SIG; IFS= read -r C_SP; } <<< "$CL_RISK"
      printf 'size_class=CLEAN_AFTER_FIX\nfiles=0\nlines=0\nreview_files=none\nnoise_files=none\ndelta_files=%s\nrisk_level=%s\nrisk_signals=%s\nrecommended_specialists=%s\n' "$DF_OUT" "$C_LVL" "$C_SIG" "$C_SP"
      exit 0
    fi

    printf 'size_class=%s\nfiles=%s\nlines=%s\nreview_files=%s\nnoise_files=%s\n' "$SIZE_CLASS" "$FILE_COUNT" "$TOTAL_LINES" "$RF_OUT" "$NF_OUT"
    if $HAS_PREV; then
      printf 'delta_files=%s\n' "$DF_OUT"
    fi
    printf 'risk_level=%s\nrisk_signals=%s\nrecommended_specialists=%s\n' "$RISK_LEVEL" "$RISK_SIGNALS" "$REC_SPECS"
    ;;

  mechanical-check)
    REPO_ROOT="."
    BASE_SHA=""
    TARGET_REF=""
    ALLOWED=""
    IGNORE_DIRTY=""
    OBSOLETES=""
    ALLOW_MASS_DELETE=false
    WAVE_SPECS=""
    WORKER_CHANGES=""
    WORKER_ROOTS=""
    PROTECTED_PATHS=""
    DIRTY_DIGESTS=""
    HAS_DIRTY_DIGESTS_ARG="false"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --allowed-paths) ALLOWED="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --obsoletes) OBSOLETES="${2:-}"; shift 2 ;;
        --allow-mass-delete) ALLOW_MASS_DELETE=true; shift ;;
        --wave-specs) [[ $# -ge 2 ]] || { echo "MECHANICAL_FAIL: missing value for $1"; exit 1; }; WAVE_SPECS="$2"; shift 2 ;;
        --worker-changes) [[ $# -ge 2 ]] || { echo "MECHANICAL_FAIL: missing value for $1"; exit 1; }; WORKER_CHANGES="$2"; shift 2 ;;
        --worker-roots) [[ $# -ge 2 ]] || { echo "MECHANICAL_FAIL: missing value for $1"; exit 1; }; WORKER_ROOTS="$2"; shift 2 ;;
        --protected-paths) [[ $# -ge 2 ]] || { echo "MECHANICAL_FAIL: missing value for $1"; exit 1; }; PROTECTED_PATHS="$2"; shift 2 ;;
        --dirty-digests) [[ $# -ge 2 ]] || { echo "MECHANICAL_FAIL: missing value for $1"; exit 1; }; DIRTY_DIGESTS="$2"; HAS_DIRTY_DIGESTS_ARG="true"; shift 2 ;;
        *) echo "MECHANICAL_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    REPO_EXISTS_MC="false"
    [[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] && REPO_EXISTS_MC="true"
    detect_repo_case_insensitive "$REPO_ROOT"
    _B3_IS_CASE_INSENSITIVE_FS="$_REPO_CASE_INSENSITIVE"

    HAS_WAVE_SPECS="false"
    [[ -n "$(trim_str "$WAVE_SPECS")" ]] && HAS_WAVE_SPECS="true"
    HAS_WORKER_CHANGES="false"
    [[ -n "$(trim_str "$WORKER_CHANGES")" ]] && HAS_WORKER_CHANGES="true"
    HAS_WORKER_ROOTS="false"
    [[ -n "$(trim_str "$WORKER_ROOTS")" ]] && HAS_WORKER_ROOTS="true"
    HAS_PROTECTED_ARG="false"
    [[ -n "$(trim_str "$PROTECTED_PATHS")" ]] && HAS_PROTECTED_ARG="true"

    if [[ "$HAS_WORKER_CHANGES" == "true" && "$HAS_WORKER_ROOTS" == "true" ]]; then
      echo "MECHANICAL_FAIL: cannot specify both -WorkerChanges and -WorkerRoots"
      exit 1
    fi
    if [[ "$HAS_WORKER_CHANGES" == "true" && "$HAS_WAVE_SPECS" != "true" ]]; then
      echo "MECHANICAL_FAIL: -WorkerChanges requires -WaveSpecs"
      exit 1
    fi
    if [[ "$HAS_WORKER_ROOTS" == "true" && "$HAS_WAVE_SPECS" != "true" ]]; then
      echo "MECHANICAL_FAIL: -WorkerRoots requires -WaveSpecs"
      exit 1
    fi
    if [[ "$HAS_WORKER_ROOTS" == "true" && -n "$(trim_str "$TARGET_REF")" ]]; then
      echo "MECHANICAL_FAIL: -WorkerRoots cannot be combined with -TargetRef"
      exit 1
    fi

    MC_PROT_LIST=()
    MC_PROT_LOW_LIST=()
    if [[ "$HAS_PROTECTED_ARG" == "true" ]]; then
      parse_wave_paths "$PROTECTED_PATHS" false false "MECHANICAL_FAIL"
      if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
        for prot in "${_WAVE_PARSED_PATHS[@]}"; do
          if [[ "$prot" == "." ]]; then
            echo "MECHANICAL_FAIL: invalid protected path '.'"
            exit 1
          fi
          if [[ "$REPO_EXISTS_MC" == "true" ]] && ! check_wave_path_containment "$REPO_ROOT" "$prot"; then
            echo "MECHANICAL_FAIL: unsafe symlink or junction alias in path '$prot'"
            exit 1
          fi
          MC_PROT_LIST+=("$prot")
          if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
            MC_PROT_LOW_LIST+=("$(printf '%s' "$prot" | LC_ALL=C tr '[:upper:]' '[:lower:]')")
          else
            MC_PROT_LOW_LIST+=("$prot")
          fi
        done
      fi
    fi

    _mc_prot_match_ci() {
      local cand="$1" c_cmp p_cmp
      [[ ${#MC_PROT_LOW_LIST[@]} -gt 0 && -n "$cand" ]] || return 1
      if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
        c_cmp="$(printf '%s' "$cand" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      else
        c_cmp="$cand"
      fi
      for p_cmp in "${MC_PROT_LOW_LIST[@]}"; do
        if [[ "$p_cmp" == "." || "$c_cmp" == "$p_cmp" || "$c_cmp" == "${p_cmp}/"* ]]; then
          return 0
        fi
      done
      return 1
    }

    DD_PATHS=()
    DD_DIGESTS=()
    DD_KEYS_SEEN="|"
    if [[ "$HAS_DIRTY_DIGESTS_ARG" == "true" ]]; then
      if has_control_chars "$DIRTY_DIGESTS"; then
        echo "MECHANICAL_FAIL: invalid -DirtyDigests"
        exit 1
      fi
      DD_TRIM="$(trim_str "$DIRTY_DIGESTS")"
      if [[ -n "$DD_TRIM" && "$DD_TRIM" != "none" && "$DD_TRIM" != "[]" ]]; then
        _had_ng_dd=false
        case "$-" in *f*) _had_ng_dd=true ;; esac
        set -f
        DD_ENTRIES=()
        IFS=';' read -r -d '' -a DD_ENTRIES < <(printf '%s\0' "$DD_TRIM") || true
        if ! $_had_ng_dd; then set +f; fi
        if [[ ${#DD_ENTRIES[@]} -gt 0 ]]; then
          for dd_ent in "${DD_ENTRIES[@]}"; do
            dd_part="$(trim_str "$dd_ent")"
            [[ -z "$dd_part" ]] && continue
            if [[ "$dd_part" != *"="* ]]; then
              echo "MECHANICAL_FAIL: invalid DirtyDigests entry '$dd_part'"
              exit 1
            fi
            raw_dp="$(trim_str "${dd_part%%=*}")"
            raw_dig="$(trim_str "${dd_part#*=}")"
            if [[ -z "$raw_dp" || "$raw_dp" == *","* ]]; then
              echo "MECHANICAL_FAIL: invalid DirtyDigests path '$raw_dp'"
              exit 1
            fi
            parse_wave_paths "$raw_dp" false true "MECHANICAL_FAIL"
            if [[ ${#_WAVE_PARSED_PATHS[@]} -ne 1 ]]; then
              echo "MECHANICAL_FAIL: invalid DirtyDigests path '$raw_dp'"
              exit 1
            fi
            dp_norm="${_WAVE_PARSED_PATHS[0]}"
            if is_checkpoint_dir "$dp_norm"; then
              echo "MECHANICAL_FAIL: invalid DirtyDigests path '$dp_norm'"
              exit 1
            fi
            if [[ "$REPO_EXISTS_MC" == "true" ]] && ! check_wave_path_containment "$REPO_ROOT" "$dp_norm"; then
              echo "MECHANICAL_FAIL: unsafe symlink or junction alias in path '$dp_norm'"
              exit 1
            fi
            if [[ "$raw_dig" != "DELETED" && ! "$raw_dig" =~ ^[0-9a-fA-F]{64}$ ]]; then
              echo "MECHANICAL_FAIL: invalid DirtyDigests digest for '$dp_norm'"
              exit 1
            fi
            if [[ "$raw_dig" == "DELETED" ]]; then
              norm_dig="DELETED"
            else
              norm_dig="$(printf '%s' "$raw_dig" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            fi
            if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
              dd_key="$(printf '%s' "$dp_norm" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            else
              dd_key="$dp_norm"
            fi
            if [[ "$DD_KEYS_SEEN" == *"|${dd_key}|"* ]]; then
              echo "MECHANICAL_FAIL: duplicate DirtyDigests path '$dp_norm'"
              exit 1
            fi
            DD_KEYS_SEEN+="${dd_key}|"
            DD_PATHS+=("$dp_norm")
            DD_DIGESTS+=("$norm_dig")
          done
        fi
      fi
    fi

    IS_ATTRIBUTING="false"
    [[ "$HAS_WORKER_CHANGES" == "true" || "$HAS_WORKER_ROOTS" == "true" ]] && IS_ATTRIBUTING="true"

    WS_IDS=()
    WS_PACKED=()
    WS_LOW_PACKED=()
    WC_IDS=()
    WC_PACKED=()
    WR_IDS=()
    WR_ROOTS=()
    if [[ "$HAS_WAVE_SPECS" == "true" ]]; then
      parse_wave_task_map "$WAVE_SPECS" "$REPO_ROOT" "MECHANICAL_FAIL" "WaveSpecs" "--wave-specs" true true true ""
      WS_IDS=("${_WTM_IDS[@]}")
      WS_PACKED=("${_WTM_PACKED[@]}")
      WS_LOW_PACKED=("${_WTM_LOW_PACKED[@]}")
      if [[ ${#MC_PROT_LIST[@]} -gt 0 ]]; then
        for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
          [[ -n "${WS_PACKED[$wsi]}" ]] || continue
          IFS='|' read -ra wpi_arr <<< "${WS_PACKED[$wsi]}"
          IFS='|' read -ra wpi_low_arr <<< "${WS_LOW_PACKED[$wsi]}"
          for ((pk_i = 0; pk_i < ${#wpi_arr[@]}; pk_i++)); do
            for ((pk_j = 0; pk_j < ${#MC_PROT_LIST[@]}; pk_j++)); do
              if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
                wave_paths_overlap_cmp "${wpi_low_arr[$pk_i]}" "${MC_PROT_LOW_LIST[$pk_j]}"
              else
                wave_paths_overlap_cmp "${wpi_arr[$pk_i]}" "${MC_PROT_LIST[$pk_j]}"
              fi
              if [[ "$_WAVE_OV" == "equal" || "$_WAVE_OV" == "prefix" ]]; then
                echo "MECHANICAL_FAIL: protected path '${wpi_arr[$pk_i]}' overlaps single-writer boundary '${MC_PROT_LIST[$pk_j]}'"
                exit 1
              fi
            done
          done
        done
      fi
      if [[ "$IS_ATTRIBUTING" == "true" ]]; then
        BASE_RAW_ATTR="$(trim_str "$BASE_SHA")"
        if [[ ! "$BASE_RAW_ATTR" =~ ^[0-9a-fA-F]{40}$ ]]; then
          echo "MECHANICAL_FAIL: worker attribution requires explicit 40-hex -BaseSha"
          exit 1
        fi
        MID_OP_MC="$(check_git_mid_operation "$REPO_ROOT")"
        if [[ -n "$MID_OP_MC" ]]; then
          echo "MECHANICAL_FAIL: git operation in progress ($MID_OP_MC)"
          exit 1
        fi
        for ((wsi_a = 0; wsi_a < ${#WS_IDS[@]}; wsi_a++)); do
          [[ -n "${WS_PACKED[$wsi_a]}" ]] || continue
          for ((wsi_b = wsi_a + 1; wsi_b < ${#WS_IDS[@]}; wsi_b++)); do
            [[ -n "${WS_PACKED[$wsi_b]}" ]] || continue
            IFS='|' read -ra pa_arr <<< "${WS_PACKED[$wsi_a]}"
            IFS='|' read -ra pb_arr <<< "${WS_PACKED[$wsi_b]}"
            IFS='|' read -ra pa_low <<< "${WS_LOW_PACKED[$wsi_a]}"
            IFS='|' read -ra pb_low <<< "${WS_LOW_PACKED[$wsi_b]}"
            for ((ka = 0; ka < ${#pa_arr[@]}; ka++)); do
              for ((kb = 0; kb < ${#pb_arr[@]}; kb++)); do
                wave_paths_overlap_cmp "${pa_low[$ka]}" "${pb_low[$kb]}"
                if [[ "$_WAVE_OV" != "none" ]]; then
                  echo "MECHANICAL_FAIL: overlapping WaveSpecs '${pa_arr[$ka]}' and '${pb_arr[$kb]}' (${WS_IDS[$wsi_a]},${WS_IDS[$wsi_b]})"
                  exit 1
                fi
              done
            done
          done
        done
      fi
      WS_ALLOWED_PACKED="|$(IFS='|'; printf '%s' "${WS_IDS[*]}")|"
      if [[ "$HAS_WORKER_CHANGES" == "true" ]]; then
        parse_wave_task_map "$WORKER_CHANGES" "$REPO_ROOT" "MECHANICAL_FAIL" "WorkerChanges" "--worker-changes" false true true "$WS_ALLOWED_PACKED"
        WC_IDS=("${_WTM_IDS[@]}")
        WC_PACKED=("${_WTM_PACKED[@]}")
      fi
      if [[ "$HAS_WORKER_ROOTS" == "true" ]]; then
        if has_control_chars "$WORKER_ROOTS"; then
          echo "MECHANICAL_FAIL: invalid -WorkerRoots"
          exit 1
        fi
        _had_ng_wr=false
        case "$-" in *f*) _had_ng_wr=true ;; esac
        set -f
        WR_ENTRIES=()
        IFS=';' read -r -d '' -a WR_ENTRIES < <(printf '%s\0' "$WORKER_ROOTS") || true
        if ! $_had_ng_wr; then set +f; fi
        WR_SEEN_IDS="|"
        if [[ ${#WR_ENTRIES[@]} -gt 0 ]]; then
          for wr_ent in "${WR_ENTRIES[@]}"; do
            wr_trim="$(trim_str "$wr_ent")"
            [[ -z "$wr_trim" ]] && continue
            if [[ "$wr_trim" != *"="* ]]; then
              echo "MECHANICAL_FAIL: invalid WorkerRoots entry '$wr_trim' (expected TaskId=worktree_path)"
              exit 1
            fi
            tid="$(trim_str "${wr_trim%%=*}")"
            wt_val="$(trim_str "${wr_trim#*=}")"
            if [[ -z "$tid" ]] || ! is_valid_wave_task_id "$tid"; then
              echo "MECHANICAL_FAIL: invalid task id '$tid' in WorkerRoots"
              exit 1
            fi
            if [[ "$WR_SEEN_IDS" == *"|${tid}|"* ]]; then
              echo "MECHANICAL_FAIL: duplicate task id '$tid' in WorkerRoots"
              exit 1
            fi
            if [[ "$WS_ALLOWED_PACKED" != *"|${tid}|"* ]]; then
              echo "MECHANICAL_FAIL: unknown task id '$tid' in WorkerRoots"
              exit 1
            fi
            if [[ -z "$wt_val" ]]; then
              echo "MECHANICAL_FAIL: empty worktree root for task '$tid' in WorkerRoots"
              exit 1
            fi
            WR_SEEN_IDS+="${tid}|"
            WR_IDS+=("$tid")
            if [[ "$wt_val" == "none" || "$wt_val" == "[]" ]]; then
              WR_ROOTS+=("")
            else
              WR_ROOTS+=("$wt_val")
            fi
          done
        fi
        if [[ ${#WR_IDS[@]} -lt 1 ]]; then
          echo "MECHANICAL_FAIL: no tasks in -WorkerRoots"
          exit 1
        fi
      fi
    fi

    split_path_csv_checked "$ALLOWED" "MECHANICAL_FAIL" "false"
    ALLOWED_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && ALLOWED_ARR=("${_CHECKED_CSV_PATHS[@]}")

    split_path_csv_checked "$IGNORE_DIRTY" "MECHANICAL_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    OBS_ARR=()
    while IFS= read -r tok; do [[ -n "$tok" ]] && OBS_ARR+=("$tok"); done < <(split_csv_lines "$OBSOLETES" false)

    BASE_KIND_MC="object"
    [[ "$IS_ATTRIBUTING" == "true" ]] && BASE_KIND_MC="commit"
    resolve_scope_target_and_base "$REPO_ROOT" "$TARGET_REF" "$BASE_SHA" "MECHANICAL_FAIL" "$BASE_KIND_MC" ${IGNORE_ARR[@]+"${IGNORE_ARR[@]}"}
    TARGET_REF="$_SCOPE_TARGET_REF"
    TARGET_COMMIT_SHA="$_SCOPE_TARGET_SHA"
    BASE_SHA="$_SCOPE_BASE_SHA"

    CH_PATHS=()
    NONDEL_PATHS=()
    UN_PATHS=()
    CA_BASE_CH_PATHS=()
    CA_BASE_NONDEL_PATHS=()
    if [[ -n "$TARGET_REF" ]]; then
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && CH_PATHS=("${_GIT_PATHS_Z[@]}")
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --diff-filter=d --name-only -z "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && NONDEL_PATHS=("${_GIT_PATHS_Z[@]}")
    else
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z "$BASE_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && CH_PATHS=("${_GIT_PATHS_Z[@]}")
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --diff-filter=d --name-only -z "$BASE_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && NONDEL_PATHS=("${_GIT_PATHS_Z[@]}")
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --cached --no-renames --name-only -z "$BASE_SHA" -- || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && CA_BASE_CH_PATHS=("${_GIT_PATHS_Z[@]}")
      if [[ ${#CA_BASE_CH_PATHS[@]} -gt 0 ]]; then
        run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --cached --no-renames --diff-filter=d --name-only -z "$BASE_SHA" -- || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && CA_BASE_NONDEL_PATHS=("${_GIT_PATHS_Z[@]}")
      fi
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- ls-files --others --exclude-standard -z || exit 1
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && UN_PATHS=("${_GIT_PATHS_Z[@]}")
    fi

    RAW_BEFORE_IGN=()
    _RAW_CANDS=(${CH_PATHS[@]+"${CH_PATHS[@]}"} ${CA_BASE_CH_PATHS[@]+"${CA_BASE_CH_PATHS[@]}"} ${UN_PATHS[@]+"${UN_PATHS[@]}"})
    if [[ "$HAS_PROTECTED_ARG" == "true" || "$HAS_DIRTY_DIGESTS_ARG" == "true" ]]; then
      if [[ -z "$TARGET_REF" ]]; then
        run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z HEAD -- || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RAW_CANDS+=("${_GIT_PATHS_Z[@]}")
        run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --cached --name-only -z -- || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RAW_CANDS+=("${_GIT_PATHS_Z[@]}")
        run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z -- || exit 1
        [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _RAW_CANDS+=("${_GIT_PATHS_Z[@]}")
      fi
      _raw_seen=$'\x1f'
      for xp in ${_RAW_CANDS[@]+"${_RAW_CANDS[@]}"}; do
        [[ -n "$xp" ]] || continue
        is_checkpoint_dir "$xp" && continue
        if [[ "$_raw_seen" != *$'\x1f'"${xp}"$'\x1f'* ]]; then
          _raw_seen+="${xp}"$'\x1f'
          RAW_BEFORE_IGN+=("$xp")
        fi
      done
    fi

    PROTECTED_VIOLATIONS=()
    if [[ ${#MC_PROT_LIST[@]} -gt 0 && ${#RAW_BEFORE_IGN[@]} -gt 0 ]]; then
      for rp in "${RAW_BEFORE_IGN[@]}"; do
        if _mc_prot_match_ci "$rp"; then
          PROTECTED_VIOLATIONS+=("$rp")
        fi
      done
    fi

    DIRTY_TAMPER_LIST=()
    if [[ "$HAS_DIRTY_DIGESTS_ARG" == "true" ]]; then
      CANON_REPO_MC=""
      [[ "$REPO_EXISTS_MC" == "true" ]] && CANON_REPO_MC="$(canon_repo_root "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
      if [[ ${#DD_PATHS[@]} -gt 0 ]]; then
        for ((ddi = 0; ddi < ${#DD_PATHS[@]}; ddi++)); do
          dp="${DD_PATHS[$ddi]}"
          exp_dig="${DD_DIGESTS[$ddi]}"
          full_dp="${CANON_REPO_MC:-$REPO_ROOT}/${dp}"
          if [[ "$exp_dig" == "DELETED" ]]; then
            if [[ -e "$full_dp" || -L "$full_dp" ]]; then
              DIRTY_TAMPER_LIST+=("$dp")
            fi
          else
            if [[ ! -f "$full_dp" || -L "$full_dp" ]] || ! check_wave_path_containment "${CANON_REPO_MC:-$REPO_ROOT}" "$dp"; then
              DIRTY_TAMPER_LIST+=("$dp")
            else
              act_dig="$(compute_file_sha256 "$full_dp" || true)"
              if [[ "$act_dig" != "$exp_dig" ]]; then
                DIRTY_TAMPER_LIST+=("$dp")
              fi
            fi
          fi
        done
      fi
      if [[ ${#IGNORE_ARR[@]} -gt 0 && ${#RAW_BEFORE_IGN[@]} -gt 0 ]]; then
        IGN_PACKED_DD="$(IFS='|'; printf '%s' "${IGNORE_ARR[*]}")"
        for rp in "${RAW_BEFORE_IGN[@]}"; do
          if ownership_path_match "$rp" "$IGN_PACKED_DD"; then
            if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
              rp_key="$(printf '%s' "$rp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            else
              rp_key="$rp"
            fi
            if [[ "$DD_KEYS_SEEN" != *"|${rp_key}|"* ]]; then
              DIRTY_TAMPER_LIST+=("$rp")
            fi
          fi
        done
      fi
    fi

    IGN_PACKED_MC=""
    if [[ ${#IGNORE_ARR[@]} -gt 0 ]]; then
      IGN_PACKED_MC="$(IFS='|'; printf '%s' "${IGNORE_ARR[*]}")"
    fi
    ALL_CHANGED=()
    ALL_CHANGED_DEDUP=$'\x1f'
    for p in ${CH_PATHS[@]+"${CH_PATHS[@]}"} ${UN_PATHS[@]+"${UN_PATHS[@]}"} ${CA_BASE_CH_PATHS[@]+"${CA_BASE_CH_PATHS[@]}"}; do
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      p_key="$p"
      if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
        p_key="$(printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      fi
      if [[ -n "$IGN_PACKED_MC" ]] && ownership_path_match "$p" "$IGN_PACKED_MC"; then continue; fi
      if [[ "$ALL_CHANGED_DEDUP" != *$'\x1f'"${p_key}"$'\x1f'* ]]; then
        ALL_CHANGED_DEDUP+="${p_key}"$'\x1f'
        ALL_CHANGED+=("$p")
      fi
    done

    NON_DEL_CHANGED=()
    NON_DEL_DEDUP=$'\x1f'
    for p in ${NONDEL_PATHS[@]+"${NONDEL_PATHS[@]}"} ${UN_PATHS[@]+"${UN_PATHS[@]}"} ${CA_BASE_NONDEL_PATHS[@]+"${CA_BASE_NONDEL_PATHS[@]}"}; do
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ -n "$IGN_PACKED_MC" ]] && ownership_path_match "$p" "$IGN_PACKED_MC"; then continue; fi
      if [[ "$NON_DEL_DEDUP" != *$'\x1f'"${p}"$'\x1f'* ]]; then
        NON_DEL_DEDUP+="${p}"$'\x1f'
        NON_DEL_CHANGED+=("$p")
      fi
    done

    SCOPE_CREEP=()
    if [[ ${#ALLOWED_ARR[@]} -gt 0 && ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          SCOPE_CREEP+=("$p")
        fi
      done
    fi

    SAFETY_HITS=()
    SAFETY_SEEN="|"
    if [[ ${#NON_DEL_CHANGED[@]} -gt 0 ]]; then
      for p in "${NON_DEL_CHANGED[@]}"; do
        if is_secret_path "$p"; then
          SAFETY_SEEN+="secret_path:${p}|"
          SAFETY_HITS+=("secret_path:${p}")
        fi
      done
    fi
    SQL_HIT_COUNT=0

    DIFF_CA_U0=""
    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-ext-diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-ext-diff --no-renames -U0 "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
      if [[ ${#CA_BASE_CH_PATHS[@]} -gt 0 ]]; then
        run_git_cmd "$REPO_ROOT" diff --no-ext-diff --cached --no-renames -U0 "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --cached -U0 failed: $(git_err_detail)"; exit 1; }
        DIFF_CA_U0="$_GIT_STDOUT"
      fi
    fi
    LEFTOVER_HITS=()
    LEFTOVER_SEEN="|"
    for _u0_blob in "$DIFF_U0" "$DIFF_CA_U0"; do
      [[ -n "$_u0_blob" ]] || continue
      CUR_FILE=""
      CUR_LINE=0
      SKIP_FILE=true
      CUR_IS_TEST=false
      IN_HUNK=false
      while IFS= read -r ln; do
        ln="${ln%$'\r'}"
        if [[ "$ln" == "diff --git "* ]]; then
          CUR_FILE=""
          SKIP_FILE=true
          CUR_IS_TEST=false
          IN_HUNK=false
          continue
        fi
        if ! $IN_HUNK && [[ "$ln" == "+++ "* ]]; then
          if [[ "$ln" == "+++ /dev/null" ]]; then
            CUR_FILE=""
            SKIP_FILE=true
            CUR_IS_TEST=false
          else
            cand="${ln#+++ }"
            cand="${cand#b/}"
            CUR_FILE="$(norm_path "$cand")"
            SKIP_FILE=false
            if [[ -z "$CUR_FILE" ]] || is_checkpoint_dir "$CUR_FILE" || is_md_file "$CUR_FILE"; then
              SKIP_FILE=true
            elif is_noise_file "$CUR_FILE"; then
              SKIP_FILE=true
            elif [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$CUR_FILE" "${IGNORE_ARR[@]}"; then
              SKIP_FILE=true
            fi
            if ! $SKIP_FILE && is_test_path "$CUR_FILE"; then
              CUR_IS_TEST=true
            else
              CUR_IS_TEST=false
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
          find_leftover_tag_var "$body"
          if [[ -n "$_LO_TAG" && ${#LEFTOVER_HITS[@]} -lt 10 ]]; then
            _lo_ent="${CUR_FILE}:${CUR_LINE}:${_LO_TAG}"
            if [[ "$LEFTOVER_SEEN" != *"|${_lo_ent}|"* ]]; then
              LEFTOVER_SEEN+="${_lo_ent}|"
              LEFTOVER_HITS+=("$_lo_ent")
            fi
          fi
          if ! $CUR_IS_TEST && has_destructive_sql "$body" && [[ $SQL_HIT_COUNT -lt 10 ]]; then
            _sh_ent="destructive_sql:${CUR_FILE}:${CUR_LINE}"
            if [[ "$SAFETY_SEEN" != *"|${_sh_ent}|"* ]]; then
              SAFETY_SEEN+="${_sh_ent}|"
              SAFETY_HITS+=("$_sh_ent")
              SQL_HIT_COUNT=$((SQL_HIT_COUNT + 1))
            fi
          fi
          CUR_LINE=$((CUR_LINE + 1))
        fi
      done <<< "$_u0_blob"
    done

    UN_SORTED=(${UN_PATHS[@]+"${UN_PATHS[@]}"})

    if [[ ${#UN_SORTED[@]} -gt 0 ]]; then
      for u in "${UN_SORTED[@]}"; do
        if [[ ${#LEFTOVER_HITS[@]} -ge 10 && $SQL_HIT_COUNT -ge 10 ]]; then break; fi
        if is_checkpoint_dir "$u" || is_md_file "$u"; then continue; fi
        is_noise_file "$u" && continue
        if [[ -n "$IGN_PACKED_MC" ]] && ownership_path_match "$u" "$IGN_PACKED_MC"; then continue; fi
        [[ -f "${REPO_ROOT}/${u}" ]] || continue
        is_binary_file "${REPO_ROOT}/${u}" && continue
        u_is_test=false
        is_test_path "$u" && u_is_test=true
        lno=0
        while IFS= read -r fl || [[ -n "$fl" ]]; do
          lno=$((lno + 1))
          fl="${fl%$'\r'}"
          find_leftover_tag_var "$fl"
          if [[ -n "$_LO_TAG" && ${#LEFTOVER_HITS[@]} -lt 10 ]]; then
            LEFTOVER_HITS+=("${u}:${lno}:${_LO_TAG}")
          fi
          if ! $u_is_test && has_destructive_sql "$fl" && [[ $SQL_HIT_COUNT -lt 10 ]]; then
            SAFETY_HITS+=("destructive_sql:${u}:${lno}")
            SQL_HIT_COUNT=$((SQL_HIT_COUNT + 1))
          fi
        done < "${REPO_ROOT}/${u}"
      done
    fi

    CAND_DEL_SEEN=$'\x1f'
    CAND_DEL_COUNT=0
    for dp in ${CH_PATHS[@]+"${CH_PATHS[@]}"}; do
      [[ -n "$dp" ]] || continue
      is_checkpoint_dir "$dp" && continue
      if [[ -n "$IGN_PACKED_MC" ]] && ownership_path_match "$dp" "$IGN_PACKED_MC"; then continue; fi
      is_noise_file "$dp" && continue
      if [[ "$NON_DEL_DEDUP" != *$'\x1f'"${dp}"$'\x1f'* && "$CAND_DEL_SEEN" != *$'\x1f'"${dp}"$'\x1f'* ]]; then
        CAND_DEL_SEEN+="${dp}"$'\x1f'
        CAND_DEL_COUNT=$((CAND_DEL_COUNT + 1))
      fi
    done

    if ! $ALLOW_MASS_DELETE && [[ $CAND_DEL_COUNT -ge 10 ]]; then
      if [[ -n "$TARGET_REF" ]]; then
        DEL_TARGET="$TARGET_COMMIT_SHA"
      else
        build_working_tree_oid "$REPO_ROOT" "MECHANICAL_FAIL" "true"
        DEL_TARGET="$_WT_TREE_OID"
      fi
      run_git_paths_z "$REPO_ROOT" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff -M --diff-filter=D --name-only -z "$BASE_SHA" "$DEL_TARGET" -- || exit 1
      DEL_COUNT=0
      for dp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$dp" ]] || continue
        is_checkpoint_dir "$dp" && continue
        if [[ -n "$IGN_PACKED_MC" ]] && ownership_path_match "$dp" "$IGN_PACKED_MC"; then continue; fi
        is_noise_file "$dp" && continue
        DEL_COUNT=$((DEL_COUNT + 1))
      done
      if [[ $DEL_COUNT -ge 10 ]]; then
        SAFETY_HITS+=("mass_delete:${DEL_COUNT}f")
      fi
    fi

    OBS_HITS=()
    if [[ ${#OBS_ARR[@]} -gt 0 ]]; then
      OBS_EXISTING_PACKED="|"
      if [[ -n "$TARGET_REF" ]]; then
        OBS_LS_PATHS=()
        re_obs_dd='(^|/)\.\.(/|$)'
        for tok in "${OBS_ARR[@]}"; do
          nt="$(norm_path "$tok")"
          if [[ -n "$nt" && "$nt" != -* && "$nt" != *:* && ! "$nt" =~ $re_obs_dd ]]; then
            OBS_LS_PATHS+=("$nt")
          fi
        done
        if [[ ${#OBS_LS_PATHS[@]} -gt 0 ]]; then
          run_git_paths_z "$REPO_ROOT" "ls-tree-z" "MECHANICAL_FAIL" "" -- ls-tree --name-only -z "$TARGET_COMMIT_SHA" -- "${OBS_LS_PATHS[@]}" || exit 1
          for lp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
            [[ -n "$lp" ]] && OBS_EXISTING_PACKED+="${lp}|"
          done
        fi
      fi

      BATCH_GREP_ARGS=(grep)
      [[ -z "$TARGET_REF" ]] && BATCH_GREP_ARGS+=(--untracked)
      BATCH_GREP_ARGS+=(-l -F)
      for tok in "${OBS_ARR[@]}"; do
        BATCH_GREP_ARGS+=(-e "$tok")
      done
      [[ -n "$TARGET_REF" ]] && BATCH_GREP_ARGS+=("$TARGET_COMMIT_SHA")
      BATCH_GREP_ARGS+=(-- . ':(exclude).b3/ship' ':(exclude).b3/research-ship' ':(exclude).b3/autodev')

      if run_git_cmd "$REPO_ROOT" "${BATCH_GREP_ARGS[@]}"; then batch_code=0; else batch_code=$?; fi
      if [[ "$batch_code" -gt 1 ]]; then
        echo "MECHANICAL_FAIL: git grep failed for obsoletes: $(git_err_detail)"
        exit 1
      fi
      BATCH_HIT_FILES=()
      BATCH_HIT_SEEN="|"
      if [[ "$batch_code" -eq 0 && -n "$_GIT_STDOUT" ]]; then
        obs_cprefix="${TARGET_COMMIT_SHA}:"
        while IFS= read -r g_row; do
          g_row="$(trim_str "$g_row")"
          [[ -n "$g_row" ]] || continue
          if [[ -n "$TARGET_REF" && "$g_row" == "${obs_cprefix}"* ]]; then
            g_row="${g_row#${obs_cprefix}}"
          fi
          g_row="$(norm_path "$g_row")"
          [[ -n "$g_row" ]] || continue
          is_checkpoint_dir "$g_row" && continue
          if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$g_row" "${IGNORE_ARR[@]}"; then continue; fi
          if [[ "$BATCH_HIT_SEEN" != *"|${g_row}|"* ]]; then
            BATCH_HIT_SEEN+="${g_row}|"
            BATCH_HIT_FILES+=("$g_row")
          fi
        done <<< "$_GIT_STDOUT"
      fi

      re_obs_dd2='(^|/)\.\.(/|$)'
      for tok in "${OBS_ARR[@]}"; do
        norm_tok="$(norm_path "$tok")"
        exists_path=false
        if [[ -n "$norm_tok" ]]; then
          if [[ -n "$TARGET_REF" ]]; then
            if [[ "$norm_tok" == -* || "$norm_tok" == *:* || "$norm_tok" =~ $re_obs_dd2 ]]; then
              if run_git_cmd_quiet "$REPO_ROOT" cat-file -e "${TARGET_COMMIT_SHA}:${norm_tok}"; then
                exists_path=true
              fi
            elif [[ "$OBS_EXISTING_PACKED" == *"|${norm_tok}|"* ]]; then
              exists_path=true
            fi
          elif [[ -e "${REPO_ROOT}/${norm_tok}" ]]; then
            exists_path=true
          fi
        fi
        grep_count=0
        if [[ ${#BATCH_HIT_FILES[@]} -gt 0 ]]; then
          if [[ ${#OBS_ARR[@]} -eq 1 ]]; then
            grep_count=${#BATCH_HIT_FILES[@]}
          else
            SINGLE_GREP_ARGS=(grep)
            [[ -z "$TARGET_REF" ]] && SINGLE_GREP_ARGS+=(--untracked)
            SINGLE_GREP_ARGS+=(-l -F -e "$tok")
            [[ -n "$TARGET_REF" ]] && SINGLE_GREP_ARGS+=("$TARGET_COMMIT_SHA")
            SINGLE_GREP_ARGS+=(-- "${BATCH_HIT_FILES[@]}")
            if run_git_cmd "$REPO_ROOT" "${SINGLE_GREP_ARGS[@]}"; then s_code=0; else s_code=$?; fi
            if [[ "$s_code" -gt 1 ]]; then
              echo "MECHANICAL_FAIL: git grep failed for obsolete '$tok': $(git_err_detail)"
              exit 1
            fi
            if [[ "$s_code" -eq 0 && -n "$_GIT_STDOUT" ]]; then
              obs_cprefix="${TARGET_COMMIT_SHA}:"
              while IFS= read -r g_row; do
                g_row="$(trim_str "$g_row")"
                [[ -n "$g_row" ]] || continue
                if [[ -n "$TARGET_REF" && "$g_row" == "${obs_cprefix}"* ]]; then
                  g_row="${g_row#${obs_cprefix}}"
                fi
                g_row="$(norm_path "$g_row")"
                [[ -n "$g_row" ]] || continue
                is_checkpoint_dir "$g_row" && continue
                if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$g_row" "${IGNORE_ARR[@]}"; then continue; fi
                grep_count=$((grep_count + 1))
              done <<< "$_GIT_STDOUT"
            fi
          fi
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

    _in_all_changed_fs() {
      local cand="$1" gp
      [[ ${#ALL_CHANGED[@]} -gt 0 ]] || return 1
      for gp in "${ALL_CHANGED[@]}"; do
        if paths_equal_fs "$gp" "$cand"; then
          return 0
        fi
      done
      return 1
    }

    OV_STATUS=""
    OV_VIOLATIONS_OUT=""
    if [[ "$HAS_WAVE_SPECS" == "true" ]]; then
      if [[ "$IS_ATTRIBUTING" != "true" ]]; then
        OV_STATUS="UNVERIFIED_COMBINED_ONLY"
        OV_VIOLATIONS_OUT="unverified"
      elif [[ "$HAS_WORKER_CHANGES" == "true" ]]; then
        IGNORE_PACKED=""
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]]; then
          IGNORE_PACKED="$(IFS='|'; printf '%s' "${IGNORE_ARR[*]}")"
        fi
        OV_VIOLATIONS=()
        ATTRIBUTED_PATHS=()
        WC_PRESENT_IDS="|"
        re_mc_b3='^\.b3(/|$)'
        re_mc_git='(^|/)\.git(/|$)'
        re_mc_gitmodules='(^|/)\.gitmodules$'
        for ((wci = 0; wci < ${#WC_IDS[@]}; wci++)); do
          tid="${WC_IDS[$wci]}"
          WC_PRESENT_IDS+="${tid}|"
          wc_packed="${WC_PACKED[$wci]}"
          [[ -n "$wc_packed" ]] || continue
          tid_owned=""
          for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
            if [[ "${WS_IDS[$wsi]}" == "$tid" ]]; then
              tid_owned="${WS_PACKED[$wsi]}"
              break
            fi
          done
          IFS='|' read -ra wp_arr <<< "$wc_packed"
          for wp in "${wp_arr[@]}"; do
            [[ -n "$wp" ]] || continue
            ATTRIBUTED_PATHS+=("$wp")
            wp_low="$(printf '%s' "$wp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            if [[ "$wp_low" =~ $re_mc_b3 || "$wp_low" =~ $re_mc_git || "$wp_low" =~ $re_mc_gitmodules ]] || _mc_prot_match_ci "$wp"; then
              OV_VIOLATIONS+=("${wp}(${tid}->protected)")
              continue
            fi
            if [[ -n "$IGNORE_PACKED" ]] && ownership_path_match "$wp" "$IGNORE_PACKED"; then
              OV_VIOLATIONS+=("${wp}(${tid}->user_dirty)")
              continue
            fi
            if [[ -n "$tid_owned" ]] && ownership_path_match "$wp" "$tid_owned"; then
              if ! _in_all_changed_fs "$wp"; then
                OV_VIOLATIONS+=("${wp}(${tid}->phantom)")
              fi
              continue
            fi
            OTHER_OWNERS=()
            for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
              other_tid="${WS_IDS[$wsi]}"
              [[ "$other_tid" == "$tid" ]] && continue
              if [[ -n "${WS_PACKED[$wsi]}" ]] && ownership_path_match "$wp" "${WS_PACKED[$wsi]}"; then
                OTHER_OWNERS+=("$other_tid")
              fi
            done
            if [[ ${#OTHER_OWNERS[@]} -gt 0 ]]; then
              first_other="$(printf '%s\n' "${OTHER_OWNERS[@]}" | LC_ALL=C sort | head -n 1)"
              OV_VIOLATIONS+=("${wp}(${tid}->${first_other})")
            else
              OV_VIOLATIONS+=("${wp}(${tid}->unowned)")
            fi
          done
        done
        if [[ ${#ALL_CHANGED[@]} -gt 0 ]]; then
          for gp in "${ALL_CHANGED[@]}"; do
            is_attrib="false"
            if [[ ${#ATTRIBUTED_PATHS[@]} -gt 0 ]]; then
              for ap in "${ATTRIBUTED_PATHS[@]}"; do
                if paths_equal_fs "$gp" "$ap"; then
                  is_attrib="true"
                  break
                fi
              done
            fi
            if [[ "$is_attrib" != "true" ]]; then
              OV_VIOLATIONS+=("${gp}(unattributed)")
            fi
          done
        fi
        if [[ ${#PROTECTED_VIOLATIONS[@]} -gt 0 ]]; then
          for pv in "${PROTECTED_VIOLATIONS[@]}"; do OV_VIOLATIONS+=("${pv}(protected)"); done
        fi
        if [[ ${#DIRTY_TAMPER_LIST[@]} -gt 0 ]]; then
          for dt in "${DIRTY_TAMPER_LIST[@]}"; do OV_VIOLATIONS+=("${dt}(dirty_tamper)"); done
        fi
        MISSING_WORKERS=()
        for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
          if [[ "$WC_PRESENT_IDS" != *"|${WS_IDS[$wsi]}|"* ]]; then
            MISSING_WORKERS+=("${WS_IDS[$wsi]}(missing_worker)")
          fi
        done
        if [[ ${#OV_VIOLATIONS[@]} -gt 0 ]]; then
          OV_STATUS="VIOLATION"
          OV_VIOLATIONS_OUT="$(printf '%s\n' "${OV_VIOLATIONS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        elif [[ ${#MISSING_WORKERS[@]} -gt 0 ]]; then
          OV_STATUS="PARTIAL_ATTRIBUTION"
          OV_VIOLATIONS_OUT="$(printf '%s\n' "${MISSING_WORKERS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        else
          OV_STATUS="CALLER_ATTRIBUTED"
          OV_VIOLATIONS_OUT="none"
        fi
      else
        # --worker-roots verified per-worker attribution
        check_worktree_identity "$REPO_ROOT" "missing_repo_root" "not_a_git_repo" "true"
        PARENT_TOP_NORM="$_WT_TOP_NORM"
        PARENT_COMMON="$_WT_COMMON_DIR"

        SEEN_WT_TOPS=("$PARENT_TOP_NORM")
        IGNORE_PACKED=""
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]]; then
          IGNORE_PACKED="$(IFS='|'; printf '%s' "${IGNORE_ARR[*]}")"
        fi
        OV_VIOLATIONS=()
        ATTRIBUTED_PATHS=()
        WR_PRESENT_IDS="|"
        re_mc_b3='^\.b3(/|$)'
        re_mc_git='(^|/)\.git(/|$)'
        re_mc_gitmodules='(^|/)\.gitmodules$'

        for ((wri = 0; wri < ${#WR_IDS[@]}; wri++)); do
          tid="${WR_IDS[$wri]}"
          WR_PRESENT_IDS+="${tid}|"
          wt_raw_p="${WR_ROOTS[$wri]}"
          [[ -n "$wt_raw_p" ]] || continue

          check_worktree_identity "$wt_raw_p" "missing_worker_root" "worker_not_git" "true"
          W_LOGICAL="$_WT_LOGICAL"
          W_TOP_NORM="$_WT_TOP_NORM"
          W_COMMON="$_WT_COMMON_DIR"
          W_GIT_DIR="$_WT_GIT_DIR"
          W_HEAD="$_WT_HEAD"

          W_MID="$(check_git_mid_operation "$W_LOGICAL")"
          if [[ -n "$W_MID" ]]; then
            echo "WORKTREE_UNSAFE: git_op_in_progress(${W_MID})"
            exit 2
          fi
          if ! paths_equal_fs "$W_COMMON" "$PARENT_COMMON"; then
            echo "WORKTREE_UNSAFE: peer_repo_mismatch(expected=${PARENT_COMMON},actual=${W_COMMON})"
            exit 2
          fi
          if paths_equal_fs "$W_GIT_DIR" "$W_COMMON" || worktree_roots_overlap "$W_TOP_NORM" "$PARENT_TOP_NORM"; then
            echo "WORKTREE_UNSAFE: not_isolated_linked_worktree(parent=${PARENT_TOP_NORM},worker=${W_TOP_NORM})"
            exit 2
          fi
          for prev_wt in "${SEEN_WT_TOPS[@]}"; do
            if worktree_roots_overlap "$W_TOP_NORM" "$prev_wt"; then
              echo "WORKTREE_UNSAFE: duplicate_or_nested_worktree(${W_TOP_NORM})"
              exit 2
            fi
          done
          SEEN_WT_TOPS+=("$W_TOP_NORM")

          if ! run_git_cmd_quiet "$W_TOP_NORM" merge-base --is-ancestor "$BASE_SHA" "$W_HEAD"; then
            echo "WORKTREE_UNSAFE: base_not_ancestor_of_worker(task=${tid},base=${BASE_SHA},head=${W_HEAD})"
            exit 2
          fi

          W_CHANGED=()
          W_SEEN=$'\x1f'
          _W_CANDS=()
          run_git_paths_z "$W_TOP_NORM" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --no-renames --name-only -z "$BASE_SHA" -- || exit 1
          [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _W_CANDS+=("${_GIT_PATHS_Z[@]}")
          run_git_paths_z "$W_TOP_NORM" "names" "MECHANICAL_FAIL" "" -- diff --no-ext-diff --cached --no-renames --name-only -z "$BASE_SHA" -- || exit 1
          [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _W_CANDS+=("${_GIT_PATHS_Z[@]}")
          run_git_paths_z "$W_TOP_NORM" "names" "MECHANICAL_FAIL" "" -- ls-files --others --exclude-standard -z || exit 1
          [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _W_CANDS+=("${_GIT_PATHS_Z[@]}")
          for wp in ${_W_CANDS[@]+"${_W_CANDS[@]}"}; do
            [[ -n "$wp" ]] || continue
            is_checkpoint_dir "$wp" && continue
            if [[ "$W_SEEN" != *$'\x1f'"${wp}"$'\x1f'* ]]; then
              W_SEEN+="${wp}"$'\x1f'
              W_CHANGED+=("$wp")
            fi
          done

          tid_owned=""
          for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
            if [[ "${WS_IDS[$wsi]}" == "$tid" ]]; then
              tid_owned="${WS_PACKED[$wsi]}"
              break
            fi
          done

          if [[ ${#W_CHANGED[@]} -gt 0 ]]; then
            for wp in "${W_CHANGED[@]}"; do
              ATTRIBUTED_PATHS+=("$wp")
              wp_low="$(printf '%s' "$wp" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
              if [[ "$wp_low" =~ $re_mc_b3 || "$wp_low" =~ $re_mc_git || "$wp_low" =~ $re_mc_gitmodules ]] || _mc_prot_match_ci "$wp"; then
                OV_VIOLATIONS+=("${wp}(${tid}->protected)")
                continue
              fi
              if [[ -n "$IGNORE_PACKED" ]] && ownership_path_match "$wp" "$IGNORE_PACKED"; then
                OV_VIOLATIONS+=("${wp}(${tid}->user_dirty)")
                continue
              fi
              if [[ -z "$tid_owned" ]] || ! ownership_path_match "$wp" "$tid_owned"; then
                OTHER_OWNERS=()
                for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
                  other_tid="${WS_IDS[$wsi]}"
                  [[ "$other_tid" == "$tid" ]] && continue
                  if [[ -n "${WS_PACKED[$wsi]}" ]] && ownership_path_match "$wp" "${WS_PACKED[$wsi]}"; then
                    OTHER_OWNERS+=("$other_tid")
                  fi
                done
                if [[ ${#OTHER_OWNERS[@]} -gt 0 ]]; then
                  first_other="$(printf '%s\n' "${OTHER_OWNERS[@]}" | LC_ALL=C sort | head -n 1)"
                  OV_VIOLATIONS+=("${wp}(${tid}->${first_other})")
                else
                  OV_VIOLATIONS+=("${wp}(${tid}->unowned)")
                fi
                continue
              fi
              if ! _in_all_changed_fs "$wp"; then
                OV_VIOLATIONS+=("${wp}(${tid}->content_mismatch)")
                continue
              fi
              wt_state="$(get_effective_repo_path_state "$W_TOP_NORM" "$wp" "MECHANICAL_FAIL")" || exit 1
              root_state="$(get_effective_repo_path_state "$REPO_ROOT" "$wp" "MECHANICAL_FAIL")" || exit 1
              if [[ "$wt_state" == "UNSAFE_REPARSE" || "$root_state" == "UNSAFE_REPARSE" || "$wt_state" == "INDEX_WT_DIVERGED" || "$root_state" == "INDEX_WT_DIVERGED" || "$wt_state" != "$root_state" ]]; then
                OV_VIOLATIONS+=("${wp}(${tid}->content_mismatch)")
              fi
            done
          fi
        done

        if [[ ${#ALL_CHANGED[@]} -gt 0 ]]; then
          for gp in "${ALL_CHANGED[@]}"; do
            is_attrib="false"
            if [[ ${#ATTRIBUTED_PATHS[@]} -gt 0 ]]; then
              for ap in "${ATTRIBUTED_PATHS[@]}"; do
                if paths_equal_fs "$gp" "$ap"; then
                  is_attrib="true"
                  break
                fi
              done
            fi
            if [[ "$is_attrib" != "true" ]]; then
              OV_VIOLATIONS+=("${gp}(unattributed)")
            fi
          done
        fi
        if [[ ${#PROTECTED_VIOLATIONS[@]} -gt 0 ]]; then
          for pv in "${PROTECTED_VIOLATIONS[@]}"; do OV_VIOLATIONS+=("${pv}(protected)"); done
        fi
        if [[ ${#DIRTY_TAMPER_LIST[@]} -gt 0 ]]; then
          for dt in "${DIRTY_TAMPER_LIST[@]}"; do OV_VIOLATIONS+=("${dt}(dirty_tamper)"); done
        fi
        MISSING_WORKERS=()
        for ((wsi = 0; wsi < ${#WS_IDS[@]}; wsi++)); do
          if [[ "$WR_PRESENT_IDS" != *"|${WS_IDS[$wsi]}|"* ]]; then
            MISSING_WORKERS+=("${WS_IDS[$wsi]}(missing_worker)")
          fi
        done
        if [[ ${#OV_VIOLATIONS[@]} -gt 0 ]]; then
          OV_STATUS="VIOLATION"
          OV_VIOLATIONS_OUT="$(printf '%s\n' "${OV_VIOLATIONS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        elif [[ ${#MISSING_WORKERS[@]} -gt 0 ]]; then
          OV_STATUS="PARTIAL_ATTRIBUTION"
          OV_VIOLATIONS_OUT="$(printf '%s\n' "${MISSING_WORKERS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        else
          OV_STATUS="VERIFIED_PER_WORKER"
          OV_VIOLATIONS_OUT="none"
        fi
      fi
    fi

    SC_OUT="none"
    [[ ${#SCOPE_CREEP[@]} -gt 0 ]] && SC_OUT="$(printf '%s\n' "${SCOPE_CREEP[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    LO_OUT="none"
    [[ ${#LEFTOVER_HITS[@]} -gt 0 ]] && LO_OUT="$(IFS=','; echo "${LEFTOVER_HITS[*]}")"
    OB_OUT="none"
    [[ ${#OBS_HITS[@]} -gt 0 ]] && OB_OUT="$(printf '%s\n' "${OBS_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    SF_OUT="none"
    [[ ${#SAFETY_HITS[@]} -gt 0 ]] && SF_OUT="$(printf '%s\n' "${SAFETY_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    PV_OUT="none"
    [[ ${#PROTECTED_VIOLATIONS[@]} -gt 0 ]] && PV_OUT="$(printf '%s\n' "${PROTECTED_VIOLATIONS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    DT_OUT="none"
    [[ ${#DIRTY_TAMPER_LIST[@]} -gt 0 ]] && DT_OUT="$(printf '%s\n' "${DIRTY_TAMPER_LIST[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"

    printf 'scope_creep=%s\nleftovers=%s\nobsolete_hits=%s\nsafety_hits=%s\n' "$SC_OUT" "$LO_OUT" "$OB_OUT" "$SF_OUT"
    if [[ "$HAS_PROTECTED_ARG" == "true" ]]; then
      printf 'protected_violations=%s\n' "$PV_OUT"
    fi
    if [[ "$HAS_DIRTY_DIGESTS_ARG" == "true" ]]; then
      printf 'dirty_tamper=%s\n' "$DT_OUT"
    fi
    if [[ "$HAS_WAVE_SPECS" == "true" ]]; then
      printf 'ownership_verification=%s\nownership_violations=%s\n' "$OV_STATUS" "$OV_VIOLATIONS_OUT"
    fi
    OV_OK="true"
    if [[ "$HAS_WAVE_SPECS" == "true" ]]; then
      case "$OV_STATUS" in
        UNVERIFIED_COMBINED_ONLY|CALLER_ATTRIBUTED|VERIFIED_PER_WORKER) OV_OK="true" ;;
        *) OV_OK="false" ;;
      esac
    fi
    if [[ "$SC_OUT" == "none" && "$LO_OUT" == "none" && "$OB_OUT" == "none" && "$SF_OUT" == "none" && "$PV_OUT" == "none" && "$DT_OUT" == "none" && "$OV_OK" == "true" ]]; then
      echo "MECHANICAL_OK"
      exit 0
    fi
    echo "MECHANICAL_FINDINGS"
    exit 2
    ;;

  check-wave)
    REPO_ROOT="."
    WAVE_SPECS=""
    WAVE_READS=""
    EXPECTED_BASE_SHA=""
    PARTITION="false"
    MAX_CONCURRENCY="3"
    PROTECTED_PATHS=""
    CHECK_DIRTY_SCOPE="false"
    IGNORE_DIRTY_PATHS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
        --wave-specs) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; WAVE_SPECS="$2"; shift 2 ;;
        --wave-reads) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; WAVE_READS="$2"; shift 2 ;;
        --expected-base-sha) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; EXPECTED_BASE_SHA="$2"; shift 2 ;;
        --partition) PARTITION="true"; shift ;;
        --max-concurrency) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; MAX_CONCURRENCY="$2"; shift 2 ;;
        --protected-paths) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; PROTECTED_PATHS="$2"; shift 2 ;;
        --check-dirty-scope) CHECK_DIRTY_SCOPE="true"; shift ;;
        --ignore-dirty-paths) [[ $# -ge 2 ]] || { echo "WAVE_FAIL: missing value for $1"; exit 1; }; IGNORE_DIRTY_PATHS="$2"; shift 2 ;;
        *) echo "WAVE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    WAVE_SPECS="$(trim_str "$WAVE_SPECS")"
    [[ -n "$WAVE_SPECS" ]] || { echo "WAVE_FAIL: missing --wave-specs"; exit 1; }
    [[ -n "$REPO_ROOT" ]] || { echo "WAVE_FAIL: missing --repo-root"; exit 1; }
    MAX_CONCURRENCY="$(trim_str "$MAX_CONCURRENCY")"
    if [[ ! "$MAX_CONCURRENCY" =~ ^[1-4]$ ]]; then
      echo "WAVE_FAIL: --max-concurrency must be between 1 and 4"
      exit 1
    fi
    REPO_LOGICAL="$(_normalize_logical_abs_path "$REPO_ROOT" || true)"
    if [[ -n "$REPO_LOGICAL" ]]; then
      SYM_ROOT_HIT="$(find_symlink_in_hierarchy "$REPO_LOGICAL" || true)"
      if [[ -n "$SYM_ROOT_HIT" ]]; then
        echo "WAVE_FAIL: unsafe symlink or junction alias in path '.'"
        exit 1
      fi
    fi

    EXPECTED_BASE_SHA="$(trim_str "$EXPECTED_BASE_SHA")"
    if [[ -n "$EXPECTED_BASE_SHA" ]]; then
      MID_OP="$(check_git_mid_operation "$REPO_ROOT")"
      if [[ -n "$MID_OP" ]]; then
        echo "WAVE_BASE_MISMATCH: git_op_in_progress($MID_OP)"
        exit 2
      fi
      if run_git_cmd "$REPO_ROOT" rev-parse HEAD; then
        ACT_HEAD="$(trim_str "$_GIT_STDOUT")"
      else
        ACT_HEAD=""
      fi
      if [[ -z "$ACT_HEAD" ]]; then
        echo "WAVE_BASE_MISMATCH: git rev-parse HEAD failed"
        exit 2
      fi
      if [[ "$ACT_HEAD" != "$EXPECTED_BASE_SHA" ]]; then
        echo "WAVE_BASE_MISMATCH: expected=${EXPECTED_BASE_SHA} actual=${ACT_HEAD}"
        exit 2
      fi
    fi

    REPO_EXISTS="false"
    if [[ -d "$REPO_ROOT" ]]; then
      REPO_EXISTS="true"
    fi
    detect_repo_case_insensitive "$REPO_ROOT"
    _B3_IS_CASE_INSENSITIVE_FS="$_REPO_CASE_INSENSITIVE"

    parse_wave_task_map "$WAVE_SPECS" "$REPO_ROOT" "WAVE_FAIL" "WaveSpecs" "--wave-specs" true "$PARTITION" true ""
    TASK_IDS=("${_WTM_IDS[@]}")
    TASK_PATHS_PACKED=("${_WTM_PACKED[@]}")
    TASK_PATHS_LOW_PACKED=("${_WTM_LOW_PACKED[@]}")
    TOTAL_PATHS="$_WTM_TOTAL_PATHS"
    TASK_READS_PACKED=()
    TASK_READS_LOW_PACKED=()
    for ((ti_init = 0; ti_init < ${#TASK_IDS[@]}; ti_init++)); do
      TASK_READS_PACKED+=("")
      TASK_READS_LOW_PACKED+=("")
    done

    n_tasks="${#TASK_IDS[@]}"
    READ_SEEN_IDS=()
    WAVE_READS="$(trim_str "$WAVE_READS")"
    if [[ -n "$WAVE_READS" ]]; then
      _had_noglob_wr=false
      case "$-" in
        *f*) _had_noglob_wr=true ;;
      esac
      set -f
      RENTRIES=()
      IFS=';' read -r -d '' -a RENTRIES < <(printf '%s\0' "$WAVE_READS") || true
      if ! $_had_noglob_wr; then set +f; fi
      if [[ ${#RENTRIES[@]} -gt 0 ]]; then
        for entry in "${RENTRIES[@]}"; do
          trim_e="$(trim_str "$entry")"
          [[ -z "$trim_e" ]] && continue
          if [[ "$trim_e" != *"="* ]]; then
            echo "WAVE_FAIL: invalid WaveReads entry '$trim_e' (expected TaskId=path1,path2)"
            exit 1
          fi
          rtid="$(trim_str "${trim_e%%=*}")"
          rcsv="${trim_e#*=}"
          [[ -n "$rtid" ]] || { echo "WAVE_FAIL: empty task id in WaveReads '$trim_e'"; exit 1; }
          if ! is_valid_wave_task_id "$rtid"; then
            echo "WAVE_FAIL: invalid task id '$rtid'"
            exit 1
          fi
          if [[ ${#READ_SEEN_IDS[@]} -gt 0 ]]; then
            for prev_rt in "${READ_SEEN_IDS[@]}"; do
              if [[ "$prev_rt" == "$rtid" ]]; then
                echo "WAVE_FAIL: duplicate task id '$rtid' in WaveReads"
                exit 1
              fi
            done
          fi
          rt_idx=-1
          for ((ti_idx = 0; ti_idx < n_tasks; ti_idx++)); do
            if [[ "${TASK_IDS[$ti_idx]}" == "$rtid" ]]; then
              rt_idx=$ti_idx
              break
            fi
          done
          if [[ $rt_idx -lt 0 ]]; then
            echo "WAVE_FAIL: unknown task id '$rtid' in WaveReads"
            exit 1
          fi
          READ_SEEN_IDS+=("$rtid")
          parse_wave_paths "$rcsv" false false
          if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
            if [[ "$REPO_EXISTS" == "true" ]]; then
              for rp in "${_WAVE_PARSED_PATHS[@]}"; do
                if ! check_wave_path_containment "$REPO_ROOT" "$rp"; then
                  echo "WAVE_FAIL: unsafe symlink or junction alias in path '$rp'"
                  exit 1
                fi
              done
            fi
            rpacked="$(IFS='|'; printf '%s' "${_WAVE_PARSED_PATHS[*]}")"
            if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
              rlow_packed="$(printf '%s' "$rpacked" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            else
              rlow_packed="$rpacked"
            fi
            TASK_READS_PACKED[$rt_idx]="$rpacked"
            TASK_READS_LOW_PACKED[$rt_idx]="$rlow_packed"
          fi
        done
      fi
    fi

    PROTECTED_LIST=()
    PROTECTED_LOW_LIST=()
    PROTECTED_PATHS="$(trim_str "$PROTECTED_PATHS")"
    if [[ -n "$PROTECTED_PATHS" ]]; then
      parse_wave_paths "$PROTECTED_PATHS" false false
      if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
        for prot in "${_WAVE_PARSED_PATHS[@]}"; do
          if [[ "$prot" == "." ]]; then
            echo "WAVE_FAIL: invalid protected path '.'"
            exit 1
          fi
          if [[ "$REPO_EXISTS" == "true" ]] && ! check_wave_path_containment "$REPO_ROOT" "$prot"; then
            echo "WAVE_FAIL: unsafe symlink or junction alias in path '$prot'"
            exit 1
          fi
          PROTECTED_LIST+=("$prot")
          if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
            PROTECTED_LOW_LIST+=("$(printf '%s' "$prot" | LC_ALL=C tr '[:upper:]' '[:lower:]')")
          else
            PROTECTED_LOW_LIST+=("$prot")
          fi
        done
      fi
    fi

    if [[ ${#PROTECTED_LIST[@]} -gt 0 ]]; then
      for ((i = 0; i < n_tasks; i++)); do
        [[ -n "${TASK_PATHS_PACKED[$i]}" ]] || continue
        IFS='|' read -ra pi_arr <<< "${TASK_PATHS_PACKED[$i]}"
        IFS='|' read -ra pi_low_arr <<< "${TASK_PATHS_LOW_PACKED[$i]}"
        for ((pi_k = 0; pi_k < ${#pi_arr[@]}; pi_k++)); do
          for ((pk = 0; pk < ${#PROTECTED_LIST[@]}; pk++)); do
            wave_paths_overlap_cmp "${pi_low_arr[$pi_k]}" "${PROTECTED_LOW_LIST[$pk]}"
            if [[ "$_WAVE_OV" == "equal" || "$_WAVE_OV" == "prefix" ]]; then
              echo "WAVE_FAIL: protected path '${pi_arr[$pi_k]}' overlaps single-writer boundary '${PROTECTED_LIST[$pk]}'"
              exit 1
            fi
          done
        done
      done
    fi

    HAS_CONFLICT=()
    for ((idx = 0; idx < n_tasks * n_tasks; idx++)); do
      HAS_CONFLICT+=(0)
    done
    CONFLICTS=()
    for ((i = 0; i < n_tasks; i++)); do
      [[ -n "${TASK_PATHS_PACKED[$i]}" ]] || continue
      for ((j = i + 1; j < n_tasks; j++)); do
        [[ -n "${TASK_PATHS_PACKED[$j]}" ]] || continue
        ti="${TASK_IDS[$i]}"
        tj="${TASK_IDS[$j]}"
        IFS='|' read -ra pi_arr <<< "${TASK_PATHS_PACKED[$i]}"
        IFS='|' read -ra pj_arr <<< "${TASK_PATHS_PACKED[$j]}"
        IFS='|' read -ra pi_low_arr <<< "${TASK_PATHS_LOW_PACKED[$i]}"
        IFS='|' read -ra pj_low_arr <<< "${TASK_PATHS_LOW_PACKED[$j]}"
        for ((pi_k = 0; pi_k < ${#pi_arr[@]}; pi_k++)); do
          for ((pj_k = 0; pj_k < ${#pj_arr[@]}; pj_k++)); do
            wave_paths_overlap_cmp "${pi_low_arr[$pi_k]}" "${pj_low_arr[$pj_k]}"
            if [[ "$_WAVE_OV" == "equal" ]]; then
              CONFLICTS+=("${pi_arr[$pi_k]}(${ti},${tj})")
              HAS_CONFLICT[$((i * n_tasks + j))]=1
              HAS_CONFLICT[$((j * n_tasks + i))]=1
            elif [[ "$_WAVE_OV" == "prefix" ]]; then
              CONFLICTS+=("${pi_arr[$pi_k]}<->${pj_arr[$pj_k]}(${ti},${tj})")
              HAS_CONFLICT[$((i * n_tasks + j))]=1
              HAS_CONFLICT[$((j * n_tasks + i))]=1
            fi
          done
        done
      done
    done

    for ((i = 0; i < n_tasks; i++)); do
      [[ -n "${TASK_PATHS_PACKED[$i]}" ]] || continue
      ti="${TASK_IDS[$i]}"
      IFS='|' read -ra pi_arr <<< "${TASK_PATHS_PACKED[$i]}"
      IFS='|' read -ra pi_low_arr <<< "${TASK_PATHS_LOW_PACKED[$i]}"
      for ((j = 0; j < n_tasks; j++)); do
        [[ $i -eq $j ]] && continue
        [[ -z "${TASK_READS_PACKED[$j]}" ]] && continue
        tj="${TASK_IDS[$j]}"
        IFS='|' read -ra rj_arr <<< "${TASK_READS_PACKED[$j]}"
        IFS='|' read -ra rj_low_arr <<< "${TASK_READS_LOW_PACKED[$j]}"
        for ((pi_k = 0; pi_k < ${#pi_arr[@]}; pi_k++)); do
          for ((rj_k = 0; rj_k < ${#rj_arr[@]}; rj_k++)); do
            wave_paths_overlap_cmp "${pi_low_arr[$pi_k]}" "${rj_low_arr[$rj_k]}"
            if [[ "$_WAVE_OV" == "equal" ]]; then
              CONFLICTS+=("rw:${pi_arr[$pi_k]}(${ti}->${tj})")
              HAS_CONFLICT[$((i * n_tasks + j))]=1
              HAS_CONFLICT[$((j * n_tasks + i))]=1
            elif [[ "$_WAVE_OV" == "prefix" ]]; then
              CONFLICTS+=("rw:${pi_arr[$pi_k]}<->${rj_arr[$rj_k]}(${ti}->${tj})")
              HAS_CONFLICT[$((i * n_tasks + j))]=1
              HAS_CONFLICT[$((j * n_tasks + i))]=1
            fi
          done
        done
      done
    done

    IGNORE_DIRTY_PATHS="$(trim_str "$IGNORE_DIRTY_PATHS")"
    RUN_DIRTY_CHECK="false"
    if [[ "$CHECK_DIRTY_SCOPE" == "true" || -n "$IGNORE_DIRTY_PATHS" || ( "$PARTITION" == "true" && -n "$EXPECTED_BASE_SHA" ) ]]; then
      RUN_DIRTY_CHECK="true"
    fi
    DIRTY_BLOCKED=()
    for ((i = 0; i < n_tasks; i++)); do
      DIRTY_BLOCKED+=(0)
    done
    USER_DIRTY_ARR=()
    UNEXPECTED_DIRTY_ARR=()
    DIRTY_SCOPE_VAL="not_checked"
    USER_DIRTY_CSV="none"
    UNEXPECTED_DIRTY_CSV="none"
    BLOCKED_TASKS_CSV="none"

    if [[ "$RUN_DIRTY_CHECK" == "true" ]]; then
      IGNORE_LIST=()
      IGNORE_LOW_LIST=()
      if [[ -n "$IGNORE_DIRTY_PATHS" ]]; then
        parse_wave_paths "$IGNORE_DIRTY_PATHS" false false
        if [[ ${#_WAVE_PARSED_PATHS[@]} -gt 0 ]]; then
          for ign in "${_WAVE_PARSED_PATHS[@]}"; do
            if [[ "$ign" == "." ]]; then
              echo "WAVE_FAIL: invalid ignore-dirty path '.'"
              exit 1
            fi
            if [[ "$REPO_EXISTS" == "true" ]] && ! check_wave_path_containment "$REPO_ROOT" "$ign"; then
              echo "WAVE_FAIL: unsafe symlink or junction alias in path '$ign'"
              exit 1
            fi
            IGNORE_LIST+=("$ign")
            if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
              IGNORE_LOW_LIST+=("$(printf '%s' "$ign" | LC_ALL=C tr '[:upper:]' '[:lower:]')")
            else
              IGNORE_LOW_LIST+=("$ign")
            fi
          done
        fi
      fi

      MID_OP_DIRTY="$(check_git_mid_operation "$REPO_ROOT")"
      if [[ -n "$MID_OP_DIRTY" ]]; then
        echo "WAVE_BASE_MISMATCH: git_op_in_progress(${MID_OP_DIRTY})"
        exit 2
      fi

      _WAVE_DIRTY_CANDS=()
      if ! run_git_paths_z "$REPO_ROOT" "names" "WAVE_BASE_MISMATCH" "" -- diff --no-ext-diff --no-renames --name-only -z HEAD --; then exit 2; fi
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _WAVE_DIRTY_CANDS+=("${_GIT_PATHS_Z[@]}")
      if ! run_git_paths_z "$REPO_ROOT" "names" "WAVE_BASE_MISMATCH" "" -- diff --no-ext-diff --no-renames --cached --name-only -z --; then exit 2; fi
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _WAVE_DIRTY_CANDS+=("${_GIT_PATHS_Z[@]}")
      if ! run_git_paths_z "$REPO_ROOT" "names" "WAVE_BASE_MISMATCH" "" -- ls-files --others --exclude-standard -z; then exit 2; fi
      [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]] && _WAVE_DIRTY_CANDS+=("${_GIT_PATHS_Z[@]}")

      DIRTY_RAW_ARR=()
      for dp in ${_WAVE_DIRTY_CANDS[@]+"${_WAVE_DIRTY_CANDS[@]}"}; do
        [[ -n "$dp" ]] || continue
        is_checkpoint_dir "$dp" && continue
        DIRTY_RAW_ARR+=("$dp")
      done

      DIRTY_SORTED=()
      if [[ ${#DIRTY_RAW_ARR[@]} -gt 0 ]]; then
        while IFS= read -r sd; do
          [[ -n "$sd" ]] && DIRTY_SORTED+=("$sd")
        done < <(printf '%s\n' "${DIRTY_RAW_ARR[@]}" | LC_ALL=C sort -u)
      fi

      DIRTY_TAGGED_PATHS=()
      DIRTY_TAGGED_LOW_PATHS=()
      DIRTY_TAGGED_TAGS=()
      if [[ ${#DIRTY_SORTED[@]} -gt 0 ]]; then
        for d in "${DIRTY_SORTED[@]}"; do
          if [[ "$_B3_IS_CASE_INSENSITIVE_FS" == "true" ]]; then
            d_cmp="$(printf '%s' "$d" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          else
            d_cmp="$d"
          fi
          is_user_dirty="false"
          if [[ ${#IGNORE_LIST[@]} -gt 0 ]]; then
            for ((ik = 0; ik < ${#IGNORE_LIST[@]}; ik++)); do
              ign_orig="${IGNORE_LIST[$ik]}"
              ign_cmp="${IGNORE_LOW_LIST[$ik]}"
              if [[ "$d_cmp" == "$ign_cmp" || ( "$ign_orig" != "." && "$d_cmp" == "$ign_cmp/"* ) ]]; then
                is_user_dirty="true"
                break
              fi
            done
          fi
          if [[ "$is_user_dirty" == "true" ]]; then
            USER_DIRTY_ARR+=("$d")
            DIRTY_TAGGED_PATHS+=("$d")
            DIRTY_TAGGED_LOW_PATHS+=("$d_cmp")
            DIRTY_TAGGED_TAGS+=("USER_DIRTY")
          else
            UNEXPECTED_DIRTY_ARR+=("$d")
            DIRTY_TAGGED_PATHS+=("$d")
            DIRTY_TAGGED_LOW_PATHS+=("$d_cmp")
            DIRTY_TAGGED_TAGS+=("UNEXPECTED_DIRTY")
          fi
        done
      fi

      for ((i = 0; i < n_tasks; i++)); do
        ti="${TASK_IDS[$i]}"
        TASK_ALL_LOW=()
        if [[ -n "${TASK_PATHS_LOW_PACKED[$i]}" ]]; then
          IFS='|' read -ra tw_low <<< "${TASK_PATHS_LOW_PACKED[$i]}"
          for twp in "${tw_low[@]}"; do
            TASK_ALL_LOW+=("$twp")
          done
        fi
        if [[ -n "${TASK_READS_LOW_PACKED[$i]}" ]]; then
          IFS='|' read -ra tr_low <<< "${TASK_READS_LOW_PACKED[$i]}"
          for trp in "${tr_low[@]}"; do
            TASK_ALL_LOW+=("$trp")
          done
        fi

        if [[ ${#DIRTY_TAGGED_PATHS[@]} -gt 0 && ${#TASK_ALL_LOW[@]} -gt 0 ]]; then
          for ((dk = 0; dk < ${#DIRTY_TAGGED_PATHS[@]}; dk++)); do
            d_orig="${DIRTY_TAGGED_PATHS[$dk]}"
            d_cmp="${DIRTY_TAGGED_LOW_PATHS[$dk]}"
            d_tag="${DIRTY_TAGGED_TAGS[$dk]}"
            for tp_cmp in "${TASK_ALL_LOW[@]}"; do
              wave_paths_overlap_cmp "$d_cmp" "$tp_cmp"
              if [[ "$_WAVE_OV" == "equal" || "$_WAVE_OV" == "prefix" ]]; then
                DIRTY_BLOCKED[$i]=1
                CONFLICTS+=("dirty:${d_orig}(${d_tag}->${ti})")
                break
              fi
            done
          done
        fi
      done

      if [[ ${#UNEXPECTED_DIRTY_ARR[@]} -gt 0 ]]; then
        DIRTY_SCOPE_VAL="unexpected"
      elif [[ ${#USER_DIRTY_ARR[@]} -gt 0 ]]; then
        DIRTY_SCOPE_VAL="user_only"
      else
        DIRTY_SCOPE_VAL="clean"
      fi
      if [[ ${#USER_DIRTY_ARR[@]} -gt 0 ]]; then
        USER_DIRTY_CSV="$(IFS=','; printf '%s' "${USER_DIRTY_ARR[*]}")"
      fi
      if [[ ${#UNEXPECTED_DIRTY_ARR[@]} -gt 0 ]]; then
        UNEXPECTED_DIRTY_CSV="$(IFS=','; printf '%s' "${UNEXPECTED_DIRTY_ARR[*]}")"
      fi
      BLOCKED_NAMES=()
      for ((i = 0; i < n_tasks; i++)); do
        if [[ "${DIRTY_BLOCKED[$i]}" == "1" ]]; then
          BLOCKED_NAMES+=("${TASK_IDS[$i]}")
        fi
      done
      if [[ ${#BLOCKED_NAMES[@]} -gt 0 ]]; then
        BLOCKED_TASKS_CSV="$(IFS=','; printf '%s' "${BLOCKED_NAMES[*]}")"
      fi
    fi

    if [[ "$PARTITION" != "true" ]]; then
      if [[ "$RUN_DIRTY_CHECK" == "true" && ${#UNEXPECTED_DIRTY_ARR[@]} -gt 0 ]]; then
        echo "WAVE_BASE_MISMATCH: unexpected_dirty(${UNEXPECTED_DIRTY_CSV})"
        exit 2
      fi
      ANY_DIRTY_BLOCKED="false"
      for ((i = 0; i < n_tasks; i++)); do
        if [[ "${DIRTY_BLOCKED[$i]}" == "1" ]]; then
          ANY_DIRTY_BLOCKED="true"
          break
        fi
      done
      if [[ "$ANY_DIRTY_BLOCKED" == "true" || ${#CONFLICTS[@]} -gt 0 ]]; then
        C_STR="$(printf '%s\n' "${CONFLICTS[@]}" | LC_ALL=C sort -u | awk 'NR>1{printf ", "} {printf "%s", $0}')"
        echo "WAVE_CONFLICT: ${C_STR}"
        exit 2
      fi
      printf 'WAVE_OK: disjoint (%d tasks, %d paths)\n' "$n_tasks" "$TOTAL_PATHS"
      exit 0
    fi

    ELIGIBLE_INDICES=()
    for ((i = 0; i < n_tasks; i++)); do
      if [[ "${DIRTY_BLOCKED[$i]}" != "1" ]]; then
        ELIGIBLE_INDICES+=("$i")
      fi
    done
    ELIGIBLE_COUNT="${#ELIGIBLE_INDICES[@]}"
    BLOCKED_COUNT=$((n_tasks - ELIGIBLE_COUNT))

    WAVE_MEMBERS=()
    WAVE_COUNTS=()
    if [[ $ELIGIBLE_COUNT -gt 0 ]]; then
      for i in "${ELIGIBLE_INDICES[@]}"; do
        placed="false"
        w_len="${#WAVE_MEMBERS[@]}"
        for ((w = 0; w < w_len; w++)); do
          if [[ "${WAVE_COUNTS[$w]}" -ge "$MAX_CONCURRENCY" ]]; then
            continue
          fi
          ok="true"
          IFS=',' read -ra mem_arr <<< "${WAVE_MEMBERS[$w]}"
          for m in "${mem_arr[@]}"; do
            if [[ "${HAS_CONFLICT[$((i * n_tasks + m))]}" == "1" ]]; then
              ok="false"
              break
            fi
          done
          if [[ "$ok" == "true" ]]; then
            WAVE_MEMBERS[$w]="${WAVE_MEMBERS[$w]},$i"
            WAVE_COUNTS[$w]=$((WAVE_COUNTS[$w] + 1))
            placed="true"
            break
          fi
        done
        if [[ "$placed" != "true" ]]; then
          WAVE_MEMBERS+=("$i")
          WAVE_COUNTS+=(1)
        fi
      done
    fi

    W_COUNT="${#WAVE_MEMBERS[@]}"
    MAX_PARALLEL=0
    for ((w = 0; w < W_COUNT; w++)); do
      if [[ "${WAVE_COUNTS[$w]}" -gt "$MAX_PARALLEL" ]]; then
        MAX_PARALLEL="${WAVE_COUNTS[$w]}"
      fi
    done
    if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
      CONFLICTS_CSV="$(printf '%s\n' "${CONFLICTS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    else
      CONFLICTS_CSV="none"
    fi

    printf 'dirty_scope=%s\n' "$DIRTY_SCOPE_VAL"
    printf 'user_dirty=%s\n' "$USER_DIRTY_CSV"
    printf 'unexpected_dirty=%s\n' "$UNEXPECTED_DIRTY_CSV"
    printf 'blocked_tasks=%s\n' "$BLOCKED_TASKS_CSV"
    printf 'wave_count=%d\n' "$W_COUNT"
    printf 'max_concurrency=%d\n' "$MAX_CONCURRENCY"
    printf 'max_parallel=%d\n' "$MAX_PARALLEL"
    printf 'conflicts=%s\n' "$CONFLICTS_CSV"

    for ((w = 0; w < W_COUNT; w++)); do
      cnt="${WAVE_COUNTS[$w]}"
      IFS=',' read -ra mem_arr <<< "${WAVE_MEMBERS[$w]}"
      t_names=()
      for m in "${mem_arr[@]}"; do
        t_names+=("${TASK_IDS[$m]}")
      done
      tasks_csv="$(IFS=','; printf '%s' "${t_names[*]}")"
      if [[ "$cnt" -ge 2 ]]; then
        printf 'wave|%d|PARALLEL|agents=%d|tasks=%s|reason=independent_ready_tasks\n' "$((w + 1))" "$cnt" "$tasks_csv"
      else
        t="${mem_arr[0]}"
        if [[ "$ELIGIBLE_COUNT" -eq 1 ]]; then
          w_reason="single_ready_task"
        else
          bounded="false"
          for ((k = 0; k < w; k++)); do
            if [[ "${WAVE_COUNTS[$k]}" -eq "$MAX_CONCURRENCY" ]]; then
              prior_conflict="false"
              IFS=',' read -ra prior_arr <<< "${WAVE_MEMBERS[$k]}"
              for pm in "${prior_arr[@]}"; do
                if [[ "${HAS_CONFLICT[$((t * n_tasks + pm))]}" == "1" ]]; then
                  prior_conflict="true"
                  break
                fi
              done
              if [[ "$prior_conflict" != "true" ]]; then
                bounded="true"
                break
              fi
            fi
          done
          if [[ "$bounded" != "true" && "$MAX_CONCURRENCY" -eq 1 ]]; then
            any_conf="false"
            for u in "${ELIGIBLE_INDICES[@]}"; do
              if [[ $u -ne $t && "${HAS_CONFLICT[$((t * n_tasks + u))]}" == "1" ]]; then
                any_conf="true"
                break
              fi
            done
            if [[ "$any_conf" != "true" ]]; then
              bounded="true"
            fi
          fi
          if [[ "$bounded" == "true" ]]; then
            w_reason="bounded_concurrency"
          else
            w_reason="shared_write_conflict"
          fi
        fi
        printf 'wave|%d|SEQUENTIAL|agents=1|tasks=%s|reason=%s\n' "$((w + 1))" "$tasks_csv" "$w_reason"
      fi
    done

    ELIGIBLE_HAS_PAIR_CONFLICT="false"
    for ((ei = 0; ei < ELIGIBLE_COUNT; ei++)); do
      for ((ej = ei + 1; ej < ELIGIBLE_COUNT; ej++)); do
        if [[ "${HAS_CONFLICT[$((ELIGIBLE_INDICES[$ei] * n_tasks + ELIGIBLE_INDICES[$ej]))]}" == "1" ]]; then
          ELIGIBLE_HAS_PAIR_CONFLICT="true"
          break
        fi
      done
      [[ "$ELIGIBLE_HAS_PAIR_CONFLICT" == "true" ]] && break
    done

    if [[ "$RUN_DIRTY_CHECK" == "true" && ${#UNEXPECTED_DIRTY_ARR[@]} -gt 0 ]]; then
      printf 'WAVE_BASE_MISMATCH: unexpected_dirty(%s)\n' "$UNEXPECTED_DIRTY_CSV"
      exit 2
    elif [[ "$ELIGIBLE_COUNT" -eq 0 ]]; then
      printf 'WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=dirty_scope_conflict\n'
      exit 2
    elif [[ "$BLOCKED_COUNT" -gt 0 ]]; then
      if [[ "$MAX_PARALLEL" -ge 2 ]]; then
        printf 'WAVE_PARTITIONED: waves=%d max_parallel=%d reason=dirty_scope_partial_split\n' "$W_COUNT" "$MAX_PARALLEL"
        exit 0
      else
        printf 'WAVE_SEQUENTIAL: waves=%d max_parallel=1 reason=dirty_scope_partial_split\n' "$W_COUNT"
        if [[ "$ELIGIBLE_HAS_PAIR_CONFLICT" != "true" ]]; then exit 0; else exit 2; fi
      fi
    elif [[ "$W_COUNT" -eq 1 && "$CONFLICTS_CSV" == "none" ]]; then
      printf 'WAVE_OK: disjoint (%d tasks, %d paths)\n' "$n_tasks" "$TOTAL_PATHS"
      exit 0
    elif [[ "$MAX_PARALLEL" -ge 2 ]]; then
      if [[ "$CONFLICTS_CSV" == "none" ]]; then
        term_reason="bounded_concurrency_split"
      else
        term_reason="conflicting_wave_split"
      fi
      printf 'WAVE_PARTITIONED: waves=%d max_parallel=%d reason=%s\n' "$W_COUNT" "$MAX_PARALLEL" "$term_reason"
      exit 0
    elif [[ "$CONFLICTS_CSV" == "none" ]]; then
      printf 'WAVE_SEQUENTIAL: waves=%d max_parallel=1 reason=bounded_concurrency\n' "$W_COUNT"
      exit 0
    else
      printf 'WAVE_SEQUENTIAL: waves=%d max_parallel=1 reason=shared_write_conflict\n' "$W_COUNT"
      exit 2
    fi
    ;;

  new-run)
    REPO_ROOT="."
    SLUG=""
    TS=""
    NAMESPACE="ship"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --slug) SLUG="${2:-}"; shift 2 ;;
        --timestamp) TS="${2:-}"; shift 2 ;;
        --namespace) NAMESPACE="${2:-}"; shift 2 ;;
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

    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    NS_DIR="$(resolve_namespace_dir "$REPO_ROOT" "$NAMESPACE")"
    RUNS_DIR="${NS_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$NS_DIR" || -L "$RUNS_DIR" ]]; then
      echo "NEW_RUN_FAIL: runs directory is a link"
      exit 1
    fi
    mkdir -p "$RUNS_DIR"

    BASE_ID="${TS}-${CLEAN_SLUG}"
    CANDIDATE="$BASE_ID"
    SUFFIX=2
    while [[ -e "${RUNS_DIR}/${CANDIDATE}" ]]; do
      CANDIDATE="${BASE_ID}-${SUFFIX}"
      SUFFIX=$((SUFFIX + 1))
    done

    mkdir -p "${RUNS_DIR}/${CANDIDATE}"
    write_atomic_lf_file "${NS_DIR}/CURRENT" "${CANDIDATE}"$'\n'
    printf '%s\n' "$CANDIDATE"
    ;;

  resolve-run)
    REPO_ROOT="."
    RUN_ID=""
    NAMESPACE="ship"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        --namespace) NAMESPACE="${2:-}"; shift 2 ;;
        *) echo "RESOLVE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    NS_TRIM="$(trim_str "$NAMESPACE")"
    [[ -n "$NS_TRIM" ]] || NS_TRIM="ship"
    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    NS_DIR="$(resolve_namespace_dir "$REPO_ROOT" "$NS_TRIM")"
    NS_REL=".b3/${NS_TRIM}"
    RUNS_DIR="${NS_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$NS_DIR" || -L "$RUNS_DIR" ]]; then
      echo "RESOLVE_FAIL: runs directory is a link"
      exit 1
    fi
    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    AUTODEV_RUNS_DIR="${AUTODEV_DIR}/runs"

    if [[ -n "$RUN_ID" ]]; then
      RUN_ID="$(trim_str "$RUN_ID")"
      valid_run_id "$RUN_ID" || { echo "RESOLVE_FAIL: invalid run id '$RUN_ID'"; exit 1; }
      if [[ -d "${RUNS_DIR}/${RUN_ID}" && ! -L "${RUNS_DIR}/${RUN_ID}" ]]; then
        printf '%s/runs/%s\n' "$NS_REL" "$RUN_ID"
        exit 0
      fi
      if [[ "$NS_TRIM" == "ship" && -d "${AUTODEV_RUNS_DIR}/${RUN_ID}" && ! -L "${AUTODEV_RUNS_DIR}/${RUN_ID}" ]]; then
        printf '.b3/autodev/runs/%s\n' "$RUN_ID"
        exit 0
      fi
      echo "RESOLVE_FAIL: run not found '$RUN_ID'"
      exit 1
    fi

    CUR_FILE="${NS_DIR}/CURRENT"
    if [[ -f "$CUR_FILE" && ! -L "$CUR_FILE" ]]; then
      CUR_ID="$(read_current_run_id "$NS_DIR")"
      valid_run_id "$CUR_ID" || { echo "RESOLVE_FAIL: CURRENT contains invalid run id '$CUR_ID'"; exit 1; }
      [[ -d "${RUNS_DIR}/${CUR_ID}" && ! -L "${RUNS_DIR}/${CUR_ID}" ]] || { echo "RESOLVE_FAIL: CURRENT points to missing run '$CUR_ID'"; exit 1; }
      printf '%s/runs/%s\n' "$NS_REL" "$CUR_ID"
      exit 0
    fi

    if [[ "$NS_TRIM" == "ship" ]]; then
      if [[ -f "${NS_DIR}/progress.md" ]]; then
        printf '.b3/ship\n'
        exit 0
      fi

      AD_CUR_FILE="${AUTODEV_DIR}/CURRENT"
      if [[ -f "$AD_CUR_FILE" ]]; then
        AD_CUR_ID="$(read_current_run_id "$AUTODEV_DIR")"
        valid_run_id "$AD_CUR_ID" || { echo "RESOLVE_FAIL: CURRENT contains invalid run id '$AD_CUR_ID'"; exit 1; }
        [[ -d "${AUTODEV_RUNS_DIR}/${AD_CUR_ID}" ]] || { echo "RESOLVE_FAIL: CURRENT points to missing run '$AD_CUR_ID'"; exit 1; }
        printf '.b3/autodev/runs/%s\n' "$AD_CUR_ID"
        exit 0
      fi

      if [[ -f "${AUTODEV_DIR}/progress.md" ]]; then
        printf '.b3/autodev\n'
        exit 0
      fi
    fi

    echo "NO_ACTIVE_RUN"
    exit 1
    ;;

  list-runs)
    REPO_ROOT="."
    NAMESPACE="ship"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --namespace) NAMESPACE="${2:-}"; shift 2 ;;
        *) echo "LIST_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    NS_TRIM="$(trim_str "$NAMESPACE")"
    [[ -n "$NS_TRIM" ]] || NS_TRIM="ship"
    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    NS_DIR="$(resolve_namespace_dir "$REPO_ROOT" "$NS_TRIM")"
    RUNS_DIR="${NS_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$NS_DIR" || -L "$RUNS_DIR" ]]; then
      echo "LIST_FAIL: runs directory is a link"
      exit 1
    fi
    CUR_ID="$(read_current_run_id "$NS_DIR")"

    RUN_NAMES=()
    if [[ -d "$RUNS_DIR" ]]; then
      while IFS= read -r d; do
        [[ -n "$d" ]] && [[ ! -L "${RUNS_DIR}/${d}" ]] && RUN_NAMES+=("$d")
      done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)
    fi

    if [[ ${#RUN_NAMES[@]} -gt 0 ]]; then
      for id in "${RUN_NAMES[@]}"; do
        ST="$(read_run_status "${RUNS_DIR}/${id}")"
        MARK="  "
        if [[ -n "$CUR_ID" && "$id" == "$CUR_ID" ]]; then
          MARK="* "
        fi
        printf '%s%s [%s]\n' "$MARK" "$id" "$ST"
      done
      exit 0
    fi

    if [[ "$NS_TRIM" == "ship" ]]; then
      if [[ -f "${NS_DIR}/progress.md" ]]; then
        ST="$(read_run_status "$NS_DIR")"
        printf '* legacy [%s]\n' "$ST"
        exit 0
      fi

      AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
      AUTODEV_RUNS_DIR="${AUTODEV_DIR}/runs"
      AD_CUR_ID="$(read_current_run_id "$AUTODEV_DIR")"
      AD_NAMES=()
      if [[ -d "$AUTODEV_RUNS_DIR" ]]; then
        while IFS= read -r d; do
          [[ -n "$d" ]] && AD_NAMES+=("$d")
        done < <(find "$AUTODEV_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)
      fi
      if [[ ${#AD_NAMES[@]} -gt 0 ]]; then
        for id in "${AD_NAMES[@]}"; do
          ST="$(read_run_status "${AUTODEV_RUNS_DIR}/${id}")"
          MARK="  "
          if [[ -n "$AD_CUR_ID" && "$id" == "$AD_CUR_ID" ]]; then
            MARK="* "
          fi
          printf '%s%s [%s] (legacy-autodev)\n' "$MARK" "$id" "$ST"
        done
        exit 0
      fi
      if [[ -f "${AUTODEV_DIR}/progress.md" ]]; then
        ST="$(read_run_status "$AUTODEV_DIR")"
        printf '* legacy (legacy-autodev) [%s]\n' "$ST"
        exit 0
      fi
    fi

    echo "NO_RUNS"
    ;;

  prune)
    REPO_ROOT="."
    KEEP=10
    NAMESPACE="ship"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --keep) KEEP="${2:-}"; shift 2 ;;
        --namespace) NAMESPACE="${2:-}"; shift 2 ;;
        *) echo "PRUNE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    if [[ ! "$KEEP" =~ ^[0-9]+$ ]]; then
      echo "PRUNE_FAIL: --keep must be >= 0"
      exit 1
    fi

    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    NS_DIR="$(resolve_namespace_dir "$REPO_ROOT" "$NAMESPACE")"
    RUNS_DIR="${NS_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$NS_DIR" || -L "$RUNS_DIR" ]]; then
      echo "PRUNE_FAIL: runs directory is a link"
      exit 1
    fi
    if [[ ! -d "$RUNS_DIR" ]]; then
      echo "PRUNE_OK: 0 removed"
      exit 0
    fi

    CUR_ID="$(read_current_run_id "$NS_DIR")"
    RUN_NAMES=()
    while IFS= read -r d; do
      [[ -n "$d" ]] && [[ ! -L "${RUNS_DIR}/${d}" ]] && RUN_NAMES+=("$d")
    done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort -r)

    PASS_COUNT=0
    PRUNED=()
    if [[ ${#RUN_NAMES[@]} -gt 0 ]]; then
      for id in "${RUN_NAMES[@]}"; do
        ST="$(read_run_status "${RUNS_DIR}/${id}")"
        if [[ "$ST" == "PASS" ]]; then
          PASS_COUNT=$((PASS_COUNT + 1))
          if [[ $PASS_COUNT -gt $KEEP && "$id" != "$CUR_ID" ]]; then
            remove_dir_tree_safely "${RUNS_DIR}/${id}"
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

  verify-run)
    REPO_ROOT="."
    VERIFY_CMD=""
    RECEIPT_PATH=""
    TASK_ID=""
    SCOPE=""
    RELEVANT_PATHS=""
    LOG_PATH=""
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --verify-cmd) VERIFY_CMD="${2:-}"; shift 2 ;;
        --receipt-path) RECEIPT_PATH="${2:-}"; shift 2 ;;
        --task-id) TASK_ID="${2:-}"; shift 2 ;;
        --scope) SCOPE="${2:-}"; shift 2 ;;
        --relevant-paths) RELEVANT_PATHS="${2:-}"; shift 2 ;;
        --log-path) LOG_PATH="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "VERIFY_RUN_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    [[ -n "$(trim_str "$VERIFY_CMD")" ]] || { echo "VERIFY_RUN_FAIL: missing --verify-cmd"; exit 1; }
    [[ -n "$(trim_str "$RECEIPT_PATH")" ]] || { echo "VERIFY_RUN_FAIL: missing --receipt-path"; exit 1; }

    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      echo "VERIFY_RUN_FAIL: invalid --repo-root"
      exit 1
    fi

    if ! validate_repo_write_path "$REPO_ROOT" "$RECEIPT_PATH" || [[ -d "$_SAFE_FULL" ]]; then
      echo "VERIFY_RUN_FAIL: invalid receipt_path"
      exit 1
    fi
    FULL_RECEIPT="$_SAFE_FULL"
    RECEIPT_REL="$_SAFE_REL"

    if [[ -n "$(trim_str "$LOG_PATH")" ]]; then
      CAND_LOG="$LOG_PATH"
    else
      CAND_LOG="${RECEIPT_REL}.log"
    fi
    if ! validate_repo_write_path "$REPO_ROOT" "$CAND_LOG" || [[ -d "$_SAFE_FULL" ]]; then
      echo "VERIFY_RUN_FAIL: invalid log_path"
      exit 1
    fi
    FULL_LOG="$_SAFE_FULL"
    LOG_REL="$_SAFE_REL"

    EFF_TASK="$(trim_str "$(printf '%s' "$TASK_ID" | LC_ALL=C tr '\r\n' '  ')")"
    [[ -n "$EFF_TASK" ]] || EFF_TASK="unknown"
    EFF_SCOPE="$(trim_str "$(printf '%s' "$SCOPE" | LC_ALL=C tr '\r\n' '  ')")"
    [[ -n "$EFF_SCOPE" ]] || EFF_SCOPE="scoped"

    split_path_csv_checked "$IGNORE_DIRTY" "VERIFY_RUN_FAIL" "true"
    split_path_csv_checked "$RELEVANT_PATHS" "VERIFY_RUN_FAIL" "false"

    mkdir -p "$(dirname "$FULL_RECEIPT")"

    make_temp_file "b3-verify-out" OUT_TMP
    START_MS="$(now_epoch_ms)"
    set +e
    (cd "$REPO_ROOT" && sh -c "$VERIFY_CMD") >"$OUT_TMP" 2>&1
    CMD_EXIT=$?
    set -e
    END_MS="$(now_epoch_ms)"
    DURATION_MS=$((END_MS - START_MS))
    [[ $DURATION_MS -lt 0 ]] && DURATION_MS=0

    OUT_LINES="$(awk 'END{print NR}' "$OUT_TMP")"
    if ! FP_OUT="$(compute_tree_fingerprint "$REPO_ROOT" "$RELEVANT_PATHS" "$IGNORE_DIRTY")"; then
      echo "$FP_OUT"
      rm -f "$OUT_TMP"
      exit 1
    fi
    {
      IFS= read -r FP_HEAD
      IFS= read -r FP_TREE
      IFS= read -r FP_PATHS
    } <<< "$FP_OUT"

    STATUS_VAL="FAIL"
    [[ $CMD_EXIT -eq 0 ]] && STATUS_VAL="PASS"

    LOG_DISP="none"
    if [[ $CMD_EXIT -ne 0 || "$OUT_LINES" -gt 35 ]]; then
      mkdir -p "$(dirname "$FULL_LOG")"
      TMP_LOG="${FULL_LOG}.tmp.$$.${RANDOM}"
      _CLEANUP_FILES+=("$TMP_LOG")
      LC_ALL=C tr -d '\r' < "$OUT_TMP" > "$TMP_LOG"
      mv -f "$TMP_LOG" "$FULL_LOG"
      LOG_DISP="$LOG_REL"
    fi

    SINGLE_CMD="$(normalize_cmd_str "$VERIFY_CMD")"
    TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    RECEIPT_BODY="schema=b3-verify-v1
task_id=${EFF_TASK}
scope=${EFF_SCOPE}
head_sha=${FP_HEAD}
tree_hash=${FP_TREE}
relevant_paths=${FP_PATHS}
exit_code=${CMD_EXIT}
status=${STATUS_VAL}
duration_ms=${DURATION_MS}
command=${SINGLE_CMD}
log_path=${LOG_DISP}
timestamp_utc=${TS_UTC}
"
    write_atomic_lf_file "$FULL_RECEIPT" "$RECEIPT_BODY"

    SHORT_TREE="${FP_TREE:0:12}"
    if [[ $CMD_EXIT -eq 0 ]]; then
      rm -f "$OUT_TMP"
      printf 'VERIFY_PASS: exit=0 tree=%s receipt=%s duration_ms=%s\n' "$SHORT_TREE" "$RECEIPT_REL" "$DURATION_MS"
      exit 0
    fi
    printf 'VERIFY_FAIL: exit=%s tree=%s receipt=%s log=%s duration_ms=%s\n' "$CMD_EXIT" "$SHORT_TREE" "$RECEIPT_REL" "$LOG_DISP" "$DURATION_MS"
    LC_ALL=C awk 'NR <= 35 { sub(/\r$/, ""); print } NR == 35 { exit }' "$OUT_TMP"
    rm -f "$OUT_TMP"
    exit 1
    ;;

  verify-check)
    REPO_ROOT="."
    RECEIPT_PATH=""
    IGNORE_DIRTY=""
    EXPECTED_CMD=""
    RELEVANT_PATHS=""
    TARGET_COMMIT_SHA=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --receipt-path) RECEIPT_PATH="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --expected-cmd) EXPECTED_CMD="${2:-}"; shift 2 ;;
        --relevant-paths) RELEVANT_PATHS="${2:-}"; shift 2 ;;
        --target-commit-sha)
          [[ $# -ge 2 && -n "${2// /}" ]] || { echo "VERIFY_CHECK_FAIL: missing value for $1" >&2; exit 1; }
          TARGET_COMMIT_SHA="$2"; shift 2 ;;
        *) echo "VERIFY_CHECK_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    split_path_csv_checked "$IGNORE_DIRTY" "VERIFY_CHECK_FAIL" "true"
    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid --repo-root"
      printf '%s\n' "$_VR_MSG"
      exit 1
    fi
    set +e
    run_verify_check "$REPO_ROOT" "$RECEIPT_PATH" "$IGNORE_DIRTY" "$EXPECTED_CMD" "$RELEVANT_PATHS" "$TARGET_COMMIT_SHA"
    RC=$?
    set -e
    printf '%s\n' "$_VR_MSG"
    exit "$RC"
    ;;

  symbol-check)
    REPO_ROOT="."
    BASE_SHA=""
    TARGET_REF=""
    IGNORE_DIRTY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        *) echo "SYMBOL_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    split_path_csv_checked "$IGNORE_DIRTY" "SYMBOL_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    resolve_scope_target_and_base "$REPO_ROOT" "$TARGET_REF" "$BASE_SHA" "SYMBOL_FAIL" "object" ${IGNORE_ARR[@]+"${IGNORE_ARR[@]}"}
    TARGET_REF="$_SCOPE_TARGET_REF"
    TARGET_COMMIT_SHA="$_SCOPE_TARGET_SHA"
    BASE_SHA="$_SCOPE_BASE_SHA"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-ext-diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-ext-diff --no-renames -U0 "$BASE_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    fi

    REM_KEYS=()
    REM_EXPS=()
    ADD_KEYS=()
    ADD_EXPS=()

    _sym_upsert() {
      local kind="$1" f="$2" s="$3" e="$4" idx
      if [[ "$kind" == "rem" ]]; then
        if [[ ${#REM_KEYS[@]} -gt 0 ]]; then
          for ((idx = 0; idx < ${#REM_KEYS[@]}; idx++)); do
            if [[ "${REM_KEYS[$idx]}" == "${f}|${s}" ]]; then
              [[ "$e" == "1" ]] && REM_EXPS[$idx]="1"
              return 0
            fi
          done
        fi
        REM_KEYS+=("${f}|${s}")
        REM_EXPS+=("$e")
      else
        if [[ ${#ADD_KEYS[@]} -gt 0 ]]; then
          for ((idx = 0; idx < ${#ADD_KEYS[@]}; idx++)); do
            if [[ "${ADD_KEYS[$idx]}" == "${f}|${s}" ]]; then
              [[ "$e" == "1" ]] && ADD_EXPS[$idx]="1"
              return 0
            fi
          done
        fi
        ADD_KEYS+=("${f}|${s}")
        ADD_EXPS+=("$e")
      fi
    }

    OLD_FILE=""
    NEW_FILE=""
    OLD_EXT=""
    NEW_EXT=""
    SKIP_OLD=true
    SKIP_NEW=true
    IN_HUNK=false
    while IFS= read -r ln; do
      ln="${ln%$'\r'}"
      if [[ "$ln" == "diff --git "* ]]; then
        OLD_FILE=""; NEW_FILE=""; OLD_EXT=""; NEW_EXT=""; SKIP_OLD=true; SKIP_NEW=true; IN_HUNK=false
        continue
      fi
      if ! $IN_HUNK && [[ "$ln" == "--- "* ]]; then
        if [[ "$ln" == "--- /dev/null" ]]; then
          OLD_FILE=""; OLD_EXT=""; SKIP_OLD=true
        else
          cand="${ln#--- }"
          cand="${cand#a/}"
          OLD_FILE="$(norm_path "$cand")"
          SKIP_OLD=false
          if [[ -z "$OLD_FILE" ]] || is_checkpoint_dir "$OLD_FILE" || is_noise_file "$OLD_FILE" || ! is_code_path "$OLD_FILE"; then
            SKIP_OLD=true
          elif [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$OLD_FILE" "${IGNORE_ARR[@]}"; then
            SKIP_OLD=true
          else
            OLD_EXT="$(get_code_ext_lower "$OLD_FILE")" || SKIP_OLD=true
          fi
        fi
        continue
      fi
      if ! $IN_HUNK && [[ "$ln" == "+++ "* ]]; then
        if [[ "$ln" == "+++ /dev/null" ]]; then
          NEW_FILE=""; NEW_EXT=""; SKIP_NEW=true
        else
          cand="${ln#+++ }"
          cand="${cand#b/}"
          NEW_FILE="$(norm_path "$cand")"
          SKIP_NEW=false
          if [[ -z "$NEW_FILE" ]] || is_checkpoint_dir "$NEW_FILE" || is_noise_file "$NEW_FILE" || ! is_code_path "$NEW_FILE"; then
            SKIP_NEW=true
          elif [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$NEW_FILE" "${IGNORE_ARR[@]}"; then
            SKIP_NEW=true
          else
            NEW_EXT="$(get_code_ext_lower "$NEW_FILE")" || SKIP_NEW=true
          fi
        fi
        continue
      fi
      if [[ "$ln" =~ ^@@\ -[0-9,]+\ \+[0-9,]+\ @@ ]]; then
        IN_HUNK=true
        continue
      fi
      if ! $IN_HUNK; then continue; fi
      if [[ "$ln" == "-"* ]] && ! $SKIP_OLD; then
        if extract_symbol_decl_ext "$OLD_EXT" "${ln#-}"; then
          _sym_upsert rem "$OLD_FILE" "$_SYM_NAME" "$_SYM_EXP"
        fi
      elif [[ "$ln" == "+"* ]] && ! $SKIP_NEW; then
        if extract_symbol_decl_ext "$NEW_EXT" "${ln#+}"; then
          _sym_upsert add "$NEW_FILE" "$_SYM_NAME" "$_SYM_EXP"
        fi
      fi
    done <<< "$DIFF_U0"

    if [[ -z "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "SYMBOL_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
      while IFS= read -r u; do
        u="$(norm_path "$u")"
        [[ -n "$u" ]] || continue
        is_checkpoint_dir "$u" && continue
        is_noise_file "$u" && continue
        is_code_path "$u" || continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
        [[ -f "${REPO_ROOT}/${u}" ]] || continue
        u_ext="$(get_code_ext_lower "$u")" || continue
        while IFS= read -r fl || [[ -n "$fl" ]]; do
          fl="${fl%$'\r'}"
          if extract_symbol_decl_ext "$u_ext" "$fl"; then
            _sym_upsert add "$u" "$_SYM_NAME" "$_SYM_EXP"
          fi
        done < "${REPO_ROOT}/${u}"
      done < <(printf '%s\n' "$UN_OUT" | LC_ALL=C sort -u)
    fi

    REMOVED_SYMS=()
    EXPORTED_REMOVED=()
    DANGLING_REFS=()
    ORPHAN_INTERNAL=()
    REM_CHECKED="|"

    _sym_find_exp() {
      local kind="$1" f="$2" s="$3" idx
      _SYM_FOUND_EXP="0"
      if [[ "$kind" == "add" ]]; then
        [[ ${#ADD_KEYS[@]} -gt 0 ]] || return 1
        for ((idx = 0; idx < ${#ADD_KEYS[@]}; idx++)); do
          if [[ "${ADD_KEYS[$idx]}" == "${f}|${s}" ]]; then
            _SYM_FOUND_EXP="${ADD_EXPS[$idx]}"
            return 0
          fi
        done
      else
        [[ ${#REM_KEYS[@]} -gt 0 ]] || return 1
        for ((idx = 0; idx < ${#REM_KEYS[@]}; idx++)); do
          if [[ "${REM_KEYS[$idx]}" == "${f}|${s}" ]]; then
            _SYM_FOUND_EXP="${REM_EXPS[$idx]}"
            return 0
          fi
        done
      fi
      return 1
    }

    _sym_exists_any() {
      local kind="$1" s="$2" idx
      _SYM_ANY_EXP="0"
      local found=1
      if [[ "$kind" == "add" ]]; then
        [[ ${#ADD_KEYS[@]} -gt 0 ]] || return 1
        for ((idx = 0; idx < ${#ADD_KEYS[@]}; idx++)); do
          if [[ "${ADD_KEYS[$idx]}" == *"|${s}" ]]; then
            found=0
            [[ "${ADD_EXPS[$idx]}" == "1" ]] && _SYM_ANY_EXP="1"
          fi
        done
      else
        [[ ${#REM_KEYS[@]} -gt 0 ]] || return 1
        for ((idx = 0; idx < ${#REM_KEYS[@]}; idx++)); do
          if [[ "${REM_KEYS[$idx]}" == *"|${s}" ]]; then
            found=0
            [[ "${REM_EXPS[$idx]}" == "1" ]] && _SYM_ANY_EXP="1"
          fi
        done
      fi
      return $found
    }

    if [[ ${#REM_KEYS[@]} -gt 0 ]]; then
      for ((idx = 0; idx < ${#REM_KEYS[@]}; idx++)); do
        k="${REM_KEYS[$idx]}"
        is_exp="${REM_EXPS[$idx]}"
        f="${k%%|*}"
        s_name="${k#*|}"
        in_same=false
        if _sym_find_exp add "$f" "$s_name"; then
          in_same=true
          if [[ "$is_exp" != "1" || "$_SYM_FOUND_EXP" == "1" ]]; then
            continue
          fi
        elif _sym_exists_any add "$s_name"; then
          if [[ "$is_exp" != "1" || "$_SYM_ANY_EXP" == "1" ]]; then
            continue
          fi
        fi
        REMOVED_SYMS+=("$s_name")
        [[ "$is_exp" == "1" ]] && EXPORTED_REMOVED+=("$s_name")
        if [[ "$REM_CHECKED" == *"|${s_name}|"* ]]; then continue; fi
        REM_CHECKED="${REM_CHECKED}${s_name}|"

        if [[ -n "$TARGET_REF" ]]; then
          if run_git_cmd "$REPO_ROOT" grep -w -F -l -e "$s_name" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3' ':(exclude)*.md'; then g_code=0; else g_code=$?; fi
        else
          if run_git_cmd "$REPO_ROOT" grep --untracked -w -F -l -e "$s_name" -- . ':(exclude).b3' ':(exclude)*.md'; then g_code=0; else g_code=$?; fi
        fi
        g_out="$_GIT_STDOUT"
        if [[ $g_code -gt 1 ]]; then
          echo "SYMBOL_FAIL: git grep failed for '$s_name': $(git_err_detail)"
          exit 1
        fi
        if [[ $g_code -eq 0 && -n "$g_out" ]]; then
          hit_files=()
          cprefix="${TARGET_COMMIT_SHA}:"
          while IFS= read -r row; do
            row="$(trim_str "$row")"
            [[ -n "$row" ]] || continue
            if [[ -n "$TARGET_REF" && "$row" == "${cprefix}"* ]]; then
              row="${row#${cprefix}}"
            fi
            np="$(norm_path "$row")"
            [[ -n "$np" ]] || continue
            is_checkpoint_dir "$np" && continue
            if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$np" "${IGNORE_ARR[@]}"; then continue; fi
            is_noise_file "$np" && continue
            is_code_path "$np" || continue
            if $in_same && [[ "$np" == "$f" ]]; then continue; fi
            hit_files+=("$np")
          done <<< "$g_out"
          if [[ ${#hit_files[@]} -gt 0 ]]; then
            f_cnt="$(printf '%s\n' "${hit_files[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
            if [[ $f_cnt -gt 0 ]]; then
              DANGLING_REFS+=("${s_name}(${f_cnt}f)")
            fi
          fi
        fi
      done
    fi

    if [[ ${#ADD_KEYS[@]} -gt 0 ]]; then
      for ((idx = 0; idx < ${#ADD_KEYS[@]}; idx++)); do
        k="${ADD_KEYS[$idx]}"
        is_exp="${ADD_EXPS[$idx]}"
        [[ "$is_exp" == "1" ]] && continue
        f="${k%%|*}"
        s_name="${k#*|}"
        is_test_path "$f" && continue
        _sym_exists_any rem "$s_name" && continue

        if [[ -n "$TARGET_REF" ]]; then
          if run_git_cmd "$REPO_ROOT" grep -w -F -n -e "$s_name" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3' ':(exclude)*.md'; then gn_code=0; else gn_code=$?; fi
        else
          if run_git_cmd "$REPO_ROOT" grep --untracked -w -F -n -e "$s_name" -- . ':(exclude).b3' ':(exclude)*.md'; then gn_code=0; else gn_code=$?; fi
        fi
        gn_out="$_GIT_STDOUT"
        if [[ $gn_code -gt 1 ]]; then
          echo "SYMBOL_FAIL: git grep -n failed for '$s_name': $(git_err_detail)"
          exit 1
        fi
        line_hits=0
        if [[ $gn_code -eq 0 && -n "$gn_out" ]]; then
          cprefix="${TARGET_COMMIT_SHA}:"
          while IFS= read -r row; do
            row="$(trim_str "$row")"
            [[ -n "$row" ]] || continue
            if [[ -n "$TARGET_REF" && "$row" == "${cprefix}"* ]]; then
              row="${row#${cprefix}}"
            fi
            [[ "$row" == *":"* ]] || continue
            np="$(norm_path "${row%%:*}")"
            [[ -n "$np" ]] || continue
            is_checkpoint_dir "$np" && continue
            if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$np" "${IGNORE_ARR[@]}"; then continue; fi
            is_noise_file "$np" && continue
            is_code_path "$np" || continue
            line_hits=$((line_hits + 1))
          done <<< "$gn_out"
        fi
        if [[ $line_hits -le 1 ]]; then
          ORPHAN_INTERNAL+=("${f}:${s_name}")
        fi
      done
    fi

    REM_OUT="none"
    [[ ${#REMOVED_SYMS[@]} -gt 0 ]] && REM_OUT="$(printf '%s\n' "${REMOVED_SYMS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    EXP_OUT="none"
    [[ ${#EXPORTED_REMOVED[@]} -gt 0 ]] && EXP_OUT="$(printf '%s\n' "${EXPORTED_REMOVED[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    DAN_OUT="none"
    [[ ${#DANGLING_REFS[@]} -gt 0 ]] && DAN_OUT="$(printf '%s\n' "${DANGLING_REFS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    ORP_OUT="none"
    [[ ${#ORPHAN_INTERNAL[@]} -gt 0 ]] && ORP_OUT="$(printf '%s\n' "${ORPHAN_INTERNAL[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"

    printf 'removed_symbols=%s\nexported_removed=%s\ndangling_refs=%s\norphan_internal=%s\n' "$REM_OUT" "$EXP_OUT" "$DAN_OUT" "$ORP_OUT"
    if [[ "$DAN_OUT" == "none" && "$ORP_OUT" == "none" ]]; then
      echo "SYMBOL_OK"
      exit 0
    fi
    echo "SYMBOL_FINDINGS"
    exit 2
    ;;

  check-worktree)
    REPO_ROOT="."
    EXPECTED_ROOT=""
    EXPECTED_BASE_SHA=""
    PEER_ROOTS=""
    REQUIRE_ISOLATED="false"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) [[ $# -ge 2 ]] || { echo "WORKTREE_FAIL: missing value for $1"; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
        --expected-root) [[ $# -ge 2 ]] || { echo "WORKTREE_FAIL: missing value for $1"; exit 1; }; EXPECTED_ROOT="$2"; shift 2 ;;
        --expected-base-sha) [[ $# -ge 2 ]] || { echo "WORKTREE_FAIL: missing value for $1"; exit 1; }; EXPECTED_BASE_SHA="$2"; shift 2 ;;
        --peer-roots) [[ $# -ge 2 ]] || { echo "WORKTREE_FAIL: missing value for $1"; exit 1; }; PEER_ROOTS="$2"; shift 2 ;;
        --require-isolated) REQUIRE_ISOLATED="true"; shift ;;
        *) echo "WORKTREE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    check_worktree_identity "$REPO_ROOT" "missing_repo_root" "not_a_git_repo" "true"
    ACTUAL_ROOT_NORM="$_WT_TOP_NORM"
    ACT_COMMON="$_WT_COMMON_DIR"
    ACT_GIT_DIR="$_WT_GIT_DIR"
    HEAD_RAW="$_WT_HEAD"

    MID_OP="$(check_git_mid_operation "$_WT_LOGICAL")"
    if [[ -n "$MID_OP" ]]; then
      echo "WORKTREE_UNSAFE: git_op_in_progress(${MID_OP})"
      exit 2
    fi

    IS_LINKED="true"
    if paths_equal_fs "$ACT_GIT_DIR" "$ACT_COMMON"; then
      IS_LINKED="false"
    fi

    PEER_ROOTS="$(trim_str "$PEER_ROOTS")"
    PEER_LIST=()
    if [[ -n "$PEER_ROOTS" && "$PEER_ROOTS" != "none" && "$PEER_ROOTS" != "[]" ]]; then
      while IFS= read -r p_item; do
        p_trim="$(trim_str "$p_item")"
        [[ -z "$p_trim" || "$p_trim" == "none" ]] && continue
        PEER_LIST+=("$p_trim")
      done < <(split_csv_lines "$PEER_ROOTS")
    fi

    EXPECTED_ROOT="$(trim_str "$EXPECTED_ROOT")"
    HAS_EXPECTED_ROOT="false"
    if [[ -n "$EXPECTED_ROOT" ]]; then
      HAS_EXPECTED_ROOT="true"
    fi
    if [[ "$REQUIRE_ISOLATED" == "true" && "$HAS_EXPECTED_ROOT" != "true" ]]; then
      echo "WORKTREE_UNSAFE: missing_expected_root_for_isolation"
      exit 2
    fi
    CHECK_ISOLATION="false"
    if [[ "$REQUIRE_ISOLATED" == "true" || ( "$HAS_EXPECTED_ROOT" == "true" && ${#PEER_LIST[@]} -gt 0 ) ]]; then
      CHECK_ISOLATION="true"
    fi

    EXP_TOP_NORM=""
    COMMON_SAME=false
    if [[ "$HAS_EXPECTED_ROOT" == "true" ]]; then
      check_worktree_identity "$EXPECTED_ROOT" "expected_root_missing" "expected_root_not_git" "false"
      EXP_TOP_NORM="$_WT_TOP_NORM"
      EXP_COMMON="$_WT_COMMON_DIR"

      TOP_SAME=false
      if paths_equal_fs "$ACTUAL_ROOT_NORM" "$EXP_TOP_NORM"; then TOP_SAME=true; fi
      if [[ -n "$ACT_COMMON" && -n "$EXP_COMMON" ]] && paths_equal_fs "$ACT_COMMON" "$EXP_COMMON"; then COMMON_SAME=true; fi
      if ! $TOP_SAME && ! $COMMON_SAME; then
        echo "WORKTREE_UNSAFE: root_mismatch(expected=${EXP_TOP_NORM},actual=${ACTUAL_ROOT_NORM})"
        exit 2
      fi
      if [[ "$CHECK_ISOLATION" == "true" ]]; then
        if worktree_roots_overlap "$ACTUAL_ROOT_NORM" "$EXP_TOP_NORM"; then
          echo "WORKTREE_UNSAFE: parent_root_reused_or_nested(parent=${EXP_TOP_NORM},worker=${ACTUAL_ROOT_NORM})"
          exit 2
        fi
        if [[ "$IS_LINKED" != "true" ]] || ! $COMMON_SAME; then
          echo "WORKTREE_UNSAFE: not_isolated_linked_worktree(parent=${EXP_TOP_NORM},worker=${ACTUAL_ROOT_NORM})"
          exit 2
        fi
      fi
    fi

    if [[ ${#PEER_LIST[@]} -gt 0 ]]; then
      SEEN_TOPS=("$ACTUAL_ROOT_NORM")
      for peer in "${PEER_LIST[@]}"; do
        check_worktree_identity "$peer" "missing_peer_root" "peer_not_git" "false"
        PEER_TOP_NORM="$_WT_TOP_NORM"
        PEER_COMMON="$_WT_COMMON_DIR"
        if ! paths_equal_fs "$ACT_COMMON" "$PEER_COMMON"; then
          echo "WORKTREE_UNSAFE: peer_repo_mismatch(expected=${ACT_COMMON},actual=${PEER_COMMON})"
          exit 2
        fi
        if [[ "$CHECK_ISOLATION" == "true" && "$HAS_EXPECTED_ROOT" == "true" ]]; then
          if worktree_roots_overlap "$PEER_TOP_NORM" "$EXP_TOP_NORM"; then
            echo "WORKTREE_UNSAFE: parent_root_reused_or_nested(parent=${EXP_TOP_NORM},worker=${PEER_TOP_NORM})"
            exit 2
          fi
        fi
        for prev_top in "${SEEN_TOPS[@]}"; do
          if worktree_roots_overlap "$PEER_TOP_NORM" "$prev_top"; then
            echo "WORKTREE_UNSAFE: duplicate_or_nested_worktree(${PEER_TOP_NORM})"
            exit 2
          fi
        done
        SEEN_TOPS+=("$PEER_TOP_NORM")
      done
    fi

    EXPECTED_BASE_SHA="$(trim_str "$EXPECTED_BASE_SHA")"
    if [[ -n "$EXPECTED_BASE_SHA" ]]; then
      if [[ "$HEAD_RAW" != "$EXPECTED_BASE_SHA" ]]; then
        echo "WORKTREE_UNSAFE: base_mismatch(expected=${EXPECTED_BASE_SHA},actual=${HEAD_RAW})"
        exit 2
      fi
    fi

    IS_ISOLATED="false"
    if [[ "$HAS_EXPECTED_ROOT" == "true" && "$COMMON_SAME" == "true" && "$IS_LINKED" == "true" ]] && ! worktree_roots_overlap "$ACTUAL_ROOT_NORM" "$EXP_TOP_NORM"; then
      IS_ISOLATED="true"
    fi
    printf 'WORKTREE_OK: root=%s head=%s common_dir=%s linked=%s isolated=%s\n' "$ACTUAL_ROOT_NORM" "$HEAD_RAW" "$ACT_COMMON" "$IS_LINKED" "$IS_ISOLATED"
    exit 0
    ;;

  review-inventory)
    REPO_ROOT="."
    BASE_SHA=""
    TARGET_REF=""
    IGNORE_DIRTY=""
    MAX_CONC=4
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --max-concurrency) MAX_CONC="${2:-4}"; shift 2 ;;
        *) echo "INVENTORY_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    split_path_csv_checked "$IGNORE_DIRTY" "INVENTORY_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    resolve_scope_target_and_base "$REPO_ROOT" "$TARGET_REF" "$BASE_SHA" "INVENTORY_FAIL" "object" ${IGNORE_ARR[@]+"${IGNORE_ARR[@]}"}
    TARGET_REF="$_SCOPE_TARGET_REF"
    TARGET_COMMIT_SHA="$_SCOPE_TARGET_SHA"
    BASE_SHA="$_SCOPE_BASE_SHA"

    INV_OUT=""
    if ! INV_OUT="$(run_scope_engine "$REPO_ROOT" "$BASE_SHA" "$TARGET_COMMIT_SHA" "$IGNORE_DIRTY" "$MAX_CONC" "INVENTORY_FAIL")"; then
      printf '%s\n' "$INV_OUT"
      exit 1
    fi

    parse_scope_engine_output "$INV_OUT"
    IS_EMPTY="$_SE_IS_EMPTY"; PART_ERR="$_SE_PART_ERR"; SIZE_CLASS="$_SE_SIZE_CLASS"; FILE_COUNT="$_SE_FILES"; TOTAL_LINES="$_SE_LINES"
    RISK_LEVEL="$_SE_RISK_LEVEL"; RISK_SIGNALS="$_SE_RISK_SIGNALS"; REC_SPECS="$_SE_REC_SPECS"; L1_SPECS="$_SE_L1_SPECS"; L1_SKIP="$_SE_L1_SKIP"
    CHANGE_TYPES="$_SE_CHANGE_TYPES"; CONTRACT_FILES="$_SE_CONTRACT_FILES"; GENERATED_FILES="$_SE_GENERATED_FILES"; TEST_FILES="$_SE_TEST_FILES"
    NF_OUT="$_SE_NOISE_FILES"; SPLIT_REC="$_SE_SPLIT_REC"; MC_OUT="$_SE_MAX_CONC"; UNIT_CNT="$_SE_UNIT_COUNT"
    UNITS_LINES=()
    if [[ ${#_SE_UNITS[@]} -gt 0 ]]; then UNITS_LINES=("${_SE_UNITS[@]}"); fi

    if [[ "$IS_EMPTY" == "true" ]]; then
      echo "EMPTY_DIFF"
      exit 2
    fi
    if [[ -n "$PART_ERR" ]]; then
      printf '%s\n' "$PART_ERR"
      exit 2
    fi

    printf 'size_class=%s\nfiles=%s\nlines=%s\nrisk_level=%s\nrisk_signals=%s\nrecommended_specialists=%s\nl1_specialists=%s\nl1_skip_rationale=%s\nchange_types=%s\ncontract_files=%s\ngenerated_files=%s\ntest_files=%s\nnoise_files=%s\nsplit_recommended=%s\nmax_concurrency=%s\nunit_count=%s\n' \
      "$SIZE_CLASS" "$FILE_COUNT" "$TOTAL_LINES" "$RISK_LEVEL" "$RISK_SIGNALS" "$REC_SPECS" "$L1_SPECS" "$L1_SKIP" "$CHANGE_TYPES" "$CONTRACT_FILES" "$GENERATED_FILES" "$TEST_FILES" "$NF_OUT" "$SPLIT_REC" "$MC_OUT" "$UNIT_CNT"
    if [[ ${#UNITS_LINES[@]} -gt 0 ]]; then
      for ul in "${UNITS_LINES[@]}"; do
        IFS=$'\t' read -r _tag uid grp ufc ulc urk usp usig ucsv <<< "$ul"
        printf 'unit|%s|%s|%s|%s|%s|%s|%s|%s\n' "$uid" "$grp" "$ufc" "$ulc" "$urk" "$usp" "$usig" "$ucsv"
      done
    fi
    exit 0
    ;;

  review-ledger)
    REPO_ROOT="."
    ACTION=""
    LEDGER_PATH=""
    BASE_SHA=""
    TARGET_REF=""
    IGNORE_DIRTY=""
    MAX_CONC=4
    MAX_PASSES=-1
    MAX_PASSES_SET="false"
    UNIT_ID=""
    STATUS=""
    FINDINGS=""
    SPECIALISTS=""
    RATIONALE=""
    RECEIPT_PATH=""
    CROSS_UNIT_STATUS=""
    BUDGET_STATUS=""
    REVIEW_INDEPENDENCE=""
    PASSES_USED=-1
    PASSES_USED_SET="false"
    SCOPE=""
    FORCE=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --action) ACTION="${2:-}"; shift 2 ;;
        --ledger-path) LEDGER_PATH="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --max-concurrency) MAX_CONC="${2:-4}"; shift 2 ;;
        --max-passes) MAX_PASSES="${2:-0}"; MAX_PASSES_SET="true"; shift 2 ;;
        --unit-id) UNIT_ID="${2:-}"; shift 2 ;;
        --status) STATUS="${2:-}"; shift 2 ;;
        --findings) FINDINGS="${2:-}"; shift 2 ;;
        --specialists) SPECIALISTS="${2:-}"; shift 2 ;;
        --rationale) RATIONALE="${2:-}"; shift 2 ;;
        --receipt-path) RECEIPT_PATH="${2:-}"; shift 2 ;;
        --cross-unit-status) CROSS_UNIT_STATUS="${2:-}"; shift 2 ;;
        --budget-status) BUDGET_STATUS="${2:-}"; shift 2 ;;
        --review-independence) REVIEW_INDEPENDENCE="${2:-}"; shift 2 ;;
        --passes-used) PASSES_USED="${2:--1}"; PASSES_USED_SET="true"; shift 2 ;;
        --scope) SCOPE="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *) echo "LEDGER_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    ACT_LOW="$(printf '%s' "$(trim_str "$ACTION")" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    case "$ACT_LOW" in
      init|update|normalize|check) ;;
      *) echo "LEDGER_FAIL: --action must be init, update, normalize, or check"; exit 1 ;;
    esac

    if [[ "$ACT_LOW" == "normalize" && -z "$(trim_str "$LEDGER_PATH")" ]]; then
      [[ -n "$(trim_str "$SCOPE")" ]] || { echo "LEDGER_FAIL: --ledger-path or --scope required for normalize"; exit 1; }
      NORM_SC="$(normalize_size_class "$SCOPE")" || { echo "LEDGER_FAIL: unknown size class '$SCOPE'"; exit 1; }
      printf '%s\n' "$NORM_SC"
      exit 0
    fi

    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      echo "LEDGER_FAIL: invalid --repo-root"
      exit 1
    fi

    if ! validate_repo_write_path "$REPO_ROOT" "$LEDGER_PATH"; then
      echo "LEDGER_FAIL: invalid --ledger-path"
      exit 1
    fi
    LEDGER_FULL="$_SAFE_FULL"
    LEDGER_REL="$_SAFE_REL"
    split_path_csv_checked "$IGNORE_DIRTY" "LEDGER_FAIL" "true"
    IGNORE_ARR=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && IGNORE_ARR=("${_CHECKED_CSV_PATHS[@]}")

    if [[ "$ACT_LOW" == "normalize" ]]; then
      [[ -f "$LEDGER_FULL" ]] || { echo "LEDGER_MISSING: $LEDGER_REL"; exit 1; }
      make_temp_file "b3-norm" NORM_TMP
      NORM_CNT="$(LC_ALL=C awk -v out_f="$NORM_TMP" '
      BEGIN { ch = 0; has_schema = 0; has_ri = 0; n = 0 }
      {
        sub(/\r$/, "", $0)
        if ($0 == "schema=b3-review-ledger-v1") has_schema = 1
        if ($0 ~ /^review_independence=/) has_ri = 1
        low = tolower($0)
        if (match(low, /^-?[ \t]*size_class[ \t]*[:=][ \t]*(small|medium|large|very_large)([^a-z0-9_]|$)/)) {
          # Split preserving exact prefix & suffix spacing
          ln = $0
          if (match(ln, /^(-?[ \t]*[sS][iI][zZ][eE]_[cC][lL][aA][sS][sS][ \t]*[:=][ \t]*)/)) {
            pref = substr(ln, 1, RLENGTH)
            rest = substr(ln, RLENGTH + 1)
            if (match(rest, /^[A-Za-z_]+/)) {
              tok = toupper(substr(rest, 1, RLENGTH))
              tail = substr(rest, RLENGTH + 1)
              rep = (tok == "SMALL" ? "S" : (tok == "MEDIUM" ? "M" : (tok == "LARGE" ? "L" : (tok == "VERY_LARGE" ? "XL" : tok))))
              if (rep != tok) ch++
              ln = pref rep tail
            }
          }
          lines[++n] = ln
        } else {
          lines[++n] = $0
        }
      }
      END {
        inserted = 0
        for (i = 1; i <= n; i++) {
          print lines[i] > out_f
          if (has_schema && !has_ri && !inserted && lines[i] ~ /^budget_status=/) {
            print "review_independence=UNKNOWN" > out_f
            ch++
            inserted = 1
          }
        }
        close(out_f)
        printf "%d", ch
      }' "$LEDGER_FULL")"
      if [[ "${NORM_CNT:-0}" -gt 0 ]]; then
        write_atomic_lf_file "$LEDGER_FULL" "$(cat "$NORM_TMP")"$'\n'
      fi
      rm -f "$NORM_TMP" 2>/dev/null || true
      printf 'LEDGER_NORMALIZED: path=%s changes=%s\n' "$LEDGER_REL" "${NORM_CNT:-0}"
      exit 0
    fi

    if [[ "$ACT_LOW" == "init" ]]; then
      [[ ! -d "$LEDGER_FULL" ]] || { echo "LEDGER_FAIL: --ledger-path is a directory"; exit 1; }
      if [[ "$MAX_PASSES_SET" == "true" ]]; then
        [[ "$MAX_PASSES" =~ ^[0-9]+$ ]] || { echo "LEDGER_FAIL: --max-passes must be a positive integer"; exit 1; }
        MAX_PASSES="$((10#$MAX_PASSES))"
        [[ "$MAX_PASSES" -gt 0 ]] || { echo "LEDGER_FAIL: --max-passes must be a positive integer"; exit 1; }
      fi
      RI_INIT="UNKNOWN"
      if [[ -n "$(trim_str "$REVIEW_INDEPENDENCE")" ]]; then
        RI_INIT="$(printf '%s' "$(trim_str "$REVIEW_INDEPENDENCE")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
        case "$RI_INIT" in
          UNKNOWN|INDEPENDENT|SINGLE_AGENT_LIMIT) ;;
          *) echo "LEDGER_FAIL: invalid --review-independence '$RI_INIT'"; exit 1 ;;
        esac
      fi
      resolve_scope_target_and_base "$REPO_ROOT" "$TARGET_REF" "$BASE_SHA" "LEDGER_FAIL" "commit" ${IGNORE_ARR[@]+"${IGNORE_ARR[@]}"}
      TARGET_REF="$_SCOPE_TARGET_REF"
      TARGET_COMMIT_SHA="$_SCOPE_TARGET_SHA"
      BASE_SHA="$_SCOPE_BASE_SHA"
      if [[ -n "$TARGET_COMMIT_SHA" ]]; then
        HEAD_SHA="$TARGET_COMMIT_SHA"
      else
        assert_valid_git_rev "$REPO_ROOT" "HEAD" "commit" "LEDGER_FAIL" "HEAD"
        HEAD_SHA="$_VALID_REV_SHA"
      fi

      if ! $FORCE && [[ -f "$LEDGER_FULL" ]]; then
        set +e
        _INIT_PROBE="$(
          _CLEANUP_FILES=()
          trap _cleanup_tmp EXIT
          make_temp_file "b3-git-err-ip" _B3_GIT_ERR_FILE
          L_SCHEMA=""; L_BASE=""; L_HEAD=""; L_TREF=""; L_TSHA=""; L_SNAP=""; L_SIZE=""; L_NLSIZE=""; L_RISK=""; L_RSIG=""; L_RSPEC=""
          L_L1SPEC=""; L_L1SKIP=""; L_PCHAIN=""; L_HAS_CHAIN="false"; L_RIND=""
          L_CFILES=""; L_GFILES=""; L_MCONC=""; L_MPASS=""; L_PUSED=""; L_BSTAT=""; L_CSTAT=""; L_CHASH=""; L_UCNT=""
          L_SEEN_KEYS=""
          U_ROWS=()
          P_ROWS=()
          while IFS= read -r rawln || [[ -n "$rawln" ]]; do
            ln="$(trim_str "${rawln%$'\r'}")"
            [[ -z "$ln" || "$ln" == \#* ]] && continue
            if [[ "$ln" == \|* ]]; then
              inner="${ln#|}"; inner="${inner%|}"
              c_cnt=0; c0=""; c2=""; c3=""
              while IFS= read -r col; do
                tc="$(trim_str "$col")"
                case "$c_cnt" in 0) c0="$tc" ;; 2) c2="$tc" ;; 3) c3="$tc" ;; esac
                c_cnt=$((c_cnt + 1))
              done < <(printf '%s\n' "$inner" | LC_ALL=C awk -F'|' '{for(i=1;i<=NF;i++) print $i}')
              [[ "$c_cnt" -eq 12 ]] || exit 10
              [[ "$c0" == "unit_id" || "$c0" == "---" ]] && continue
              [[ "$c0" =~ ^U[0-9]{2,}$ && "$c2" =~ ^[0-9]+$ && "$c3" =~ ^[0-9]+$ ]] || exit 10
              U_ROWS+=("$c0")
              continue
            fi
            if [[ "$ln" == pass\|* ]]; then
              _re_pass='^pass\|[0-9]+\|[^|]+\|[^|]+\|[0-9]+\|([0-9a-f]{40}|none)\|[0-9a-f]{40}$'
              [[ "$ln" =~ $_re_pass ]] || exit 10
              P_ROWS+=("$ln")
              continue
            fi
            [[ "$ln" == *"="* ]] || exit 10
            lk="$(trim_str "${ln%%=*}")"; lv="$(trim_str "${ln#*=}")"
            [[ -n "$lk" ]] || exit 10
            case "$L_SEEN_KEYS" in *"|${lk}|"*) exit 10 ;; esac
            L_SEEN_KEYS+="|${lk}|"
            case "$lk" in
              schema) L_SCHEMA="$lv" ;; base_sha) L_BASE="$lv" ;; head_sha) L_HEAD="$lv" ;; target_ref) L_TREF="$lv" ;;
              target_sha) L_TSHA="$lv" ;; snapshot_sha) L_SNAP="$lv" ;; size_class) L_SIZE="$lv" ;; normalized_legacy_size) L_NLSIZE="$lv" ;;
              risk_level) L_RISK="$lv" ;; risk_signals) L_RSIG="$lv" ;; recommended_specialists) L_RSPEC="$lv" ;;
              l1_specialists) L_L1SPEC="$lv" ;; l1_skip_rationale) L_L1SKIP="$lv" ;; pass_chain) L_PCHAIN="$lv"; L_HAS_CHAIN="true" ;;
              review_independence) L_RIND="$lv" ;; contract_files) L_CFILES="$lv" ;; generated_files) L_GFILES="$lv" ;;
              max_concurrency) L_MCONC="$lv" ;; max_passes) L_MPASS="$lv" ;; passes_used) L_PUSED="$lv" ;;
              budget_status) L_BSTAT="$lv" ;; cross_unit_status) L_CSTAT="$lv" ;; cross_unit_tree_hash) L_CHASH="$lv" ;; unit_count) L_UCNT="$lv" ;;
            esac
          done < "$LEDGER_FULL"
          for rv in "$L_SCHEMA" "$L_BASE" "$L_HEAD" "$L_TREF" "$L_SNAP" "$L_SIZE" "$L_NLSIZE" "$L_RISK" "$L_RSIG" "$L_RSPEC" "$L_CFILES" "$L_GFILES" "$L_MCONC" "$L_MPASS" "$L_PUSED" "$L_BSTAT" "$L_CSTAT" "$L_CHASH" "$L_UCNT"; do
            [[ -n "$rv" ]] || exit 10
          done
          [[ "$L_SCHEMA" == "b3-review-ledger-v1" && "$L_BASE" =~ ^[0-9a-f]{40}$ && "$L_HEAD" =~ ^[0-9a-f]{40}$ ]] || exit 10
          if [[ -z "$L_TSHA" ]]; then
            if [[ "$L_TREF" == "working_tree" ]]; then
              L_TSHA="none"
            elif [[ "$L_TREF" =~ ^[0-9a-f]{40}$ ]]; then
              L_TSHA="$L_TREF"
            else
              exit 10
            fi
          fi
          if [[ "$L_TREF" == "working_tree" ]]; then
            [[ "$L_TSHA" == "none" ]] || exit 10
          else
            [[ "$L_TSHA" =~ ^[0-9a-f]{40}$ ]] || exit 10
          fi
          [[ "$L_MPASS" =~ ^[0-9]+$ && "$L_PUSED" =~ ^[0-9]+$ && "$L_UCNT" =~ ^[0-9]+$ ]] || exit 10
          L_PUSED="$((10#$L_PUSED))"; L_UCNT="$((10#$L_UCNT))"
          [[ "$L_UCNT" -eq ${#U_ROWS[@]} ]] || exit 10
          [[ "$L_HAS_CHAIN" == "true" && "$L_PCHAIN" =~ ^[0-9a-f]{40}$ ]] || exit 10
          [[ "$L_RIND" == "UNKNOWN" || "$L_RIND" == "INDEPENDENT" || "$L_RIND" == "SINGLE_AGENT_LIMIT" ]] || exit 10
          normalize_size_class "$L_SIZE" >/dev/null || exit 10
          cur="$(init_pass_chain "$REPO_ROOT" "$L_BASE")" || exit 10
          sum=0; idx=0
          if [[ ${#P_ROWS[@]} -gt 0 ]]; then
            for row in "${P_ROWS[@]}"; do
              IFS='|' read -r _pt p_seq p_scope p_kind p_delta p_ref p_hash <<< "$row"
              p_seq="$((10#$p_seq))"; p_delta="$((10#$p_delta))"
              [[ "$p_seq" -eq $((idx + 1)) && "$p_delta" -ge 1 ]] || exit 10
              sum=$((sum + p_delta))
              cur="$(step_pass_chain "$REPO_ROOT" "$cur" "$p_seq" "$p_scope" "$p_kind" "$p_delta" "$p_ref")" || exit 10
              [[ "$cur" == "$p_hash" ]] || exit 10
              idx=$((idx + 1))
            done
          fi
          [[ "$sum" -eq "$L_PUSED" && "$cur" == "$L_PCHAIN" ]] || exit 10
          if [[ "$L_BASE" == "$BASE_SHA" ]]; then
            if [[ "$L_PUSED" -gt 0 || "$L_BSTAT" == "EXHAUSTED" || "$L_RIND" == "SINGLE_AGENT_LIMIT" ]]; then
              exit 11
            fi
          fi
          exit 0
        )"
        _IP_RC=$?
        set -e
        if [[ $_IP_RC -eq 11 ]]; then
          printf "LEDGER_FAIL: cannot reset active ledger '%s' on same base_sha without --force\n" "$LEDGER_REL"
          exit 1
        elif [[ $_IP_RC -ne 0 ]]; then
          printf "LEDGER_CORRUPT: cannot overwrite corrupt ledger '%s' without --force\n" "$LEDGER_REL"
          exit 1
        fi
      fi

      INV_OUT=""
      if ! INV_OUT="$(run_scope_engine "$REPO_ROOT" "$BASE_SHA" "$TARGET_COMMIT_SHA" "$IGNORE_DIRTY" "$MAX_CONC" "LEDGER_FAIL")"; then
        printf '%s\n' "$INV_OUT"
        exit 1
      fi
      parse_scope_engine_output "$INV_OUT"
      IS_EMPTY="$_SE_IS_EMPTY"; PART_ERR="$_SE_PART_ERR"; SIZE_CLASS="$_SE_SIZE_CLASS"
      RISK_LEVEL="$_SE_RISK_LEVEL"; RISK_SIGNALS="$_SE_RISK_SIGNALS"; REC_SPECS="$_SE_REC_SPECS"
      L1_SPECS="$_SE_L1_SPECS"; L1_SKIP="$_SE_L1_SKIP"; CONTRACT_FILES="$_SE_CONTRACT_FILES"
      GENERATED_FILES="$_SE_GENERATED_FILES"; RF_OUT="$_SE_REVIEW_FILES"; MC_OUT="$_SE_MAX_CONC"; UNIT_CNT="$_SE_UNIT_COUNT"
      UNITS_LINES=()
      if [[ ${#_SE_UNITS[@]} -gt 0 ]]; then UNITS_LINES=("${_SE_UNITS[@]}"); fi
      if [[ "$IS_EMPTY" == "true" ]]; then
        echo "LEDGER_FAIL: EMPTY_DIFF"
        exit 2
      fi
      if [[ -n "$PART_ERR" ]]; then
        printf '%s\n' "$PART_ERR"
        exit 2
      fi

      if [[ -n "$TARGET_COMMIT_SHA" ]]; then
        SNAP_SHA="$TARGET_COMMIT_SHA"
      else
        assert_valid_git_rev "$REPO_ROOT" "HEAD" "tree" "LEDGER_FAIL" "HEAD^{tree}"
        HEAD_TREE="$_VALID_REV_SHA"
        build_working_tree_oid "$REPO_ROOT" "LEDGER_FAIL"
        WT_TREE="$_WT_TREE_OID"
        if [[ "$WT_TREE" == "$HEAD_TREE" ]]; then
          SNAP_SHA="$HEAD_SHA"
        else
          run_git_cmd "$REPO_ROOT" commit-tree "$WT_TREE" -p "$HEAD_SHA" -m "b3-ledger-snapshot" || { echo "LEDGER_FAIL: git commit-tree failed"; exit 1; }
          SNAP_SHA="$(trim_str "$_GIT_STDOUT")"
        fi
      fi

      INIT_CHAIN="$(init_pass_chain "$REPO_ROOT" "$BASE_SHA")" || exit 1

      if [[ "$MAX_PASSES_SET" != "true" ]]; then
        MAX_PASSES="$(default_max_passes "$SIZE_CLASS" "$UNIT_CNT")"
      fi

      NEED_CROSS=false
      if [[ ( "$SIZE_CLASS" == "L" || "$SIZE_CLASS" == "XL" || "$SIZE_CLASS" == "XXL" ) && "$UNIT_CNT" -gt 1 ]]; then
        NEED_CROSS=true
      fi
      CROSS_STATUS="N_A"; CROSS_HASH="none"
      if $NEED_CROSS; then
        CROSS_STATUS="PENDING"
        CROSS_PATHS="$CONTRACT_FILES"
        [[ "$CROSS_PATHS" == "none" ]] && CROSS_PATHS="$RF_OUT"
        CROSS_HASH="$(compute_scope_paths_hash "$REPO_ROOT" "$TARGET_COMMIT_SHA" "$CROSS_PATHS" "$IGNORE_DIRTY")" || exit 1
      fi

      TREF_VAL="working_tree"
      TSHA_VAL="none"
      if [[ -n "$TARGET_REF" ]]; then
        TREF_VAL="$TARGET_REF"
        TSHA_VAL="$TARGET_COMMIT_SHA"
      fi
      L_BASE="$BASE_SHA"; L_HEAD="$HEAD_SHA"; L_TREF="$TREF_VAL"; L_TSHA="$TSHA_VAL"; L_SNAP="$SNAP_SHA"
      L_SIZE="$SIZE_CLASS"; L_NLSIZE="none"; L_RISK="$RISK_LEVEL"; L_RSIG="$RISK_SIGNALS"; L_RSPEC="$REC_SPECS"
      L_L1SPEC="$L1_SPECS"; L_L1SKIP="$L1_SKIP"; L_CFILES="$CONTRACT_FILES"; L_GFILES="$GENERATED_FILES"
      L_MCONC="$MC_OUT"; L_MPASS="$MAX_PASSES"; L_PUSED="0"; L_PCHAIN="$INIT_CHAIN"; L_BSTAT="OK"
      L_RIND="$RI_INIT"; L_CSTAT="$CROSS_STATUS"; L_CHASH="$CROSS_HASH"; L_UCNT="$UNIT_CNT"
      U_ROWS=()
      P_ROWS=()
      if [[ ${#UNITS_LINES[@]} -gt 0 ]]; then
        for ul in "${UNITS_LINES[@]}"; do
          IFS=$'\t' read -r _tag uid grp ufc ulc urk usp usig ucsv <<< "$ul"
          COMB_PATHS="$ucsv"
          [[ "$CONTRACT_FILES" != "none" ]] && COMB_PATHS="${ucsv},${CONTRACT_FILES}"
          UHASH="$(compute_scope_paths_hash "$REPO_ROOT" "$TARGET_COMMIT_SHA" "$COMB_PATHS" "$IGNORE_DIRTY")" || exit 1
          U_ROWS+=("${uid}|${grp}|${ufc}|${ulc}|${urk}|none|none|PENDING|none|none|${UHASH}|${ucsv}")
        done
      fi
      serialize_review_ledger
      write_atomic_lf_file "$LEDGER_FULL" "$_LEDGER_TXT"
      printf 'LEDGER_INIT: path=%s size=%s risk=%s units=%s max_passes=%s snapshot=%s\n' "$LEDGER_REL" "$SIZE_CLASS" "$RISK_LEVEL" "$UNIT_CNT" "$MAX_PASSES" "$SNAP_SHA"
      exit 0
    fi

    if [[ "$ACT_LOW" == "check" ]]; then
      run_review_ledger_check_sub "$REPO_ROOT" "$LEDGER_FULL" "$LEDGER_REL" "$IGNORE_DIRTY" "false"
      exit $?
    fi

    [[ -f "$LEDGER_FULL" ]] || { echo "LEDGER_MISSING: $LEDGER_REL"; exit 1; }

    # Parse ledger metadata + unit rows + pass log (update)
    L_SCHEMA=""; L_BASE=""; L_HEAD=""; L_TREF=""; L_TSHA=""; L_SNAP=""; L_SIZE=""; L_NLSIZE=""; L_RISK=""; L_RSIG=""; L_RSPEC=""
    L_L1SPEC=""; L_L1SKIP=""; L_PCHAIN=""; L_HAS_CHAIN="false"; L_RIND=""
    L_CFILES=""; L_GFILES=""; L_MCONC=""; L_MPASS=""; L_PUSED=""; L_BSTAT=""; L_CSTAT=""; L_CHASH=""; L_UCNT=""
    L_SEEN_KEYS=""
    U_ROWS=()
    P_ROWS=()
    while IFS= read -r rawln || [[ -n "$rawln" ]]; do
      ln="$(trim_str "${rawln%$'\r'}")"
      [[ -z "$ln" || "$ln" == \#* ]] && continue
      if [[ "$ln" == \|* ]]; then
        inner="${ln#|}"; inner="${inner%|}"
        c_cnt=0; c0=""; c1=""; c2=""; c3=""; c4=""; c5=""; c6=""; c7=""; c8=""; c9=""; c10=""; c11=""
        while IFS= read -r col; do
          tc="$(trim_str "$col")"
          case "$c_cnt" in
            0) c0="$tc" ;; 1) c1="$tc" ;; 2) c2="$tc" ;; 3) c3="$tc" ;; 4) c4="$tc" ;; 5) c5="$tc" ;;
            6) c6="$tc" ;; 7) c7="$tc" ;; 8) c8="$tc" ;; 9) c9="$tc" ;; 10) c10="$tc" ;; 11) c11="$tc" ;;
          esac
          c_cnt=$((c_cnt + 1))
        done < <(printf '%s\n' "$inner" | LC_ALL=C awk -F'|' '{for(i=1;i<=NF;i++) print $i}')
        [[ "$c_cnt" -eq 12 ]] || { echo "LEDGER_CORRUPT: malformed unit row column count"; exit 1; }
        [[ "$c0" == "unit_id" || "$c0" == "---" ]] && continue
        [[ "$c0" =~ ^U[0-9]{2,}$ ]] || { echo "LEDGER_CORRUPT: invalid unit_id '$c0'"; exit 1; }
        [[ "$c2" =~ ^[0-9]+$ && "$c3" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: invalid unit row numeric field"; exit 1; }
        U_ROWS+=("${c0}|${c1}|${c2}|${c3}|${c4}|${c5}|${c6}|${c7}|${c8}|${c9}|${c10}|${c11}")
        continue
      fi
      if [[ "$ln" == pass\|* ]]; then
        _re_pass='^pass\|[0-9]+\|[^|]+\|[^|]+\|[0-9]+\|([0-9a-f]{40}|none)\|[0-9a-f]{40}$'
        [[ "$ln" =~ $_re_pass ]] || { printf "LEDGER_CORRUPT: malformed pass log entry '%s'\n" "$ln"; exit 1; }
        P_ROWS+=("$ln")
        continue
      fi
      [[ "$ln" == *"="* ]] || { echo "LEDGER_CORRUPT: unexpected line '$ln'"; exit 1; }
      lk="$(trim_str "${ln%%=*}")"; lv="$(trim_str "${ln#*=}")"
      case "$L_SEEN_KEYS" in *"|${lk}|"*) echo "LEDGER_CORRUPT: duplicate key '$lk'"; exit 1 ;; esac
      L_SEEN_KEYS+="|${lk}|"
      case "$lk" in
        schema) L_SCHEMA="$lv" ;; base_sha) L_BASE="$lv" ;; head_sha) L_HEAD="$lv" ;; target_ref) L_TREF="$lv" ;;
        target_sha) L_TSHA="$lv" ;; snapshot_sha) L_SNAP="$lv" ;; size_class) L_SIZE="$lv" ;; normalized_legacy_size) L_NLSIZE="$lv" ;;
        risk_level) L_RISK="$lv" ;; risk_signals) L_RSIG="$lv" ;; recommended_specialists) L_RSPEC="$lv" ;;
        l1_specialists) L_L1SPEC="$lv" ;; l1_skip_rationale) L_L1SKIP="$lv" ;; pass_chain) L_PCHAIN="$lv"; L_HAS_CHAIN="true" ;;
        review_independence) L_RIND="$lv" ;;
        contract_files) L_CFILES="$lv" ;; generated_files) L_GFILES="$lv" ;; max_concurrency) L_MCONC="$lv" ;;
        max_passes) L_MPASS="$lv" ;; passes_used) L_PUSED="$lv" ;; budget_status) L_BSTAT="$lv" ;;
        cross_unit_status) L_CSTAT="$lv" ;; cross_unit_tree_hash) L_CHASH="$lv" ;; unit_count) L_UCNT="$lv" ;;
      esac
    done < "$LEDGER_FULL"

    for rv in "$L_SCHEMA" "$L_BASE" "$L_HEAD" "$L_TREF" "$L_SNAP" "$L_SIZE" "$L_NLSIZE" "$L_RISK" "$L_RSIG" "$L_RSPEC" "$L_CFILES" "$L_GFILES" "$L_MCONC" "$L_MPASS" "$L_PUSED" "$L_BSTAT" "$L_CSTAT" "$L_CHASH" "$L_UCNT"; do
      [[ -n "$rv" ]] || { echo "LEDGER_CORRUPT: missing required ledger key"; exit 1; }
    done
    [[ "$L_SCHEMA" == "b3-review-ledger-v1" ]] || { echo "LEDGER_CORRUPT: unsupported schema '$L_SCHEMA'"; exit 1; }
    [[ "$L_BASE" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid base_sha"; exit 1; }
    [[ "$L_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid head_sha"; exit 1; }
    if [[ -z "$L_TSHA" ]]; then
      if [[ "$L_TREF" == "working_tree" ]]; then
        L_TSHA="none"
      elif [[ "$L_TREF" =~ ^[0-9a-f]{40}$ ]]; then
        L_TSHA="$L_TREF"
      else
        echo "LEDGER_CORRUPT: missing target_sha for symbolic target_ref"; exit 1
      fi
    fi
    if [[ "$L_TREF" == "working_tree" ]]; then
      [[ "$L_TSHA" == "none" ]] || { echo "LEDGER_CORRUPT: invalid target_sha"; exit 1; }
    else
      [[ "$L_TSHA" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid target_sha"; exit 1; }
    fi
    [[ "$L_MPASS" =~ ^[0-9]+$ && "$L_PUSED" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: invalid pass counter"; exit 1; }
    L_MPASS="$((10#$L_MPASS))"
    L_PUSED="$((10#$L_PUSED))"
    if [[ "$L_HAS_CHAIN" != "true" || -z "$L_PCHAIN" ]]; then
      echo "LEDGER_CORRUPT: missing pass_chain"
      exit 1
    fi
    [[ "$L_PCHAIN" =~ ^[0-9a-f]{40}$ ]] || { echo "LEDGER_CORRUPT: invalid pass_chain"; exit 1; }
    if [[ -z "$L_RIND" ]]; then
      echo "LEDGER_CORRUPT: missing review_independence"
      exit 1
    fi
    if [[ "$L_RIND" != "UNKNOWN" && "$L_RIND" != "INDEPENDENT" && "$L_RIND" != "SINGLE_AGENT_LIMIT" ]]; then
      echo "LEDGER_CORRUPT: invalid review_independence '$L_RIND'"
      exit 1
    fi
    [[ -z "$L_L1SPEC" ]] && L_L1SPEC="none"
    [[ -z "$L_L1SKIP" ]] && L_L1SKIP="none"
    ORIG_RAW_SIZE="$L_SIZE"
    NORM_SIZE="$(normalize_size_class "$ORIG_RAW_SIZE")" || { echo "LEDGER_CORRUPT: invalid size_class '$ORIG_RAW_SIZE'"; exit 1; }
    [[ "$L_UCNT" =~ ^[0-9]+$ ]] || { echo "LEDGER_CORRUPT: unit_count mismatch"; exit 1; }
    L_UCNT="$((10#$L_UCNT))"
    [[ "$L_UCNT" -eq ${#U_ROWS[@]} ]] || { echo "LEDGER_CORRUPT: unit_count mismatch"; exit 1; }
    if [[ "$ORIG_RAW_SIZE" != "$NORM_SIZE" ]]; then
      L_NLSIZE="${ORIG_RAW_SIZE}:${NORM_SIZE}"
    fi
    L_SIZE="$NORM_SIZE"
    TARGET_COMMIT_SHA=""
    [[ "$L_TREF" != "working_tree" ]] && TARGET_COMMIT_SHA="$L_TSHA"

    verify_ledger_pass_chain() {
      local cur sum idx row _pt p_seq p_scope p_kind p_delta p_ref p_hash expect_seq
      cur="$(init_pass_chain "$REPO_ROOT" "$L_BASE")" || exit 1
      sum=0; idx=0
      if [[ ${#P_ROWS[@]} -gt 0 ]]; then
        for row in "${P_ROWS[@]}"; do
          IFS='|' read -r _pt p_seq p_scope p_kind p_delta p_ref p_hash <<< "$row"
          p_seq="$((10#$p_seq))"
          p_delta="$((10#$p_delta))"
          expect_seq=$((idx + 1))
          if [[ "$p_seq" -ne "$expect_seq" || "$p_delta" -lt 1 ]]; then
            printf 'LEDGER_CORRUPT: passes_used tamper detected (invalid sequence or delta at index %s)\n' "$expect_seq"
            exit 1
          fi
          sum=$((sum + p_delta))
          cur="$(step_pass_chain "$REPO_ROOT" "$cur" "$p_seq" "$p_scope" "$p_kind" "$p_delta" "$p_ref")" || exit 1
          if [[ "$cur" != "$p_hash" ]]; then
            printf 'LEDGER_CORRUPT: passes_used tamper detected (chain hash mismatch at seq %s)\n' "$p_seq"
            exit 1
          fi
          idx=$((idx + 1))
        done
      fi
      if [[ "$sum" -ne "$L_PUSED" || "$cur" != "$L_PCHAIN" ]]; then
        printf 'LEDGER_CORRUPT: passes_used tamper detected (passes=%s log_sum=%s)\n' "$L_PUSED" "$sum"
        exit 1
      fi
    }

    if [[ "$ACT_LOW" == "update" ]]; then
      verify_ledger_pass_chain
      if [[ "$MAX_PASSES_SET" == "true" ]]; then
        [[ "$MAX_PASSES" =~ ^[0-9]+$ ]] || { echo "LEDGER_FAIL: --max-passes must be a positive integer"; exit 1; }
        MAX_PASSES="$((10#$MAX_PASSES))"
        [[ "$MAX_PASSES" -gt 0 ]] || { echo "LEDGER_FAIL: --max-passes must be a positive integer"; exit 1; }
        if [[ "$MAX_PASSES" -gt "$L_MPASS" ]]; then
          printf 'LEDGER_CORRUPT: cannot raise max_passes (%s->%s)\n' "$L_MPASS" "$MAX_PASSES"
          exit 1
        fi
      fi
      if [[ "$PASSES_USED_SET" == "true" ]]; then
        [[ "$PASSES_USED" =~ ^[0-9]+$ ]] || { echo "LEDGER_FAIL: --passes-used must be non-negative"; exit 1; }
        PASSES_USED="$((10#$PASSES_USED))"
      fi
      ORIG_HEAD_SHA="$L_HEAD"
      RI_EXPLICIT=false
      if [[ -n "$(trim_str "$REVIEW_INDEPENDENCE")" ]]; then
        RI_EXPLICIT=true
        RI_UPD="$(printf '%s' "$(trim_str "$REVIEW_INDEPENDENCE")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
        case "$RI_UPD" in
          UNKNOWN|INDEPENDENT|SINGLE_AGENT_LIMIT)
            if [[ "$L_RIND" == "SINGLE_AGENT_LIMIT" && "$RI_UPD" == "INDEPENDENT" ]]; then
              echo "LEDGER_FAIL: cannot upgrade SINGLE_AGENT_LIMIT to INDEPENDENT"
              exit 1
            fi
            if [[ "$L_RIND" == "SINGLE_AGENT_LIMIT" && "$RI_UPD" == "UNKNOWN" ]]; then
              echo "LEDGER_FAIL: cannot clear SINGLE_AGENT_LIMIT"
              exit 1
            fi
            L_RIND="$RI_UPD"
            ;;
          *) echo "LEDGER_FAIL: invalid --review-independence '$RI_UPD'"; exit 1 ;;
        esac
      fi
      UNIT_ID="$(trim_str "$UNIT_ID")"
      FOUND_IDX=-1
      ST_VAL=""
      ADDED_NEW_SPEC="false"
      u0=""; u1=""; u2=""; u3=""; u4=""; u5=""; u6=""; u7=""; u8=""; u9=""; u10=""; u11=""
      if [[ -n "$UNIT_ID" ]]; then
        if [[ ${#U_ROWS[@]} -gt 0 ]]; then
          for idx in "${!U_ROWS[@]}"; do
            IFS='|' read -r r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 <<< "${U_ROWS[$idx]}"
            if [[ "$r0" == "$UNIT_ID" ]]; then FOUND_IDX=$idx; break; fi
          done
        fi
        [[ $FOUND_IDX -ge 0 ]] || { echo "LEDGER_FAIL: unknown --unit-id '$UNIT_ID'"; exit 1; }
        IFS='|' read -r u0 u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11 <<< "${U_ROWS[$FOUND_IDX]}"
        ST_VAL="$(printf '%s' "$(trim_str "$STATUS")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
        if [[ -n "$ST_VAL" ]]; then
          case "$ST_VAL" in PENDING|IN_PROGRESS|REVIEWED|INCOMPLETE|STALE|BLOCKED) ;; *) echo "LEDGER_FAIL: invalid unit --status '$ST_VAL'"; exit 1 ;; esac
          u7="$ST_VAL"
        fi
        F_VAL="$(trim_str "$FINDINGS")"
        if [[ -n "$F_VAL" ]]; then u8="$(printf '%s' "$F_VAL" | tr '\r\n|' ';;;' | sed 's/;;;*/;/g')"; fi
        SP_VAL="$(trim_str "$SPECIALISTS")"
        if [[ -n "$SP_VAL" ]]; then
          OLD_U5="$u5"
          while IFS= read -r nsi; do
            [[ -n "$nsi" ]] || continue
            case ",${OLD_U5}," in *,"${nsi}",*) ;; *) ADDED_NEW_SPEC="true"; break ;; esac
          done < <(split_csv_lines "$SP_VAL" false)
          SP_LIST="$(split_csv_lines "$SP_VAL" false | LC_ALL=C sort -u | paste -sd ',' -)"
          u5="${SP_LIST:-none}"
        fi
        RAT_VAL="$(trim_str "$RATIONALE")"
        if [[ -n "$RAT_VAL" ]]; then u6="$(printf '%s' "$RAT_VAL" | tr '\r\n|' '   ')"; fi
        REC_VAL="$(trim_str "$RECEIPT_PATH")"
        if [[ -n "$REC_VAL" ]]; then
          if [[ "$REC_VAL" == "none" ]]; then
            u9="none"
          else
            if ! validate_repo_write_path "$REPO_ROOT" "$REC_VAL"; then echo "LEDGER_FAIL: invalid --receipt-path"; exit 1; fi
            u9="$_SAFE_REL"
          fi
        fi
      fi

      CU_VAL="$(printf '%s' "$(trim_str "$CROSS_UNIT_STATUS")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      if [[ -n "$CU_VAL" ]]; then
        case "$CU_VAL" in N_A|PENDING|REVIEWED|INCOMPLETE|STALE|BLOCKED) ;; *) echo "LEDGER_FAIL: invalid --cross-unit-status '$CU_VAL'"; exit 1 ;; esac
        L_CSTAT="$CU_VAL"
      fi

      if [[ ( $FOUND_IDX -ge 0 && "$ST_VAL" == "REVIEWED" ) || "$CU_VAL" == "REVIEWED" ]]; then
        if [[ "$L_TREF" != "working_tree" ]]; then
          if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${L_TREF}^{commit}"; then
            printf "LEDGER_STALE: target_ref '%s' cannot be resolved\n" "$L_TREF"
            exit 2
          fi
          _UPD_TR_SHA="$(trim_str "$_GIT_STDOUT")"
          if [[ ! "$_UPD_TR_SHA" =~ ^[0-9a-f]{40}$ ]]; then
            printf "LEDGER_STALE: target_ref '%s' cannot be resolved\n" "$L_TREF"
            exit 2
          fi
          TARGET_COMMIT_SHA="$_UPD_TR_SHA"
          L_TSHA="$_UPD_TR_SHA"
          L_HEAD="$_UPD_TR_SHA"
          L_SNAP="$_UPD_TR_SHA"
        fi
        make_temp_file "b3-ufsig" UPD_FSIG_TMP
        make_temp_file "b3-ufln" UPD_FLINES_TMP
        : > "$UPD_FSIG_TMP"; : > "$UPD_FLINES_TMP"
        UPD_OUT=""
        if ! UPD_OUT="$(run_scope_engine "$REPO_ROOT" "$L_BASE" "$TARGET_COMMIT_SHA" "$IGNORE_DIRTY" "$L_MCONC" "LEDGER_FAIL" "$UPD_FSIG_TMP" "$UPD_FLINES_TMP" "false")"; then
          printf '%s\n' "$UPD_OUT"
          exit 1
        fi
        parse_scope_engine_output "$UPD_OUT"
        UPD_RF="$_SE_REVIEW_FILES"; UPD_CF="$_SE_CONTRACT_FILES"
        L_CFILES="$UPD_CF"
        if [[ -n "$UPD_RF" && "$UPD_RF" != "none" ]]; then
          ALL_RISK_OUT="$(eval_risk_for_csv_awk "$UPD_RF" "$UPD_FSIG_TMP" "$UPD_FLINES_TMP")"
          { IFS= read -r L_RISK; IFS= read -r L_RSIG; IFS= read -r L_RSPEC; } <<< "$ALL_RISK_OUT"
          L1_UPD_OUT="$(eval_l1_dispatch_awk "$L_CFILES" "$L_RSPEC" "$L_RISK" "$UPD_RF")"
          { IFS= read -r L_L1SPEC; IFS= read -r L_L1SKIP; } <<< "$L1_UPD_OUT"
        fi
        if [[ $FOUND_IDX -ge 0 && "$ST_VAL" == "REVIEWED" ]]; then
          IFS=$'\t' read -r u2 u3 < <(unit_counts_from_flines_awk "$u11" "$UPD_FLINES_TMP")
          U_RISK_OUT="$(eval_risk_for_csv_awk "$u11" "$UPD_FSIG_TMP" "$UPD_FLINES_TMP")"
          { IFS= read -r U_LIVE_LVL; } <<< "$U_RISK_OUT"
          u4="$U_LIVE_LVL"
          COMB_U="$u11"
          [[ "$L_CFILES" != "none" ]] && COMB_U="${u11},${L_CFILES}"
          u10="$(compute_scope_paths_hash "$REPO_ROOT" "$TARGET_COMMIT_SHA" "$COMB_U" "$IGNORE_DIRTY")" || exit 1
          if [[ -n "$TARGET_COMMIT_SHA" ]]; then
            L_HEAD="$TARGET_COMMIT_SHA"
          else
            assert_valid_git_rev "$REPO_ROOT" "HEAD" "commit" "LEDGER_FAIL" "HEAD"
            L_HEAD="$_VALID_REV_SHA"
          fi
        fi
        rm -f "$UPD_FSIG_TMP" "$UPD_FLINES_TMP" 2>/dev/null || true
      fi
      if [[ $FOUND_IDX -ge 0 ]]; then
        U_ROWS[$FOUND_IDX]="${u0}|${u1}|${u2}|${u3}|${u4}|${u5}|${u6}|${u7}|${u8}|${u9}|${u10}|${u11}"
      fi
      if [[ "$CU_VAL" == "REVIEWED" ]]; then
        if [[ "$L_CFILES" != "none" ]]; then
          CU_PATHS="$L_CFILES"
        else
          ALL_U=()
          if [[ ${#U_ROWS[@]} -gt 0 ]]; then
            for ur in "${U_ROWS[@]}"; do
              IFS='|' read -r _0 _1 _2 _3 _4 _5 _6 _7 _8 _9 _10 fcsv <<< "$ur"
              ALL_U+=("$fcsv")
            done
          fi
          CU_PATHS="none"
          if [[ ${#ALL_U[@]} -gt 0 ]]; then
            CU_PATHS="$(printf '%s,' "${ALL_U[@]}")"; CU_PATHS="${CU_PATHS%,}"
          fi
        fi
        L_CHASH="$(compute_scope_paths_hash "$REPO_ROOT" "$TARGET_COMMIT_SHA" "$CU_PATHS" "$IGNORE_DIRTY")" || exit 1
      fi
      if [[ "$L_HEAD" != "$ORIG_HEAD_SHA" && "$RI_EXPLICIT" != "true" && "$L_RIND" == "INDEPENDENT" ]]; then
        L_RIND="UNKNOWN"
      fi

      PASS_EVT_ROWS=()
      AUTO_DELTA=0
      if [[ $FOUND_IDX -ge 0 && ( "$ST_VAL" == "REVIEWED" || "$ST_VAL" == "INCOMPLETE" || "$ST_VAL" == "BLOCKED" ) ]]; then
        PASS_EVT_ROWS+=("${u0}|unit:${ST_VAL}|1")
        AUTO_DELTA=$((AUTO_DELTA + 1))
      elif [[ $FOUND_IDX -ge 0 && "$ADDED_NEW_SPEC" == "true" ]]; then
        PASS_EVT_ROWS+=("${u0}|specialist|1")
        AUTO_DELTA=$((AUTO_DELTA + 1))
      fi
      if [[ "$CU_VAL" == "REVIEWED" || "$CU_VAL" == "INCOMPLETE" || "$CU_VAL" == "BLOCKED" ]]; then
        PASS_EVT_ROWS+=("cross_unit|cross_unit:${CU_VAL}|1")
        AUTO_DELTA=$((AUTO_DELTA + 1))
      fi
      CUR_PASSES="$L_PUSED"
      MIN_NEXT_PASSES=$((CUR_PASSES + AUTO_DELTA))
      if [[ "$PASSES_USED_SET" == "true" ]]; then
        if [[ "$PASSES_USED" -lt "$CUR_PASSES" ]]; then
          printf 'LEDGER_FAIL: passes_used cannot be reduced or reset (%s->%s)\n' "$CUR_PASSES" "$PASSES_USED"
          exit 1
        fi
        if [[ "$PASSES_USED" -lt "$MIN_NEXT_PASSES" ]]; then
          printf 'LEDGER_FAIL: passes_used (%s) cannot bypass consumed passes (minimum %s)\n' "$PASSES_USED" "$MIN_NEXT_PASSES"
          exit 1
        fi
        NEW_PASSES="$PASSES_USED"
        EXTRA_MANUAL=$((NEW_PASSES - MIN_NEXT_PASSES))
        if [[ "$EXTRA_MANUAL" -gt 0 ]]; then
          PASS_EVT_ROWS+=("manual|manual|${EXTRA_MANUAL}")
        fi
      else
        NEW_PASSES="$MIN_NEXT_PASSES"
      fi

      EVT_REF_SHA="none"
      if [[ -n "$TARGET_COMMIT_SHA" ]]; then
        EVT_REF_SHA="$TARGET_COMMIT_SHA"
      elif [[ "$L_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
        EVT_REF_SHA="$L_HEAD"
      fi
      if [[ ${#PASS_EVT_ROWS[@]} -gt 0 ]]; then
        for pev in "${PASS_EVT_ROWS[@]}"; do
          IFS='|' read -r p_sc p_kd p_dt <<< "$pev"
          NEXT_SEQ=$(( ${#P_ROWS[@]} + 1 ))
          L_PCHAIN="$(step_pass_chain "$REPO_ROOT" "$L_PCHAIN" "$NEXT_SEQ" "$p_sc" "$p_kd" "$p_dt" "$EVT_REF_SHA")" || exit 1
          P_ROWS+=("pass|${NEXT_SEQ}|${p_sc}|${p_kd}|${p_dt}|${EVT_REF_SHA}|${L_PCHAIN}")
        done
      fi
      L_PUSED="$NEW_PASSES"

      if [[ "$MAX_PASSES_SET" == "true" ]]; then
        L_MPASS="$MAX_PASSES"
      fi
      BS_VAL="$(printf '%s' "$(trim_str "$BUDGET_STATUS")" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      if [[ -n "$BS_VAL" ]]; then
        case "$BS_VAL" in OK|EXHAUSTED) ;; *) echo "LEDGER_FAIL: invalid --budget-status '$BS_VAL'"; exit 1 ;; esac
        if [[ "$BS_VAL" == "OK" && "$L_MPASS" -gt 0 && "$L_PUSED" -gt "$L_MPASS" ]]; then
          printf 'LEDGER_FAIL: cannot set budget_status=OK while passes_used (%s) exceeds max_passes (%s)\n' "$L_PUSED" "$L_MPASS"
          exit 1
        fi
        L_BSTAT="$BS_VAL"
      elif [[ "$L_MPASS" -gt 0 && "$L_PUSED" -gt "$L_MPASS" ]]; then
        L_BSTAT="EXHAUSTED"
      fi

      serialize_review_ledger
      write_atomic_lf_file "$LEDGER_FULL" "$_LEDGER_TXT"
      printf 'LEDGER_UPDATED: path=%s\n' "$LEDGER_REL"
      exit 0
    fi
    ;;

  evidence-check)
    REPO_ROOT="."
    SOURCE_PATHS=""
    MANIFEST_PATH=""
    WRITE_MANIFEST=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --source-paths) SOURCE_PATHS="${2:-}"; shift 2 ;;
        --manifest-path) MANIFEST_PATH="${2:-}"; shift 2 ;;
        --write-manifest) WRITE_MANIFEST=true; shift ;;
        *) echo "EVIDENCE_MISSING: unknown option $1" >&2; exit 1 ;;
      esac
    done

    if ! check_contained_repo_path "$REPO_ROOT" "$MANIFEST_PATH"; then
      echo "EVIDENCE_MISSING: invalid manifest path"
      exit 1
    fi
    MANIFEST_REL="$_CONTAINED_REL"
    MANIFEST_FULL="$_CONTAINED_FULL"

    split_path_csv_checked "$SOURCE_PATHS" "EVIDENCE_MISSING" "true" "EVIDENCE_MISSING: invalid path ."
    SRC_RAW=()
    [[ ${#_CHECKED_CSV_PATHS[@]} -gt 0 ]] && SRC_RAW=("${_CHECKED_CSV_PATHS[@]}")

    if $WRITE_MANIFEST; then
      if [[ ${#SRC_RAW[@]} -lt 1 ]]; then
        echo "EVIDENCE_MISSING: missing --source-paths"
        exit 1
      fi
      CHECKED_SRC=()
      for sp in "${SRC_RAW[@]}"; do
        if ! check_contained_repo_path "$REPO_ROOT" "$sp"; then
          echo "EVIDENCE_MISSING: invalid path $sp"
          exit 1
        fi
        CHECKED_SRC+=("$_CONTAINED_REL")
      done
      SORTED_SRC=()
      while IFS= read -r sp; do [[ -n "$sp" ]] && SORTED_SRC+=("$sp"); done < <(printf '%s\n' "${CHECKED_SRC[@]}" | LC_ALL=C sort -u)

      MISSING_ARR=()
      ENTRY_LINES=()
      for rel in "${SORTED_SRC[@]}"; do
        if ! check_contained_repo_path "$REPO_ROOT" "$rel"; then
          echo "EVIDENCE_MISSING: invalid path $rel"
          exit 1
        fi
        full="$_CONTAINED_FULL"
        if [[ ! -f "$full" ]]; then
          MISSING_ARR+=("$rel")
        else
          h="$(compute_file_sha256 "$full")" || { echo "EVIDENCE_MISSING: sha256 tool unavailable"; exit 1; }
          ENTRY_LINES+=("file=${h} ${rel}")
        fi
      done
      if [[ ${#MISSING_ARR[@]} -gt 0 ]]; then
        echo "EVIDENCE_MISSING: $(printf '%s\n' "${MISSING_ARR[@]}" | paste -sd ',' -)"
        exit 1
      fi

      HEAD_SHA="NO_HEAD"
      if run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet HEAD; then
        raw_head="$(trim_str "$_GIT_STDOUT")"
        [[ "$raw_head" =~ ^[0-9a-f]{40}$ ]] && HEAD_SHA="$raw_head"
      fi
      TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      BODY_STR="schema=b3-evidence-v1
head_sha=${HEAD_SHA}
timestamp_utc=${TS_UTC}"
      for el in "${ENTRY_LINES[@]}"; do
        BODY_STR="${BODY_STR}
${el}"
      done
      BODY_STR="${BODY_STR}
"
      write_atomic_lf_file "$MANIFEST_FULL" "$BODY_STR"
      printf 'EVIDENCE_WRITTEN: %d files -> %s\n' "${#ENTRY_LINES[@]}" "$MANIFEST_REL"
      exit 0
    fi

    if [[ ! -f "$MANIFEST_FULL" ]]; then
      echo "EVIDENCE_MISSING: missing manifest (${MANIFEST_REL})"
      exit 1
    fi

    HAS_SCHEMA=false
    HAS_HEAD=false
    HAS_TS=false
    SEEN_ENTRIES=$'\n'
    ENT_RELS=()
    ENT_HASHES=()
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      ln="$(trim_str "$raw_line")"
      [[ -z "$ln" ]] && continue
      if [[ "$ln" == "schema=b3-evidence-v1" ]]; then
        HAS_SCHEMA=true; continue
      elif [[ "$ln" =~ ^head_sha=([0-9a-f]{40}|NO_HEAD)$ ]]; then
        HAS_HEAD=true; continue
      elif [[ "$ln" =~ ^timestamp_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        HAS_TS=true; continue
      elif [[ "$ln" =~ ^file=([0-9a-f]{64})[[:space:]]+(.+)$ ]]; then
        h="${BASH_REMATCH[1]}"
        rp="$(trim_str "${BASH_REMATCH[2]}")"
        if ! check_contained_repo_path "$REPO_ROOT" "$rp"; then
          echo "EVIDENCE_MISSING: invalid path $rp"
          exit 1
        fi
        rel="$_CONTAINED_REL"
        if [[ "$SEEN_ENTRIES" == *$'\n'"${rel}"$'\n'* ]]; then
          echo "EVIDENCE_MISSING: duplicate entry $rel"
          exit 1
        fi
        SEEN_ENTRIES="${SEEN_ENTRIES}${rel}"$'\n'
        ENT_RELS+=("$rel")
        ENT_HASHES+=("$h")
      else
        echo "EVIDENCE_MISSING: invalid manifest (${MANIFEST_REL})"
        exit 1
      fi
    done < "$MANIFEST_FULL"

    if ! $HAS_SCHEMA || ! $HAS_HEAD || ! $HAS_TS || [[ ${#ENT_RELS[@]} -lt 1 ]]; then
      echo "EVIDENCE_MISSING: invalid manifest (${MANIFEST_REL})"
      exit 1
    fi

    if [[ ${#SRC_RAW[@]} -gt 0 ]]; then
      UNCOVERED=()
      for sp in "${SRC_RAW[@]}"; do
        if ! check_contained_repo_path "$REPO_ROOT" "$sp"; then
          echo "EVIDENCE_MISSING: invalid path $sp"
          exit 1
        fi
        rel="$_CONTAINED_REL"
        if [[ "$SEEN_ENTRIES" != *$'\n'"${rel}"$'\n'* ]]; then
          UNCOVERED+=("$rel")
        fi
      done
      if [[ ${#UNCOVERED[@]} -gt 0 ]]; then
        echo "EVIDENCE_MISSING: uncovered $(printf '%s\n' "${UNCOVERED[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        exit 1
      fi
    fi

    MISS_FILES=()
    STALE_FILES=()
    for ((idx = 0; idx < ${#ENT_RELS[@]}; idx++)); do
      rel="${ENT_RELS[$idx]}"
      exp_h="${ENT_HASHES[$idx]}"
      if ! check_contained_repo_path "$REPO_ROOT" "$rel"; then
        echo "EVIDENCE_MISSING: invalid path $rel"
        exit 1
      fi
      full="$_CONTAINED_FULL"
      if [[ ! -f "$full" ]]; then
        MISS_FILES+=("$rel")
      else
        cur_h="$(compute_file_sha256 "$full")" || { echo "EVIDENCE_MISSING: sha256 tool unavailable"; exit 1; }
        if [[ "$cur_h" != "$exp_h" ]]; then
          STALE_FILES+=("$rel")
        fi
      fi
    done

    if [[ ${#MISS_FILES[@]} -gt 0 ]]; then
      echo "EVIDENCE_MISSING: $(printf '%s\n' "${MISS_FILES[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      exit 1
    fi
    if [[ ${#STALE_FILES[@]} -gt 0 ]]; then
      echo "EVIDENCE_STALE: $(printf '%s\n' "${STALE_FILES[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      exit 2
    fi
    printf 'EVIDENCE_FRESH: %d files\n' "${#ENT_RELS[@]}"
    exit 0
    ;;

  merge-policy-check)
    REPO_ROOT="."
    POLICY_PATH=""
    PR_STATE="NONE"
    PR_STATE_SET=false
    CI_STATUS="UNKNOWN"
    CI_STATUS_SET=false
    REVIEW_STATUS="UNKNOWN"
    REVIEW_STATUS_SET=false
    BLOCKING_FINDINGS="0"
    GOV_STATUS="CLEAR"
    CHANGED_PATHS=""
    POST_MERGE=false
    MERGED_SHA=""
    MAIN_REF=""
    TARGET_REF=""
    AUTHORITY_REF=""
    BASE_SHA=""
    HEAD_SHA_ARG=""
    LEDGER_PATH=""
    RECEIPT_PATH=""
    IGNORE_DIRTY=""
    PR_NUMBER=""
    REPO_ARG=""
    TARGET_BRANCH=""
    LOCAL_ONLY=false
    REQUIRE_REMOTE_CI=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --policy-path) POLICY_PATH="${2:-}"; shift 2 ;;
        --pr-state) PR_STATE="${2:-}"; PR_STATE_SET=true; shift 2 ;;
        --ci-status) CI_STATUS="${2:-}"; CI_STATUS_SET=true; shift 2 ;;
        --review-status) REVIEW_STATUS="${2:-}"; REVIEW_STATUS_SET=true; shift 2 ;;
        --blocking-findings) BLOCKING_FINDINGS="${2:-}"; shift 2 ;;
        --governance-status) GOV_STATUS="${2:-}"; shift 2 ;;
        --changed-paths) CHANGED_PATHS="${2:-}"; shift 2 ;;
        --post-merge) POST_MERGE=true; shift ;;
        --merged-sha) MERGED_SHA="${2:-}"; shift 2 ;;
        --main-ref) MAIN_REF="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --authority-ref) AUTHORITY_REF="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --head-sha) HEAD_SHA_ARG="${2:-}"; shift 2 ;;
        --ledger-path) LEDGER_PATH="${2:-}"; shift 2 ;;
        --receipt-path) RECEIPT_PATH="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --pr-number) PR_NUMBER="${2:-}"; shift 2 ;;
        --repo) REPO_ARG="${2:-}"; shift 2 ;;
        --target-branch) TARGET_BRANCH="${2:-}"; shift 2 ;;
        --local-only) LOCAL_ONLY=true; shift ;;
        --require-remote-ci) REQUIRE_REMOTE_CI=true; shift ;;
        *) echo "MERGE_BLOCKED: unknown option $1" >&2; exit 1 ;;
      esac
    done

    MP_ERR_PFX="MERGE_BLOCKED"
    $POST_MERGE && MP_ERR_PFX="POST_MERGE_FAILED"
    split_path_csv_checked "$IGNORE_DIRTY" "$MP_ERR_PFX" "true"

    PR_STATE="$(trim_str "$PR_STATE")"; [[ -n "$PR_STATE" ]] || PR_STATE="NONE"
    CI_STATUS="$(trim_str "$CI_STATUS")"; [[ -n "$CI_STATUS" ]] || CI_STATUS="UNKNOWN"
    REVIEW_STATUS="$(trim_str "$REVIEW_STATUS")"; [[ -n "$REVIEW_STATUS" ]] || REVIEW_STATUS="UNKNOWN"
    GOV_STATUS="$(trim_str "$GOV_STATUS")"; [[ -n "$GOV_STATUS" ]] || GOV_STATUS="CLEAR"
    BLOCKING_FINDINGS="$(trim_str "$BLOCKING_FINDINGS")"; [[ -n "$BLOCKING_FINDINGS" ]] || BLOCKING_FINDINGS="0"
    PR_NUM_TRIM="$(trim_str "$PR_NUMBER")"
    TARGET_BR_TRIM="$(trim_str "$TARGET_BRANCH")"
    T_REF_TRIM="$(trim_str "$TARGET_REF")"
    M_REF_TRIM="$(trim_str "$MAIN_REF")"
    AUTH_REF_TRIM="$(trim_str "$AUTHORITY_REF")"
    HEAD_SHA_TRIM="$(trim_str "$HEAD_SHA_ARG")"

    case "$PR_STATE" in OPEN|MERGED|CLOSED|NONE) ;; *) echo "MERGE_BLOCKED: invalid_pr_state=$PR_STATE"; exit 1 ;; esac
    case "$CI_STATUS" in PASS|FAIL|PENDING|UNKNOWN) ;; *) echo "MERGE_BLOCKED: invalid_ci_status=$CI_STATUS"; exit 1 ;; esac
    case "$REVIEW_STATUS" in PASS|BLOCKED|PENDING|UNKNOWN) ;; *) echo "MERGE_BLOCKED: invalid_review_status=$REVIEW_STATUS"; exit 1 ;; esac
    case "$GOV_STATUS" in
      CLEAR|BLOCKED|MISSING_OWNER_DECISION|WITHHELD_PROMOTION|UNAUTHORIZED_AUTHORITY|INVALID_EDITORIAL_REVIEW|UNAUTHORIZED_REVIEWER) ;;
      *) echo "MERGE_BLOCKED: invalid_governance=$GOV_STATUS"; exit 1 ;;
    esac
    if [[ ! "$BLOCKING_FINDINGS" =~ ^[0-9]+$ ]]; then
      echo "MERGE_BLOCKED: invalid_blocking_findings=$BLOCKING_FINDINGS"
      exit 1
    fi
    BLOCKING_FINDINGS="$((10#$BLOCKING_FINDINGS))"
    if [[ -n "$TARGET_BR_TRIM" ]]; then
      if [[ "$TARGET_BR_TRIM" == -* || "$TARGET_BR_TRIM" =~ [[:space:][:cntrl:]] || "$TARGET_BR_TRIM" == *".."* ]]; then
        echo "${MP_ERR_PFX}: invalid_target_branch"
        exit 1
      fi
    fi
    if [[ -n "$T_REF_TRIM" && -n "$M_REF_TRIM" && "$T_REF_TRIM" != "$M_REF_TRIM" ]]; then
      echo "${MP_ERR_PFX}: conflicting_target_ref"
      exit 1
    fi
    EFF_TARGET_REF_ARG="${T_REF_TRIM:-$M_REF_TRIM}"
    _re_head='^(HEAD([~^].*)?|@([~^{].*)?)$'
    _re_ls_pol=$'^(100644|100755) blob ([0-9a-f]{40})\t\\.b3/research-policy\\.json$'

    if $POST_MERGE; then
      if $PR_STATE_SET && [[ "$PR_STATE" != "MERGED" ]]; then
        echo "POST_MERGE_FAILED: pr_state=$PR_STATE"
        exit 1
      fi
      M_REF="$EFF_TARGET_REF_ARG"
      if [[ -z "$M_REF" ]]; then
        echo "POST_MERGE_FAILED: missing_main_ref"
        exit 1
      fi
      M_REF_UP="$(printf '%s' "$M_REF" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      if [[ "$M_REF" == -* || "$M_REF" =~ [[:space:][:cntrl:]] || "$M_REF_UP" =~ $_re_head ]]; then
        echo "POST_MERGE_FAILED: invalid_main_ref"
        exit 1
      fi
      SYM_FULL=""
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --symbolic-full-name "$M_REF"; then
        SYM_FULL="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ "$SYM_FULL" != refs/heads/* && "$SYM_FULL" != refs/remotes/* ]]; then
        echo "POST_MERGE_FAILED: invalid_main_ref"
        exit 1
      fi
      LOCAL_TARGET_BRANCH=""
      if [[ "$SYM_FULL" == refs/heads/* ]]; then
        LOCAL_TARGET_BRANCH="${SYM_FULL#refs/heads/}"
      elif [[ "$SYM_FULL" =~ ^refs/remotes/[^/]+/(.+)$ ]]; then
        LOCAL_TARGET_BRANCH="${BASH_REMATCH[1]}"
      fi
      if [[ -z "$LOCAL_TARGET_BRANCH" ]]; then
        echo "POST_MERGE_FAILED: invalid_main_ref"
        exit 1
      fi
      if [[ -n "$TARGET_BR_TRIM" && "$TARGET_BR_TRIM" != "$LOCAL_TARGET_BRANCH" ]]; then
        echo "POST_MERGE_FAILED: target_branch_mismatch(expected=${TARGET_BR_TRIM},got=${LOCAL_TARGET_BRANCH})"
        exit 1
      fi
      M_SHA="$(trim_str "$MERGED_SHA")"
      if [[ -n "$M_SHA" && "$M_SHA" == -* ]]; then
        echo "POST_MERGE_FAILED: invalid_ref"
        exit 1
      fi
      if [[ -n "$HEAD_SHA_TRIM" && "$HEAD_SHA_TRIM" == -* ]]; then
        echo "POST_MERGE_FAILED: invalid_ref"
        exit 1
      fi

      if [[ -n "$PR_NUM_TRIM" ]]; then
        if [[ ! "$PR_NUM_TRIM" =~ ^[1-9][0-9]*$ ]]; then
          echo "POST_MERGE_FAILED: invalid_pr_number"
          exit 1
        fi
        invoke_b3_github_verify "post-merge" "$REPO_ROOT" "$REPO_ARG" "$PR_NUM_TRIM" "POST_MERGE_FAILED"
        if [[ "$GH_PR_NUMBER" != "$PR_NUM_TRIM" ]]; then
          echo "POST_MERGE_FAILED: pr_identity_mismatch"
          exit 1
        fi
        REPO_TRIM_PM="$(trim_str "$REPO_ARG")"
        if [[ -n "$REPO_TRIM_PM" ]]; then
          _gh_br_low="$(printf '%s' "$GH_BASE_REPO" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          _rs_low="$(printf '%s' "$REPO_TRIM_PM" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
          if [[ "$_gh_br_low" != "$_rs_low" ]]; then
            echo "POST_MERGE_FAILED: pr_identity_mismatch"
            exit 1
          fi
        fi
        if [[ "$GH_PR_MERGED" != "true" || "$GH_PR_STATE" != "CLOSED" ]]; then
          echo "POST_MERGE_FAILED: pr_not_merged(state=${GH_PR_STATE},merged=${GH_PR_MERGED})"
          exit 1
        fi
        if [[ ! "$GH_MERGE_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
          echo "POST_MERGE_FAILED: missing_merge_commit_sha"
          exit 1
        fi
        if [[ "$LOCAL_TARGET_BRANCH" != "$GH_BASE_REF" ]]; then
          echo "POST_MERGE_FAILED: target_branch_mismatch(expected=${GH_BASE_REF},got=${LOCAL_TARGET_BRANCH})"
          exit 1
        fi
        if [[ -n "$TARGET_BR_TRIM" && "$TARGET_BR_TRIM" != "$GH_BASE_REF" ]]; then
          echo "POST_MERGE_FAILED: target_branch_mismatch(expected=${GH_BASE_REF},got=${TARGET_BR_TRIM})"
          exit 1
        fi
        if [[ -n "$M_SHA" ]]; then
          CALLER_M_SHA=""
          if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${M_SHA}^{commit}"; then
            CALLER_M_SHA="$(trim_str "$_GIT_STDOUT")"
          fi
          if [[ ! "$CALLER_M_SHA" =~ ^[0-9a-f]{40}$ ]]; then
            echo "POST_MERGE_FAILED: unresolvable_commit"
            exit 1
          fi
          if [[ "$CALLER_M_SHA" != "$GH_MERGE_COMMIT_SHA" ]]; then
            echo "POST_MERGE_FAILED: merge_commit_sha_mismatch(expected=${GH_MERGE_COMMIT_SHA},got=${CALLER_M_SHA})"
            exit 1
          fi
        fi
        if [[ -n "$HEAD_SHA_TRIM" ]]; then
          CALLER_H_SHA=""
          if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${HEAD_SHA_TRIM}^{commit}"; then
            CALLER_H_SHA="$(trim_str "$_GIT_STDOUT")"
          fi
          if [[ ! "$CALLER_H_SHA" =~ ^[0-9a-f]{40}$ ]]; then
            echo "POST_MERGE_FAILED: invalid_head_sha"
            exit 1
          fi
          if [[ "$CALLER_H_SHA" != "$GH_HEAD_SHA" ]]; then
            echo "POST_MERGE_FAILED: head_sha_mismatch(expected=${GH_HEAD_SHA},got=${CALLER_H_SHA})"
            exit 1
          fi
        fi
        if [[ ( "$GH_COMPARE_STATUS" != "identical" && "$GH_COMPARE_STATUS" != "ahead" ) || "$GH_COMPARE_BEHIND" != "0" ]]; then
          echo "POST_MERGE_FAILED: merge_commit_not_in_remote_target(status=${GH_COMPARE_STATUS},target_ref=${GH_BASE_REF})"
          exit 1
        fi

        RES_MERGED=""
        RES_MAIN=""
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${GH_MERGE_COMMIT_SHA}^{commit}"; then
          RES_MERGED="$(trim_str "$_GIT_STDOUT")"
        fi
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${M_REF}^{commit}"; then
          RES_MAIN="$(trim_str "$_GIT_STDOUT")"
        fi
        if [[ ! "$RES_MERGED" =~ ^[0-9a-f]{40}$ || ! "$RES_MAIN" =~ ^[0-9a-f]{40}$ ]]; then
          echo "POST_MERGE_FAILED: unresolvable_commit"
          exit 1
        fi
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_MERGED" "$RES_MAIN"; then
          echo "POST_MERGE_FAILED: sha_not_in_target(sha=${RES_MERGED},target_ref=${GH_BASE_REF},main_ref=${M_REF})"
          exit 1
        fi

        if [[ -z "$GH_POLICY_AUTH_REF" || ! "$GH_POLICY_AUTH_SHA" =~ ^[0-9a-f]{40}$ ]]; then
          echo "POST_MERGE_FAILED: incomplete_pr_metadata"
          exit 1
        fi
        if ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${GH_POLICY_AUTH_SHA}^{commit}" || [[ "$(trim_str "$_GIT_STDOUT")" != "$GH_POLICY_AUTH_SHA" ]]; then
          echo "POST_MERGE_FAILED: policy_authority_not_fetched"
          exit 1
        fi
        if ! run_git_cmd_quiet "$REPO_ROOT" ls-tree "$GH_POLICY_AUTH_SHA" -- ".b3/research-policy.json"; then
          echo "POST_MERGE_FAILED: policy_authority_not_fetched"
          exit 1
        fi
        _gh_pm_ls="$(trim_str "$_GIT_STDOUT")"
        if [[ -n "$_gh_pm_ls" ]]; then
          if [[ ! "$_gh_pm_ls" =~ $_re_ls_pol ]]; then
            echo "POST_MERGE_FAILED: invalid_policy_path"
            exit 1
          fi
          if ! run_git_cmd_quiet "$REPO_ROOT" show "${GH_POLICY_AUTH_SHA}:.b3/research-policy.json"; then
            echo "POST_MERGE_FAILED: policy_not_in_authority"
            exit 1
          fi
          load_merge_policy_from_source "-" "$_GIT_STDOUT" "POST_MERGE_FAILED"
          if [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]]; then
            if ! branch_pattern_match "$GH_BASE_REF" "${_POL_ALLOWED_BR[@]}"; then
              echo "POST_MERGE_FAILED: target_branch_not_allowed(${GH_BASE_REF})"
              exit 1
            fi
          fi
        fi

        if ! run_git_cmd_quiet "$REPO_ROOT" rev-list --parents -n 1 "$RES_MERGED"; then
          echo "POST_MERGE_FAILED: unresolvable_commit"
          exit 1
        fi
        PAR_LINE="$(trim_str "$_GIT_STDOUT")"
        read -r -a PAR_TOKS <<< "$PAR_LINE"
        PAR_CNT=$((${#PAR_TOKS[@]} - 1))
        MERGE_KIND="squash_or_rebase"
        if [[ "$PAR_CNT" -ge 2 ]]; then
          MERGE_KIND="merge_commit"
          if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$GH_HEAD_SHA" "$RES_MERGED"; then
            echo "POST_MERGE_FAILED: merge_commit_head_mismatch"
            exit 1
          fi
        elif [[ "$RES_MERGED" == "$GH_HEAD_SHA" ]]; then
          MERGE_KIND="fast_forward"
        fi

        printf 'POST_MERGE_VERIFIED: mode=github pr=%s#%s pr_status=PR_MERGED sha=%s target_ref=%s main_ref=%s merge_kind=%s runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED\n' \
          "$GH_BASE_REPO" "$PR_NUM_TRIM" "$RES_MERGED" "$GH_BASE_REF" "$M_REF" "$MERGE_KIND"
        exit 0
      fi

      # Provider-neutral local post-merge verification (no --pr-number)
      if [[ -z "$M_SHA" ]]; then echo "POST_MERGE_FAILED: missing_merged_sha"; exit 1; fi
      if [[ ! "$M_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then echo "POST_MERGE_FAILED: invalid_merged_sha"; exit 1; fi
      if [[ -z "$HEAD_SHA_TRIM" ]]; then echo "POST_MERGE_FAILED: missing_head_sha"; exit 1; fi
      if [[ ! "$HEAD_SHA_TRIM" =~ ^[0-9a-fA-F]{40}$ ]]; then echo "POST_MERGE_FAILED: invalid_head_sha"; exit 1; fi

      RES_MERGED=""; RES_HEAD_PM=""; RES_MAIN=""
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${M_SHA}^{commit}"; then
        RES_MERGED="$(trim_str "$_GIT_STDOUT")"
      fi
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${HEAD_SHA_TRIM}^{commit}"; then
        RES_HEAD_PM="$(trim_str "$_GIT_STDOUT")"
      fi
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${M_REF}^{commit}"; then
        RES_MAIN="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ ! "$RES_MERGED" =~ ^[0-9a-f]{40}$ || ! "$RES_HEAD_PM" =~ ^[0-9a-f]{40}$ || ! "$RES_MAIN" =~ ^[0-9a-f]{40}$ ]]; then
        echo "POST_MERGE_FAILED: unresolvable_commit"
        exit 1
      fi

      RES_BASE_PM=""
      BASE_PM_TRIM="$(trim_str "$BASE_SHA")"
      if [[ -n "$BASE_PM_TRIM" ]]; then
        if [[ "$BASE_PM_TRIM" == -* || ! "$BASE_PM_TRIM" =~ ^[0-9a-fA-F]{40}$ ]]; then
          echo "POST_MERGE_FAILED: invalid_base_sha"
          exit 1
        fi
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${BASE_PM_TRIM}^{commit}"; then
          RES_BASE_PM="$(trim_str "$_GIT_STDOUT")"
        fi
        if [[ ! "$RES_BASE_PM" =~ ^[0-9a-f]{40}$ ]]; then
          echo "POST_MERGE_FAILED: invalid_base_sha"
          exit 1
        fi
        if [[ "$RES_BASE_PM" == "$RES_MERGED" ]]; then echo "POST_MERGE_FAILED: base_sha_equals_merged_sha"; exit 1; fi
        if [[ "$RES_BASE_PM" == "$RES_HEAD_PM" ]]; then echo "POST_MERGE_FAILED: base_sha_equals_head"; exit 1; fi
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_BASE_PM" "$RES_MERGED"; then
          echo "POST_MERGE_FAILED: base_not_ancestor_of_merged"
          exit 1
        fi
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_BASE_PM" "$RES_HEAD_PM"; then
          echo "POST_MERGE_FAILED: base_not_ancestor_of_head"
          exit 1
        fi
      fi

      HAS_ANY_REMOTE_PM=false
      HAS_ORIGIN_PM=false
      if run_git_cmd_quiet "$REPO_ROOT" remote; then
        while IFS= read -r rln; do
          rt="$(trim_str "${rln%$'\r'}")"
          if [[ -n "$rt" ]]; then
            HAS_ANY_REMOTE_PM=true
            [[ "$rt" == "origin" ]] && HAS_ORIGIN_PM=true
          fi
        done <<< "$_GIT_STDOUT"
      fi
      if ! $LOCAL_ONLY && $HAS_ANY_REMOTE_PM && ! $HAS_ORIGIN_PM; then
        echo "POST_MERGE_FAILED: origin_remote_missing"
        exit 1
      fi

      PM_TRUNK_SHA=""
      PM_TRUNK_BRANCH=""
      if $HAS_ORIGIN_PM; then
        if run_git_cmd_quiet "$REPO_ROOT" symbolic-ref -q refs/remotes/origin/HEAD; then
          _oh_full="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_oh_full" == refs/remotes/origin/* ]]; then
            if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${_oh_full}^{commit}"; then
              _oh_sha="$(trim_str "$_GIT_STDOUT")"
              if [[ "$_oh_sha" =~ ^[0-9a-f]{40}$ ]]; then
                PM_TRUNK_SHA="$_oh_sha"
                PM_TRUNK_BRANCH="${_oh_full#refs/remotes/origin/}"
              fi
            fi
          fi
        fi
        if [[ -z "$PM_TRUNK_SHA" ]]; then
          for _cand_br in main master; do
            if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/${_cand_br}^{commit}"; then
              _c_sha="$(trim_str "$_GIT_STDOUT")"
              if [[ "$_c_sha" =~ ^[0-9a-f]{40}$ ]]; then
                PM_TRUNK_SHA="$_c_sha"
                PM_TRUNK_BRANCH="$_cand_br"
                break
              fi
            fi
          done
        fi
      fi
      if [[ -z "$PM_TRUNK_SHA" ]]; then
        for _cand_br in main master; do
          if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/${_cand_br}^{commit}"; then
            _c_sha="$(trim_str "$_GIT_STDOUT")"
            if [[ "$_c_sha" =~ ^[0-9a-f]{40}$ ]]; then
              PM_TRUNK_SHA="$_c_sha"
              PM_TRUNK_BRANCH="$_cand_br"
              break
            fi
          fi
        done
      fi

      PM_ALLOWED_BRANCHES=()
      if [[ -n "$PM_TRUNK_SHA" ]]; then
        if run_git_cmd_quiet "$REPO_ROOT" ls-tree "$PM_TRUNK_SHA" -- ".b3/research-policy.json"; then
          _pm_ls="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_pm_ls" =~ $_re_ls_pol ]]; then
            if run_git_cmd_quiet "$REPO_ROOT" show "${PM_TRUNK_SHA}:.b3/research-policy.json"; then
              load_merge_policy_from_source "-" "$_GIT_STDOUT" "POST_MERGE_FAILED"
              [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && PM_ALLOWED_BRANCHES=("${_POL_ALLOWED_BR[@]}")
            fi
          fi
        fi
      fi
      if [[ ${#PM_ALLOWED_BRANCHES[@]} -gt 0 ]]; then
        if ! branch_pattern_match "$LOCAL_TARGET_BRANCH" "${PM_ALLOWED_BRANCHES[@]}"; then
          echo "POST_MERGE_FAILED: target_branch_not_allowed(${LOCAL_TARGET_BRANCH})"
          exit 1
        fi
      elif [[ -n "$PM_TRUNK_BRANCH" ]]; then
        if [[ "$LOCAL_TARGET_BRANCH" != "$PM_TRUNK_BRANCH" ]]; then
          echo "POST_MERGE_FAILED: target_branch_not_allowed(${LOCAL_TARGET_BRANCH})"
          exit 1
        fi
      else
        echo "POST_MERGE_FAILED: canonical_trunk_missing"
        exit 1
      fi

      if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_MERGED" "$RES_MAIN"; then
        echo "POST_MERGE_FAILED: sha_not_in_target(sha=${RES_MERGED},target_ref=${LOCAL_TARGET_BRANCH},main_ref=${M_REF})"
        exit 1
      fi
      if $HAS_ORIGIN_PM && ! $LOCAL_ONLY; then
        REM_TARGET_SHA=""
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/${LOCAL_TARGET_BRANCH}^{commit}"; then
          REM_TARGET_SHA="$(trim_str "$_GIT_STDOUT")"
        fi
        if [[ ! "$REM_TARGET_SHA" =~ ^[0-9a-f]{40}$ ]]; then
          echo "POST_MERGE_FAILED: remote_target_not_fetched"
          exit 1
        fi
        git_ls_remote_ref "$REPO_ROOT" "refs/heads/${LOCAL_TARGET_BRANCH}"
        if [[ "$_LS_REMOTE_STATUS" == "MISSING" ]]; then
          echo "POST_MERGE_FAILED: remote_target_ref_missing"
          exit 1
        fi
        if [[ "$_LS_REMOTE_STATUS" == "UNREACHABLE" ]]; then
          echo "PROVIDER_UNAVAILABLE: post_merge_remote_unverifiable"
          exit 2
        fi
        if [[ "$_LS_REMOTE_SHA" != "$REM_TARGET_SHA" ]]; then
          printf 'POST_MERGE_FAILED: stale_remote_target_ref(local=%s remote=%s)\n' "$REM_TARGET_SHA" "$_LS_REMOTE_SHA"
          exit 1
        fi
        if [[ -n "$PM_TRUNK_BRANCH" ]]; then
          if [[ "$PM_TRUNK_BRANCH" != "$LOCAL_TARGET_BRANCH" ]]; then
            git_ls_remote_ref "$REPO_ROOT" "refs/heads/${PM_TRUNK_BRANCH}"
            if [[ "$_LS_REMOTE_STATUS" == "MISSING" ]]; then
              echo "POST_MERGE_FAILED: remote_authority_ref_missing"
              exit 1
            fi
            if [[ "$_LS_REMOTE_STATUS" == "UNREACHABLE" ]]; then
              echo "PROVIDER_UNAVAILABLE: post_merge_remote_unverifiable"
              exit 2
            fi
            if [[ "$_LS_REMOTE_SHA" != "$PM_TRUNK_SHA" ]]; then
              printf 'POST_MERGE_FAILED: stale_remote_authority_ref(local=%s remote=%s)\n' "$PM_TRUNK_SHA" "$_LS_REMOTE_SHA"
              exit 1
            fi
          elif [[ "$_LS_REMOTE_SHA" != "$PM_TRUNK_SHA" ]]; then
            printf 'POST_MERGE_FAILED: stale_remote_authority_ref(local=%s remote=%s)\n' "$PM_TRUNK_SHA" "$_LS_REMOTE_SHA"
            exit 1
          fi
        fi
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_MERGED" "$REM_TARGET_SHA"; then
          echo "POST_MERGE_FAILED: merge_commit_not_in_remote_target(target_ref=${LOCAL_TARGET_BRANCH})"
          exit 1
        fi
      fi

      if ! run_git_cmd_quiet "$REPO_ROOT" rev-list --parents -n 1 "$RES_MERGED"; then
        echo "POST_MERGE_FAILED: unresolvable_commit"
        exit 1
      fi
      PAR_LINE="$(trim_str "$_GIT_STDOUT")"
      read -r -a PAR_TOKS <<< "$PAR_LINE"
      PAR_CNT=$((${#PAR_TOKS[@]} - 1))
      MERGE_KIND=""
      if [[ "$RES_MERGED" == "$RES_HEAD_PM" ]]; then
        MERGE_KIND="fast_forward"
      elif [[ "$PAR_CNT" -ge 2 ]]; then
        IN_FIRST_PAR=false
        if run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_HEAD_PM" "${PAR_TOKS[1]}"; then
          IN_FIRST_PAR=true
        fi
        IN_MERGED_PAR=false
        for (( _pidx=2; _pidx<${#PAR_TOKS[@]}; _pidx++ )); do
          if run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_HEAD_PM" "${PAR_TOKS[$_pidx]}"; then
            IN_MERGED_PAR=true
            break
          fi
        done
        if ! $IN_MERGED_PAR || $IN_FIRST_PAR; then
          echo "POST_MERGE_FAILED: merge_commit_head_mismatch"
          exit 1
        fi
        MERGE_KIND="merge_commit"
      elif [[ "$PAR_CNT" -eq 1 ]]; then
        if [[ -z "$RES_BASE_PM" ]]; then
          echo "POST_MERGE_FAILED: squash_or_rebase_requires_base_sha"
          exit 1
        fi
        P1_SHA="${PAR_TOKS[1]}"
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_BASE_PM" "$P1_SHA"; then
          echo "POST_MERGE_FAILED: base_not_ancestor_of_merged_parent"
          exit 1
        fi
        M_TREE=""; H_TREE=""
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${RES_MERGED}^{tree}"; then
          M_TREE="$(trim_str "$_GIT_STDOUT")"
        fi
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${RES_HEAD_PM}^{tree}"; then
          H_TREE="$(trim_str "$_GIT_STDOUT")"
        fi
        TREE_OK=false
        if [[ "$M_TREE" =~ ^[0-9a-f]{40}$ && "$P1_SHA" == "$RES_BASE_PM" && "$M_TREE" == "$H_TREE" ]]; then
          TREE_OK=true
        fi
        if ! $TREE_OK && [[ "$M_TREE" =~ ^[0-9a-f]{40}$ ]]; then
          if run_git_cmd_quiet "$REPO_ROOT" merge-tree --write-tree "$P1_SHA" "$RES_HEAD_PM"; then
            MT_LINE="${_GIT_STDOUT%%$'\n'*}"
            MT_LINE="$(trim_str "${MT_LINE%$'\r'}")"
            [[ "$MT_LINE" == "$M_TREE" ]] && TREE_OK=true
          fi
        fi
        if ! $TREE_OK; then
          echo "POST_MERGE_FAILED: squash_tree_mismatch"
          exit 1
        fi
        MERGE_KIND="squash_or_rebase"
      else
        echo "POST_MERGE_FAILED: merge_commit_head_mismatch"
        exit 1
      fi

      printf 'POST_MERGE_VERIFIED: mode=local sha=%s target_ref=%s main_ref=%s merge_kind=%s runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED\n' \
        "$RES_MERGED" "$LOCAL_TARGET_BRANCH" "$M_REF" "$MERGE_KIND"
      exit 0
    fi

    # --- Unified Provider-Neutral Pre-Merge Pipeline ---
    detect_repo_case_insensitive "$REPO_ROOT"
    _MP_CASE_INSENSITIVE="$_REPO_CASE_INSENSITIVE"
    if [[ -L "${REPO_ROOT%/}/.b3" ]] || { [[ -d "${REPO_ROOT%/}/.b3" ]] && is_dir_link_or_junction "$REPO_ROOT" ".b3"; }; then
      echo "MERGE_BLOCKED: invalid_policy_path"
      exit 1
    fi
    DEF_POL_FILE_FULL=""
    if [[ -e "${REPO_ROOT%/}/.b3/research-policy.json" || -L "${REPO_ROOT%/}/.b3/research-policy.json" ]]; then
      if ! check_contained_repo_path "$REPO_ROOT" ".b3/research-policy.json" || [[ ! -f "$_CONTAINED_FULL" || -L "$_CONTAINED_FULL" ]]; then
        echo "MERGE_BLOCKED: invalid_policy_path"
        exit 1
      fi
      DEF_POL_FILE_FULL="$_CONTAINED_FULL"
    fi

    POL_EXPLICIT=false
    POL_FILE_FULL=""
    POL_REL=""
    POLICY_PATH="$(trim_str "$POLICY_PATH")"
    if [[ -n "$POLICY_PATH" ]]; then
      POL_EXPLICIT=true
      if ! check_contained_repo_path "$REPO_ROOT" "$POLICY_PATH"; then
        echo "MERGE_BLOCKED: invalid_policy_path"
        exit 1
      fi
      if [[ ! -f "$_CONTAINED_FULL" || -L "$_CONTAINED_FULL" ]]; then
        echo "MERGE_BLOCKED: missing_policy"
        exit 1
      fi
      POL_FILE_FULL="$_CONTAINED_FULL"
      POL_REL="$_CONTAINED_REL"
    fi

    CHANGED_ARR=()
    _seen_chg="|"
    TRIM_CP="$(trim_str "$CHANGED_PATHS")"
    if [[ -n "$TRIM_CP" && "$TRIM_CP" != "[]" && "$TRIM_CP" != "none" ]]; then
      RAW_CP="$CHANGED_PATHS"
      while [[ "$RAW_CP" == " "* ]]; do RAW_CP="${RAW_CP# }"; done
      if [[ "$RAW_CP" == "["* && "$RAW_CP" == *"]" ]]; then
        RAW_CP="${RAW_CP#\[}"
        RAW_CP="${RAW_CP%\]}"
      fi
      _cp_rem="$RAW_CP"
      while true; do
        if [[ "$_cp_rem" == *,* ]]; then
          _cp_tok="${_cp_rem%%,*}"
          _cp_rem="${_cp_rem#*,}"
          _cp_more=true
        else
          _cp_tok="$_cp_rem"
          _cp_rem=""
          _cp_more=false
        fi
        _cp_tok_slash="${_cp_tok//\\//}"
        [[ "$_cp_tok_slash" == "./" ]] && _cp_tok_slash="."
        if [[ "$_cp_tok_slash" != "." ]] && ! is_valid_literal_git_path "$_cp_tok_slash"; then
          while [[ "$_cp_tok_slash" == " "* ]]; do _cp_tok_slash="${_cp_tok_slash# }"; done
          if ! is_valid_literal_git_path "$_cp_tok_slash"; then
            echo "MERGE_BLOCKED: invalid_changed_path"
            exit 1
          fi
        fi
        if [[ "$_seen_chg" != *"|${_cp_tok_slash}|"* ]]; then
          _seen_chg+="${_cp_tok_slash}|"
          CHANGED_ARR+=("$_cp_tok_slash")
        fi
        $_cp_more || break
      done
    fi

    if [[ -n "$EFF_TARGET_REF_ARG" ]]; then
      _t_up="$(printf '%s' "$EFF_TARGET_REF_ARG" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      if [[ "$EFF_TARGET_REF_ARG" == -* || "$EFF_TARGET_REF_ARG" =~ [[:space:][:cntrl:]] || "$_t_up" =~ $_re_head ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
    fi
    if [[ -n "$AUTH_REF_TRIM" ]]; then
      _a_up="$(printf '%s' "$AUTH_REF_TRIM" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
      if [[ "$AUTH_REF_TRIM" == -* || "$AUTH_REF_TRIM" =~ [[:space:][:cntrl:]] || "$_a_up" =~ $_re_head ]]; then
        echo "MERGE_BLOCKED: invalid_authority_ref"
        exit 1
      fi
    fi

    LIVE_HEAD_SHA=""
    if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "HEAD^{commit}"; then
      _hp="$(trim_str "$_GIT_STDOUT")"
      [[ "$_hp" =~ ^[0-9a-f]{40}$ ]] && LIVE_HEAD_SHA="$_hp"
    fi
    if [[ -n "$HEAD_SHA_TRIM" ]]; then
      if [[ "$HEAD_SHA_TRIM" == -* ]]; then echo "MERGE_BLOCKED: invalid_head"; exit 1; fi
      CALLER_HEAD_SHA=""
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${HEAD_SHA_TRIM}^{commit}"; then
        CALLER_HEAD_SHA="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ ! "$CALLER_HEAD_SHA" =~ ^[0-9a-f]{40}$ || -z "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: invalid_head"
        exit 1
      fi
      if [[ "$CALLER_HEAD_SHA" != "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: head_sha_mismatch"
        exit 1
      fi
    fi

    HAS_ANY_REMOTE=false
    HAS_ORIGIN=false
    if run_git_cmd_quiet "$REPO_ROOT" remote; then
      while IFS= read -r rln; do
        rt="$(trim_str "${rln%$'\r'}")"
        if [[ -n "$rt" ]]; then
          HAS_ANY_REMOTE=true
          [[ "$rt" == "origin" ]] && HAS_ORIGIN=true
        fi
      done <<< "$_GIT_STDOUT"
    fi

    CUR_SYM_FULL=""
    if run_git_cmd_quiet "$REPO_ROOT" symbolic-ref -q HEAD; then
      CUR_SYM_FULL="$(trim_str "$_GIT_STDOUT")"
    fi

    CANON_AUTH_FULL=""
    CANON_AUTH_BRANCH=""
    CANON_AUTH_SHA=""
    if $HAS_ORIGIN; then
      if run_git_cmd_quiet "$REPO_ROOT" symbolic-ref -q refs/remotes/origin/HEAD; then
        _oh_full="$(trim_str "$_GIT_STDOUT")"
        if [[ "$_oh_full" == refs/remotes/origin/* ]]; then
          if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${_oh_full}^{commit}"; then
            _oh_sha="$(trim_str "$_GIT_STDOUT")"
            if [[ "$_oh_sha" =~ ^[0-9a-f]{40}$ ]]; then
              CANON_AUTH_FULL="$_oh_full"
              CANON_AUTH_BRANCH="${_oh_full#refs/remotes/origin/}"
              CANON_AUTH_SHA="$_oh_sha"
            fi
          fi
        fi
      fi
      if [[ -z "$CANON_AUTH_SHA" ]]; then
        for _cand_br in main master; do
          _c_full="refs/remotes/origin/${_cand_br}"
          if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${_c_full}^{commit}"; then
            _c_sha="$(trim_str "$_GIT_STDOUT")"
            if [[ "$_c_sha" =~ ^[0-9a-f]{40}$ ]]; then
              CANON_AUTH_FULL="$_c_full"
              CANON_AUTH_BRANCH="$_cand_br"
              CANON_AUTH_SHA="$_c_sha"
              break
            fi
          fi
        done
      fi
    elif ! $HAS_ANY_REMOTE; then
      for _cand_br in main master; do
        _c_full="refs/heads/${_cand_br}"
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${_c_full}^{commit}"; then
          _c_sha="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_c_sha" =~ ^[0-9a-f]{40}$ ]]; then
            CANON_AUTH_FULL="$_c_full"
            CANON_AUTH_BRANCH="$_cand_br"
            CANON_AUTH_SHA="$_c_sha"
            break
          fi
        fi
      done
    fi

    CALLER_AUTH_SYM_FULL=""
    CALLER_AUTH_BRANCH=""
    if [[ -n "$AUTH_REF_TRIM" ]]; then
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --symbolic-full-name "$AUTH_REF_TRIM"; then
        CALLER_AUTH_SYM_FULL="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ "$CALLER_AUTH_SYM_FULL" != refs/heads/* && "$CALLER_AUTH_SYM_FULL" != refs/remotes/* ]]; then
        echo "MERGE_BLOCKED: invalid_authority_ref"
        exit 1
      fi
      if [[ -n "$CUR_SYM_FULL" && "$CALLER_AUTH_SYM_FULL" == "$CUR_SYM_FULL" ]]; then
        echo "MERGE_BLOCKED: invalid_authority_ref"
        exit 1
      fi
      if [[ "$CALLER_AUTH_SYM_FULL" == refs/heads/* ]]; then
        CALLER_AUTH_BRANCH="${CALLER_AUTH_SYM_FULL#refs/heads/}"
      elif [[ "$CALLER_AUTH_SYM_FULL" =~ ^refs/remotes/[^/]+/(.+)$ ]]; then
        CALLER_AUTH_BRANCH="${BASH_REMATCH[1]}"
      fi
      if [[ -n "$CANON_AUTH_FULL" && "$CALLER_AUTH_SYM_FULL" != "$CANON_AUTH_FULL" ]]; then
        echo "MERGE_BLOCKED: authority_ref_mismatch"
        exit 1
      fi
    fi

    EFFECTIVE_POL_REL="${POL_REL:-.b3/research-policy.json}"
    _pr_low="$(printf '%s' "$EFFECTIVE_POL_REL" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    POL_IS_DEFAULT_PATH=true
    if $POL_EXPLICIT && [[ "$_pr_low" != ".b3/research-policy.json" ]]; then
      POL_IS_DEFAULT_PATH=false
    fi
    POL_PROT_ARR=(".b3/research-policy.json")
    if ! $POL_IS_DEFAULT_PATH; then
      POL_PROT_ARR+=("$EFFECTIVE_POL_REL")
    fi

    AUTO_MERGE="disabled"
    ALLOW_PROT="false"
    REQ_CI="false"
    REQ_REV="true"
    PROT_ARR=()
    ALLOWED_BRANCHES=()

    FALLBACK_LOCAL_TRUNK_SHA=""
    if [[ -z "$CANON_AUTH_SHA" ]] && ! $HAS_ANY_REMOTE; then
      for _cand_br in main master; do
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/${_cand_br}^{commit}"; then
          _fb_sha="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_fb_sha" =~ ^[0-9a-f]{40}$ ]]; then
            FALLBACK_LOCAL_TRUNK_SHA="$_fb_sha"
            break
          fi
        fi
      done
    fi
    INSPECT_AUTH_SHA="${CANON_AUTH_SHA:-$FALLBACK_LOCAL_TRUNK_SHA}"
    IS_GITHUB_PR_MODE=false
    if [[ -n "$PR_NUM_TRIM" ]] && ! $LOCAL_ONLY; then
      IS_GITHUB_PR_MODE=true
    fi
    if ! $IS_GITHUB_PR_MODE && ! $LOCAL_ONLY && $HAS_ANY_REMOTE && ! $HAS_ORIGIN; then
      echo "MERGE_BLOCKED: origin_remote_missing"
      exit 1
    fi

    if ! $POL_IS_DEFAULT_PATH; then
      load_merge_policy_from_source "$POL_FILE_FULL" "" "MERGE_BLOCKED"
      AUTO_MERGE="$_POL_AUTO_MERGE"
      ALLOW_PROT="$_POL_ALLOW_PROT"
      REQ_CI="$_POL_REQ_CI"
      REQ_REV="$_POL_REQ_REV"
      [[ ${#_POL_PROT_ARR[@]} -gt 0 ]] && PROT_ARR=("${_POL_PROT_ARR[@]}")
      [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && ALLOWED_BRANCHES=("${_POL_ALLOWED_BR[@]}")
      if ! $IS_GITHUB_PR_MODE && [[ -n "$INSPECT_AUTH_SHA" ]]; then
        if run_git_cmd_quiet "$REPO_ROOT" ls-tree "$INSPECT_AUTH_SHA" -- ".b3/research-policy.json"; then
          _tls_ln="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_tls_ln" =~ $_re_ls_pol ]] && run_git_cmd_quiet "$REPO_ROOT" show "${INSPECT_AUTH_SHA}:.b3/research-policy.json"; then
            load_merge_policy_from_source "-" "$_GIT_STDOUT" "MERGE_BLOCKED"
            [[ "$_POL_REQ_CI" == "true" ]] && REQ_CI="true"
            [[ "$_POL_REQ_REV" == "true" ]] && REQ_REV="true"
            if [[ ${#_POL_PROT_ARR[@]} -gt 0 ]]; then
              _seen_tpp="|"
              if [[ ${#PROT_ARR[@]} -gt 0 ]]; then
                for _epp in "${PROT_ARR[@]}"; do _seen_tpp+="${_epp}|"; done
              fi
              for _tpp in "${_POL_PROT_ARR[@]}"; do
                if [[ "$_seen_tpp" != *"|${_tpp}|"* ]]; then
                  _seen_tpp+="${_tpp}|"
                  PROT_ARR+=("$_tpp")
                fi
              done
              [[ "$_POL_ALLOW_PROT" != "true" ]] && ALLOW_PROT="false"
            fi
          fi
        fi
      fi
    elif ! $IS_GITHUB_PR_MODE; then
      AUTH_HAS_COMMITTED_POL=false
      if [[ -n "$INSPECT_AUTH_SHA" ]]; then
        if run_git_cmd_quiet "$REPO_ROOT" ls-tree "$INSPECT_AUTH_SHA" -- ".b3/research-policy.json"; then
          _als_ln="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_als_ln" =~ $_re_ls_pol ]]; then
            AUTH_HAS_COMMITTED_POL=true
            if ! run_git_cmd_quiet "$REPO_ROOT" show "${INSPECT_AUTH_SHA}:.b3/research-policy.json"; then
              echo "MERGE_BLOCKED: policy_not_in_authority"
              exit 1
            fi
            load_merge_policy_from_source "-" "$_GIT_STDOUT" "MERGE_BLOCKED"
            AUTO_MERGE="$_POL_AUTO_MERGE"
            ALLOW_PROT="$_POL_ALLOW_PROT"
            REQ_CI="$_POL_REQ_CI"
            REQ_REV="$_POL_REQ_REV"
            [[ ${#_POL_PROT_ARR[@]} -gt 0 ]] && PROT_ARR=("${_POL_PROT_ARR[@]}")
            [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && ALLOWED_BRANCHES=("${_POL_ALLOWED_BR[@]}")
          fi
        fi
      fi
      if $AUTH_HAS_COMMITTED_POL; then
        if [[ -n "$INSPECT_AUTH_SHA" && -n "$LIVE_HEAD_SHA" && "$INSPECT_AUTH_SHA" != "$LIVE_HEAD_SHA" ]]; then
          _mb_rc_i=0
          if run_git_cmd_quiet "$REPO_ROOT" merge-base "$INSPECT_AUTH_SHA" "$LIVE_HEAD_SHA"; then _mb_rc_i=0; else _mb_rc_i=$?; fi
          if [[ $_mb_rc_i -eq 0 ]]; then
            _mb_insp="$(trim_str "$_GIT_STDOUT")"
            if [[ "$_mb_insp" =~ ^[0-9a-f]{40}$ ]]; then
              run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${_mb_insp}..${LIVE_HEAD_SHA}" -- ".b3/research-policy.json" || exit 1
              if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then
                echo "MERGE_BLOCKED: policy_modified_in_pr"
                exit 1
              fi
            fi
          elif [[ $_mb_rc_i -gt 1 ]]; then
            echo "MERGE_BLOCKED: git_diff_failed"
            exit 1
          fi
        fi
        run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --cached --name-status -z -- ".b3/research-policy.json" || exit 1
        if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then echo "MERGE_BLOCKED: policy_modified_in_pr"; exit 1; fi
        run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z -- ".b3/research-policy.json" || exit 1
        if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then echo "MERGE_BLOCKED: policy_modified_in_pr"; exit 1; fi
        run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z HEAD -- ".b3/research-policy.json" || exit 1
        if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then echo "MERGE_BLOCKED: policy_modified_in_pr"; exit 1; fi
      else
        if [[ -n "$INSPECT_AUTH_SHA" && -n "$LIVE_HEAD_SHA" && "$INSPECT_AUTH_SHA" != "$LIVE_HEAD_SHA" ]]; then
          _mb_rc_i2=0
          if run_git_cmd_quiet "$REPO_ROOT" merge-base "$INSPECT_AUTH_SHA" "$LIVE_HEAD_SHA"; then _mb_rc_i2=0; else _mb_rc_i2=$?; fi
          if [[ $_mb_rc_i2 -eq 0 ]]; then
            _mb_insp="$(trim_str "$_GIT_STDOUT")"
            if [[ "$_mb_insp" =~ ^[0-9a-f]{40}$ ]]; then
              run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${_mb_insp}..${LIVE_HEAD_SHA}" -- ".b3/research-policy.json" || exit 1
              if [[ ${#_GIT_PATHS_Z[@]} -gt 0 ]]; then
                echo "MERGE_BLOCKED: policy_not_in_authority"
                exit 1
              fi
            fi
          elif [[ $_mb_rc_i2 -gt 1 ]]; then
            echo "MERGE_BLOCKED: git_diff_failed"
            exit 1
          fi
          if [[ -n "$DEF_POL_FILE_FULL" ]]; then
            echo "MERGE_BLOCKED: policy_not_in_authority"
            exit 1
          fi
        elif [[ -n "$DEF_POL_FILE_FULL" ]]; then
          load_merge_policy_from_source "$DEF_POL_FILE_FULL" "" "MERGE_BLOCKED"
          if [[ "$_POL_AUTO_MERGE" == "authorized" ]]; then
            echo "MERGE_BLOCKED: policy_not_in_authority"
            exit 1
          fi
          AUTO_MERGE="disabled"
          ALLOW_PROT="$_POL_ALLOW_PROT"
          REQ_CI="$_POL_REQ_CI"
          REQ_REV="true"
          [[ ${#_POL_PROT_ARR[@]} -gt 0 ]] && PROT_ARR=("${_POL_PROT_ARR[@]}")
          [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && ALLOWED_BRANCHES=("${_POL_ALLOWED_BR[@]}")
        fi
      fi
    fi

    if [[ "$GOV_STATUS" != "CLEAR" ]]; then
      echo "MERGE_BLOCKED: governance=$GOV_STATUS"
      exit 1
    fi

    LOCAL_PRE_CHANGED_ARR=()
    _seen_lpre="|"
    if [[ ${#CHANGED_ARR[@]} -gt 0 ]]; then
      for cp in "${CHANGED_ARR[@]}"; do
        if [[ "$_seen_lpre" != *"|${cp}|"* ]]; then
          _seen_lpre+="${cp}|"
          LOCAL_PRE_CHANGED_ARR+=("$cp")
        fi
      done
    fi
    if ! $IS_GITHUB_PR_MODE && [[ -n "$INSPECT_AUTH_SHA" && -n "$LIVE_HEAD_SHA" && "$INSPECT_AUTH_SHA" != "$LIVE_HEAD_SHA" ]]; then
      _mb_rc_c=0
      if run_git_cmd_quiet "$REPO_ROOT" merge-base "$INSPECT_AUTH_SHA" "$LIVE_HEAD_SHA"; then _mb_rc_c=0; else _mb_rc_c=$?; fi
      if [[ $_mb_rc_c -eq 0 ]]; then
        _mb_chg="$(trim_str "$_GIT_STDOUT")"
        if [[ "$_mb_chg" =~ ^[0-9a-f]{40}$ ]]; then
          run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${_mb_chg}..${LIVE_HEAD_SHA}" -- || exit 1
          for lp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
            [[ -n "$lp" ]] || continue
            is_checkpoint_dir "$lp" && continue
            if [[ "$_seen_lpre" != *"|${lp}|"* ]]; then
              _seen_lpre+="${lp}|"
              LOCAL_PRE_CHANGED_ARR+=("$lp")
            fi
          done
        fi
      elif [[ $_mb_rc_c -gt 1 ]]; then
        echo "MERGE_BLOCKED: git_diff_failed"
        exit 1
      fi
    fi

    if [[ ${#PROT_ARR[@]} -gt 0 && "$ALLOW_PROT" != "true" && ${#LOCAL_PRE_CHANGED_ARR[@]} -gt 0 ]]; then
      PROT_HITS=()
      for cp in "${LOCAL_PRE_CHANGED_ARR[@]}"; do
        if protected_path_match_ci "$cp" "${PROT_ARR[@]}"; then
          PROT_HITS+=("$cp")
        fi
      done
      if [[ ${#PROT_HITS[@]} -gt 0 ]]; then
        echo "MERGE_BLOCKED: protected_paths=$(printf '%s\n' "${PROT_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        exit 1
      fi
    fi
    if [[ ${#CHANGED_ARR[@]} -gt 0 ]]; then
      for cp in "${CHANGED_ARR[@]}"; do
        if protected_path_match_ci "$cp" "${POL_PROT_ARR[@]}"; then
          echo "MERGE_BLOCKED: policy_modified_in_pr"
          exit 1
        fi
      done
    fi

    if [[ "$BLOCKING_FINDINGS" -gt 0 ]]; then
      echo "MERGE_BLOCKED: blocking_findings=$BLOCKING_FINDINGS"
      exit 1
    fi

    # Caller-supplied negative signals always tighten (can block, never authorize)
    if $CI_STATUS_SET && [[ "$CI_STATUS" == "FAIL" || "$CI_STATUS" == "PENDING" ]]; then
      echo "MERGE_BLOCKED: ci_status=$CI_STATUS"
      exit 1
    fi
    if $REVIEW_STATUS_SET && [[ "$REVIEW_STATUS" == "BLOCKED" || "$REVIEW_STATUS" == "PENDING" ]]; then
      echo "MERGE_BLOCKED: review_status=$REVIEW_STATUS"
      exit 1
    fi
    if $PR_STATE_SET && [[ "$PR_STATE" == "CLOSED" || "$PR_STATE" == "MERGED" ]]; then
      echo "MERGE_BLOCKED: pr_state=$PR_STATE"
      exit 1
    fi

    if ! $POL_IS_DEFAULT_PATH; then
      if $IS_GITHUB_PR_MODE || [[ "$AUTO_MERGE" == "authorized" ]] || [[ -n "$INSPECT_AUTH_SHA" && -n "$LIVE_HEAD_SHA" && "$INSPECT_AUTH_SHA" != "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: policy_path_override_not_allowed"
        exit 1
      fi
    fi

    # --- GitHub PR Authorization Path (when --pr-number is supplied and !--local-only) ---
    if $IS_GITHUB_PR_MODE; then
      if [[ ! "$PR_NUM_TRIM" =~ ^[1-9][0-9]*$ ]]; then
        echo "MERGE_BLOCKED: invalid_pr_number"
        exit 1
      fi
      invoke_b3_github_verify "pre-merge" "$REPO_ROOT" "$REPO_ARG" "$PR_NUM_TRIM" "MERGE_BLOCKED"

      if [[ "$GH_PR_NUMBER" != "$PR_NUM_TRIM" ]]; then echo "MERGE_BLOCKED: pr_identity_mismatch"; exit 1; fi
      REPO_TRIM_GH="$(trim_str "$REPO_ARG")"
      if [[ -n "$REPO_TRIM_GH" ]]; then
        _gh_br_low="$(printf '%s' "$GH_BASE_REPO" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        _rs_low="$(printf '%s' "$REPO_TRIM_GH" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        if [[ "$_gh_br_low" != "$_rs_low" ]]; then
          echo "MERGE_BLOCKED: cross_repo_mismatch"
          exit 1
        fi
      fi
      if [[ "$GH_SAME_REPO" != "true" ]]; then echo "MERGE_BLOCKED: cross_repo_head_pr"; exit 1; fi
      if [[ "$GH_PR_STATE" != "OPEN" || "$GH_PR_MERGED" == "true" ]]; then echo "MERGE_BLOCKED: pr_state=$GH_PR_STATE"; exit 1; fi
      if [[ "$GH_PR_DRAFT" == "true" ]]; then echo "MERGE_BLOCKED: pr_is_draft"; exit 1; fi

      if [[ -z "$GH_BASE_REF" || -z "$GH_POLICY_AUTH_REF" || ! "$GH_PR_BASE_SHA" =~ ^[0-9a-f]{40}$ || ! "$GH_LIVE_TARGET_SHA" =~ ^[0-9a-f]{40}$ || ! "$GH_HEAD_SHA" =~ ^[0-9a-f]{40}$ || ! "$GH_POLICY_AUTH_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "MERGE_BLOCKED: incomplete_pr_metadata"
        exit 1
      fi

      if [[ "$GH_LIVE_TARGET_SHA" != "$GH_PR_BASE_SHA" ]]; then
        echo "MERGE_BLOCKED: target_branch_moved"
        exit 1
      fi
      if [[ -n "$TARGET_BR_TRIM" && "$TARGET_BR_TRIM" != "$GH_BASE_REF" ]]; then
        echo "MERGE_BLOCKED: target_ref_mismatch"
        exit 1
      fi
      if [[ -n "$EFF_TARGET_REF_ARG" ]]; then
        T_SYM_GH=""
        T_BR_GH=""
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --symbolic-full-name "$EFF_TARGET_REF_ARG"; then
          T_SYM_GH="$(trim_str "$_GIT_STDOUT")"
          if [[ "$T_SYM_GH" == refs/heads/* ]]; then
            T_BR_GH="${T_SYM_GH#refs/heads/}"
          elif [[ "$T_SYM_GH" =~ ^refs/remotes/origin/(.+)$ ]]; then
            T_BR_GH="${BASH_REMATCH[1]}"
          fi
        fi
        if [[ -z "$T_BR_GH" || "$T_BR_GH" != "$GH_BASE_REF" ]]; then
          echo "MERGE_BLOCKED: target_ref_mismatch"
          exit 1
        fi
      fi
      if [[ -n "$CALLER_AUTH_BRANCH" && "$CALLER_AUTH_BRANCH" != "$GH_POLICY_AUTH_REF" ]]; then
        echo "MERGE_BLOCKED: authority_ref_mismatch"
        exit 1
      fi

      BASE_TRIM="$(trim_str "$BASE_SHA")"
      if [[ -n "$BASE_TRIM" ]]; then
        if [[ "$BASE_TRIM" == -* ]] || ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${BASE_TRIM}^{commit}"; then
          echo "MERGE_BLOCKED: invalid_base_sha"
          exit 1
        fi
        CALLER_BASE_SHA="$(trim_str "$_GIT_STDOUT")"
        if [[ ! "$CALLER_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
          echo "MERGE_BLOCKED: invalid_base_sha"
          exit 1
        fi
        if [[ "$CALLER_BASE_SHA" != "$GH_LIVE_TARGET_SHA" ]]; then
          if [[ -n "$LIVE_HEAD_SHA" && "$CALLER_BASE_SHA" == "$LIVE_HEAD_SHA" ]]; then
            echo "MERGE_BLOCKED: base_sha_equals_head"
            exit 1
          fi
          echo "MERGE_BLOCKED: base_sha_mismatch"
          exit 1
        fi
      fi
      RES_BASE_SHA="$GH_LIVE_TARGET_SHA"

      if [[ -z "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: invalid_head"
        exit 1
      fi
      if [[ "$LIVE_HEAD_SHA" != "$GH_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: head_sha_mismatch"
        exit 1
      fi
      if [[ "$RES_BASE_SHA" == "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: base_sha_equals_head"
        exit 1
      fi

      if ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${RES_BASE_SHA}^{commit}" || [[ "$(trim_str "$_GIT_STDOUT")" != "$RES_BASE_SHA" ]]; then
        echo "MERGE_BLOCKED: target_sha_not_fetched"
        exit 1
      fi
      if ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${GH_POLICY_AUTH_SHA}^{commit}" || [[ "$(trim_str "$_GIT_STDOUT")" != "$GH_POLICY_AUTH_SHA" ]]; then
        echo "MERGE_BLOCKED: policy_authority_not_fetched"
        exit 1
      fi

      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/${GH_BASE_REF}^{commit}"; then
        REM_TRACK_SHA="$(trim_str "$_GIT_STDOUT")"
        if [[ "$REM_TRACK_SHA" =~ ^[0-9a-f]{40}$ && "$REM_TRACK_SHA" != "$RES_BASE_SHA" ]]; then
          echo "MERGE_BLOCKED: target_branch_moved"
          exit 1
        fi
      fi
      if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_BASE_SHA" "$LIVE_HEAD_SHA"; then
        echo "MERGE_BLOCKED: target_branch_moved"
        exit 1
      fi

      AUTH_HAS_POLICY=false
      if run_git_cmd_quiet "$REPO_ROOT" ls-tree "$GH_POLICY_AUTH_SHA" -- ".b3/research-policy.json"; then
        AUTH_LS_LINE="$(trim_str "$_GIT_STDOUT")"
        if [[ "$AUTH_LS_LINE" =~ $_re_ls_pol ]]; then
          AUTH_HAS_POLICY=true
        fi
      fi
      AUTH_AUTO_MERGE="disabled"
      AUTH_ALLOW_PROT="false"
      AUTH_REQ_CI="false"
      AUTH_PROT_ARR=()
      AUTH_ALLOWED_BR=()
      GH_POL_VIOLATION_REASON="policy_not_in_authority"
      if $AUTH_HAS_POLICY; then
        GH_POL_VIOLATION_REASON="policy_modified_in_pr"
        if ! run_git_cmd_quiet "$REPO_ROOT" show "${GH_POLICY_AUTH_SHA}:.b3/research-policy.json"; then
          echo "MERGE_BLOCKED: policy_not_in_authority"
          exit 1
        fi
        load_merge_policy_from_source "-" "$_GIT_STDOUT" "MERGE_BLOCKED"
        AUTH_AUTO_MERGE="$_POL_AUTO_MERGE"
        AUTH_ALLOW_PROT="$_POL_ALLOW_PROT"
        AUTH_REQ_CI="$_POL_REQ_CI"
        [[ ${#_POL_PROT_ARR[@]} -gt 0 ]] && AUTH_PROT_ARR=("${_POL_PROT_ARR[@]}")
        [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && AUTH_ALLOWED_BR=("${_POL_ALLOWED_BR[@]}")
      else
        if $POL_EXPLICIT || [[ -n "$DEF_POL_FILE_FULL" ]]; then
          echo "MERGE_BLOCKED: policy_not_in_authority"
          exit 1
        fi
      fi

      if [[ "$GH_BASE_REF" != "$GH_POLICY_AUTH_REF" ]]; then
        if ! run_git_cmd_quiet "$REPO_ROOT" merge-base "$GH_POLICY_AUTH_SHA" "$RES_BASE_SHA"; then
          echo "MERGE_BLOCKED: target_branch_unrelated_to_authority"
          exit 1
        fi
        MB_AUTH_SHA="$(trim_str "$_GIT_STDOUT")"
        if [[ ! "$MB_AUTH_SHA" =~ ^[0-9a-f]{40}$ ]]; then
          echo "MERGE_BLOCKED: target_branch_unrelated_to_authority"
          exit 1
        fi
        run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${MB_AUTH_SHA}..${RES_BASE_SHA}" -- || exit 1
        for tp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
          [[ -n "$tp" ]] || continue
          if protected_path_match_ci "$tp" "${POL_PROT_ARR[@]}"; then
            echo "MERGE_BLOCKED: target_branch_modified_policy"
            exit 1
          fi
        done
      fi

      HAS_DIRTY_WT=false
      for _dkind in staged wt untracked; do
        case "$_dkind" in
          staged) run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --cached --name-status -z -- || exit 1 ;;
          wt) run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z -- || exit 1 ;;
          untracked) run_git_paths_z "$REPO_ROOT" "names" "MERGE_BLOCKED" "" -- ls-files --others --exclude-standard -z || exit 1 ;;
        esac
        for dp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
          [[ -n "$dp" ]] || continue
          is_checkpoint_dir "$dp" && continue
          if protected_path_match_ci "$dp" "${POL_PROT_ARR[@]}"; then
            echo "MERGE_BLOCKED: $GH_POL_VIOLATION_REASON"
            exit 1
          fi
          HAS_DIRTY_WT=true
        done
      done
      if $HAS_DIRTY_WT; then
        echo "MERGE_BLOCKED: dirty_worktree"
        exit 1
      fi

      ALL_CHANGED=()
      _seen_all="|"
      if [[ ${#CHANGED_ARR[@]} -gt 0 ]]; then
        for cp in "${CHANGED_ARR[@]}"; do
          if [[ "$_seen_all" != *"|${cp}|"* ]]; then
            _seen_all+="${cp}|"
            ALL_CHANGED+=("$cp")
          fi
        done
      fi
      if [[ ${#GH_PR_CHANGED_FILES[@]} -gt 0 ]]; then
        for ghf in "${GH_PR_CHANGED_FILES[@]}"; do
          if ! is_valid_literal_git_path "$ghf"; then
            echo "MERGE_BLOCKED: invalid_pr_changed_path"
            exit 1
          fi
          if [[ "$_seen_all" != *"|${ghf}|"* ]]; then
            _seen_all+="${ghf}|"
            ALL_CHANGED+=("$ghf")
          fi
        done
      fi
      run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${RES_BASE_SHA}..${LIVE_HEAD_SHA}" -- || exit 1
      for gp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$gp" ]] || continue
        is_checkpoint_dir "$gp" && continue
        if [[ "$_seen_all" != *"|${gp}|"* ]]; then
          _seen_all+="${gp}|"
          ALL_CHANGED+=("$gp")
        fi
      done

      if [[ ${#ALL_CHANGED[@]} -gt 0 ]]; then
        for cp in "${ALL_CHANGED[@]}"; do
          if protected_path_match_ci "$cp" "${POL_PROT_ARR[@]}"; then
            echo "MERGE_BLOCKED: $GH_POL_VIOLATION_REASON"
            exit 1
          fi
        done
      fi
      if [[ ${#AUTH_PROT_ARR[@]} -gt 0 && "$AUTH_ALLOW_PROT" != "true" ]]; then
        if [[ ${#ALL_CHANGED[@]} -eq 0 ]]; then
          echo "MERGE_BLOCKED: missing_changed_paths"
          exit 1
        fi
        PROT_HITS=()
        for cp in "${ALL_CHANGED[@]}"; do
          if protected_path_match_ci "$cp" "${AUTH_PROT_ARR[@]}"; then
            PROT_HITS+=("$cp")
          fi
        done
        if [[ ${#PROT_HITS[@]} -gt 0 ]]; then
          echo "MERGE_BLOCKED: protected_paths=$(printf '%s\n' "${PROT_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
          exit 1
        fi
      fi

      if [[ ${#AUTH_ALLOWED_BR[@]} -gt 0 ]]; then
        if ! branch_pattern_match "$GH_BASE_REF" "${AUTH_ALLOWED_BR[@]}"; then
          echo "MERGE_BLOCKED: target_branch_not_allowed(${GH_BASE_REF})"
          exit 1
        fi
      fi

      if [[ "$GH_MERGEABLE" == "false" ]]; then
        echo "MERGE_BLOCKED: pr_not_mergeable(mergeable=${GH_MERGEABLE},state=${GH_MERGEABLE_STATE})"
        exit 1
      fi
      if [[ "$GH_MERGEABLE_STATE" == "dirty" ]]; then
        echo "MERGE_BLOCKED: mergeable_state=$GH_MERGEABLE_STATE"
        exit 1
      fi

      EFF_REQ_CI=false
      if [[ "$AUTH_REQ_CI" == "true" ]] || $REQUIRE_REMOTE_CI; then
        EFF_REQ_CI=true
      fi
      if $EFF_REQ_CI; then
        if [[ "$GH_CI_STATUS" != "PASS" ]]; then
          echo "MERGE_BLOCKED: ci_status=$GH_CI_STATUS"
          exit 1
        fi
      elif [[ "$GH_CI_STATUS" == "FAIL" || "$GH_CI_STATUS" == "PENDING" ]]; then
        echo "MERGE_BLOCKED: ci_status=$GH_CI_STATUS"
        exit 1
      fi

      if [[ "$AUTH_AUTO_MERGE" != "authorized" ]]; then
        LED_OPT_GH="$(trim_str "$LEDGER_PATH")"
        if [[ -n "$LED_OPT_GH" ]]; then
          if ! check_contained_repo_path "$REPO_ROOT" "$LED_OPT_GH"; then
            echo "MERGE_BLOCKED: invalid_ledger_path"
            exit 1
          fi
        fi
        echo "PR_READY: auto_merge=disabled"
        exit 2
      fi

      LED_TRIM="$(trim_str "$LEDGER_PATH")"
      if [[ -z "$LED_TRIM" ]]; then
        echo "MERGE_BLOCKED: missing_ledger_path"
        exit 1
      fi
      if ! check_contained_repo_path "$REPO_ROOT" "$LED_TRIM"; then
        echo "MERGE_BLOCKED: invalid_ledger_path"
        exit 1
      fi
      LED_FULL="$_CONTAINED_FULL"
      LED_REL="$_CONTAINED_REL"
      if [[ ! -f "$LED_FULL" ]]; then
        echo "MERGE_BLOCKED: missing_ledger_path"
        exit 1
      fi
      set +e
      LED_CHK_OUT="$(run_review_ledger_check_sub "$REPO_ROOT" "$LED_FULL" "$LED_REL" "" "true")"
      LED_CHK_RC=$?
      set -e
      if [[ $LED_CHK_RC -ne 0 ]]; then
        _first_err="${LED_CHK_OUT%%$'\n'*}"
        echo "MERGE_BLOCKED: ledger_check_failed (${_first_err:-unknown})"
        exit 1
      fi
      M_BASE=""; M_HEAD=""; M_TREF=""; M_TSHA=""; M_RIND=""
      while IFS= read -r mline; do
        case "$mline" in
          META_BASE_SHA=*) M_BASE="${mline#META_BASE_SHA=}" ;;
          META_HEAD_SHA=*) M_HEAD="${mline#META_HEAD_SHA=}" ;;
          META_TARGET_REF=*) M_TREF="${mline#META_TARGET_REF=}" ;;
          META_TARGET_SHA=*) M_TSHA="${mline#META_TARGET_SHA=}" ;;
          META_REVIEW_INDEPENDENCE=*) M_RIND="${mline#META_REVIEW_INDEPENDENCE=}" ;;
        esac
      done <<< "$LED_CHK_OUT"
      if [[ "$M_BASE" != "$RES_BASE_SHA" ]]; then
        echo "MERGE_BLOCKED: ledger_target_mismatch"
        exit 1
      fi
      if [[ "$M_HEAD" != "$LIVE_HEAD_SHA" || ( "$M_TREF" != "working_tree" && "$M_TSHA" != "$LIVE_HEAD_SHA" ) ]]; then
        echo "MERGE_BLOCKED: ledger_head_mismatch"
        exit 1
      fi
      if [[ "$M_RIND" == "SINGLE_AGENT_LIMIT" ]]; then
        echo "MERGE_BLOCKED: single_agent_limit"
        exit 1
      fi
      if [[ "$M_RIND" != "INDEPENDENT" ]]; then
        echo "MERGE_BLOCKED: review_independence_unknown"
        exit 1
      fi

      printf 'MERGE_AUTHORIZED: mode=github pr=%s#%s target_ref=%s target_sha=%s head_sha=%s policy_authority=%s@%s auto_merge=authorized ci=%s governance=CLEAR\n' \
        "$GH_BASE_REPO" "$PR_NUM_TRIM" "$GH_BASE_REF" "$RES_BASE_SHA" "$LIVE_HEAD_SHA" "$GH_POLICY_AUTH_REF" "$GH_POLICY_AUTH_SHA" "$GH_CI_STATUS"
      exit 0
    fi

    # --- Provider-Neutral Local / --local-only / auto_merge=disabled Path ---
    if $REQUIRE_REMOTE_CI; then
      echo "PROVIDER_UNAVAILABLE: remote_ci_requires_provider_verification"
      exit 2
    fi
    if [[ "$AUTO_MERGE" != "authorized" ]]; then
      LED_OPT_TRIM="$(trim_str "$LEDGER_PATH")"
      OPT_LED_OUT=""
      if [[ -n "$LED_OPT_TRIM" ]]; then
        if ! check_contained_repo_path "$REPO_ROOT" "$LED_OPT_TRIM"; then
          echo "MERGE_BLOCKED: invalid_ledger_path"
          exit 1
        fi
        if [[ -f "$_CONTAINED_FULL" && "$REQ_CI" == "true" && -z "$(trim_str "$RECEIPT_PATH")" ]]; then
          set +e
          _led_dis_out="$(run_review_ledger_check_sub "$REPO_ROOT" "$_CONTAINED_FULL" "$_CONTAINED_REL" "" "true")"
          _led_dis_rc=$?
          set -e
          [[ $_led_dis_rc -eq 0 ]] && OPT_LED_OUT="$_led_dis_out"
        fi
      fi
      if [[ ${#PROT_ARR[@]} -gt 0 && "$ALLOW_PROT" != "true" && ${#LOCAL_PRE_CHANGED_ARR[@]} -eq 0 ]]; then
        echo "MERGE_BLOCKED: missing_changed_paths"
        exit 1
      fi
      if [[ "$REQ_CI" == "true" || -n "$(trim_str "$RECEIPT_PATH")" ]]; then
        assert_local_ci_evidence "$REPO_ROOT" "$LIVE_HEAD_SHA" "$RECEIPT_PATH" "$OPT_LED_OUT" "$IGNORE_DIRTY" "$CI_STATUS" "$REQ_CI" "$_MP_CASE_INSENSITIVE" ${LOCAL_PRE_CHANGED_ARR[@]+"${LOCAL_PRE_CHANGED_ARR[@]}"}
      fi
      if [[ "$REQ_REV" == "true" && "$REVIEW_STATUS" != "PASS" && -z "$LED_OPT_TRIM" ]]; then
        echo "MERGE_BLOCKED: review_status=$REVIEW_STATUS"
        exit 1
      fi
      BASE_OPT_TRIM="$(trim_str "$BASE_SHA")"
      if [[ -n "$BASE_OPT_TRIM" ]]; then
        if [[ "$BASE_OPT_TRIM" == -* ]] || ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${BASE_OPT_TRIM}^{commit}" || [[ ! "$(trim_str "$_GIT_STDOUT")" =~ ^[0-9a-f]{40}$ ]]; then
          echo "MERGE_BLOCKED: invalid_base_sha"
          exit 1
        fi
      fi
      echo "PR_READY: auto_merge=disabled"
      exit 2
    fi

    # auto_merge == 'authorized' without --pr-number (or with --local-only)
    if $POL_EXPLICIT && [[ "$EFFECTIVE_POL_REL" != ".b3/research-policy.json" ]]; then
      echo "MERGE_BLOCKED: policy_path_override_not_allowed"
      exit 1
    fi
    if [[ -z "$LIVE_HEAD_SHA" ]]; then
      echo "MERGE_BLOCKED: invalid_head"
      exit 1
    fi

    HAS_DIRTY_LOC=false
    for _dkind in staged wt untracked; do
      case "$_dkind" in
        staged) run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --cached --name-status -z -- || exit 1 ;;
        wt) run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z -- || exit 1 ;;
        untracked) run_git_paths_z "$REPO_ROOT" "names" "MERGE_BLOCKED" "" -- ls-files --others --exclude-standard -z || exit 1 ;;
      esac
      for dp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        [[ -n "$dp" ]] || continue
        is_checkpoint_dir "$dp" && continue
        if protected_path_match_ci "$dp" "${POL_PROT_ARR[@]}"; then
          echo "MERGE_BLOCKED: policy_modified_in_pr"
          exit 1
        fi
        HAS_DIRTY_LOC=true
      done
    done
    if $HAS_DIRTY_LOC; then
      echo "MERGE_BLOCKED: dirty_worktree"
      exit 1
    fi

    if ! $LOCAL_ONLY; then
      if $REQUIRE_REMOTE_CI; then
        echo "MERGE_BLOCKED: missing_pr_number"
        exit 1
      fi
      if $HAS_ANY_REMOTE && ! $HAS_ORIGIN; then
        echo "MERGE_BLOCKED: origin_remote_missing"
        exit 1
      fi
      if $HAS_ORIGIN && [[ -z "$CANON_AUTH_SHA" ]]; then
        echo "MERGE_BLOCKED: missing_pr_number"
        exit 1
      fi
    fi

    EFF_AUTH_SYM_FULL="$CANON_AUTH_FULL"
    EFF_AUTH_BRANCH="$CANON_AUTH_BRANCH"
    EFF_AUTH_SHA="${CANON_AUTH_SHA:-$FALLBACK_LOCAL_TRUNK_SHA}"
    if [[ -z "$EFF_AUTH_SHA" ]]; then
      echo "MERGE_BLOCKED: policy_not_in_authority"
      exit 1
    fi

    if ! run_git_cmd_quiet "$REPO_ROOT" ls-tree "$EFF_AUTH_SHA" -- ".b3/research-policy.json"; then
      echo "MERGE_BLOCKED: policy_not_in_authority"
      exit 1
    fi
    AUTH_LOC_LINE="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$AUTH_LOC_LINE" =~ $_re_ls_pol ]]; then
      echo "MERGE_BLOCKED: policy_not_in_authority"
      exit 1
    fi
    if ! run_git_cmd_quiet "$REPO_ROOT" show "${EFF_AUTH_SHA}:.b3/research-policy.json"; then
      echo "MERGE_BLOCKED: policy_not_in_authority"
      exit 1
    fi
    load_merge_policy_from_source "-" "$_GIT_STDOUT" "MERGE_BLOCKED"
    AUTH_LOC_AUTO_MERGE="$_POL_AUTO_MERGE"
    AUTH_LOC_ALLOW_PROT="$_POL_ALLOW_PROT"
    AUTH_LOC_REQ_CI="$_POL_REQ_CI"
    AUTH_LOC_PROT_ARR=()
    AUTH_LOC_ALLOWED_BR=()
    [[ ${#_POL_PROT_ARR[@]} -gt 0 ]] && AUTH_LOC_PROT_ARR=("${_POL_PROT_ARR[@]}")
    [[ ${#_POL_ALLOWED_BR[@]} -gt 0 ]] && AUTH_LOC_ALLOWED_BR=("${_POL_ALLOWED_BR[@]}")
    if [[ "$AUTH_LOC_AUTO_MERGE" != "authorized" ]]; then
      echo "PR_READY: auto_merge=disabled"
      exit 2
    fi

    TARGET_SYM_FULL=""
    TARGET_BRANCH_NAME=""
    RES_BASE_SHA=""
    if [[ -n "$EFF_TARGET_REF_ARG" ]]; then
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --symbolic-full-name "$EFF_TARGET_REF_ARG"; then
        TARGET_SYM_FULL="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ "$TARGET_SYM_FULL" != refs/heads/* && "$TARGET_SYM_FULL" != refs/remotes/* ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
      if [[ -n "$CUR_SYM_FULL" && "$TARGET_SYM_FULL" == "$CUR_SYM_FULL" ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
      if ! $LOCAL_ONLY && $HAS_ORIGIN && [[ "$TARGET_SYM_FULL" != refs/remotes/origin/* ]]; then
        echo "MERGE_BLOCKED: remote_tracking_target_required"
        exit 1
      fi
      if ! $LOCAL_ONLY && ! $HAS_ANY_REMOTE && [[ "$TARGET_SYM_FULL" != refs/heads/* ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
      if [[ "$TARGET_SYM_FULL" == refs/heads/* ]]; then
        TARGET_BRANCH_NAME="${TARGET_SYM_FULL#refs/heads/}"
      elif [[ "$TARGET_SYM_FULL" =~ ^refs/remotes/[^/]+/(.+)$ ]]; then
        TARGET_BRANCH_NAME="${BASH_REMATCH[1]}"
      fi
      if [[ -n "$TARGET_BR_TRIM" && "$TARGET_BR_TRIM" != "$TARGET_BRANCH_NAME" ]]; then
        echo "MERGE_BLOCKED: target_ref_mismatch"
        exit 1
      fi
      if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_SYM_FULL}^{commit}"; then
        RES_BASE_SHA="$(trim_str "$_GIT_STDOUT")"
      fi
      if [[ ! "$RES_BASE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
    elif [[ -n "$TARGET_BR_TRIM" ]]; then
      CAND_REFS=()
      if $HAS_ORIGIN; then
        if $LOCAL_ONLY; then
          CAND_REFS=("refs/remotes/origin/${TARGET_BR_TRIM}" "refs/heads/${TARGET_BR_TRIM}")
        else
          CAND_REFS=("refs/remotes/origin/${TARGET_BR_TRIM}")
        fi
      else
        CAND_REFS=("refs/heads/${TARGET_BR_TRIM}")
      fi
      for _cr in "${CAND_REFS[@]}"; do
        if run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${_cr}^{commit}"; then
          _cr_sha="$(trim_str "$_GIT_STDOUT")"
          if [[ "$_cr_sha" =~ ^[0-9a-f]{40}$ ]]; then
            TARGET_SYM_FULL="$_cr"
            TARGET_BRANCH_NAME="$TARGET_BR_TRIM"
            RES_BASE_SHA="$_cr_sha"
            break
          fi
        fi
      done
      if [[ -z "$RES_BASE_SHA" ]]; then
        echo "MERGE_BLOCKED: target_sha_not_fetched"
        exit 1
      fi
      if [[ -n "$CUR_SYM_FULL" && "$TARGET_SYM_FULL" == "$CUR_SYM_FULL" ]]; then
        echo "MERGE_BLOCKED: invalid_target_ref"
        exit 1
      fi
    elif [[ -n "$EFF_AUTH_SYM_FULL" ]]; then
      if [[ -n "$CUR_SYM_FULL" && "$EFF_AUTH_SYM_FULL" == "$CUR_SYM_FULL" ]]; then
        if ! $LOCAL_ONLY; then
          echo "MERGE_BLOCKED: base_sha_equals_head"
          exit 1
        fi
      else
        TARGET_SYM_FULL="$EFF_AUTH_SYM_FULL"
        TARGET_BRANCH_NAME="$EFF_AUTH_BRANCH"
        RES_BASE_SHA="$EFF_AUTH_SHA"
      fi
    fi

    BASE_TRIM_LOC="$(trim_str "$BASE_SHA")"
    if [[ -n "$BASE_TRIM_LOC" ]]; then
      if [[ "$BASE_TRIM_LOC" == -* ]] || ! run_git_cmd_quiet "$REPO_ROOT" rev-parse --verify --quiet "${BASE_TRIM_LOC}^{commit}"; then
        echo "MERGE_BLOCKED: invalid_base_sha"
        exit 1
      fi
      CALLER_BASE_LOC="$(trim_str "$_GIT_STDOUT")"
      if [[ ! "$CALLER_BASE_LOC" =~ ^[0-9a-f]{40}$ ]]; then
        echo "MERGE_BLOCKED: invalid_base_sha"
        exit 1
      fi
      if [[ "$CALLER_BASE_LOC" == "$LIVE_HEAD_SHA" ]]; then
        echo "MERGE_BLOCKED: base_sha_equals_head"
        exit 1
      fi
      if [[ -n "$RES_BASE_SHA" ]]; then
        if [[ "$CALLER_BASE_LOC" != "$RES_BASE_SHA" ]]; then
          if $LOCAL_ONLY && [[ -z "$EFF_TARGET_REF_ARG" && -z "$TARGET_BR_TRIM" ]]; then
            RES_BASE_SHA="$CALLER_BASE_LOC"
          else
            echo "MERGE_BLOCKED: base_sha_mismatch"
            exit 1
          fi
        fi
      elif $LOCAL_ONLY; then
        RES_BASE_SHA="$CALLER_BASE_LOC"
      fi
    fi

    if [[ -z "$RES_BASE_SHA" ]]; then
      if $LOCAL_ONLY; then
        echo "MERGE_BLOCKED: missing_base_sha"
        exit 1
      fi
      echo "MERGE_BLOCKED: invalid_target_ref"
      exit 1
    fi
    if [[ "$RES_BASE_SHA" == "$LIVE_HEAD_SHA" ]]; then
      echo "MERGE_BLOCKED: base_sha_equals_head"
      exit 1
    fi
    if ! run_git_cmd_quiet "$REPO_ROOT" merge-base --is-ancestor "$RES_BASE_SHA" "$LIVE_HEAD_SHA"; then
      echo "MERGE_BLOCKED: target_branch_moved"
      exit 1
    fi

    if [[ -n "$TARGET_BRANCH_NAME" && ${#AUTH_LOC_ALLOWED_BR[@]} -gt 0 ]]; then
      if ! branch_pattern_match "$TARGET_BRANCH_NAME" "${AUTH_LOC_ALLOWED_BR[@]}"; then
        echo "MERGE_BLOCKED: target_branch_not_allowed(${TARGET_BRANCH_NAME})"
        exit 1
      fi
    fi

    if [[ "$RES_BASE_SHA" != "$EFF_AUTH_SHA" ]]; then
      if ! run_git_cmd_quiet "$REPO_ROOT" merge-base "$EFF_AUTH_SHA" "$RES_BASE_SHA"; then
        echo "MERGE_BLOCKED: target_branch_unrelated_to_authority"
        exit 1
      fi
      MB_AUTH_LOC_SHA="$(trim_str "$_GIT_STDOUT")"
      if [[ ! "$MB_AUTH_LOC_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "MERGE_BLOCKED: target_branch_unrelated_to_authority"
        exit 1
      fi
      run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${MB_AUTH_LOC_SHA}..${RES_BASE_SHA}" -- || exit 1
      for tp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
        if [[ -n "$tp" ]] && protected_path_match_ci "$tp" "${POL_PROT_ARR[@]}"; then
          echo "MERGE_BLOCKED: target_branch_modified_policy"
          exit 1
        fi
      done
    fi

    ALL_CHANGED_LOC=()
    _seen_aloc="|"
    if [[ ${#CHANGED_ARR[@]} -gt 0 ]]; then
      for cp in "${CHANGED_ARR[@]}"; do
        if [[ "$_seen_aloc" != *"|${cp}|"* ]]; then
          _seen_aloc+="${cp}|"
          ALL_CHANGED_LOC+=("$cp")
        fi
      done
    fi
    run_git_paths_z "$REPO_ROOT" "name-status-z" "MERGE_BLOCKED" "" -- diff --no-ext-diff --name-status -z "${RES_BASE_SHA}..${LIVE_HEAD_SHA}" -- || exit 1
    for gp in ${_GIT_PATHS_Z[@]+"${_GIT_PATHS_Z[@]}"}; do
      [[ -n "$gp" ]] || continue
      is_checkpoint_dir "$gp" && continue
      if [[ "$_seen_aloc" != *"|${gp}|"* ]]; then
        _seen_aloc+="${gp}|"
        ALL_CHANGED_LOC+=("$gp")
      fi
    done

    if [[ ${#ALL_CHANGED_LOC[@]} -gt 0 ]]; then
      for cp in "${ALL_CHANGED_LOC[@]}"; do
        if protected_path_match_ci "$cp" "${POL_PROT_ARR[@]}"; then
          echo "MERGE_BLOCKED: policy_modified_in_pr"
          exit 1
        fi
      done
    fi
    if [[ ${#AUTH_LOC_PROT_ARR[@]} -gt 0 && "$AUTH_LOC_ALLOW_PROT" != "true" ]]; then
      if [[ ${#ALL_CHANGED_LOC[@]} -eq 0 ]]; then
        echo "MERGE_BLOCKED: missing_changed_paths"
        exit 1
      fi
      PROT_HITS_LOC=()
      for cp in "${ALL_CHANGED_LOC[@]}"; do
        if protected_path_match_ci "$cp" "${AUTH_LOC_PROT_ARR[@]}"; then
          PROT_HITS_LOC+=("$cp")
        fi
      done
      if [[ ${#PROT_HITS_LOC[@]} -gt 0 ]]; then
        echo "MERGE_BLOCKED: protected_paths=$(printf '%s\n' "${PROT_HITS_LOC[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        exit 1
      fi
    fi

    LED_TRIM_LOC="$(trim_str "$LEDGER_PATH")"
    if [[ -z "$LED_TRIM_LOC" ]]; then
      echo "MERGE_BLOCKED: missing_ledger_path"
      exit 1
    fi
    if ! check_contained_repo_path "$REPO_ROOT" "$LED_TRIM_LOC"; then
      echo "MERGE_BLOCKED: invalid_ledger_path"
      exit 1
    fi
    LED_FULL_LOC="$_CONTAINED_FULL"
    LED_REL_LOC="$_CONTAINED_REL"
    if [[ ! -f "$LED_FULL_LOC" ]]; then
      echo "MERGE_BLOCKED: missing_ledger_path"
      exit 1
    fi
    set +e
    LED_LOC_OUT="$(run_review_ledger_check_sub "$REPO_ROOT" "$LED_FULL_LOC" "$LED_REL_LOC" "" "true")"
    LED_LOC_RC=$?
    set -e
    if [[ $LED_LOC_RC -ne 0 ]]; then
      _first_err="${LED_LOC_OUT%%$'\n'*}"
      echo "MERGE_BLOCKED: ledger_check_failed (${_first_err:-unknown})"
      exit 1
    fi
    M_BASE_LOC=""; M_HEAD_LOC=""; M_TREF_LOC=""; M_TSHA_LOC=""; M_RIND_LOC=""
    while IFS= read -r mline; do
      case "$mline" in
        META_BASE_SHA=*) M_BASE_LOC="${mline#META_BASE_SHA=}" ;;
        META_HEAD_SHA=*) M_HEAD_LOC="${mline#META_HEAD_SHA=}" ;;
        META_TARGET_REF=*) M_TREF_LOC="${mline#META_TARGET_REF=}" ;;
        META_TARGET_SHA=*) M_TSHA_LOC="${mline#META_TARGET_SHA=}" ;;
        META_REVIEW_INDEPENDENCE=*) M_RIND_LOC="${mline#META_REVIEW_INDEPENDENCE=}" ;;
      esac
    done <<< "$LED_LOC_OUT"
    if [[ "$M_BASE_LOC" != "$RES_BASE_SHA" ]]; then
      echo "MERGE_BLOCKED: ledger_target_mismatch"
      exit 1
    fi
    if [[ "$M_HEAD_LOC" != "$LIVE_HEAD_SHA" || ( "$M_TREF_LOC" != "working_tree" && "$M_TSHA_LOC" != "$LIVE_HEAD_SHA" ) ]]; then
      echo "MERGE_BLOCKED: ledger_head_mismatch"
      exit 1
    fi
    if [[ "$M_RIND_LOC" == "SINGLE_AGENT_LIMIT" ]]; then
      echo "MERGE_BLOCKED: single_agent_limit"
      exit 1
    fi
    if [[ "$M_RIND_LOC" != "INDEPENDENT" ]]; then
      echo "MERGE_BLOCKED: review_independence_unknown"
      exit 1
    fi

    assert_local_ci_evidence "$REPO_ROOT" "$LIVE_HEAD_SHA" "$RECEIPT_PATH" "$LED_LOC_OUT" "$IGNORE_DIRTY" "$CI_STATUS" "$AUTH_LOC_REQ_CI" "$_MP_CASE_INSENSITIVE" ${ALL_CHANGED_LOC[@]+"${ALL_CHANGED_LOC[@]}"}

    if [[ -z "$TARGET_SYM_FULL" || -z "$EFF_AUTH_SYM_FULL" ]]; then
      echo "MERGE_BLOCKED: invalid_target_ref"
      exit 1
    fi
    if $HAS_ORIGIN && ! $LOCAL_ONLY && [[ "$TARGET_SYM_FULL" != refs/remotes/origin/* ]]; then
      echo "MERGE_BLOCKED: remote_tracking_target_required"
      exit 1
    fi
    if ! $HAS_ANY_REMOTE && ( [[ "$TARGET_SYM_FULL" != refs/heads/* ]] || [[ -n "$CUR_SYM_FULL" && "$TARGET_SYM_FULL" == "$CUR_SYM_FULL" ]] ); then
      echo "MERGE_BLOCKED: invalid_target_ref"
      exit 1
    fi

    if $HAS_ANY_REMOTE; then
      REMOTE_AUTH_STATE="no_provider_verification"
      if $HAS_ORIGIN; then
        _ra_status="" _ra_sha=""
        if [[ -n "$EFF_AUTH_BRANCH" ]]; then
          git_ls_remote_ref "$REPO_ROOT" "refs/heads/${EFF_AUTH_BRANCH}"
          _ra_status="$_LS_REMOTE_STATUS"
          _ra_sha="$_LS_REMOTE_SHA"
          if [[ "$_ra_status" == "MISSING" ]]; then
            echo "MERGE_BLOCKED: remote_authority_ref_missing"
            exit 1
          fi
          if [[ "$_ra_status" == "OK" && "$_ra_sha" != "$EFF_AUTH_SHA" ]]; then
            printf 'MERGE_BLOCKED: stale_remote_ref(authority local=%s remote=%s)\n' "$EFF_AUTH_SHA" "$_ra_sha"
            exit 1
          fi
          if [[ "$_ra_status" == "UNREACHABLE" ]]; then
            REMOTE_AUTH_STATE="remote_ref_unverifiable"
          fi
        fi
        if [[ -n "$TARGET_BRANCH_NAME" ]]; then
          if [[ -n "$EFF_AUTH_BRANCH" && "$TARGET_BRANCH_NAME" == "$EFF_AUTH_BRANCH" && -n "$_ra_status" ]]; then
            if [[ "$_ra_status" == "OK" && "$_ra_sha" != "$RES_BASE_SHA" ]]; then
              printf 'MERGE_BLOCKED: stale_remote_ref(target local=%s remote=%s)\n' "$RES_BASE_SHA" "$_ra_sha"
              exit 1
            fi
          else
            git_ls_remote_ref "$REPO_ROOT" "refs/heads/${TARGET_BRANCH_NAME}"
            if [[ "$_LS_REMOTE_STATUS" == "MISSING" ]]; then
              echo "MERGE_BLOCKED: remote_target_ref_missing"
              exit 1
            fi
            if [[ "$_LS_REMOTE_STATUS" == "OK" && "$_LS_REMOTE_SHA" != "$RES_BASE_SHA" ]]; then
              printf 'MERGE_BLOCKED: stale_remote_ref(target local=%s remote=%s)\n' "$RES_BASE_SHA" "$_LS_REMOTE_SHA"
              exit 1
            fi
            if [[ "$_LS_REMOTE_STATUS" == "UNREACHABLE" ]]; then
              REMOTE_AUTH_STATE="remote_ref_unverifiable"
            fi
          fi
        fi
      else
        REMOTE_AUTH_STATE="no_origin_remote"
      fi
      printf 'LOCAL_ELIGIBLE_ONLY: engineering_ready=true remote_authorization=UNVERIFIED(%s) auto_merge=authorized target_ref=%s target_sha=%s head_sha=%s policy_authority=%s@%s governance=CLEAR\n' \
        "$REMOTE_AUTH_STATE" "$TARGET_SYM_FULL" "$RES_BASE_SHA" "$LIVE_HEAD_SHA" "$EFF_AUTH_SYM_FULL" "$EFF_AUTH_SHA"
      exit 2
    fi

    if $LOCAL_ONLY; then
      echo "LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized"
      exit 2
    fi

    printf 'MERGE_AUTHORIZED: mode=local target_ref=%s target_sha=%s head_sha=%s policy_authority=%s@%s auto_merge=authorized governance=CLEAR\n' \
      "$TARGET_SYM_FULL" "$RES_BASE_SHA" "$LIVE_HEAD_SHA" "$EFF_AUTH_SYM_FULL" "$EFF_AUTH_SHA"
    exit 0
    ;;

  context-cache)
    export LC_ALL=C
    REPO_ROOT="."
    ACTION=""
    CACHE_PATH=""
    SCOPE_ID=""
    ANCHOR_PATHS=""
    SCOPE_PATHS=""
    GRAPH_INDEX_SHA=""
    SUMMARY_REF=""
    IGNORE_DIRTY_PATHS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
        --action) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; ACTION="$2"; shift 2 ;;
        --cache-path) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; CACHE_PATH="$2"; shift 2 ;;
        --scope-id) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; SCOPE_ID="$2"; shift 2 ;;
        --anchor-paths) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; ANCHOR_PATHS="$2"; shift 2 ;;
        --scope-paths) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; SCOPE_PATHS="$2"; shift 2 ;;
        --graph-index-sha) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; GRAPH_INDEX_SHA="$2"; shift 2 ;;
        --summary-ref) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; SUMMARY_REF="$2"; shift 2 ;;
        --ignore-dirty-paths) [[ $# -ge 2 ]] || { echo "CONTEXT_ERROR: missing value for $1"; exit 1; }; IGNORE_DIRTY_PATHS="$2"; shift 2 ;;
        *) echo "CONTEXT_ERROR: unknown option $1"; exit 1 ;;
      esac
    done

    for raw_arg in "$ACTION" "$CACHE_PATH" "$SCOPE_ID" "$ANCHOR_PATHS" "$SCOPE_PATHS" "$GRAPH_INDEX_SHA" "$SUMMARY_REF" "$IGNORE_DIRTY_PATHS"; do
      if has_control_chars "$raw_arg"; then
        echo "CONTEXT_ERROR: control characters not allowed"
        exit 1
      fi
    done

    ACT="$(trim_str "$ACTION")"
    if [[ "$ACT" != "record" && "$ACT" != "check" ]]; then
      echo "CONTEXT_ERROR: invalid action"
      exit 1
    fi

    if CANON_R="$(canon_repo_root "$REPO_ROOT")"; then
      REPO_ROOT="$CANON_R"
    fi

    MID_OP="$(check_git_mid_operation "$REPO_ROOT")"
    if [[ -n "$MID_OP" ]]; then
      echo "CONTEXT_ERROR: mid-operation git state"
      exit 1
    fi

    if ! resolve_strict_commit_sha "$REPO_ROOT" "HEAD"; then
      echo "CONTEXT_ERROR: invalid HEAD"
      exit 1
    fi
    LIVE_HEAD_SHA="$_COMMIT_SHA"

    CP_RC=0
    check_checkpoint_file_path "$REPO_ROOT" "$CACHE_PATH" || CP_RC=$?
    CACHE_REL="$_CP_REL"
    CACHE_FULL="$_CP_FULL"

    if [[ "$ACT" == "record" ]]; then
      if [[ $CP_RC -ne 0 ]]; then
        echo "CONTEXT_ERROR: invalid cache_path"
        exit 1
      fi
      SCOPE_VAL="$(trim_str "$SCOPE_ID")"
      if ! is_valid_context_scope_id "$SCOPE_VAL"; then
        echo "CONTEXT_ERROR: invalid scope_id"
        exit 1
      fi

      if ! split_strict_paths "$REPO_ROOT" "$ANCHOR_PATHS" true true; then
        echo "CONTEXT_ERROR: invalid path ${_CTX_BAD_TOKEN}"
        exit 1
      fi
      ANC_ARR=()
      if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
        ANC_ARR=("${_CTX_PATHS[@]}")
      fi

      if ! split_strict_paths "$REPO_ROOT" "$SCOPE_PATHS" true true; then
        echo "CONTEXT_ERROR: invalid path ${_CTX_BAD_TOKEN}"
        exit 1
      fi
      REC_SCOPE_ARR=()
      if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
        REC_SCOPE_ARR=("${_CTX_PATHS[@]}")
      fi

      _IGN_PATHS=()
      if ! split_strict_paths "$REPO_ROOT" "$IGNORE_DIRTY_PATHS" true false; then
        echo "CONTEXT_ERROR: invalid ignore path"
        exit 1
      fi
      if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
        _IGN_PATHS=("${_CTX_PATHS[@]}")
      fi
      if [[ ${#ANC_ARR[@]} -gt 0 ]] && ignore_overlaps_paths "${ANC_ARR[@]}"; then
        echo "CONTEXT_ERROR: invalid ignore path"
        exit 1
      fi
      if [[ ${#REC_SCOPE_ARR[@]} -gt 0 ]] && ignore_overlaps_paths "${REC_SCOPE_ARR[@]}"; then
        echo "CONTEXT_ERROR: invalid ignore path"
        exit 1
      fi

      GRAPH_TRIM="$(trim_str "$GRAPH_INDEX_SHA")"
      GRAPH_VAL="none"
      if [[ -n "$GRAPH_TRIM" && "$GRAPH_TRIM" != "none" ]]; then
        if ! resolve_strict_commit_sha "$REPO_ROOT" "$GRAPH_TRIM"; then
          echo "CONTEXT_ERROR: invalid graph_index_sha"
          exit 1
        fi
        GRAPH_VAL="$_COMMIT_SHA"
      fi

      if [[ ${#ANC_ARR[@]} -eq 0 && "$GRAPH_VAL" == "none" ]]; then
        echo "CONTEXT_ERROR: empty cache (anchor_paths or graph_index_sha required)"
        exit 1
      fi

      SUM_TRIM="$(trim_str "$SUMMARY_REF")"
      SUM_REF_VAL="none"
      SUM_SHA_VAL="none"
      if [[ -n "$SUM_TRIM" && "$SUM_TRIM" != "none" ]]; then
        SUM_RC=0
        check_checkpoint_file_path "$REPO_ROOT" "$SUM_TRIM" || SUM_RC=$?
        if [[ $SUM_RC -ne 0 ]]; then
          echo "CONTEXT_ERROR: invalid summary_ref"
          exit 1
        fi
        SUM_REL="$_CP_REL"
        SUM_FULL="$_CP_FULL"
        if [[ ! -f "$SUM_FULL" || -L "$SUM_FULL" ]]; then
          echo "CONTEXT_ERROR: missing summary_ref"
          exit 1
        fi
        SUM_SHA_VAL="$(compute_file_sha256 "$SUM_FULL")" || { echo "CONTEXT_ERROR: sha256 computation failed"; exit 1; }
        if [[ ! "$SUM_SHA_VAL" =~ ^[0-9a-f]{64}$ ]]; then
          echo "CONTEXT_ERROR: sha256 computation failed"
          exit 1
        fi
        SUM_REF_VAL="$SUM_REL"
      fi

      ANCHOR_PATHS_VAL="none"
      ANCHOR_HASH_VAL="none"
      IGN_CSV=""
      if [[ ${#_IGN_PATHS[@]} -gt 0 ]]; then
        IGN_CSV="$(join_csv "${_IGN_PATHS[@]}")"
      fi
      if [[ ${#ANC_ARR[@]} -gt 0 ]]; then
        ANCHOR_PATHS_VAL="$(join_csv "${ANC_ARR[@]}")"
        if ! FP_OUT="$(compute_tree_fingerprint "$REPO_ROOT" "$ANCHOR_PATHS_VAL" "$IGN_CSV")"; then
          echo "$FP_OUT"
          exit 1
        fi
        { IFS= read -r _fp_h; IFS= read -r ANCHOR_HASH_VAL; IFS= read -r _fp_p; } <<< "$FP_OUT"
      fi

      TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      BODY_STR="schema=b3-context-v1
scope_id=${SCOPE_VAL}
head_sha=${LIVE_HEAD_SHA}
anchor_paths=${ANCHOR_PATHS_VAL}
anchor_hash=${ANCHOR_HASH_VAL}
graph_index_sha=${GRAPH_VAL}
summary_ref=${SUM_REF_VAL}
summary_sha256=${SUM_SHA_VAL}
timestamp_utc=${TS_UTC}
"
      write_atomic_lf_file "$CACHE_FULL" "$BODY_STR"
      printf 'CONTEXT_RECORDED: %s scope=%s head=%s anchor_hash=%s graph_index_sha=%s\n' "$CACHE_REL" "$SCOPE_VAL" "$LIVE_HEAD_SHA" "$ANCHOR_HASH_VAL" "$GRAPH_VAL"
      exit 0
    fi

    if [[ $CP_RC -eq 2 ]]; then
      echo "CONTEXT_ERROR: invalid cache_path"
      exit 1
    fi
    if [[ $CP_RC -eq 3 ]]; then
      echo "CONTEXT_CORRUPT: invalid cache_path"
      exit 1
    fi

    CALLER_SCOPE="$(trim_str "$SCOPE_ID")"
    if [[ -n "$CALLER_SCOPE" ]] && ! is_valid_context_scope_id "$CALLER_SCOPE"; then
      echo "CONTEXT_ERROR: invalid scope_id"
      exit 1
    fi

    HAS_CALLER_ANCHOR=false
    CALLER_ANCHOR_ARR=()
    CALLER_ANCHOR_CSV="none"
    ANC_RAW_TRIM="$(trim_str "$ANCHOR_PATHS")"
    if [[ -n "$ANC_RAW_TRIM" ]]; then
      HAS_CALLER_ANCHOR=true
      if ! split_strict_paths "$REPO_ROOT" "$ANCHOR_PATHS" true true; then
        echo "CONTEXT_ERROR: invalid path ${_CTX_BAD_TOKEN}"
        exit 1
      fi
      if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
        CALLER_ANCHOR_ARR=("${_CTX_PATHS[@]}")
        CALLER_ANCHOR_CSV="$(join_csv "${CALLER_ANCHOR_ARR[@]}")"
      fi
    fi

    if ! split_strict_paths "$REPO_ROOT" "$SCOPE_PATHS" true true; then
      echo "CONTEXT_ERROR: invalid path ${_CTX_BAD_TOKEN}"
      exit 1
    fi
    SCOPE_ARR=()
    if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
      SCOPE_ARR=("${_CTX_PATHS[@]}")
    fi

    _IGN_PATHS=()
    if ! split_strict_paths "$REPO_ROOT" "$IGNORE_DIRTY_PATHS" true false; then
      echo "CONTEXT_ERROR: invalid ignore path"
      exit 1
    fi
    if [[ ${#_CTX_PATHS[@]} -gt 0 ]]; then
      _IGN_PATHS=("${_CTX_PATHS[@]}")
    fi
    IGN_CSV=""
    if [[ ${#_IGN_PATHS[@]} -gt 0 ]]; then
      IGN_CSV="$(join_csv "${_IGN_PATHS[@]}")"
    fi

    HAS_CALLER_GRAPH=false
    CALLER_GRAPH_VAL="none"
    CALLER_GRAPH_TRIM="$(trim_str "$GRAPH_INDEX_SHA")"
    if [[ -n "$CALLER_GRAPH_TRIM" ]]; then
      HAS_CALLER_GRAPH=true
      if [[ "$CALLER_GRAPH_TRIM" == "none" ]]; then
        CALLER_GRAPH_VAL="none"
      else
        if ! resolve_strict_commit_sha "$REPO_ROOT" "$CALLER_GRAPH_TRIM"; then
          echo "CONTEXT_ERROR: invalid graph_index_sha"
          exit 1
        fi
        CALLER_GRAPH_VAL="$_COMMIT_SHA"
      fi
    fi

    HAS_CALLER_SUMMARY=false
    CALLER_SUMMARY_VAL="none"
    SUM_RAW_TRIM="$(trim_str "$SUMMARY_REF")"
    if [[ -n "$SUM_RAW_TRIM" ]]; then
      HAS_CALLER_SUMMARY=true
      if [[ "$SUM_RAW_TRIM" == "none" ]]; then
        CALLER_SUMMARY_VAL="none"
      else
        CSUM_RC=0
        check_checkpoint_file_path "$REPO_ROOT" "$SUM_RAW_TRIM" || CSUM_RC=$?
        if [[ $CSUM_RC -ne 0 ]]; then
          echo "CONTEXT_ERROR: invalid summary_ref"
          exit 1
        fi
        CALLER_SUMMARY_VAL="$_CP_REL"
      fi
    fi

    if $HAS_CALLER_ANCHOR && [[ ${#CALLER_ANCHOR_ARR[@]} -gt 0 ]] && ignore_overlaps_paths "${CALLER_ANCHOR_ARR[@]}"; then
      echo "CONTEXT_ERROR: invalid ignore path"
      exit 1
    fi
    if [[ ${#SCOPE_ARR[@]} -gt 0 ]] && ignore_overlaps_paths "${SCOPE_ARR[@]}"; then
      echo "CONTEXT_ERROR: invalid ignore path"
      exit 1
    fi

    if [[ ! -f "$CACHE_FULL" ]]; then
      echo "CONTEXT_MISSING: ${CACHE_REL}"
      exit 1
    fi
    if [[ -L "$CACHE_FULL" ]]; then
      echo "CONTEXT_CORRUPT: invalid cache_path"
      exit 1
    fi

    if ! validate_strict_utf8_file "$CACHE_FULL"; then
      echo "CONTEXT_CORRUPT: invalid utf8 encoding"
      exit 1
    fi

    CTRL_CNT="$(LC_ALL=C tr -cd '\000-\011\013-\037\177' < "$CACHE_FULL" | wc -c | tr -d '[:space:]')"
    if [[ "${CTRL_CNT:-0}" -gt 0 ]]; then
      echo "CONTEXT_CORRUPT: control character or CRLF in cache"
      exit 1
    fi

    SEEN_KEYS=$'\n'
    REC_SCHEMA=""
    REC_SCOPE_ID=""
    REC_HEAD_SHA=""
    REC_ANCHOR_PATHS=""
    REC_ANCHOR_HASH=""
    REC_GRAPH_INDEX_SHA=""
    REC_SUMMARY_REF=""
    REC_SUMMARY_SHA256=""
    REC_TIMESTAMP_UTC=""

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      if [[ "$raw_line" != *=* ]]; then
        echo "CONTEXT_CORRUPT: malformed line"
        exit 1
      fi
      k="${raw_line%%=*}"
      v="${raw_line#*=}"
      if [[ -z "$k" ]]; then
        echo "CONTEXT_CORRUPT: malformed line"
        exit 1
      fi
      case "$k" in
        schema|scope_id|head_sha|anchor_paths|anchor_hash|graph_index_sha|summary_ref|summary_sha256|timestamp_utc) ;;
        *) echo "CONTEXT_CORRUPT: unknown field '${k}'"; exit 1 ;;
      esac
      if [[ "$SEEN_KEYS" == *$'\n'"${k}"$'\n'* ]]; then
        echo "CONTEXT_CORRUPT: duplicate field '${k}'"
        exit 1
      fi
      if [[ -z "$v" ]]; then
        echo "CONTEXT_CORRUPT: empty field '${k}'"
        exit 1
      fi
      SEEN_KEYS="${SEEN_KEYS}${k}"$'\n'
      case "$k" in
        schema) REC_SCHEMA="$v" ;;
        scope_id) REC_SCOPE_ID="$v" ;;
        head_sha) REC_HEAD_SHA="$v" ;;
        anchor_paths) REC_ANCHOR_PATHS="$v" ;;
        anchor_hash) REC_ANCHOR_HASH="$v" ;;
        graph_index_sha) REC_GRAPH_INDEX_SHA="$v" ;;
        summary_ref) REC_SUMMARY_REF="$v" ;;
        summary_sha256) REC_SUMMARY_SHA256="$v" ;;
        timestamp_utc) REC_TIMESTAMP_UTC="$v" ;;
      esac
    done < "$CACHE_FULL"

    for req_key in schema scope_id head_sha anchor_paths anchor_hash graph_index_sha summary_ref summary_sha256 timestamp_utc; do
      if [[ "$SEEN_KEYS" != *$'\n'"${req_key}"$'\n'* ]]; then
        echo "CONTEXT_CORRUPT: missing field '${req_key}'"
        exit 1
      fi
    done

    if [[ "$REC_SCHEMA" != "b3-context-v1" ]]; then
      echo "CONTEXT_CORRUPT: invalid schema"
      exit 1
    fi
    if ! is_valid_context_scope_id "$REC_SCOPE_ID"; then
      echo "CONTEXT_CORRUPT: invalid scope_id"
      exit 1
    fi
    if [[ ! "$REC_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
      echo "CONTEXT_CORRUPT: invalid head_sha"
      exit 1
    fi

    REC_ANCHOR_ARR=()
    REC_ANCHOR_CSV="none"
    if [[ "$REC_ANCHOR_PATHS" == "none" ]]; then
      if [[ "$REC_ANCHOR_HASH" != "none" ]]; then
        echo "CONTEXT_CORRUPT: invalid anchor_hash"
        exit 1
      fi
    else
      if [[ ! "$REC_ANCHOR_HASH" =~ ^[0-9a-f]{40}$ ]]; then
        echo "CONTEXT_CORRUPT: invalid anchor_hash"
        exit 1
      fi
      if ! split_strict_paths "$REPO_ROOT" "$REC_ANCHOR_PATHS" false true || [[ ${#_CTX_PATHS[@]} -lt 1 ]]; then
        echo "CONTEXT_CORRUPT: invalid anchor_paths"
        exit 1
      fi
      REC_ANCHOR_ARR=("${_CTX_PATHS[@]}")
      REC_ANCHOR_CSV="$(join_csv "${REC_ANCHOR_ARR[@]}")"
    fi

    if [[ "$REC_GRAPH_INDEX_SHA" != "none" && ! "$REC_GRAPH_INDEX_SHA" =~ ^[0-9a-f]{40}$ ]]; then
      echo "CONTEXT_CORRUPT: invalid graph_index_sha"
      exit 1
    fi
    if [[ "$REC_ANCHOR_PATHS" == "none" && "$REC_GRAPH_INDEX_SHA" == "none" ]]; then
      echo "CONTEXT_CORRUPT: empty cache (anchor_paths or graph_index_sha required)"
      exit 1
    fi

    REC_SUM_FULL=""
    if [[ "$REC_SUMMARY_REF" == "none" ]]; then
      if [[ "$REC_SUMMARY_SHA256" != "none" ]]; then
        echo "CONTEXT_CORRUPT: invalid summary_sha256"
        exit 1
      fi
    else
      if [[ ! "$REC_SUMMARY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "CONTEXT_CORRUPT: invalid summary_sha256"
        exit 1
      fi
      REC_SUM_RC=0
      check_checkpoint_file_path "$REPO_ROOT" "$REC_SUMMARY_REF" || REC_SUM_RC=$?
      if [[ $REC_SUM_RC -ne 0 ]]; then
        echo "CONTEXT_CORRUPT: missing or invalid summary_ref"
        exit 1
      fi
      REC_SUM_FULL="$_CP_FULL"
    fi

    if [[ ! "$REC_TIMESTAMP_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      echo "CONTEXT_CORRUPT: invalid timestamp_utc"
      exit 1
    fi

    if [[ -n "$CALLER_SCOPE" && "$CALLER_SCOPE" != "$REC_SCOPE_ID" ]]; then
      echo "CONTEXT_MISMATCH: scope_id expected=${CALLER_SCOPE} got=${REC_SCOPE_ID}"
      exit 1
    fi

    if $HAS_CALLER_SUMMARY && [[ "$CALLER_SUMMARY_VAL" != "$REC_SUMMARY_REF" ]]; then
      echo "CONTEXT_MISMATCH: summary_ref expected=${CALLER_SUMMARY_VAL} got=${REC_SUMMARY_REF}"
      exit 1
    fi

    if [[ ${#REC_ANCHOR_ARR[@]} -gt 0 ]] && ignore_overlaps_paths "${REC_ANCHOR_ARR[@]}"; then
      echo "CONTEXT_ERROR: invalid ignore path"
      exit 1
    fi

    REASONS=()

    if ! run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$REC_HEAD_SHA" "$LIVE_HEAD_SHA"; then
      REASONS+=("head_diverged")
    fi

    if $HAS_CALLER_ANCHOR && [[ "$CALLER_ANCHOR_CSV" != "$REC_ANCHOR_CSV" ]]; then
      REASONS+=("anchor_scope_changed")
    fi

    if [[ ${#REC_ANCHOR_ARR[@]} -gt 0 ]]; then
      if ! FP_OUT="$(compute_tree_fingerprint "$REPO_ROOT" "$REC_ANCHOR_CSV" "$IGN_CSV")"; then
        echo "$FP_OUT"
        exit 1
      fi
      { IFS= read -r _fp_h; IFS= read -r LIVE_ANCHOR_HASH; IFS= read -r _fp_p; } <<< "$FP_OUT"
      if [[ "$LIVE_ANCHOR_HASH" != "$REC_ANCHOR_HASH" ]]; then
        REASONS+=("anchor_changed")
      fi
    fi

    if [[ "$REC_SUMMARY_REF" != "none" ]]; then
      if [[ -z "$REC_SUM_FULL" || ! -f "$REC_SUM_FULL" || -L "$REC_SUM_FULL" ]]; then
        echo "CONTEXT_CORRUPT: missing or invalid summary_ref"
        exit 1
      fi
      LIVE_SUM_SHA="$(compute_file_sha256 "$REC_SUM_FULL")" || { echo "CONTEXT_ERROR: sha256 computation failed"; exit 1; }
      if [[ "$LIVE_SUM_SHA" != "$REC_SUMMARY_SHA256" ]]; then
        REASONS+=("summary_changed")
      fi
    fi

    GRAPH_INDEX_STATUS="NOT_RECORDED"
    if [[ "$REC_GRAPH_INDEX_SHA" != "none" ]] || { $HAS_CALLER_GRAPH && [[ "$CALLER_GRAPH_VAL" != "none" ]]; }; then
      PROBE_PATHS=()
      if [[ ${#SCOPE_ARR[@]} -gt 0 ]]; then
        PROBE_RAW=()
        if [[ ${#REC_ANCHOR_ARR[@]} -gt 0 ]]; then
          for rp in "${REC_ANCHOR_ARR[@]}"; do PROBE_RAW+=("$rp"); done
        fi
        if $HAS_CALLER_ANCHOR && [[ ${#CALLER_ANCHOR_ARR[@]} -gt 0 ]]; then
          for cp in "${CALLER_ANCHOR_ARR[@]}"; do PROBE_RAW+=("$cp"); done
        fi
        for sp in "${SCOPE_ARR[@]}"; do PROBE_RAW+=("$sp"); done
        while IFS= read -r pp; do
          [[ -n "$pp" ]] && PROBE_PATHS+=("$pp")
        done < <(printf '%s\n' "${PROBE_RAW[@]}" | LC_ALL=C sort -u)
      fi
      if [[ "$REC_GRAPH_INDEX_SHA" != "none" ]]; then
        GRAPH_MISMATCH=false
        if $HAS_CALLER_GRAPH && [[ "$CALLER_GRAPH_VAL" != "$REC_GRAPH_INDEX_SHA" ]]; then
          GRAPH_MISMATCH=true
        fi
        REC_GRAPH_FRESH=false
        if [[ ${#PROBE_PATHS[@]} -gt 0 ]]; then
          if check_graph_index_fresh "$REPO_ROOT" "$REC_GRAPH_INDEX_SHA" "$LIVE_HEAD_SHA" "${PROBE_PATHS[@]}"; then
            REC_GRAPH_FRESH=true
          fi
        else
          if check_graph_index_fresh "$REPO_ROOT" "$REC_GRAPH_INDEX_SHA" "$LIVE_HEAD_SHA"; then
            REC_GRAPH_FRESH=true
          fi
        fi
        if $GRAPH_MISMATCH; then
          REASONS+=("graph_index_mismatch")
        fi
        if ! $REC_GRAPH_FRESH; then
          REASONS+=("graph_index_stale")
        fi
        if $GRAPH_MISMATCH || ! $REC_GRAPH_FRESH; then
          GRAPH_INDEX_STATUS="STALE"
        else
          GRAPH_INDEX_STATUS="FRESH"
        fi
      else
        GRAPH_INDEX_STATUS="STALE"
        REASONS+=("graph_index_mismatch")
        CALLER_GRAPH_FRESH=false
        if [[ ${#PROBE_PATHS[@]} -gt 0 ]]; then
          if check_graph_index_fresh "$REPO_ROOT" "$CALLER_GRAPH_VAL" "$LIVE_HEAD_SHA" "${PROBE_PATHS[@]}"; then
            CALLER_GRAPH_FRESH=true
          fi
        else
          if check_graph_index_fresh "$REPO_ROOT" "$CALLER_GRAPH_VAL" "$LIVE_HEAD_SHA"; then
            CALLER_GRAPH_FRESH=true
          fi
        fi
        if ! $CALLER_GRAPH_FRESH; then
          REASONS+=("graph_index_stale")
        fi
      fi
    fi

    ANCHOR_STATUS="FRESH"
    if [[ "$REC_ANCHOR_PATHS" == "none" ]]; then
      ANCHOR_STATUS="NOT_RECORDED"
    fi
    if [[ ${#REASONS[@]} -gt 0 ]]; then
      for r in "${REASONS[@]}"; do
        if [[ "$r" == "head_diverged" || "$r" == "anchor_scope_changed" || "$r" == "anchor_changed" ]]; then
          ANCHOR_STATUS="STALE"
          break
        fi
      done
      REASON_CSV="$(join_csv "${REASONS[@]}")"
      printf 'CONTEXT_STALE: scope=%s reasons=%s anchor_status=%s graph_index=%s live_lsp_eligible=true\n' "$REC_SCOPE_ID" "$REASON_CSV" "$ANCHOR_STATUS" "$GRAPH_INDEX_STATUS"
      exit 2
    fi

    printf 'CONTEXT_FRESH: scope=%s head=%s anchor_status=%s graph_index=%s live_lsp_eligible=true\n' "$REC_SCOPE_ID" "$LIVE_HEAD_SHA" "$ANCHOR_STATUS" "$GRAPH_INDEX_STATUS"
    exit 0
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
