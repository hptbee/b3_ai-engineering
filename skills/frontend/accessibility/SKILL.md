---
name: accessibility
description: >
  Use when implementing or reviewing UI accessibility: keyboard, labels,
  names, contrast, focus, forms, images, WCAG AA hotspots. Do not use for
  visual polish only, React performance, or claiming a11y PASS from a
  linter alone.
---

# Accessibility

Findings cite WCAG success criteria when claiming defects. Automation is incomplete.

## When to use

- Forms, dialogs, navigation, images, live regions
- “Is this accessible?”
- Keyboard or screen-reader issues

## When not to use

- Layout/CSS without interaction/semantics
- Performance
- Full WCAG AAA audit unless requested (say INCOMPLETE vs AAA)

## Procedure

1. Scope the UI surface.
2. Automated scan if available (axe, eslint-plugin-jsx-a11y) — record command.
3. Manual: keyboard order, visible focus, labels (`<label>` / `aria-labelledby`), button vs div, alt text, contrast for text.
4. Record findings with **WCAG SC id**, evidence, severity ≠ confidence (`review-loop/spec.md`).
5. Do not mark PASS on “looks fine”.

Hotspots: 1.1.1, 1.3.1, 1.4.3, 2.1.1, 2.4.7, 4.1.2.

## Verification

Repro with keyboard (and tool output if run). Unrun checks → INCOMPLETE.

## Failure handling

- No browser → INCOMPLETE
- Design-system claims a11y — still verify usage

## Provenance

ADOPT WCAG 2.2 as citation standard (`research/sources/w3c-wcag.md`). Checklist is ADAPT, not the full spec.
