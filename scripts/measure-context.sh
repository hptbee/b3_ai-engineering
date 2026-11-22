#!/usr/bin/env bash
# Measure static context footprint (canonical LF UTF-8 bytes) for B3 always-on, /b3-ship, /b3-review-loop, and subagent roles.
# Usage: ./scripts/measure-context.sh [--repo-root DIR] [--strict]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --strict) STRICT=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

raw_lf_bytes() {
  if [[ -f "$1" ]]; then
    tr -d '\r' < "$1" | wc -c | tr -d ' '
  else
    echo 0
  fi
}

file_bytes() {
  raw_lf_bytes "${REPO_ROOT}/$1"
}

est_tok() {
  echo $(( ($1 + 2) / 4 ))
}

WARNINGS=()

AGENTS_B="$(file_bytes "AGENTS.md")"
[[ "$AGENTS_B" -gt 3600 ]] && WARNINGS+=("AGENTS.md (${AGENTS_B} B > 3600 B)")

RULES_B=0
for rf in "${REPO_ROOT}/rules"/*.md; do
  [[ -f "$rf" ]] || continue
  b="$(raw_lf_bytes "$rf")"
  RULES_B=$((RULES_B + b))
done

SKILL_COUNT=0
FM_TOTAL=0
MAX_FM=0
MAX_FM_FILE=""
MAX_SKILL=0
MAX_SKILL_FILE=""

while IFS= read -r sf; do
  [[ -n "$sf" && -f "$sf" ]] || continue
  SKILL_COUNT=$((SKILL_COUNT + 1))
  rel="${sf#${REPO_ROOT}/}"
  sb="$(raw_lf_bytes "$sf")"
  if [[ "$sb" -gt "$MAX_SKILL" ]]; then
    MAX_SKILL="$sb"
    MAX_SKILL_FILE="$rel"
  fi
  [[ "$sb" -gt 4000 ]] && WARNINGS+=("${rel} (${sb} B > 4000 B)")

  fm_b="$(LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm { sum += length($0) + 1 }
    END { print (sum > 0 ? sum - 1 : 0) }
  ' "$sf")"
  FM_TOTAL=$((FM_TOTAL + fm_b))
  if [[ "$fm_b" -gt "$MAX_FM" ]]; then
    MAX_FM="$fm_b"
    MAX_FM_FILE="$rel"
  fi
  [[ "$fm_b" -gt 280 ]] && WARNINGS+=("${rel} frontmatter (${fm_b} B > 280 B)")
done < <(find "${REPO_ROOT}/skills" "${REPO_ROOT}/adapters/command-skills" -name 'SKILL.md' -type f 2>/dev/null | LC_ALL=C sort)

ALWAYS_ON=$((AGENTS_B + RULES_B + FM_TOTAL))
WF_SHIP_B="$(file_bytes "workflows/ship.md")"
[[ "$WF_SHIP_B" -gt 9500 ]] && WARNINGS+=("workflows/ship.md (${WF_SHIP_B} B > 9500 B)")
SHIP_CORE=$((WF_SHIP_B + $(file_bytes "commands/b3-ship.md")))

SHIP_REFS=$(($(file_bytes "workflows/references/ship-templates.md") + $(file_bytes "workflows/references/ship-resume.md")))
[[ "$SHIP_REFS" -gt 6000 ]] && WARNINGS+=("workflows/references/ship-{templates,resume}.md (${SHIP_REFS} B > 6000 B)")

RL_STRAT_B="$(file_bytes "review-loop/strategy.md")"
[[ "$RL_STRAT_B" -gt 5400 ]] && WARNINGS+=("review-loop/strategy.md (${RL_STRAT_B} B > 5400 B)")
CR_SKILL_B="$(file_bytes "skills/engineering/code-review/SKILL.md")"
REV_AGENT_B="$(file_bytes "agents/b3-reviewer.md")"
REV_DELTA_B=$((REV_AGENT_B + CR_SKILL_B))
RL_OP=$((RL_STRAT_B + $(file_bytes "commands/b3-review-loop.md") + REV_AGENT_B + CR_SKILL_B))
RL_ALL=$(($(file_bytes "review-loop/spec.md") + RL_STRAT_B + $(file_bytes "review-loop/sizing.md") + $(file_bytes "review-loop/models.md")))

AGENT_ROLES_B=0
for af in "${REPO_ROOT}/agents"/*.md; do
  [[ -f "$af" ]] || continue
  [[ "$(basename "$af")" == "README.md" ]] && continue
  ab="$(raw_lf_bytes "$af")"
  AGENT_ROLES_B=$((AGENT_ROLES_B + ab))
done
[[ "$AGENT_ROLES_B" -gt 8500 ]] && WARNINGS+=("agents/*.md roles (${AGENT_ROLES_B} B > 8500 B)")

echo "=== B3 Context Budget Report ==="
printf "always_on_total   : %6d B (~%4d tok)  [AGENTS.md=%d B, rules=%d B, %d skill frontmatters=%d B]\n" "$ALWAYS_ON" "$(est_tok "$ALWAYS_ON")" "$AGENTS_B" "$RULES_B" "$SKILL_COUNT" "$FM_TOTAL"
printf "ship_core_load    : %6d B (~%4d tok)  [ship.md=%d B + commands/b3-ship.md]\n" "$SHIP_CORE" "$(est_tok "$SHIP_CORE")" "$WF_SHIP_B"
printf "ship_refs_load    : %6d B (~%4d tok)  [ship-templates.md + ship-resume.md]\n" "$SHIP_REFS" "$(est_tok "$SHIP_REFS")"
printf "review_loop_op    : %6d B (~%4d tok)  [strategy=%d B + cmd + reviewer + code-review/SKILL.md=%d B]\n" "$RL_OP" "$(est_tok "$RL_OP")" "$RL_STRAT_B" "$CR_SKILL_B"
printf "review_delta_load : %6d B (~%4d tok)  [b3-reviewer.md + code-review/SKILL.md]\n" "$REV_DELTA_B" "$(est_tok "$REV_DELTA_B")"
printf "review_loop_all   : %6d B (~%4d tok)  [spec+strategy+sizing+models (reference-only)]\n" "$RL_ALL" "$(est_tok "$RL_ALL")"
printf "agents_roles_total: %6d B (~%4d tok)  [5 runtime subagent roles excl. README.md]\n" "$AGENT_ROLES_B" "$(est_tok "$AGENT_ROLES_B")"
printf "max_skill_file    : %6d B  (%s)\n" "$MAX_SKILL" "$MAX_SKILL_FILE"
printf "max_frontmatter   : %6d B  (%s)\n" "$MAX_FM" "$MAX_FM_FILE"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo "warnings          : ${#WARNINGS[@]}"
  for w in "${WARNINGS[@]}"; do
    echo "  - $w"
  done
  $STRICT && exit 1
else
  echo "warnings          : 0"
fi
exit 0
