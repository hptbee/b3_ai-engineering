# Backend skills comparison

## Candidates compared

| Source | Scope | Structure | Best for |
| --- | --- | --- | --- |
| OWASP API Top 10 2023 | API threat taxonomy | Standard categories | Finding IDs (API1–API10) |
| OWASP Auth Cheat Sheet | AuthN/session controls | Checklist | Implementation/review checklist |
| Node.js Security Best Practices | Runtime/app threats | Threat → mitigation | Node service hardening |
| Trail of Bits differential-review | Security diff review | Phased skill + references | Deep PR security review |
| b3 code-review (existing) | General review pass | Single SKILL.md | Default review; security light |

## Layering model

```text
code-review (always available, all dimensions)
    ↓ optional depth
backend-api-security (OWASP APIx findings)
backend-auth-security (session/password/MFA checklist)
backend-node-architecture (runtime + layout)
backend-security-review (ADAPT differential triage + rationalizations)
```

## Structural patterns

| Pattern | Example | b3 fit |
| --- | --- | --- |
| Taxonomy-backed findings | API Top 10 | **ADOPT** |
| Checklist skill | OWASP Auth sheet | **ADAPT** |
| Threat index references | Node security doc | **ADAPT** |
| Phased diff review | Trail of Bits | **ADAPT** subset; reject default 6-phase |
| allowed-tools frontmatter | Trail of Bits | **Adapter only** — not in portable core |

## Activation risks

| Risk | Mitigation |
| --- | --- |
| Security skill triggers on any PR | Narrow description to "security review of API/auth/crypto changes" |
| Overlap with code-review | code-review stays default; security skills for explicit depth |
| Trail of Bits subagent names | Do not copy namespaced agents into portable core |

## Verdict

Split backend into **3–4 skills** after synthesis:
1. API security review (OWASP API Top 10)
2. Auth/session security (cheat sheet)
3. Node architecture + runtime security (Node doc + layout conventions)
4. Optional security differential review (adapted Trail of Bits triage + rationalizations)

Keep **code-review** as first pass; specialist skills activate on explicit security tasks or high-risk diffs.

## b3 alignment

Matches decision-004 (independent review, validation) — security differential review aligns with optional deep pass, not default OCR-scale pipeline.

## Confidence

Medium-High
