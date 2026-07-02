---
command: implement_elixir
version: 1.0.0
description: Elixir-native implement step — build a plan/spec (or inline request) into this Phoenix/OTP app and make the mix green gate pass. Immune to slash-command argument garbling.
argument-hint: [path-to-plan | inline request]
allowed-tools: Read, Write, Edit, Bash
---

# Implement (Elixir)

Follow the `Workflow` to implement `REQUEST` into this **Elixir/Phoenix/OTP** codebase,
then `Report` the completed work. This is the load-bearing build step of the ADW pipeline —
leave the repo compiling, formatted, typed, and green.

## Variables

REQUEST: $ARGUMENTS

> **Argument contract (why `$ARGUMENTS`, not `$1 $2 $3`).** This command takes the
> **entire** argument string as one lossless value. Do NOT rely on positional
> variables (`$1`/`$2`/`$3`): Claude Code fills those by splitting on whitespace, so any
> argument that contains spaces — a JSON payload, or a freeform sentence — gets shredded
> across the slots (`/feature the workstreams ui` → `$1=the`, `$2=workstreams`, `$3=ui`).
> By binding the whole string to `$ARGUMENTS`, `REQUEST` always arrives intact. This is
> the Elixir-side fix for the arg-garbling defect: keep the argument boundary in one
> variable and interpret it here, in the prompt, rather than at the whitespace-splitting
> dispatcher.

## Workflow

### 0. Resolve `REQUEST` (robust — never garble)

- If `REQUEST` is empty/blank, STOP immediately and report the error (nothing to implement).
- Otherwise classify `REQUEST` yourself — do not assume it is a bare path:
  - **A spec/plan path** — it names a readable file (e.g. `specs/issue-….md`). Read that
    file and implement it as the plan.
  - **A JSON blob** — it parses as JSON (has `title`/`body` or `number`). Treat
    `title`+`body` as the request and, if no matching `specs/…` plan exists yet, implement
    directly from that description.
  - **Freeform prose** — anything else. Treat the full `REQUEST` string as the inline build
    instruction. Do NOT bind individual words to positional variables, and do NOT invent a
    spec file unless the work clearly needs one.
- If `REQUEST` looks like garbled positional fragments (e.g. three stray words such as
  `the workstreams ui`), STOP and report that the caller likely passed positional args to a
  `$ARGUMENTS` command — ask them to re-invoke with the whole request (or a spec path) as a
  single argument. Never fabricate a plan from garbled fragments.

### 1. Implement

- Think hard, then implement every step of the plan's `Step by Step Tasks` (for a spec) or
  the full inline request, following any `Acceptance Criteria`.
- Honor the typed style guide in `BUILD_PROMPT.md` §3: an `@spec` on every public function
  (`@impl true` callbacks are exempt), `@type`/`typedstruct`/`@enforce_keys` for domain
  data, precise types over `any()`/`map()`, `{:ok, t()} | {:error, reason()}` over raising.
  Keep DB access behind `@spec`'d context modules — LiveViews/controllers/OTP processes
  never touch `Repo`/`Ecto.Query` directly (§8).
- Follow existing patterns and conventions; reuse existing components/contexts. Don't
  reinvent the wheel. Read `AGENTS.md`, `README.md`, and `BUILD_PROMPT.md` as needed.
- If the change touches the LiveView dashboard or user interactions (§9), add or update a
  `Phoenix.LiveViewTest` integration test that fails before and passes after your change.
  When the app is running, you may use **Tidewave** (`http://localhost:4000/tidewave/mcp`:
  `get_logs`, `project_eval`, `execute_sql_query`, `get_docs`) to reproduce/verify behavior
  rather than guessing.

### Worktree setup (this may be a fresh isolated worktree)

- Toolchain is mise-pinned (Erlang/Elixir/Postgres). If `mix` can't resolve deps or
  `deps/` is absent, set the worktree up before compiling, in order:
  `mix deps.get` → `scripts/patch_deps.sh` (patches `type_check` for Elixir 1.20 — REQUIRED
  before compiling) → `mix deps.compile type_check && mix compile`.
- Postgres for the test step is a separate running cluster on `localhost:5432`
  (postgres/trust); `mix test` will create the test DB. Do NOT start/stop the cluster.

## Validation

Run the plan's `Validation Commands` (if a spec provided them). At minimum these must pass
before you finish:

- `mix compile --warnings-as-errors` — clean; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix format` (then `mix format --check-formatted`)
- `mix credo --strict` — includes the "every public function has an `@spec`" convention.
- `mix test --warnings-as-errors`

`mix dialyzer` is best-effort in a fresh worktree (PLT build is slow) — run it if time
allows and fix any new warnings; never delete or weaken existing ignore filters.

Fix every failure you introduce. Do NOT leave the build red, do NOT commit (the workflow
commits separately), and do NOT push.

## Report

- Summarize the work in a concise bullet list.
- State how you interpreted `REQUEST` (spec path / JSON / freeform inline).
- Report files and total lines changed with `git diff --stat`.
- State the final status of each validation command you ran.
