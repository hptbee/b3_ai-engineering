#!/usr/bin/env bash
# Measure static context footprint (canonical LF UTF-8 bytes) for B3 always-on, /b3-ship, /b3-review-loop, and subagent roles.
# Usage: ./scripts/measure-context.sh [--repo-root DIR] [--strict]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 1; }
      REPO_ROOT="$2"; shift 2 ;;
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
    in_fm && $0 == "---" { closed = 1; exit }
    in_fm { sum += length($0) + 1 }
    END { print (closed && sum > 0 ? sum - 1 : 0) }
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

WF_RS_B="$(file_bytes "workflows/research-ship.md")"
[[ "$WF_RS_B" -gt 9500 ]] && WARNINGS+=("workflows/research-ship.md (${WF_RS_B} B > 9500 B)")
RS_CORE=$((WF_RS_B + $(file_bytes "commands/b3-research-ship.md")))

RS_REFS=$(($(file_bytes "workflows/references/research-ship-templates.md") + $(file_bytes "workflows/references/research-ship-resume.md") + $(file_bytes "workflows/references/research-ship-gates.md")))
[[ "$RS_REFS" -gt 12000 ]] && WARNINGS+=("workflows/references/research-ship-{templates,resume,gates}.md (${RS_REFS} B > 12000 B)")

CTX_ROUTE_B="$(file_bytes "workflows/references/context-routing.md")"
[[ "$CTX_ROUTE_B" -gt 3000 ]] && WARNINGS+=("workflows/references/context-routing.md (${CTX_ROUTE_B} B > 3000 B)")

DISP_NAMING_B="$(file_bytes "workflows/references/dispatch-naming.md")"
[[ "$DISP_NAMING_B" -gt 9200 ]] && WARNINGS+=("workflows/references/dispatch-naming.md (${DISP_NAMING_B} B > 9200 B)")

RL_STRAT_B="$(file_bytes "review-loop/strategy.md")"
[[ "$RL_STRAT_B" -gt 5200 ]] && WARNINGS+=("review-loop/strategy.md (${RL_STRAT_B} B > 5200 B)")
CR_SKILL_B="$(file_bytes "skills/engineering/code-review/SKILL.md")"
REV_TPL_B="$(file_bytes "skills/engineering/code-review/references/review-template.md")"
REV_AGENT_B="$(file_bytes "agents/b3-reviewer.md")"
FIXER_AGENT_B="$(file_bytes "agents/b3-fixer.md")"
REV_DELTA_B="$REV_AGENT_B"
REV_ITER_SUBAG=$((REV_AGENT_B + FIXER_AGENT_B))
PLAN_CMD_B=$(($(file_bytes "commands/b3-plan.md") + $(file_bytes "skills/engineering/planning/SKILL.md")))
IMPL_CMD_B=$(($(file_bytes "commands/b3-implement.md") + $(file_bytes "skills/engineering/problem-solving/SKILL.md")))
DEBUG_CMD_B=$(($(file_bytes "commands/b3-debug.md") + $(file_bytes "skills/engineering/debugging/SKILL.md")))
REVIEW_CMD_B=$(($(file_bytes "commands/b3-review.md") + CR_SKILL_B))
STANDALONE_REV_ALL=$((REVIEW_CMD_B + REV_TPL_B))
VERIFY_CMD_B=$(($(file_bytes "commands/b3-verify.md") + $(file_bytes "skills/engineering/verification/SKILL.md")))
PR_FB_SKILL_B="$(file_bytes "skills/engineering/pr-feedback/SKILL.md")"
PR_FB_REFS_B=$(($(file_bytes "skills/engineering/pr-feedback/references/reply-template.md") + $(file_bytes "skills/engineering/pr-feedback/references/thread-lifecycle.md") + $(file_bytes "skills/engineering/pr-feedback/references/github-adapter.md")))
PR_FB_ALL=$((PR_FB_SKILL_B + PR_FB_REFS_B))
RL_OP=$((RL_STRAT_B + $(file_bytes "commands/b3-review-loop.md") + REV_AGENT_B))
RL_HIER=$((RL_OP + $(file_bytes "review-loop/hierarchical.md")))
RL_ALL=$(($(file_bytes "review-loop/spec.md") + RL_STRAT_B + $(file_bytes "review-loop/sizing.md") + $(file_bytes "review-loop/models.md") + $(file_bytes "review-loop/hierarchical.md")))

AGENT_ROLES_B=0
AGENT_COUNT=0
for af in "${REPO_ROOT}/agents"/*.md; do
  [[ -f "$af" ]] || continue
  [[ "$(basename "$af")" == "README.md" ]] && continue
  ab="$(raw_lf_bytes "$af")"
  AGENT_ROLES_B=$((AGENT_ROLES_B + ab))
  AGENT_COUNT=$((AGENT_COUNT + 1))
done
[[ "$AGENT_ROLES_B" -gt 8500 ]] && WARNINGS+=("agents/*.md roles (${AGENT_ROLES_B} B > 8500 B)")

echo "=== B3 Context Budget Report ==="
printf "always_on_total   : %6d B (~%4d tok)  [AGENTS.md=%d B, rules=%d B, %d skill frontmatters=%d B]\n" "$ALWAYS_ON" "$(est_tok "$ALWAYS_ON")" "$AGENTS_B" "$RULES_B" "$SKILL_COUNT" "$FM_TOTAL"
printf "ship_core_load    : %6d B (~%4d tok)  [ship.md=%d B + commands/b3-ship.md]\n" "$SHIP_CORE" "$(est_tok "$SHIP_CORE")" "$WF_SHIP_B"
printf "ship_refs_load    : %6d B (~%4d tok)  [ship-templates.md + ship-resume.md]\n" "$SHIP_REFS" "$(est_tok "$SHIP_REFS")"
printf "research_ship_core: %6d B (~%4d tok)  [research-ship.md=%d B + commands/b3-research-ship.md]\n" "$RS_CORE" "$(est_tok "$RS_CORE")" "$WF_RS_B"
printf "research_ship_refs: %6d B (~%4d tok)  [research-ship-{templates,resume,gates}.md]\n" "$RS_REFS" "$(est_tok "$RS_REFS")"
printf "context_routing   : %6d B (~%4d tok)  [workflows/references/context-routing.md (on-demand)]\n" "$CTX_ROUTE_B" "$(est_tok "$CTX_ROUTE_B")"
printf "dispatch_naming   : %6d B (~%4d tok)  [workflows/references/dispatch-naming.md (on-demand)]\n" "$DISP_NAMING_B" "$(est_tok "$DISP_NAMING_B")"
printf "review_loop_op    : %6d B (~%4d tok)  [strategy=%d B + cmd + reviewer=%d B]\n" "$RL_OP" "$(est_tok "$RL_OP")" "$RL_STRAT_B" "$REV_AGENT_B"
printf "review_hier_load  : %6d B (~%4d tok)  [review_loop_op + hierarchical.md (L/XL/XXL on demand)]\n" "$RL_HIER" "$(est_tok "$RL_HIER")"
printf "review_delta_load : %6d B (~%4d tok)  [b3-reviewer.md (self-contained)]\n" "$REV_DELTA_B" "$(est_tok "$REV_DELTA_B")"
printf "review_iter_subag : %6d B (~%4d tok)  [b3-reviewer.md + b3-fixer.md (self-contained loop iter)]\n" "$REV_ITER_SUBAG" "$(est_tok "$REV_ITER_SUBAG")"
printf "standalone_cmds   : plan=%d B, impl=%d B, debug=%d B, review=%d B, verify=%d B\n" "$PLAN_CMD_B" "$IMPL_CMD_B" "$DEBUG_CMD_B" "$REVIEW_CMD_B" "$VERIFY_CMD_B"
printf "standalone_rev_all: %6d B (~%4d tok)  [cmd + code-review/SKILL.md + review-template.md]\n" "$STANDALONE_REV_ALL" "$(est_tok "$STANDALONE_REV_ALL")"
printf "pr_feedback_load  : %6d B (~%4d tok)  [pr-feedback/SKILL.md=%d B + refs=%d B (on-demand)]\n" "$PR_FB_ALL" "$(est_tok "$PR_FB_ALL")" "$PR_FB_SKILL_B" "$PR_FB_REFS_B"
printf "review_loop_all   : %6d B (~%4d tok)  [spec+strategy+sizing+models+hierarchical (reference-only)]\n" "$RL_ALL" "$(est_tok "$RL_ALL")"
printf "agents_roles_total: %6d B (~%4d tok)  [%d runtime subagent roles excl. README.md]\n" "$AGENT_ROLES_B" "$(est_tok "$AGENT_ROLES_B")" "$AGENT_COUNT"
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
