---
description: Run the Node test + typecheck gate and report
argument-hint: [filter]
---

# Test (Node)

Run the gate, reporting each command:

1. `{{LINT_COMMAND}}`
2. `{{TYPECHECK_COMMAND}}`
3. `{{TEST_COMMAND}}` (append `$ARGUMENTS` as a test name filter when provided)

Use `{{PACKAGE_MANAGER}}` for any dependency operations. On failure, surface the
failing output verbatim and propose the smallest fix.
