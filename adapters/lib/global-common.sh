# Shared Bash primitives for B3 global host installers (Cursor & Antigravity).
# Bash 3.2+ compatible (macOS / Linux / Windows Git Bash).

IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

_B3_BASH_MAJOR="${BASH_VERSINFO[0]:-3}"
_B3_SHA_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
  _B3_SHA_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  _B3_SHA_TOOL="shasum"
elif command -v openssl >/dev/null 2>&1; then
  _B3_SHA_TOOL="openssl"
fi

trim_crlf() {
  printf '%s' "${1%$'\r'}"
}

to_upper() {
  if [[ $_B3_BASH_MAJOR -ge 4 ]]; then
    printf '%s' "${1^^}"
  else
    printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]'
  fi
}

upper_drive() {
  local p="${1//\\//}"
  if $IS_WINDOWS && [[ "$p" =~ ^([a-z]):(.*)$ ]]; then
    local d
    if [[ $_B3_BASH_MAJOR -ge 4 ]]; then
      d="${BASH_REMATCH[1]^^}"
    else
      d="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    fi
    p="${d}:${BASH_REMATCH[2]}"
  fi
  printf '%s' "$p"
}

canon_existing_dir() {
  [[ -n "${1:-}" ]] || return 1
  local d="$1" res
  [[ -n "${d//[[:space:]]/}" ]] || return 1
  res="$(cd -- "$d" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  if [[ "$res" != "/" && ! "$res" =~ ^[A-Za-z]:$ && ! "$res" =~ ^[A-Za-z]:/$ ]]; then
    res="${res%/}"
  fi
  upper_drive "$res"
}

canon_path_allow_missing() {
  local p
  p="$(upper_drive "$1")"
  while [[ "$p" == */ && "$p" != "/" && ! "$p" =~ ^[A-Za-z]:/$ ]]; do
    p="${p%/}"
  done
  if [[ -L "$p" ]]; then
    local base parent resolved
    base="$(basename "$p")"
    parent="$(dirname "$p")"
    if [[ -d "$parent" ]]; then
      resolved="$(canon_existing_dir "$parent")"
      resolved="${resolved%/}"
      printf '%s/%s' "$resolved" "$base"
    else
      printf '%s' "$p"
    fi
    return
  fi
  if [[ -d "$p" ]]; then
    canon_existing_dir "$p"
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
    resolved="$(canon_existing_dir "$cur")"
    resolved="${resolved%/}"
    if [[ -n "$suffix" ]]; then printf '%s/%s' "$resolved" "$suffix"; else printf '%s' "$resolved"; fi
  else
    printf '%s' "$p"
  fi
}

norm_cmp_path() {
  local p="${1//\\//}"
  p="${p%/}"
  if $IS_WINDOWS; then
    if [[ $_B3_BASH_MAJOR -ge 4 ]]; then
      printf '%s' "${p,,}"
    else
      printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]'
    fi
  else
    printf '%s' "$p"
  fi
}

_extract_sha_lower() {
  local raw="$1" hex
  if [[ "$_B3_SHA_TOOL" == "openssl" ]]; then
    hex="${raw##* }"
  else
    hex="${raw%% *}"
  fi
  if [[ $_B3_BASH_MAJOR -ge 4 ]]; then
    printf '%s' "${hex,,}"
  else
    printf '%s' "$hex" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  fi
}

sha256_file() {
  local out
  case "$_B3_SHA_TOOL" in
    sha256sum) out="$(sha256sum "$1")" ;;
    shasum)    out="$(shasum -a 256 "$1")" ;;
    openssl)   out="$(openssl dgst -sha256 "$1")" ;;
    *) echo "error: missing sha256 utility (sha256sum/shasum/openssl)" >&2; return 1 ;;
  esac
  _extract_sha_lower "$out"
}

sha256_text() {
  local clean="${1//$'\r'/}" out
  case "$_B3_SHA_TOOL" in
    sha256sum) out="$(printf '%s' "$clean" | sha256sum)" ;;
    shasum)    out="$(printf '%s' "$clean" | shasum -a 256)" ;;
    openssl)   out="$(printf '%s' "$clean" | openssl dgst -sha256)" ;;
    *) echo "error: missing sha256 utility (sha256sum/shasum/openssl)" >&2; return 1 ;;
  esac
  _extract_sha_lower "$out"
}

write_lf_file() {
  local dest="$1" content="$2" parent
  if [[ "$dest" == */* ]]; then parent="${dest%/*}"; else parent="."; fi
  mkdir -p "${parent:-/}"
  local tmp="${dest}.tmp.$$.${RANDOM}"
  printf '%s' "${content//$'\r'/}" > "$tmp"
  mv -f "$tmp" "$dest"
}

install_file_atomic() {
  local src="$1" dest="$2" parent
  if [[ "$dest" == */* ]]; then parent="${dest%/*}"; else parent="."; fi
  mkdir -p "${parent:-/}"
  local tmp="${dest}.tmp.$$.${RANDOM}"
  cp "$src" "$tmp"
  mv -f "$tmp" "$dest"
}

_win_ps_exe() {
  if command -v powershell.exe >/dev/null 2>&1; then
    command -v powershell.exe
  elif command -v pwsh >/dev/null 2>&1; then
    command -v pwsh
  elif [[ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
    printf '%s\n' "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  else
    echo "error: PowerShell (powershell.exe or pwsh) not found on PATH" >&2
    return 1
  fi
}

is_link_entry() {
  [[ -L "$1" ]]
}

remove_link_only() {
  local p="$1"
  if ! is_link_entry "$p"; then
    echo "error: refusing to remove non-link entry: $p" >&2
    exit 1
  fi
  if $IS_WINDOWS && [[ -d "$p" || ! -e "$p" ]]; then
    local win_p ps_exe
    win_p="$(cygpath -w "$p")"
    ps_exe="$(_win_ps_exe)"
    if B3_WIN_PATH="$win_p" "$ps_exe" -NoProfile -NonInteractive -Command '[System.IO.Directory]::Delete($env:B3_WIN_PATH, $false)' >/dev/null 2>&1; then
      return 0
    fi
  fi
  rm -f "$p"
}

create_dir_link() {
  local dest="$1" target="$2" parent
  if [[ "$dest" == */* ]]; then parent="${dest%/*}"; else parent="."; fi
  mkdir -p "${parent:-/}"
  if $IS_WINDOWS; then
    local win_d win_t ps_exe
    win_d="$(cygpath -w "$dest")"
    win_t="$(cygpath -w "$target")"
    ps_exe="$(_win_ps_exe)"
    B3_WIN_DEST="$win_d" B3_WIN_TARGET="$win_t" "$ps_exe" -NoProfile -NonInteractive -Command 'New-Item -ItemType Junction -Path $env:B3_WIN_DEST -Target $env:B3_WIN_TARGET | Out-Null' >/dev/null || {
      echo "error: could not create junction $dest -> $target" >&2
      exit 1
    }
  else
    ln -s "$target" "$dest"
  fi
}

remove_dir_tree_safely() {
  local dir="$1" entry
  while [[ "$dir" == */ && "$dir" != "/" ]]; do
    dir="${dir%/}"
  done
  if [[ -z "$dir" || "$dir" == "/" ]]; then
    echo "error: refusing unsafe recursive delete path: '$dir'" >&2
    exit 1
  fi
  if is_link_entry "$dir"; then
    echo "error: refusing recursive delete of link path: $dir" >&2
    exit 1
  fi
  if [[ ! -e "$dir" ]]; then
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    rm -f "$dir"
    return 0
  fi
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    if is_link_entry "$entry"; then
      remove_link_only "$entry"
    elif [[ -d "$entry" ]]; then
      remove_dir_tree_safely "$entry"
    else
      rm -f "$entry"
    fi
  done
  rmdir "$dir"
}

link_target_ok() {
  local dest="$1" expected="$2"
  [[ -L "$dest" && -d "$dest" ]] || return 1
  local rd rd_norm exp_norm
  rd="$(cd -P "$dest" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  [[ -n "$rd" ]] || return 1
  rd_norm="$(norm_cmp_path "$rd")"
  exp_norm="$(norm_cmp_path "$expected")"
  [[ "$rd_norm" == "$exp_norm" ]] && return 0
  local re
  re="$(cd -P "$expected" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  [[ "$rd_norm" == "$(norm_cmp_path "$re")" ]]
}

link_matches_expected_or_dangling() {
  local dest="$1" expected="$2"
  is_link_entry "$dest" || return 1
  if [[ -d "$dest" ]]; then
    link_target_ok "$dest" "$expected"
    return $?
  fi
  local rl
  rl="$(readlink "$dest" 2>/dev/null)" || return 1
  if $IS_WINDOWS && command -v cygpath >/dev/null 2>&1; then
    rl="$(cygpath -m "$rl" 2>/dev/null || printf '%s' "$rl")"
  elif [[ "$rl" != /* && ! "$rl" =~ ^[A-Za-z]: ]]; then
    local parent
    parent="$(canon_path_allow_missing "$(dirname "$dest")")"
    rl="${parent%/}/${rl}"
  fi
  local exp_norm rl_norm
  exp_norm="$(canon_path_allow_missing "$expected")"
  rl_norm="$(canon_path_allow_missing "$rl")"
  [[ "$(norm_cmp_path "$rl_norm")" == "$(norm_cmp_path "$exp_norm")" ]]
}

discover_skills_tsv() {
  local root_dir="$1"
  local root_canon
  root_canon="$(canon_existing_dir "$root_dir")" || return 1
  find "$root_canon" -name 'SKILL.md' -type f | LC_ALL=C sort | awk '
    {
      sub(/\r$/, "")
      sf = $0
      if (sf == "") next
      dir = sf
      sub(/\/SKILL\.md$/, "", dir)
      name = ""
      in_fm = 0
      line_no = 0
      while ((getline line < sf) > 0) {
        sub(/\r$/, "", line)
        line_no++
        if (line_no == 1) {
          if (line == "---") { in_fm = 1; continue }
          else break
        }
        if (in_fm && line == "---") break
        if (in_fm && line ~ /^[[:space:]]*name:[[:space:]]*[a-z0-9-]+[[:space:]]*$/) {
          sub(/^[[:space:]]*name:[[:space:]]*/, "", line)
          gsub(/[[:space:]]+$/, "", line)
          name = line
          break
        }
      }
      close(sf)
      if (name == "") {
        n = split(dir, parts, "/")
        name = parts[n]
      }
      printf "%s\t%s\n", name, dir
    }
  '
}

array_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

M_EXISTS=false
M_CORRUPT=false
M_SCHEMA=""
M_B3_HOME=""
M_PLUGIN_ROOT=""
M_KINDS=()
M_KEYS=()
M_VALS=()

is_safe_manifest_key() {
  local kind="$1" key="$2" seg0 seg1
  [[ -n "$key" ]] || return 1
  case "$key" in
    /*|*/|*//*|*'\'*|*:*|~*|' '*|*' '|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  [[ "$key" =~ [[:cntrl:]] ]] && return 1
  if [[ "$key" == */* ]]; then
    seg0="${key%%/*}"
    seg1="${key#*/}"
    [[ "$seg1" != */* ]] || return 1
    [[ -n "$seg0" && -n "$seg1" && "$seg0" != "." && "$seg0" != ".." && "$seg1" != "." && "$seg1" != ".." ]] || return 1
    case "$kind" in
      link) [[ "$seg0" == "skills" ]] ;;
      file) [[ "$seg0" == "rules" || "$seg0" == "agents" ]] ;;
      *) return 1 ;;
    esac
  else
    [[ "$key" != "." && "$key" != ".." ]] || return 1
    case "$kind" in
      skill|command|agent|file) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

path_within_root() {
  local root_dir="$1" cand="$2" leaf root_norm cand_parent parent_norm
  [[ -n "$root_dir" && -n "$cand" ]] || return 1
  case "$cand" in
    *'\'*|*/../*|*/./*|*/..|*/.|*//*) return 1 ;;
  esac
  [[ "$cand" == */* ]] || return 1
  leaf="${cand##*/}"
  [[ -n "$leaf" && "$leaf" != "." && "$leaf" != ".." ]] || return 1
  cand_parent="${cand%/*}"
  root_norm="$(norm_cmp_path "$(canon_path_allow_missing "$root_dir")")"
  parent_norm="$(norm_cmp_path "$(canon_path_allow_missing "$cand_parent")")"
  [[ -n "$root_norm" && -n "$parent_norm" ]] || return 1
  [[ "$parent_norm" == "$root_norm" || "$parent_norm" == "${root_norm}/"* ]]
}

_is_clean_nonempty_val() {
  local val="$1"
  [[ -n "$val" ]] || return 1
  [[ "$val" != ' '* && "$val" != *' ' && "$val" != $'\t'* && "$val" != *$'\t' ]] || return 1
  [[ "$val" =~ [[:cntrl:]] ]] && return 1
  return 0
}

is_safe_header_path() {
  local val="$1"
  local LC_ALL=C
  _is_clean_nonempty_val "$val" || return 1
  local re_dotdot='(^|[/\\])\.\.([/\\]|$)'
  local re_posix='^/'
  local re_win='^[A-Za-z]:[/\\]'
  [[ "$val" =~ $re_dotdot ]] && return 1
  [[ "$val" =~ $re_posix || "$val" =~ $re_win ]]
}

is_safe_manifest_value() {
  local kind="$1" val="$2"
  local LC_ALL=C
  _is_clean_nonempty_val "$val" || return 1
  case "$kind" in
    command|agent|file)
      local re_sha='^[0-9a-f]{64}$'
      [[ "$val" =~ $re_sha ]]
      ;;
    skill|link)
      [[ "$val" != *"|"* ]] || return 1
      local re_dotdot='(^|[/\\])\.\.([/\\]|$)'
      local re_posix='^/'
      local re_win='^[A-Za-z]:[/\\]'
      [[ "$val" =~ $re_dotdot ]] && return 1
      [[ "$val" =~ $re_posix || "$val" =~ $re_win ]]
      ;;
    *)
      return 1
      ;;
  esac
}

manifest_load() {
  local mfile="$1"
  M_EXISTS=false
  M_CORRUPT=false
  M_SCHEMA=""
  M_B3_HOME=""
  M_PLUGIN_ROOT=""
  M_KINDS=()
  M_KEYS=()
  M_VALS=()
  [[ -f "$mfile" ]] || return 0
  M_EXISTS=true
  local raw k v1 v2
  local seen_schema=false seen_b3_home=false seen_plugin_root=false
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -n "$raw" ]] || continue
    case "$raw" in
      schema=*)
        if $seen_schema; then M_CORRUPT=true; continue; fi
        seen_schema=true
        v1="${raw#schema=}"
        if ! _is_clean_nonempty_val "$v1"; then M_CORRUPT=true; continue; fi
        M_SCHEMA="$v1"
        continue ;;
      b3_home=*)
        if $seen_b3_home; then M_CORRUPT=true; continue; fi
        seen_b3_home=true
        v1="${raw#b3_home=}"
        if ! is_safe_header_path "$v1"; then M_CORRUPT=true; continue; fi
        M_B3_HOME="$v1"
        continue ;;
      plugin_root=*)
        if $seen_plugin_root; then M_CORRUPT=true; continue; fi
        seen_plugin_root=true
        v1="${raw#plugin_root=}"
        if ! is_safe_header_path "$v1"; then M_CORRUPT=true; continue; fi
        M_PLUGIN_ROOT="$v1"
        continue ;;
    esac
    if [[ "$raw" != *"|"* ]]; then
      M_CORRUPT=true
      continue
    fi
    k="${raw%%|*}"
    v1="${raw#*|}"
    if [[ "$v1" != *"|"* ]]; then
      M_CORRUPT=true
      continue
    fi
    v2="${v1#*|}"
    v1="${v1%%|*}"
    case "$k" in
      skill|command|agent|file|link)
        if ! is_safe_manifest_key "$k" "$v1"; then
          M_CORRUPT=true
          continue
        fi
        if manifest_has "$k" "$v1"; then
          M_CORRUPT=true
          continue
        fi
        if ! is_safe_manifest_value "$k" "$v2"; then
          M_CORRUPT=true
          continue
        fi
        M_KINDS+=("$k"); M_KEYS+=("$v1"); M_VALS+=("$v2") ;;
      *)
        M_CORRUPT=true ;;
    esac
  done < "$mfile"
}

manifest_get() {
  local want_kind="$1" want_key="$2" i
  if [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      if [[ "${M_KINDS[$i]}" == "$want_kind" && "${M_KEYS[$i]}" == "$want_key" ]]; then
        printf '%s' "${M_VALS[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

manifest_has() {
  local want_kind="$1" want_key="$2" i
  if [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      if [[ "${M_KINDS[$i]}" == "$want_kind" && "${M_KEYS[$i]}" == "$want_key" ]]; then
        return 0
      fi
    done
  fi
  return 1
}

assert_regular_dir_or_missing() {
  local d="$1" label="${2:-}"
  if [[ -e "$d" || -L "$d" ]]; then
    if is_link_entry "$d"; then
      if [[ -n "$label" ]]; then
        echo "error: refusing to traverse link directory ${label}: $d" >&2
      else
        echo "error: refusing to traverse link directory: $d" >&2
      fi
      exit 1
    fi
    if [[ ! -d "$d" ]]; then
      if [[ -n "$label" ]]; then
        echo "error: existing non-directory path blocks ${label}: $d" >&2
      else
        echo "error: existing non-directory path blocks directory: $d" >&2
      fi
      exit 1
    fi
  fi
}

assert_regular_file_or_missing() {
  local f="$1" label="${2:-$1}"
  if is_link_entry "$f"; then
    echo "error: existing link blocks ${label}: $f" >&2
    exit 1
  fi
  if [[ -e "$f" && ! -f "$f" ]]; then
    echo "error: existing non-file path blocks ${label}: $f" >&2
    exit 1
  fi
}

count_skill_overlaps() {
  local root_dir="$1"
  shift
  OVERLAP_COUNT=0
  OVERLAP_FIRST=""
  [[ -d "$root_dir" ]] || return 0
  local sn
  for sn in "$@"; do
    if [[ -e "${root_dir}/${sn}" || -L "${root_dir}/${sn}" ]]; then
      [[ -z "$OVERLAP_FIRST" ]] && OVERLAP_FIRST="$sn"
      OVERLAP_COUNT=$((OVERLAP_COUNT + 1))
    fi
  done
}

init_personal_models_file() {
  local b3_home="$1"
  local user_home="${2:-}"
  local dry_run="${3:-false}"
  local non_fatal="${4:-false}"

  if [[ "${B3_SKIP_MODEL_INIT:-}" == "1" ]]; then
    printf '%s\n' "skipped"
    return 0
  fi
  local template_md="${b3_home}/config/models.example.md"
  if [[ ! -f "$template_md" ]]; then
    printf '%s\n' "no-template"
    return 0
  fi
  local dest="${B3_MODELS_PERSONAL:-}"
  dest="${dest#"${dest%%[![:space:]]*}"}"
  dest="${dest%"${dest##*[![:space:]]}"}"
  if [[ -z "$dest" ]]; then
    dest="${user_home:-$HOME}/.b3/models.md"
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    printf 'kept:%s\n' "$dest"
    return 0
  fi
  if [[ "$dry_run" == "true" ]]; then
    printf 'dry-run:%s\n' "$dest"
    return 0
  fi
  if (mkdir -p "$(dirname "$dest")" && umask 077 && set -C && cat "$template_md" > "$dest") 2>/dev/null; then
    printf 'created:%s\n' "$dest"
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    printf 'kept:%s\n' "$dest"
    return 0
  fi
  if [[ "$non_fatal" == "true" ]]; then
    echo "MODEL_PREFERENCES_WARNING: optional initialization failed at $dest" >&2
    printf 'error:%s\n' "$dest"
    return 0
  fi
  echo "error: could not initialize personal model preferences at $dest" >&2
  return 1
}

resolve_user_home() {
  local h="${1:-}"
  if [[ -z "$h" ]]; then h="$HOME"; fi
  canon_path_allow_missing "$h"
}

resolve_b3_home() {
  local b3="${1:-}" def="${2:-}"
  if [[ -z "$b3" ]]; then b3="$def"; fi
  [[ -d "$b3" ]] || { echo "error: B3Home directory not found: $b3" >&2; exit 1; }
  canon_existing_dir "$b3"
}

list_canonical_md_names() {
  local dir="$1" f base
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    base="${f##*/}"
    [[ "$base" == "README.md" ]] && continue
    printf '%s\n' "$base"
  done < <(find "$dir" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
}

strip_yaml_frontmatter() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0; started = 0; next }
    in_fm { next }
    !started && $0 == "" { next }
    { started = 1; lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] == "") n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$1"
}

manifest_write() {
  local mpath="$1" schema="$2" b3_home="$3" plugin_root="${4:-}" entries="${5:-}" body
  body="schema=${schema}"$'\n'"b3_home=${b3_home}"$'\n'
  if [[ -n "$plugin_root" ]]; then
    body="${body}plugin_root=${plugin_root}"$'\n'
  fi
  body="${body}${entries}"
  write_lf_file "$mpath" "$body"
}

uninstall_managed_link() {
  local root_dir="$1" root_label="$2" p="$3" exp_target="${4:-}" verify_expected="${5:-true}" force="${6:-false}" dry_run="${7:-false}" unmanaged_label="${8:-unmanaged non-link entry}"
  path_within_root "$root_dir" "$p" || { echo "error: refusing to uninstall path outside ${root_label}: $p" >&2; exit 1; }
  if is_link_entry "$p"; then
    if [[ "$verify_expected" == "true" && "$force" != "true" ]]; then
      if [[ -z "$exp_target" ]] || ! link_matches_expected_or_dangling "$p" "$exp_target"; then
        echo "warning: skipping retargeted skill link: $p (expected $exp_target; re-run with --force to remove)" >&2
        SKIPPED=$((SKIPPED + 1))
        return 0
      fi
    fi
    if [[ "$dry_run" == "true" ]]; then echo "dry-run: remove skill link $p"; else remove_link_only "$p"; fi
    REMOVED=$((REMOVED + 1))
  elif [[ -e "$p" ]]; then
    echo "warning: skipping ${unmanaged_label}: $p" >&2
  fi
}

_B3_WARNED_CONTAINERS=""
uninstall_managed_file() {
  local root_dir="$1" root_label="$2" p="$3" exp_sha="${4:-}" verify_sha="${5:-true}" marker_re="${6:-}" label="${7:-file}" sha_label="${8:-modified managed file}" check_parent="${9:-false}" force="${10:-false}" dry_run="${11:-false}"
  path_within_root "$root_dir" "$p" || { echo "error: refusing to uninstall path outside ${root_label}: $p" >&2; exit 1; }
  if [[ "$check_parent" == "true" ]]; then
    local p_parent="${p%/*}"
    if [[ "$(norm_cmp_path "$p_parent")" != "$(norm_cmp_path "$root_dir")" ]] && is_link_entry "$p_parent"; then
      case "$'\n'${_B3_WARNED_CONTAINERS}$'\n'" in
        *$'\n'"$p_parent"$'\n'*) ;;
        *)
          echo "warning: skipping symlinked container directory: $p_parent" >&2
          _B3_WARNED_CONTAINERS="${_B3_WARNED_CONTAINERS}"$'\n'"${p_parent}"
          ;;
      esac
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  fi
  if is_link_entry "$p"; then
    echo "warning: skipping symlinked ${label}: $p" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  [[ -f "$p" ]] || return 0
  if [[ -n "$marker_re" ]] && ! grep -q "$marker_re" "$p"; then
    echo "warning: skipping unmanaged ${label}: $p" >&2
    return 0
  fi
  if [[ "$verify_sha" == "true" && "$force" != "true" ]] && { [[ -z "$exp_sha" ]] || [[ "$(sha256_file "$p")" != "$exp_sha" ]]; }; then
    echo "warning: skipping ${sha_label}: $p (re-run with --force to remove)" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if [[ "$dry_run" == "true" ]]; then echo "dry-run: remove $p"; else rm -f "$p"; fi
  REMOVED=$((REMOVED + 1))
}

print_personal_models_status() {
  local b3_home="$1" status="$2" emit_error="${3:-false}"
  case "$status" in
    kept:*) echo "model_preferences=${status#kept:} (kept existing)" ;;
    dry-run:*) echo "dry-run: initialize model_preferences=${status#dry-run:} from ${b3_home}/config/models.example.md" ;;
    created:*) echo "model_preferences=${status#created:} (created from example)" ;;
    error:*) [[ "$emit_error" == "true" ]] && echo "model_preferences=${status}" || true ;;
  esac
}

