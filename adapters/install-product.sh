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
COMMAND_SKILLS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-command-skills"

skill_name_from_file() {
  awk 'BEGIN{FS=": "} /^name:/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$1"
}

link_target_ok() {
  local dest="$1" expected="$2"
  [[ -L "$dest" ]] || return 1
  local existing
  existing="$(cd "$(dirname "$dest")" && cd "$(readlink "$dest")" && pwd)"
  [[ "$existing" == "$expected" ]]
}

install_skill_link() {
  local dest="$1" target="$2"
  if [[ -e "$dest" || -L "$dest" ]]; then
    if link_target_ok "$dest" "$target"; then
      return 0
    fi
    echo "error: refusing to replace existing $dest" >&2
    exit 1
  fi
  ln -s "$target" "$dest"
}

install_codex_skill_index() {
  local dest_root="$1" skills_src="$2" command_src="$3"
  if [[ -L "$dest_root" ]]; then
    rm "$dest_root"
  elif [[ -e "$dest_root" && ! -d "$dest_root" ]]; then
    echo "error: refusing to replace existing $dest_root" >&2
    exit 1
  fi
  mkdir -p "$dest_root"
  local skill_md src_dir name dest
  while IFS= read -r skill_md; do
    [[ -n "$skill_md" ]] || continue
    name="$(skill_name_from_file "$skill_md")"
    [[ -n "$name" ]] || name="$(basename "$(dirname "$skill_md")")"
    src_dir="$(cd "$(dirname "$skill_md")" && pwd)"
    dest="${dest_root}/${name}"
    install_skill_link "$dest" "$src_dir"
  done < <(find "$skills_src" -name 'SKILL.md' -type f)
  if [[ -d "$command_src" ]]; then
    local cmd_dir
    for cmd_dir in "$command_src"/*; do
      [[ -d "$cmd_dir" && -f "$cmd_dir/SKILL.md" ]] || continue
      install_skill_link "${dest_root}/$(basename "$cmd_dir")" "$(cd "$cmd_dir" && pwd)"
    done
  fi
}

B3_COMMANDS="${B3_HOME}/.cursor/commands"
CURSOR_README_TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/product-cursor-readme.md"
AGENTS_MD_TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/product-agents.md"
CURSOR_README_DEST="${PRODUCT_ROOT}/.cursor/README.md"
AGENTS_MD_DEST="${PRODUCT_ROOT}/AGENTS.md"

update_b3_gitignore() {
  local gi="$1"
  local block=$'# B3: commit .b3/home; keep autodev checkpoints local\n.b3/autodev/\n'
  if [[ ! -f "$gi" ]]; then
    printf '%s' "$block" > "$gi"
    echo created
    return
  fi
  if grep -qE '^\s*\.b3/autodev/\s*$' "$gi"; then
    echo present
    return
  fi
  if grep -qE '^\s*\.b3/\s*$' "$gi"; then
    sed -i.bak -E 's/^[[:space:]]*\.b3\/[[:space:]]*$/.b3\/autodev\//' "$gi" && rm -f "${gi}.bak"
    echo upgraded
    return
  fi
  printf '\n%s' "$block" >> "$gi"
  echo appended
}

update_host_skill_gitignore() {
  local gi="$1"
  local host="$2"
  local line=""
  [[ "$host" == "codex" ]] && line=".agents/skills"
  [[ "$host" == "claude" ]] && line=".claude/skills"
  if [[ -z "$line" ]]; then
    echo n/a
    return
  fi
  if [[ ! -f "$gi" ]]; then
    printf '# B3: local host skill link\n%s\n' "$line" > "$gi"
    echo created
    return
  fi
  if grep -qE "^[[:space:]]*$(printf '%s' "$line" | sed 's/[.[\*^$()+?{|]/\\&/g')[[:space:]]*$" "$gi"; then
    echo present
    return
  fi
  printf '\n# B3: local host skill link (do not commit)\n%s\n' "$line" >> "$gi"
  echo appended
}

GI="${PRODUCT_ROOT}/.gitignore"
IGNORE_PLAN=dry-run
SKILL_IGNORE_PLAN=dry-run
if ! $DRY_RUN; then
  IGNORE_PLAN="$(update_b3_gitignore "$GI")"
  SKILL_IGNORE_PLAN="$(update_host_skill_gitignore "$GI" "$HOST")"
fi

if $DRY_RUN; then
  echo "dry-run: write $HOME_DEST = $B3_HOME"
  if [[ -f "$COMMAND_DEST" ]]; then
    echo "dry-run: keep existing $COMMAND_DEST (matches template)"
  else
    echo "dry-run: write $COMMAND_DEST from $TEMPLATE"
  fi
  if [[ -f "$AGENTS_MD_DEST" ]]; then
    echo "dry-run: keep existing $AGENTS_MD_DEST"
  elif [[ -f "$AGENTS_MD_TEMPLATE" ]]; then
    echo "dry-run: write $AGENTS_MD_DEST from $AGENTS_MD_TEMPLATE"
  fi
  echo "dry-run: gitignore .b3/autodev/ ($IGNORE_PLAN)"
  [[ "$HOST" == "codex" ]] && echo "dry-run: gitignore .agents/skills"
  [[ "$HOST" == "claude" ]] && echo "dry-run: gitignore .claude/skills"
  if [[ "$HOST" == "codex" ]]; then
    echo "dry-run: flatten $AGENTS_DEST (one symlink per skill + command skills)"
  elif [[ -n "$LINK_DEST" ]]; then
    echo "dry-run: ln -s $SKILLS $LINK_DEST"
  fi
  exit 0
fi

mkdir -p "${PRODUCT_ROOT}/.b3" "${PRODUCT_ROOT}/.cursor/commands"
if [[ ! -f "$HOME_DEST" ]]; then
  printf '%s' "$B3_HOME" > "$HOME_DEST"
fi
if [[ ! -f "$COMMAND_DEST" ]]; then
  cp "$TEMPLATE" "$COMMAND_DEST"
fi
if [[ ! -f "$AGENTS_MD_DEST" && -f "$AGENTS_MD_TEMPLATE" ]]; then
  cp "$AGENTS_MD_TEMPLATE" "$AGENTS_MD_DEST"
fi

if [[ -d "$B3_COMMANDS" ]]; then
  for src in "$B3_COMMANDS"/*.md; do
    [[ -f "$src" ]] || continue
    base="$(basename "$src")"
    [[ "$base" == "README.md" || "$base" == "autodev.md" ]] && continue
    dest="${PRODUCT_ROOT}/.cursor/commands/${base}"
    if [[ ! -f "$dest" ]]; then
      cp "$src" "$dest"
    fi
  done
  if [[ "$HOST" == "cursor" && -f "$CURSOR_README_TEMPLATE" ]]; then
    cp "$CURSOR_README_TEMPLATE" "$CURSOR_README_DEST"
  fi
fi

if [[ "$HOST" == "codex" ]]; then
  install_codex_skill_index "$AGENTS_DEST" "$SKILLS" "$COMMAND_SKILLS_SRC"
elif [[ -n "$LINK_DEST" ]]; then
  if [[ ! -e "$LINK_DEST" && ! -L "$LINK_DEST" ]]; then
    mkdir -p "$(dirname "$LINK_DEST")"
    ln -s "$SKILLS" "$LINK_DEST"
  elif ! link_target_ok "$LINK_DEST" "$SKILLS"; then
    echo "error: refusing to replace existing $LINK_DEST" >&2
    exit 1
  fi
fi

echo "installed B3 pointer in $PRODUCT_ROOT"
echo "B3_HOME=$B3_HOME"
echo "command=$COMMAND_DEST"
echo "agents.md=$AGENTS_MD_DEST"
echo "gitignore.b3=$IGNORE_PLAN"
echo "gitignore.skills=$SKILL_IGNORE_PLAN"
echo "host=$HOST"
if [[ "$HOST" == "codex" ]]; then
  echo "skills=$AGENTS_DEST (flattened links + \$autodev; gitignored, not copied)"
elif [[ "$HOST" == "claude" ]]; then
  echo "skills=$CLAUDE_DEST -> $SKILLS (gitignored local link, not copied)"
else
  echo "skills=user-level ~/.cursor/skills/b3-ai-engineering -> $SKILLS (not copied into product)"
fi
echo "note: this proves files were written, not host slash-command or skill discovery"
