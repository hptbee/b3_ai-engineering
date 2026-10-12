#!/usr/bin/env bash
# Attach B3 to a product repository without copying skills.
# Usage: ./adapters/install-product.sh --product-root PATH [--b3-home PATH] [--host cursor|codex|claude] [--dry-run]
# All refusal checks run before any write. Existing autodev.md / .b3/home are not overwritten.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_ROOT=""
B3_HOME="$ROOT"
HOST="cursor"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-root) PRODUCT_ROOT="${2:-}"; shift 2 ;;
    --b3-home) B3_HOME="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PRODUCT_ROOT" ]]; then
  echo "usage: $0 --product-root PATH [--b3-home PATH] [--host cursor|codex|claude] [--dry-run]" >&2
  exit 1
fi

B3_HOME="$(cd "$B3_HOME" && pwd)"
PRODUCT_ROOT="$(cd "$PRODUCT_ROOT" && pwd)"
WORKFLOW="${B3_HOME}/workflows/autonomous-development.md"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/product-autodev.md"
SKILLS="${B3_HOME}/.cursor/skills"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "error: B3_HOME missing workflow: $WORKFLOW" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "error: missing template: $TEMPLATE" >&2
  exit 1
fi
if [[ "$(find "$SKILLS" -name 'SKILL.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -lt 1 ]]; then
  echo "error: B3_HOME has no SKILL.md under .cursor/skills" >&2
  exit 1
fi

PRODUCT_SKILLS="${PRODUCT_ROOT}/.cursor/skills"
COMMAND_DEST="${PRODUCT_ROOT}/.cursor/commands/autodev.md"
HOME_DEST="${PRODUCT_ROOT}/.b3/home"
AGENTS_DEST="${PRODUCT_ROOT}/.agents/skills"
CLAUDE_DEST="${PRODUCT_ROOT}/.claude/skills"

if [[ -d "$PRODUCT_SKILLS" ]] && [[ "$(find "$PRODUCT_SKILLS" -name 'SKILL.md' -type f 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]]; then
  echo "error: product already has SKILL.md under .cursor/skills; refusing duplicate skill tree" >&2
  exit 1
fi

if [[ "$HOST" == "cursor" ]]; then
  if [[ -e "$AGENTS_DEST" ]]; then
    echo "error: product has .agents/skills; Cursor would duplicate discovery" >&2
    exit 1
  fi
  if [[ -e "$CLAUDE_DEST" ]]; then
    echo "error: product has .claude/skills; Cursor would duplicate discovery" >&2
    exit 1
  fi
fi

if [[ -f "$COMMAND_DEST" ]]; then
  if ! cmp -s "$COMMAND_DEST" "$TEMPLATE"; then
    echo "error: refusing to overwrite existing $COMMAND_DEST (differs from template). Move it aside and re-run" >&2
    exit 1
  fi
fi

if [[ -f "$HOME_DEST" ]]; then
  existing_home="$(tr -d '\r\n' < "$HOME_DEST")"
  if [[ "$existing_home" != "$B3_HOME" ]]; then
    echo "error: refusing to overwrite $HOME_DEST (points to $existing_home, requested $B3_HOME)" >&2
    exit 1
  fi
fi

LINK_DEST=""
[[ "$HOST" == "codex" ]] && LINK_DEST="$AGENTS_DEST"
[[ "$HOST" == "claude" ]] && LINK_DEST="$CLAUDE_DEST"
if [[ -n "$LINK_DEST" && ( -e "$LINK_DEST" || -L "$LINK_DEST" ) ]]; then
  echo "error: refusing to replace existing $LINK_DEST" >&2
  exit 1
fi

GI="${PRODUCT_ROOT}/.gitignore"
if [[ -f "$GI" ]] && grep -qE '^\s*\.b3/\s*$' "$GI"; then
  IGNORE_PLAN=present
elif [[ -f "$GI" ]]; then
  IGNORE_PLAN=append
else
  IGNORE_PLAN=create
fi

if $DRY_RUN; then
  echo "dry-run: write $HOME_DEST = $B3_HOME"
  if [[ -f "$COMMAND_DEST" ]]; then
    echo "dry-run: keep existing $COMMAND_DEST (matches template)"
  else
    echo "dry-run: write $COMMAND_DEST from $TEMPLATE"
  fi
  echo "dry-run: gitignore .b3/ ($IGNORE_PLAN)"
  [[ -n "$LINK_DEST" ]] && echo "dry-run: ln -s $SKILLS $LINK_DEST"
  exit 0
fi

mkdir -p "${PRODUCT_ROOT}/.b3" "${PRODUCT_ROOT}/.cursor/commands"
if [[ ! -f "$HOME_DEST" ]]; then
  printf '%s' "$B3_HOME" > "$HOME_DEST"
fi
if [[ ! -f "$COMMAND_DEST" ]]; then
  cp "$TEMPLATE" "$COMMAND_DEST"
fi

if [[ "$IGNORE_PLAN" == "append" ]]; then
  printf '\n# B3 autonomous-development checkpoints (local, do not commit)\n.b3/\n' >> "$GI"
elif [[ "$IGNORE_PLAN" == "create" ]]; then
  printf '# B3 autonomous-development checkpoints (local, do not commit)\n.b3/\n' > "$GI"
fi

if [[ -n "$LINK_DEST" ]]; then
  mkdir -p "$(dirname "$LINK_DEST")"
  ln -s "$SKILLS" "$LINK_DEST"
fi

echo "installed B3 pointer in $PRODUCT_ROOT"
echo "B3_HOME=$B3_HOME"
echo "command=$COMMAND_DEST"
echo "gitignore.b3=$IGNORE_PLAN"
echo "host=$HOST"
echo "note: this proves files were written, not host slash-command or skill discovery"
