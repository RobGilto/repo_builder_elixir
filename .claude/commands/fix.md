---
command: fix
version: 1.0.0
---

# Fix

Follow the `Instructions` to **resolve the issues a `/review` raised** so the build
passes its acceptance criteria. This is the review→fix branch of the
plan→build→review→fix ADW: it runs only when a review reported problems.

## Variables

adw_id: $ARGUMENT
spec_file: $ARGUMENT
review_findings: $ARGUMENT — the issues the review surfaced (passed in by the workflow)
agent_name: $ARGUMENT if provided, otherwise use 'fix_agent'

## Instructions

- Read the `review_findings` and the `spec_file` to understand what failed and why.
- Run `git diff` to see the current state of the build under review.
- Fix every issue the review raised, smallest coherent change first; do NOT introduce
  unrelated changes.
- Honor the repo's typed style guide (BUILD_PROMPT.md §3) and keep DB access behind
  `@spec`'d context modules (§8).
- After fixing, make the validation gate pass: `mix compile --warnings-as-errors`,
  `mix format`, `mix credo --strict`, `mix test --warnings-as-errors`. Fix every failure
  you introduce; leave the repo compiling, formatted, and green.
- Do NOT commit or push (the workflow commits separately).

## Report

- Summarize each issue fixed in a concise bullet list, referencing the review finding it
  resolves.
- State the final status of each validation command you ran.
