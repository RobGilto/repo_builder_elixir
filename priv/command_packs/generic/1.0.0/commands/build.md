---
description: Implement a plan, then make the validation gate pass (stack-agnostic)
argument-hint: <path-to-plan>
---

# Build

Implement the plan at `$ARGUMENTS` into the codebase, following its acceptance criteria.

- Production code lives under `{{SOURCE_DIRS}}`; tests under `{{TEST_DIR}}`.
- Use `{{PACKAGE_MANAGER}}` for dependency operations.
- Leave the repo compiling, formatted, and green.

Validation (all must pass before you finish):

- `{{BUILD_COMMAND}}`
- `{{FORMAT_COMMAND}}`
- `{{LINT_COMMAND}}`
- `{{TEST_COMMAND}}`
