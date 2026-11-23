#!/usr/bin/env bash
# Deterministic helper checks for /b3-ship and /b3-review-loop (not an orchestrator or runner).
# Subcommands: fingerprint | check-freshness | precommit | snapshot | diff-scope | mechanical-check | check-wave | new-run | resolve-run | list-runs | prune | verify-run | verify-check | symbol-check | check-worktree
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

_GIT_STDOUT=""
_GIT_STDERR=""
run_git_cmd() {
  local root="$1"; shift
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/b3-git-err.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-git-err.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$errf")
  _GIT_STDOUT=""
  _GIT_STDERR=""
  if _GIT_STDOUT="$(git -C "$root" -c core.quotepath=false "$@" 2>"$errf")"; then
    rc=0
  else
    rc=$?
  fi
  _GIT_STDERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return $rc
}

run_git_cmd_with_index() {
  local root="$1" idx_file="$2"; shift 2
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/b3-git-err.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-git-err.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$errf")
  _GIT_STDOUT=""
  _GIT_STDERR=""
  if _GIT_STDOUT="$(GIT_INDEX_FILE="$idx_file" git -C "$root" -c core.quotepath=false "$@" 2>"$errf")"; then
    rc=0
  else
    rc=$?
  fi
  _GIT_STDERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return $rc
}

run_git_cmd_stdin() {
  local root="$1"
  local stdin_text="$2"
  shift 2
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/b3-git-err.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-git-err.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$errf")
  _GIT_STDOUT=""
  _GIT_STDERR=""
  if _GIT_STDOUT="$(printf '%s' "$stdin_text" | git -C "$root" -c core.quotepath=false "$@" 2>"$errf")"; then
    rc=0
  else
    rc=$?
  fi
  _GIT_STDERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return $rc
}

run_git_cmd_stdin_file() {
  local root="$1"
  local stdin_file="$2"
  shift 2
  local errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/b3-git-err.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-git-err.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$errf")
  _GIT_STDOUT=""
  _GIT_STDERR=""
  if _GIT_STDOUT="$(git -C "$root" -c core.quotepath=false "$@" < "$stdin_file" 2>"$errf")"; then
    rc=0
  else
    rc=$?
  fi
  _GIT_STDERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  return $rc
}

git_err_detail() {
  local d
  d="$(trim_str "$_GIT_STDERR")"
  [[ -n "$d" ]] || d="$(trim_str "$_GIT_STDOUT")"
  printf '%s' "$d"
}

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "usage: $0 fingerprint|check-freshness|precommit|snapshot|diff-scope|mechanical-check|check-wave|new-run|resolve-run|list-runs|prune|verify-run|verify-check|symbol-check|check-worktree [options]" >&2
  exit 1
fi
shift

_B3_IS_WINDOWS=false
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*) _B3_IS_WINDOWS=true ;;
esac

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
  if ! run_git_cmd "$root" rev-parse --verify --quiet "${rev}^{${kind}}"; then
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
  local root="$1" prefix="$2" changed untracked links p line sub state
  if ! run_git_cmd "$root" diff --no-renames --name-only HEAD --; then
    echo "${prefix}: unable to inspect snapshot paths"; return 1
  fi
  changed="$_GIT_STDOUT"
  if ! run_git_cmd "$root" ls-files --others --exclude-standard; then
    echo "${prefix}: unable to inspect untracked snapshot paths"; return 1
  fi
  untracked="$_GIT_STDOUT"
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -n "$p" ]] || continue
    if is_secret_path "$p"; then
      echo "${prefix}: sensitive path cannot be snapshotted ($p)"
      return 1
    fi
  done < <(printf '%s\n%s\n' "$changed" "$untracked")

  if ! run_git_cmd "$root" ls-files --stage; then
    echo "${prefix}: unable to inspect submodules"; return 1
  fi
  links="$_GIT_STDOUT"
  while IFS= read -r line; do
    [[ "$line" == 160000\ * ]] || continue
    [[ "$line" == *
  local root="$1" prefix="$2" real_idx_raw="" real_idx="" tmp_idx="" tree_sha=""
  snapshot_preflight "$root" "$prefix" || return 1
  if ! run_git_cmd "$root" rev-parse --git-path index; then
    echo "${prefix}: failed to locate git index"
    exit 1
  fi
  real_idx_raw="$(trim_str "$_GIT_STDOUT")"
  real_idx="$(resolve_target_path "$root" "$real_idx_raw")"
  tmp_idx="$(mktemp "${TMPDIR:-/tmp}/b3-snap-idx.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-snap-idx.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_idx")
  if [[ -f "$real_idx" ]]; then
    cp "$real_idx" "$tmp_idx"
  else
    rm -f "$tmp_idx"
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" add -A; then
    echo "${prefix}: git add -A failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" rm -r --cached --ignore-unmatch --quiet -- .b3/ship .b3/autodev; then
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

find_leftover_tag() {
  find_leftover_tag_var "$1"
  [[ -n "$_LO_TAG" ]] && printf '%s' "$_LO_TAG"
}

resolve_auto_base_sha() {
  local root="$1"
  shift
  local -a ignored=("$@")
  local diff_out="" un_out="" line p
  if run_git_cmd "$root" diff --no-renames --name-only HEAD; then diff_out="$_GIT_STDOUT"; fi
  if run_git_cmd "$root" ls-files --others --exclude-standard; then un_out="$_GIT_STDOUT"; fi
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -z "$p" ]] && continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ignored[@]} -gt 0 ]] && path_in_list "$p" "${ignored[@]}"; then continue; fi
    printf '%s' "HEAD"
    return 0
  done < <(printf '%s\n%s\n' "$diff_out" "$un_out")

  local head_sha="" ref mb=""
  if run_git_cmd "$root" rev-parse HEAD; then head_sha="$(trim_str "$_GIT_STDOUT")"; fi
  if [[ -n "$head_sha" ]]; then
    for ref in origin/HEAD origin/main origin/master main master; do
      if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
        if run_git_cmd "$root" merge-base "$ref" HEAD; then
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
    if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
      if run_git_cmd "$root" merge-base "$ref" "$target_commit_sha"; then
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
  if run_git_cmd "$root" rev-parse --verify --quiet "${target_commit_sha}^"; then
    local par=""
    par="$(trim_str "$_GIT_STDOUT")"
    if [[ -n "$par" ]]; then
      printf '%s' "$par"
      return 0
    fi
  fi
  printf '%s' "$target_commit_sha"
}

is_checkpoint_dir() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == ".b3/ship" || "$lp" == ".b3/ship/"* || "$lp" == ".b3/autodev" || "$lp" == ".b3/autodev/"* ]]
}

is_md_file() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == *.md ]]
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

repo_rel_path() {
  local root="$1"
  local full="$2"
  local rn fn
  rn="$(norm_path "$root")"
  fn="$(norm_path "$full")"
  if [[ "$rn" == "." ]]; then
    printf '%s' "$fn"
    return 0
  fi
  if [[ "$rn" == "/" ]]; then
    if [[ "$fn" == "/" ]]; then
      printf '.'
    elif [[ "$fn" == /* ]]; then
      printf '%s' "${fn:1}"
    else
      printf '%s' "$fn"
    fi
    return 0
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    local rn_low fn_low
    rn_low="$(printf '%s' "$rn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    fn_low="$(printf '%s' "$fn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$fn_low" == "$rn_low/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn_low" == "$rn_low" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
  else
    if [[ "$fn" == "$rn/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn" == "$rn" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
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

_SAFE_FULL=""
_SAFE_REL=""
validate_repo_write_path() {
  _SAFE_FULL=""
  _SAFE_REL=""
  local LC_ALL=C
  local root="$1"
  local raw_arg="$2"
  local p
  p="$(trim_str "$raw_arg")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if [[ "$p" == "." || "$p" == ~* || "$p" == */ ]]; then
    return 1
  fi
  if [[ "$p" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  local re_dotdot='(^|/)\.\.(/|$)'
  if [[ "$p" =~ $re_dotdot ]]; then
    return 1
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]] && [[ "$p" =~ ^[A-Za-z]: && ! "$p" =~ ^[A-Za-z]:/ ]]; then
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

  while [[ "$rel" == *"//"* ]]; do
    rel="${rel//\/\///}"
  done
  rel="${rel#/}"
  while [[ "$rel" == ./* ]]; do
    rel="${rel#./}"
  done
  while [[ "$rel" == *"/./"* ]]; do
    rel="${rel//\/.\///}"
  done
  rel="${rel%/.}"
  [[ -n "$rel" && "$rel" != "." ]] || return 1
  if [[ "$rel" == /* || "$rel" == ~* || "$rel" =~ ^[A-Za-z]: || "$rel" =~ $re_dotdot ]]; then
    return 1
  fi
  local rel_low re_git='^\.git(/|$)'
  rel_low="$(printf '%s' "$rel" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$rel_low" =~ $re_git ]]; then
    return 1
  fi

  local rem="$rel" seg_cur="${root%/}" seg
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
    if [[ -L "$seg_cur" ]]; then
      return 1
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
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tmp="${dest}.tmp.$$.${RANDOM}"
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
    if ! run_git_cmd_stdin "$root" "$tgt" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $sha"
      return 1
    fi
    printf '%s' "$sha"
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

    if ! run_git_cmd "$sub_full" status --porcelain -uall --ignore-submodules=none; then
      echo "GIT_ERROR: submodule status failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local st_out="$_GIT_STDOUT"
    local -a st_lines=()
    local raw_st clean_st trimmed_st
    while IFS= read -r raw_st; do
      clean_st="${raw_st%$'\r'}"
      trimmed_st="$(trim_str "$clean_st")"
      [[ -n "$trimmed_st" ]] && st_lines+=("$clean_st")
    done <<< "$st_out"

    if [[ ${#st_lines[@]} -eq 0 ]]; then
      printf '160000 commit %s' "$sub_head"
      return 0
    fi

    local dirty_buf="" sl
    while IFS= read -r sl; do
      [[ -n "$sl" ]] && dirty_buf="${dirty_buf}S ${sl}"$'\n'
    done < <(printf '%s\n' "${st_lines[@]}" | LC_ALL=C sort)

    local s_wt="" s_ca="" s_un=""
    if $has_head; then
      run_git_cmd "$sub_full" diff --no-renames --name-only --ignore-submodules=none HEAD || { echo "GIT_ERROR: submodule diff failed for ${rel_p}: $(git_err_detail)"; return 1; }
      s_wt="$_GIT_STDOUT"
    fi
    run_git_cmd "$sub_full" diff --no-renames --cached --name-only || { echo "GIT_ERROR: submodule diff cached failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_ca="$_GIT_STDOUT"
    run_git_cmd "$sub_full" ls-files --others --exclude-standard || { echo "GIT_ERROR: submodule ls-files failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_un="$_GIT_STDOUT"

    local -a s_cands=()
    local line sp
    while IFS= read -r line; do
      sp="$(norm_path "$line")"
      [[ -n "$sp" ]] && s_cands+=("$sp")
    done < <(printf '%s\n%s\n%s\n' "$s_wt" "$s_ca" "$s_un")

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

    if ! run_git_cmd_stdin "$root" "$dirty_buf" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local d_sha
    d_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$d_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $d_sha"
      return 1
    fi
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
  local head_sha
  if ! run_git_cmd "$root" rev-parse HEAD; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $(git_err_detail)"
    return 1
  fi
  head_sha="$(trim_str "$_GIT_STDOUT")"
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"
    return 1
  fi

  local is_win_os=false
  case "$(uname -s 2>/dev/null || printf '')" in
    MINGW*|MSYS*|CYGWIN*) is_win_os=true ;;
  esac
  local core_filemode=false
  if run_git_cmd "$root" config --bool core.filemode; then
    [[ "$(trim_str "$_GIT_STDOUT")" == "true" ]] && core_filemode=true
  else
    ! $is_win_os && core_filemode=true
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

  local ls_out diff_head_raw diff_cached_raw diff_idx_wt_raw untracked
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    run_git_cmd "$root" ls-tree -r HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
  else
    run_git_cmd "$root" ls-tree -r HEAD || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
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
      return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
      if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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

  local resolved_lines="" kind arg p full_p res_val rc_r=0 w_sha l_sha u_mode
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

  local tmp_fp tree_hash
  tmp_fp="$(mktemp "${TMPDIR:-/tmp}/b3-tree-fp.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-tree-fp.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_fp")

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
        return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
        if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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
        if (nm < 3 || mp[1] !~ /^[0-9]{6}$/ || (mp[2] != "blob" && mp[2] != "commit") || mp[3] !~ /^[0-9a-f]{40}$/) next
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
          em = ""
          if (has_e) { split(eff[fp], e_p, " "); em = e_p[1] }
          if ((cm == "000000" && has_e) || (cm != "000000" && (!has_e || em != cm))) {
            printf "I\t%s\t%s %s %s\n", fp, cm, entry_type(cm), c_o[fp]
          }
        }
        for (fp in eff) {
          printf "E\t%s\t%s\n", fp, eff[fp]
        }
      }
    ' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | LC_ALL=C awk -F '\t' '{ printf "%s %s %s\n", $1, $3, $2 }'
  } > "$tmp_fp"

  if ! run_git_cmd_stdin_file "$root" "$tmp_fp" hash-object --stdin; then
    echo "GIT_ERROR: git hash-object manifest failed: $(git_err_detail)"
    rm -f "$tmp_fp"
    return 1
  fi
  tree_hash="$(trim_str "$_GIT_STDOUT")"
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

  if [[ "$cur_head" != "$_v_head_sha" ]]; then
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

    if ! run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$TASK_BASE" HEAD; then
      echo "STALE: HEAD is not a descendant of task_base"
      exit 2
    fi

    run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" HEAD || { echo "GIT_ERROR: git diff failed: $(git_err_detail)"; exit 1; }
    COMMITTED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" || { echo "GIT_ERROR: git diff working tree failed: $(git_err_detail)"; exit 1; }
      WT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
      CA_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
      RO_HITS=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
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

    run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
    STAGED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${STAGED_ARR[@]}" || { echo "GIT_ERROR: git diff index-vs-wt failed: $(git_err_detail)"; exit 1; }
      IDX_VS_WT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --diff-filter=D --name-only || { echo "GIT_ERROR: git diff cached delete failed: $(git_err_detail)"; exit 1; }
      STAGED_DEL="$_GIT_STDOUT"
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

      IGN_ARR=()
      while IFS= read -r ip; do [[ -n "$ip" ]] && IGN_ARR+=("$ip"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)
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
      if $SCOPE_ALL; then
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      else
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      fi
      UNSTAGED_SCOPE=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -n "$p" ]] || continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGN_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGN_ARR[@]}"; then continue; fi
        if ! $SCOPE_ALL; then
          [[ ${#SCOPE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${SCOPE_ARR[@]}" || continue
        fi
        UNSTAGED_SCOPE+=("$p")
      done < <(printf '%s\n%s\n' "$UNSTAGED_RAW" "$UNTRACKED_RAW")
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
    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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
    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "DIFF_SCOPE_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      UNTRACKED_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "DIFF_SCOPE_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UNTRACKED_OUT="$_GIT_STDOUT"
    fi

    exact_in_list() {
      local cand="$1"; shift
      local it
      for it in "$@"; do [[ "$it" == "$cand" ]] && return 0; done
      return 1
    }

    REVIEW_ARR=()
    NOISE_ARR=()
    TOTAL_LINES=0

    while IFS=$'\t' read -r add del raw_path; do
      [[ -n "${raw_path:-}" ]] || continue
      p="$(norm_path "$raw_path")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then REVIEW_ARR+=("$p"); fi
      [[ "$add" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + add))
      [[ "$del" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + del))
    done <<< "$NUMSTAT_OUT"

    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then
        REVIEW_ARR+=("$p")
        if [[ -f "${REPO_ROOT}/${p}" ]] && ! is_binary_file "${REPO_ROOT}/${p}"; then
          lc="$(awk 'END{print NR}' "${REPO_ROOT}/${p}")"
          TOTAL_LINES=$((TOTAL_LINES + ${lc:-0}))
        fi
      fi
    done <<< "$UNTRACKED_OUT"

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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA" "$DELTA_END" -- || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed: $(git_err_detail)"; exit 1; }
      DELTA_OUT="$_GIT_STDOUT"
      DELTA_ARR=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
        if is_noise_file "$p"; then continue; fi
        DELTA_ARR+=("$p")
      done <<< "$DELTA_OUT"
      if [[ ${#DELTA_ARR[@]} -gt 0 ]]; then
        DF_OUT="$(printf '%s\n' "${DELTA_ARR[@]}" | LC_ALL=C sort -u | paste -sd ',' -)"
      fi
    fi

    if [[ ${#REVIEW_ARR[@]} -eq 0 && ${#NOISE_ARR[@]} -eq 0 ]]; then
      if ! $HAS_PREV || [[ "$DF_OUT" == "none" ]]; then
        echo "EMPTY_DIFF"
        exit 2
      fi
      printf 'size_class=CLEAN_AFTER_FIX\nfiles=0\nlines=0\nreview_files=none\nnoise_files=none\ndelta_files=%s\n' "$DF_OUT"
      exit 0
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "MECHANICAL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      UN_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "MECHANICAL_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
    fi

    ALL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      ALL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$CH_OUT" "$UN_OUT")

    NON_DEL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      NON_DEL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$NONDEL_OUT" "$UN_OUT")

    SCOPE_CREEP=()
    if [[ ${#ALLOWED_ARR[@]} -gt 0 && ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          SCOPE_CREEP+=("$p")
        fi
      done
    fi

    SAFETY_HITS=()
    if [[ ${#NON_DEL_CHANGED[@]} -gt 0 ]]; then
      for p in "${NON_DEL_CHANGED[@]}"; do
        if is_secret_path "$p"; then
          SAFETY_HITS+=("secret_path:${p}")
        fi
      done
    fi
    SQL_HIT_COUNT=0

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
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
        if is_checkpoint_dir "$u" || is_md_file "$u"; then continue; fi
        is_noise_file "$u" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
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

    if [[ -n "$TARGET_REF" ]]; then
      DEL_TARGET="$TARGET_COMMIT_SHA"
    else
      build_working_tree_oid "$REPO_ROOT" "MECHANICAL_FAIL"
      DEL_TARGET="$_WT_TREE_OID"
    fi
    run_git_cmd "$REPO_ROOT" diff -M --diff-filter=D --name-only "$BASE_SHA" "$DEL_TARGET" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=D failed: $(git_err_detail)"; exit 1; }
    DEL_OUT="$_GIT_STDOUT"
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
            if run_git_cmd "$REPO_ROOT" cat-file -e "${TARGET_COMMIT_SHA}:${norm_tok}"; then
              exists_path=true
            fi
          elif [[ -e "${REPO_ROOT}/${norm_tok}" ]]; then
            exists_path=true
          fi
        fi
        if [[ -n "$TARGET_REF" ]]; then
          if run_git_cmd "$REPO_ROOT" grep -l -F -e "$tok" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        else
          if run_git_cmd "$REPO_ROOT" grep --untracked -l -F -e "$tok" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        fi
        grep_out="$_GIT_STDOUT"
        if [[ "$grep_code" -gt 1 ]]; then
          echo "MECHANICAL_FAIL: git grep failed for obsolete '$tok': $(git_err_detail)"
          exit 1
        fi
        grep_count=0
        if [[ "$grep_code" -eq 0 && -n "$grep_out" ]]; then
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
          done <<< "$grep_out"
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

    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    SHIP_DIR="${DOT_B3_DIR}/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$SHIP_DIR" || -L "$RUNS_DIR" ]]; then
      echo "PRUNE_FAIL: runs directory is a link"
      exit 1
    fi
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

    mkdir -p "$(dirname "$FULL_RECEIPT")"

    OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/b3-verify-out.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-verify-out.$$.${RANDOM}.tmp")"
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
    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid --repo-root"
      printf '%s\n' "$_VR_MSG"
      exit 1
    fi
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "SYMBOL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
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
    TOP_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse --show-toplevel; then
      TOP_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
    if [[ -z "$TOP_RAW" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
      exit 2
    fi
    HEAD_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse HEAD; then
      HEAD_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
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
      EXP_TOP_RAW=""
      if run_git_cmd "$EXPECTED_ROOT" rev-parse --show-toplevel; then
        EXP_TOP_RAW="$(trim_str "$_GIT_STDOUT")"
      fi
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

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
\t'* ]] || continue
    p="${line#*
  local root="$1" prefix="$2" real_idx_raw="" real_idx="" tmp_idx="" tree_sha=""
  if ! run_git_cmd "$root" rev-parse --git-path index; then
    echo "${prefix}: failed to locate git index"
    exit 1
  fi
  real_idx_raw="$(trim_str "$_GIT_STDOUT")"
  real_idx="$(resolve_target_path "$root" "$real_idx_raw")"
  tmp_idx="$(mktemp "${TMPDIR:-/tmp}/b3-snap-idx.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-snap-idx.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_idx")
  if [[ -f "$real_idx" ]]; then
    cp "$real_idx" "$tmp_idx"
  else
    rm -f "$tmp_idx"
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" add -A; then
    echo "${prefix}: git add -A failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" rm -r --cached --ignore-unmatch --quiet -- .b3/ship .b3/autodev; then
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

find_leftover_tag() {
  find_leftover_tag_var "$1"
  [[ -n "$_LO_TAG" ]] && printf '%s' "$_LO_TAG"
}

resolve_auto_base_sha() {
  local root="$1"
  shift
  local -a ignored=("$@")
  local diff_out="" un_out="" line p
  if run_git_cmd "$root" diff --no-renames --name-only HEAD; then diff_out="$_GIT_STDOUT"; fi
  if run_git_cmd "$root" ls-files --others --exclude-standard; then un_out="$_GIT_STDOUT"; fi
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -z "$p" ]] && continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ignored[@]} -gt 0 ]] && path_in_list "$p" "${ignored[@]}"; then continue; fi
    printf '%s' "HEAD"
    return 0
  done < <(printf '%s\n%s\n' "$diff_out" "$un_out")

  local head_sha="" ref mb=""
  if run_git_cmd "$root" rev-parse HEAD; then head_sha="$(trim_str "$_GIT_STDOUT")"; fi
  if [[ -n "$head_sha" ]]; then
    for ref in origin/HEAD origin/main origin/master main master; do
      if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
        if run_git_cmd "$root" merge-base "$ref" HEAD; then
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
    if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
      if run_git_cmd "$root" merge-base "$ref" "$target_commit_sha"; then
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
  if run_git_cmd "$root" rev-parse --verify --quiet "${target_commit_sha}^"; then
    local par=""
    par="$(trim_str "$_GIT_STDOUT")"
    if [[ -n "$par" ]]; then
      printf '%s' "$par"
      return 0
    fi
  fi
  printf '%s' "$target_commit_sha"
}

is_checkpoint_dir() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == ".b3/ship" || "$lp" == ".b3/ship/"* || "$lp" == ".b3/autodev" || "$lp" == ".b3/autodev/"* ]]
}

is_md_file() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == *.md ]]
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

repo_rel_path() {
  local root="$1"
  local full="$2"
  local rn fn
  rn="$(norm_path "$root")"
  fn="$(norm_path "$full")"
  if [[ "$rn" == "." ]]; then
    printf '%s' "$fn"
    return 0
  fi
  if [[ "$rn" == "/" ]]; then
    if [[ "$fn" == "/" ]]; then
      printf '.'
    elif [[ "$fn" == /* ]]; then
      printf '%s' "${fn:1}"
    else
      printf '%s' "$fn"
    fi
    return 0
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    local rn_low fn_low
    rn_low="$(printf '%s' "$rn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    fn_low="$(printf '%s' "$fn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$fn_low" == "$rn_low/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn_low" == "$rn_low" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
  else
    if [[ "$fn" == "$rn/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn" == "$rn" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
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

_SAFE_FULL=""
_SAFE_REL=""
validate_repo_write_path() {
  _SAFE_FULL=""
  _SAFE_REL=""
  local LC_ALL=C
  local root="$1"
  local raw_arg="$2"
  local p
  p="$(trim_str "$raw_arg")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if [[ "$p" == "." || "$p" == ~* || "$p" == */ ]]; then
    return 1
  fi
  if [[ "$p" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  local re_dotdot='(^|/)\.\.(/|$)'
  if [[ "$p" =~ $re_dotdot ]]; then
    return 1
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]] && [[ "$p" =~ ^[A-Za-z]: && ! "$p" =~ ^[A-Za-z]:/ ]]; then
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

  while [[ "$rel" == *"//"* ]]; do
    rel="${rel//\/\///}"
  done
  rel="${rel#/}"
  while [[ "$rel" == ./* ]]; do
    rel="${rel#./}"
  done
  while [[ "$rel" == *"/./"* ]]; do
    rel="${rel//\/.\///}"
  done
  rel="${rel%/.}"
  [[ -n "$rel" && "$rel" != "." ]] || return 1
  if [[ "$rel" == /* || "$rel" == ~* || "$rel" =~ ^[A-Za-z]: || "$rel" =~ $re_dotdot ]]; then
    return 1
  fi
  local rel_low re_git='^\.git(/|$)'
  rel_low="$(printf '%s' "$rel" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$rel_low" =~ $re_git ]]; then
    return 1
  fi

  local rem="$rel" seg_cur="${root%/}" seg
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
    if [[ -L "$seg_cur" ]]; then
      return 1
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
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tmp="${dest}.tmp.$$.${RANDOM}"
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
    if ! run_git_cmd_stdin "$root" "$tgt" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $sha"
      return 1
    fi
    printf '%s' "$sha"
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

    if ! run_git_cmd "$sub_full" status --porcelain -uall --ignore-submodules=none; then
      echo "GIT_ERROR: submodule status failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local st_out="$_GIT_STDOUT"
    local -a st_lines=()
    local raw_st clean_st trimmed_st
    while IFS= read -r raw_st; do
      clean_st="${raw_st%$'\r'}"
      trimmed_st="$(trim_str "$clean_st")"
      [[ -n "$trimmed_st" ]] && st_lines+=("$clean_st")
    done <<< "$st_out"

    if [[ ${#st_lines[@]} -eq 0 ]]; then
      printf '160000 commit %s' "$sub_head"
      return 0
    fi

    local dirty_buf="" sl
    while IFS= read -r sl; do
      [[ -n "$sl" ]] && dirty_buf="${dirty_buf}S ${sl}"$'\n'
    done < <(printf '%s\n' "${st_lines[@]}" | LC_ALL=C sort)

    local s_wt="" s_ca="" s_un=""
    if $has_head; then
      run_git_cmd "$sub_full" diff --no-renames --name-only --ignore-submodules=none HEAD || { echo "GIT_ERROR: submodule diff failed for ${rel_p}: $(git_err_detail)"; return 1; }
      s_wt="$_GIT_STDOUT"
    fi
    run_git_cmd "$sub_full" diff --no-renames --cached --name-only || { echo "GIT_ERROR: submodule diff cached failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_ca="$_GIT_STDOUT"
    run_git_cmd "$sub_full" ls-files --others --exclude-standard || { echo "GIT_ERROR: submodule ls-files failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_un="$_GIT_STDOUT"

    local -a s_cands=()
    local line sp
    while IFS= read -r line; do
      sp="$(norm_path "$line")"
      [[ -n "$sp" ]] && s_cands+=("$sp")
    done < <(printf '%s\n%s\n%s\n' "$s_wt" "$s_ca" "$s_un")

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

    if ! run_git_cmd_stdin "$root" "$dirty_buf" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local d_sha
    d_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$d_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $d_sha"
      return 1
    fi
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
  local head_sha
  if ! run_git_cmd "$root" rev-parse HEAD; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $(git_err_detail)"
    return 1
  fi
  head_sha="$(trim_str "$_GIT_STDOUT")"
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"
    return 1
  fi

  local is_win_os=false
  case "$(uname -s 2>/dev/null || printf '')" in
    MINGW*|MSYS*|CYGWIN*) is_win_os=true ;;
  esac
  local core_filemode=false
  if run_git_cmd "$root" config --bool core.filemode; then
    [[ "$(trim_str "$_GIT_STDOUT")" == "true" ]] && core_filemode=true
  else
    ! $is_win_os && core_filemode=true
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

  local ls_out diff_head_raw diff_cached_raw diff_idx_wt_raw untracked
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    run_git_cmd "$root" ls-tree -r HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
  else
    run_git_cmd "$root" ls-tree -r HEAD || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
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
      return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
      if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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

  local resolved_lines="" kind arg p full_p res_val rc_r=0 w_sha l_sha u_mode
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

  local tmp_fp tree_hash
  tmp_fp="$(mktemp "${TMPDIR:-/tmp}/b3-tree-fp.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-tree-fp.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_fp")

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
        return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
        if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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
        if (nm < 3 || mp[1] !~ /^[0-9]{6}$/ || (mp[2] != "blob" && mp[2] != "commit") || mp[3] !~ /^[0-9a-f]{40}$/) next
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
          em = ""
          if (has_e) { split(eff[fp], e_p, " "); em = e_p[1] }
          if ((cm == "000000" && has_e) || (cm != "000000" && (!has_e || em != cm))) {
            printf "I\t%s\t%s %s %s\n", fp, cm, entry_type(cm), c_o[fp]
          }
        }
        for (fp in eff) {
          printf "E\t%s\t%s\n", fp, eff[fp]
        }
      }
    ' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | LC_ALL=C awk -F '\t' '{ printf "%s %s %s\n", $1, $3, $2 }'
  } > "$tmp_fp"

  if ! run_git_cmd_stdin_file "$root" "$tmp_fp" hash-object --stdin; then
    echo "GIT_ERROR: git hash-object manifest failed: $(git_err_detail)"
    rm -f "$tmp_fp"
    return 1
  fi
  tree_hash="$(trim_str "$_GIT_STDOUT")"
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

  if [[ "$cur_head" != "$_v_head_sha" ]]; then
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

    if ! run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$TASK_BASE" HEAD; then
      echo "STALE: HEAD is not a descendant of task_base"
      exit 2
    fi

    run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" HEAD || { echo "GIT_ERROR: git diff failed: $(git_err_detail)"; exit 1; }
    COMMITTED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" || { echo "GIT_ERROR: git diff working tree failed: $(git_err_detail)"; exit 1; }
      WT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
      CA_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
      RO_HITS=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
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

    run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
    STAGED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${STAGED_ARR[@]}" || { echo "GIT_ERROR: git diff index-vs-wt failed: $(git_err_detail)"; exit 1; }
      IDX_VS_WT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --diff-filter=D --name-only || { echo "GIT_ERROR: git diff cached delete failed: $(git_err_detail)"; exit 1; }
      STAGED_DEL="$_GIT_STDOUT"
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

      IGN_ARR=()
      while IFS= read -r ip; do [[ -n "$ip" ]] && IGN_ARR+=("$ip"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)
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
      if $SCOPE_ALL; then
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      else
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      fi
      UNSTAGED_SCOPE=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -n "$p" ]] || continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGN_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGN_ARR[@]}"; then continue; fi
        if ! $SCOPE_ALL; then
          [[ ${#SCOPE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${SCOPE_ARR[@]}" || continue
        fi
        UNSTAGED_SCOPE+=("$p")
      done < <(printf '%s\n%s\n' "$UNSTAGED_RAW" "$UNTRACKED_RAW")
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
    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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
    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "DIFF_SCOPE_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      UNTRACKED_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "DIFF_SCOPE_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UNTRACKED_OUT="$_GIT_STDOUT"
    fi

    exact_in_list() {
      local cand="$1"; shift
      local it
      for it in "$@"; do [[ "$it" == "$cand" ]] && return 0; done
      return 1
    }

    REVIEW_ARR=()
    NOISE_ARR=()
    TOTAL_LINES=0

    while IFS=$'\t' read -r add del raw_path; do
      [[ -n "${raw_path:-}" ]] || continue
      p="$(norm_path "$raw_path")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then REVIEW_ARR+=("$p"); fi
      [[ "$add" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + add))
      [[ "$del" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + del))
    done <<< "$NUMSTAT_OUT"

    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then
        REVIEW_ARR+=("$p")
        if [[ -f "${REPO_ROOT}/${p}" ]] && ! is_binary_file "${REPO_ROOT}/${p}"; then
          lc="$(awk 'END{print NR}' "${REPO_ROOT}/${p}")"
          TOTAL_LINES=$((TOTAL_LINES + ${lc:-0}))
        fi
      fi
    done <<< "$UNTRACKED_OUT"

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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA" "$DELTA_END" -- || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed: $(git_err_detail)"; exit 1; }
      DELTA_OUT="$_GIT_STDOUT"
      DELTA_ARR=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
        if is_noise_file "$p"; then continue; fi
        DELTA_ARR+=("$p")
      done <<< "$DELTA_OUT"
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "MECHANICAL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      UN_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "MECHANICAL_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
    fi

    ALL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      ALL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$CH_OUT" "$UN_OUT")

    NON_DEL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      NON_DEL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$NONDEL_OUT" "$UN_OUT")

    SCOPE_CREEP=()
    if [[ ${#ALLOWED_ARR[@]} -gt 0 && ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          SCOPE_CREEP+=("$p")
        fi
      done
    fi

    SAFETY_HITS=()
    if [[ ${#NON_DEL_CHANGED[@]} -gt 0 ]]; then
      for p in "${NON_DEL_CHANGED[@]}"; do
        if is_secret_path "$p"; then
          SAFETY_HITS+=("secret_path:${p}")
        fi
      done
    fi
    SQL_HIT_COUNT=0

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
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
        if is_checkpoint_dir "$u" || is_md_file "$u"; then continue; fi
        is_noise_file "$u" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
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

    if [[ -n "$TARGET_REF" ]]; then
      DEL_TARGET="$TARGET_COMMIT_SHA"
    else
      build_working_tree_oid "$REPO_ROOT" "MECHANICAL_FAIL"
      DEL_TARGET="$_WT_TREE_OID"
    fi
    run_git_cmd "$REPO_ROOT" diff -M --diff-filter=D --name-only "$BASE_SHA" "$DEL_TARGET" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=D failed: $(git_err_detail)"; exit 1; }
    DEL_OUT="$_GIT_STDOUT"
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
            if run_git_cmd "$REPO_ROOT" cat-file -e "${TARGET_COMMIT_SHA}:${norm_tok}"; then
              exists_path=true
            fi
          elif [[ -e "${REPO_ROOT}/${norm_tok}" ]]; then
            exists_path=true
          fi
        fi
        if [[ -n "$TARGET_REF" ]]; then
          if run_git_cmd "$REPO_ROOT" grep -l -F -e "$tok" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        else
          if run_git_cmd "$REPO_ROOT" grep --untracked -l -F -e "$tok" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        fi
        grep_out="$_GIT_STDOUT"
        if [[ "$grep_code" -gt 1 ]]; then
          echo "MECHANICAL_FAIL: git grep failed for obsolete '$tok': $(git_err_detail)"
          exit 1
        fi
        grep_count=0
        if [[ "$grep_code" -eq 0 && -n "$grep_out" ]]; then
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
          done <<< "$grep_out"
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

    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    SHIP_DIR="${DOT_B3_DIR}/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$SHIP_DIR" || -L "$RUNS_DIR" ]]; then
      echo "PRUNE_FAIL: runs directory is a link"
      exit 1
    fi
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

    mkdir -p "$(dirname "$FULL_RECEIPT")"

    OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/b3-verify-out.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-verify-out.$$.${RANDOM}.tmp")"
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
    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid --repo-root"
      printf '%s\n' "$_VR_MSG"
      exit 1
    fi
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "SYMBOL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
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
    TOP_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse --show-toplevel; then
      TOP_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
    if [[ -z "$TOP_RAW" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
      exit 2
    fi
    HEAD_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse HEAD; then
      HEAD_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
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
      EXP_TOP_RAW=""
      if run_git_cmd "$EXPECTED_ROOT" rev-parse --show-toplevel; then
        EXP_TOP_RAW="$(trim_str "$_GIT_STDOUT")"
      fi
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

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
\t'}"
    sub="${root}/${p}"
    [[ -e "${sub}/.git" ]] || continue
    if ! run_git_cmd "$sub" status --porcelain --untracked-files=all --ignore-submodules=none; then
      echo "${prefix}: unable to inspect submodule ($p)"
      return 1
    fi
    state="$_GIT_STDOUT"
    if [[ -n "$state" ]]; then
      echo "${prefix}: dirty submodule cannot be snapshotted ($p)"
      return 1
    fi
  done <<< "$links"
}

build_working_tree_oid() {
  local root="$1" prefix="$2" real_idx_raw="" real_idx="" tmp_idx="" tree_sha=""
  if ! run_git_cmd "$root" rev-parse --git-path index; then
    echo "${prefix}: failed to locate git index"
    exit 1
  fi
  real_idx_raw="$(trim_str "$_GIT_STDOUT")"
  real_idx="$(resolve_target_path "$root" "$real_idx_raw")"
  tmp_idx="$(mktemp "${TMPDIR:-/tmp}/b3-snap-idx.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-snap-idx.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_idx")
  if [[ -f "$real_idx" ]]; then
    cp "$real_idx" "$tmp_idx"
  else
    rm -f "$tmp_idx"
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" add -A; then
    echo "${prefix}: git add -A failed: $(git_err_detail)"
    rm -f "$tmp_idx"
    exit 1
  fi
  if ! run_git_cmd_with_index "$root" "$tmp_idx" rm -r --cached --ignore-unmatch --quiet -- .b3/ship .b3/autodev; then
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

find_leftover_tag() {
  find_leftover_tag_var "$1"
  [[ -n "$_LO_TAG" ]] && printf '%s' "$_LO_TAG"
}

resolve_auto_base_sha() {
  local root="$1"
  shift
  local -a ignored=("$@")
  local diff_out="" un_out="" line p
  if run_git_cmd "$root" diff --no-renames --name-only HEAD; then diff_out="$_GIT_STDOUT"; fi
  if run_git_cmd "$root" ls-files --others --exclude-standard; then un_out="$_GIT_STDOUT"; fi
  while IFS= read -r line; do
    p="$(norm_path "$line")"
    [[ -z "$p" ]] && continue
    is_checkpoint_dir "$p" && continue
    if [[ ${#ignored[@]} -gt 0 ]] && path_in_list "$p" "${ignored[@]}"; then continue; fi
    printf '%s' "HEAD"
    return 0
  done < <(printf '%s\n%s\n' "$diff_out" "$un_out")

  local head_sha="" ref mb=""
  if run_git_cmd "$root" rev-parse HEAD; then head_sha="$(trim_str "$_GIT_STDOUT")"; fi
  if [[ -n "$head_sha" ]]; then
    for ref in origin/HEAD origin/main origin/master main master; do
      if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
        if run_git_cmd "$root" merge-base "$ref" HEAD; then
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
    if run_git_cmd "$root" rev-parse --verify --quiet "$ref"; then
      if run_git_cmd "$root" merge-base "$ref" "$target_commit_sha"; then
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
  if run_git_cmd "$root" rev-parse --verify --quiet "${target_commit_sha}^"; then
    local par=""
    par="$(trim_str "$_GIT_STDOUT")"
    if [[ -n "$par" ]]; then
      printf '%s' "$par"
      return 0
    fi
  fi
  printf '%s' "$target_commit_sha"
}

is_checkpoint_dir() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == ".b3/ship" || "$lp" == ".b3/ship/"* || "$lp" == ".b3/autodev" || "$lp" == ".b3/autodev/"* ]]
}

is_md_file() {
  local lp
  lp="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$lp" == *.md ]]
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

repo_rel_path() {
  local root="$1"
  local full="$2"
  local rn fn
  rn="$(norm_path "$root")"
  fn="$(norm_path "$full")"
  if [[ "$rn" == "." ]]; then
    printf '%s' "$fn"
    return 0
  fi
  if [[ "$rn" == "/" ]]; then
    if [[ "$fn" == "/" ]]; then
      printf '.'
    elif [[ "$fn" == /* ]]; then
      printf '%s' "${fn:1}"
    else
      printf '%s' "$fn"
    fi
    return 0
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]]; then
    local rn_low fn_low
    rn_low="$(printf '%s' "$rn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    fn_low="$(printf '%s' "$fn" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$fn_low" == "$rn_low/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn_low" == "$rn_low" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
  else
    if [[ "$fn" == "$rn/"* ]]; then
      printf '%s' "${fn:${#rn}+1}"
    elif [[ "$fn" == "$rn" ]]; then
      printf '.'
    else
      printf '%s' "$fn"
    fi
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

_SAFE_FULL=""
_SAFE_REL=""
validate_repo_write_path() {
  _SAFE_FULL=""
  _SAFE_REL=""
  local LC_ALL=C
  local root="$1"
  local raw_arg="$2"
  local p
  p="$(trim_str "$raw_arg")"
  [[ -n "$p" ]] || return 1
  p="${p//\\//}"
  if [[ "$p" == "." || "$p" == ~* || "$p" == */ ]]; then
    return 1
  fi
  if [[ "$p" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  local re_dotdot='(^|/)\.\.(/|$)'
  if [[ "$p" =~ $re_dotdot ]]; then
    return 1
  fi
  if [[ "$_B3_IS_WINDOWS" == "true" ]] && [[ "$p" =~ ^[A-Za-z]: && ! "$p" =~ ^[A-Za-z]:/ ]]; then
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

  while [[ "$rel" == *"//"* ]]; do
    rel="${rel//\/\///}"
  done
  rel="${rel#/}"
  while [[ "$rel" == ./* ]]; do
    rel="${rel#./}"
  done
  while [[ "$rel" == *"/./"* ]]; do
    rel="${rel//\/.\///}"
  done
  rel="${rel%/.}"
  [[ -n "$rel" && "$rel" != "." ]] || return 1
  if [[ "$rel" == /* || "$rel" == ~* || "$rel" =~ ^[A-Za-z]: || "$rel" =~ $re_dotdot ]]; then
    return 1
  fi
  local rel_low re_git='^\.git(/|$)'
  rel_low="$(printf '%s' "$rel" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$rel_low" =~ $re_git ]]; then
    return 1
  fi

  local rem="$rel" seg_cur="${root%/}" seg
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
    if [[ -L "$seg_cur" ]]; then
      return 1
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
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tmp="${dest}.tmp.$$.${RANDOM}"
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
    if ! run_git_cmd_stdin "$root" "$tgt" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object symlink failed for ${rel_p}: $sha"
      return 1
    fi
    printf '%s' "$sha"
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

    if ! run_git_cmd "$sub_full" status --porcelain -uall --ignore-submodules=none; then
      echo "GIT_ERROR: submodule status failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local st_out="$_GIT_STDOUT"
    local -a st_lines=()
    local raw_st clean_st trimmed_st
    while IFS= read -r raw_st; do
      clean_st="${raw_st%$'\r'}"
      trimmed_st="$(trim_str "$clean_st")"
      [[ -n "$trimmed_st" ]] && st_lines+=("$clean_st")
    done <<< "$st_out"

    if [[ ${#st_lines[@]} -eq 0 ]]; then
      printf '160000 commit %s' "$sub_head"
      return 0
    fi

    local dirty_buf="" sl
    while IFS= read -r sl; do
      [[ -n "$sl" ]] && dirty_buf="${dirty_buf}S ${sl}"$'\n'
    done < <(printf '%s\n' "${st_lines[@]}" | LC_ALL=C sort)

    local s_wt="" s_ca="" s_un=""
    if $has_head; then
      run_git_cmd "$sub_full" diff --no-renames --name-only --ignore-submodules=none HEAD || { echo "GIT_ERROR: submodule diff failed for ${rel_p}: $(git_err_detail)"; return 1; }
      s_wt="$_GIT_STDOUT"
    fi
    run_git_cmd "$sub_full" diff --no-renames --cached --name-only || { echo "GIT_ERROR: submodule diff cached failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_ca="$_GIT_STDOUT"
    run_git_cmd "$sub_full" ls-files --others --exclude-standard || { echo "GIT_ERROR: submodule ls-files failed for ${rel_p}: $(git_err_detail)"; return 1; }
    s_un="$_GIT_STDOUT"

    local -a s_cands=()
    local line sp
    while IFS= read -r line; do
      sp="$(norm_path "$line")"
      [[ -n "$sp" ]] && s_cands+=("$sp")
    done < <(printf '%s\n%s\n%s\n' "$s_wt" "$s_ca" "$s_un")

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

    if ! run_git_cmd_stdin "$root" "$dirty_buf" hash-object --stdin; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $(git_err_detail)"
      return 1
    fi
    local d_sha
    d_sha="$(trim_str "$_GIT_STDOUT")"
    if [[ ! "$d_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "GIT_ERROR: git hash-object submodule digest failed for ${rel_p}: $d_sha"
      return 1
    fi
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
  local head_sha
  if ! run_git_cmd "$root" rev-parse HEAD; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $(git_err_detail)"
    return 1
  fi
  head_sha="$(trim_str "$_GIT_STDOUT")"
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "GIT_ERROR: git rev-parse HEAD failed: $head_sha"
    return 1
  fi

  local is_win_os=false
  case "$(uname -s 2>/dev/null || printf '')" in
    MINGW*|MSYS*|CYGWIN*) is_win_os=true ;;
  esac
  local core_filemode=false
  if run_git_cmd "$root" config --bool core.filemode; then
    [[ "$(trim_str "$_GIT_STDOUT")" == "true" ]] && core_filemode=true
  else
    ! $is_win_os && core_filemode=true
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

  local ls_out diff_head_raw diff_cached_raw diff_idx_wt_raw untracked
  if [[ ${#clean_rel[@]} -gt 0 ]]; then
    run_git_cmd "$root" ls-tree -r HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none -- "${clean_rel[@]}" || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard -- "${clean_rel[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
  else
    run_git_cmd "$root" ls-tree -r HEAD || { echo "GIT_ERROR: git ls-tree failed: $(git_err_detail)"; return 1; }
    ls_out="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none HEAD || { echo "GIT_ERROR: git diff --raw HEAD failed: $(git_err_detail)"; return 1; }
    diff_head_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --cached --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --cached --raw failed: $(git_err_detail)"; return 1; }
    diff_cached_raw="$_GIT_STDOUT"
    run_git_cmd "$root" diff --raw --no-renames --no-abbrev --ignore-submodules=none || { echo "GIT_ERROR: git diff --raw index-wt failed: $(git_err_detail)"; return 1; }
    diff_idx_wt_raw="$_GIT_STDOUT"
    run_git_cmd "$root" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; return 1; }
    untracked="$_GIT_STDOUT"
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
      return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
      if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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

  local resolved_lines="" kind arg p full_p res_val rc_r=0 w_sha l_sha u_mode
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

  local tmp_fp tree_hash
  tmp_fp="$(mktemp "${TMPDIR:-/tmp}/b3-tree-fp.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-tree-fp.$$.${RANDOM}.tmp")"
  _CLEANUP_FILES+=("$tmp_fp")

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
        return (s ~ /^\.b3\/(ship|autodev)(\/|$)/)
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
        if (nm !~ /^[0-9]{6}$/ || noid !~ /^[0-9a-f]{40}$/) return
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
        if (nm < 3 || mp[1] !~ /^[0-9]{6}$/ || (mp[2] != "blob" && mp[2] != "commit") || mp[3] !~ /^[0-9a-f]{40}$/) next
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
          em = ""
          if (has_e) { split(eff[fp], e_p, " "); em = e_p[1] }
          if ((cm == "000000" && has_e) || (cm != "000000" && (!has_e || em != cm))) {
            printf "I\t%s\t%s %s %s\n", fp, cm, entry_type(cm), c_o[fp]
          }
        }
        for (fp in eff) {
          printf "E\t%s\t%s\n", fp, eff[fp]
        }
      }
    ' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | LC_ALL=C awk -F '\t' '{ printf "%s %s %s\n", $1, $3, $2 }'
  } > "$tmp_fp"

  if ! run_git_cmd_stdin_file "$root" "$tmp_fp" hash-object --stdin; then
    echo "GIT_ERROR: git hash-object manifest failed: $(git_err_detail)"
    rm -f "$tmp_fp"
    return 1
  fi
  tree_hash="$(trim_str "$_GIT_STDOUT")"
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

  if [[ "$cur_head" != "$_v_head_sha" ]]; then
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

    if ! run_git_cmd "$REPO_ROOT" merge-base --is-ancestor "$TASK_BASE" HEAD; then
      echo "STALE: HEAD is not a descendant of task_base"
      exit 2
    fi

    run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" HEAD || { echo "GIT_ERROR: git diff failed: $(git_err_detail)"; exit 1; }
    COMMITTED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$APPROACH_AT" || { echo "GIT_ERROR: git diff working tree failed: $(git_err_detail)"; exit 1; }
      WT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
      CA_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
      RO_HITS=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
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

    run_git_cmd "$REPO_ROOT" diff --no-renames --cached --name-only || { echo "GIT_ERROR: git diff cached failed: $(git_err_detail)"; exit 1; }
    STAGED_OUT="$_GIT_STDOUT"
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
      run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${STAGED_ARR[@]}" || { echo "GIT_ERROR: git diff index-vs-wt failed: $(git_err_detail)"; exit 1; }
      IDX_VS_WT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --cached --diff-filter=D --name-only || { echo "GIT_ERROR: git diff cached delete failed: $(git_err_detail)"; exit 1; }
      STAGED_DEL="$_GIT_STDOUT"
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

      IGN_ARR=()
      while IFS= read -r ip; do [[ -n "$ip" ]] && IGN_ARR+=("$ip"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)
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
      if $SCOPE_ALL; then
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      else
        run_git_cmd "$REPO_ROOT" diff --no-renames --ignore-submodules=none --name-only -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git diff unstaged failed: $(git_err_detail)"; exit 1; }
        UNSTAGED_RAW="$_GIT_STDOUT"
        run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard -- "${SCOPE_ARR[@]}" || { echo "GIT_ERROR: git ls-files failed: $(git_err_detail)"; exit 1; }
        UNTRACKED_RAW="$_GIT_STDOUT"
      fi
      UNSTAGED_SCOPE=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -n "$p" ]] || continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGN_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGN_ARR[@]}"; then continue; fi
        if ! $SCOPE_ALL; then
          [[ ${#SCOPE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${SCOPE_ARR[@]}" || continue
        fi
        UNSTAGED_SCOPE+=("$p")
      done < <(printf '%s\n%s\n' "$UNSTAGED_RAW" "$UNTRACKED_RAW")
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
    IGNORE_ARR=()
    while IFS= read -r p; do [[ -n "$p" ]] && IGNORE_ARR+=("$p"); done < <(split_csv_lines "$IGNORE_DIRTY" true | LC_ALL=C sort -u)

    TARGET_REF="$(trim_str "$TARGET_REF")"
    TARGET_COMMIT_SHA=""
    if [[ -n "$TARGET_REF" ]]; then
      if [[ "$TARGET_REF" == -* ]]; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "DIFF_SCOPE_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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
    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "DIFF_SCOPE_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      UNTRACKED_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --numstat "$BASE_SHA" -- || { echo "DIFF_SCOPE_FAIL: git diff --numstat failed: $(git_err_detail)"; exit 1; }
      NUMSTAT_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "DIFF_SCOPE_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UNTRACKED_OUT="$_GIT_STDOUT"
    fi

    exact_in_list() {
      local cand="$1"; shift
      local it
      for it in "$@"; do [[ "$it" == "$cand" ]] && return 0; done
      return 1
    }

    REVIEW_ARR=()
    NOISE_ARR=()
    TOTAL_LINES=0

    while IFS=$'\t' read -r add del raw_path; do
      [[ -n "${raw_path:-}" ]] || continue
      p="$(norm_path "$raw_path")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then REVIEW_ARR+=("$p"); fi
      [[ "$add" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + add))
      [[ "$del" =~ ^[0-9]+$ ]] && TOTAL_LINES=$((TOTAL_LINES + del))
    done <<< "$NUMSTAT_OUT"

    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      if is_noise_file "$p"; then
        if [[ ${#NOISE_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${NOISE_ARR[@]}"; then NOISE_ARR+=("$p"); fi
        continue
      fi
      if [[ ${#REVIEW_ARR[@]} -eq 0 ]] || ! exact_in_list "$p" "${REVIEW_ARR[@]}"; then
        REVIEW_ARR+=("$p")
        if [[ -f "${REPO_ROOT}/${p}" ]] && ! is_binary_file "${REPO_ROOT}/${p}"; then
          lc="$(awk 'END{print NR}' "${REPO_ROOT}/${p}")"
          TOTAL_LINES=$((TOTAL_LINES + ${lc:-0}))
        fi
      fi
    done <<< "$UNTRACKED_OUT"

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
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$PREV_SHA" "$DELTA_END" -- || { echo "DIFF_SCOPE_FAIL: git diff --prev-sha failed: $(git_err_detail)"; exit 1; }
      DELTA_OUT="$_GIT_STDOUT"
      DELTA_ARR=()
      while IFS= read -r line; do
        p="$(norm_path "$line")"
        [[ -z "$p" ]] && continue
        is_checkpoint_dir "$p" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
        if is_noise_file "$p"; then continue; fi
        DELTA_ARR+=("$p")
      done <<< "$DELTA_OUT"
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "MECHANICAL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "MECHANICAL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      UN_OUT=""
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --name-only failed: $(git_err_detail)"; exit 1; }
      CH_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" diff --no-renames --diff-filter=d --name-only "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=d failed: $(git_err_detail)"; exit 1; }
      NONDEL_OUT="$_GIT_STDOUT"
      run_git_cmd "$REPO_ROOT" ls-files --others --exclude-standard || { echo "MECHANICAL_FAIL: git ls-files failed: $(git_err_detail)"; exit 1; }
      UN_OUT="$_GIT_STDOUT"
    fi

    ALL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      ALL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$CH_OUT" "$UN_OUT")

    NON_DEL_CHANGED=()
    while IFS= read -r line; do
      p="$(norm_path "$line")"
      [[ -z "$p" ]] && continue
      is_checkpoint_dir "$p" && continue
      if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$p" "${IGNORE_ARR[@]}"; then continue; fi
      NON_DEL_CHANGED+=("$p")
    done < <(printf '%s\n%s\n' "$NONDEL_OUT" "$UN_OUT")

    SCOPE_CREEP=()
    if [[ ${#ALLOWED_ARR[@]} -gt 0 && ${#ALL_CHANGED[@]} -gt 0 ]]; then
      for p in "${ALL_CHANGED[@]}"; do
        if ! path_in_list "$p" "${ALLOWED_ARR[@]}"; then
          SCOPE_CREEP+=("$p")
        fi
      done
    fi

    SAFETY_HITS=()
    if [[ ${#NON_DEL_CHANGED[@]} -gt 0 ]]; then
      for p in "${NON_DEL_CHANGED[@]}"; do
        if is_secret_path "$p"; then
          SAFETY_HITS+=("secret_path:${p}")
        fi
      done
    fi
    SQL_HIT_COUNT=0

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "MECHANICAL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
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
        if is_checkpoint_dir "$u" || is_md_file "$u"; then continue; fi
        is_noise_file "$u" && continue
        if [[ ${#IGNORE_ARR[@]} -gt 0 ]] && path_in_list "$u" "${IGNORE_ARR[@]}"; then continue; fi
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

    if [[ -n "$TARGET_REF" ]]; then
      DEL_TARGET="$TARGET_COMMIT_SHA"
    else
      build_working_tree_oid "$REPO_ROOT" "MECHANICAL_FAIL"
      DEL_TARGET="$_WT_TREE_OID"
    fi
    run_git_cmd "$REPO_ROOT" diff -M --diff-filter=D --name-only "$BASE_SHA" "$DEL_TARGET" -- || { echo "MECHANICAL_FAIL: git diff --diff-filter=D failed: $(git_err_detail)"; exit 1; }
    DEL_OUT="$_GIT_STDOUT"
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
            if run_git_cmd "$REPO_ROOT" cat-file -e "${TARGET_COMMIT_SHA}:${norm_tok}"; then
              exists_path=true
            fi
          elif [[ -e "${REPO_ROOT}/${norm_tok}" ]]; then
            exists_path=true
          fi
        fi
        if [[ -n "$TARGET_REF" ]]; then
          if run_git_cmd "$REPO_ROOT" grep -l -F -e "$tok" "$TARGET_COMMIT_SHA" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        else
          if run_git_cmd "$REPO_ROOT" grep --untracked -l -F -e "$tok" -- . ':(exclude).b3/ship' ':(exclude).b3/autodev'; then grep_code=0; else grep_code=$?; fi
        fi
        grep_out="$_GIT_STDOUT"
        if [[ "$grep_code" -gt 1 ]]; then
          echo "MECHANICAL_FAIL: git grep failed for obsolete '$tok': $(git_err_detail)"
          exit 1
        fi
        grep_count=0
        if [[ "$grep_code" -eq 0 && -n "$grep_out" ]]; then
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
          done <<< "$grep_out"
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

    DOT_B3_DIR="${REPO_ROOT%/}/.b3"
    SHIP_DIR="${DOT_B3_DIR}/ship"
    RUNS_DIR="${SHIP_DIR}/runs"
    if [[ -L "$DOT_B3_DIR" || -L "$SHIP_DIR" || -L "$RUNS_DIR" ]]; then
      echo "PRUNE_FAIL: runs directory is a link"
      exit 1
    fi
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

    mkdir -p "$(dirname "$FULL_RECEIPT")"

    OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/b3-verify-out.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/b3-verify-out.$$.${RANDOM}.tmp")"
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
    if ! REPO_ROOT="$(canon_repo_root "$REPO_ROOT")"; then
      _VR_MSG="VERIFY_CHECK_FAIL: invalid --repo-root"
      printf '%s\n' "$_VR_MSG"
      exit 1
    fi
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
      if ! run_git_cmd "$REPO_ROOT" rev-parse --verify --quiet "${TARGET_REF}^{commit}"; then
        echo "SYMBOL_FAIL: invalid --target-ref '$TARGET_REF'"
        exit 1
      fi
      TARGET_COMMIT_SHA="$(trim_str "$_GIT_STDOUT")"
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

    assert_valid_git_rev "$REPO_ROOT" "$BASE_SHA" "object" "SYMBOL_FAIL" "--base-sha"

    if [[ -n "$TARGET_REF" ]]; then
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" "$TARGET_COMMIT_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
      DIFF_U0="$_GIT_STDOUT"
    else
      run_git_cmd "$REPO_ROOT" diff --no-renames -U0 "$BASE_SHA" -- || { echo "SYMBOL_FAIL: git diff -U0 failed: $(git_err_detail)"; exit 1; }
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
    TOP_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse --show-toplevel; then
      TOP_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
    if [[ -z "$TOP_RAW" ]]; then
      echo "WORKTREE_UNSAFE: not_a_git_repo"
      exit 2
    fi
    HEAD_RAW=""
    if run_git_cmd "$REPO_ROOT" rev-parse HEAD; then
      HEAD_RAW="$(trim_str "$_GIT_STDOUT")"
    fi
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
      EXP_TOP_RAW=""
      if run_git_cmd "$EXPECTED_ROOT" rev-parse --show-toplevel; then
        EXP_TOP_RAW="$(trim_str "$_GIT_STDOUT")"
      fi
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

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
