---
description: Diagnose and fix a failing validation gate (stack-agnostic)
argument-hint: <failure-description>
---

# Fix

Diagnose and fix the failure described in `$ARGUMENTS`.

- Reproduce with `{{TEST_COMMAND}}` (or `{{BUILD_COMMAND}}` for a compile failure).
- Apply the smallest correct change under `{{SOURCE_DIRS}}`.
- Re-run `{{BUILD_COMMAND}}`, `{{LINT_COMMAND}}`, and `{{TEST_COMMAND}}` until green.
