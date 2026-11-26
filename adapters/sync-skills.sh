#!/usr/bin/env bash
# Activate canonical skills/, commands/, agents/ for a host in this B3 checkout.
# Usage: ./adapters/sync-skills.sh [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>

set -euo pipefail

DRY_RUN=false
VERIFY_ONLY=false
FORCE=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verify) VERIFY_ONLY=true; shift ;;
    --force) FORCE=true; shift ;;
    cursor|codex|claude|antigravity) TARGET="$1"; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 [--dry-run] [--verify] [--force] <cursor|codex|claude|antigravity>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/global-common.sh
source "${SCRIPT_DIR}/lib/global-common.sh"
SKILLS_SRC="${ROOT}/skills"
COMMANDS_SRC="${ROOT}/commands"
AGENTS_SRC="${ROOT}/agents"
CMD_SKILLS_SRC="${ROOT}/adapters/command-skills"

has_skill_md() {
  local dir="$1"
  [[ -d "$dir" ]] && [[ -n "$({ find -L "$dir" -name 'SKILL.md' -type f -print 2>/dev/null || true; } | head -n 1)" ]]
}

has_active_path() {
  local p="$1"
  if is_link_entry "$p"; then return 0; fi
  if [[ -d "$p" ]]; then
    [[ -n "$(ls -A "$p" 2>/dev/null || true)" ]]
    return $?
  fi
  [[ -e "$p" ]]
}

sync_dir_link() {
  local dest="$1"
  local src="$2"
  local label="$3"

  if is_link_entry "$dest"; then
    if link_target_ok "$dest" "$src"; then
      echo "ok: $dest already links to $src ($label)"
      return 0
    fi
    echo "error: existing link $dest does not resolve to $src" >&2
    exit 1
  fi

  if [[ -e "$dest" ]]; then
    if [[ -d "$dest" ]] && [[ -z "$(ls -A "$dest" 2>/dev/null || true)" ]]; then
      if $DRY_RUN; then
        echo "dry-run: rmdir $dest && link $src -> $dest"
        return 0
      fi
      rmdir "$dest"
    else
      echo "error: existing non-link path with content; refusing to replace: $dest" >&2
      exit 1
    fi
  fi

  if $DRY_RUN; then
    echo "dry-run: link $dest -> $src"
    return 0
  fi

  create_dir_link "$dest" "$src"
  link_target_ok "$dest" "$src" || { echo "error: link verification failed: $dest -> $src" >&2; exit 1; }
  echo "linked: $dest -> $src ($label)"
}

collect_flat_skills() {
  local tmp_list="$1"
  : > "$tmp_list"
  while IFS=$'\t' read -r name dir; do
    [[ -n "$name" ]] || continue
    if grep -q "^${name}|" "$tmp_list"; then
      echo "error: duplicate skill name '$name'" >&2
      exit 1
    fi
    printf '%s|%s\n' "$name" "$dir" >> "$tmp_list"
  done < <(
    discover_skills_tsv "$SKILLS_SRC"
    if [[ -d "$CMD_SKILLS_SRC" ]]; then
      discover_skills_tsv "$CMD_SKILLS_SRC"
    fi
  )
}

verify_flat_index() {
  local dest_root="$1"
  local list_file="$2"
  [[ -d "$dest_root" ]] && ! is_link_entry "$dest_root" || return 1
  while IFS='|' read -r name src_dir; do
    [[ -n "$name" ]] || continue
    link_target_ok "${dest_root}/${name}" "$src_dir" || return 1
    [[ -f "${dest_root}/${name}/SKILL.md" ]] || return 1
  done < "$list_file"
  return 0
}

sync_flat_index() {
  local dest_root="$1"
  local list_file="$2"
  local label="$3"
  local count
  count="$(wc -l < "$list_file" | tr -d ' ')"

  if is_link_entry "$dest_root"; then
    if $DRY_RUN; then
      echo "dry-run: replace legacy nested link $dest_root with flattened ${count}-skill index ($label)"
      return 0
    fi
    remove_link_only "$dest_root"
  elif [[ -e "$dest_root" ]]; then
    if [[ ! -d "$dest_root" ]]; then
      echo "error: existing non-directory path; refusing to replace: $dest_root" >&2
      exit 1
    fi
    local child
    for child in "$dest_root"/* "$dest_root"/.[!.]* "$dest_root"/..?*; do
      [[ -e "$child" || -L "$child" ]] || continue
      if ! is_link_entry "$child"; then
        echo "error: existing non-link content in $dest_root; refusing to replace: $child" >&2
        exit 1
      fi
    done
  fi

  if $DRY_RUN; then
    echo "dry-run: flatten $dest_root with $count skill links ($label)"
    return 0
  fi

  mkdir -p "$dest_root"
  while IFS='|' read -r name src_dir; do
    [[ -n "$name" ]] || continue
    local entry="${dest_root}/${name}"
    if is_link_entry "$entry"; then
      if link_target_ok "$entry" "$src_dir"; then continue; fi
      remove_link_only "$entry"
    fi
    create_dir_link "$entry" "$src_dir"
  done < "$list_file"

  local child base
  for child in "$dest_root"/*; do
    is_link_entry "$child" || continue
    base="$(basename "$child")"
    if ! grep -q "^${base}|" "$list_file"; then
      remove_link_only "$child"
    fi
  done

  verify_flat_index "$dest_root" "$list_file" || { echo "error: flattened skill index verification failed: $dest_root" >&2; exit 1; }
  echo "linked: $dest_root ($count flattened skills; $label)"
}

antigravity_entry_paths() {
  local cat skill_dir
  if [[ -d "$SKILLS_SRC" ]]; then
    for cat in "$SKILLS_SRC"/*/; do
      [[ -d "$cat" ]] || continue
      local has_one=false
      for skill_dir in "$cat"*/; do
        if [[ -f "${skill_dir}SKILL.md" ]]; then
          has_one=true
          break
        fi
      done
      if $has_one; then
        echo "skills/$(basename "${cat%/}")"
      fi
    done | LC_ALL=C sort
  fi
  if [[ -d "$CMD_SKILLS_SRC" ]]; then
    for skill_dir in "$CMD_SKILLS_SRC"/*/; do
      if [[ -f "${skill_dir}SKILL.md" ]]; then
        echo "adapters/command-skills"
        break
      fi
    done
  fi
}

verify_antigravity_manifest() {
  local manifest="$1"
  [[ -f "$manifest" ]] || { echo "error: missing manifest: $manifest" >&2; return 1; }
  local parsed_paths=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && parsed_paths+=("$line")
  done < <(awk '
    /"path"[[:space:]]*:/ {
      s = $0
      sub(/.*"path"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/".*/, "", s)
      print s
    }
  ' "$manifest")
  [[ ${#parsed_paths[@]} -gt 0 ]] || { echo "error: manifest has no entries: $manifest" >&2; return 1; }

  local seen_file total=0
  seen_file="$(mktemp)"
  trap 'rm -f "$seen_file"' RETURN

  local rel resolved skill_dir sf fm_name folder_name entry_count
  for rel in "${parsed_paths[@]}"; do
    resolved="${ROOT}/${rel}"
    [[ -d "$resolved" ]] || { echo "error: manifest entry path not found: $rel" >&2; return 1; }
    entry_count=0
    for skill_dir in "$resolved"/*/; do
      sf="${skill_dir}SKILL.md"
      [[ -f "$sf" ]] || continue
      folder_name="$(basename "${skill_dir%/}")"
      fm_name="$(awk 'BEGIN{FS=": "} /^name:/{gsub(/[\r[:space:]]/,"",$2); print $2; exit}' "$sf")"
      [[ -n "$fm_name" ]] || fm_name="$folder_name"
      [[ "$fm_name" == "$folder_name" ]] || { echo "error: skill folder '$folder_name' != frontmatter name '$fm_name'" >&2; return 1; }
      if grep -qx "$fm_name" "$seen_file"; then
        echo "error: duplicate skill name '$fm_name'" >&2
        return 1
      fi
      echo "$fm_name" >> "$seen_file"
      entry_count=$((entry_count + 1))
      total=$((total + 1))
    done
    [[ $entry_count -gt 0 ]] || { echo "error: manifest entry has no 1-level SKILL.md: $rel" >&2; return 1; }
  done

  local expected found
  while IFS= read -r expected; do
    [[ -n "$expected" ]] || continue
    found=false
    for rel in "${parsed_paths[@]}"; do
      [[ "$rel" == "$expected" ]] && { found=true; break; }
    done
    $found || { echo "error: manifest missing expected entry: $expected" >&2; return 1; }
  done < <(antigravity_entry_paths)

  echo "$total"
}

has_skill_md "$SKILLS_SRC" || { echo "error: skills source missing or has no SKILL.md: $SKILLS_SRC" >&2; exit 1; }

CURSOR_SKILLS="${ROOT}/.cursor/skills"
CURSOR_COMMANDS="${ROOT}/.cursor/commands"
CURSOR_AGENTS="${ROOT}/.cursor/agents"
CODEX_SKILLS="${ROOT}/.agents/skills"
CLAUDE_SKILLS="${ROOT}/.claude/skills"
CLAUDE_AGENTS="${ROOT}/.claude/agents"
AG_MANIFEST="${ROOT}/.agents/skills.json"

case "$TARGET" in
  antigravity)
    if has_active_path "$CODEX_SKILLS"; then
      echo "warning: .agents/skills exists alongside .agents/skills.json; Antigravity may double-discover skills." >&2
    fi
    if $VERIFY_ONLY; then
      count="$(verify_antigravity_manifest "$AG_MANIFEST")" || exit 1
      echo "verify ok: $AG_MANIFEST (antigravity); $count SKILL.md entries visible"
      exit 0
    fi
    entries=()
    while IFS= read -r e; do [[ -n "$e" ]] && entries+=("$e"); done < <(antigravity_entry_paths)
    [[ ${#entries[@]} -gt 0 ]] || { echo "error: no 1-level skill directories found under $SKILLS_SRC" >&2; exit 1; }
    if $DRY_RUN; then
      echo "dry-run: write $AG_MANIFEST with ${#entries[@]} entries (${entries[*]})"
      exit 0
    fi
    mkdir -p "$(dirname "$AG_MANIFEST")"
    {
      echo "{"
      echo '  "entries": ['
      for i in "${!entries[@]}"; do
        comma=","; [[ $i -eq $((${#entries[@]} - 1)) ]] && comma=""
        echo "    { \"path\": \"${entries[$i]}\" }${comma}"
      done
      echo "  ]"
      echo "}"
    } > "$AG_MANIFEST"
    count="$(verify_antigravity_manifest "$AG_MANIFEST")" || exit 1
    echo "synced: $AG_MANIFEST (antigravity); $count SKILL.md entries visible"
    echo "note: this proves .agents/skills.json resolves to 1-level SKILL.md entries, not Antigravity runtime discovery"
    ;;
  cursor)
    [[ -d "$COMMANDS_SRC" ]] || { echo "error: commands source missing: $COMMANDS_SRC" >&2; exit 1; }
    [[ -d "$AGENTS_SRC" ]] || { echo "error: agents source missing: $AGENTS_SRC" >&2; exit 1; }
    if $VERIFY_ONLY; then
      if link_target_ok "$CURSOR_SKILLS" "$SKILLS_SRC" && has_skill_md "$CURSOR_SKILLS" && \
         link_target_ok "$CURSOR_COMMANDS" "$COMMANDS_SRC" && link_target_ok "$CURSOR_AGENTS" "$AGENTS_SRC"; then
        echo "verify ok: .cursor/{skills,commands,agents} -> canonical root (cursor)"
        exit 0
      fi
      echo "error: verify failed for .cursor/{skills,commands,agents}" >&2
      exit 1
    fi
    if ! $FORCE; then
      if has_active_path "$CODEX_SKILLS"; then
        echo "error: coexistence guard: .agents/skills exists; Cursor cross-loads it. Remove it or re-run with --force" >&2
        exit 1
      fi
      if has_active_path "$CLAUDE_SKILLS"; then
        echo "error: coexistence guard: .claude/skills exists; Cursor cross-loads it. Remove it or re-run with --force" >&2
        exit 1
      fi
    fi
    sync_dir_link "$CURSOR_SKILLS" "$SKILLS_SRC" "cursor skills"
    sync_dir_link "$CURSOR_COMMANDS" "$COMMANDS_SRC" "cursor commands"
    sync_dir_link "$CURSOR_AGENTS" "$AGENTS_SRC" "cursor agents"
    echo "note: this proves filesystem links, not Cursor runtime skill discovery"
    ;;
  codex)
    TMP_LIST="$(mktemp)"
    trap 'rm -f "$TMP_LIST"' EXIT
    collect_flat_skills "$TMP_LIST"
    if $VERIFY_ONLY; then
      if verify_flat_index "$CODEX_SKILLS" "$TMP_LIST"; then
        echo "verify ok: $CODEX_SKILLS ($(wc -l < "$TMP_LIST" | tr -d ' ') flattened skills; codex)"
        exit 0
      fi
      echo "error: verify failed for $CODEX_SKILLS" >&2
      exit 1
    fi
    if ! $FORCE && has_active_path "$CURSOR_SKILLS"; then
      echo "error: coexistence guard: .cursor/skills exists; Cursor cross-loads .agents/skills. Remove .cursor/skills or re-run with --force" >&2
      exit 1
    fi
    if [[ -f "$AG_MANIFEST" ]]; then
      echo "warning: .agents/skills.json is committed for Antigravity; if Antigravity also opens this checkout, it may read both .agents/skills.json and .agents/skills." >&2
    fi
    sync_flat_index "$CODEX_SKILLS" "$TMP_LIST" "codex"
    echo "note: this proves filesystem links, not Codex runtime skill discovery"
    ;;
  claude)
    [[ -d "$AGENTS_SRC" ]] || { echo "error: agents source missing: $AGENTS_SRC" >&2; exit 1; }
    TMP_LIST="$(mktemp)"
    trap 'rm -f "$TMP_LIST"' EXIT
    collect_flat_skills "$TMP_LIST"
    if $VERIFY_ONLY; then
      if verify_flat_index "$CLAUDE_SKILLS" "$TMP_LIST" && link_target_ok "$CLAUDE_AGENTS" "$AGENTS_SRC"; then
        echo "verify ok: $CLAUDE_SKILLS ($(wc -l < "$TMP_LIST" | tr -d ' ') flattened skills) + $CLAUDE_AGENTS -> $AGENTS_SRC (claude)"
        exit 0
      fi
      echo "error: verify failed for .claude/skills or .claude/agents" >&2
      exit 1
    fi
    if ! $FORCE && has_active_path "$CURSOR_SKILLS"; then
      echo "error: coexistence guard: .cursor/skills exists; Cursor cross-loads .claude/skills. Remove .cursor/skills or re-run with --force" >&2
      exit 1
    fi
    sync_flat_index "$CLAUDE_SKILLS" "$TMP_LIST" "claude"
    sync_dir_link "$CLAUDE_AGENTS" "$AGENTS_SRC" "claude agents"
    echo "note: this proves filesystem links, not Claude Code runtime skill discovery"
    ;;
esac

if ! $DRY_RUN && ! $VERIFY_ONLY && [[ "${B3_SKIP_MODEL_INIT:-}" != "1" ]]; then
  MODEL_PREF_STATUS="$(init_personal_models_file "$ROOT" "" "false" "true")"
  print_personal_models_status "$ROOT" "$MODEL_PREF_STATUS" "true"
fi
