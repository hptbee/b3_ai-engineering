---
name: implement
description: Execute a plan or specified change using the default engineering loop. Use when the user asks to implement, build, or ship a change.
---

# implement

**Action now:** resolve `B3_HOME` (`B3_HOME` env, `.b3/home`, or this repo) and execute a plan or specified change using the default engineering loop.

**Skill:** `{B3_HOME}/skills/engineering/problem-solving/SKILL.md`

Load the smallest domain skill that matches the stack (React, Node, ASP.NET, Three.js, etc.).

Sequence: `{B3_HOME}/workflows/feature-implementation.md`. Do not run the full review loop unless asked (`commands/review-loop.md`).

A lifecycle that plans, implements, reviews, commits, and continues is `commands/autodev.md`. This command stays one execution request.
