#!/usr/bin/env bash
# Symlink portable skills/ to host-specific discovery paths.
# Usage: ./adapters/sync-skills.sh [--dry-run] cursor|codex|claude|all

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="${ROOT}/skills"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

TARGET="${1:-}"

link_skills() {
  local host="$1"
  local dest="$2"

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
    if [[ "$current" == "../skills" || "$current" == "skills" ]]; then
      echo "ok: $dest already linked for $host"
      return 0
    fi
    echo "warn: $dest is a symlink to $current — skipping $host" >&2
    return 0
  fi

  if $DRY_RUN; then
    echo "dry-run: ln -s ../skills $dest"
  else
    ln -s ../skills "$dest"
    echo "linked: $dest → ../skills ($host)"
  fi
}

case "$TARGET" in
  cursor)
    link_skills cursor "${ROOT}/.cursor/skills"
    ;;
  codex)
    link_skills codex "${ROOT}/.agents/skills"
    ;;
  claude)
    link_skills claude "${ROOT}/.claude/skills"
    ;;
  all)
    link_skills cursor "${ROOT}/.cursor/skills"
    link_skills codex "${ROOT}/.agents/skills"
    link_skills claude "${ROOT}/.claude/skills"
    ;;
  "")
    echo "usage: $0 [--dry-run] cursor|codex|claude|all" >&2
    exit 1
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac
