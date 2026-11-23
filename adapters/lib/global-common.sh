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
  local d="$1" res
  res="$(cd "$d" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
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
    local win_p
    win_p="$(cygpath -w "$p")"
    if MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$win_p" >/dev/null 2>&1; then
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
    local win_d win_t
    win_d="$(cygpath -w "$dest")"
    win_t="$(cygpath -w "$target")"
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$win_d" "$win_t" >/dev/null || {
      echo "error: could not create junction $dest -> $target" >&2
      exit 1
    }
  else
    ln -s "$target" "$dest"
  fi
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
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -n "$raw" ]] || continue
    case "$raw" in
      schema=*) M_SCHEMA="${raw#schema=}"; continue ;;
      b3_home=*) M_B3_HOME="${raw#b3_home=}"; continue ;;
      plugin_root=*) M_PLUGIN_ROOT="${raw#plugin_root=}"; continue ;;
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
