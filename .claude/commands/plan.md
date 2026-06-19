---
command: plan
version: 1.0.0
---

---
description: Turn a work item into a written specs/*.md implementation plan
argument-hint: [adw_id] [prompt-or-spec-file]
allowed-tools: Read, Write, Bash, Grep, Glob
---

# Plan

Follow the `Workflow` to turn the requested work item into a concrete, written
implementation plan saved under `specs/`, then `Report` the path. This is the
`/plan` step every portable ADW (`plan_build*`, `plan_build_review_fix`,
`plan_w_scouts…`, `build_in_parallel`) depends on — it produces the artifact the
downstream `/build` step implements.

## Variables

adw_id: $1 — the ADW run/correlation id (used to name the plan; default `plan`)
prompt: $ARGUMENTS — the work item / task description (or a path to an existing spec)
agent_name: 'plan_agent'

## Workflow

- If no `prompt` is provided, STOP immediately and ask for the work item to plan.
- If `prompt` is a path to an existing `specs/*.md` file, read it and refine it in
  place rather than creating a duplicate.
- Otherwise research the codebase first — read `BUILD_PROMPT.md` (the authoritative
  architecture/spec) and `README.md`, then the files the work item touches — so the
  plan fits existing patterns and conventions. Don't reinvent the wheel.
- THINK HARD about requirements, design, and implementation approach before writing.
- Create the plan in `specs/` with filename
  `issue-{adw_id}-adw-{adw_id}-sdlc_planner-{descriptive-name}.md`, replacing
  `{descriptive-name}` with a short kebab-case name derived from the work item.
- This is an **Elixir/Phoenix/OTP** app. Honor the typed style guide in
  `BUILD_PROMPT.md` §3: an `@spec` on every public function (`@impl true` callbacks
  exempt), `@type`/`typedstruct`/`@enforce_keys` for domain data, precise types over
  `any()`/`map()`, `{:ok, t()} | {:error, reason()}` over raising. Keep DB access
  behind `@spec`'d context modules — LiveViews/controllers/OTP processes never touch
  `Repo`/`Ecto.Query` directly (§8). Build is `--warnings-as-errors`; the gradual
  set-theoretic checker and Dialyzer must both stay green.
- If the work touches the LiveView UI (§9), add a task to create a
  `Phoenix.LiveViewTest` integration test in
  `test/repo_builder_web/live/test_<name>_test.exs` and list it in `New Files`.
- If `.claude/commands/conditional_docs.md` exists, read it to see whether the task
  needs additional docs, and include any matching docs in the plan's `Relevant Files`.

## Plan Format

```md
# <Feature | Bug | Chore>: <name>

## Metadata
adw_id: `{adw_id}`

## Description
<describe the work item in detail, including its purpose and value>

## Problem Statement
<clearly define the problem or opportunity this work addresses>

## Solution Statement
<describe the proposed approach and how it solves the problem>

## Relevant Files
Use these files to do the work:

<list the files relevant to the work, why each is relevant, in bullet points. List
any files to be created under an h3 'New Files' section.>

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

<list step-by-step tasks as h3 headers plus bullet points. Order matters: foundational
shared changes first, then the specific implementation. Include creating tests
throughout. The last step runs the Validation Commands.>

## Acceptance Criteria
<specific, measurable criteria that must be met for the work to be complete>

## Validation Commands
Execute every command to validate the work with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; gradual checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` - Full ExUnit suite, zero failures.
- `mix format --check-formatted` - Formatting.
- `mix credo --strict` - Lint incl. the `@spec` convention.
- `mix dialyzer` - Contract checking, no new warnings.

## Notes
<optional additional context helpful to the developer who implements this plan>
```

## Report

- IMPORTANT: Return exclusively the path to the plan file created and nothing else.
