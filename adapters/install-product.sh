#!/usr/bin/env bash
# Attach a separate product repository to this B3 checkout without copying B3 skills.
# Usage: ./adapters/install-product.sh --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity|all] [--dry-run] [--force]

set -euo pipefail

PRODUCT_ROOT=""
B3_HOME=""
HOST_NAME="cursor"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product-root) PRODUCT_ROOT="$2"; shift 2 ;;
    --b3-home) B3_HOME="$2"; shift 2 ;;
    --host) HOST_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      echo "Usage: $0 --product-root <dir> [--b3-home <dir>] [--host cursor|codex|claude|antigravity|all] [--dry-run] [--force]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$HOST_NAME" in
  cursor|codex|claude|antigravity|all) ;;
  *) echo "error: invalid --host '$HOST_NAME' (expected cursor|codex|claude|antigravity|all)" >&2; exit 1 ;;
esac

[[ -n "$PRODUCT_ROOT" ]] || { echo "error: --product-root is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/global-common.sh
source "${SCRIPT_DIR}/lib/global-common.sh"
B3_HOME="$(resolve_b3_home "$B3_HOME" "${SCRIPT_DIR}/..")"
PRODUCT_ROOT="$(canon_existing_dir "$PRODUCT_ROOT")"

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

USE_CURSOR=false
USE_FLAT_AGENTS=false
USE_CLAUDE=false
case "$HOST_NAME" in
  cursor) USE_CURSOR=true ;;
  codex|antigravity) USE_FLAT_AGENTS=true ;;
  claude) USE_CLAUDE=true ;;
  all) USE_CURSOR=true; USE_FLAT_AGENTS=true; USE_CLAUDE=true ;;
esac

PRODUCT_SKILLS="${PRODUCT_ROOT}/.cursor/skills"
CURSOR_DIR="${PRODUCT_ROOT}/.cursor"
CURSOR_COMMANDS_DIR="${PRODUCT_ROOT}/.cursor/commands"
COMMAND_DEST="${CURSOR_COMMANDS_DIR}/b3-ship.md"
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

if [[ "$HOST_NAME" == "cursor" ]] && ! $FORCE; then
  if [[ -e "$AGENTS_DEST" || -L "$AGENTS_DEST" ]]; then
    echo "error: product has .agents/skills; Cursor would duplicate discovery (remove it or pass --force)" >&2
    exit 1
  fi
  if [[ -e "$CLAUDE_SKILLS_DEST" || -L "$CLAUDE_SKILLS_DEST" ]]; then
    echo "error: product has .claude/skills; Cursor would duplicate discovery (remove it or pass --force)" >&2
    exit 1
  fi
fi

assert_regular_dir_or_missing "${PRODUCT_ROOT}/.b3" ".b3"
assert_regular_file_or_missing "$HOME_DEST" ".b3/home"
REWRITE_HOME=false
if [[ ! -f "$HOME_DEST" ]] || $FORCE; then
  REWRITE_HOME=true
fi
if [[ -f "$HOME_DEST" ]]; then
  EXISTING_HOME="$(tr -d '\r\n' < "$HOME_DEST")"
  EXISTING_HOME="${EXISTING_HOME#"${EXISTING_HOME%%[![:space:]]*}"}"
  EXISTING_HOME="${EXISTING_HOME%"${EXISTING_HOME##*[![:space:]]}"}"
  if [[ -z "$EXISTING_HOME" ]]; then
    if ! $FORCE; then
      echo "error: refusing to overwrite empty or invalid $HOME_DEST (pass --force to update)" >&2
      exit 1
    fi
    REWRITE_HOME=true
  else
    SAME_HOME=false
    if [[ "$EXISTING_HOME" == /* || "$EXISTING_HOME" =~ ^[A-Za-z]:[/\\] ]]; then
      EXISTING_CANON="$(canon_existing_dir "$EXISTING_HOME" 2>/dev/null || printf '%s' "$EXISTING_HOME")"
      REQ_CANON="$(canon_existing_dir "$B3_HOME" 2>/dev/null || printf '%s' "$B3_HOME")"
      if [[ "$(norm_cmp_path "$EXISTING_CANON")" == "$(norm_cmp_path "$REQ_CANON")" ]]; then
        SAME_HOME=true
      fi
    fi
    if ! $SAME_HOME; then
      if ! $FORCE; then
        echo "error: refusing to overwrite $HOME_DEST (points to $EXISTING_HOME, requested $B3_HOME; pass --force to update)" >&2
        exit 1
      fi
      REWRITE_HOME=true
    fi
  fi
fi

CMD_BODY_LF=""
CMD_BODY_SHA=""
CMD_RENDERED=""

build_canonical_cmd_payload() {
  local src="$1" raw
  raw="$(tr -d '\r' < "$src")"
  while [[ "$raw" == *$'\n' ]]; do
    raw="${raw%$'\n'}"
  done
  CMD_BODY_LF="${raw}"$'\n'
  CMD_BODY_SHA="$(sha256_text "$CMD_BODY_LF")"
  CMD_RENDERED="${CMD_BODY_LF}<!-- b3-managed-command: sha256=${CMD_BODY_SHA} -->"$'\n'
}

managed_command_state() {
  local dest="$1" body_lf="$2" rendered="$3"
  if [[ ! -f "$dest" ]]; then
    printf '%s' "missing"
    return 0
  fi
  local dest_lf
  dest_lf="$(awk '{ sub(/\r$/, ""); printf "%s\n", $0 } END { printf "X" }' "$dest")"
  dest_lf="${dest_lf%X}"
  if [[ "$dest_lf" == "$rendered" ]]; then
    printf '%s' "current"
    return 0
  fi
  local marker_re='^<!-- b3-managed-command: sha256=([0-9a-f]{64}) -->$'
  local last_line
  last_line="$(awk 'NF { last = $0 } END { sub(/\r$/, "", last); printf "%s", last }' "$dest")"
  if [[ "$last_line" =~ $marker_re ]]; then
    local rec_sha="${BASH_REMATCH[1]}"
    local prefix_lf
    prefix_lf="$(awk '
      { sub(/\r$/, ""); lines[NR] = $0 }
      END {
        end_idx = NR
        while (end_idx > 0 && lines[end_idx] == "") end_idx--
        if (end_idx > 0) end_idx--
        for (i = 1; i <= end_idx; i++) printf "%s\n", lines[i]
        printf "X"
      }
    ' "$dest")"
    prefix_lf="${prefix_lf%X}"
    if [[ "$(sha256_text "$prefix_lf")" == "$rec_sha" ]]; then
      printf '%s' "managed-stale"
    else
      printf '%s' "user-modified"
    fi
    return 0
  fi
  local dest_trimmed="$dest_lf"
  while [[ "$dest_trimmed" == *$'\n' ]]; do
    dest_trimmed="${dest_trimmed%$'\n'}"
  done
  if [[ "${dest_trimmed}"$'\n' == "$body_lf" ]]; then
    printf '%s' "legacy-unmodified"
  else
    printf '%s' "user-modified"
  fi
}

CMD_SRCS=()
CMD_DESTS=()
CMD_STATES=()
CMD_PAYLOADS=()

if $USE_CURSOR; then
  assert_regular_dir_or_missing "$CURSOR_DIR" ".cursor"
  assert_regular_dir_or_missing "$CURSOR_COMMANDS_DIR" ".cursor/commands"
  assert_regular_file_or_missing "$CURSOR_README_DEST" ".cursor/README.md"
  if [[ -d "$COMMANDS_SRC" ]]; then
    while IFS= read -r src; do
      [[ -n "$src" ]] || continue
      base="$(basename "$src")"
      [[ "$base" == "README.md" ]] && continue
      dest="${CURSOR_COMMANDS_DIR}/${base}"
      assert_regular_file_or_missing "$dest" "$base"
      build_canonical_cmd_payload "$src"
      state="$(managed_command_state "$dest" "$CMD_BODY_LF" "$CMD_RENDERED")"
      if [[ "$state" == "user-modified" ]] && ! $FORCE; then
        echo "error: refusing to overwrite modified command pointer $dest (re-run with --force to overwrite)" >&2
        exit 1
      fi
      CMD_SRCS+=("$src")
      CMD_DESTS+=("$dest")
      CMD_STATES+=("$state")
      CMD_PAYLOADS+=("$CMD_RENDERED")
    done < <(find "$COMMANDS_SRC" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)
  fi
fi

install_skill_link() {
  local dest="$1" target="$2"
  if is_link_entry "$dest"; then
    if link_target_ok "$dest" "$target"; then return 0; fi
    if ! $FORCE; then
      echo "error: refusing to replace existing link $dest (pass --force to update)" >&2
      exit 1
    fi
    remove_link_only "$dest"
  elif [[ -e "$dest" ]]; then
    echo "error: refusing to replace existing $dest" >&2
    exit 1
  fi
  create_dir_link "$dest" "$target"
}

install_flat_skills() {
  local dest_root="$1"
  if is_link_entry "$dest_root"; then
    remove_link_only "$dest_root"
  elif [[ -e "$dest_root" && ! -d "$dest_root" ]]; then
    echo "error: refusing to replace existing $dest_root" >&2
    exit 1
  fi
  mkdir -p "$dest_root"
  while IFS=$'\t' read -r name dir; do
    [[ -n "$name" ]] || continue
    install_skill_link "${dest_root}/${name}" "$dir"
  done < <(
    discover_skills_tsv "$SKILLS_SRC"
    if [[ -d "$CMD_SKILLS_SRC" ]]; then
      discover_skills_tsv "$CMD_SKILLS_SRC"
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
    all) lines=(".agents/skills" ".claude/skills" ".claude/agents") ;;
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
  if $USE_CURSOR; then
    for i in "${!CMD_DESTS[@]}"; do
      case "${CMD_STATES[$i]}" in
        current) echo "dry-run: keep existing ${CMD_DESTS[$i]} (up to date)" ;;
        missing) echo "dry-run: write ${CMD_DESTS[$i]} from ${CMD_SRCS[$i]}" ;;
        *) echo "dry-run: refresh ${CMD_DESTS[$i]} from ${CMD_SRCS[$i]} (${CMD_STATES[$i]})" ;;
      esac
    done
    [[ -f "$CURSOR_README_TEMPLATE" ]] && echo "dry-run: write $CURSOR_README_DEST"
  fi
  if [[ -f "$AGENTS_MD_DEST" ]]; then echo "dry-run: keep existing $AGENTS_MD_DEST"
  elif [[ -f "$AGENTS_MD_TEMPLATE" ]]; then echo "dry-run: write $AGENTS_MD_DEST from $AGENTS_MD_TEMPLATE"; fi
  if $USE_CLAUDE; then
    if [[ -f "$CLAUDE_MD_DEST" ]]; then echo "dry-run: keep existing $CLAUDE_MD_DEST"
    elif [[ -f "$CLAUDE_MD_TEMPLATE" ]]; then echo "dry-run: write $CLAUDE_MD_DEST from $CLAUDE_MD_TEMPLATE"; fi
  fi
  echo "dry-run: gitignore .b3/ship/, .b3/research-ship/, .b3/pr-feedback/, and .b3/models.md (see update_b3_gitignore)"
  if $USE_FLAT_AGENTS; then
    echo "dry-run: gitignore .agents/skills"
    echo "dry-run: flatten $AGENTS_DEST (one link per skill + command-skills linked)"
  fi
  if $USE_CLAUDE; then
    echo "dry-run: gitignore .claude/skills and .claude/agents"
    echo "dry-run: flatten $CLAUDE_SKILLS_DEST (one link per skill + command-skills linked)"
    echo "dry-run: link $CLAUDE_AGENTS_DEST -> $AGENTS_SRC"
  fi
  MODEL_DRY_STATUS="$(init_personal_models_file "$B3_HOME" "" "true" "true")"
  case "$MODEL_DRY_STATUS" in
    kept:*) echo "dry-run: keep existing personal model preferences ${MODEL_DRY_STATUS#kept:}" ;;
    dry-run:*) echo "dry-run: initialize personal model preferences at ${MODEL_DRY_STATUS#dry-run:} from ${B3_HOME}/config/models.example.md" ;;
  esac
  exit 0
fi

IGNORE_PLAN="$(update_b3_gitignore)"
SKILL_IGNORE_PLAN="$(update_host_gitignore)"

mkdir -p "${PRODUCT_ROOT}/.b3"
if $REWRITE_HOME; then
  printf '%s' "$B3_HOME" > "$HOME_DEST"
fi
if [[ ! -f "$AGENTS_MD_DEST" && -f "$AGENTS_MD_TEMPLATE" ]]; then
  cp "$AGENTS_MD_TEMPLATE" "$AGENTS_MD_DEST"
fi
if $USE_CLAUDE && [[ ! -f "$CLAUDE_MD_DEST" && -f "$CLAUDE_MD_TEMPLATE" ]]; then
  cp "$CLAUDE_MD_TEMPLATE" "$CLAUDE_MD_DEST"
fi

if $USE_CURSOR; then
  mkdir -p "$CURSOR_COMMANDS_DIR"
  for i in "${!CMD_DESTS[@]}"; do
    if [[ "${CMD_STATES[$i]}" != "current" ]]; then
      write_lf_file "${CMD_DESTS[$i]}" "${CMD_PAYLOADS[$i]}"
    fi
  done
  if [[ -f "$CURSOR_README_TEMPLATE" ]]; then
    cp "$CURSOR_README_TEMPLATE" "$CURSOR_README_DEST"
  fi
fi

if $USE_FLAT_AGENTS; then
  install_flat_skills "$AGENTS_DEST"
fi
if $USE_CLAUDE; then
  install_flat_skills "$CLAUDE_SKILLS_DEST"
  if [[ -d "$AGENTS_SRC" ]]; then
    mkdir -p "$(dirname "$CLAUDE_AGENTS_DEST")"
    install_skill_link "$CLAUDE_AGENTS_DEST" "$AGENTS_SRC"
  fi
fi

MODEL_PREF_STATUS="$(init_personal_models_file "$B3_HOME" "" "false" "true")"

echo "installed B3 pointer in $PRODUCT_ROOT"
echo "B3_HOME=$B3_HOME"
if $USE_CURSOR; then
  echo "command=$COMMAND_DEST"
elif [[ "$HOST_NAME" == "codex" || "$HOST_NAME" == "antigravity" ]]; then
  echo "command=command-skills ($AGENTS_DEST)"
else
  echo "command=command-skills ($CLAUDE_SKILLS_DEST)"
fi
echo "agents.md=$AGENTS_MD_DEST"
$USE_CLAUDE && echo "claude.md=$CLAUDE_MD_DEST"
echo "gitignore.b3=$IGNORE_PLAN"
echo "gitignore.skills=$SKILL_IGNORE_PLAN"
echo "model_preferences=$MODEL_PREF_STATUS"
echo "host=$HOST_NAME"
case "$HOST_NAME" in
  codex) echo "skills=$AGENTS_DEST (flattened symlinks + command-skills linked incl. \$b3-ship; gitignored, not copied)" ;;
  antigravity) echo "skills=$AGENTS_DEST (flattened symlinks + command-skills linked; gitignored, not copied; use adapters/install-global.sh --host antigravity if Cursor also opens this repo)" ;;
  claude) echo "skills=$CLAUDE_SKILLS_DEST (flattened symlinks + command-skills linked) + $CLAUDE_AGENTS_DEST -> $AGENTS_SRC (gitignored, not copied)" ;;
  all) echo "skills=$AGENTS_DEST + $CLAUDE_SKILLS_DEST (flattened symlinks + command-skills linked incl. \$b3-ship) + .cursor/commands" ;;
  cursor) echo "skills=user-level ~/.cursor/skills/<name> via adapters/install-global.sh --host cursor (not copied into product)" ;;
esac
echo "note: this proves files were written, not host slash-command or skill discovery"
