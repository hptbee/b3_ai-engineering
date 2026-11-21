# Skill evals

Each skill (folder name = skill slug; canonical path is the YAML `artifact:` field):

```text
<skill>/
├── should-trigger/     (min 2)
├── should-not-trigger/ (min 2)
└── near-miss/          (min 2)
```

Eval folders are not nested by `engineering/` / `frontend/` / `backend/` / … — that taxonomy lives in `skills/`.

Foundation skills: 7 cases each (Track C). Synthesized domain skills: 6 cases each (decision-008).

Manual judge: read `description` + case `input`. Automated runner: **not implemented**.

Validate: `./scripts/validate-evals.sh`
