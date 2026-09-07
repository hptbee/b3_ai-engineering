# Precedence

When instructions conflict, resolve them in this order. Higher wins. Lower items are contextual guidance, not a license to violate higher ones.

```text
1. Safety / platform constraints
2. Explicit user request
3. Project / repository requirements
4. Hard rules
5. Strong engineering guidelines
6. Technology-specific guidance
7. Personal preferences
8. Optional suggestions
```

This order is about **authority**, not about which file to open first.

## How to read the stack

### 1. Safety / platform constraints

Do not violate security, data-loss protections, legal/safety limits, or hard limits of the host tool or runtime. A preference cannot “make it simpler” by skipping auth. A missing sandbox cannot be treated as a successful test.

### 2. Explicit user request

The user’s current request sets **what to work on** and **scope**. It does not authorize:

- false verification (`PASS` without evidence)
- ignoring safety or platform constraints
- rewriting a product’s stated requirements
- turning a preference into a hard rule

If the request conflicts with (1), (3), or (4), do not silently comply and do not silently ignore. State the conflict and follow the higher constraint.

### 3. Project / repository requirements

The product repo under change wins over this personal system’s taste. Coding standards, architecture, and tests in that repo are requirements for that work. This system must not import those requirements back as universal rules.

Personal preferences must **never** silently override project requirements.

### 4. Hard rules

Durable constraints in `rules/` with `strength: hard` (see [`rule-standard.md`](rule-standard.md)). Example: never claim a check passed unless it ran.

Hard rules yield only to (1)–(3) as above — and even then, they still forbid dishonest outcomes (fake PASS, laundering preference as spec).

### 5. Strong engineering guidelines

Defaults that require a stated reason to skip. Record the reason in the working notes.

### 6. Technology-specific guidance

Volatile knowledge, official docs for the stack in use, and domain skills. Stale or unverified volatile notes must be re-checked; they do not beat official docs or project requirements.

### 7. Personal preferences

Profile files under `profiles/` and personal knowledge. Useful for defaults when nothing higher speaks.

```text
Personal Profile
      ↓
Personal Preferences
```

This is contextual guidance. It is **not** an instruction to violate higher-priority constraints.

```text
Personal preference  ≠  Engineering rule
```

A profile must never override:

- security requirements
- correctness
- explicit project requirements
- hard repository rules
- platform / tool constraints

### 8. Optional suggestions

Nits, style ideas, and speculative review comments. They must not block completion unless the user or a higher item promotes them.

## Profiles vs rules

| | Profile | Hard rule |
| --- | --- | --- |
| Question | How does the owner prefer to work? | What must always be true? |
| Override safety / correctness? | No | N/A (those are higher still) |
| Override project requirements? | No | No |
| Silent? | Must be labeled personal when it affects a choice | Applies without being asked |

## Skills, commands, workflows, adapters

These do not have their own rank on the stack:

- **Skills** supply method; they cannot waive (1)–(4).
- **Commands / workflows** select and sequence work; they cannot waive (1)–(4).
- **Agents** narrow mandate; they cannot waive (1)–(4).
- **Adapters** change location and invocation, not meaning.

## Honesty when something loses

When a lower item is overridden, say so briefly (which higher item won). Do not pretend the preference was followed. Do not pretend a skipped check passed.
