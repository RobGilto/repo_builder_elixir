# Bug: Worker spawn fails with misleading `orchestrator_id has already been taken`

## Metadata
issue_number: `doing`
adw_id: `a`
issue_json: `research`

## Bug Description
During a research project, the orchestrator (`orch-877`) tried to spawn one or more
workers and each spawn failed with:

```
invalid agent: %{orchestrator_id: ["has already been taken"]}
```

The orchestrator LLM then **misdiagnosed** the failure ("Spawns failed with an odd
error. Let me check config to use the correct tier-based spawning.") and went off to
re-read `get_config`, wasting a turn — because the surfaced error points at
`orchestrator_id`, implying an ownership/tier/config problem, when the real cause is a
**duplicate worker name within the same orchestrator**.

- **Expected:** When a spawn collides on a name already used by that orchestrator, the
  error should clearly say the *name* is a duplicate, so the orchestrator can simply
  retry with a different name. (Spawning a fresh, uniquely-named worker should succeed.)
- **Actual:** The error blames `orchestrator_id` ("has already been taken"), which is
  confusing and non-actionable, causing the orchestrator to chase a non-existent config
  issue.

## Problem Statement
The composite per-orchestrator uniqueness rule on agents (`(orchestrator_id, name)`) is
attached to the changeset such that, on violation, Ecto reports the error against the
**first field in the list** (`:orchestrator_id`). The orchestrator tool layer's
human-readable error mapper only recognises a `:name` error as a duplicate-name case, so
the composite violation falls through to a generic, misleading message.

## Solution Statement
Attach the composite unique-constraint violation to the `:name` field (still keyed to the
existing `:agents_orchestrator_id_name_index` index) so that:

1. The Ecto changeset error reads `%{name: ["has already been taken"]}`.
2. `RepoBuilder.Orchestrator.Tools.changeset_reason/1` — which already special-cases
   `%{name: [_ | _]}` → `"duplicate or invalid name"` — produces an actionable message.

This is a one-line, surgical change in the changeset. **No migration is needed** (the
underlying DB index `:agents_orchestrator_id_name_index` is unchanged; only the
changeset field the error is reported on changes).

## Steps to Reproduce
1. Pick any orchestrator id `oid`.
2. Spawn (create) a worker named `"w1"` for `oid` — succeeds.
3. Spawn another worker named `"w1"` for the **same** `oid`.
4. Observe the returned error: `invalid agent: %{orchestrator_id: ["has already been taken"]}`.

Reproduce inside the running app via Tidewave `project_eval`:

```elixir
alias RepoBuilder.{Agents, Orchestrators}
# create/fetch an orchestrator to get a valid orchestrator_id (FK)
{:ok, o} = Orchestrators.create(%{name: "repro-#{System.unique_integer([:positive])}", harness: "fake"})
p = %{"name" => "dupe", "harness" => "fake", "provider" => "anthropic"}
{:ok, _} = Agents.create_worker(o.id, p)
{:error, cs} = Agents.create_worker(o.id, p)
Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)
#=> BEFORE fix: %{orchestrator_id: ["has already been taken"]}
#=> AFTER  fix: %{name: ["has already been taken"]}
```

(Confirm the exact `Orchestrators` create/fetch helper name and required fields with
`get_source_location`/reading `lib/repo_builder/orchestrators*.ex` before running; adjust
the setup line accordingly. The assertion of interest is which key the error lands on.)

## Root Cause Analysis
- `lib/repo_builder/agents/agent.ex` `worker_changeset/2` ends with:
  ```elixir
  |> unique_constraint([:orchestrator_id, :name], name: :agents_orchestrator_id_name_index)
  ```
  When given a **list** of fields, `Ecto.Changeset.unique_constraint/3` attaches the
  `"has already been taken"` error to the **first** field, `:orchestrator_id`. So a
  duplicate `(orchestrator_id, name)` insert surfaces as
  `%{orchestrator_id: ["has already been taken"]}`.
- `lib/repo_builder/orchestrator/tools.ex` `changeset_reason/1` (lines ~1136–1149) maps
  `%{name: [_ | _]}` → `"duplicate or invalid name"`, but any other shape →
  `"invalid agent: #{inspect(errors)}"`. The composite violation lands on
  `:orchestrator_id`, so it hits the generic branch and produces the misleading text
  seen in the logs (`log-3543`/`log-3544`).
- The DB index `:agents_orchestrator_id_name_index` (created in
  `priv/repo/migrations/20260616000002_add_orchestrator_fields_to_agents.exs`) is correct
  and unchanged; only the **changeset field the error is reported on** is wrong for the
  message-mapping layer.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/agents/agent.ex` — **fix site.** `worker_changeset/2`'s
  `unique_constraint/3` reports the composite-index violation on `:orchestrator_id`
  instead of `:name`. Change it to attach to `:name` while keeping the same index name.
- `lib/repo_builder/orchestrator/tools.ex` — `changeset_reason/1` consumes the changeset
  errors and already has the desired `%{name: [_ | _]}` → `"duplicate or invalid name"`
  branch; no change required, but it documents the intended target shape.
- `lib/repo_builder/agents.ex` — `create_worker/2` is the insert path that triggers the
  constraint; read-only context for the fix and tests.
- `priv/repo/migrations/20260616000002_add_orchestrator_fields_to_agents.exs` — confirms
  the index name `:agents_orchestrator_id_name_index`; no migration change needed.
- `BUILD_PROMPT.md` — §3 typed style and §8 persistence rules the fix must respect
  (preserve `@spec`s, keep DB access behind context modules).

### New Files
- `test/repo_builder/agents/worker_changeset_dup_name_test.exs` — new ExUnit test that
  asserts a duplicate `(orchestrator_id, name)` insert returns a changeset whose error is
  on `:name` (fails before the fix, passes after), and that
  `RepoBuilder.Orchestrator.Tools` surfaces `"duplicate or invalid name"` for that case.
  (If an existing agents/worker test module already covers `create_worker/2`, add the
  cases there instead of creating a new file — confirm by checking
  `test/repo_builder/` for an agents test before adding a new file.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the failure shape in the running app (Tidewave)
- Use Tidewave `get_logs` to re-read the original stacktrace/error context if still
  available.
- Use Tidewave `project_eval` with the snippet in **Steps to Reproduce** to confirm the
  pre-fix error lands on `:orchestrator_id`.
- Use `get_source_location` to confirm the exact `Orchestrators` create/fetch helper used
  in the repro setup so the FK is satisfied.

### 2. Add the failing test (red)
- Create `test/repo_builder/agents/worker_changeset_dup_name_test.exs` (or extend the
  existing agents test module). Use the project's DataCase/SessionCase test support.
- Test A: insert a worker for an orchestrator, then insert a second worker with the same
  name for the same orchestrator via `RepoBuilder.Agents.create_worker/2`; assert
  `{:error, changeset}` and that `Ecto.Changeset.traverse_errors/2` returns the error
  under `:name` (NOT `:orchestrator_id`).
- Test B (regression guard): assert two workers with the **same name** under **different**
  orchestrators both insert successfully (per-orchestrator scoping still holds).
- Test C: assert the orchestrator tool boundary returns the friendly message — call the
  spawn tool (`RepoBuilder.Orchestrator.Tools.call("spawn_agent"/applicable name, oid,
  args)`) twice with the same name and assert the second returns
  `{:error, "duplicate or invalid name"}`. (Confirm the exact catalog tool name for
  create/spawn from `lib/repo_builder/orchestrator/tool_catalog.ex`.)
- Run the test and confirm Test A and Test C **fail** before the fix.

### 3. Apply the surgical fix
- In `lib/repo_builder/agents/agent.ex` `worker_changeset/2`, replace:
  ```elixir
  |> unique_constraint([:orchestrator_id, :name], name: :agents_orchestrator_id_name_index)
  ```
  with:
  ```elixir
  |> unique_constraint(:name, name: :agents_orchestrator_id_name_index)
  ```
- Keep the `@spec` and all other changeset steps intact. Update the nearby doc/comment if
  it implies the error lands on `orchestrator_id`.

### 4. Verify green
- Re-run the new test file; Tests A, B, C must pass.
- Re-run the repro `project_eval` snippet; the error must now land on `:name`.

### 5. Full regression gate
- Run all `Validation Commands` below; every command must pass with zero failures and no
  new warnings.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/agents/worker_changeset_dup_name_test.exs` - The new test
  (red before the fix, green after) proving the error lands on `:name`, per-orchestrator
  scoping still allows same-name workers across orchestrators, and the tool boundary
  returns `"duplicate or invalid name"`.
- `mix compile --warnings-as-errors` - Compile clean; gradual set-theoretic type checker
  and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Full ExUnit suite (Postgres-backed) with zero
  failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`"
  convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore
  filters.

## Notes
- **No migration and no library additions.** The DB index
  `:agents_orchestrator_id_name_index` is correct and unchanged; the fix only changes
  which changeset field reports the violation so the existing message-mapping in
  `changeset_reason/1` produces an actionable error.
- Ecto semantics: `unique_constraint/3` given a **single** field attaches the error to
  that field while still matching the named composite index — this is the intended idiom
  and is why no DB change is required.
- Out of scope (do not chase): whatever made the orchestrator pick a duplicate name in
  the first place (e.g. retry/idempotency of spawns). This plan fixes the *misleading
  error* root cause so the orchestrator can self-correct by choosing a unique name. If a
  duplicate-name retry-loop is later observed, file it as a separate issue.
- This is not a LiveView UI bug (it surfaces as an orchestrator TOOL log/return value), so
  no `Phoenix.LiveViewTest` integration test is required.
