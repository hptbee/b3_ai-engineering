#!/usr/bin/env bash
# Symlink canonical .cursor/skills to other-host discovery paths.
# Cursor does not need this — skills already live in .cursor/skills.
# Usage: ./adapters/sync-skills.sh [--dry-run] [--verify] codex|claude|antigravity|all
# Exit 0 only when the destination is a working link and SKILL.md is visible.
# Filesystem success is not host skill-discovery PASS.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="${ROOT}/.cursor/skills"
DRY_RUN=false
VERIFY_ONLY=false

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verify) VERIFY_ONLY=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

TARGET="${1:-}"

skill_count() {
  local dir="$1"
  find "$dir" -name 'SKILL.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

verify_link() {
  local dest="$1"
  local expected_rel="$2"
  if [[ ! -L "$dest" ]]; then
    return 1
  fi
  local current
  current="$(readlink "$dest")"
  if [[ "$current" != "$expected_rel" ]]; then
    return 1
  fi
  if [[ "$(skill_count "$dest")" -lt 1 ]]; then
    return 1
  fi
  return 0
}

link_skills() {
  local host="$1"
  local dest="$2"
  local rel="$3"

  if [[ ! -d "$SKILLS_SRC" ]]; then
    echo "error: skills source not found: $SKILLS_SRC" >&2
    exit 1
  fi
  if [[ "$(skill_count "$SKILLS_SRC")" -lt 1 ]]; then
    echo "error: skills source has no SKILL.md: $SKILLS_SRC" >&2
    exit 1
  fi

  if $VERIFY_ONLY; then
    if verify_link "$dest" "$rel"; then
      echo "verify ok: $dest → $rel ($host); SKILL.md visible"
      return 0
    fi
    echo "error: verify failed: $dest is not a working link to $rel with SKILL.md" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -L "$dest" ]]; then
    if verify_link "$dest" "$rel"; then
      echo "ok: $dest already linked for $host"
      return 0
    fi
    echo "error: existing symlink $dest does not resolve to $rel with SKILL.md" >&2
    exit 1
  fi

  if [[ -d "$dest" ]]; then
    if [[ -n "$(find "$dest" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
      echo "error: existing non-link path with content; refusing to replace: $dest" >&2
      exit 1
    fi
    if $DRY_RUN; then
      echo "dry-run: rmdir $dest && ln -s $rel $dest"
      return 0
    fi
    rmdir "$dest"
  elif [[ -e "$dest" ]]; then
    echo "error: $dest exists and is not a symlink or directory" >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "dry-run: ln -s $rel $dest"
    return 0
  fi

  ln -s "$rel" "$dest"
  if ! verify_link "$dest" "$rel"; then
    echo "error: link created but verification failed: $dest → $rel" >&2
    exit 1
  fi
  echo "linked: $dest → $rel ($host); SKILL.md visible"
  echo "note: this proves the filesystem link, not Codex or Cursor skill discovery"
}

get_antigravity_entries() {
  local cat_dir skill_dir found
  if [[ -d "$SKILLS_SRC" ]]; then
    while IFS= read -r cat_dir; do
      [[ -n "$cat_dir" && -d "$cat_dir" ]] || continue
      found=false
      for skill_dir in "$cat_dir"/*; do
        if [[ -d "$skill_dir" && -f "${skill_dir}/SKILL.md" ]]; then
          found=true
          break
        fi
      done
      if $found; then
        printf '.cursor/skills/%s\n' "$(basename "$cat_dir")"
      fi
    done < <(find "$SKILLS_SRC" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  fi
  local cmd_dir="${ROOT}/adapters/codex-command-skills"
  if [[ -d "$cmd_dir" ]]; then
    for skill_dir in "$cmd_dir"/*; do
      if [[ -d "$skill_dir" && -f "${skill_dir}/SKILL.md" ]]; then
        printf 'adapters/codex-command-skills\n'
        break
      fi
    done
  fi
}

extract_manifest_paths() {
  local manifest="$1"
  if ! grep -q '"entries"' "$manifest"; then
    return 1
  fi
  awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /"path"[[:space:]]*:[[:space:]]*"/) {
        line = $0
        sub(/.*"path"[[:space:]]*:[[:space:]]*"/, "", line)
        sub(/".*/, "", line)
        if (line != "") print line
      }
    }
  ' "$manifest"
}

verify_antigravity_manifest() {
  local manifest="${ROOT}/.agents/skills.json"
  if [[ ! -f "$manifest" ]]; then
    echo "error: verify failed: missing manifest: $manifest" >&2
    return 1
  fi
  if jq --version >/dev/null 2>&1; then
    if ! jq -e '.entries | type == "array" and length > 0' "$manifest" >/dev/null 2>&1; then
      echo "error: verify failed: invalid JSON or missing entries in $manifest" >&2
      return 1
    fi
  elif python3 -c 'import json, sys' >/dev/null 2>&1; then
    if ! python3 -c 'import json, sys; d=json.load(sys.stdin); assert isinstance(d.get("entries"), list) and len(d["entries"]) > 0' < "$manifest" 2>/dev/null; then
      echo "error: verify failed: invalid JSON or missing entries in $manifest" >&2
      return 1
    fi
  fi

  local manifest_paths=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && manifest_paths+=("$p")
  done < <(extract_manifest_paths "$manifest")

  if [[ ${#manifest_paths[@]} -lt 1 ]]; then
    echo "error: verify failed: manifest has no path entries: $manifest" >&2
    return 1
  fi

  local total_skills=0
  local seen_names=()
  local rel resolved entry_count skill_dir skill_file fm_name dir_name existing
  for rel in "${manifest_paths[@]}"; do
    resolved="${ROOT}/${rel}"
    if [[ ! -d "$resolved" ]]; then
      echo "error: verify failed: manifest entry path not found: $rel" >&2
      return 1
    fi
    entry_count=0
    for skill_dir in "$resolved"/*; do
      [[ -d "$skill_dir" ]] || continue
      skill_file="${skill_dir}/SKILL.md"
      if [[ -f "$skill_file" ]]; then
        dir_name="$(basename "$skill_dir")"
        fm_name="$(awk 'BEGIN{FS=": "} /^name:/{gsub(/[\r[:space:]]/,"",$2); print $2; exit}' "$skill_file")"
        if [[ -z "$fm_name" || "$fm_name" != "$dir_name" ]]; then
          echo "error: verify failed: skill folder '$dir_name' does not match frontmatter name '$fm_name' in $skill_file" >&2
          return 1
        fi
        if [[ ${#seen_names[@]} -gt 0 ]]; then
          for existing in "${seen_names[@]}"; do
            if [[ "$existing" == "$fm_name" ]]; then
              echo "error: verify failed: duplicate skill name '$fm_name'" >&2
              return 1
            fi
          done
        fi
        seen_names+=("$fm_name")
        entry_count=$((entry_count + 1))
        total_skills=$((total_skills + 1))
      fi
    done
    if [[ "$entry_count" -lt 1 ]]; then
      echo "error: verify failed: manifest entry has no 1-level SKILL.md: $rel" >&2
      return 1
    fi
  done

  local exp found_exp
  while IFS= read -r exp; do
    [[ -n "$exp" ]] || continue
    found_exp=false
    for p in "${manifest_paths[@]}"; do
      if [[ "$p" == "$exp" ]]; then
        found_exp=true
        break
      fi
    done
    if ! $found_exp; then
      echo "error: verify failed: manifest missing expected entry: $exp" >&2
      return 1
    fi
  done < <(get_antigravity_entries)

  if [[ "$total_skills" -lt 1 ]]; then
    echo "error: verify failed: manifest resolved 0 skills" >&2
    return 1
  fi
  echo "$total_skills"
}

sync_antigravity() {
  local manifest="${ROOT}/.agents/skills.json"
  if [[ ! -d "$SKILLS_SRC" ]]; then
    echo "error: skills source not found: $SKILLS_SRC" >&2
    exit 1
  fi
  if [[ "$(skill_count "$SKILLS_SRC")" -lt 1 ]]; then
    echo "error: skills source has no SKILL.md: $SKILLS_SRC" >&2
    exit 1
  fi

  if $VERIFY_ONLY; then
    local count
    if count="$(verify_antigravity_manifest)"; then
      echo "verify ok: $manifest (antigravity); $count SKILL.md entries visible"
      return 0
    fi
    exit 1
  fi

  local entries=()
  local e
  while IFS= read -r e; do
    [[ -n "$e" ]] && entries+=("$e")
  done < <(get_antigravity_entries)

  if [[ ${#entries[@]} -lt 1 ]]; then
    echo "error: no 1-level skill category directories found under $SKILLS_SRC" >&2
    exit 1
  fi

  if $DRY_RUN; then
    echo "dry-run: write $manifest with ${#entries[@]} entries (${entries[*]})"
    return 0
  fi

  mkdir -p "$(dirname "$manifest")"
  {
    printf '{\n'
    printf '  "entries": [\n'
    local i comma
    for i in "${!entries[@]}"; do
      comma=","
      [[ "$i" -eq $(( ${#entries[@]} - 1 )) ]] && comma=""
      printf '    { "path": "%s" }%s\n' "${entries[$i]}" "$comma"
    done
    printf '  ]\n'
    printf '}\n'
  } > "$manifest"

  local count
  if ! count="$(verify_antigravity_manifest)"; then
    exit 1
  fi
  echo "synced: $manifest (antigravity); $count SKILL.md entries visible"
  echo "note: this proves .agents/skills.json resolves to 1-level SKILL.md entries, not Antigravity runtime discovery"
}

case "$TARGET" in
  cursor)
    echo "error: Cursor skills are canonical at .cursor/skills — nothing to sync" >&2
    exit 1
    ;;
  codex)
    link_skills codex "${ROOT}/.agents/skills" "../.cursor/skills"
    ;;
  claude)
    link_skills claude "${ROOT}/.claude/skills" "../.cursor/skills"
    ;;
  antigravity)
    sync_antigravity
    ;;
  all)
    link_skills codex "${ROOT}/.agents/skills" "../.cursor/skills"
    link_skills claude "${ROOT}/.claude/skills" "../.cursor/skills"
    ;;
  "")
    echo "usage: $0 [--dry-run] [--verify] codex|claude|antigravity|all" >&2
    exit 1
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac
