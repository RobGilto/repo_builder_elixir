---
description: Validate then ship — runs the project's test command before declaring done (stack-aware)
argument-hint: [scope]
---

# Ship It

Validate the change and report readiness to ship.

- Run `{{TEST_COMMAND}}` and confirm it passes (append `$ARGUMENTS` as a scope filter when provided).
- Confirm `{{LINT_COMMAND}}` and `{{FORMAT_COMMAND}}` are clean.
- On any failure, surface the output verbatim and stop — do not declare shippable.
