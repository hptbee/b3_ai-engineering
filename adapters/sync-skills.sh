#!/usr/bin/env bash
# Symlink canonical .cursor/skills to other-host discovery paths.
# Cursor does not need this — skills already live in .cursor/skills.
# Usage: ./adapters/sync-skills.sh [--dry-run] [--verify] codex|claude|all
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
  all)
    link_skills codex "${ROOT}/.agents/skills" "../.cursor/skills"
    link_skills claude "${ROOT}/.claude/skills" "../.cursor/skills"
    ;;
  "")
    echo "usage: $0 [--dry-run] [--verify] codex|claude|all" >&2
    exit 1
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac
