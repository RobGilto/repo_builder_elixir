---
description: Runs the project's smoke test and reports a concise pass/fail summary.
argument-hint: [target]
allowed-tools: Read, Bash
---

# Smoke Test

## Purpose

Run the project's fast smoke test and surface a one-glance pass/fail, so a change can be
sanity-checked before the full gate. A sample artifact forged by the Forge (it stands in
for a stack-correct generated command).

## Variables

`$1` / `$ARGUMENTS` — an optional target to scope the smoke test (default: the whole repo).

## Instructions

- Resolve the project's smoke/test command from its detected capabilities (the
  `{{TEST_COMMAND}}` token); do not hard-wire a toolchain.
- Keep output terse: the verdict first, then only failing details.

## Workflow

1. Determine the smoke command for this stack.
2. Run it (scoped to `$ARGUMENTS` when given).
3. Now follow the `Report` section to report the completed work.

## Report

Output `PASS` or `FAIL` on the first line, then a short bullet list of any failures.
