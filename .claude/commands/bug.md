---
command: bug
version: 1.0.0
---

# Bug Planning

Create a new plan to resolve the `Bug` using the exact specified markdown `Plan Format`. Follow the `Instructions` to create the plan use the `Relevant Files` to focus on the right files.

## Variables
REQUEST: $ARGUMENTS

> **Argument contract (why `$ARGUMENTS`, not `$1 $2 $3`).** This command takes the
> **entire** argument string as one lossless value. Do NOT rely on positional variables
> (`$1`/`$2`/`$3`): the server-side slash expander fills those by splitting on whitespace,
> so any argument containing spaces — a JSON payload, or a freeform sentence — gets shredded
> across the slots (`/bug the login flow breaks` → `$1=the`, `$2=login`, `$3=flow`). Binding
> the whole string to `$ARGUMENTS` keeps the bug report intact.

Derive the plan variables from `REQUEST`:

- If `REQUEST` parses as JSON, use its `number` → `issue_number`, its `title`/`body` as the
  bug, and any `adw_id` it carries (else synthesize a short one).
- Otherwise treat the full `REQUEST` string as the freeform bug report; set `issue_number`
  and `adw_id` to a short descriptive placeholder derived from the report.
- NEVER bind individual whitespace-separated words to `issue_number`/`adw_id`/`issue_json`.

## Instructions

- IMPORTANT: You're writing a plan to resolve a bug based on the `Bug` that will add value to the application.
- IMPORTANT: The `Bug` describes the bug that will be resolved but remember we're not resolving the bug, we're creating the plan that will be used to resolve the bug based on the `Plan Format` below.
- You're writing a plan to resolve a bug, it should be thorough and precise so we fix the root cause and prevent regressions.
- Create the plan in the `specs/` directory with filename: `issue-{issue_number}-adw-{adw_id}-sdlc_planner-{descriptive-name}.md`
  - Replace `{descriptive-name}` with a short, descriptive name based on the bug (e.g., "fix-login-error", "resolve-timeout", "patch-memory-leak")
- Use the plan format below to create the plan. 
- Research the codebase to understand the bug, reproduce it, and put together a plan to fix it.
- IMPORTANT: Replace every <placeholder> in the `Plan Format` with the requested value. Add as much detail as needed to fix the bug.
- Use your reasoning model: THINK HARD about the bug, its root cause, and the steps to fix it properly.
- IMPORTANT: Be surgical with your bug fix, solve the bug at hand and don't fall off track.
- IMPORTANT: We want the minimal number of changes that will fix and address the bug.
- IMPORTANT: This is an Elixir/Phoenix/OTP application. Keep the fix idiomatic and typed per `BUILD_PROMPT.md` §3: preserve `@spec`s, `@enforce_keys`/`typedstruct` structs, precise types, and `{:ok, t()} | {:error, reason()}` over raising. The build is `--warnings-as-errors` and both the gradual set-theoretic compiler and Dialyzer must stay green. Keep DB access behind `@spec`'d context modules (`BUILD_PROMPT.md` §8).
- If you need a new library, add it to `mix.exs` `deps/0` (pin a version per `BUILD_PROMPT.md` §2), run `mix deps.get`, and report it in the `Notes` section of the `Plan Format`.
- This project uses **Tidewave** for Phoenix (runtime intelligence over MCP at `http://localhost:4000/tidewave/mcp`). When reproducing and root-causing the bug, prefer Tidewave's `get_logs` (read the actual stacktrace), `project_eval` (reproduce the failure by running code in the live app), and `execute_sql_query` (inspect the DB state behind the bug) over guesswork; use `get_docs`/`get_source_location` for exact-version library behavior. Note any such step in the plan.
- IMPORTANT: If the bug affects the LiveView UI or user interactions (the dashboard is Phoenix LiveView, `BUILD_PROMPT.md` §9):
  - Add a task in the `Step by Step Tasks` section to create a `Phoenix.LiveViewTest` integration test in `test/repo_builder_web/live/test_<descriptive_name>_test.exs` that fails before the fix and passes after it.
  - Add that test file to your `Plan Format: New Files` section and add `mix test test/repo_builder_web/live/...` to your Validation Commands section.
  - Optionally capture a screenshot of `http://localhost:4000` as visual proof the bug is fixed, via Tidewave Web's vision mode (or the Playwright MCP tools if unavailable).
- Respect requested files in the `Relevant Files` section.
- Start your research by reading `BUILD_PROMPT.md` (the authoritative architecture/spec) and `README.md`.

## Relevant Files

Focus on the following files:
- `BUILD_PROMPT.md` - The authoritative architecture/spec for the platform (mission, tech stack §2, typed style guide §3, harness event contract §4, supervision tree §5, session runtime §6, workflow engine §7, persistence §8, LiveView dashboard §9, extensibility §10, directory layout §11, milestones §12, testing §13).
- `README.md` - Project overview and run instructions.
- `AGENTS.md` - Agent/contributor conventions for this repo (if present).
- `mix.exs` - Project config, dependency pins, Dialyzer config, and `mix` aliases.
- `lib/repo_builder/**` - Business domain: contexts, Ecto schemas, OTP processes (session runtime, workflow engine, harness adapters, Oban workers).
- `lib/repo_builder_web/**` - Web interface: Endpoint, Router, LiveViews, typed function components, controllers (webhooks).
- `config/**` - `config.exs`/`dev.exs`/`test.exs`/`runtime.exs`, including the harness registry and Oban config.
- `priv/repo/migrations/**` - Ecto migrations (binary_id PKs, JSONB, Oban tables).
- `test/**` - ExUnit tests, `test/support/` cases, Mox setup.
- `scripts/**` - Helper scripts (e.g. `scripts/patch_deps.sh`).
- `adws/**` - AI Developer Workflow (ADW) Python `uv` scripts.

- If `.claude/commands/conditional_docs.md` exists, read it to check if your task requires additional documentation, and include any matching docs in the `Plan Format: Relevant Files` section of your plan.

Ignore all other files in the codebase.

## Plan Format

```md
# Bug: <bug name>

## Metadata
issue_number: `{issue_number}`
adw_id: `{adw_id}`
issue_json: `{issue_json}`

## Bug Description
<describe the bug in detail, including symptoms and expected vs actual behavior>

## Problem Statement
<clearly define the specific problem that needs to be solved>

## Solution Statement
<describe the proposed solution approach to fix the bug>

## Steps to Reproduce
<list exact steps to reproduce the bug>

## Root Cause Analysis
<analyze and explain the root cause of the bug>

## Relevant Files
Use these files to fix the bug:

<find and list the files that are relevant to the bug describe why they are relevant in bullet points. If there are new files that need to be created to fix the bug, list them in an h3 'New Files' section.>

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

<list step by step tasks as h3 headers plus bullet points. use as many h3 headers as needed to fix the bug. Order matters, start with the foundational shared changes required to fix the bug then move on to the specific changes required to fix the bug. Include tests that will validate the bug is fixed with zero regressions.>

<If the bug affects the LiveView UI, include a task to create a `Phoenix.LiveViewTest` integration test in `test/repo_builder_web/live/test_<descriptive_name>_test.exs` that reproduces the bug (fails before the fix) and proves it is fixed (passes after). Keep it to the minimal set of steps; optionally capture a Playwright screenshot of `http://localhost:4000` as proof.>

<Your last step should be running the `Validation Commands` to validate the bug is fixed with zero regressions.>

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

<list commands you'll use to validate with 100% confidence the bug is fixed with zero regressions. every command must execute without errors so be specific about what you want to run to validate the bug is fixed with zero regressions. Include commands to reproduce the bug before and after the fix.>

<If you created a LiveView integration test, include running it explicitly: `mix test test/repo_builder_web/live/test_<descriptive_name>_test.exs`.>

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
<optionally list any additional notes or context that are relevant to the bug that will be helpful to the developer>
```

## Bug
Interpret `REQUEST` per the `## Variables` contract: if it is JSON, use its `title` and
`body`; otherwise treat the entire `REQUEST` string as the bug report. If `REQUEST` is empty
or is only a few stray words (garbled positional fragments), STOP and report that the caller
should re-invoke with the full bug report (or the issue JSON) as a single argument — do not
fabricate a bug.

## Report

- IMPORTANT: Return exclusively the path to the plan file created and nothing else.
