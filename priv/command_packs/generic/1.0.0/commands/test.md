---
description: Run the repo's test suite and report results (stack-agnostic)
argument-hint: [filter]
---

# Test

Run the test suite for this repository and report pass/fail.

- Command: `{{TEST_COMMAND}}` (append `$ARGUMENTS` as a filter when provided).
- Test sources live under `{{TEST_DIR}}`.
- On failure, surface the failing output verbatim and propose the smallest fix.
