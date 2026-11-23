#!/usr/bin/env bash
# Deterministic helper checks for /b3-ship and /b3-review-loop (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot | diff-scope | mechanical-check | check-wave | new-run | resolve-run | list-runs | prune | verify-run | verify-check | symbol-check | check-worktree | resolve-models
set -euo pipefail

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

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|mechanical-check|check-wave|new-run|resolve-run|list-runs|prune|verify-run|verify-check|symbol-check|check-worktree|resolve-models [options]" >&2
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

find_leftover_tag() {
  find_leftover_tag_var "$1"
  [[ -n "$_LO_TAG" ]] && printf '%s' "$_LO_TAG"
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

is_checkpoint_dir() {
  [[ "$1" == ".b3/ship" || "$1" == ".b3/ship/"* || "$1" == ".b3/autodev" || "$1" == ".b3/autodev/"* ]]
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
  local gd
  gd="$(git -C "$root" rev-parse --git-dir 2>/dev/null || true)"
  gd="$(trim_str "$gd")"
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

resolve_target_path() {
  local root="$1"
  local p
  p="$(trim_str "$2")"
  [[ -n "$p" ]] || return 1
  if [[ "$p" == /* || "$p" =~ ^[A-Za-z]: ]]; then
    printf '%s' "$p"
  else
    printf '%s' "${root}/${p#./}"
  fi
}

repo_rel_path() {
  local root="$1"
  local full="$2"
  local rn fn rn_low fn_low
  rn="$(norm_path "$root")"
  fn="$(norm_path "$full")"
  if [[ "$rn" == "." ]]; then
    printf '%s' "$fn"
    return 0
  fi
  rn_low="$(printf '%s' "$rn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fn_low="$(printf '%s' "$fn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$fn_low" == "$rn_low/"* ]]; then
    printf '%s' "${fn:${#rn}+1}"
  elif [[ "$fn_low" == "$rn_low" ]]; then
    printf '.'
  else
    printf '%s' "$fn"
  fi
}

write_atomic_lf_file() {
  local dest="$1"
  local content="$2"
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tmp="${dest}.tmp.$$.${RANDOM}"
  _CLEANUP_FILES+=("$tmp")
  printf '%s' "$content" | LC_ALL=C tr -d '\r' > "$tmp"
  mv -f "$tmp" "$dest"
}

compute_tree_fingerprint() {
  local root="$1"
  local rel_csv="$2"
  local ign_csv="$3"
  local head_sha
  head_sha="$(git -C "$root" rev-parse HEAD 2>&1)" || { echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"; return 1; }
  head_sha="$(trim_str "$head_sha")"
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"
    return 1
  fi

  local -a ign_arr=()
  while IFS= read -r p; do [[ -n "$p" ]] && ign_arr+=("$p"); done < <(split_csv_lines "$ign_csv" true | LC_ALL=C sort -u)

  local had_rel=false
  local -a clean_rel=()
  local -a raw_rel=()
  while IFS= read -r p; do [[ -n "$p" ]] && raw_rel+=("$p"); done < <(split_csv_lines "$rel_csv" true)
  if [[ ${#raw_rel[@]} -gt 0 ]]; then
    had_rel=true
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

  local paths_csv="ALL"
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    paths_csv="$(printf '%s\n' "${clean_rel[@]}" | paste -sd ',' -)"
  fi

  local wt_dirty staged_dirty untracked
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    wt_dirty="$(git -C "$root" diff --no-renames --name-only HEAD -- "${clean_rel[@]}")" || { echo "GIT_ERROR: git diff HEAD failed"; return 1; }
    staged_dirty="$(git -C "$root" diff --no-renames --cached --name-only -- "${clean_rel[@]}")" || { echo "GIT_ERROR: git diff cached failed"; return 1; }
    untracked="$(git -C "$root" ls-files --others --exclude-standard -- "${clean_rel[@]}")" || { echo "GIT_ERROR: git ls-files failed"; return 1; }
  else
    wt_dirty="$(git -C "$root" diff --no-renames --name-only HEAD)" || { echo "GIT_ERROR: git diff HEAD failed"; return 1; }
    staged_dirty="$(git -C "$root" diff --no-renames --cached --name-only)" || { echo "GIT_ERROR: git diff cached failed"; return 1; }
    untracked="$(git -C "$root" ls-files --others --exclude-standard)" || { echo "GIT_ERROR: git ls-files failed"; return 1; }
  fi

  local -a candidates=()
  local line p
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -n "$p" ]] || continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ign_arr[@]} -gt 0 ]] && path_in_list "$p" "${ign_arr[@]}"; then continue; fi
    if [[ ${#clean_rel[@]} -gt 0 ]] && ! path_in_list "$p" "${clean_rel[@]}"; then continue; fi
    candidates+=("$p")
  done < <(printf '%s\n%s\n%s\n' "$wt_dirty" "$staged_dirty" "$untracked")

  local -a sorted_changed=()
  if [[ ${#candidates[@]} -gt 0 ]]; then
    while IFS= read -r p; do [[ -n "$p" ]] && sorted_changed+=("$p"); done < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort -u)
  fi

  local git_dir tmp_fp w_sha tree_hash
  git_dir="$(resolve_git_dir "$root")" || { echo "GIT_ERROR: unable to resolve .git dir"; return 1; }
  tmp_fp="${git_dir}/b3-tree-fp-$$-${RANDOM}.tmp"
  _CLEANUP_FILES+=("$tmp_fp")

  {
    printf 'HEAD=%s\n' "$head_sha"
    printf 'PATHS=%s\n' "$paths_csv"
    if [[ ${#sorted_changed[@]} -gt 0 ]]; then
      for p in "${sorted_changed[@]}"; do
        if [[ -f "${root}/${p}" ]]; then
          w_sha="$(git -C "$root" hash-object -- "$p" 2>&1)" || { echo "GIT_ERROR: git hash-object failed for $p" >&2; rm -f "$tmp_fp"; return 1; }
          w_sha="$(trim_str "$w_sha")"
          printf 'W %s %s\n' "$p" "$w_sha"
        else
          printf 'W %s DELETED\n' "$p"
        fi
      done
    fi
  } > "$tmp_fp"

  tree_hash="$(git -C "$root" hash-object -- "$tmp_fp" 2>&1)" || { echo "GIT_ERROR: git hash-object manifest failed: $tree_hash"; rm -f "$tmp_fp"; return 1; }
  tree_hash="$(trim_str "$tree_hash")"
  rm -f "$tmp_fp"
  if [[ ! "$tree_hash" =~ ^[0-9a-f]{40}$ ]]; then
    echo "GIT_ERROR: git hash-object manifest failed: $tree_hash"
    return 1
  fi
  printf '%s\n%s\n%s\n' "$head_sha" "$tree_hash" "$paths_csv"
}

run_verify_check() {
  local root="$1"
  local receipt_arg="$2"
  local ign_csv="$3"
  local expected_cmd_arg="${4:-}"
  local req_rel_arg="${5:-}"
  _VR_MSG=""
  _VR_REL_PATHS=""
  local trim_arg
  trim_arg="$(trim_str "$receipt_arg")"
  if [[ -z "$trim_arg" ]]; then
    _VR_MSG="VERIFY_MISSING: empty receipt path"
    return 1
  fi
  local full_receipt disp_path
  full_receipt="$(resolve_target_path "$root" "$trim_arg")"
  disp_path="$(repo_rel_path "$root" "$full_receipt")"
  if [[ ! -f "$full_receipt" ]]; then
    _VR_MSG="VERIFY_MISSING: $disp_path"
    return 1
  fi

  local _v_schema="" _v_task_id="" _v_scope="" _v_head_sha="" _v_tree_hash="" _v_relevant_paths="" _v_exit_code="" _v_status="" _v_command="" _v_log_path="" _v_timestamp_utc=""
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

  if [[ "$_v_log_path" != "none" ]]; then
    local lp_slash canon_root full_log log_dir canon_dir cr_low cd_low
    lp_slash="${_v_log_path//\\//}"
    lp_slash="$(trim_str "$lp_slash")"
    if [[ -z "$lp_slash" || "$lp_slash" == "." || "$lp_slash" == /* || "$lp_slash" == ~* || "$lp_slash" =~ ^[A-Za-z]: || "$lp_slash" =~ (^|/)\.\.(/|$) ]]; then
      _VR_MSG="VERIFY_CORRUPT: invalid log_path"
      return 1
    fi
    full_log="$(resolve_target_path "$root" "$lp_slash")"
    local rem="${lp_slash#./}" seg_cur="$root" seg
    while [[ -n "$rem" ]]; do
      if [[ "$rem" == */* ]]; then
        seg="${rem%%/*}"
        rem="${rem#*/}"
      else
        seg="$rem"
        rem=""
      fi
      [[ -z "$seg" || "$seg" == "." ]] && continue
      seg_cur="${seg_cur}/${seg}"
      if [[ -L "$seg_cur" ]]; then
        _VR_MSG="VERIFY_CORRUPT: invalid log_path"
        return 1
      fi
    done
    canon_root="$(cd "$root" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || canon_root=""
    canon_root="$(norm_path "$canon_root")"
    if [[ -n "$canon_root" ]]; then
      log_dir="$(dirname "$full_log")"
      if [[ -d "$log_dir" ]]; then
        canon_dir="$(cd "$log_dir" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || canon_dir=""
        canon_dir="$(norm_path "$canon_dir")"
        cr_low="$(printf '%s' "$canon_root" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        cd_low="$(printf '%s' "$canon_dir" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        if [[ -z "$cd_low" || ( "$cd_low" != "$cr_low" && "$cd_low" != "$cr_low/"* ) ]]; then
          _VR_MSG="VERIFY_CORRUPT: invalid log_path"
          return 1
        fi
      fi
    fi
    if [[ ! -f "$full_log" ]]; then
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
    local rp
    while IFS= read -r rp; do [[ -n "$rp" ]] && rp_arr+=("$rp"); done < <(split_csv_lines "$_v_relevant_paths" true)
    if [[ ${#rp_arr[@]} -lt 1 ]]; then
      _VR_MSG="VERIFY_CORRUPT: invalid relevant_paths"
      return 1
    fi
    for rp in "${rp_arr[@]}"; do
      if is_checkpoint_dir "$rp"; then
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
    local -a req_arr=()
    local rq
    while IFS= read -r rq; do
      [[ -n "$rq" ]] || continue
      is_checkpoint_dir "$rq" && continue
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

  local fp_out cur_head cur_tree cur_paths
  if ! fp_out="$(compute_tree_fingerprint "$root" "$rel_for_fp" "$ign_csv")"; then
    _VR_MSG="$fp_out"
    return 1
  fi
  {
    IFS= read -r cur_head
    IFS= read -r cur_tree
    IFS= read -r cur_paths
  } <<< "$fp_out"

  if [[ "$cur_head" != "$_v_head_sha" || "$cur_tree" != "$_v_tree_hash" ]]; then
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
  local gd
  gd="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)"
  gd="$(trim_str "$gd")"
  [[ -n "$gd" ]] || return 1
  if [[ "$gd" != /* && ! "$gd" =~ ^[A-Za-z]: ]]; then
    gd="${dir}/${gd}"
  fi
  if [[ -d "$gd" ]]; then
    local abs
    abs="$(cd "$gd" && (pwd -W 2>/dev/null || pwd -P))"
    norm_path "$abs"
  else
    norm_path "$gd"
  fi
}

paths_equal_fs() {
  local a b
  a="$(norm_path "$1")"
  b="$(norm_path "$2")"
  if [[ "$a" =~ ^[A-Za-z]: || "$b" =~ ^[A-Za-z]: ]]; then
    a="$(printf '%s' "$a" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    b="$(printf '%s' "$b" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  fi
  [[ "$a" == "$b" ]]
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
      if is_checkpoint_dir "$p"; then
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
      IDX_VS_WT="$(git -C "$REPO_ROOT" diff --no-renames --name-only -- "${STAGED_ARR[@]}")" || { echo "GIT_ERROR: git diff index-vs-wt failed"; exit 1; }
      STAGED_DEL="$(git -C "$REPO_ROOT" diff --no-renames --cached --diff-filter=D --name-only)" || { echo "GIT_ERROR: git diff cached delete failed"; exit 1; }
      WT_MM=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -n "$p" ]] && WT_MM+=("$p")
      done <<< "$IDX_VS_WT"
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -n "$p" ]] || continue
        if [[ -e "${REPO_ROOT}/${p}" ]]; then
          WT_MM+=("$p")
        fi
      done <<< "$STAGED_DEL"
      if [[ ${#WT_MM[@]} -gt 0 ]]; then
        MM_STR="$(printf '%s\n' "${WT_MM[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
        echo "PRECOMMIT_FAIL: staged content differs from working tree (${MM_STR//,/, })"
        exit 1
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
    ALLOW_MASS_DELETE=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --base-sha) BASE_SHA="${2:-}"; shift 2 ;;
        --target-ref) TARGET_REF="${2:-}"; shift 2 ;;
        --allowed-paths) ALLOWED="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --obsoletes) OBSOLETES="${2:-}"; shift 2 ;;
        --allow-mass-delete) ALLOW_MASS_DELETE=true; shift ;;
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
      is_checkpoint_dir "$p" && continue
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

    SAFETY_HITS=()
    if [[ ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if is_secret_path "$p"; then
          SAFETY_HITS+=("secret_path:${p}")
        fi
      done
    fi
    SQL_HIT_COUNT=0

    if [[ -n "$TARGET_REF" ]]; then
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "MECHANICAL_FAIL: git diff -U0 failed"; exit 1; }
    else
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA")" || { echo "MECHANICAL_FAIL: git diff -U0 failed"; exit 1; }
    fi
    LEFTOVER_HITS=()
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
          if [[ -z "$CUR_FILE" ]] || is_checkpoint_dir "$CUR_FILE" || [[ "$CUR_FILE" == *.md ]]; then
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
          LEFTOVER_HITS+=("${CUR_FILE}:${CUR_LINE}:${_LO_TAG}")
        fi
        if ! $CUR_IS_TEST && has_destructive_sql "$body" && [[ $SQL_HIT_COUNT -lt 10 ]]; then
          SAFETY_HITS+=("destructive_sql:${CUR_FILE}:${CUR_LINE}")
          SQL_HIT_COUNT=$((SQL_HIT_COUNT + 1))
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
        if [[ ${#LEFTOVER_HITS[@]} -ge 10 && $SQL_HIT_COUNT -ge 10 ]]; then break; fi
        if is_checkpoint_dir "$u" || [[ "$u" == *.md ]]; then continue; fi
        is_noise_file "$u" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
        [[ -f "${REPO_ROOT}/${u}" ]] || continue
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

    if [[ -n "$TARGET_REF" ]]; then
      DEL_OUT="$(git -C "$REPO_ROOT" diff --no-renames --diff-filter=D --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "MECHANICAL_FAIL: git diff --diff-filter=D failed"; exit 1; }
    else
      DEL_OUT="$(git -C "$REPO_ROOT" diff --no-renames --diff-filter=D --name-only "$BASE_SHA")" || { echo "MECHANICAL_FAIL: git diff --diff-filter=D failed"; exit 1; }
    fi
    DEL_ARR=()
    while IFS= read -r line; do
      dp="$(norm_path "$line")"
      [[ -n "$dp" ]] || continue
      is_checkpoint_dir "$dp" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$dp" "${IGNORE_ARR[@]}"; then continue; fi
      is_noise_file "$dp" && continue
      DEL_ARR+=("$dp")
    done <<< "$DEL_OUT"
    DEL_COUNT=0
    if [[ ${#DEL_ARR[@]} -gt 0 ]]; then
      DEL_COUNT="$(printf '%s\n' "${DEL_ARR[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    fi
    if [[ $DEL_COUNT -ge 10 ]] && ! $ALLOW_MASS_DELETE; then
      SAFETY_HITS+=("mass_delete:${DEL_COUNT}f")
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
    SF_OUT="none"
    if [[ ${#SAFETY_HITS[@]} -gt 0 ]]; then
      SF_OUT="$(printf '%s\n' "${SAFETY_HITS[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
    fi

    printf 'scope_creep=%s\nleftovers=%s\nobsolete_hits=%s\nsafety_hits=%s\n' "$SC_OUT" "$LO_OUT" "$OB_OUT" "$SF_OUT"
    if [[ "$SC_OUT" == "none" && "$LO_OUT" == "none" && "$OB_OUT" == "none" && "$SF_OUT" == "none" ]]; then
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
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --wave-specs) WAVE_SPECS="${2:-}"; shift 2 ;;
        --wave-reads) WAVE_READS="${2:-}"; shift 2 ;;
        --expected-base-sha) EXPECTED_BASE_SHA="${2:-}"; shift 2 ;;
        *) echo "WAVE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    WAVE_SPECS="$(trim_str "$WAVE_SPECS")"
    [[ -n "$WAVE_SPECS" ]] || { echo "WAVE_FAIL: missing --wave-specs"; exit 1; }

    EXPECTED_BASE_SHA="$(trim_str "$EXPECTED_BASE_SHA")"
    if [[ -n "$EXPECTED_BASE_SHA" ]]; then
      MID_OP="$(check_git_mid_operation "$REPO_ROOT")"
      if [[ -n "$MID_OP" ]]; then
        echo "WAVE_BASE_MISMATCH: git_op_in_progress($MID_OP)"
        exit 2
      fi
      ACT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
      ACT_HEAD="$(trim_str "$ACT_HEAD")"
      if [[ -z "$ACT_HEAD" ]]; then
        echo "WAVE_BASE_MISMATCH: git rev-parse HEAD failed"
        exit 2
      fi
      if [[ "$ACT_HEAD" != "$EXPECTED_BASE_SHA" ]]; then
        echo "WAVE_BASE_MISMATCH: expected=${EXPECTED_BASE_SHA} actual=${ACT_HEAD}"
        exit 2
      fi
    fi

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

    READ_IDS=()
    READ_PATHS_PACKED=()
    WAVE_READS="$(trim_str "$WAVE_READS")"
    if [[ -n "$WAVE_READS" ]]; then
      IFS=';' read -ra RENTRIES <<< "$WAVE_READS"
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
          if [[ ${#READ_IDS[@]} -gt 0 ]]; then
            for prev_rt in "${READ_IDS[@]}"; do
              if [[ "$prev_rt" == "$rtid" ]]; then
                echo "WAVE_FAIL: duplicate task id '$rtid' in WaveReads"
                exit 1
              fi
            done
          fi
          r_arr=()
          while IFS= read -r rp; do [[ -n "$rp" ]] && r_arr+=("$rp"); done < <(split_csv_lines "$rcsv" true | LC_ALL=C sort -u)
          READ_IDS+=("$rtid")
          if [[ ${#r_arr[@]} -gt 0 ]]; then
            rpacked="$(printf '%s\n' "${r_arr[@]}" | paste -sd '|' -)"
          else
            rpacked=""
          fi
          READ_PATHS_PACKED+=("$rpacked")
        done
      fi
    fi

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

    if [[ ${#READ_IDS[@]} -gt 0 ]]; then
      n_reads="${#READ_IDS[@]}"
      for ((i = 0; i < n_tasks; i++)); do
        ti="${TASK_IDS[$i]}"
        IFS='|' read -ra pi_arr <<< "${TASK_PATHS_PACKED[$i]}"
        for ((k = 0; k < n_reads; k++)); do
          tj="${READ_IDS[$k]}"
          [[ "$ti" == "$tj" ]] && continue
          [[ -z "${READ_PATHS_PACKED[$k]}" ]] && continue
          IFS='|' read -ra rj_arr <<< "${READ_PATHS_PACKED[$k]}"
          for pi in "${pi_arr[@]}"; do
            for rj in "${rj_arr[@]}"; do
              if [[ "$pi" == "$rj" ]]; then
                CONFLICTS+=("rw:${pi}(${ti}->${tj})")
              elif [[ "$pi" == "." || "$rj" == "." || "$pi" == "$rj/"* || "$rj" == "$pi/"* ]]; then
                CONFLICTS+=("rw:${pi}<->${rj}(${ti}->${tj})")
              fi
            done
          done
        done
      done
    fi

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
    write_atomic_lf_file "${SHIP_DIR}/CURRENT" "${CANDIDATE}"$'\n'
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
    AUTODEV_DIR="${REPO_ROOT}/.b3/autodev"
    AUTODEV_RUNS_DIR="${AUTODEV_DIR}/runs"

    if [[ -n "$RUN_ID" ]]; then
      RUN_ID="$(trim_str "$RUN_ID")"
      valid_run_id "$RUN_ID" || { echo "RESOLVE_FAIL: invalid run id '$RUN_ID'"; exit 1; }
      if [[ -d "${RUNS_DIR}/${RUN_ID}" ]]; then
        printf '.b3/ship/runs/%s\n' "$RUN_ID"
        exit 0
      fi
      if [[ -d "${AUTODEV_RUNS_DIR}/${RUN_ID}" ]]; then
        printf '.b3/autodev/runs/%s\n' "$RUN_ID"
        exit 0
      fi
      echo "RESOLVE_FAIL: run not found '$RUN_ID'"
      exit 1
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

    if [[ -f "${SHIP_DIR}/progress.md" ]]; then
      ST="$(read_run_status "$SHIP_DIR")"
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

    echo "NO_RUNS"
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

    EFF_TASK="$(trim_str "$(printf '%s' "$TASK_ID" | LC_ALL=C tr '\r\n' '  ')")"
    [[ -n "$EFF_TASK" ]] || EFF_TASK="unknown"
    EFF_SCOPE="$(trim_str "$(printf '%s' "$SCOPE" | LC_ALL=C tr '\r\n' '  ')")"
    [[ -n "$EFF_SCOPE" ]] || EFF_SCOPE="scoped"

    FULL_RECEIPT="$(resolve_target_path "$REPO_ROOT" "$RECEIPT_PATH")"
    RECEIPT_REL="$(repo_rel_path "$REPO_ROOT" "$FULL_RECEIPT")"
    mkdir -p "$(dirname "$FULL_RECEIPT")"

    OUT_TMP="${FULL_RECEIPT}.out.$$.${RANDOM}.tmp"
    _CLEANUP_FILES+=("$OUT_TMP")
    set +e
    (cd "$REPO_ROOT" && sh -c "$VERIFY_CMD") >"$OUT_TMP" 2>&1
    CMD_EXIT=$?
    set -e

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
      if [[ -n "$(trim_str "$LOG_PATH")" ]]; then
        FULL_LOG="$(resolve_target_path "$REPO_ROOT" "$LOG_PATH")"
      else
        FULL_LOG="${FULL_RECEIPT}.log"
      fi
      mkdir -p "$(dirname "$FULL_LOG")"
      TMP_LOG="${FULL_LOG}.tmp.$$.${RANDOM}"
      _CLEANUP_FILES+=("$TMP_LOG")
      LC_ALL=C tr -d '\r' < "$OUT_TMP" > "$TMP_LOG"
      mv -f "$TMP_LOG" "$FULL_LOG"
      LOG_DISP="$(repo_rel_path "$REPO_ROOT" "$FULL_LOG")"
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
command=${SINGLE_CMD}
log_path=${LOG_DISP}
timestamp_utc=${TS_UTC}
"
    write_atomic_lf_file "$FULL_RECEIPT" "$RECEIPT_BODY"

    SHORT_TREE="${FP_TREE:0:12}"
    if [[ $CMD_EXIT -eq 0 ]]; then
      rm -f "$OUT_TMP"
      printf 'VERIFY_PASS: exit=0 tree=%s receipt=%s\n' "$SHORT_TREE" "$RECEIPT_REL"
      exit 0
    fi
    printf 'VERIFY_FAIL: exit=%s tree=%s receipt=%s log=%s\n' "$CMD_EXIT" "$SHORT_TREE" "$RECEIPT_REL" "$LOG_DISP"
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
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --receipt-path) RECEIPT_PATH="${2:-}"; shift 2 ;;
        --ignore-dirty-paths) IGNORE_DIRTY="${2:-}"; shift 2 ;;
        --expected-cmd) EXPECTED_CMD="${2:-}"; shift 2 ;;
        --relevant-paths) RELEVANT_PATHS="${2:-}"; shift 2 ;;
        *) echo "VERIFY_CHECK_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done
    set +e
    run_verify_check "$REPO_ROOT" "$RECEIPT_PATH" "$IGNORE_DIRTY" "$EXPECTED_CMD" "$RELEVANT_PATHS"
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

    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! TARGET_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}" 2>/dev/null)"; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$TARGET_COMMIT_SHA")"
      if [[ -z "$TARGET_COMMIT_SHA" ]]; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
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
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" --)" || { echo "SYMBOL_FAIL: git diff -U0 failed"; exit 1; }
    else
      DIFF_U0="$(git -C "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA")" || { echo "SYMBOL_FAIL: git diff -U0 failed"; exit 1; }
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

    _sym_exists() {
      local kind="$1" f="$2" s="$3" k
      if [[ "$kind" == "rem" ]]; then
        [[ ${#REM_KEYS[@]} -gt 0 ]] || return 1
        for k in "${REM_KEYS[@]}"; do [[ "$k" == "${f}|${s}" ]] && return 0; done
      else
        [[ ${#ADD_KEYS[@]} -gt 0 ]] || return 1
        for k in "${ADD_KEYS[@]}"; do [[ "$k" == "${f}|${s}" ]] && return 0; done
      fi
      return 1
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
      if [[ "$ln" =~ ^@@\ -[0-9,]+\ \+[0-9,]+\ @@ ]] || [[ "$ln" =~ ^@@\ -[0-9]+\ \+[0-9]+\ @@ ]] || [[ "$ln" =~ ^@@\ -[0-9,]+\ \+[0-9]+\ @@ ]] || [[ "$ln" =~ ^@@\ -[0-9]+\ \+[0-9,]+\ @@ ]]; then
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
      UN_OUT="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" || { echo "SYMBOL_FAIL: git ls-files failed"; exit 1; }
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

    if [[ ${#REM_KEYS[@]} -gt 0 ]]; then
      for ((idx = 0; idx < ${#REM_KEYS[@]}; idx++)); do
        k="${REM_KEYS[$idx]}"
        is_exp="${REM_EXPS[$idx]}"
        f="${k%%|*}"
        s_name="${k#*|}"
        _sym_exists add "$f" "$s_name" && continue
        REMOVED_SYMS+=("$s_name")
        [[ "$is_exp" == "1" ]] && EXPORTED_REMOVED+=("$s_name")
        if [[ "$REM_CHECKED" == *"|${s_name}|"* ]]; then continue; fi
        REM_CHECKED="${REM_CHECKED}${s_name}|"

        set +e
        if [[ -n "$TARGET_REF" ]]; then
          g_out="$(git -C "$REPO_ROOT" grep -w -F -l -e "$s_name" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3' ':(exclude)*.md' 2>/dev/null)"
        else
          g_out="$(git -C "$REPO_ROOT" grep --untracked -w -F -l -e "$s_name" -- . ':(exclude).b3' ':(exclude)*.md' 2>/dev/null)"
        fi
        g_code=$?
        set -e
        if [[ $g_code -gt 1 ]]; then
          echo "SYMBOL_FAIL: git grep failed for '$s_name'"
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
        _sym_exists rem "$f" "$s_name" && continue

        set +e
        if [[ -n "$TARGET_REF" ]]; then
          gn_out="$(git -C "$REPO_ROOT" grep -w -F -n -e "$s_name" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3' ':(exclude)*.md' 2>/dev/null)"
        else
          gn_out="$(git -C "$REPO_ROOT" grep --untracked -w -F -n -e "$s_name" -- . ':(exclude).b3' ':(exclude)*.md' 2>/dev/null)"
        fi
        gn_code=$?
        set -e
        if [[ $gn_code -gt 1 ]]; then
          echo "SYMBOL_FAIL: git grep -n failed for '$s_name'"
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
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        --expected-root) EXPECTED_ROOT="${2:-}"; shift 2 ;;
        --expected-base-sha) EXPECTED_BASE_SHA="${2:-}"; shift 2 ;;
        *) echo "WORKTREE_FAIL: unknown option $1" >&2; exit 1 ;;
      esac
    done

    if [[ ! -d "$REPO_ROOT" ]]; then
      echo "WORKTREE_UNSAFE: missing_repo_root(${REPO_ROOT})"
      exit 2
    fi
    TOP_RAW="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
    TOP_RAW="$(trim_str "$TOP_RAW")"
    if [[ -z "$TOP_RAW" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
      exit 2
    fi
    HEAD_RAW="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    HEAD_RAW="$(trim_str "$HEAD_RAW")"
    if [[ ! "$HEAD_RAW" =~ ^[0-9a-f]{40}$ ]]; then
      echo "WORKTREE_UNSAFE: unborn_or_invalid_head"
      exit 2
    fi
    ACTUAL_ROOT_NORM="$(norm_path "$TOP_RAW")"

    MID_OP="$(check_git_mid_operation "$REPO_ROOT")"
    if [[ -n "$MID_OP" ]]; then
      echo "WORKTREE_UNSAFE: git_op_in_progress(${MID_OP})"
      exit 2
    fi

    EXPECTED_ROOT="$(trim_str "$EXPECTED_ROOT")"
    if [[ -n "$EXPECTED_ROOT" ]]; then
      if [[ ! -d "$EXPECTED_ROOT" ]]; then
        echo "WORKTREE_UNSAFE: expected_root_missing(${EXPECTED_ROOT})"
        exit 2
      fi
      EXP_TOP_RAW="$(git -C "$EXPECTED_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
      EXP_TOP_RAW="$(trim_str "$EXP_TOP_RAW")"
      if [[ -z "$EXP_TOP_RAW" ]]; then
        echo "WORKTREE_UNSAFE: expected_root_not_git(${EXPECTED_ROOT})"
        exit 2
      fi
      EXP_TOP_NORM="$(norm_path "$EXP_TOP_RAW")"
      ACT_COMMON="$(resolve_canonical_git_common_dir "$REPO_ROOT" || true)"
      EXP_COMMON="$(resolve_canonical_git_common_dir "$EXPECTED_ROOT" || true)"

      TOP_SAME=false
      COMMON_SAME=false
      if paths_equal_fs "$ACTUAL_ROOT_NORM" "$EXP_TOP_NORM"; then TOP_SAME=true; fi
      if [[ -n "$ACT_COMMON" && -n "$EXP_COMMON" ]] && paths_equal_fs "$ACT_COMMON" "$EXP_COMMON"; then COMMON_SAME=true; fi
      if ! $TOP_SAME && ! $COMMON_SAME; then
        echo "WORKTREE_UNSAFE: root_mismatch(expected=${EXP_TOP_NORM},actual=${ACTUAL_ROOT_NORM})"
        exit 2
      fi
    fi

    EXPECTED_BASE_SHA="$(trim_str "$EXPECTED_BASE_SHA")"
    if [[ -n "$EXPECTED_BASE_SHA" ]]; then
      if [[ "$HEAD_RAW" != "$EXPECTED_BASE_SHA" ]]; then
        echo "WORKTREE_UNSAFE: base_mismatch(expected=${EXPECTED_BASE_SHA},actual=${HEAD_RAW})"
        exit 2
      fi
    fi

    printf 'WORKTREE_OK: root=%s head=%s\n' "$ACTUAL_ROOT_NORM" "$HEAD_RAW"
    exit 0
    ;;

  resolve-models)
    REPO_ROOT="."
    B3_HOME_ARG=""
    PERSONAL_CFG=""
    PROJECT_CFG=""
    ROLE_ARG=""
    EXPLICIT_MODEL=""
    AS_JSON=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo-root)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --repo-root requires a value"; exit 1; }
          REPO_ROOT="$2"; shift 2 ;;
        --b3-home)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --b3-home requires a value"; exit 1; }
          B3_HOME_ARG="$2"; shift 2 ;;
        --personal-config)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --personal-config requires a value"; exit 1; }
          PERSONAL_CFG="$2"; shift 2 ;;
        --project-config)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --project-config requires a value"; exit 1; }
          PROJECT_CFG="$2"; shift 2 ;;
        --role)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --role requires a value"; exit 1; }
          ROLE_ARG="$2"; shift 2 ;;
        --explicit-model)
          [[ $# -ge 2 ]] || { echo "CONFIG_ERROR: option --explicit-model requires a value"; exit 1; }
          EXPLICIT_MODEL="$2"; shift 2 ;;
        --json) AS_JSON=true; shift ;;
        *) echo "CONFIG_ERROR: unknown option $1" >&2; exit 1 ;;
      esac
    done

    canon_fwd_path() {
      local p="${1//\\//}"
      if [[ "$p" =~ ^([a-z]):(.*)$ ]]; then
        local d
        d="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
        p="${d}:${BASH_REMATCH[2]}"
      fi
      while [[ "$p" == */ && "$p" != "/" && ! "$p" =~ ^[A-Za-z]:/$ ]]; do
        p="${p%/}"
      done
      if [[ -d "$p" ]]; then
        local r
        r="$(cd "$p" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || r="$p"
        r="${r//\\//}"
        if [[ "$r" =~ ^([a-z]):(.*)$ ]]; then
          local d
          d="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
          r="${d}:${BASH_REMATCH[2]}"
        fi
        printf '%s' "${r%/}"
        return
      fi
      local cur="$p" suffix=""
      while [[ ! -d "$cur" ]]; do
        local base parent
        base="$(basename "$cur")"
        parent="$(dirname "$cur")"
        [[ "$parent" == "$cur" ]] && break
        if [[ -z "$suffix" ]]; then suffix="$base"; else suffix="${base}/${suffix}"; fi
        cur="$parent"
      done
      if [[ -d "$cur" ]]; then
        local resolved
        resolved="$(cd "$cur" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || resolved="$cur"
        resolved="${resolved//\\//}"
        if [[ "$resolved" =~ ^([a-z]):(.*)$ ]]; then
          local d
          d="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
          resolved="${d}:${BASH_REMATCH[2]}"
        fi
        resolved="${resolved%/}"
        if [[ -n "$suffix" ]]; then printf '%s/%s' "$resolved" "$suffix"; else printf '%s' "$resolved"; fi
      else
        printf '%s' "$p"
      fi
    }

    json_escape() {
      LC_ALL=C awk -v s="$1" 'BEGIN {
        out = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
          ch = substr(s, i, 1)
          if (ch == "\\") out = out "\\\\"
          else if (ch == "\"") out = out "\\\""
          else if (ch == "\t") out = out "\\t"
          else if (ch == "\r") out = out "\\r"
          else if (ch == "\n") out = out "\\n"
          else out = out ch
        }
        printf "%s", out
      }'
    }

    # Parse & strictly validate JSON model config using pure AWK recursive descent
    parse_model_json_awk() {
      local cfg_path="$1" norm_disp="$2"
      LC_ALL=C awk -v disp="$norm_disp" '
        BEGIN { src = "" }
        {
          gsub(/\r/, "", $0)
          src = (NR == 1 ? $0 : src "\n" $0)
        }
        function fail(msg) {
          print "CONFIG_ERROR: " disp ": " msg > "/dev/stderr"
          exit 2
        }
        function skip_ws() {
          while (pos <= slen) {
            ch = substr(src, pos, 1)
            if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") pos++
            else break
          }
        }
        function parse_string(    ch, out, esc, hx, i, hc) {
          if (substr(src, pos, 1) != "\"") fail("expected string")
          pos++
          out = ""
          while (pos <= slen) {
            ch = substr(src, pos, 1)
            if (ch == "\"") { pos++; return out }
            if (ch == "\n" || ch == "\r" || ch == "\t") fail("unescaped control character in string")
            if (ch == "\\") {
              pos++
              if (pos > slen) fail("unterminated escape sequence")
              esc = substr(src, pos, 1)
              if (esc == "\"" || esc == "\\" || esc == "/") out = out esc
              else if (esc == "b") out = out "\b"
              else if (esc == "f") out = out "\f"
              else if (esc == "n") out = out "\n"
              else if (esc == "r") out = out "\r"
              else if (esc == "t") out = out "\t"
              else if (esc == "u") {
                if (pos + 4 > slen) fail("invalid \\uXXXX escape")
                hx = substr(src, pos + 1, 4)
                for (i = 1; i <= 4; i++) {
                  hc = substr(hx, i, 1)
                  if (index("0123456789abcdefABCDEF", hc) == 0) fail("invalid \\uXXXX hex digit")
                }
                out = out "\\u" hx
                pos += 4
              } else fail("invalid escape \\" esc)
              pos++
            } else {
              out = out ch
              pos++
            }
          }
          fail("unterminated string")
        }
        function parse_number(    start, ch, sub_s) {
          start = pos
          if (substr(src, pos, 1) == "-") pos++
          if (pos > slen) fail("invalid number")
          ch = substr(src, pos, 1)
          if (ch == "0") {
            pos++
            if (pos <= slen && index("0123456789", substr(src, pos, 1)) > 0) fail("leading zero in number")
          } else if (index("123456789", ch) > 0) {
            while (pos <= slen && index("0123456789", substr(src, pos, 1)) > 0) pos++
          } else fail("invalid number")
          if (pos <= slen && substr(src, pos, 1) == ".") {
            pos++
            if (pos > slen || index("0123456789", substr(src, pos, 1)) == 0) fail("invalid fraction in number")
            while (pos <= slen && index("0123456789", substr(src, pos, 1)) > 0) pos++
          }
          if (pos <= slen && (substr(src, pos, 1) == "e" || substr(src, pos, 1) == "E")) {
            pos++
            if (pos <= slen && (substr(src, pos, 1) == "+" || substr(src, pos, 1) == "-")) pos++
            if (pos > slen || index("0123456789", substr(src, pos, 1)) == 0) fail("invalid exponent in number")
            while (pos <= slen && index("0123456789", substr(src, pos, 1)) > 0) pos++
          }
          return substr(src, start, pos - start)
        }
        function skip_value(depth,    ch, first) {
          if (depth > 32) fail("nesting too deep")
          skip_ws()
          if (pos > slen) fail("unexpected end of JSON")
          ch = substr(src, pos, 1)
          if (ch == "\"") { parse_string(); return "str" }
          if (ch == "{") {
            pos++; skip_ws()
            if (pos <= slen && substr(src, pos, 1) == "}") { pos++; return "obj" }
            while (1) {
              skip_ws(); parse_string(); skip_ws()
              if (substr(src, pos, 1) != ":") fail("expected colon in object")
              pos++; skip_value(depth + 1); skip_ws()
              if (pos > slen) fail("unterminated object")
              ch = substr(src, pos, 1)
              if (ch == ",") { pos++; continue }
              if (ch == "}") { pos++; return "obj" }
              fail("expected , or } in object")
            }
          }
          if (ch == "[") {
            pos++; skip_ws()
            if (pos <= slen && substr(src, pos, 1) == "]") { pos++; return "arr" }
            while (1) {
              skip_value(depth + 1); skip_ws()
              if (pos > slen) fail("unterminated array")
              ch = substr(src, pos, 1)
              if (ch == ",") { pos++; continue }
              if (ch == "]") { pos++; return "arr" }
              fail("expected , or ] in array")
            }
          }
          if (substr(src, pos, 4) == "true") { pos += 4; return "bool" }
          if (substr(src, pos, 5) == "false") { pos += 5; return "bool" }
          if (substr(src, pos, 4) == "null") { pos += 4; return "null" }
          if (ch == "-" || index("0123456789", ch) > 0) { parse_number(); return "num" }
          fail("unexpected token at pos " pos)
        }
        function trim(s) {
          gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "", s)
          return s
        }
        function parse_models_obj(    mk, mv, ch, mv_trim, mk_trim) {
          skip_ws()
          if (pos > slen || substr(src, pos, 1) != "{") fail("missing or non-object \x27models\x27")
          pos++; skip_ws()
          if (pos <= slen && substr(src, pos, 1) == "}") { pos++; return }
          while (1) {
            skip_ws()
            mk = parse_string()
            mk_trim = trim(mk)
            if (mk_trim == "" || mk ~ /[\n\r\t]/) fail("invalid role name \x27" mk "\x27")
            skip_ws()
            if (pos > slen || substr(src, pos, 1) != ":") fail("expected colon in models object")
            pos++; skip_ws()
            if (pos > slen || substr(src, pos, 1) != "\"") fail("model value for \x27" mk_trim "\x27 must be a non-empty string")
            mv = parse_string()
            mv_trim = trim(mv)
            if (mv_trim == "" || mv ~ /[\n\r\t]/) fail("model value for \x27" mk_trim "\x27 must be a non-empty string")
            if (!(mk_trim in m_seen)) { m_seen[mk_trim] = 1; m_order[++m_cnt] = mk_trim }
            m_val[mk_trim] = mv_trim
            skip_ws()
            if (pos > slen) fail("unterminated models object")
            ch = substr(src, pos, 1)
            if (ch == ",") { pos++; continue }
            if (ch == "}") { pos++; return }
            fail("expected , or } in models object")
          }
        }
        END {
          slen = length(src)
          pos = 1
          m_cnt = 0
          skip_ws()
          if (pos > slen || substr(src, pos, 1) != "{") fail("root must be a JSON object")
          pos++; skip_ws()
          seen_ver = 0; ver_val = ""; seen_models = 0
          if (pos <= slen && substr(src, pos, 1) == "}") {
            pos++
          } else {
            while (1) {
              skip_ws()
              tk = parse_string()
              if (tk != "version" && tk != "models" && tk != "_comment") fail("unsupported top-level key \x27" tk "\x27")
              skip_ws()
              if (pos > slen || substr(src, pos, 1) != ":") fail("expected colon after key \x27" tk "\x27")
              pos++; skip_ws()
              if (tk == "version") {
                if (pos > slen || (substr(src, pos, 1) != "-" && index("0123456789", substr(src, pos, 1)) == 0)) {
                  fail("missing or invalid \x27version\x27 (expected integer 1)")
                }
                ver_val = parse_number()
                seen_ver = 1
                if (ver_val != "1") fail("missing or invalid \x27version\x27 (expected integer 1)")
              } else if (tk == "_comment") {
                if (pos > slen || substr(src, pos, 1) != "\"") fail("\x27_comment\x27 must be a string")
                parse_string()
              } else if (tk == "models") {
                seen_models = 1
                parse_models_obj()
              }
              skip_ws()
              if (pos > slen) fail("unterminated root object")
              ch = substr(src, pos, 1)
              if (ch == ",") { pos++; continue }
              if (ch == "}") { pos++; break }
              fail("expected , or } in root object")
            }
          }
          skip_ws()
          if (pos <= slen) fail("trailing characters after JSON root")
          if (!seen_ver) fail("missing or invalid \x27version\x27 (expected integer 1)")
          if (!seen_models) fail("missing or non-object \x27models\x27")
          for (i = 1; i <= m_cnt; i++) {
            k = m_order[i]
            printf "%s\t%s\n", k, m_val[k]
          }
        }
      ' "$cfg_path"
    }

    SCRIPT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_PARENT="$(cd "${SCRIPT_DIR_SELF}/.." && pwd)"
    RESOLVED_B3_HOME=""
    if [[ -n "$(trim_str "$B3_HOME_ARG")" ]]; then
      RESOLVED_B3_HOME="$(trim_str "$B3_HOME_ARG")"
    else
      HOME_PTR="${REPO_ROOT}/.b3/home"
      if [[ -f "${SCRIPT_PARENT}/config/models.default.json" || -f "${SCRIPT_PARENT}/workflows/ship.md" ]]; then
        RESOLVED_B3_HOME="$SCRIPT_PARENT"
      elif [[ -n "${B3_HOME:-}" && -d "${B3_HOME}" ]]; then
        RESOLVED_B3_HOME="${B3_HOME}"
      elif [[ -f "$HOME_PTR" ]]; then
        PTR_VAL="$(trim_str "$(cat "$HOME_PTR")")"
        RESOLVED_B3_HOME="${PTR_VAL:-$SCRIPT_PARENT}"
      else
        RESOLVED_B3_HOME="$SCRIPT_PARENT"
      fi
    fi

    if [[ -z "$PERSONAL_CFG" ]]; then
      if [[ -n "${B3_MODELS_PERSONAL:-}" && -n "$(trim_str "$B3_MODELS_PERSONAL")" ]]; then
        PERSONAL_CFG="$(trim_str "$B3_MODELS_PERSONAL")"
      else
        PERSONAL_CFG="${HOME}/.b3/models.local.json"
      fi
    fi
    if [[ -z "$PROJECT_CFG" ]]; then
      PROJECT_CFG="${REPO_ROOT}/.b3/models.local.json"
    fi

    DEFAULT_CFG="$(canon_fwd_path "${RESOLVED_B3_HOME}/config/models.default.json")"
    PERSONAL_NORM="$(canon_fwd_path "$PERSONAL_CFG")"
    PROJECT_NORM="$(canon_fwd_path "$PROJECT_CFG")"

    CANONICAL_ROLES=("main" "planning" "implementation" "debugging" "b3-reviewer" "b3-fixer" "b3-security-reviewer" "b3-architecture-reviewer" "b3-performance-reviewer")
    WARNINGS=()

    is_known_role() {
      local cand="$1" r
      for r in "${CANONICAL_ROLES[@]}"; do
        [[ "$r" == "$cand" ]] && return 0
      done
      return 1
    }

    DEF_KEYS=(); DEF_VALS=(); DEF_PRESENT=false
    PERS_KEYS=(); PERS_VALS=(); PERS_PRESENT=false
    PROJ_KEYS=(); PROJ_VALS=(); PROJ_PRESENT=false

    load_model_layer() {
      local fpath="$1" norm_p="$2" prefix="$3"
      if [[ ! -e "$fpath" && ! -L "$fpath" ]]; then return 0; fi
      if [[ ! -f "$fpath" ]]; then
        echo "CONFIG_ERROR: ${norm_p}: path is not a regular file"
        exit 1
      fi
      if [[ "$prefix" == "DEF" ]]; then DEF_PRESENT=true
      elif [[ "$prefix" == "PERS" ]]; then PERS_PRESENT=true
      elif [[ "$prefix" == "PROJ" ]]; then PROJ_PRESENT=true
      fi
      local parsed_err tmp_kv
      tmp_kv="$(mktemp)"; _CLEANUP_FILES+=("$tmp_kv")
      if ! parsed_err="$(parse_model_json_awk "$fpath" "$norm_p" 2>&1 > "$tmp_kv")"; then
        printf '%s\n' "$parsed_err"
        exit 1
      fi
      local k v
      while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] || continue
        if ! is_known_role "$k"; then
          WARNINGS+=("UNKNOWN_ROLE_WARNING: role=${k} file=${norm_p}")
        fi
        if [[ "$prefix" == "DEF" ]]; then DEF_KEYS+=("$k"); DEF_VALS+=("$v")
        elif [[ "$prefix" == "PERS" ]]; then PERS_KEYS+=("$k"); PERS_VALS+=("$v")
        elif [[ "$prefix" == "PROJ" ]]; then PROJ_KEYS+=("$k"); PROJ_VALS+=("$v")
        fi
      done < "$tmp_kv"
    }

    load_model_layer "$DEFAULT_CFG" "$DEFAULT_CFG" "DEF"
    load_model_layer "$PERSONAL_NORM" "$PERSONAL_NORM" "PERS"
    load_model_layer "$PROJECT_NORM" "$PROJECT_NORM" "PROJ"

    EXPLICIT_TRIM="$(trim_str "$EXPLICIT_MODEL")"
    ROLE_TRIM="$(trim_str "$ROLE_ARG")"
    if [[ "$ROLE_ARG" == *$'\n'* || "$ROLE_ARG" == *$'\r'* || "$ROLE_ARG" == *$'\t'* ]]; then
      echo "CONFIG_ERROR: invalid --role value"
      exit 1
    fi

    lookup_layer() {
      local role="$1" layer="$2" i
      if [[ "$layer" == "PROJ" && ${#PROJ_KEYS[@]} -gt 0 ]]; then
        for i in "${!PROJ_KEYS[@]}"; do [[ "${PROJ_KEYS[$i]}" == "$role" ]] && { printf '%s' "${PROJ_VALS[$i]}"; return 0; }; done
      elif [[ "$layer" == "PERS" && ${#PERS_KEYS[@]} -gt 0 ]]; then
        for i in "${!PERS_KEYS[@]}"; do [[ "${PERS_KEYS[$i]}" == "$role" ]] && { printf '%s' "${PERS_VALS[$i]}"; return 0; }; done
      elif [[ "$layer" == "DEF" && ${#DEF_KEYS[@]} -gt 0 ]]; then
        for i in "${!DEF_KEYS[@]}"; do [[ "${DEF_KEYS[$i]}" == "$role" ]] && { printf '%s' "${DEF_VALS[$i]}"; return 0; }; done
      fi
      return 1
    }

    resolve_one_role() {
      local role="$1" raw="" src="platform_default"
      if [[ -n "$EXPLICIT_TRIM" ]]; then
        raw="$EXPLICIT_TRIM"; src="explicit"
      elif raw="$(lookup_layer "$role" "PROJ")"; then
        src="project"
      elif raw="$(lookup_layer "$role" "PERS")"; then
        src="personal"
      elif raw="$(lookup_layer "$role" "DEF")"; then
        src="default"
      else
        raw="auto"; src="platform_default"
      fi
      local low
      low="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      if [[ "$low" == "auto" ]]; then
        RES_MODEL="auto"
        RES_EFF="platform_default"
      else
        RES_MODEL="$raw"
        RES_EFF="$raw"
      fi
      RES_SRC="$src"
    }

    TARGET_ROLES=()
    if [[ -n "$ROLE_TRIM" ]]; then
      TARGET_ROLES=("$ROLE_TRIM")
    else
      TARGET_ROLES=("${CANONICAL_ROLES[@]}")
    fi

    if $AS_JSON; then
      printf '{\n  "version": 1,\n  "sources": {\n'
      if [[ -n "$EXPLICIT_TRIM" ]]; then
        printf '    "explicit": "%s",\n' "$(json_escape "$EXPLICIT_TRIM")"
      else
        printf '    "explicit": null,\n'
      fi
      printf '    "project": "%s",\n' "$(json_escape "$PROJECT_NORM")"
      printf '    "personal": "%s",\n' "$(json_escape "$PERSONAL_NORM")"
      printf '    "default": "%s",\n' "$(json_escape "$DEFAULT_CFG")"
      printf '    "project_present": %s,\n' "$($PROJ_PRESENT && echo true || echo false)"
      printf '    "personal_present": %s,\n' "$($PERS_PRESENT && echo true || echo false)"
      printf '    "default_present": %s\n' "$($DEF_PRESENT && echo true || echo false)"
      printf '  },\n  "warnings": ['
      if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '\n'
        for wi in "${!WARNINGS[@]}"; do
          sep=","
          [[ "$wi" -eq $((${#WARNINGS[@]} - 1)) ]] && sep=""
          printf '    "%s"%s\n' "$(json_escape "${WARNINGS[$wi]}")" "$sep"
        done
        printf '  '
      fi
      printf '],\n  "roles": {\n'
      for ri in "${!TARGET_ROLES[@]}"; do
        rn="${TARGET_ROLES[$ri]}"
        resolve_one_role "$rn"
        sep=","
        [[ "$ri" -eq $((${#TARGET_ROLES[@]} - 1)) ]] && sep=""
        printf '    "%s": { "model": "%s", "effective": "%s", "source": "%s" }%s\n' \
          "$(json_escape "$rn")" "$(json_escape "$RES_MODEL")" "$(json_escape "$RES_EFF")" "$(json_escape "$RES_SRC")" "$sep"
      done
      printf '  }\n}\n'
      exit 0
    fi

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
      for w in "${WARNINGS[@]}"; do printf '%s\n' "$w"; done
    fi
    for rn in "${TARGET_ROLES[@]}"; do
      resolve_one_role "$rn"
      printf 'role=%s model=%s effective=%s source=%s\n' "$rn" "$RES_MODEL" "$RES_EFF" "$RES_SRC"
    done
    if [[ -z "$ROLE_TRIM" ]]; then
      echo "RESOLVE_MODELS_OK"
    fi
    exit 0
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
