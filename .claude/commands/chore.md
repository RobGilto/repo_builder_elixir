---
command: chore
version: 1.0.0
---

# Chore Planning

Create a new plan to resolve the `Chore` using the exact specified markdown `Plan Format`. Follow the `Instructions` to create the plan use the `Relevant Files` to focus on the right files. Follow the `Report` section to properly report the results of your work.

## Variables
REQUEST: $ARGUMENTS

> **Argument contract (why `$ARGUMENTS`, not `$1 $2 $3`).** This command takes the
> **entire** argument string as one lossless value. Do NOT rely on positional variables
> (`$1`/`$2`/`$3`): the server-side slash expander fills those by splitting on whitespace,
> so any argument containing spaces — a JSON payload, or a freeform sentence — gets shredded
> across the slots (`/chore bump the deps` → `$1=bump`, `$2=the`, `$3=deps`). Binding the
> whole string to `$ARGUMENTS` keeps the chore request intact.

Derive the plan variables from `REQUEST`:

- If `REQUEST` parses as JSON, use its `number` → `issue_number`, its `title`/`body` as the
  chore, and any `adw_id` it carries (else synthesize a short one).
- Otherwise treat the full `REQUEST` string as the freeform chore request; set `issue_number`
  and `adw_id` to a short descriptive placeholder derived from the request.
- NEVER bind individual whitespace-separated words to `issue_number`/`adw_id`/`issue_json`.

## Instructions

- IMPORTANT: You're writing a plan to resolve a chore based on the `Chore` that will add value to the application.
- IMPORTANT: The `Chore` describes the chore that will be resolved but remember we're not resolving the chore, we're creating the plan that will be used to resolve the chore based on the `Plan Format` below.
- You're writing a plan to resolve a chore, it should be simple but we need to be thorough and precise so we don't miss anything or waste time with any second round of changes.
- Create the plan in the `specs/` directory with filename: `issue-{issue_number}-adw-{adw_id}-sdlc_planner-{descriptive-name}.md`
  - Replace `{descriptive-name}` with a short, descriptive name based on the chore (e.g., "update-readme", "fix-tests", "refactor-auth")
- Use the plan format below to create the plan. 
- Research the codebase and put together a plan to accomplish the chore.
- IMPORTANT: Replace every <placeholder> in the `Plan Format` with the requested value. Add as much detail as needed to accomplish the chore.
- Use your reasoning model: THINK HARD about the plan and the steps to accomplish the chore.
- IMPORTANT: This is an Elixir/Phoenix/OTP application. Keep changes idiomatic and typed per `BUILD_PROMPT.md` §3, build clean under `--warnings-as-errors`, and keep DB access behind `@spec`'d context modules (`BUILD_PROMPT.md` §8).
- If you need a new library, add it to `mix.exs` `deps/0` (pin a version per `BUILD_PROMPT.md` §2), run `mix deps.get`, and report it in the `Notes` section.
- This project uses **Tidewave** for Phoenix (runtime intelligence over MCP at `http://localhost:4000/tidewave/mcp`). Where a chore benefits from runtime verification, prefer Tidewave's `project_eval`, `execute_sql_query`, and `get_logs`, and `get_docs`/`get_source_location` for exact-version docs.
- Respect requested files in the `Relevant Files` section.
- Start your research by reading `BUILD_PROMPT.md` (the authoritative architecture/spec) and `README.md`.
- `adws/*.py` contain Astral `uv` single-file Python scripts. So if you want to run them use `uv run <script_name>`.
- When you finish creating the plan for the chore, follow the `Report` section to properly report the results of your work.

## Relevant Files

Focus on the following files:
- `BUILD_PROMPT.md` - The authoritative architecture/spec for the platform (tech stack §2, typed style guide §3, persistence §8, directory layout §11, milestones §12, testing §13).
- `README.md` - Project overview and run instructions.
- `AGENTS.md` - Agent/contributor conventions for this repo (if present).
- `mix.exs` - Project config, dependency pins, Dialyzer config, and `mix` aliases.
- `lib/repo_builder/**` - Business domain: contexts, Ecto schemas, OTP processes.
- `lib/repo_builder_web/**` - Web interface: Endpoint, Router, LiveViews, components, controllers.
- `config/**` - `config.exs`/`dev.exs`/`test.exs`/`runtime.exs`.
- `priv/repo/migrations/**` - Ecto migrations.
- `test/**` - ExUnit tests and `test/support/` cases.
- `scripts/**` - Helper scripts (e.g. `scripts/pg.sh`).
- `adws/**` - AI Developer Workflow (ADW) Python `uv` scripts.

- If `.claude/commands/conditional_docs.md` exists, read it to check if your task requires additional documentation, and include any matching docs in the `Plan Format: Relevant Files` section of your plan.

Ignore all other files in the codebase.

## Plan Format

```md
# Chore: <chore name>

## Metadata
issue_number: `{issue_number}`
adw_id: `{adw_id}`
issue_json: `{issue_json}`

## Chore Description
<describe the chore in detail>

## Relevant Files
Use these files to resolve the chore:

<find and list the files that are relevant to the chore describe why they are relevant in bullet points. If there are new files that need to be created to accomplish the chore, list them in an h3 'New Files' section.>

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

<list step by step tasks as h3 headers plus bullet points. use as many h3 headers as needed to accomplish the chore. Order matters, start with the foundational shared changes required to fix the chore then move on to the specific changes required to fix the chore. Your last step should be running the `Validation Commands` to validate the chore is complete with zero regressions.>

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

<list commands you'll use to validate with 100% confidence the chore is complete with zero regressions. every command must execute without errors so be specific about what you want to run to validate the chore is complete with zero regressions. Don't validate with curl commands.>
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.

## Notes
<optionally list any additional notes or context that are relevant to the chore that will be helpful to the developer>
```

## Chore
Interpret `REQUEST` per the `## Variables` contract: if it is JSON, use its `title` and
`body`; otherwise treat the entire `REQUEST` string as the chore request. If `REQUEST` is
empty or is only a few stray words (garbled positional fragments), STOP and report that the
caller should re-invoke with the full chore request (or the issue JSON) as a single
argument — do not fabricate a chore.

## Report

- IMPORTANT: Return exclusively the path to the plan file created and nothing else.
