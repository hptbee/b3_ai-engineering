#!/usr/bin/env bash
# Symlink canonical .cursor/skills to other-host discovery paths.
# Cursor does not need this — skills already live in .cursor/skills.
# Usage: ./adapters/sync-skills.sh [--dry-run] codex|claude|all

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="${ROOT}/.cursor/skills"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

TARGET="${1:-}"

link_skills() {
  local host="$1"
  local dest="$2"
  local rel="$3"

  if [[ ! -d "$SKILLS_SRC" ]]; then
    echo "error: skills source not found: $SKILLS_SRC" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "warn: $dest exists and is not a symlink — skipping $host" >&2
    return 0
  fi

  if [[ -L "$dest" ]]; then
    local current
    current="$(readlink "$dest")"
    if [[ "$current" == "$rel" ]]; then
      echo "ok: $dest already linked for $host"
      return 0
    fi
    echo "warn: $dest is a symlink to $current — skipping $host" >&2
    return 0
  fi

  if $DRY_RUN; then
    echo "dry-run: ln -s $rel $dest"
  else
    ln -s "$rel" "$dest"
    echo "linked: $dest → $rel ($host)"
  fi
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
    echo "usage: $0 [--dry-run] codex|claude|all" >&2
    exit 1
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac
