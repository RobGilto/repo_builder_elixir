# Bug: Allocated orchestrator's events are missing from the middle event-stream log

## Metadata
issue_number: `am`
adw_id: `noticing`
issue_json: `the`

## Bug Description
The console's middle column (the event-stream / "logs" view in `RepoBuilderWeb.ConsoleLive`)
is supposed to show the activity of the orchestrator that is allocated to the currently
active project, alongside that project's worker agents. In practice, **the allocated
orchestrator's events never appear in the middle log** while a project is active (which is
the default, since the console always mounts scoped to `Projects.default_project/0`).

- **Expected:** When the active project's orchestrator runs a turn (e.g. emits a
  `text_delta`, a tool call, an error like "no model selected", or any operation event),
  that activity streams into the middle event-stream column just like worker-agent events do.
- **Actual:** Worker-agent events appear, but orchestrator-originated events are silently
  dropped from the center stream. They are correctly persisted to `agent_logs` and the
  orchestrator chat (right pane) renders them, but they are filtered out of the middle log
  on both the live broadcast path and the reconnect backfill path.

This is a **filter false-negative**, not a data-loss bug: the events exist and are
broadcast/persisted; the LiveView's project-scope predicate rejects them due to an
agent-key format mismatch.

## Problem Statement
The project-scope filter `project_pass?/2` in `lib/repo_builder_web/live/console_live.ex`
decides whether an event row belongs to the active project by testing
`MapSet.member?(project_agent_keys, to_string(row.agent_key))`. This is an **exact-string**
membership test, but the orchestrator's `agent_key` and the set of "owned" keys are built
in **three mutually incompatible formats**, so the orchestrator's key never matches the set.

## Solution Statement
Make the orchestrator-ownership check format-tolerant. The active project has exactly one
bound orchestrator (`socket.assigns.orchestrator_id`, a UUID). Every orchestrator-originated
`agent_key` — live or backfilled — is of the form `"orch-<orchestrator_id>…"`. So augment
`project_pass?/2` to treat a row as project-owned when its `agent_key` is a worker id already
in `project_agent_keys` **or** it carries the active orchestrator's `"orch-<id>"` prefix.

This is a surgical, one-predicate change that fixes both the live path and the backfill path
at the single point where ownership is decided, without touching the broadcast key formats
(which other features — swimlanes, cost rollups keyed by `agent_key`, chat gating — depend on).

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, `mix phx.server`) and open `http://localhost:4000`.
2. The console mounts scoped to the default project with `project_scoped?: true` (default).
3. Cause the active project's orchestrator to emit an event. Easiest deterministic trigger:
   click **Run** on the orchestrator with **no model selected** — `Orchestrator.Server`
   emits an `Event.Error` ("no model selected …") via
   `Dashboard.broadcast_event("orch-<uuid>-<int>", event, log_no)`
   (`lib/repo_builder/orchestrator/server.ex:101,123`). Any orchestrator turn works too.
4. Observe the middle event-stream column: the orchestrator error/activity row **does not
   appear**. (The same row IS persisted to `agent_logs` and visible in the orchestrator
   chat pane.)
5. Toggle project scope OFF (the scope toggle, `console_live.ex:1420`) → the orchestrator
   row now appears, confirming the scope predicate is the culprit.

Runtime confirmation via Tidewave: use `project_eval` to call
`RepoBuilder.Dashboard.broadcast_event("orch-#{orch_id}-1", %RepoBuilder.Harness.Event.Error{...}, nil)`
for the active orchestrator id and watch it be filtered; use `execute_sql_query` on
`agent_logs` to confirm the row persisted with `orchestrator_id` set (proving it is a
filter bug, not an emission bug).

## Root Cause Analysis
The orchestrator's identity is encoded in **three incompatible string formats** that all flow
through one **exact-match** predicate:

1. **Owned-key set** — `project_agent_keys/1` (`console_live.ex:597-608`) builds the set from
   the bound orchestrator's **raw UUID**:
   ```elixir
   ids = if is_binary(orchestrator_id), do: [orchestrator_id | worker_ids], else: worker_ids
   MapSet.new(ids, &to_string/1)   # => #MapSet<["<uuid>", <worker-uuids…>]>
   ```

2. **Live broadcast key** — `Orchestrator.Server` (`server.ex:101,153`) and
   `Logs` (`logs.ex:138`) broadcast with a **suffixed** key:
   `"orch-<uuid>-<int>"` and `"orch-<uuid>-op-<int>"`. `record_event/4` stores this verbatim
   as `row.agent_key`.

3. **Backfill key** — `log_to_row/4` (`console_live.ex:3757-3761`) synthesizes a
   **prefix-only** key for persisted orchestrator rows: `"orch-<uuid>"` (no suffix).

The predicate (`console_live.ex:2844-2851`):
```elixir
MapSet.member?(assigns.project_agent_keys, to_string(row.agent_key))
```
compares `"orch-<uuid>-42"` (live) or `"orch-<uuid>"` (backfill) against a set that contains
only the bare `"<uuid>"`. Neither matches, so `project_pass?/2` returns `false` and
`maybe_stream_insert/2` (`console_live.ex:2644-2650`) drops the row. Because
`project_scoped?` defaults to `true` and a project is always active, the orchestrator is
**always** filtered out of the middle log. Worker agents are unaffected because their
`agent_key` is the bare worker UUID, which matches the set exactly.

The fix must reconcile these formats at the ownership decision. The minimal, robust choice is
a **prefix-aware** orchestrator check keyed off the single active `orchestrator_id`, since
all three orchestrator formats share the `"orch-<orchestrator_id>"` prefix and worker UUIDs
never collide with it.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — **primary fix site.**
  - `project_pass?/2` (lines 2843-2851): the exact-match predicate to make prefix-aware.
  - `project_agent_keys/1` (lines 596-608): builds the owned-key set from the bare
    orchestrator UUID; documents the intent ("orchestrator id ∪ worker ids").
  - `maybe_stream_insert/2` (lines 2644-2650) and `passes?/2` (lines 2831-2837): the gate the
    predicate feeds; read-only context for understanding the drop.
  - `assign_orchestrator/1` / `switch_orchestrator/1` and the `:orchestrator_id` assign:
    confirm `assigns.orchestrator_id` is the active project's bound orchestrator UUID and is
    available to `project_pass?/2` via `assigns`.
  - `log_to_row/4` (lines 3749-3794): the backfill key `"orch-<orch_id>"` the fix must also
    accept (the prefix check covers it).
- `lib/repo_builder/orchestrator/server.ex` — source of the live `"orch-<uuid>-<int>"`
  broadcast keys (lines 101, 123, 153); read-only, do **not** change the key format.
- `lib/repo_builder/logs.ex` — `"orch-<uuid>-op-<int>"` operation key (line 138) and
  `persist_orchestrator_event/2`; confirms persistence is correct (read-only).
- `lib/repo_builder/orchestrator.ex` — `get_or_create_for_project/1`; confirms one bound
  orchestrator per project (read-only).
- `test/repo_builder_web/live/test_orchestrator_project_switch_test.exs` — reference for the
  ConnCase + `live/2` + `select_project` + `Orchestrators.get_or_create_for_project/1` setup
  the new test will mirror.

### New Files
- `test/repo_builder_web/live/test_orchestrator_events_in_scoped_log_test.exs` — a
  `Phoenix.LiveViewTest` integration test that mounts the scoped console, resolves the active
  project's bound orchestrator, broadcasts a live orchestrator event with the real
  `"orch-<id>-<int>"` key, and asserts the row appears in the `:events` stream. Fails before
  the fix (filtered out), passes after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the root cause at runtime
- With the app running, use Tidewave `get_logs` and `execute_sql_query` to confirm an
  orchestrator event is persisted (row in `agent_logs` with `orchestrator_id` set) yet absent
  from the rendered middle stream, ruling out an emission bug.
- Inspect `assigns.orchestrator_id`, `assigns.project_agent_keys`, and a sample orchestrator
  `row.agent_key` (via `project_eval` or temporary logging) to confirm the
  `"orch-<uuid>-<int>"` vs `"<uuid>"` mismatch described in Root Cause Analysis.

### 2. Add the failing LiveView integration test (red)
- Create `test/repo_builder_web/live/test_orchestrator_events_in_scoped_log_test.exs`
  (`async: false`, `use RepoBuilderWeb.ConnCase`), mirroring the fixture style of
  `test_orchestrator_project_switch_test.exs`.
- In the test:
  - Mount `live(conn, ~p"/")`; the console is scoped to the default project with
    `project_scoped?: true`.
  - Resolve the active orchestrator: `{:ok, orch} = Orchestrators.get_or_create_for_project(<active project id>)`
    (use `Projects.default_project/0` to get the mounted project, matching the switch test).
  - Build a canonical orchestrator event and the **live-format** key
    `agent_id = "orch-#{orch.id}-#{System.unique_integer([:positive])}"`, then drive the
    LiveView's event path the same way the live broadcast does — prefer
    `Dashboard.broadcast_event(agent_id, event, nil)` (the LiveView is subscribed to the
    global event feed) and `render(view)`; if PubSub delivery is racy in test, fall back to
    `send(view.pid, {:agent_event, agent_id, event, nil})` to exercise `record_event/4`
    directly. Use a stable, searchable marker string in the event body.
  - Assert the marker is present in the rendered middle stream (e.g.
    `assert render(view) =~ marker` or `has_element?(view, "#event-stream …", marker)`),
    using a DOM id/region scoped to the `:events` stream, not the chat pane.
  - Add a complementary assertion that a worker-agent event for the same project still
    appears (guards against an over-broad fix that breaks worker scoping) and, optionally,
    that an UNRELATED project's orchestrator event is still excluded (guards against
    fail-open regression).
- Run the test and confirm it **fails** on the orchestrator assertion before the fix.

### 3. Implement the surgical fix in `project_pass?/2`
- In `lib/repo_builder_web/live/console_live.ex`, change the project-scope predicate so a row
  is project-owned when it is a known worker key **or** carries the active orchestrator's
  prefix. Keep the existing fail-open branch unchanged. Concretely, replace the membership
  line with a check equivalent to:
  ```elixir
  key = to_string(row.agent_key)

  MapSet.member?(assigns.project_agent_keys, key) or
    orchestrator_owned?(key, assigns[:orchestrator_id])
  ```
  and add a private, `@spec`'d helper:
  ```elixir
  @spec orchestrator_owned?(String.t(), String.t() | nil) :: boolean()
  defp orchestrator_owned?(_key, nil), do: false
  defp orchestrator_owned?(key, orchestrator_id),
    do: String.starts_with?(key, "orch-#{orchestrator_id}")
  ```
- Keep `project_agent_keys/1` as the worker-id set (it may continue to also include the bare
  orchestrator UUID harmlessly). Update the surrounding doc comments on `project_pass?/2` /
  `project_agent_keys/1` to state that orchestrator ownership is matched by the
  `"orch-<orchestrator_id>"` prefix across the live (`-<int>`, `-op-<int>`) and backfill
  (no-suffix) key formats — so the rationale is captured at the fix site and we don't
  regress it later.
- Ensure `assigns[:orchestrator_id]` is reliably present wherever `passes?/2` runs
  (mount, restream, live insert, backfill); it is set by `assign_orchestrator/1` /
  `switch_orchestrator/1`. Use `assigns[:orchestrator_id]` (bracket access) to be nil-safe.

### 4. Re-run the new test (green) and guard against regressions
- Run `mix test test/repo_builder_web/live/test_orchestrator_events_in_scoped_log_test.exs`
  and confirm all assertions pass: orchestrator event present, worker event present,
  unrelated-project orchestrator event still excluded.
- Run the existing orchestrator/console/project tests to confirm no scoping regression:
  `mix test test/repo_builder_web/live/test_orchestrator_project_switch_test.exs test/repo_builder_web/live/test_orchestration_console_test.exs`.

### 5. (Optional) Visual proof
- With the app running, trigger an orchestrator event and capture a screenshot of
  `http://localhost:4000` via Tidewave Web vision mode (or Playwright MCP) showing the
  orchestrator row in the middle event-stream column. Do not use the screenshot to judge
  styling — only as functional proof the row now appears.

### 6. Run the full validation suite
- Execute every command in **Validation Commands** and confirm all pass with zero failures
  and zero new warnings.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_orchestrator_events_in_scoped_log_test.exs` — the
  new integration test: fails before the fix, passes after (orchestrator event now streams to
  the middle log; worker scoping and cross-project exclusion preserved).
- `mix test test/repo_builder_web/live/test_orchestrator_project_switch_test.exs test/repo_builder_web/live/test_orchestration_console_test.exs` — orchestrator/console scoping regression guard.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` — formatting check.
- `mix credo --strict` — lint, including the every-public-function-has-an-`@spec` gate (the new private helper carries an `@spec`).
- `mix dialyzer` — contract checking with no new warnings and no stale ignore filters.

## Notes
- **Why prefix-match on `orchestrator_id`, not normalize the key formats:** the three key
  formats are each load-bearing elsewhere — the `-<int>`/`-op-<int>` suffix keeps concurrent
  orchestrator operations distinct for cost rollups and swimlane keying; the backfill
  `"orch-<id>"` form is also matched by `orchestrator_event?/1` for chat-history gating. The
  bound project has exactly one orchestrator (`Orchestrators.get_or_create_for_project/1`), so
  a prefix check against the single active `orchestrator_id` is both correct and minimal, and
  fixes the live and backfill paths at one site.
- **No new dependencies, no migration.** Pure LiveView predicate change plus one test.
- **Fail-open behavior is preserved:** scope-off, no active project, or an empty
  owned-key set still pass everything through, exactly as today.
- Confirm via Tidewave that worker UUIDs can never be prefixed by `"orch-"` (Ecto
  `binary_id`/UUIDv4 are hex+hyphen with no `"orch-"` prefix), so the prefix check cannot
  misclassify a worker row.
