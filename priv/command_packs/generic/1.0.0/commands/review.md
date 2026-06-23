---
description: Review the current change for correctness and quality (stack-agnostic)
argument-hint: [scope]
---

# Review

Review the current diff for correctness bugs and quality issues.

- Focus on the sources under `{{SOURCE_DIRS}}`.
- Confirm the change still passes `{{BUILD_COMMAND}}`, `{{LINT_COMMAND}}`, and `{{TEST_COMMAND}}`.
- Report findings as a concise, prioritized list; do not apply fixes unless asked.
