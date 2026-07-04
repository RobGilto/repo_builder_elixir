---
command: feature
version: 1.0.0
---

# Feature Planning

Create a new plan to implement the `Feature` using the exact specified markdown `Plan Format`. Follow the `Instructions` to create the plan use the `Relevant Files` to focus on the right files.

## Variables
REQUEST: $ARGUMENTS

> **Argument contract (why `$ARGUMENTS`, not `$1 $2 $3`).** This command takes the
> **entire** argument string as one lossless value. Do NOT rely on positional variables
> (`$1`/`$2`/`$3`): the server-side slash expander fills those by splitting on whitespace,
> so any argument containing spaces — a JSON payload, or a freeform sentence — gets shredded
> across the slots (`/feature the workstreams ui` → `$1=the`, `$2=workstreams`, `$3=ui`).
> Binding the whole string to `$ARGUMENTS` keeps the feature request intact.

Derive the plan variables from `REQUEST`:

- If `REQUEST` parses as JSON, use its `number` → `issue_number`, its `title`/`body` as the
  feature, and any `adw_id` it carries (else synthesize a short one).
- Otherwise treat the full `REQUEST` string as the freeform feature request; set
  `issue_number` and `adw_id` to a short descriptive placeholder derived from the request.
- NEVER bind individual whitespace-separated words to `issue_number`/`adw_id`/`issue_json`.

## Instructions

- IMPORTANT: You're writing a plan to implement a net new feature based on the `Feature` that will add value to the application.
- IMPORTANT: The `Feature` describes the feature that will be implemented but remember we're not implementing a new feature, we're creating the plan that will be used to implement the feature based on the `Plan Format` below.
- Create the plan in the `specs/` directory with filename: `issue-{issue_number}-adw-{adw_id}-sdlc_planner-{descriptive-name}.md`
  - Replace `{descriptive-name}` with a short, descriptive name based on the feature (e.g., "add-auth-system", "implement-search", "create-dashboard")
- Use the `Plan Format` below to create the plan. 
- Research the codebase to understand existing patterns, architecture, and conventions before planning the feature.
- IMPORTANT: Replace every <placeholder> in the `Plan Format` with the requested value. Add as much detail as needed to implement the feature successfully.
- Use your reasoning model: THINK HARD about the feature requirements, design, and implementation approach.
- Follow existing patterns and conventions in the codebase. Don't reinvent the wheel.
- Design for extensibility and maintainability.
- IMPORTANT: This is an Elixir/Phoenix/OTP application. Honor the typed style guide in `BUILD_PROMPT.md` §3: an `@spec` on every public function (callback implementations carrying `@impl true` are exempt), `@type`/`@typep`/`@opaque` for domain data, `@enforce_keys` (prefer `typedstruct`) on every struct, precise types over `any()`/`map()`, and `{:ok, t()} | {:error, reason()}` over raising. Build is `--warnings-as-errors`; the gradual set-theoretic compiler plus Dialyzer must both stay green.
- Keep DB access behind `@spec`'d context modules — LiveViews, controllers, and OTP processes never touch `Repo`/`Ecto.Query` directly (`BUILD_PROMPT.md` §8).
- If you need a new library, add it to `mix.exs` `deps/0` (pin a version per `BUILD_PROMPT.md` §2), run `mix deps.get`, and report it in the `Notes` section of the `Plan Format`.
- This project uses **Tidewave** for Phoenix (runtime intelligence over MCP at `http://localhost:4000/tidewave/mcp`; `{:tidewave, "~> 0.5", only: :dev}` + `plug Tidewave`). When researching, prefer Tidewave's `get_docs`/`get_source_location` for exact-version library docs and definitions over web search. When planning validation, prefer Tidewave's `project_eval` (run code in the live app), `execute_sql_query` (verify DB state), and `get_logs` (inspect stacktraces) over ad-hoc IEx/`curl`. Note any such validation step in the plan.
- IMPORTANT: If the feature includes UI components or user interactions (the dashboard is Phoenix LiveView, `BUILD_PROMPT.md` §9):
  - Add a task in the `Step by Step Tasks` section to create a LiveView integration test in `test/repo_builder_web/live/test_<descriptive_name>_test.exs` using `Phoenix.LiveViewTest` (`live/2`, `render_*`, `element/2`, `assert_push`/PubSub assertions) that drives the new UI and asserts the rendered/streamed result.
  - Add that test file to your `Plan Format: New Files` section and add `mix test test/repo_builder_web/live/...` to your Validation Commands section.
  - Optionally, for visual proof, capture a screenshot of the running dashboard via Tidewave Web's vision mode (or, if unavailable, the Playwright MCP tools) against `http://localhost:4000`.
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
- `scripts/**` - Helper scripts (e.g. `scripts/pg.sh`).
- `adws/**` - AI Developer Workflow (ADW) Python `uv` scripts.

- If `.claude/commands/conditional_docs.md` exists, read it to check if your task requires additional documentation, and include any matching docs in the `Plan Format: Relevant Files` section of your plan.

Ignore all other files in the codebase.

## Plan Format

```md
# Feature: <feature name>

## Metadata
issue_number: `{issue_number}`
adw_id: `{adw_id}`
issue_json: `{issue_json}`

## Feature Description
<describe the feature in detail, including its purpose and value to users>

## User Story
As a <type of user>
I want to <action/goal>
So that <benefit/value>

## Problem Statement
<clearly define the specific problem or opportunity this feature addresses>

## Solution Statement
<describe the proposed solution approach and how it solves the problem>

## Relevant Files
Use these files to implement the feature:

<find and list the files that are relevant to the feature describe why they are relevant in bullet points. If there are new files that need to be created to implement the feature, list them in an h3 'New Files' section.>

## Implementation Plan
### Phase 1: Foundation
<describe the foundational work needed before implementing the main feature>

### Phase 2: Core Implementation
<describe the main implementation work for the feature>

### Phase 3: Integration
<describe how the feature will integrate with existing functionality>

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

<list step by step tasks as h3 headers plus bullet points. use as many h3 headers as needed to implement the feature. Order matters, start with the foundational shared changes required then move on to the specific implementation. Include creating tests throughout the implementation process.>

<If the feature affects the LiveView UI, include a task to create a `Phoenix.LiveViewTest` integration test in `test/repo_builder_web/live/test_<descriptive_name>_test.exs` as one of your early tasks. That test should validate the feature works as expected with the minimal set of steps — mount the LiveView, drive the interaction, and assert the rendered/streamed output (and, where relevant, that the right canonical event was broadcast over PubSub). Optionally capture a Playwright screenshot of `http://localhost:4000` as visual proof.>

<Your last step should be running the `Validation Commands` to validate the feature works correctly with zero regressions.>

## Testing Strategy
### Unit Tests
<describe unit tests needed for the feature>

### Edge Cases
<list edge cases that need to be tested>

## Acceptance Criteria
<list specific, measurable criteria that must be met for the feature to be considered complete>

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

<list commands you'll use to validate with 100% confidence the feature is implemented correctly with zero regressions. every command must execute without errors so be specific about what you want to run to validate the feature works as expected. Include commands to test the feature end-to-end.>

<If you created a LiveView integration test, include running it explicitly: `mix test test/repo_builder_web/live/test_<descriptive_name>_test.exs`.>

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
<optionally list any additional notes, future considerations, or context that are relevant to the feature that will be helpful to the developer>
```

## Feature
Interpret `REQUEST` per the `## Variables` contract: if it is JSON, use its `title` and
`body`; otherwise treat the entire `REQUEST` string as the feature request. If `REQUEST` is
empty or is only a few stray words (garbled positional fragments), STOP and report that the
caller should re-invoke with the full feature request (or the issue JSON) as a single
argument — do not fabricate a feature.

## Report

- IMPORTANT: Return exclusively the path to the plan file created and nothing else.
