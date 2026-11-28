# Research Ship Templates

Schemas for [`../research-ship.md`](../research-ship.md). Active `{RUN_DIR}` = `.b3/research-ship/runs/<run_id>/` via `.b3/research-ship/CURRENT`.

## 1. Progress (`{RUN_DIR}/progress.md`)

```markdown
# Research Ship Progress
- run_id: <YYYYMMDD-HHMM-slug>
- mode: <research-only|research+implement|research+governed-release|existing-plan>
- b3_home: <abs path>
- product_root: <abs path>
- branch: <branch>
- run_base_sha: <SHA>
- initial_dirty_paths: <csv or none>
- pr_number: <num or none>
- merge_status: <NONE|PR_READY|LOCAL_ELIGIBLE_ONLY|PROVIDER_UNAVAILABLE|MERGE_BLOCKED|MERGED_VERIFIED>
- last_wave: <none or dispatch=PARALLEL agents=<N> isolation=<mode> | dispatch=SEQUENTIAL reason=<reason>>
- run_status: running
- updated: <ISO-8601>

## Units
| id | status | exec_mode | worker_root | base_sha | scope | integration | readiness | evidence_manifest | subagent_id | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| U001 | in_progress | SHARED_READ_ONLY | . | | | pending | draft | evidence/sources.manifest | | |

## Blockers
## Next action
## Limitations
```

`integration` ∈ `pending|output_ready|integrated` (`output_ready` after artifact/`evidence-check` or shared-WT verify; `integrated` in Parent for `ISOLATED_WRITES`).

## 2. Research Plan (`{RUN_DIR}/research-plan.md`)

For 1-unit queries, inline these fields in `progress.md`:

```markdown
# Research Plan: <objective>
- version: 1
- single_writer_paths: <csv ledgers/manifests/authority or none>
- protected_paths: <csv or none>

### U001 — <title>
- question: <bounded question>
- current_knowledge: <verified baseline>
- missing_evidence: <gaps>
- required_sources: <primary/secondary/repo paths>
- schools_or_domains: <applicable schools/domains>
- depends_on: [] # hard verified-output prerequisites only
- owned_files: <disjoint output paths>
- acceptance_criteria:
  - AC1: <verifiable source/code outcome>
- verification: <source + technical check>
- implication: <doc|knowledge|impl|release-candidate|internal-only>
```

## 3. Evidence Index (`{RUN_DIR}/evidence-index.md`)

Cite path/section/edition + SHA-256 manifest (never paste full books/logs):

```markdown
# Evidence Index
- manifest: evidence/sources.manifest

| claim_id | unit | class | source_ref | conditions | dispute_status | uncertainty |
| --- | --- | --- | --- | --- | --- | --- |
| C001 | U001 | primary | <source+loc> | <operands/scope> | AGREED|UNRESOLVED|CONFLICTING | <notes> |
```

`class` ∈ `primary|secondary-scholarly|repo-evidence|prior-verified|unverified|conflicting`.

## 4. Product Policy & Profile Contract (in product `.b3/`)

Products optionally provide:
- `.b3/research-profile.md`: sources, school rules, authority paths, editorial policy, single-writer paths.
- `.b3/policy.toml` ([`policy.example.toml`](../../config/policy.example.toml); canonical trunk authority; legacy `.b3/research-policy.json` fails closed):

```toml
auto_merge = "disabled"
auto_merge_max_risk = "LOW"
protected_paths = ["docs/authority/", "releases/"]
allow_protected_paths = false
allowed_target_branches = ["main"]
require_ci = true
require_review = true
```
