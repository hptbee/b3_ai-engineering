# Skill scorecard v1

Ratings: GOOD | NEEDS_TUNING | NEEDS_BOUNDARY_CHANGE | CANDIDATE_FOR_REMOVAL | NOT_ENOUGH_EVIDENCE

Capability from applying the skill body to the matrix snippet (tabletop), not a product repo.

Portability: NOT_ENOUGH_EVIDENCE for every skill (host loaders untested). Listed once conceptually.

---

Skill: `engineering/verification`  
Activation: GOOD  
False positives: none in matrix  
False negatives: none  
Capability: GOOD (honest INCOMPLETE)  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `engineering/problem-solving`  
Activation: NEEDS_TUNING  
False positives: V1 V2 V24 (greedy)  
False negatives: none  
Capability: GOOD when it is the right loop  
Composition: overlaps debugging/planning  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F1  
Decision: NEEDS_TUNING

Skill: `engineering/code-review`  
Activation: GOOD (not in V-set as primary; commands test)  
False positives: not seen  
False negatives: not seen  
Capability: GOOD schema  
Composition: GOOD with agents  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `engineering/debugging`  
Activation: GOOD  
False positives: none on V24  
False negatives: none  
Capability: EFFECTIVE (root cause first)  
Composition: stolen by problem-solving description  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F1 (peer)  
Decision: GOOD (peer tuned)

Skill: `engineering/planning`  
Activation: GOOD  
False positives: none on V24  
False negatives: none  
Capability: GOOD  
Composition: problem-solving redundancy  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F1  
Decision: GOOD

Skill: `engineering/testing-strategy`  
Activation: GOOD (V4)  
False positives: none  
False negatives: none  
Capability: GOOD (no TDD iron law)  
Composition: GOOD vs verification  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `engineering/refactoring`  
Activation: AMBIGUOUS vs problem-solving (V3)  
False positives: none vs features  
False negatives: none  
Capability: GOOD  
Composition: NEEDS_TUNING (peer)  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: V3  
Decision: GOOD (problem-solving tuned)

Skill: `engineering/research-engineering-patterns`  
Activation: NOT_ENOUGH_EVIDENCE this phase (no research task)  
False positives: n/a  
False negatives: n/a  
Capability: NOT_ENOUGH_EVIDENCE  
Composition: NOT_ENOUGH_EVIDENCE  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: NOT_ENOUGH_EVIDENCE — keep

Skill: `frontend/react-components`  
Activation: GOOD (V5)  
False positives: none  
False negatives: none  
Capability: EFFECTIVE  
Composition: NEEDS_TUNING vs hooks trigger  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F2  
Decision: GOOD

Skill: `frontend/react-hooks`  
Activation: NEEDS_TUNING  
False positives: V5  
False negatives: none (V6 CORRECT; V21 excluded)  
Capability: EFFECTIVE on V6  
Composition: NEEDS_TUNING  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F2  
Decision: NEEDS_TUNING

Skill: `frontend/typescript-contracts`  
Activation: AMBIGUOUS vs api-design (V7)  
False positives: possible  
False negatives: none  
Capability: EFFECTIVE (`unknown` + validate)  
Composition: acceptable  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: V7  
Decision: GOOD (leave; different layer)

Skill: `frontend/react-performance`  
Activation: GOOD (V8, V22)  
False positives: none vs Three/Node  
False negatives: none  
Capability: PARTIALLY_EFFECTIVE (no profiler here)  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `frontend/accessibility`  
Activation: GOOD (V9)  
False positives: none  
False negatives: none  
Capability: GOOD  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `backend/nodejs-runtime`  
Activation: GOOD (V10 V11 V23)  
False positives: none vs React perf  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `backend/api-design`  
Activation: GOOD (V12)  
False positives: none on V13  
False negatives: none  
Capability: EFFECTIVE  
Composition: REDUNDANT ProblemDetails with aspnet-core  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F4  
Decision: GOOD (aspnet-core tuned)

Skill: `backend/api-security`  
Activation: GOOD (V13)  
False positives: none on V12  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `backend/csharp-async`  
Activation: GOOD (V14)  
False positives: none  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `backend/aspnet-core`  
Activation: NEEDS_TUNING (authn/z + ProblemDetails in description)  
False positives: composition tax V16  
False negatives: none (V15 CORRECT primary)  
Capability: EFFECTIVE on DI  
Composition: NEEDS_TUNING  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F4  
Decision: NEEDS_TUNING

Skill: `backend/ef-core`  
Activation: NEEDS_BOUNDARY_CHANGE (trigger)  
False positives: V15, V18 risk  
False negatives: none on V17  
Capability: EFFECTIVE on Include/N+1  
Composition: NEEDS_TUNING  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F3  
Decision: NEEDS_TUNING — not a new Dapper skill

Skill: `architecture/simplest-correct`  
Activation: GOOD (V25)  
False positives: latent local-simplicity  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD with planning  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: F5  
Decision: NEEDS_TUNING (wording only)

Skill: `threejs/threejs-resources`  
Activation: GOOD (V19)  
False positives: none  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `threejs/threejs-performance`  
Activation: GOOD (V20; quiet on V19/V22)  
False positives: none  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD

Skill: `threejs/react-three-fiber`  
Activation: GOOD (V21)  
False positives: none on vanilla  
False negatives: none  
Capability: EFFECTIVE  
Composition: GOOD  
Portability: NOT_ENOUGH_EVIDENCE  
Observed failures: none  
Decision: GOOD
