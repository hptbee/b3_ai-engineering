# Observed failures v1

Only items seen in the matrix or composition read. Not manufactured.

## F1 — `problem-solving` greedy trigger

**Evidence:** V1, V2, V24. Description matches any bug/feature/unclear failure.  
**Class:** REDUNDANT / AMBIGUOUS  
**Impact:** Crowds debugging, planning, and tiny edits.  
**Fix:** Narrow description and when-not-to-use (ADAPT). Keep the skill.

## F2 — `react-hooks` vs state placement

**Evidence:** V5. `useState` in hooks description.  
**Class:** FALSE_POSITIVE  
**Fix:** Description: tree placement → `react-components`; hooks = effects/deps/derived/async.

## F3 — `ef-core` vs DI / Dapper

**Evidence:** V15 (`DbContext` in singleton); V18 (Dapper + slow SQL vs “slow SQL” in when-to-use).  
**Class:** FALSE_POSITIVE risk  
**Fix:** Trigger only LINQ-to-Entities / `DbContext` query shape / tracking / migrations. Dapper/ADO.NET and DI lifetimes excluded in **description**, not only body.

## F4 — ProblemDetails / authn/z triple coverage

**Evidence:** V16, C2.  
**Class:** REDUNDANT descriptions  
**Fix:** aspnet-core description: pipeline, DI, middleware, hosting auth **configuration**. Object-level authz → api-security. Error **contract** → api-design; ProblemDetails as ASP.NET mechanism stays in body, not as a second contract skill trigger.

## F5 — `simplest-correct` vs local “keep it simple”

**Evidence:** Risk 6 + `rules/engineering-principles` already has smallest **change**.  
**Class:** latent FALSE_POSITIVE if someone says “simplest implementation” for a one-liner  
**Fix:** Description: architecture/system shape only; not local coding style; complexity **allowed** when a requirement is named.

## F6 — Host activation unknown → Cursor discovery FAIL at baseline

**Evidence:** this Agent session’s `available_skills` contained Cursor built-ins and user Cloudflare skills, not B3 `skills/`. Official docs do not load repo-root `skills/`.  
**Class:** FAIL (discovery in this workspace before adapter link); post-junction discovery **NOT VERIFIED** until a new chat (`cursor-host-v2.md`).  
**Fix:** local `.cursor/skills` → `skills` link (gitignored). Confirm in Customize → Skills. Do not treat file reads as discovery.

## Not failures

- V12 api-security stayed quiet — GOOD  
- V21 react-hooks excluded useFrame — GOOD  
- V22 threejs-performance stayed quiet — GOOD  
- Commands stayed thin — GOOD  
- No MISSED primary on expected skills in description-judge pass  
