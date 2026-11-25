#!/usr/bin/env bash
# Attach a separate product repository to this B3 checkout without copying B3 skills.
# Usage: ./adapters/install-product.sh --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity] [--dry-run]

set -euo pipefail

PRODUCT_ROOT=""
B3_HOME=""
HOST_NAME="cursor"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-root) PRODUCT_ROOT="$2"; shift 2 ;;
    --b3-home) B3_HOME="$2"; shift 2 ;;
    --host) HOST_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$HOST_NAME" in
  cursor|codex|claude|antigravity) ;;
  *) echo "error: invalid --host '$HOST_NAME' (expected cursor|codex|claude|antigravity)" >&2; exit 1 ;;
esac

[[ -n "$PRODUCT_ROOT" ]] || { echo "error: --product-root is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/global-common.sh
source "${SCRIPT_DIR}/lib/global-common.sh"
if [[ -z "$B3_HOME" ]]; then
  B3_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  B3_HOME="$(cd "$B3_HOME" && pwd)"
fi
PRODUCT_ROOT="$(cd "$PRODUCT_ROOT" && pwd)"

WORKFLOW="${B3_HOME}/workflows/ship.md"
COMMANDS_SRC="${B3_HOME}/commands"
TEMPLATE="${COMMANDS_SRC}/b3-ship.md"
CURSOR_README_TEMPLATE="${SCRIPT_DIR}/product-cursor-readme.md"
AGENTS_MD_TEMPLATE="${SCRIPT_DIR}/product-agents.md"
CLAUDE_MD_TEMPLATE="${SCRIPT_DIR}/product-claude.md"
SKILLS_SRC="${B3_HOME}/skills"
AGENTS_SRC="${B3_HOME}/agents"
CMD_SKILLS_SRC="${B3_HOME}/adapters/command-skills"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "error: missing template: $TEMPLATE" >&2; exit 1; }
[[ -n "$({ find "$SKILLS_SRC" -name 'SKILL.md' -type f -print 2>/dev/null || true; } | head -n 1)" ]] || {
  echo "error: B3_HOME has no SKILL.md under skills: $SKILLS_SRC" >&2; exit 1
}

PRODUCT_SKILLS="${PRODUCT_ROOT}/.cursor/skills"
COMMAND_DEST="${PRODUCT_ROOT}/.cursor/commands/b3-ship.md"
HOME_DEST="${PRODUCT_ROOT}/.b3/home"
AGENTS_DEST="${PRODUCT_ROOT}/.agents/skills"
CLAUDE_SKILLS_DEST="${PRODUCT_ROOT}/.claude/skills"
CLAUDE_AGENTS_DEST="${PRODUCT_ROOT}/.claude/agents"
AGENTS_MD_DEST="${PRODUCT_ROOT}/AGENTS.md"
CLAUDE_MD_DEST="${PRODUCT_ROOT}/CLAUDE.md"
CURSOR_README_DEST="${PRODUCT_ROOT}/.cursor/README.md"

if [[ -d "$PRODUCT_SKILLS" ]] && [[ -n "$({ find "$PRODUCT_SKILLS" -name 'SKILL.md' -type f -print 2>/dev/null || true; } | head -n 1)" ]]; then
  echo "error: product already has SKILL.md under .cursor/skills; refusing to install a duplicate skill tree" >&2
  exit 1
fi

if [[ "$HOST_NAME" == "cursor" ]]; then
  if [[ -e "$AGENTS_DEST" || -L "$AGENTS_DEST" ]]; then
    echo "error: product has .agents/skills; Cursor would duplicate discovery" >&2
    exit 1
  fi
  if [[ -e "$CLAUDE_SKILLS_DEST" || -L "$CLAUDE_SKILLS_DEST" ]]; then
    echo "error: product has .claude/skills; Cursor would duplicate discovery" >&2
    exit 1
  fi
fi

if [[ -f "$COMMAND_DEST" ]] && ! cmp -s "$COMMAND_DEST" "$TEMPLATE"; then
  echo "error: refusing to overwrite existing $COMMAND_DEST (differs from template)" >&2
  exit 1
fi

if [[ -f "$HOME_DEST" ]]; then
  EXISTING_HOME="$(tr -d '\r\n' < "$HOME_DEST")"
  if [[ "$EXISTING_HOME" != "$B3_HOME" ]]; then
    echo "error: refusing to overwrite $HOME_DEST (points to $EXISTING_HOME, requested $B3_HOME)" >&2
    exit 1
  fi
fi

skill_name_from_file() {
  local f="$1"
  local name
  name="$(awk 'BEGIN{FS=": "} /^name:/{gsub(/[\r[:space:]]/,"",$2); print $2; exit}' "$f")"
  if [[ -n "$name" ]]; then echo "$name"; else basename "$(dirname "$f")"; fi
}

link_target_ok() {
  local dest="$1" expected="$2"
  [[ -L "$dest" ]] || return 1
  local rd re
  rd="$(cd -P "$dest" 2>/dev/null && pwd || true)"
  re="$(cd -P "$expected" 2>/dev/null && pwd || true)"
  [[ -n "$rd" && "$rd" == "$re" ]]
}

install_link() {
  local dest="$1" target="$2"
  if [[ -L "$dest" ]]; then
    if link_target_ok "$dest" "$target"; then return 0; fi
    echo "error: refusing to replace existing link $dest" >&2; exit 1
  elif [[ -e "$dest" ]]; then
    echo "error: refusing to replace existing $dest" >&2; exit 1
  fi
  ln -s "$target" "$dest"
}

install_flat_skills() {
  local dest_root="$1"
  if [[ -L "$dest_root" ]]; then
    rm "$dest_root"
  elif [[ -e "$dest_root" && ! -d "$dest_root" ]]; then
    echo "error: refusing to replace existing $dest_root" >&2; exit 1
  fi
  mkdir -p "$dest_root"
  while IFS= read -r sf; do
    [[ -n "$sf" ]] || continue
    local name dir
    name="$(skill_name_from_file "$sf")"
    dir="$(dirname "$sf")"
    install_link "${dest_root}/${name}" "$dir"
  done < <(
    find "$SKILLS_SRC" -name 'SKILL.md' -type f | sort
    if [[ -d "$CMD_SKILLS_SRC" ]]; then
      find "$CMD_SKILLS_SRC" -name 'SKILL.md' -type f | sort
    fi
  )
}

update_b3_gitignore() {
  local gi="${PRODUCT_ROOT}/.gitignore"
  if [[ ! -f "$gi" ]]; then
    printf '# B3: commit .b3/home; keep run checkpoints and local model preferences private\n.b3/ship/\n.b3/research-ship/\n.b3/pr-feedback/\n.b3/models.md\n' > "$gi"
    echo "created"
    return
  fi
  local has_ship=false has_research=false has_prfb=false has_models=false
  grep -Eq '^[[:space:]]*\.b3/ship/[[:space:]]*$' "$gi" && has_ship=true
  grep -Eq '^[[:space:]]*\.b3/research-ship/[[:space:]]*$' "$gi" && has_research=true
  grep -Eq '^[[:space:]]*\.b3/pr-feedback/[[:space:]]*$' "$gi" && has_prfb=true
  grep -Eq '^[[:space:]]*\.b3/models\.md[[:space:]]*$' "$gi" && has_models=true
  if $has_ship && $has_research && $has_prfb && $has_models; then
    echo "present"
    return
  fi
  local missing=()
  $has_ship || missing+=(".b3/ship/")
  $has_research || missing+=(".b3/research-ship/")
  $has_prfb || missing+=(".b3/pr-feedback/")
  $has_models || missing+=(".b3/models.md")

  if grep -Eq '^[[:space:]]*\.b3/[[:space:]]*$' "$gi"; then
    local tmp="${gi}.b3tmp"
    local add_s=1 add_r=1 add_p=1 add_m=1
    $has_ship && add_s=0
    $has_research && add_r=0
    $has_prfb && add_p=0
    $has_models && add_m=0
    LC_ALL=C awk -v add_s="$add_s" -v add_r="$add_r" -v add_p="$add_p" -v add_m="$add_m" '
      /^[[:space:]]*\.b3\/[[:space:]]*$/ {
        if (add_s) print ".b3/ship/"
        if (add_r) print ".b3/research-ship/"
        if (add_p) print ".b3/pr-feedback/"
        if (add_m) print ".b3/models.md"
        next
      }
      { print }
    ' "$gi" > "$tmp" && mv "$tmp" "$gi"
    echo "upgraded"
    return
  fi
  if $has_ship || $has_research || $has_prfb || $has_models; then
    {
      echo ""
      printf '%s\n' "${missing[@]}"
    } >> "$gi"
    echo "upgraded"
    return
  fi
  printf '\n# B3: commit .b3/home; keep run checkpoints and local model preferences private\n.b3/ship/\n.b3/research-ship/\n.b3/pr-feedback/\n.b3/models.md\n' >> "$gi"
  echo "appended"
}

update_host_gitignore() {
  local lines=()
  case "$HOST_NAME" in
    codex|antigravity) lines=(".agents/skills") ;;
    claude) lines=(".claude/skills" ".claude/agents") ;;
    *) echo "n/a"; return ;;
  esac
  local gi="${PRODUCT_ROOT}/.gitignore"
  if [[ ! -f "$gi" ]]; then
    {
      echo "# B3: local host links (do not commit)"
      printf '%s\n' "${lines[@]}"
    } > "$gi"
    echo "created"
    return
  fi
  local missing=() line
  for line in "${lines[@]}"; do
    if ! grep -Eq "^[[:space:]]*$(printf '%s' "$line" | sed 's/[.[\*^$()+?{|]/\\&/g')[[:space:]]*$" "$gi"; then
      missing+=("$line")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "present"
    return
  fi
  {
    echo ""
    echo "# B3: local host links (do not commit)"
    printf '%s\n' "${missing[@]}"
  } >> "$gi"
  echo "appended"
}

if $DRY_RUN; then
  echo "dry-run: write $HOME_DEST = $B3_HOME"
  if [[ -f "$COMMAND_DEST" ]]; then echo "dry-run: keep existing $COMMAND_DEST (matches template)"
  else echo "dry-run: write $COMMAND_DEST from $TEMPLATE"; fi
  if [[ -f "$AGENTS_MD_DEST" ]]; then echo "dry-run: keep existing $AGENTS_MD_DEST"
  elif [[ -f "$AGENTS_MD_TEMPLATE" ]]; then echo "dry-run: write $AGENTS_MD_DEST from $AGENTS_MD_TEMPLATE"; fi
  if [[ "$HOST_NAME" == "claude" ]]; then
    if [[ -f "$CLAUDE_MD_DEST" ]]; then echo "dry-run: keep existing $CLAUDE_MD_DEST"
    elif [[ -f "$CLAUDE_MD_TEMPLATE" ]]; then echo "dry-run: write $CLAUDE_MD_DEST from $CLAUDE_MD_TEMPLATE"; fi
  fi
  echo "dry-run: gitignore .b3/ship/, .b3/research-ship/, and .b3/models.md (see update_b3_gitignore)"
  if [[ -d "$COMMANDS_SRC" ]]; then
    for src in "$COMMANDS_SRC"/*.md; do
      [[ -f "$src" ]] || continue
      base="$(basename "$src")"
      [[ "$base" == "README.md" || "$base" == "b3-ship.md" ]] && continue
      [[ -f "${PRODUCT_ROOT}/.cursor/commands/${base}" ]] || echo "dry-run: copy command $base"
    done
  fi
  case "$HOST_NAME" in
    codex|antigravity)
      echo "dry-run: gitignore .agents/skills"
      echo "dry-run: flatten $AGENTS_DEST (one symlink per skill + command skills)"
      ;;
    claude)
      echo "dry-run: gitignore .claude/skills and .claude/agents"
      echo "dry-run: flatten $CLAUDE_SKILLS_DEST (one symlink per skill + command skills)"
      echo "dry-run: symlink $CLAUDE_AGENTS_DEST -> $AGENTS_SRC"
      ;;
    cursor)
      [[ -f "$CURSOR_README_TEMPLATE" ]] && echo "dry-run: write $CURSOR_README_DEST"
      ;;
  esac
  MODEL_DRY_STATUS="$(init_personal_models_file "$B3_HOME" "" "true" "false")"
  case "$MODEL_DRY_STATUS" in
    kept:*) echo "dry-run: keep existing personal model preferences ${MODEL_DRY_STATUS#kept:}" ;;
    dry-run:*) echo "dry-run: initialize personal model preferences at ${MODEL_DRY_STATUS#dry-run:} from ${B3_HOME}/config/models.example.md" ;;
  esac
  exit 0
fi

IGNORE_PLAN="$(update_b3_gitignore)"
SKILL_IGNORE_PLAN="$(update_host_gitignore)"

mkdir -p "${PRODUCT_ROOT}/.b3" "${PRODUCT_ROOT}/.cursor/commands"
[[ -f "$HOME_DEST" ]] || printf '%s' "$B3_HOME" > "$HOME_DEST"
[[ -f "$COMMAND_DEST" ]] || cp "$TEMPLATE" "$COMMAND_DEST"
if [[ ! -f "$AGENTS_MD_DEST" && -f "$AGENTS_MD_TEMPLATE" ]]; then
  cp "$AGENTS_MD_TEMPLATE" "$AGENTS_MD_DEST"
fi
if [[ "$HOST_NAME" == "claude" && ! -f "$CLAUDE_MD_DEST" && -f "$CLAUDE_MD_TEMPLATE" ]]; then
  cp "$CLAUDE_MD_TEMPLATE" "$CLAUDE_MD_DEST"
fi

if [[ -d "$COMMANDS_SRC" ]]; then
  for src in "$COMMANDS_SRC"/*.md; do
    [[ -f "$src" ]] || continue
    base="$(basename "$src")"
    [[ "$base" == "README.md" || "$base" == "b3-ship.md" ]] && continue
    dest="${PRODUCT_ROOT}/.cursor/commands/${base}"
    [[ -f "$dest" ]] || cp "$src" "$dest"
  done
  if [[ "$HOST_NAME" == "cursor" && -f "$CURSOR_README_TEMPLATE" ]]; then
    cp "$CURSOR_README_TEMPLATE" "$CURSOR_README_DEST"
  fi
fi

case "$HOST_NAME" in
  codex|antigravity)
    install_flat_skills "$AGENTS_DEST"
    ;;
  claude)
    install_flat_skills "$CLAUDE_SKILLS_DEST"
    if [[ -d "$AGENTS_SRC" ]]; then
      mkdir -p "$(dirname "$CLAUDE_AGENTS_DEST")"
      install_link "$CLAUDE_AGENTS_DEST" "$AGENTS_SRC"
    fi
    ;;
esac

MODEL_PREF_STATUS="$(init_personal_models_file "$B3_HOME" "" "false" "false")"

echo "installed B3 pointer in $PRODUCT_ROOT"
echo "B3_HOME=$B3_HOME"
echo "command=$COMMAND_DEST"
echo "agents.md=$AGENTS_MD_DEST"
[[ "$HOST_NAME" == "claude" ]] && echo "claude.md=$CLAUDE_MD_DEST"
echo "gitignore.b3=$IGNORE_PLAN"
echo "gitignore.skills=$SKILL_IGNORE_PLAN"
echo "model_preferences=$MODEL_PREF_STATUS"
echo "host=$HOST_NAME"
case "$HOST_NAME" in
  codex) echo "skills=$AGENTS_DEST (flattened symlinks + \$b3-ship; gitignored, not copied)" ;;
  antigravity) echo "skills=$AGENTS_DEST (flattened symlinks + command skills; gitignored, not copied; use adapters/antigravity/install-plugin.sh if Cursor also opens this repo)" ;;
  claude) echo "skills=$CLAUDE_SKILLS_DEST (flattened symlinks + command skills) + $CLAUDE_AGENTS_DEST -> $AGENTS_SRC (gitignored, not copied)" ;;
  cursor) echo "skills=user-level ~/.cursor/skills/<name> via adapters/cursor/install-global.sh (not copied into product)" ;;
esac
echo "note: this proves files were written, not host slash-command or skill discovery"
