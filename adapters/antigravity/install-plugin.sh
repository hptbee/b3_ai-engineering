#!/usr/bin/env bash
# Global Antigravity plugin lifecycle manager for B3 AI Engineering (macOS / Linux / Git Bash).
# Installs, updates, verifies, or uninstalls the canonical B3 plugin bundle under ~/.gemini/config/plugins/b3-ai-engineering.
# Usage: ./adapters/antigravity/install-plugin.sh [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]
set -euo pipefail

ACTION="install"
ACTION_SET=false
PLUGIN_ROOT=""
B3_HOME=""
USER_HOME=""
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|verify|uninstall)
      if $ACTION_SET; then
        echo "error: duplicate action '$1'" >&2; exit 1
      fi
      ACTION="$1"; ACTION_SET=true; shift ;;
    --action)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      if $ACTION_SET; then
        echo "error: duplicate action '$2'" >&2; exit 1
      fi
      case "$2" in
        install|update|verify|uninstall) ACTION="$2"; ACTION_SET=true ;;
        *) echo "error: invalid action '$2'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --plugin-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      PLUGIN_ROOT="$2"; shift 2 ;;
    --b3-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      B3_HOME="$2"; shift 2 ;;
    --user-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      USER_HOME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--plugin-root PATH] [--b3-home PATH] [--user-home PATH] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

trim_crlf() {
  printf '%s' "$1" | LC_ALL=C tr -d '\r'
}

upper_drive() {
  local p="${1//\\//}"
  if $IS_WINDOWS && [[ "$p" =~ ^([a-z]):(.*)$ ]]; then
    local d
    d="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    p="${d}:${BASH_REMATCH[2]}"
  fi
  printf '%s' "$p"
}

canon_existing_dir() {
  local d="$1"
  local res
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
    printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]'
  else
    printf '%s' "$p"
  fi
}

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print tolower($NF)}'
  else
    echo "error: missing sha256 utility (sha256sum/shasum/openssl)" >&2
    return 1
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C tr -d '\r' | sha256sum | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C tr -d '\r' | shasum -a 256 | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C tr -d '\r' | openssl dgst -sha256 | awk '{print tolower($NF)}'
  else
    echo "error: missing sha256 utility (sha256sum/shasum/openssl)" >&2
    return 1
  fi
}

write_lf_file() {
  local dest="$1" content="$2"
  mkdir -p "$(dirname "$dest")"
  local tmp="${dest}.tmp.$$.${RANDOM}"
  printf '%s' "$content" | LC_ALL=C tr -d '\r' > "$tmp"
  mv -f "$tmp" "$dest"
}

is_link_entry() {
  [[ -L "$1" ]]
}

remove_link_only() {
  local p="$1"
  if ! is_link_entry "$p"; then
    echo "error: refusing to remove non-link entry without --force: $p" >&2
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
  local dest="$1" target="$2"
  mkdir -p "$(dirname "$dest")"
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
  local rd re
  rd="$(cd -P "$dest" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  re="$(cd -P "$expected" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  [[ -n "$rd" && "$(norm_cmp_path "$rd")" == "$(norm_cmp_path "$re")" ]]
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

skill_name_from_file() {
  local f="$1" name
  name="$(awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $0 ~ /^[[:space:]]*name:[[:space:]]*[a-z0-9-]+[[:space:]]*$/ {
      sub(/^[[:space:]]*name:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$f")"
  if [[ -n "$name" ]]; then printf '%s' "$name"; else basename "$(dirname "$f")"; fi
}

strip_frontmatter() {
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

render_agent() {
  local file="$1" b3_home="$2" base
  base="$(basename "$file")"
  awk -v file_path="$file" -v b3_home="$b3_home" -v base="$base" '
    BEGIN { in_fm = 0; done_fm = 0; cur = ""; desc_n = 0; body_n = 0; readonly_val = ""; name_val = "" }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") { print "error: agent missing YAML frontmatter: " file_path > "/dev/stderr"; exit 2 }
      in_fm = 1; next
    }
    in_fm && $0 == "---" { in_fm = 0; done_fm = 1; next }
    in_fm {
      if ($0 ~ /^[a-zA-Z0-9_-]+:[[:space:]]*/) {
        split($0, parts, ":")
        cur = parts[1]
        val = substr($0, length(cur) + 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (cur == "name") name_val = val
        else if (cur == "readonly") readonly_val = tolower(val)
        else if (cur == "description") desc[++desc_n] = $0
      } else if (cur == "description" && ($0 ~ /^[[:space:]]+[^[:space:]]/ || $0 ~ /^[[:space:]]*$/)) {
        desc[++desc_n] = $0
      }
      next
    }
    done_fm {
      if (body_n == 0 && $0 == "") next
      body[++body_n] = $0
    }
    END {
      if (!done_fm) { print "error: agent frontmatter not closed: " file_path > "/dev/stderr"; exit 2 }
      while (desc_n > 0 && desc[desc_n] ~ /^[[:space:]]*$/) desc_n--
      while (body_n > 0 && body[body_n] ~ /^[[:space:]]*$/) body_n--
      if (name_val == "") { print "error: agent missing name in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      if (desc_n == 0) { print "error: agent missing description in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      if (readonly_val != "true" && readonly_val != "false") { print "error: agent missing boolean readonly in frontmatter: " file_path > "/dev/stderr"; exit 2 }
      tools = (readonly_val == "true") ? "tools: [read_file]" : "tools: [read_file, edit_file, write_file, run_command, manage_task]"
      print "---"
      print "name: " name_val
      for (i = 1; i <= desc_n; i++) print desc[i]
      print "subagent: true"
      print "mainAgent: false"
      print tools
      print "---"
      print ""
      print "<!-- Generated from " b3_home "/agents/" base " - do not edit here -->"
      if (body_n > 0) {
        print ""
        for (i = 1; i <= body_n; i++) print body[i]
      }
    }
  ' "$file"
}

is_b3_plugin_json() {
  local pj="$1"
  [[ -f "$pj" ]] || return 1
  awk '
    BEGIN { bad = 0; seen_name = 0; txt = "" }
    {
      gsub(/\r/, "")
      txt = txt $0 "\n"
      rest = $0
      while (match(rest, /"[^"]*"[[:space:]]*:/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^"/, "", tok)
        sub(/"[[:space:]]*:$/, "", tok)
        if (tok == "name") seen_name = 1
        if (tok != "name" && tok != "displayName" && tok != "version" && tok != "description" && tok != "suggestedPrompts") {
          bad = 1
        }
      }
    }
    END {
      if (bad || !seen_name) exit 1
      if (txt !~ /^[[:space:]]*\{/) exit 1
      if (txt !~ /\}[[:space:]]*$/) exit 1
      if (txt !~ /"name"[[:space:]]*:[[:space:]]*"b3-ai-engineering"/) exit 1
    }
  ' "$pj"
}

has_b3_plugin_name_json() {
  local pj="$1"
  [[ -f "$pj" ]] || return 1
  grep -qE '"name"[[:space:]]*:[[:space:]]*"b3-ai-engineering"' "$pj"
}

check_coexistence() {
  local user_home="$1" plugin_root="$2"
  shift 2
  local skill_names=("$@")
  local plugin_norm
  plugin_norm="$(norm_cmp_path "$plugin_root")"

  local loose_dir="${user_home}/.gemini/config/skills"
  if [[ -d "$loose_dir" ]]; then
    local overlap=0 first="" sn
    for sn in "${skill_names[@]}"; do
      if [[ -e "${loose_dir}/${sn}" || -L "${loose_dir}/${sn}" ]]; then
        [[ -z "$first" ]] && first="$sn"
        overlap=$((overlap + 1))
      fi
    done
    if [[ $overlap -gt 0 ]]; then
      echo "COEXISTENCE_WARNING: ~/.gemini/config/skills contains ${overlap} overlapping B3 skill(s) (${first}...); remove loose copies to prevent duplicate discovery."
    fi
  fi

  local plugins_dir="${user_home}/.gemini/config/plugins"
  if [[ -d "$plugins_dir" ]]; then
    local cand cand_existing cand_norm
    for cand in "${plugins_dir}"/*; do
      [[ -d "$cand" ]] || continue
      if ! cand_existing="$(canon_existing_dir "$cand")"; then continue; fi
      cand_norm="$(norm_cmp_path "$cand_existing")"
      [[ "$cand_norm" == "$plugin_norm" ]] && continue
      if has_b3_plugin_name_json "${cand}/plugin.json"; then
        echo "COEXISTENCE_WARNING: duplicate b3-ai-engineering plugin found at ${cand}; only one plugin directory with name 'b3-ai-engineering' should exist."
      fi
    done
  fi

  local global_agents="${user_home}/.agents/skills"
  if [[ -d "$global_agents" ]]; then
    local ag_overlap=0 sn
    for sn in "${skill_names[@]}"; do
      if [[ -e "${global_agents}/${sn}" || -L "${global_agents}/${sn}" ]]; then
        ag_overlap=$((ag_overlap + 1))
      fi
    done
    if [[ $ag_overlap -gt 0 ]]; then
      echo "COEXISTENCE_WARNING: ~/.agents/skills contains ${ag_overlap} overlapping B3 skill(s); global Antigravity discovery may duplicate bundled plugin skills."
    fi
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$USER_HOME" ]]; then USER_HOME="$HOME"; fi
USER_HOME="$(canon_path_allow_missing "$USER_HOME")"

if [[ -z "$PLUGIN_ROOT" ]]; then
  PLUGIN_ROOT="${USER_HOME}/.gemini/config/plugins/b3-ai-engineering"
fi
PLUGIN_ROOT="$(canon_path_allow_missing "$PLUGIN_ROOT")"
MANIFEST_FILE="${PLUGIN_ROOT}/.b3-plugin-manifest"

M_EXISTS=false
M_SCHEMA=""
M_B3_HOME=""
M_PLUGIN_ROOT=""
M_FILE_KEYS=()
M_FILE_SHAS=()
M_LINK_KEYS=()
M_LINK_TARGETS=()

load_manifest() {
  M_EXISTS=false
  M_SCHEMA=""
  M_B3_HOME=""
  M_PLUGIN_ROOT=""
  M_FILE_KEYS=()
  M_FILE_SHAS=()
  M_LINK_KEYS=()
  M_LINK_TARGETS=()
  [[ -f "$MANIFEST_FILE" ]] || return 0
  M_EXISTS=true
  local raw k v1 v2
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="$(trim_crlf "$raw")"
    [[ -n "$raw" ]] || continue
    case "$raw" in
      schema=*) M_SCHEMA="${raw#schema=}"; continue ;;
      b3_home=*) M_B3_HOME="${raw#b3_home=}"; continue ;;
      plugin_root=*) M_PLUGIN_ROOT="${raw#plugin_root=}"; continue ;;
    esac
    k="${raw%%|*}"
    v1="${raw#*|}"
    v2="${v1#*|}"
    v1="${v1%%|*}"
    if [[ "$k" == "file" ]]; then M_FILE_KEYS+=("$v1"); M_FILE_SHAS+=("$v2")
    elif [[ "$k" == "link" ]]; then M_LINK_KEYS+=("$v1"); M_LINK_TARGETS+=("$v2")
    fi
  done < "$MANIFEST_FILE"
}

manifest_file_sha() {
  local target="$1" i
  if [[ ${#M_FILE_KEYS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_FILE_KEYS[@]}; i++)); do
      if [[ "${M_FILE_KEYS[$i]}" == "$target" ]]; then
        printf '%s' "${M_FILE_SHAS[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

manifest_link_target() {
  local target="$1" i
  if [[ ${#M_LINK_KEYS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_LINK_KEYS[@]}; i++)); do
      if [[ "${M_LINK_KEYS[$i]}" == "$target" ]]; then
        printf '%s' "${M_LINK_TARGETS[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

# --- Uninstall action ---
if [[ "$ACTION" == "uninstall" ]]; then
  if is_link_entry "$PLUGIN_ROOT"; then
    echo "error: refusing to uninstall link-based PluginRoot: $PLUGIN_ROOT" >&2
    exit 1
  fi
  load_manifest
  HAS_PJ=false
  is_b3_plugin_json "${PLUGIN_ROOT}/plugin.json" && HAS_PJ=true
  if ! $M_EXISTS && ! $HAS_PJ; then
    if [[ -e "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
      echo "error: refusing to uninstall unrecognized directory (missing B3 manifest or plugin.json): $PLUGIN_ROOT" >&2
      exit 1
    fi
    echo "nothing installed (no B3 plugin at $PLUGIN_ROOT)"
    exit 0
  fi

  TRACKED_FILES=()
  TRACKED_LINKS=()
  if $M_EXISTS; then
    [[ ${#M_FILE_KEYS[@]} -gt 0 ]] && TRACKED_FILES=("${M_FILE_KEYS[@]}")
    [[ ${#M_LINK_KEYS[@]} -gt 0 ]] && TRACKED_LINKS=("${M_LINK_KEYS[@]}")
  else
    [[ -f "${PLUGIN_ROOT}/plugin.json" ]] && TRACKED_FILES+=("plugin.json")
    if [[ -f "${PLUGIN_ROOT}/rules/AGENTS.md" ]] && grep -q 'Generated from B3_HOME:' "${PLUGIN_ROOT}/rules/AGENTS.md"; then
      TRACKED_FILES+=("rules/AGENTS.md")
    fi
    if [[ -d "${PLUGIN_ROOT}/agents" ]] && ! is_link_entry "${PLUGIN_ROOT}/agents"; then
      for af in "${PLUGIN_ROOT}/agents"/*.md; do
        [[ -f "$af" ]] || continue
        if grep -Eq '<!-- Generated from .*/(\.cursor/)?agents/' "$af"; then
          TRACKED_FILES+=("agents/$(basename "$af")")
        fi
      done
    fi
    if [[ -d "${PLUGIN_ROOT}/skills" ]] && ! is_link_entry "${PLUGIN_ROOT}/skills"; then
      for sk in "${PLUGIN_ROOT}/skills"/*; do
        [[ -e "$sk" || -L "$sk" ]] || continue
        is_link_entry "$sk" && TRACKED_LINKS+=("skills/$(basename "$sk")")
      done
    fi
  fi

  removed=0
  skipped=0
  if is_link_entry "${PLUGIN_ROOT}/skills"; then
    echo "warning: skipping symlinked skills directory: ${PLUGIN_ROOT}/skills" >&2
    skipped=$((skipped + 1))
  elif [[ ${#TRACKED_LINKS[@]} -gt 0 ]]; then
    for lk in "${TRACKED_LINKS[@]}"; do
      p="${PLUGIN_ROOT}/${lk}"
      if is_link_entry "$p"; then
        if $M_EXISTS && ! $FORCE; then
          exp_target="$(manifest_link_target "$lk" 2>/dev/null || true)"
          if [[ -n "$exp_target" ]] && ! link_matches_expected_or_dangling "$p" "$exp_target"; then
            echo "warning: skipping retargeted skill link: $p (expected $exp_target; re-run with --force to remove)" >&2
            skipped=$((skipped + 1))
            continue
          fi
        fi
        if $DRY_RUN; then echo "dry-run: remove skill link $p"; else remove_link_only "$p"; fi
        removed=$((removed + 1))
      elif [[ -e "$p" ]]; then
        echo "warning: skipping unmanaged non-link entry: $p" >&2
      fi
    done
  fi
  WARNED_CONTAINERS=()
  if [[ ${#TRACKED_FILES[@]} -gt 0 ]]; then
    for fk in "${TRACKED_FILES[@]}"; do
      p="${PLUGIN_ROOT}/${fk}"
      p_parent="$(dirname "$p")"
      if [[ "$(norm_cmp_path "$p_parent")" != "$(norm_cmp_path "$PLUGIN_ROOT")" ]] && is_link_entry "$p_parent"; then
        already_w=false
        if [[ ${#WARNED_CONTAINERS[@]} -gt 0 ]]; then
          for wc in "${WARNED_CONTAINERS[@]}"; do
            if [[ "$wc" == "$p_parent" ]]; then already_w=true; break; fi
          done
        fi
        if ! $already_w; then
          echo "warning: skipping symlinked container directory: $p_parent" >&2
          WARNED_CONTAINERS+=("$p_parent")
        fi
        skipped=$((skipped + 1))
        continue
      fi
      if is_link_entry "$p"; then
        echo "warning: skipping symlinked file path: $p" >&2
        skipped=$((skipped + 1))
        continue
      fi
      if [[ -f "$p" ]]; then
        if $M_EXISTS && ! $FORCE; then
          exp_sha="$(manifest_file_sha "$fk" 2>/dev/null || true)"
          if [[ -n "$exp_sha" ]] && [[ "$(sha256_file "$p")" != "$exp_sha" ]]; then
            echo "warning: skipping modified managed file: $p (re-run with --force to remove)" >&2
            skipped=$((skipped + 1))
            continue
          fi
        fi
        if $DRY_RUN; then echo "dry-run: remove file $p"; else rm -f "$p"; fi
        removed=$((removed + 1))
      fi
    done
  fi
  if [[ $skipped -gt 0 ]]; then
    if ! $DRY_RUN; then
      for sd in "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/agents"; do
        if [[ -d "$sd" && ! -L "$sd" ]]; then rmdir "$sd" 2>/dev/null || true; fi
      done
    fi
    echo "UNINSTALL_CONFLICT: removed=${removed} skipped=${skipped} plugin_root=${PLUGIN_ROOT} (re-run with --force to remove modified managed entries)"
    exit 1
  fi
  if $M_EXISTS && [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]]; then
    if $DRY_RUN; then echo "dry-run: remove manifest $MANIFEST_FILE"; else rm -f "$MANIFEST_FILE"; fi
    removed=$((removed + 1))
  fi
  if ! $DRY_RUN; then
    for sd in "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/agents"; do
      if [[ -d "$sd" && ! -L "$sd" ]]; then rmdir "$sd" 2>/dev/null || true; fi
    done
    if [[ -d "$PLUGIN_ROOT" && ! -L "$PLUGIN_ROOT" ]]; then rmdir "$PLUGIN_ROOT" 2>/dev/null || true; fi
  fi
  echo "UNINSTALL_OK: removed=${removed} plugin_root=${PLUGIN_ROOT}"
  exit 0
fi

# --- Resolve and validate B3Home ---
if [[ -z "$B3_HOME" ]]; then
  B3_HOME="$(canon_existing_dir "${SCRIPT_DIR}/../..")"
else
  [[ -d "$B3_HOME" ]] || { echo "error: B3Home not found: $B3_HOME" >&2; exit 1; }
  B3_HOME="$(canon_existing_dir "$B3_HOME")"
fi

WORKFLOW="${B3_HOME}/workflows/ship.md"
SKILLS_SRC="${B3_HOME}/skills"
CMD_SKILLS_SRC="${B3_HOME}/adapters/command-skills"
RULES_DIR="${B3_HOME}/rules"
AGENTS_DIR="${B3_HOME}/agents"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -d "$SKILLS_SRC" ]] || { echo "error: B3_HOME missing skills: $SKILLS_SRC" >&2; exit 1; }

CORE_SKILL_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && CORE_SKILL_FILES+=("$f")
done < <(find "$SKILLS_SRC" -name 'SKILL.md' -type f | LC_ALL=C sort)
[[ ${#CORE_SKILL_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no SKILL.md under skills: $SKILLS_SRC" >&2; exit 1; }

CMD_SKILL_FILES=()
if [[ -d "$CMD_SKILLS_SRC" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && CMD_SKILL_FILES+=("$f")
  done < <(find "$CMD_SKILLS_SRC" -name 'SKILL.md' -type f | LC_ALL=C sort)
fi
[[ ${#CMD_SKILL_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no command skills under: $CMD_SKILLS_SRC" >&2; exit 1; }

CORE_SKILL_NAMES=()
CORE_SKILL_DIRS=()
CMD_SKILL_NAMES=()
CMD_SKILL_DIRS=()
ALL_SKILL_NAMES=()
ALL_SKILL_DIRS=()

check_dup_skill() {
  local cand="$1" dir="$2" existing
  if [[ ${#ALL_SKILL_NAMES[@]} -gt 0 ]]; then
    for existing in "${ALL_SKILL_NAMES[@]}"; do
      if [[ "$existing" == "$cand" ]]; then
        echo "error: duplicate skill name '$cand' at $dir" >&2
        exit 1
      fi
    done
  fi
}

for sf in "${CORE_SKILL_FILES[@]}"; do
  sname="$(skill_name_from_file "$sf")"
  sdir="$(canon_existing_dir "$(dirname "$sf")")"
  check_dup_skill "$sname" "$sdir"
  CORE_SKILL_NAMES+=("$sname")
  CORE_SKILL_DIRS+=("$sdir")
  ALL_SKILL_NAMES+=("$sname")
  ALL_SKILL_DIRS+=("$sdir")
done

for sf in "${CMD_SKILL_FILES[@]}"; do
  sname="$(skill_name_from_file "$sf")"
  sdir="$(canon_existing_dir "$(dirname "$sf")")"
  check_dup_skill "$sname" "$sdir"
  CMD_SKILL_NAMES+=("$sname")
  CMD_SKILL_DIRS+=("$sdir")
  ALL_SKILL_NAMES+=("$sname")
  ALL_SKILL_DIRS+=("$sdir")
done

RULE_FILES=()
while IFS= read -r rf; do
  [[ -n "$rf" ]] && RULE_FILES+=("$rf")
done < <(find "$RULES_DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
[[ ${#RULE_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no rules under $RULES_DIR" >&2; exit 1; }

RULES_CONTENT="# B3 AI Engineering Rules

Generated from B3_HOME: \`${B3_HOME}\` (do not edit here).
Resolve B3_HOME from \`B3_HOME\` env, product \`.b3/home\`, or \`${B3_HOME}\`.
Precedence: \`${B3_HOME}/docs/precedence.md\`. Ship: \`${B3_HOME}/workflows/ship.md\`. Review loop: \`${B3_HOME}/review-loop/strategy.md\`.
Project-level AGENTS.md, GEMINI.md, .agents/rules/, and .agents/skills/ override this global baseline within their project scope; per-project install-product is optional.
B3 commands (\`/b3-plan\`, \`/b3-implement\`, \`/b3-debug\`, \`/b3-review\`, \`/b3-verify\`, \`/b3-review-loop\`, \`/b3-ship\`) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above."

for rf in "${RULE_FILES[@]}"; do
  stripped="$(strip_frontmatter "$rf")"
  if [[ -n "$stripped" ]]; then
    RULES_CONTENT="${RULES_CONTENT}

---

${stripped}"
  fi
done
RULES_CONTENT="${RULES_CONTENT}
"
RULES_BYTES="$(printf '%s' "$RULES_CONTENT" | LC_ALL=C wc -c | tr -d ' ')"
if [[ "$RULES_BYTES" -ge 24000 ]]; then
  echo "error: generated rules/AGENTS.md is $RULES_BYTES bytes (must stay under 24000 bytes)" >&2
  exit 1
fi

AGENT_FILES=()
while IFS= read -r af; do
  [[ -n "$af" ]] || continue
  [[ "$(basename "$af")" == "README.md" ]] && continue
  AGENT_FILES+=("$af")
done < <(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
[[ ${#AGENT_FILES[@]} -ge 1 ]] || { echo "error: B3_HOME has no agent definitions under $AGENTS_DIR" >&2; exit 1; }

AGENT_BASES=()
AGENT_CONTENTS=()
for af in "${AGENT_FILES[@]}"; do
  rendered="$(render_agent "$af" "$B3_HOME")"
  AGENT_BASES+=("$(basename "$af")")
  AGENT_CONTENTS+=("${rendered}
")
done

PLUGIN_JSON='{
  "name": "b3-ai-engineering",
  "displayName": "B3 AI Engineering",
  "version": "1.0.0",
  "description": "Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.",
  "suggestedPrompts": [
    "Run /b3-ship for a new feature or plan in this repository",
    "Run an independent review-loop on the current git diff",
    "Create an implementation plan without editing code yet"
  ]
}
'

# --- Verify action ---
if [[ "$ACTION" == "verify" ]]; then
  ERRORS=()
  PLUGIN_OK=true
  RULES_OK=true
  SKILLS_OK=true
  COMMANDS_OK=true
  AGENTS_OK=true

  if [[ ! -d "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
    PLUGIN_OK=false; RULES_OK=false; SKILLS_OK=false; COMMANDS_OK=false; AGENTS_OK=false
    ERRORS+=("plugin directory missing or invalid: $PLUGIN_ROOT")
  else
    load_manifest
    if is_link_entry "$MANIFEST_FILE" || ! $M_EXISTS || [[ "$M_SCHEMA" != "b3-antigravity-plugin-v1" ]]; then
      PLUGIN_OK=false
      ERRORS+=("missing or invalid .b3-plugin-manifest at $MANIFEST_FILE")
    fi
    PJ_PATH="${PLUGIN_ROOT}/plugin.json"
    if is_link_entry "$PJ_PATH"; then
      PLUGIN_OK=false
      ERRORS+=("plugin.json is a link (expected regular file): $PJ_PATH")
    elif ! is_b3_plugin_json "$PJ_PATH"; then
      PLUGIN_OK=false
      ERRORS+=("missing or invalid plugin.json at $PJ_PATH")
    elif [[ "$(sha256_file "$PJ_PATH")" != "$(sha256_text "$PLUGIN_JSON")" ]]; then
      PLUGIN_OK=false
      ERRORS+=("stale or modified plugin.json at $PJ_PATH")
    fi

    RULES_DIR_OUT="${PLUGIN_ROOT}/rules"
    RULES_OUT="${RULES_DIR_OUT}/AGENTS.md"
    if is_link_entry "$RULES_DIR_OUT"; then
      RULES_OK=false
      ERRORS+=("rules directory is a link (expected regular directory): $RULES_DIR_OUT")
    elif is_link_entry "$RULES_OUT"; then
      RULES_OK=false
      ERRORS+=("rules/AGENTS.md is a link (expected regular file): $RULES_OUT")
    elif [[ ! -f "$RULES_OUT" ]]; then
      RULES_OK=false
      ERRORS+=("missing rules/AGENTS.md at $RULES_OUT")
    else
      r_bytes="$(wc -c < "$RULES_OUT" | tr -d ' ')"
      first_non_empty="$(awk 'NF{gsub(/\r$/,""); print $0; exit}' "$RULES_OUT")"
      if [[ "$r_bytes" -ge 24000 || "$first_non_empty" == "---" ]]; then
        RULES_OK=false
        ERRORS+=("invalid rules/AGENTS.md format or size (${r_bytes} B)")
      elif [[ "$(sha256_file "$RULES_OUT")" != "$(sha256_text "$RULES_CONTENT")" ]]; then
        RULES_OK=false
        ERRORS+=("stale or modified rules/AGENTS.md at $RULES_OUT")
      fi
    fi

    SKILLS_OUT="${PLUGIN_ROOT}/skills"
    if is_link_entry "$SKILLS_OUT"; then
      SKILLS_OK=false
      COMMANDS_OK=false
      ERRORS+=("skills directory is a link (expected container of 1-level skill links): $SKILLS_OUT")
    else
      for i in "${!CORE_SKILL_NAMES[@]}"; do
        sn="${CORE_SKILL_NAMES[$i]}"
        sd="${CORE_SKILL_DIRS[$i]}"
        dest="${SKILLS_OUT}/${sn}"
        if ! link_target_ok "$dest" "$sd" || [[ ! -f "${dest}/SKILL.md" ]]; then
          SKILLS_OK=false
          ERRORS+=("missing or broken skill link: $dest -> $sd")
        fi
      done
      if [[ -d "$SKILLS_OUT" ]]; then
        for entry in "${SKILLS_OUT}"/*; do
          [[ -e "$entry" || -L "$entry" ]] || continue
          if is_link_entry "$entry"; then
            ename="$(basename "$entry")"
            known=false
            for sn in "${ALL_SKILL_NAMES[@]}"; do
              if [[ "$sn" == "$ename" ]]; then known=true; break; fi
            done
            if ! $known && manifest_link_target "skills/${ename}" >/dev/null 2>&1; then
              SKILLS_OK=false
              ERRORS+=("stale managed skill link present: $entry")
            fi
          fi
        done
      fi

      for i in "${!CMD_SKILL_NAMES[@]}"; do
        cn="${CMD_SKILL_NAMES[$i]}"
        cd_dir="${CMD_SKILL_DIRS[$i]}"
        dest="${SKILLS_OUT}/${cn}"
        if ! link_target_ok "$dest" "$cd_dir" || [[ ! -f "${dest}/SKILL.md" ]]; then
          COMMANDS_OK=false
          ERRORS+=("missing or broken command-skill link: $dest -> $cd_dir")
        fi
      done
    fi
    for core_cmd in b3-plan b3-implement b3-debug b3-review b3-verify b3-review-loop b3-ship; do
      found_cmd=false
      for cn in "${CMD_SKILL_NAMES[@]}"; do
        if [[ "$cn" == "$core_cmd" ]]; then found_cmd=true; break; fi
      done
      if ! $found_cmd; then
        COMMANDS_OK=false
        ERRORS+=("missing expected command skill in B3_HOME: $core_cmd")
      fi
    done

    AGENTS_OUT="${PLUGIN_ROOT}/agents"
    if is_link_entry "$AGENTS_OUT"; then
      AGENTS_OK=false
      ERRORS+=("agents directory is a link (expected regular directory): $AGENTS_OUT")
    else
      for i in "${!AGENT_BASES[@]}"; do
        ab="${AGENT_BASES[$i]}"
        ac="${AGENT_CONTENTS[$i]}"
        dest="${AGENTS_OUT}/${ab}"
        if is_link_entry "$dest"; then
          AGENTS_OK=false
          ERRORS+=("agent file is a link (expected regular file): $dest")
        elif [[ ! -f "$dest" ]]; then
          AGENTS_OK=false
          ERRORS+=("missing agent file: $dest")
        elif [[ "$(sha256_file "$dest")" != "$(sha256_text "$ac")" ]]; then
          AGENTS_OK=false
          ERRORS+=("stale or modified agent file: $dest")
        elif ! grep -Eq '^subagent:[[:space:]]*true[[:space:]]*$' "$dest" || ! grep -Eq '^mainAgent:[[:space:]]*false[[:space:]]*$' "$dest" || ! grep -Eq '^tools:[[:space:]]*\[' "$dest"; then
          AGENTS_OK=false
          ERRORS+=("invalid subagent frontmatter in: $dest")
        fi
      done
      if [[ -d "$AGENTS_OUT" ]]; then
        for existing in "${AGENTS_OUT}"/*.md; do
          [[ -f "$existing" ]] || continue
          ebase="$(basename "$existing")"
          keep=false
          for expected in "${AGENT_BASES[@]}"; do
            if [[ "$ebase" == "$expected" ]]; then keep=true; break; fi
          done
          if ! $keep; then
            tracked=false
            if [[ ${#M_FILE_KEYS[@]} -gt 0 ]]; then
              for fk in "${M_FILE_KEYS[@]}"; do
                if [[ "$fk" == "agents/${ebase}" ]]; then tracked=true; break; fi
              done
            fi
            if $tracked; then
              AGENTS_OK=false
              ERRORS+=("stale generated agent file present: $existing")
            fi
          fi
        done
      fi
    fi
  fi

  $PLUGIN_OK && echo "check.plugin=OK" || echo "check.plugin=FAIL"
  $RULES_OK && echo "check.rules=OK" || echo "check.rules=FAIL"
  $SKILLS_OK && echo "check.skills=OK" || echo "check.skills=FAIL"
  $COMMANDS_OK && echo "check.commands=OK" || echo "check.commands=FAIL"
  $AGENTS_OK && echo "check.agents=OK" || echo "check.agents=FAIL"

  check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do echo "VERIFY_ERROR: $e"; done
    echo "VERIFY_FAIL: errors=${#ERRORS[@]} plugin_root=${PLUGIN_ROOT}"
    echo "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
    exit 1
  fi
  echo "VERIFY_OK: skills=${#CORE_SKILL_NAMES[@]} commands=${#CMD_SKILL_NAMES[@]} agents=${#AGENT_BASES[@]} rules_bytes=${RULES_BYTES} plugin_root=${PLUGIN_ROOT} b3_home=${B3_HOME}"
  echo "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
  exit 0
fi

is_b3_skill_name() {
  local cand="$1" sn
  for sn in "${ALL_SKILL_NAMES[@]}"; do
    [[ "$sn" == "$cand" ]] && return 0
  done
  return 1
}

# --- Preflight before any write (install / update) ---
load_manifest
if $M_EXISTS && [[ "$M_SCHEMA" != "b3-antigravity-plugin-v1" ]]; then
  echo "error: invalid B3 manifest at $MANIFEST_FILE" >&2; exit 1
fi
if [[ -e "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
  if [[ ! -d "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
    echo "error: refusing to replace existing non-directory path: $PLUGIN_ROOT" >&2
    exit 1
  fi
  load_manifest
  IS_B3_PLUGIN=false
  if $M_EXISTS || is_b3_plugin_json "${PLUGIN_ROOT}/plugin.json"; then
    IS_B3_PLUGIN=true
  fi
  if ! $IS_B3_PLUGIN && ! $FORCE; then
    echo "error: refusing to overwrite existing non-B3 directory without --force: $PLUGIN_ROOT" >&2
    exit 1
  fi
  for sub_name in rules skills agents; do
    sub_path="${PLUGIN_ROOT}/${sub_name}"
    if [[ -e "$sub_path" || -L "$sub_path" ]]; then
      if is_link_entry "$sub_path"; then
        echo "error: refusing to traverse link directory ${sub_name}: $sub_path" >&2
        exit 1
      fi
      if [[ ! -d "$sub_path" ]]; then
        echo "error: existing non-directory path blocks ${sub_name}: $sub_path" >&2
        exit 1
      fi
    fi
  done
  MANAGED_FILES=(
    "${PLUGIN_ROOT}/plugin.json"
    "${PLUGIN_ROOT}/rules/AGENTS.md"
    "$MANIFEST_FILE"
  )
  for ab in "${AGENT_BASES[@]}"; do
    MANAGED_FILES+=("${PLUGIN_ROOT}/agents/${ab}")
  done
  for mp in "${MANAGED_FILES[@]}"; do
    if [[ -e "$mp" || -L "$mp" ]]; then
      if is_link_entry "$mp"; then echo "error: existing link blocks managed file: $mp" >&2; exit 1; fi
      if [[ ! -f "$mp" ]]; then echo "error: existing non-file path blocks managed file: $mp" >&2; exit 1; fi
      if [[ "$mp" != "$MANIFEST_FILE" ]]; then
        key="${mp#${PLUGIN_ROOT}/}"
        exp_sha="$(manifest_file_sha "$key" 2>/dev/null || true)"
        if ! $FORCE && { [[ -z "$exp_sha" ]] || [[ "$(sha256_file "$mp")" != "$exp_sha" ]]; }; then
          echo "error: UPDATE_CONFLICT: unmanaged or modified file: $mp (preserved; backup before --force)" >&2; exit 1
        fi
      fi
    fi
  done
  if [[ -d "${PLUGIN_ROOT}/skills" ]]; then
    for entry in "${PLUGIN_ROOT}/skills"/* "${PLUGIN_ROOT}/skills"/.[!.]* "${PLUGIN_ROOT}/skills"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      ename="$(basename "$entry")"
      prior="$(manifest_link_target "skills/${ename}" 2>/dev/null || true)"
      if is_link_entry "$entry"; then
        if [[ -n "$prior" ]]; then
          if ! $FORCE && ! link_matches_expected_or_dangling "$entry" "$prior"; then
            echo "error: UPDATE_CONFLICT: modified managed skill link: $entry" >&2; exit 1
          fi
        elif is_b3_skill_name "$ename"; then
          echo "error: UPDATE_CONFLICT: untracked skill link: $entry (move manually; --force cannot delete)" >&2; exit 1
        fi
      elif is_b3_skill_name "$ename"; then
        if ! $FORCE || [[ ! -f "${entry}/SKILL.md" ]]; then
          echo "error: UPDATE_CONFLICT: existing skill directory: $entry (explicit --force requires SKILL.md)" >&2; exit 1
        fi
      fi
    done
  fi
  if [[ -d "${PLUGIN_ROOT}/agents" ]]; then
    for existing in "${PLUGIN_ROOT}/agents"/*.md; do
      [[ -f "$existing" ]] || continue
      ebase="$(basename "$existing")"
      keep=false
      for expected in "${AGENT_BASES[@]}"; do
        if [[ "$ebase" == "$expected" ]]; then keep=true; break; fi
      done
      $keep && continue
      exp_sha="$(manifest_file_sha "agents/${ebase}" 2>/dev/null || true)"
      if [[ -n "$exp_sha" ]] && ! $FORCE && [[ "$(sha256_file "$existing")" != "$exp_sha" ]]; then
        echo "error: UPDATE_CONFLICT: modified stale B3 agent: $existing" >&2; exit 1
      fi
    done
  fi
fi

if $DRY_RUN; then
  echo "dry-run: action=${ACTION} plugin_root=${PLUGIN_ROOT}"
  echo "dry-run: B3_HOME=${B3_HOME}"
  echo "dry-run: write ${PLUGIN_ROOT}/plugin.json"
  echo "dry-run: write ${PLUGIN_ROOT}/rules/AGENTS.md (${RULES_BYTES} bytes)"
  echo "dry-run: link ${#ALL_SKILL_NAMES[@]} skills (${#CORE_SKILL_NAMES[@]} skills + ${#CMD_SKILL_NAMES[@]} command-skills) into ${PLUGIN_ROOT}/skills"
  echo "dry-run: write ${#AGENT_BASES[@]} agents into ${PLUGIN_ROOT}/agents"
  check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"
  echo "DRY_RUN_OK: action=${ACTION} plugin_root=${PLUGIN_ROOT}"
  exit 0
fi

mkdir -p "$PLUGIN_ROOT" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/agents"

MANIFEST_LINES="schema=b3-antigravity-plugin-v1
b3_home=${B3_HOME}
plugin_root=${PLUGIN_ROOT}
"

write_lf_file "${PLUGIN_ROOT}/plugin.json" "$PLUGIN_JSON"
MANIFEST_LINES="${MANIFEST_LINES}file|plugin.json|$(sha256_text "$PLUGIN_JSON")
"
write_lf_file "${PLUGIN_ROOT}/rules/AGENTS.md" "$RULES_CONTENT"
MANIFEST_LINES="${MANIFEST_LINES}file|rules/AGENTS.md|$(sha256_text "$RULES_CONTENT")
"

for entry in "${PLUGIN_ROOT}/skills"/* "${PLUGIN_ROOT}/skills"/.[!.]* "${PLUGIN_ROOT}/skills"/..?*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  ename="$(basename "$entry")"
  if is_link_entry "$entry"; then
    # Only previous manifest links are B3-owned; preserve all untracked links.
    prior="$(manifest_link_target "skills/${ename}" 2>/dev/null || true)"
    [[ -n "$prior" ]] || continue
    desired_dir=""
    for i in "${!ALL_SKILL_NAMES[@]}"; do
      if [[ "${ALL_SKILL_NAMES[$i]}" == "$ename" ]]; then desired_dir="${ALL_SKILL_DIRS[$i]}"; break; fi
    done
    if [[ -z "$desired_dir" ]] || ! link_target_ok "$entry" "$desired_dir"; then remove_link_only "$entry"; fi
  elif $FORCE && is_b3_skill_name "$ename"; then
    rm -rf "$entry"
  fi
done

# Emit sorted manifest skill links after creation
SORTED_SKILL_IDX=()
while IFS= read -r idx_line; do
  [[ -n "$idx_line" ]] && SORTED_SKILL_IDX+=("${idx_line%% *}")
done < <(
  for i in "${!ALL_SKILL_NAMES[@]}"; do
    printf '%s %s\n' "$i" "${ALL_SKILL_NAMES[$i]}"
  done | LC_ALL=C sort -k2,2
)

for i in "${SORTED_SKILL_IDX[@]}"; do
  sname="${ALL_SKILL_NAMES[$i]}"
  sdir="${ALL_SKILL_DIRS[$i]}"
  dest="${PLUGIN_ROOT}/skills/${sname}"
  if ! link_target_ok "$dest" "$sdir"; then
    if is_link_entry "$dest"; then
      prior="$(manifest_link_target "skills/${sname}" 2>/dev/null || true)"
      if [[ -z "$prior" ]]; then
        echo "error: UPDATE_CONFLICT: untracked skill link: $dest" >&2; exit 1
      fi
      remove_link_only "$dest"
    fi
    create_dir_link "$dest" "$sdir"
  fi
  MANIFEST_LINES="${MANIFEST_LINES}link|skills/${sname}|${sdir}
"
done

load_manifest
for existing in "${PLUGIN_ROOT}/agents"/*.md; do
  [[ -f "$existing" ]] || continue
  ebase="$(basename "$existing")"
  keep=false
  for expected in "${AGENT_BASES[@]}"; do
    if [[ "$ebase" == "$expected" ]]; then keep=true; break; fi
  done
  if ! $keep; then
    tracked=false
    if [[ ${#M_FILE_KEYS[@]} -gt 0 ]]; then
      for fk in "${M_FILE_KEYS[@]}"; do
        if [[ "$fk" == "agents/${ebase}" ]]; then tracked=true; break; fi
      done
    fi
    if $tracked; then
      rm -f "$existing"
    fi
  fi
done

for i in "${!AGENT_BASES[@]}"; do
  ab="${AGENT_BASES[$i]}"
  ac="${AGENT_CONTENTS[$i]}"
  write_lf_file "${PLUGIN_ROOT}/agents/${ab}" "$ac"
  MANIFEST_LINES="${MANIFEST_LINES}file|agents/${ab}|$(sha256_text "$ac")
"
done

write_lf_file "$MANIFEST_FILE" "$MANIFEST_LINES"

check_coexistence "$USER_HOME" "$PLUGIN_ROOT" "${ALL_SKILL_NAMES[@]}"

PLUGIN_DIR_NAME="$(basename "$PLUGIN_ROOT")"
ACTION_UPPER="$(printf '%s' "$ACTION" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
echo "${ACTION_UPPER}_OK: skills=${#CORE_SKILL_NAMES[@]} commands=${#CMD_SKILL_NAMES[@]} agents=${#AGENT_BASES[@]} rules_bytes=${RULES_BYTES} plugin_root=${PLUGIN_ROOT} b3_home=${B3_HOME}"
echo "installed Antigravity plugin at $PLUGIN_ROOT"
echo "B3_HOME=$B3_HOME"
echo "skills=${#ALL_SKILL_NAMES[@]}"
echo "agents=${#AGENT_BASES[@]}"
echo "rules_bytes=$RULES_BYTES"
echo "manage=customization://$PLUGIN_DIR_NAME"
echo "note: this proves plugin files were generated, not Antigravity runtime discovery"
