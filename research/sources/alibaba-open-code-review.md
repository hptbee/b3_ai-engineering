# Alibaba Open Code Review (alibaba/open-code-review)

## Source

https://github.com/alibaba/open-code-review

## Tier

Tier 2 (Production enterprise code review system)

## Purpose

AI-powered code review CLI tool originated from Alibaba Group's internal developer assistant. Employs a hybrid architecture combining deterministic engineering (Git operations, rule resolution, line-number relocation, worker concurrency) with LLM agents (context exploration, planning, and defect detection).

## Architecture

Deterministic Engineering × LLM Agent Pipeline:
1. **Target Resolution & Freeze**: Git diff inspection with `SealedInput` manifest freezing base and head commits to prevent mid-review drift.
2. **Path & Rule Resolution**: Hierarchical file-rule matching (`--rule` > `.open-code-review/rule.json` > `~/.open-code-review/rule.json` > system default) using path globbing with brace expansion to eliminate noisy instructions.
3. **Subtask Dispatcher**: Concurrent per-file review worker pool.
4. **Two-Stage Review Task**:
   - *Plan Phase*: For changes exceeding a line threshold, analyzes cross-file dependencies and generates targeted guidance.
   - *Main Tool Loop*: LLM explores context via read-only tools (`file_reader`, `diff_map`, `code_search`) and submits structured comments via `code_comment`.
5. **Comment Collector & Line Relocation**: Thread-safe comment collector; matches `existing_code` snippet against diff hunks (new-side first, old-side fallback, then full file) to lock exact line numbers; falls back to LLM snippet extraction (`ReLocateComment`) if matching fails.

## Important Patterns

- **Exact-Snippet Anchoring (`existing_code`)**: Avoids brittle LLM line number calculations by having the LLM quote the code snippet, using deterministic sliding-window text matching to locate lines.
- **Scenario-Tuned Review Tools**: Constrains review agents strictly to inspection and comment submission tools (`file_reader`, `diff_map`, `code_search`, `code_comment`), avoiding generic mutable shell tools.
- **Hierarchical Path-Based Rule Filtering**: Injects only rules relevant to the touched file path, preventing prompt saturation from irrelevant domain rules.
- **Two-Stage Large Diff Planning**: Lightweight plan pass mapping dependencies before dispatching in-depth review.
- **Immutable Target Manifest (`SealedInput`)**: Freezes diff endpoints so changes to the workspace during review do not cause drift or false positives.

## Skill Design

Packaged as an open-source Go CLI tool with optional agent skill manifest (`skills/open-code-review/SKILL.md`).

## Rules / Instructions

Path-based rules configured in `.open-code-review/rule.json` with glob matching and `merge_system_rule` support.

## Agents

Per-file LLM agent subtasks with customized tool registries and system prompt templating (`{{system_rule}}`, `{{diff}}`, `{{change_files}}`, `{{plan_guidance}}`).

## Evaluation

Internal enterprise validation across tens of thousands of developers and millions of defects; unit and integration test suite covering hunk parsing, line relocation, and comment parsing.

## Portability

Concepts (exact-snippet anchoring, tool discipline, two-stage planning, rule scoping) are highly portable to agent prompts, review schemas, and workflows. Go CLI binary and GitHub workflow hooks are external implementations.

## Strengths

- Resolves line number hallucination via deterministic fuzzy text matching
- Eliminates irrelevant rules from prompt context via path matching
- High reliability from dedicated, read-only review toolsets
- Freezes Git state against workspace drift

## Weaknesses / Trade-offs

- Per-file worker dispatch by default can miss inter-file semantic coupling compared to unit-level reviews
- Standalone CLI/daemon architecture requires external binary installation
- Unidirectional review (comments output) rather than an integrated fix-verify closed loop

## Relevance to b3-ai-engineering

Provides proven enterprise patterns for:
1. Grounding finding locations with exact code snippets (`existing_code`/`snippet`) rather than fragile line numbers.
2. Restricting reviewer agents to read-only exploration and finding submission.
3. Mapping cross-unit dependencies before diving into large diff reviews.

## Initial Recommendation

ADOPT:
- Exact-snippet anchoring in finding schemas and reviewer instructions
- Tool discipline for reviewer agents (read-only inspection over mutating shell tools)
- Dependency mapping before reviewing large unit diffs

REJECT:
- Per-file isolation as sole review boundary (preserve B3's architectural unit + cross-cutting pass)
- External Go binary daemon requirement
