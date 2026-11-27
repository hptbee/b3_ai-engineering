# Skill evals

Each skill (folder name = skill slug; canonical path is the YAML `artifact:` field):

```text
<skill>/
├── should-trigger/     (min 2)
├── should-not-trigger/ (min 2)
└── near-miss/          (min 2)
```

Eval folders are not nested by `engineering/` / `frontend/` / `backend/` / … — that taxonomy lives in `skills/`.

Minimum `2/2/2` (`should-trigger` / `should-not-trigger` / `near-miss`) per canonical skill, with larger suites where needed (for example, `simplest-correct/` and `code-review/`).

Manual judge: read `description` + case `input`. Automated runner: **not implemented**.

Validate: `cargo test --test eval_contracts`
