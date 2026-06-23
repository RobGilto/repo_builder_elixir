---
description: Plan a change before implementing it (stack-agnostic, capability-tokened)
argument-hint: <goal>
---

# Plan

Produce an implementation plan for the goal in `$ARGUMENTS`.

- Read the relevant source under `{{SOURCE_DIRS}}` and existing specs in `{{SPEC_DIR}}`.
- Write the plan to `{{SPEC_DIR}}/` as a step-by-step task list with acceptance criteria.
- Do NOT write production code yet — planning only.

When done, the validation gate for this repo is:

- build: `{{BUILD_COMMAND}}`
- test:  `{{TEST_COMMAND}}`
- lint:  `{{LINT_COMMAND}}`
