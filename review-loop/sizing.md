# Adaptive PR sizing & Risk classification

Classify **both Size and Risk before** the first review. Size governs **partitioning & context**. Risk governs **review depth, specialists & verification**. Never infer risk from LOC alone.

## T-shirt size classes

Measure changed `review_files` (`files`) and added + deleted lines (`lines`, excluding `noise_files` & `.b3/ship/`). Pick the **smallest** tier satisfying **both** limits (larger dimension wins; no overlaps/gaps):

| Size | Changed Files | Changed LOC | Workflow |
| --- | ---: | ---: | --- |
| **XS** | `<= 3` | `<= 100` | Lean full-diff loop ([`strategy.md`](strategy.md) §1) |
| **S** | `<= 8` | `<= 300` | Standard full-diff loop (`strategy.md` §1) |
| **M** | `<= 20` | `<= 800` | Full-PR risk-aware loop (`strategy.md` §1) |
| **L** | `< 50` | `< 2,000` | Cohesive unit loops + cross-unit ([`hierarchical.md`](hierarchical.md)) |
| **XL** | `<= 100` | `<= 5,000` | Coalesced `<= 4` units + deeper contracts (`hierarchical.md`) |
| **XXL** | Everything larger | Unlimited | Dynamic hierarchical L0–L4, adaptive concurrency (`hierarchical.md`) |

Special deterministic states: `NOISE_ONLY` (`0` review files, non-empty noise), `EMPTY_DIFF` (exit `2`, no target -> `UNKNOWN / INCOMPLETE`), `CLEAN_AFTER_FIX` (delta present after prior snapshot -> §1 verification before `PASS`).
Legacy state migration (`b3 guard review-ledger --action normalize`): `SMALL -> S`, `MEDIUM -> M`, `LARGE -> L`, `VERY_LARGE -> XL`.

## Decoupled Risk classification (`LOW | MEDIUM | HIGH | CRITICAL`)

Run `b3 guard diff-scope` (or `b3 guard review-inventory`) for deterministic signals, supplemented by reviewer judgment with recorded evidence (never silently downgrade uncertain risk):

- **CRITICAL:** auth/authn/authz/security/secrets/trust boundaries (directory or filename paths and content signals), security-sensitive filesystem or Git ops, destructive DB migrations (`DROP`/`TRUNCATE`), or exploit primitives.
- **HIGH:** DB schema/migrations/transactions, public APIs/shared contracts, concurrency/caching/async state, latency-critical/rendering/query hot paths, or wide multi-module blast radius (`>= 4` modules + contracts).
- **MEDIUM:** multi-file/medium behavioral code, generated code requiring provenance check, or 3+ module changes without higher triggers.
- **LOW:** docs-only (any size, e.g., 25k LOC `docs/*.md`), test-only, lockfiles, or isolated trivial code (`<= 1` file, `<= 100` LOC) with zero risk signals.

## Size × Risk Dispatch Matrix (existing `b3-*` roles only)

| Risk | `XS` / `S` | `M` | `L` / `XL` / `XXL` |
| --- | --- | --- | --- |
| **LOW** | 0-tok checks + 1 fresh `b3-reviewer` (no specialists) | 0-tok checks + 1 fresh `b3-reviewer` (no specialists) | Inventory -> skip L1 (`l1_skip_rationale`) -> cohesive units (`b3-reviewer` only) -> Ledger Gate |
| **MEDIUM** | Fresh `b3-reviewer` + triggered specialist only | Full-PR + triggered specialist only + checks | Cohesive units (adaptive concurrency) + conditional L1 / unit triggered specialists + L3 cross-unit + Ledger Gate |
| **HIGH** | Fresh `b3-reviewer` + matching specialist(s) + contract check | Deep contract review + specialists + `verify-run` | L0 Inventory -> conditional L1 (`l1_specialists`) -> L2 Units + specialists + receipts -> L3 Cross-unit -> L4 Ledger Gate |
| **CRITICAL** | **No downgrade:** Deep review + mandatory `b3-security-reviewer`/specialists (self-declared waivers disabled) + fail-closed `verify-run` | Full deep + mandatory specialists (self-declared waivers disabled) + fail-closed `verify-run` | L0–L4 fail-closed pipeline + mandatory `CRITICAL` specialists (self-declared waivers disabled) + bounded monotonic ledger & verification |

## Partitioning rules (`L` / `XL` / `XXL`)

- Unit = one **logical module/feature slice** (handlers + domain + matching tests); never split arbitrarily by LOC (`300L` chunks) or create 1-class/1-test-file crumbs.
- `L` / `XL` PRs are cohesively coalesced to `<= 4` logical units; `XXL` uses dynamic unit count with adaptive concurrency (`dispatch-naming.md`). Oversized units (`> 5,000` LOC or `> 100` files & `> 1,000` LOC) are subdivided by deeper directory hierarchy, contract files, feature tokens, and dependency imports; fail `PARTITION_INCOMPLETE` if safe cohesive partitioning is impossible.
- Recommend PR split when multi-feature units are independently mergeable (`split_recommended=true`); if un-splittable, execute hierarchical review without silently skipping any unit.
