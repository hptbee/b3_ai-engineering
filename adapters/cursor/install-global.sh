#!/usr/bin/env bash
# Global Cursor installer for B3 AI Engineering (macOS / Linux / Git Bash).
# Installs/updates/verifies/uninstalls flattened 1-level skills, 8 commands, 5 subagents, global b3-home, and plain-text User Rules template under ~/.cursor.
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
      if $ACTION_SET; then echo "error: duplicate action '$1'" >&2; exit 1; fi
      ACTION="$1"; ACTION_SET=true; shift ;;
    --cursor-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      CURSOR_HOME="$2"; shift 2 ;;
    --b3-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      B3_HOME="$2"; shift 2 ;;
    --user-home)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: option $1 requires a value" >&2; exit 1; }
      USER_HOME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [install|update|verify|uninstall] [--cursor-home DIR] [--b3-home DIR] [--user-home DIR] [--dry-run] [--force]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/global-common.sh
source "${SCRIPT_DIR}/../lib/global-common.sh"

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

render_managed_doc() {
  local src_file="$1" h1="$2" h2="$3"
  awk -v fpath="$src_file" -v h1="$h1" -v h2="$h2" '
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") { print "error: canonical markdown missing YAML frontmatter: " fpath > "/dev/stderr"; exit 2 }
      print; in_fm = 1; next
    }
    in_fm && $0 == "---" {
      print; print h1; print ""; print h2
      in_fm = 0; done_fm = 1; in_body = 1; started = 0; next
    }
    in_fm { print; next }
    in_body {
      if (!started && $0 == "") next
      started = 1; lines[++n] = $0
    }
    END {
      if (!done_fm) { print "error: canonical markdown missing/unclosed YAML frontmatter: " fpath > "/dev/stderr"; exit 2 }
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
  local sub
  for sub in ".agents/skills" ".claude/skills"; do
    count_skill_overlaps "${user_home}/${sub}" "$@"
    if [[ $OVERLAP_COUNT -gt 0 ]]; then
      echo "COEXISTENCE_WARNING: ~/${sub} contains ${OVERLAP_COUNT} overlapping B3 skill(s); Cursor cross-loads ~/${sub} and may show duplicates."
    fi
  done
}

uninstall_managed_file() {
  local path="$1" exp_sha="$2" require_marker="$3" label="$4"
  path_within_root "$CURSOR_HOME" "$path" || { echo "error: refusing to uninstall path outside CursorHome: $path" >&2; exit 1; }
  if is_link_entry "$path"; then
    echo "warning: skipping symlinked ${label}: $path" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  [[ -f "$path" ]] || return 0
  if [[ "$require_marker" == "true" ]] && ! grep -q 'b3-global-cursor-managed:' "$path"; then
    echo "warning: skipping unmanaged ${label}: $path" >&2
    return 0
  fi
  if ! $FORCE && { [[ -z "$exp_sha" ]] || [[ "$(sha256_file "$path")" != "$exp_sha" ]]; }; then
    echo "warning: skipping modified or unverified ${label}: $path (re-run with --force to remove)" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if $DRY_RUN; then echo "dry-run: remove $path"; else rm -f "$path"; fi
  REMOVED=$((REMOVED + 1))
}

assert_managed_doc_preflight() {
  local path="$1" label="$2"
  assert_regular_file_or_missing "$path" "$label"
  if [[ -f "$path" ]] && ! $FORCE && ! grep -q 'b3-global-cursor-managed:' "$path"; then
    echo "error: refusing to overwrite unmanaged ${label} $path (re-run with --force to replace)" >&2
    exit 1
  fi
}

if [[ -z "$USER_HOME" ]]; then USER_HOME="$HOME"; fi
USER_HOME="$(canon_path_allow_missing "$USER_HOME")"
if [[ -z "$CURSOR_HOME" ]]; then CURSOR_HOME="${USER_HOME}/.cursor"; fi
CURSOR_HOME="$(canon_path_allow_missing "$CURSOR_HOME")"

SKILLS_DEST="${CURSOR_HOME}/skills"
COMMANDS_DEST="${CURSOR_HOME}/commands"
AGENTS_DEST="${CURSOR_HOME}/agents"
B3_HOME_FILE="${CURSOR_HOME}/b3-home"
USER_RULES_FILE="${CURSOR_HOME}/b3-user-rules.txt"
MANIFEST_FILE="${CURSOR_HOME}/.b3-global-manifest"

EXPECTED_COMMANDS=("b3-plan.md" "b3-implement.md" "b3-debug.md" "b3-review.md" "b3-verify.md" "b3-review-loop.md" "b3-ship.md" "b3-research-ship.md")
EXPECTED_AGENTS=("b3-reviewer.md" "b3-fixer.md" "b3-security-reviewer.md" "b3-architecture-reviewer.md" "b3-performance-reviewer.md")

# --- Uninstall ---
if [[ "$ACTION" == "uninstall" ]]; then
  if is_link_entry "$CURSOR_HOME"; then
    echo "error: refusing to uninstall link-based CursorHome: $CURSOR_HOME" >&2; exit 1
  fi
  if is_link_entry "$MANIFEST_FILE"; then
    echo "error: refusing to read link-based manifest: $MANIFEST_FILE" >&2; exit 1
  fi
  manifest_load "$MANIFEST_FILE"
  if ! $M_EXISTS; then
    echo "nothing installed (no manifest at $MANIFEST_FILE)"
    exit 0
  fi
  if $M_CORRUPT || [[ "$M_SCHEMA" != "b3-cursor-global-v1" ]]; then
    echo "error: refusing to uninstall invalid or corrupt B3 manifest at $MANIFEST_FILE" >&2
    exit 1
  fi

  REMOVED=0
  SKIPPED=0
  if is_link_entry "$SKILLS_DEST"; then
    echo "warning: skipping symlinked skills directory: $SKILLS_DEST" >&2
    SKIPPED=$((SKIPPED + 1))
  elif [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      [[ "${M_KINDS[$i]}" == "skill" ]] || continue
      sk="${M_KEYS[$i]}"
      exp_target="${M_VALS[$i]}"
      p="${SKILLS_DEST}/${sk}"
      path_within_root "$CURSOR_HOME" "$p" || { echo "error: refusing to uninstall path outside CursorHome: $p" >&2; exit 1; }
      if is_link_entry "$p"; then
        if ! $FORCE && { [[ -z "$exp_target" ]] || ! link_matches_expected_or_dangling "$p" "$exp_target"; }; then
          echo "warning: skipping retargeted skill link: $p (expected $exp_target; re-run with --force to remove)" >&2
          SKIPPED=$((SKIPPED + 1))
          continue
        fi
        if $DRY_RUN; then echo "dry-run: remove skill link $p"; else remove_link_only "$p"; fi
        REMOVED=$((REMOVED + 1))
      elif [[ -e "$p" ]]; then
        echo "warning: skipping unmanaged non-link skill directory: $p" >&2
      fi
    done
  fi

  if is_link_entry "$COMMANDS_DEST"; then
    echo "warning: skipping symlinked commands directory: $COMMANDS_DEST" >&2
    SKIPPED=$((SKIPPED + 1))
  elif [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      [[ "${M_KINDS[$i]}" == "command" ]] || continue
      uninstall_managed_file "${COMMANDS_DEST}/${M_KEYS[$i]}" "${M_VALS[$i]}" "true" "command file"
    done
  fi

  if is_link_entry "$AGENTS_DEST"; then
    echo "warning: skipping symlinked agents directory: $AGENTS_DEST" >&2
    SKIPPED=$((SKIPPED + 1))
  elif [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      [[ "${M_KINDS[$i]}" == "agent" ]] || continue
      uninstall_managed_file "${AGENTS_DEST}/${M_KEYS[$i]}" "${M_VALS[$i]}" "true" "agent file"
    done
  fi

  if exp_rules_sha="$(manifest_get "file" "b3-user-rules.txt" 2>/dev/null)"; then
    uninstall_managed_file "$USER_RULES_FILE" "$exp_rules_sha" "true" "file"
  fi
  if exp_home_sha="$(manifest_get "file" "b3-home" 2>/dev/null)"; then
    uninstall_managed_file "$B3_HOME_FILE" "$exp_home_sha" "false" "b3-home"
  fi

  if ! $DRY_RUN; then
    for d in "$SKILLS_DEST" "$COMMANDS_DEST" "$AGENTS_DEST"; do
      if [[ -d "$d" && ! -L "$d" ]] && [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then rmdir "$d"; fi
    done
  fi
  if [[ $SKIPPED -gt 0 ]]; then
    echo "UNINSTALL_CONFLICT: removed=$REMOVED skipped=$SKIPPED cursor_home=$CURSOR_HOME (re-run with --force to remove modified managed entries)"
    exit 1
  fi
  if $DRY_RUN; then
    echo "dry-run: remove manifest $MANIFEST_FILE"
  else
    rm -f "$MANIFEST_FILE"
    for d in "$SKILLS_DEST" "$COMMANDS_DEST" "$AGENTS_DEST"; do
      if [[ -d "$d" && ! -L "$d" ]] && [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then rmdir "$d"; fi
    done
  fi
  echo "UNINSTALL_OK: removed=$REMOVED cursor_home=$CURSOR_HOME"
  exit 0
fi

# --- Validate canonical B3_HOME (install / update / verify) ---
if [[ -z "$B3_HOME" ]]; then
  B3_HOME="$(canon_existing_dir "${SCRIPT_DIR}/../..")"
else
  [[ -d "$B3_HOME" ]] || { echo "error: B3Home directory not found: $B3_HOME" >&2; exit 1; }
  B3_HOME="$(canon_existing_dir "$B3_HOME")"
fi

WORKFLOW="${B3_HOME}/workflows/ship.md"
SKILLS_SRC="${B3_HOME}/skills"
COMMANDS_SRC="${B3_HOME}/commands"
AGENTS_SRC="${B3_HOME}/agents"
RULES_SRC="${B3_HOME}/rules"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -d "$SKILLS_SRC" ]] || { echo "error: B3_HOME missing skills dir: $SKILLS_SRC" >&2; exit 1; }
[[ -d "$COMMANDS_SRC" ]] || { echo "error: B3_HOME missing commands dir: $COMMANDS_SRC" >&2; exit 1; }
[[ -d "$AGENTS_SRC" ]] || { echo "error: B3_HOME missing agents dir: $AGENTS_SRC" >&2; exit 1; }
[[ -n "$({ find "$RULES_SRC" -maxdepth 1 -name '*.md' -type f -print 2>/dev/null || true; } | head -n 1)" ]] || {
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
while IFS=$'\t' read -r sname sdir; do
  [[ -n "$sname" ]] || continue
  if [[ ${#SKILL_NAMES[@]} -gt 0 ]] && array_contains "$sname" "${SKILL_NAMES[@]}"; then
    echo "error: duplicate canonical skill name '$sname' at $sdir" >&2
    exit 1
  fi
  SKILL_NAMES+=("$sname")
  SKILL_TARGETS+=("$sdir")
done < <(discover_skills_tsv "$SKILLS_SRC")
[[ ${#SKILL_NAMES[@]} -ge 1 ]] || { echo "error: B3_HOME has no SKILL.md under: $SKILLS_SRC" >&2; exit 1; }

SORTED_IDX=()
while IFS= read -r entry; do
  [[ -n "$entry" ]] && SORTED_IDX+=("${entry%%|*}")
done < <(
  for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do printf '%s|%s\n' "$i" "${SKILL_NAMES[$i]}"; done | LC_ALL=C sort -t '|' -k2,2
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

if is_link_entry "$MANIFEST_FILE"; then
  M_EXISTS=false; M_CORRUPT=false; M_SCHEMA=""; M_KINDS=(); M_KEYS=(); M_VALS=()
else
  manifest_load "$MANIFEST_FILE"
fi

# --- Verify ---
if [[ "$ACTION" == "verify" ]]; then
  ERRS=()
  is_link_entry "$CURSOR_HOME" && ERRS+=("cursor_home is a link (expected regular directory): $CURSOR_HOME")
  is_link_entry "$SKILLS_DEST" && ERRS+=("skills directory is a link (expected regular directory): $SKILLS_DEST")
  is_link_entry "$COMMANDS_DEST" && ERRS+=("commands directory is a link (expected regular directory): $COMMANDS_DEST")
  is_link_entry "$AGENTS_DEST" && ERRS+=("agents directory is a link (expected regular directory): $AGENTS_DEST")

  if is_link_entry "$MANIFEST_FILE"; then
    ERRS+=("manifest is a link (expected regular file): $MANIFEST_FILE")
  elif ! $M_EXISTS; then
    ERRS+=("missing manifest: $MANIFEST_FILE")
  elif $M_CORRUPT || [[ "$M_SCHEMA" != "b3-cursor-global-v1" ]]; then
    ERRS+=("invalid or corrupt manifest at $MANIFEST_FILE")
  fi

  LEGACY_LINK="${SKILLS_DEST}/b3-ai-engineering"
  if [[ -e "$LEGACY_LINK" || -L "$LEGACY_LINK" ]]; then
    ERRS+=("legacy b3-ai-engineering entry still exists at $LEGACY_LINK (run with --force to migrate)")
  fi

  verify_file_match() {
    local actual="$1" expected="$2" label="$3"
    if [[ -L "$actual" ]]; then ERRS+=("${label} is a link (expected regular file): $actual")
    elif [[ ! -f "$actual" ]]; then ERRS+=("missing ${label}: $actual")
    elif [[ "$(sha256_file "$actual")" != "$(sha256_file "$expected")" ]]; then ERRS+=("stale or modified ${label} at $actual")
    fi
  }

  verify_file_match "$B3_HOME_FILE" "${RENDER_DIR}/b3-home" "b3-home"
  verify_file_match "$USER_RULES_FILE" "${RENDER_DIR}/b3-user-rules.txt" "b3-user-rules.txt"

  for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do
    sn="${SKILL_NAMES[$i]}"
    st="${SKILL_TARGETS[$i]}"
    dest="${SKILLS_DEST}/${sn}"
    if ! link_target_ok "$dest" "$st" || [[ ! -f "${dest}/SKILL.md" ]]; then
      ERRS+=("invalid or missing skill link: $dest -> $st")
    fi
  done
  if [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      [[ "${M_KINDS[$i]}" == "skill" ]] || continue
      old_sk="${M_KEYS[$i]}"
      if ! array_contains "$old_sk" "${SKILL_NAMES[@]}"; then
        old_path="${SKILLS_DEST}/${old_sk}"
        if [[ -e "$old_path" || -L "$old_path" ]]; then
          ERRS+=("stale managed skill entry present: $old_path")
        fi
      fi
    done
  fi

  for c in "${EXPECTED_COMMANDS[@]}"; do verify_file_match "${COMMANDS_DEST}/${c}" "${RENDER_DIR}/commands/${c}" "command"; done
  for a in "${EXPECTED_AGENTS[@]}"; do verify_file_match "${AGENTS_DEST}/${a}" "${RENDER_DIR}/agents/${a}" "agent"; done

  check_coexistence "$USER_HOME" "${SKILL_NAMES[@]}"

  if [[ ${#ERRS[@]} -gt 0 ]]; then
    for e in "${ERRS[@]}"; do echo "VERIFY_ERROR: $e"; done
    echo "VERIFY_FAIL: errors=${#ERRS[@]}"
    exit 1
  fi
  echo "VERIFY_OK: skills=${#SKILL_NAMES[@]} commands=${#EXPECTED_COMMANDS[@]} agents=${#EXPECTED_AGENTS[@]} cursor_home=$CURSOR_HOME b3_home=$B3_HOME"
  echo "note: filesystem links and hashes verified (PASS); live Cursor IDE/CLI activation and User Rules UI application remain UNKNOWN / INCOMPLETE until verified in Cursor."
  exit 0
fi

# --- Preflight all conflicts before modifying disk (install / update) ---
assert_regular_dir_or_missing "$CURSOR_HOME" "cursor_home"
assert_regular_dir_or_missing "$SKILLS_DEST" "skills"
assert_regular_dir_or_missing "$COMMANDS_DEST" "commands"
assert_regular_dir_or_missing "$AGENTS_DEST" "agents"
assert_regular_file_or_missing "$MANIFEST_FILE" "manifest"
if $M_EXISTS && { $M_CORRUPT || [[ "$M_SCHEMA" != "b3-cursor-global-v1" ]]; }; then
  echo "error: refusing to ${ACTION}: invalid or corrupt B3 manifest at $MANIFEST_FILE" >&2
  exit 1
fi

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

SKILL_OK_FLAGS=()
for ((i = 0; i < ${#SKILL_NAMES[@]}; i++)); do
  sn="${SKILL_NAMES[$i]}"
  st="${SKILL_TARGETS[$i]}"
  dest="${SKILLS_DEST}/${sn}"
  SKILL_OK_FLAGS[$i]="0"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if link_target_ok "$dest" "$st"; then
      SKILL_OK_FLAGS[$i]="1"
      continue
    fi
    is_managed=false
    if [[ "$ACTION" == "update" ]] && manifest_has "skill" "$sn"; then is_managed=true; fi
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

for c in "${EXPECTED_COMMANDS[@]}"; do assert_managed_doc_preflight "${COMMANDS_DEST}/${c}" "command"; done
for a in "${EXPECTED_AGENTS[@]}"; do assert_managed_doc_preflight "${AGENTS_DEST}/${a}" "agent"; done
assert_managed_doc_preflight "$USER_RULES_FILE" "user rules"

assert_regular_file_or_missing "$B3_HOME_FILE" "b3-home"
if [[ -f "$B3_HOME_FILE" ]]; then
  cur_home="$(trim_crlf "$(cat "$B3_HOME_FILE")")"
  cur_home="${cur_home//\\//}"
  cur_home="${cur_home%/}"
  home_managed=false
  if [[ "$ACTION" == "update" ]] && manifest_has "file" "b3-home"; then home_managed=true; fi
  if [[ "$(norm_cmp_path "$cur_home")" != "$(norm_cmp_path "$B3_HOME")" ]] && ! $home_managed && ! $FORCE; then
    echo "error: refusing to overwrite unmanaged $B3_HOME_FILE (points to $cur_home; re-run with --force)" >&2
    exit 1
  fi
fi

# --- Execute install / update ---
if $DRY_RUN; then
  $REMOVE_LEGACY && echo "dry-run: remove legacy link $LEGACY_LINK"
  echo "dry-run: ensure $CURSOR_HOME, write $B3_HOME_FILE ($B3_HOME), $USER_RULES_FILE"
  echo "dry-run: link ${#SKILL_NAMES[@]} flattened skills under $SKILLS_DEST"
  echo "dry-run: write ${#EXPECTED_COMMANDS[@]} commands under $COMMANDS_DEST and ${#EXPECTED_AGENTS[@]} agents under $AGENTS_DEST"
  if [[ ${#M_KINDS[@]} -gt 0 ]]; then
    for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
      [[ "${M_KINDS[$i]}" == "skill" ]] || continue
      old_sk="${M_KEYS[$i]}"
      if ! array_contains "$old_sk" "${SKILL_NAMES[@]}"; then
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
  if [[ "${SKILL_OK_FLAGS[$idx]}" != "1" ]]; then
    if is_link_entry "$dest"; then
      remove_link_only "$dest"
    elif [[ -d "$dest" ]]; then
      remove_dir_tree_safely "$dest"
    fi
    create_dir_link "$dest" "$st"
  fi
  MANIFEST_BODY="${MANIFEST_BODY}skill|${sn}|${st}
"
done

if [[ ${#M_KINDS[@]} -gt 0 ]]; then
  for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
    [[ "${M_KINDS[$i]}" == "skill" ]] || continue
    old_sk="${M_KEYS[$i]}"
    if ! array_contains "$old_sk" "${SKILL_NAMES[@]}"; then
      old_path="${SKILLS_DEST}/${old_sk}"
      if is_link_entry "$old_path"; then remove_link_only "$old_path"
      elif [[ -e "$old_path" ]]; then echo "warning: skipping prune of non-link directory $old_path" >&2
      fi
    fi
  done
fi

for c in "${EXPECTED_COMMANDS[@]}"; do
  tmp_src="${RENDER_DIR}/commands/${c}"
  install_file_atomic "$tmp_src" "${COMMANDS_DEST}/${c}"
  MANIFEST_BODY="${MANIFEST_BODY}command|${c}|$(sha256_file "$tmp_src")
"
done
for a in "${EXPECTED_AGENTS[@]}"; do
  tmp_src="${RENDER_DIR}/agents/${a}"
  install_file_atomic "$tmp_src" "${AGENTS_DEST}/${a}"
  MANIFEST_BODY="${MANIFEST_BODY}agent|${a}|$(sha256_file "$tmp_src")
"
done
if [[ ${#M_KINDS[@]} -gt 0 ]]; then
  for ((i = 0; i < ${#M_KINDS[@]}; i++)); do
    if [[ "${M_KINDS[$i]}" == "command" ]] && ! array_contains "${M_KEYS[$i]}" "${EXPECTED_COMMANDS[@]}"; then
      old_path="${COMMANDS_DEST}/${M_KEYS[$i]}"
      [[ -f "$old_path" ]] && grep -q 'b3-global-cursor-managed:' "$old_path" && rm -f "$old_path" || true
    elif [[ "${M_KINDS[$i]}" == "agent" ]] && ! array_contains "${M_KEYS[$i]}" "${EXPECTED_AGENTS[@]}"; then
      old_path="${AGENTS_DEST}/${M_KEYS[$i]}"
      [[ -f "$old_path" ]] && grep -q 'b3-global-cursor-managed:' "$old_path" && rm -f "$old_path" || true
    fi
  done
fi

install_file_atomic "${RENDER_DIR}/b3-home" "$B3_HOME_FILE"
MANIFEST_BODY="${MANIFEST_BODY}file|b3-home|$(sha256_file "${RENDER_DIR}/b3-home")
"
install_file_atomic "${RENDER_DIR}/b3-user-rules.txt" "$USER_RULES_FILE"
MANIFEST_BODY="${MANIFEST_BODY}file|b3-user-rules.txt|$(sha256_file "${RENDER_DIR}/b3-user-rules.txt")
"
write_lf_file "$MANIFEST_FILE" "$MANIFEST_BODY"

check_coexistence "$USER_HOME" "${SKILL_NAMES[@]}"
ACTION_UPPER="$(to_upper "$ACTION")"
echo "${ACTION_UPPER}_OK: skills=${#SKILL_NAMES[@]} commands=${#EXPECTED_COMMANDS[@]} agents=${#EXPECTED_AGENTS[@]} cursor_home=$CURSOR_HOME b3_home=$B3_HOME"
echo "note: Cursor global User Rules must be pasted once manually from $USER_RULES_FILE into Cursor Settings > Rules > User Rules (runtime discovery UNKNOWN / INCOMPLETE until verified in Cursor)."
