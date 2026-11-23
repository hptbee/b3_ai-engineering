#!/usr/bin/env bash
# Global Cursor installer for B3 AI Engineering (macOS / Linux / Git Bash).
# Installs/updates/verifies/uninstalls flattened 1-level skills, 7 commands, 5 subagents, global b3-home, and plain-text User Rules template under ~/.cursor.
# Usage: ./adapters/cursor/install-global.sh [install|update|verify|uninstall] [--cursor-home DIR] [--b3-home DIR] [--user-home DIR] [--dry-run] [--force]

set -euo pipefail

ACTION="install"
ACTION_SET=false
CURSOR_HOME=""
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
    --cursor-home) CURSOR_HOME="${2:-}"; shift 2 ;;
    --b3-home) B3_HOME="${2:-}"; shift 2 ;;
    --user-home) USER_HOME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--cursor-home DIR] [--b3-home DIR] [--user-home DIR] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

_CLEANUP_DIRS=()
_cleanup_tmp() {
  if [[ ${#_CLEANUP_DIRS[@]} -gt 0 ]]; then
    local d
    for d in "${_CLEANUP_DIRS[@]}"; do
      [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
  fi
}
trap _cleanup_tmp EXIT

trim_crlf() {
  printf '%s' "$1" | LC_ALL=C tr -d '\r'
}

canon_existing_dir() {
  local d="$1"
  (cd "$d" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))
}

canon_path_allow_missing() {
  local p="$1"
  p="${p//\\//}"
  while [[ "$p" == */ && "$p" != "/" && ! "$p" =~ ^[A-Za-z]:/$ ]]; do
    p="${p%/}"
  done
  if [[ -d "$p" ]]; then
    canon_existing_dir "$p"
    return
  fi
  local cur="$p"
  local suffix=""
  while [[ ! -d "$cur" ]]; do
    local base parent
    base="$(basename "$cur")"
    parent="$(dirname "$cur")"
    [[ "$parent" == "$cur" ]] && break
    if [[ -z "$suffix" ]]; then
      suffix="$base"
    else
      suffix="${base}/${suffix}"
    fi
    cur="$parent"
  done
  if [[ -d "$cur" ]]; then
    local resolved
    resolved="$(canon_existing_dir "$cur")"
    resolved="${resolved%/}"
    if [[ -n "$suffix" ]]; then
      printf '%s/%s' "$resolved" "$suffix"
    else
      printf '%s' "$resolved"
    fi
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

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print tolower($NF)}'
  else
    echo "error: missing sha256 utility (sha256sum/shasum/openssl)" >&2
    return 1
  fi
}

write_lf_file() {
  local dest="$1"
  local content="$2"
  mkdir -p "$(dirname "$dest")"
  local tmp="${dest}.tmp.$$.${RANDOM}"
  printf '%s' "$content" | LC_ALL=C tr -d '\r' > "$tmp"
  mv -f "$tmp" "$dest"
}

is_link_entry() {
  local p="$1"
  [[ -L "$p" ]]
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
  local dest="$1"
  local target="$2"
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
  local dest="$1"
  local expected="$2"
  [[ -L "$dest" && -d "$dest" ]] || return 1
  local rd re
  rd="$(cd -P "$dest" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  re="$(cd -P "$expected" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P))" || return 1
  [[ -n "$rd" && "$(norm_cmp_path "$rd")" == "$(norm_cmp_path "$re")" ]]
}

validate_frontmatter() {
  local f="$1"
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit 2; in_fm = 1; next }
    in_fm && $0 == "---" { done = 1; exit 0 }
    END { if (!done) exit 2 }
  ' "$f" || {
    echo "error: canonical markdown missing/unclosed YAML frontmatter: $f" >&2
    exit 1
  }
}

skill_name_from_file() {
  local f="$1"
  local name
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
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
  else
    basename "$(dirname "$f")"
  fi
}

render_managed_doc() {
  local src_file="$1"
  local header_line1="$2"
  local header_line2="$3"
  validate_frontmatter "$src_file"
  awk -v h1="$header_line1" -v h2="$header_line2" '
    { sub(/\r$/, "") }
    NR == 1 { print; in_fm = 1; next }
    in_fm && $0 == "---" {
      print
      print h1
      print ""
      print h2
      in_fm = 0
      in_body = 1
      started = 0
      next
    }
    in_fm { print; next }
    in_body {
      if (!started && $0 == "") next
      started = 1
      lines[++n] = $0
    }
    END {
      while (n > 0 && lines[n] == "") n--
      if (n > 0) {
        print ""
        for (i = 1; i <= n; i++) print lines[i]
      }
    }
  ' "$src_file"
}

check_coexistence() {
  local user_home="$1"
  shift
  local skill_names=("$@")
  local sub
  for sub in ".agents/skills" ".claude/skills"; do
    local other_root="${user_home}/${sub}"
    [[ -d "$other_root" ]] || continue
    local overlap=0 sn
    if [[ ${#skill_names[@]} -gt 0 ]]; then
      for sn in "${skill_names[@]}"; do
        if [[ -e "${other_root}/${sn}" || -L "${other_root}/${sn}" ]]; then
          overlap=$((overlap + 1))
        fi
      done
    fi
    if [[ $overlap -gt 0 ]]; then
      echo "COEXISTENCE_WARNING: ~/${sub} contains ${overlap} overlapping B3 skill(s); Cursor cross-loads ~/${sub} and may show duplicates."
    fi
  done
}

# Resolve directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$B3_HOME" ]]; then
  B3_HOME="$(canon_existing_dir "${SCRIPT_DIR}/../..")"
else
  [[ -d "$B3_HOME" ]] || { echo "error: B3Home directory not found: $B3_HOME" >&2; exit 1; }
  B3_HOME="$(canon_existing_dir "$B3_HOME")"
fi

if [[ -z "$USER_HOME" ]]; then
  USER_HOME="$HOME"
fi
USER_HOME="$(canon_path_allow_missing "$USER_HOME")"

if [[ -z "$CURSOR_HOME" ]]; then
  CURSOR_HOME="${USER_HOME}/.cursor"
fi
CURSOR_HOME="$(canon_path_allow_missing "$CURSOR_HOME")"

SKILLS_DEST="${CURSOR_HOME}/skills"
COMMANDS_DEST="${CURSOR_HOME}/commands"
AGENTS_DEST="${CURSOR_HOME}/agents"
B3_HOME_FILE="${CURSOR_HOME}/b3-home"
USER_RULES_FILE="${CURSOR_HOME}/b3-user-rules.txt"
MANIFEST_FILE="${CURSOR_HOME}/.b3-global-manifest"

EXPECTED_COMMANDS=("b3-plan.md" "b3-implement.md" "b3-debug.md" "b3-review.md" "b3-verify.md" "b3-review-loop.md" "b3-ship.md")
EXPECTED_AGENTS=("b3-reviewer.md" "b3-fixer.md" "b3-security-reviewer.md" "b3-architecture-reviewer.md" "b3-performance-reviewer.md")

# Read existing manifest into parallel indexed arrays (Bash 3.2 safe)
M_EXISTS=false
M_SKILL_NAMES=()
M_SKILL_TARGETS=()
M_CMD_NAMES=()
M_CMD_SHAS=()
M_AGENT_NAMES=()
M_AGENT_SHAS=()
M_FILE_NAMES=()
M_FILE_SHAS=()

load_manifest() {
  [[ -f "$MANIFEST_FILE" ]] || return 0
  M_EXISTS=true
  local raw k v1 v2
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="$(trim_crlf "$raw")"
    [[ -n "$raw" ]] || continue
    [[ "$raw" == schema=* || "$raw" == b3_home=* ]] && continue
    IFS='|' read -r k v1 v2 <<< "$raw"
    case "$k" in
      skill) M_SKILL_NAMES+=("$v1"); M_SKILL_TARGETS+=("$v2") ;;
      command) M_CMD_NAMES+=("$v1"); M_CMD_SHAS+=("$v2") ;;
      agent) M_AGENT_NAMES+=("$v1"); M_AGENT_SHAS+=("$v2") ;;
      file) M_FILE_NAMES+=("$v1"); M_FILE_SHAS+=("$v2") ;;
    esac
  done < "$MANIFEST_FILE"
}

manifest_has_skill() {
  local target="$1" s
  if [[ ${#M_SKILL_NAMES[@]} -gt 0 ]]; then
    for s in "${M_SKILL_NAMES[@]}"; do
      [[ "$s" == "$target" ]] && return 0
    done
  fi
  return 1
}

manifest_file_sha() {
  local target="$1" i
  if [[ ${#M_FILE_NAMES[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_FILE_NAMES[@]}; i++)); do
      if [[ "${M_FILE_NAMES[$i]}" == "$target" ]]; then
        printf '%s' "${M_FILE_SHAS[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

# --- Uninstall ---
if [[ "$ACTION" == "uninstall" ]]; then
  load_manifest
  if ! $M_EXISTS; then
    echo "nothing installed (no manifest at $MANIFEST_FILE)"
    exit 0
  fi
  REMOVED=0
  if [[ ${#M_SKILL_NAMES[@]} -gt 0 ]]; then
    for sk in "${M_SKILL_NAMES[@]}"; do
      p="${SKILLS_DEST}/${sk}"
      if is_link_entry "$p"; then
        if $DRY_RUN; then echo "dry-run: remove skill link $p"; else remove_link_only "$p"; fi
        REMOVED=$((REMOVED + 1))
      elif [[ -e "$p" ]]; then
        echo "warning: skipping unmanaged non-link skill directory: $p" >&2
      fi
    done
  fi
  if [[ ${#M_CMD_NAMES[@]} -gt 0 ]]; then
    for cmd in "${M_CMD_NAMES[@]}"; do
      p="${COMMANDS_DEST}/${cmd}"
      if [[ -f "$p" ]]; then
        if grep -q 'b3-global-cursor-managed:' "$p"; then
          if $DRY_RUN; then echo "dry-run: remove command $p"; else rm -f "$p"; fi
          REMOVED=$((REMOVED + 1))
        else
          echo "warning: skipping unmanaged command file: $p" >&2
        fi
      fi
    done
  fi
  if [[ ${#M_AGENT_NAMES[@]} -gt 0 ]]; then
    for ag in "${M_AGENT_NAMES[@]}"; do
      p="${AGENTS_DEST}/${ag}"
      if [[ -f "$p" ]]; then
        if grep -q 'b3-global-cursor-managed:' "$p"; then
          if $DRY_RUN; then echo "dry-run: remove agent $p"; else rm -f "$p"; fi
          REMOVED=$((REMOVED + 1))
        else
          echo "warning: skipping unmanaged agent file: $p" >&2
        fi
      fi
    done
  fi
  if manifest_file_sha "b3-user-rules.txt" >/dev/null 2>&1 && [[ -f "$USER_RULES_FILE" ]]; then
    if grep -q 'b3-global-cursor-managed:' "$USER_RULES_FILE"; then
      if $DRY_RUN; then echo "dry-run: remove $USER_RULES_FILE"; else rm -f "$USER_RULES_FILE"; fi
      REMOVED=$((REMOVED + 1))
    else
      echo "warning: skipping unmanaged file: $USER_RULES_FILE" >&2
    fi
  fi
  if exp_home_sha="$(manifest_file_sha "b3-home" 2>/dev/null)" && [[ -f "$B3_HOME_FILE" ]]; then
    cur_sha="$(sha256_file "$B3_HOME_FILE")"
    if [[ "$cur_sha" == "$exp_home_sha" ]]; then
      if $DRY_RUN; then echo "dry-run: remove $B3_HOME_FILE"; else rm -f "$B3_HOME_FILE"; fi
      REMOVED=$((REMOVED + 1))
    else
      echo "warning: skipping modified b3-home: $B3_HOME_FILE" >&2
    fi
  fi
  if $DRY_RUN; then
    echo "dry-run: remove manifest $MANIFEST_FILE"
  else
    rm -f "$MANIFEST_FILE"
    for d in "$SKILLS_DEST" "$COMMANDS_DEST" "$AGENTS_DEST"; do
      if [[ -d "$d" ]] && [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
        rmdir "$d"
      fi
    done
  fi
  echo "UNINSTALL_OK: removed=$REMOVED cursor_home=$CURSOR_HOME"
  exit 0
fi

# --- Validate canonical B3_HOME (install / update / verify) ---
WORKFLOW="${B3_HOME}/workflows/ship.md"
SKILLS_SRC="${B3_HOME}/skills"
COMMANDS_SRC="${B3_HOME}/commands"
AGENTS_SRC="${B3_HOME}/agents"
RULES_SRC="${B3_HOME}/rules"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -d "$SKILLS_SRC" ]] || { echo "error: B3_HOME missing skills dir: $SKILLS_SRC" >&2; exit 1; }
[[ -d "$COMMANDS_SRC" ]] || { echo "error: B3_HOME missing commands dir: $COMMANDS_SRC" >&2; exit 1; }
[[ -d "$AGENTS_SRC" ]] || { echo "error: B3_HOME missing agents dir: $AGENTS_SRC" >&2; exit 1; }
[[ -n "$(find "$RULES_SRC" -maxdepth 1 -name '*.md' -type f -print -quit 2>/dev/null || true)" ]] || {
  echo "error: B3_HOME missing rules/*.md under: $RULES_SRC" >&2; exit 1
}

for c in "${EXPECTED_COMMANDS[@]}"; do
  [[ -f "${COMMANDS_SRC}/${c}" ]] || { echo "error: B3_HOME missing canonical command: $c" >&2; exit 1; }
done
for a in "${EXPECTED_AGENTS[@]}"; do
  [[ -f "${AGENTS_SRC}/${a}" ]] || { echo "error: B3_HOME missing canonical agent: $a" >&2; exit 1; }
done

SKILL_NAMES=()
SKILL_TARGETS=()
while IFS= read -r sf; do
  [[ -n "$sf" ]] || continue
  sname="$(skill_name_from_file "$sf")"
  sdir="$(canon_existing_dir "$(dirname "$sf")")"
  if [[ ${#SKILL_NAMES[@]} -gt 0 ]]; then
    for existing in "${SKILL_NAMES[@]}"; do
      if [[ "$existing" == "$sname" ]]; then
        echo "error: duplicate canonical skill name '$sname' at $sf" >&2
        exit 1
      fi
    done
  fi
  SKILL_NAMES+=("$sname")
  SKILL_TARGETS+=("$sdir")
done < <(find "$SKILLS_SRC" -name 'SKILL.md' -type f | LC_ALL=C sort)

[[ ${#SKILL_NAMES[@]} -ge 1 ]] || { echo "error: B3_HOME has no SKILL.md under: $SKILLS_SRC" >&2; exit 1; }

# Sort skills deterministically by skill name
SORTED_IDX=()
while IFS= read -r entry; do
  [[ -n "$entry" ]] && SORTED_IDX+=("${entry%%|*}")
done < <(
  for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do
    printf '%s|%s\n' "$i" "${SKILL_NAMES[$i]}"
  done | LC_ALL=C sort -t '|' -k2,2
)

RENDER_DIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$RENDER_DIR")
mkdir -p "${RENDER_DIR}/commands" "${RENDER_DIR}/agents"

for c in "${EXPECTED_COMMANDS[@]}"; do
  h1="<!-- b3-global-cursor-managed: source=${B3_HOME}/commands/${c} -->"
  h2="**Global B3_HOME fallback:** if \`B3_HOME\` env and project \`.b3/home\` are absent, read \`~/.cursor/b3-home\` (\`${B3_HOME}\`). Project \`AGENTS.md\` and \`.cursor/rules/*.mdc\` override global defaults on project requirements."
  render_managed_doc "${COMMANDS_SRC}/${c}" "$h1" "$h2" > "${RENDER_DIR}/commands/${c}"
done

for a in "${EXPECTED_AGENTS[@]}"; do
  h1="<!-- b3-global-cursor-managed: source=${B3_HOME}/agents/${a} -->"
  h2="**Global B3_HOME:** resolve \`B3_HOME\` env, project \`.b3/home\`, or \`~/.cursor/b3-home\` (\`${B3_HOME}\`)."
  render_managed_doc "${AGENTS_SRC}/${a}" "$h1" "$h2" > "${RENDER_DIR}/agents/${a}"
done

printf '# B3 Global User Rules (paste into Cursor Settings > Rules > User Rules)
# b3-global-cursor-managed: source=%s/rules/
B3 Engineering Baseline (personal/global; project AGENTS.md and .cursor/rules/*.mdc override these on project requirements):
1. Resolve B3_HOME: B3_HOME env var -> project .b3/home -> ~/.cursor/b3-home (%s). Never copy skills/ into product repos.
2. Verification honesty: never claim PASS without executed evidence; missing evidence, skipped suite, or tool failure = UNKNOWN / INCOMPLETE.
3. Scope & design: understand before editing; prefer simplest correct change meeting stated requirements; load only the smallest matching skill from ~/.cursor/skills/.
4. Provenance: cite official docs vs practice vs preference; never copy external repos verbatim without provenance.
5. Delegation: independent review and fixer roles stay separate; report host limit honestly if subagent isolation is unavailable.
' "$B3_HOME" "$B3_HOME" > "${RENDER_DIR}/b3-user-rules.txt"

printf '%s\n' "$B3_HOME" > "${RENDER_DIR}/b3-home"

load_manifest

in_current_skills() {
  local target="$1" s
  for s in "${SKILL_NAMES[@]}"; do
    [[ "$s" == "$target" ]] && return 0
  done
  return 1
}

in_expected_commands() {
  local target="$1" c
  for c in "${EXPECTED_COMMANDS[@]}"; do
    [[ "$c" == "$target" ]] && return 0
  done
  return 1
}

in_expected_agents() {
  local target="$1" a
  for a in "${EXPECTED_AGENTS[@]}"; do
    [[ "$a" == "$target" ]] && return 0
  done
  return 1
}

# --- Verify ---
if [[ "$ACTION" == "verify" ]]; then
  ERRS=()
  if ! $M_EXISTS; then
    ERRS+=("missing manifest: $MANIFEST_FILE")
  fi
  LEGACY_LINK="${SKILLS_DEST}/b3-ai-engineering"
  if [[ -e "$LEGACY_LINK" || -L "$LEGACY_LINK" ]]; then
    ERRS+=("legacy b3-ai-engineering entry still exists at $LEGACY_LINK (run with --force to migrate)")
  fi
  if [[ ! -f "$B3_HOME_FILE" ]]; then
    ERRS+=("missing b3-home file: $B3_HOME_FILE")
  elif [[ "$(sha256_file "$B3_HOME_FILE")" != "$(sha256_file "${RENDER_DIR}/b3-home")" ]]; then
    ERRS+=("b3-home mismatch at $B3_HOME_FILE")
  fi
  if [[ ! -f "$USER_RULES_FILE" ]]; then
    ERRS+=("missing b3-user-rules.txt: $USER_RULES_FILE")
  elif [[ "$(sha256_file "$USER_RULES_FILE")" != "$(sha256_file "${RENDER_DIR}/b3-user-rules.txt")" ]]; then
    ERRS+=("stale or modified b3-user-rules.txt at $USER_RULES_FILE")
  fi
  for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do
    sn="${SKILL_NAMES[$i]}"
    st="${SKILL_TARGETS[$i]}"
    dest="${SKILLS_DEST}/${sn}"
    if ! link_target_ok "$dest" "$st" || [[ ! -f "${dest}/SKILL.md" ]]; then
      ERRS+=("invalid or missing skill link: $dest -> $st")
    fi
  done
  if [[ ${#M_SKILL_NAMES[@]} -gt 0 ]]; then
    for old_sk in "${M_SKILL_NAMES[@]}"; do
      if ! in_current_skills "$old_sk"; then
        old_path="${SKILLS_DEST}/${old_sk}"
        if [[ -e "$old_path" || -L "$old_path" ]]; then
          ERRS+=("stale managed skill entry present: $old_path")
        fi
      fi
    done
  fi
  for c in "${EXPECTED_COMMANDS[@]}"; do
    dest="${COMMANDS_DEST}/${c}"
    if [[ ! -f "$dest" ]]; then
      ERRS+=("missing command: $dest")
    elif [[ "$(sha256_file "$dest")" != "$(sha256_file "${RENDER_DIR}/commands/${c}")" ]]; then
      ERRS+=("stale or modified command: $dest")
    fi
  done
  for a in "${EXPECTED_AGENTS[@]}"; do
    dest="${AGENTS_DEST}/${a}"
    if [[ ! -f "$dest" ]]; then
      ERRS+=("missing agent: $dest")
    elif [[ "$(sha256_file "$dest")" != "$(sha256_file "${RENDER_DIR}/agents/${a}")" ]]; then
      ERRS+=("stale or modified agent: $dest")
    fi
  done

  check_coexistence "$USER_HOME" "${SKILL_NAMES[@]}"

  if [[ ${#ERRS[@]} -gt 0 ]]; then
    for e in "${ERRS[@]}"; do
      echo "VERIFY_ERROR: $e"
    done
    echo "VERIFY_FAIL: errors=${#ERRS[@]}"
    exit 1
  fi
  echo "VERIFY_OK: skills=${#SKILL_NAMES[@]} commands=${#EXPECTED_COMMANDS[@]} agents=${#EXPECTED_AGENTS[@]} cursor_home=$CURSOR_HOME b3_home=$B3_HOME"
  echo "note: filesystem links and hashes verified (PASS); live Cursor IDE/CLI activation and User Rules UI application remain UNKNOWN / INCOMPLETE until verified in Cursor."
  exit 0
fi

# --- Preflight all conflicts before modifying disk (install / update) ---
LEGACY_LINK="${SKILLS_DEST}/b3-ai-engineering"
REMOVE_LEGACY=false
if [[ -e "$LEGACY_LINK" || -L "$LEGACY_LINK" ]]; then
  if $FORCE && is_link_entry "$LEGACY_LINK" && link_target_ok "$LEGACY_LINK" "$SKILLS_SRC"; then
    REMOVE_LEGACY=true
  else
    echo "error: legacy $LEGACY_LINK exists; re-run with --force if it is a link to $SKILLS_SRC (or move unmanaged directory aside)" >&2
    exit 1
  fi
fi

for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do
  sn="${SKILL_NAMES[$i]}"
  st="${SKILL_TARGETS[$i]}"
  dest="${SKILLS_DEST}/${sn}"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if link_target_ok "$dest" "$st"; then continue; fi
    is_managed=false
    if [[ "$ACTION" == "update" ]] && manifest_has_skill "$sn"; then is_managed=true; fi
    if is_link_entry "$dest"; then
      if $is_managed || $FORCE; then continue; fi
      echo "error: conflicting link at $dest (does not point to $st). Re-run with --force or update." >&2
      exit 1
    fi
    if $FORCE; then
      if [[ ! -f "${dest}/SKILL.md" ]]; then
        echo "error: refusing to overwrite non-skill directory even with --force: $dest" >&2
        exit 1
      fi
      continue
    fi
    echo "error: conflicting unmanaged directory at $dest; move aside or re-run with --force" >&2
    exit 1
  fi
done

for c in "${EXPECTED_COMMANDS[@]}"; do
  dest="${COMMANDS_DEST}/${c}"
  if [[ -f "$dest" ]]; then
    if ! grep -q 'b3-global-cursor-managed:' "$dest" && ! $FORCE; then
      echo "error: refusing to overwrite unmanaged command $dest (re-run with --force to replace)" >&2
      exit 1
    fi
  elif [[ -e "$dest" || -L "$dest" ]]; then
    echo "error: existing non-file path blocks command $dest" >&2
    exit 1
  fi
done

for a in "${EXPECTED_AGENTS[@]}"; do
  dest="${AGENTS_DEST}/${a}"
  if [[ -f "$dest" ]]; then
    if ! grep -q 'b3-global-cursor-managed:' "$dest" && ! $FORCE; then
      echo "error: refusing to overwrite unmanaged agent $dest (re-run with --force to replace)" >&2
      exit 1
    fi
  elif [[ -e "$dest" || -L "$dest" ]]; then
    echo "error: existing non-file path blocks agent $dest" >&2
    exit 1
  fi
done

if [[ -e "$B3_HOME_FILE" || -L "$B3_HOME_FILE" ]]; then
  [[ -f "$B3_HOME_FILE" ]] || { echo "error: existing non-file path blocks $B3_HOME_FILE" >&2; exit 1; }
  cur_home="$(trim_crlf "$(cat "$B3_HOME_FILE")")"
  cur_home="${cur_home//\\//}"
  cur_home="${cur_home%/}"
  home_managed=false
  if [[ "$ACTION" == "update" ]] && manifest_file_sha "b3-home" >/dev/null 2>&1; then home_managed=true; fi
  if [[ "$(norm_cmp_path "$cur_home")" != "$(norm_cmp_path "$B3_HOME")" ]] && ! $home_managed && ! $FORCE; then
    echo "error: refusing to overwrite unmanaged $B3_HOME_FILE (points to $cur_home; re-run with --force)" >&2
    exit 1
  fi
fi

if [[ -e "$USER_RULES_FILE" || -L "$USER_RULES_FILE" ]]; then
  [[ -f "$USER_RULES_FILE" ]] || { echo "error: existing non-file path blocks $USER_RULES_FILE" >&2; exit 1; }
  if ! grep -q 'b3-global-cursor-managed:' "$USER_RULES_FILE" && ! $FORCE; then
    echo "error: refusing to overwrite unmanaged $USER_RULES_FILE (re-run with --force)" >&2
    exit 1
  fi
fi

# --- Execute install / update ---
if $DRY_RUN; then
  $REMOVE_LEGACY && echo "dry-run: remove legacy link $LEGACY_LINK"
  echo "dry-run: ensure $CURSOR_HOME, write $B3_HOME_FILE ($B3_HOME), $USER_RULES_FILE"
  echo "dry-run: link ${#SKILL_NAMES[@]} flattened skills under $SKILLS_DEST"
  echo "dry-run: write ${#EXPECTED_COMMANDS[@]} commands under $COMMANDS_DEST and ${#EXPECTED_AGENTS[@]} agents under $AGENTS_DEST"
  if [[ ${#M_SKILL_NAMES[@]} -gt 0 ]]; then
    for old_sk in "${M_SKILL_NAMES[@]}"; do
      if ! in_current_skills "$old_sk"; then
        echo "dry-run: prune removed skill ${SKILLS_DEST}/${old_sk}"
      fi
    done
  fi
  check_coexistence "$USER_HOME" "${SKILL_NAMES[@]}"
  echo "DRY_RUN_OK: action=$ACTION cursor_home=$CURSOR_HOME"
  exit 0
fi

mkdir -p "$CURSOR_HOME" "$SKILLS_DEST" "$COMMANDS_DEST" "$AGENTS_DEST"

if $REMOVE_LEGACY; then
  remove_link_only "$LEGACY_LINK"
  echo "migrated: removed legacy link $LEGACY_LINK"
fi

MANIFEST_BODY="schema=b3-cursor-global-v1
b3_home=${B3_HOME}
"

for idx in "${SORTED_IDX[@]}"; do
  sn="${SKILL_NAMES[$idx]}"
  st="${SKILL_TARGETS[$idx]}"
  dest="${SKILLS_DEST}/${sn}"
  if ! link_target_ok "$dest" "$st"; then
    if is_link_entry "$dest"; then
      remove_link_only "$dest"
    elif [[ -d "$dest" ]]; then
      rm -rf "$dest"
    fi
    create_dir_link "$dest" "$st"
  fi
  MANIFEST_BODY="${MANIFEST_BODY}skill|${sn}|${st}
"
done

if [[ ${#M_SKILL_NAMES[@]} -gt 0 ]]; then
  for old_sk in "${M_SKILL_NAMES[@]}"; do
    if ! in_current_skills "$old_sk"; then
      old_path="${SKILLS_DEST}/${old_sk}"
      if is_link_entry "$old_path"; then
        remove_link_only "$old_path"
      elif [[ -e "$old_path" ]]; then
        echo "warning: skipping prune of non-link directory $old_path" >&2
      fi
    fi
  done
fi

for c in "${EXPECTED_COMMANDS[@]}"; do
  dest="${COMMANDS_DEST}/${c}"
  tmp_src="${RENDER_DIR}/commands/${c}"
  cp -f "$tmp_src" "$dest"
  c_sha="$(sha256_file "$tmp_src")"
  MANIFEST_BODY="${MANIFEST_BODY}command|${c}|${c_sha}
"
done
if [[ ${#M_CMD_NAMES[@]} -gt 0 ]]; then
  for old_cmd in "${M_CMD_NAMES[@]}"; do
    if ! in_expected_commands "$old_cmd"; then
      old_path="${COMMANDS_DEST}/${old_cmd}"
      if [[ -f "$old_path" ]] && grep -q 'b3-global-cursor-managed:' "$old_path"; then
        rm -f "$old_path"
      fi
    fi
  done
fi

for a in "${EXPECTED_AGENTS[@]}"; do
  dest="${AGENTS_DEST}/${a}"
  tmp_src="${RENDER_DIR}/agents/${a}"
  cp -f "$tmp_src" "$dest"
  a_sha="$(sha256_file "$tmp_src")"
  MANIFEST_BODY="${MANIFEST_BODY}agent|${a}|${a_sha}
"
done
if [[ ${#M_AGENT_NAMES[@]} -gt 0 ]]; then
  for old_ag in "${M_AGENT_NAMES[@]}"; do
    if ! in_expected_agents "$old_ag"; then
      old_path="${AGENTS_DEST}/${old_ag}"
      if [[ -f "$old_path" ]] && grep -q 'b3-global-cursor-managed:' "$old_path"; then
        rm -f "$old_path"
      fi
    fi
  done
fi

cp -f "${RENDER_DIR}/b3-home" "$B3_HOME_FILE"
MANIFEST_BODY="${MANIFEST_BODY}file|b3-home|$(sha256_file "${RENDER_DIR}/b3-home")
"
cp -f "${RENDER_DIR}/b3-user-rules.txt" "$USER_RULES_FILE"
MANIFEST_BODY="${MANIFEST_BODY}file|b3-user-rules.txt|$(sha256_file "${RENDER_DIR}/b3-user-rules.txt")
"

write_lf_file "$MANIFEST_FILE" "$MANIFEST_BODY"

check_coexistence "$USER_HOME" "${SKILL_NAMES[@]}"
ACTION_UPPER="$(printf '%s' "$ACTION" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
echo "${ACTION_UPPER}_OK: skills=${#SKILL_NAMES[@]} commands=${#EXPECTED_COMMANDS[@]} agents=${#EXPECTED_AGENTS[@]} cursor_home=$CURSOR_HOME b3_home=$B3_HOME"
echo "note: Cursor global User Rules must be pasted once manually from $USER_RULES_FILE into Cursor Settings > Rules > User Rules (runtime discovery UNKNOWN / INCOMPLETE until verified in Cursor)."
