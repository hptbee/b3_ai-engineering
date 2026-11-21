#!/usr/bin/env bash
# Generate a local Antigravity plugin bundle from B3 without forking source files.
# Usage: ./adapters/antigravity/install-plugin.sh [--plugin-root PATH] [--b3-home PATH] [--dry-run] [--force]
# All validation checks run before any write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B3_HOME="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLUGIN_ROOT="${HOME}/.gemini/config/plugins/b3-ai-engineering"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-root) PLUGIN_ROOT="${2:-}"; shift 2 ;;
    --b3-home) B3_HOME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$B3_HOME" ]]; then
  echo "error: B3Home not found: $B3_HOME" >&2
  exit 1
fi
B3_HOME="$(cd "$B3_HOME" && pwd)"

WORKFLOW="${B3_HOME}/workflows/autonomous-development.md"
SKILLS_SRC="${B3_HOME}/.cursor/skills"
CMD_SKILLS_SRC="${B3_HOME}/adapters/codex-command-skills"
RULES_DIR="${B3_HOME}/rules"
AGENTS_DIR="${B3_HOME}/.cursor/agents"

[[ -f "$WORKFLOW" ]] || { echo "error: B3_HOME missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -d "$SKILLS_SRC" ]] || { echo "error: B3_HOME missing .cursor/skills: $SKILLS_SRC" >&2; exit 1; }

skill_name_from_file() {
  awk 'BEGIN{FS=": "} /^name:/{gsub(/[\r[:space:]]/,"",$2); print $2; exit}' "$1"
}

strip_frontmatter() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0; started = 1; next }
    in_fm { next }
    !started && $0 == "" { next }
    { started = 1; lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] == "") n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$1"
}

render_agent() {
  local file="$1"
  local b3_home="$2"
  local base
  base="$(basename "$file")"
  awk -v file_path="$file" -v b3_home="$b3_home" -v base="$base" '
    BEGIN { in_fm = 0; done_fm = 0; cur = ""; desc_n = 0; body_n = 0; readonly_val = ""; name_val = "" }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") {
        print "error: agent missing YAML frontmatter: " file_path > "/dev/stderr"
        exit 2
      }
      in_fm = 1
      next
    }
    in_fm && $0 == "---" {
      in_fm = 0
      done_fm = 1
      next
    }
    in_fm {
      if ($0 ~ /^[a-zA-Z0-9_-]+:[[:space:]]*/) {
        split($0, parts, ":")
        cur = parts[1]
        val = substr($0, length(cur) + 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (cur == "name") {
          name_val = val
        } else if (cur == "readonly") {
          readonly_val = tolower(val)
        } else if (cur == "description") {
          desc[++desc_n] = $0
        }
      } else if (cur == "description" && ($0 ~ /^[[:space:]]+[^[:space:]]/ || $0 ~ /^[[:space:]]*$/)) {
        desc[++desc_n] = $0
      }
      next
    }
    done_fm {
      if (body_n == 0 && $0 == "") next
      body[++body_n] = $0
    }
    END {
      if (!done_fm) {
        print "error: agent frontmatter not closed: " file_path > "/dev/stderr"
        exit 2
      }
      while (desc_n > 0 && desc[desc_n] ~ /^[[:space:]]*$/) desc_n--
      while (body_n > 0 && body[body_n] ~ /^[[:space:]]*$/) body_n--
      if (name_val == "") {
        print "error: agent missing name in frontmatter: " file_path > "/dev/stderr"
        exit 2
      }
      if (desc_n == 0) {
        print "error: agent missing description in frontmatter: " file_path > "/dev/stderr"
        exit 2
      }
      if (readonly_val != "true" && readonly_val != "false") {
        print "error: agent missing boolean readonly in frontmatter: " file_path > "/dev/stderr"
        exit 2
      }
      tools = (readonly_val == "true") ? "tools: [read_file]" : "tools: [read_file, edit_file, write_file, run_command, manage_task]"
      print "---"
      print "name: " name_val
      for (i = 1; i <= desc_n; i++) print desc[i]
      print "subagent: true"
      print "mainAgent: false"
      print tools
      print "---"
      print ""
      print "<!-- Generated from " b3_home "/.cursor/agents/" base " - do not edit here -->"
      if (body_n > 0) {
        print ""
        for (i = 1; i <= body_n; i++) print body[i]
      }
    }
  ' "$file"
}

SKILL_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && SKILL_FILES+=("$f")
done < <(find "$SKILLS_SRC" -name 'SKILL.md' -type f | LC_ALL=C sort)

if [[ ${#SKILL_FILES[@]} -lt 1 ]]; then
  echo "error: B3_HOME has no SKILL.md under .cursor/skills: $SKILLS_SRC" >&2
  exit 1
fi

if [[ -d "$CMD_SKILLS_SRC" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && SKILL_FILES+=("$f")
  done < <(find "$CMD_SKILLS_SRC" -name 'SKILL.md' -type f | LC_ALL=C sort)
fi

SKILL_NAMES=()
SKILL_DIRS=()
for sf in "${SKILL_FILES[@]}"; do
  sname="$(skill_name_from_file "$sf")"
  sdir="$(cd "$(dirname "$sf")" && pwd)"
  [[ -n "$sname" ]] || sname="$(basename "$sdir")"
  if [[ ${#SKILL_NAMES[@]} -gt 0 ]]; then
    for existing in "${SKILL_NAMES[@]}"; do
      if [[ "$existing" == "$sname" ]]; then
        echo "error: duplicate skill name '$sname' at $sdir" >&2
        exit 1
      fi
    done
  fi
  SKILL_NAMES+=("$sname")
  SKILL_DIRS+=("$sdir")
done

RULE_FILES=()
while IFS= read -r rf; do
  [[ -n "$rf" ]] && RULE_FILES+=("$rf")
done < <(find "$RULES_DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)

if [[ ${#RULE_FILES[@]} -lt 1 ]]; then
  echo "error: B3_HOME has no rules under $RULES_DIR" >&2
  exit 1
fi

RULES_CONTENT="# B3 AI Engineering Rules

Generated from B3_HOME: \`${B3_HOME}\` (do not edit here).
Resolve B3_HOME from \`B3_HOME\` env, product \`.b3/home\`, or \`${B3_HOME}\`.
Precedence: \`${B3_HOME}/docs/precedence.md\`. Autodev: \`${B3_HOME}/workflows/autonomous-development.md\`. Review loop: \`${B3_HOME}/review-loop/spec.md\`."

for rf in "${RULE_FILES[@]}"; do
  stripped="$(strip_frontmatter "$rf")"
  if [[ -n "$stripped" ]]; then
    RULES_CONTENT="${RULES_CONTENT}

---

${stripped}"
  fi
done
RULES_CONTENT="${RULES_CONTENT}
"
RULES_BYTES="$(printf '%s' "$RULES_CONTENT" | wc -c | tr -d ' ')"
if [[ "$RULES_BYTES" -ge 24000 ]]; then
  echo "error: generated rules/AGENTS.md is $RULES_BYTES bytes (must stay under 24000 bytes)" >&2
  exit 1
fi

AGENT_FILES=()
while IFS= read -r af; do
  [[ -n "$af" ]] || continue
  [[ "$(basename "$af")" == "README.md" ]] && continue
  AGENT_FILES+=("$af")
done < <(find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f | LC_ALL=C sort)

if [[ ${#AGENT_FILES[@]} -lt 1 ]]; then
  echo "error: B3_HOME has no agent definitions under $AGENTS_DIR" >&2
  exit 1
fi

AGENT_BASES=()
AGENT_CONTENTS=()
for af in "${AGENT_FILES[@]}"; do
  rendered="$(render_agent "$af" "$B3_HOME")"
  AGENT_BASES+=("$(basename "$af")")
  AGENT_CONTENTS+=("$rendered")
done

if [[ -e "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
  if [[ ! -d "$PLUGIN_ROOT" || -L "$PLUGIN_ROOT" ]]; then
    echo "error: refusing to replace existing non-directory path: $PLUGIN_ROOT" >&2
    exit 1
  fi
  IS_B3_PLUGIN=false
  if [[ -f "${PLUGIN_ROOT}/plugin.json" ]] && grep -qE '"name"[[:space:]]*:[[:space:]]*"b3-ai-engineering"' "${PLUGIN_ROOT}/plugin.json"; then
    IS_B3_PLUGIN=true
  fi
  if ! $IS_B3_PLUGIN && ! $FORCE; then
    echo "error: refusing to overwrite existing non-B3 directory without --force: $PLUGIN_ROOT" >&2
    exit 1
  fi
  if [[ -d "${PLUGIN_ROOT}/skills" ]] && ! $FORCE; then
    for entry in "${PLUGIN_ROOT}/skills"/*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      if [[ ! -L "$entry" ]]; then
        echo "error: refusing to overwrite non-link entry in ${PLUGIN_ROOT}/skills without --force: $entry" >&2
        exit 1
      fi
    done
  fi
fi

PLUGIN_JSON='{
  "name": "b3-ai-engineering",
  "displayName": "B3 AI Engineering",
  "version": "1.0.0",
  "description": "Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.",
  "suggestedPrompts": [
    "Run autodev for a new feature or plan in this repository",
    "Run an independent review-loop on the current git diff",
    "Create an implementation plan without editing code yet"
  ]
}
'

if $DRY_RUN; then
  echo "dry-run: plugin_root=$PLUGIN_ROOT"
  echo "dry-run: B3_HOME=$B3_HOME"
  echo "dry-run: write ${PLUGIN_ROOT}/plugin.json"
  echo "dry-run: write ${PLUGIN_ROOT}/rules/AGENTS.md (${RULES_BYTES} bytes)"
  echo "dry-run: link ${#SKILL_NAMES[@]} skills into ${PLUGIN_ROOT}/skills"
  echo "dry-run: write ${#AGENT_BASES[@]} agents into ${PLUGIN_ROOT}/agents"
  exit 0
fi

mkdir -p "$PLUGIN_ROOT" "${PLUGIN_ROOT}/rules" "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/agents"

printf '%s' "$PLUGIN_JSON" > "${PLUGIN_ROOT}/plugin.json"
printf '%s' "$RULES_CONTENT" > "${PLUGIN_ROOT}/rules/AGENTS.md"

for entry in "${PLUGIN_ROOT}/skills"/* "${PLUGIN_ROOT}/skills"/.[!.]* "${PLUGIN_ROOT}/skills"/..?*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  if [[ -L "$entry" ]]; then
    rm "$entry"
  elif $FORCE; then
    rm -rf "$entry"
  fi
done

for i in "${!SKILL_NAMES[@]}"; do
  ln -s "${SKILL_DIRS[$i]}" "${PLUGIN_ROOT}/skills/${SKILL_NAMES[$i]}"
done

for existing in "${PLUGIN_ROOT}/agents"/*.md; do
  [[ -f "$existing" ]] || continue
  ebase="$(basename "$existing")"
  keep=false
  for expected in "${AGENT_BASES[@]}"; do
    if [[ "$ebase" == "$expected" ]]; then
      keep=true
      break
    fi
  done
  if ! $keep; then
    if $FORCE || grep -q '<!-- Generated from .*/\.cursor/agents/' "$existing"; then
      rm -f "$existing"
    fi
  fi
done

for i in "${!AGENT_BASES[@]}"; do
  printf '%s\n' "${AGENT_CONTENTS[$i]}" > "${PLUGIN_ROOT}/agents/${AGENT_BASES[$i]}"
done

PLUGIN_DIR_NAME="$(basename "$PLUGIN_ROOT")"
echo "installed Antigravity plugin at $PLUGIN_ROOT"
echo "B3_HOME=$B3_HOME"
echo "skills=${#SKILL_NAMES[@]}"
echo "agents=${#AGENT_BASES[@]}"
echo "rules_bytes=$RULES_BYTES"
echo "manage=customization://$PLUGIN_DIR_NAME"
echo "note: this proves plugin files were generated, not Antigravity runtime discovery"
