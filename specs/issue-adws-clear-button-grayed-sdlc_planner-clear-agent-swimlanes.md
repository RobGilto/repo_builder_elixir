# Bug: ADWS "CLEAR" button stays grayed out when only agent swimlane cards are on screen

## Metadata
issue_number: `n/a` (filed from the console via `/bug` with a selected element, no issue number)
adw_id: `n/a`
issue_json: `n/a`

> Filed from the console at `http://localhost:4000/` (ADWS view). The user selected the
> `#clear-workflows` button and an agent swimlane card
> (`#swimlane-46fc691f-caca-4a0f-a744-888809b09135`) and reported: *"I am seeking to clear
> what is on the screen but the clear button is grayed out here."*

## Bug Description
In the ADWS view, the **CLEAR** button (`#clear-workflows`) is permanently disabled (grayed,
`opacity-40`, `cursor-not-allowed`) whenever the screen shows only **agent swimlane cards** and
no **finished workflow** cards. The user cannot clear the swimlane cards that are visibly on the
screen.

**Expected:** CLEAR is enabled whenever there is anything clearable in the ADWS view —
finished workflows *or* non-running agent swimlanes — and clicking it removes those cards while
leaving running work in place.

**Actual:** CLEAR's enabled-state and its click handler consider **only** `@workflow_progress`
(the ADW workflow cards). Agent swimlane cards (`@swimlanes`, derived from `@event_buffer`) are
ignored entirely, so:
- With zero finished workflows, the button is disabled even though finished/idle agent cards
  are on screen.
- Even if it were enabled, the handler would not remove any swimlane card.

## Problem Statement
The ADWS pane renders two independent card groups:
1. `#workflow-runs` — from `@workflow_progress` (ADW workflow runs).
2. `#agent-cards` — from `@swimlanes`, which `agent_swimlanes/1` derives by grouping
   `@event_buffer` by `agent_key`.

The CLEAR control only governs group (1). Its disable predicate
(`any_finished_workflows?(@workflow_progress)`) and its handler (`clear_workflows`) never look
at group (2). So when the ADWS view contains only agent swimlanes, there is no way to clear the
screen.

Runtime confirmation (live socket assigns for the reported view,
`RepoBuilderWeb.ConsoleLive`):
- `workflow_progress` → `%{}` (empty) ⇒ `any_finished_workflows?/1` returns `false` ⇒ button
  disabled.
- `event_buffer` → 240 rows across 3 `agent_key`s, including the selected worker
  `46fc691f-caca-4a0f-a744-888809b09135` (status defaults to `:idle`) and
  `orch-877c689b-…-3070530` (status `:succeeded`). These render as swimlane cards that CLEAR
  cannot touch.

## Solution Statement
Make the ADWS CLEAR button govern **both** card groups:
1. Enable the button when there are finished workflows **or** clearable (non-running) agent
   swimlanes.
2. Extend the `clear_workflows` handler to also remove clearable swimlanes from the view —
   dropping their rows from `@event_buffer`, `stream_delete`-ing them from the `:events` stream,
   and removing their `@statuses` entries — while keeping `:running` lanes.
3. Make the swimlane clear **durable across reconnect** for worker lanes (matching how the
   workflow clear soft-hides finished runs): add a `@spec`'d
   `RepoBuilder.Logs.hide_logs_for_agents/1` context function and call it (guarded by
   `unless @show_hidden?`) so cleared worker swimlanes do not reappear when `backfill_events/1`
   re-seeds from `Logs.list_recent_global/2` on reconnect.
4. Update the button label/`title` to reflect the broadened scope.

"Clearable swimlane" = a lane whose status is **not** `:running` (mirrors the existing "running
ones stay" semantics). The agent status enum is `:idle | :running | :error`; the `statuses` map
may also carry orchestrator terminal statuses (e.g. `:succeeded`) — all of which are clearable.

## Steps to Reproduce
1. `scripts/pg.sh start`, then `mix phx.server`; open `http://localhost:4000/` and switch to the
   ADWS view.
2. Produce state where at least one worker/agent has streamed events (so a swimlane card
   renders) but there are **no finished ADW workflow runs** in `@workflow_progress` (e.g. a
   plain worker run with no `start_adw` workflow, or after the workflow cards have already been
   cleared).
3. Observe the `#agent-cards` swimlane(s) on screen and the `#clear-workflows` CLEAR button
   rendered disabled (grayed, `cursor-not-allowed`).
4. There is no way to clear the visible swimlane cards.

Runtime reproduction (Tidewave `project_eval`) — confirms the disable cause:
```elixir
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid)  # pid of the ConsoleLive
map_size(socket.assigns.workflow_progress)          # => 0  (=> button disabled)
socket.assigns.event_buffer |> Enum.map(& &1.agent_key) |> Enum.uniq()  # => 3 swimlanes present
```

## Root Cause Analysis
The CLEAR control was built for workflow cards only and never extended when agent swimlane cards
were added to the same pane:

- `lib/repo_builder_web/live/console_live.ex:3066-3075` — the `#clear-workflows` button:
  `disabled={not any_finished_workflows?(@workflow_progress)}`.
- `lib/repo_builder_web/live/console_live.ex:3424-3429` — `any_finished_workflows?/1` only
  inspects `@workflow_progress`.
- `lib/repo_builder_web/live/console_live.ex:1571-1581` — the `clear_workflows` handler only
  rejects finished entries from `@workflow_progress`; it never touches `@event_buffer`,
  `:events`, or `@statuses`.
- `lib/repo_builder_web/live/console_live.ex:3106-3113` — `#agent-cards` renders `@swimlanes`,
  and `agent_swimlanes/1` (line 3431) derives them from `@event_buffer`, a source the CLEAR
  control does not consider.

Because `@workflow_progress` is empty in the reported view, the predicate returns `false` and
the button is disabled, even though clearable swimlane cards are present.

## Relevant Files
Use these files to fix the bug:

### Reference / Standards (read before implementing)
- `ai_docs/typed-elixir-standard.md` — typed-Elixir coding standard (always-row; `@spec` on every
  public function, precise types, `{:ok, t()} | {:error, reason()}` over raising, rule 10 float→Decimal).
- `BUILD_PROMPT.md §8` — context module convention (Repo/Ecto.Query must live behind context functions;
  LiveView never calls Repo directly — relevant for `hide_logs_for_agents/1` placement in `Logs`).
- `BUILD_PROMPT.md §9` — LiveView streams / swimlane / reconnect handling (ADWS pane, `stream_delete`,
  the buffer-backed stream pattern, the §9 reconnect re-seed rule that makes durable hiding necessary).
- `BUILD_PROMPT.md §13` and `AGENTS.md` — test conventions (ConnCase, async: false for PubSub tests,
  Ecto sandbox ownership, `wait_render/3` poller pattern).

- `lib/repo_builder_web/live/console_live.ex` — the ADWS pane, the `#clear-workflows` button
  (line 3066) and its `disabled` predicate (line 3070), the `clear_workflows` handler (line
  1571), `any_finished_workflows?/1` (line 3424), `agent_swimlanes/1` (line 3431),
  `@finished_workflow_statuses` (line 68), `event_buffer`/`:events` stream management, and
  `backfill_events/1` (line 762, reconnect re-seed). `@swimlanes` is recomputed from
  `@event_buffer` every render at line 2847 (`assign(assigns, :swimlanes, agent_swimlanes(assigns))`),
  so trimming `event_buffer` in the handler automatically clears the swimlane list. The
  `stream_delete` pattern to follow is in `handle_event("hide_selected", …)` at lines 1728–1734.
  All edits live here except the new context function.
- `lib/repo_builder/logs.ex` — add `@spec`'d `hide_logs_for_agents/1` alongside the existing
  `hide_logs/1` (line 299, hides by log row `id`) and `hide_all_logs/0` (line 213). **Key
  distinction:** `hide_logs_for_agents/1` hides by the `agent_id` column (FK) not by log row
  `id` — `where([l], l.agent_id in ^agent_ids)`. `backfill_events/1` reads through
  `list_recent_global/2` which respects the `hidden` flag, so hiding worker rows here is what
  makes the swimlane clear survive reconnect.
- `lib/repo_builder/agents/agent.ex` — reference only: confirms the `status` enum is
  `:idle | :running | :error` (line 16/38), which defines the non-running "clearable" rule.

### New Files
- `test/repo_builder_web/live/test_adws_clear_swimlanes_test.exs` — `Phoenix.LiveViewTest`
  integration test reproducing the disabled-button bug and proving the fix.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add a "clearable swimlane" predicate
- In `console_live.ex`, add a private helper immediately after `any_finished_workflows?/1`
  (line 3429):
  ```elixir
  @spec any_clearable_swimlanes?([map()]) :: boolean()
  defp any_clearable_swimlanes?(swimlanes) do
    Enum.any?(swimlanes, fn lane -> lane.status != :running end)
  end
  ```
  The `swimlanes` argument is the `@swimlanes` assign: a list of `%{key:, name:, status:,
  columns:}` maps produced by `agent_swimlanes/1`. The predicate mirrors
  `any_finished_workflows?/1`'s shape — positive when ANY lane is clearable.
- No new module attribute is needed; `:running` is the one kept-status and documenting it
  inline is sufficient (contrast with the multi-value `@finished_workflow_statuses` which
  warranted an attribute).

### 2. Enable the CLEAR button for swimlanes too
- Change the button's `disabled` attribute (line 3070) to:
  `disabled={not (any_finished_workflows?(@workflow_progress) or any_clearable_swimlanes?(@swimlanes))}`.
- Update the button label/`title` (line 3072) to state it clears finished workflows **and**
  non-running agent cards from the view, running ones stay, nothing is deleted (reversible via
  the settings "show hidden" toggle).

### 3. Add a context function to soft-hide a worker's logs (durability)
- In `lib/repo_builder/logs.ex`, add `hide_logs_for_agents/1` after `hide_logs/1` (line 308):
  ```elixir
  @doc """
  Soft-hide all `agent_logs` rows belonging to the given agent UUIDs (the console
  ADWS "CLEAR" swimlane action). Mirrors `hide_logs/1` but scoped to the `agent_id`
  FK column rather than log row `id`. An empty list is a no-op returning 0.
  Returns the count updated.
  """
  @spec hide_logs_for_agents([Ecto.UUID.t()]) :: non_neg_integer()
  def hide_logs_for_agents([]), do: 0

  def hide_logs_for_agents(agent_ids) when is_list(agent_ids) do
    {count, _} =
      AgentLog
      |> where([l], l.agent_id in ^agent_ids)
      |> Repo.update_all(set: [hidden: true])

    count
  end
  ```
  **Key distinction from `hide_logs/1`:** this function filters by the `agent_id` FK column,
  not by log row `id`. All rows ever produced by those agents are hidden in one query.
- This scopes durable hiding to **worker** swimlanes (whose `agent_key` is the worker's UUID
  `agent_id`). Orchestrator-derived lanes (`agent_key` like `"orch-…"`) are cleared view-only;
  their persistence is governed by the orchestrator/chat backfill path and is out of scope here
  (note this in the handler comment).

### 4. Extend the `clear_workflows` handler to clear swimlanes
- **Important:** `@swimlanes` is a **render-time derived assign** computed in `render/1` (line
  2847: `assign(assigns, :swimlanes, agent_swimlanes(assigns))`). It is NOT stored in
  `socket.assigns`. The handler must derive clearable keys from the real socket assigns
  `event_buffer` and `statuses`.
- In the `clear_workflows/3` handler (line 1571), extend it as follows:
  ```elixir
  def handle_event("clear_workflows", _params, socket) do
    # Existing: drop finished workflow cards and persist cleared state.
    _ = unless socket.assigns.show_hidden?, do: Workflows.hide_finished_runs()

    kept =
      socket.assigns.workflow_progress
      |> Enum.reject(fn {_run_id, view} -> view.status in @finished_workflow_statuses end)
      |> Map.new()

    # New: derive clearable agent_key set from event_buffer + statuses (not @swimlanes,
    # which is render-time only). Any key whose current status is not :running is clearable.
    clearable_keys =
      socket.assigns.event_buffer
      |> Enum.map(& &1.agent_key)
      |> Enum.uniq()
      |> Enum.reject(fn k -> Map.get(socket.assigns.statuses, k, :idle) == :running end)
      |> MapSet.new()

    # Trim event_buffer; @swimlanes auto-recomputes from it in render/1 (line 2847).
    {cleared_rows, kept_buffer} =
      Enum.split_with(socket.assigns.event_buffer, fn row ->
        MapSet.member?(clearable_keys, row.agent_key)
      end)

    # Drop clearable keys from @statuses so running_count/1 badge stays accurate.
    kept_statuses =
      Map.reject(socket.assigns.statuses, fn {k, _} -> MapSet.member?(clearable_keys, k) end)

    # Durable: soft-hide worker swimlanes (UUID-shaped agent_key) in the DB so the clear
    # survives a reconnect (backfill_events reads list_recent_global which respects hidden).
    # Orchestrator-derived lanes ("orch-…" keys) are cleared view-only; persisting those
    # is governed by the orchestrator/chat backfill path and is out of scope here.
    _ =
      unless socket.assigns.show_hidden? do
        worker_keys =
          clearable_keys
          |> Enum.filter(fn k -> match?({:ok, _}, Ecto.UUID.cast(k)) end)

        Logs.hide_logs_for_agents(worker_keys)
      end

    socket =
      socket
      |> assign(:workflow_progress, kept)
      |> assign(:event_buffer, kept_buffer)
      |> assign(:statuses, kept_statuses)

    # stream_delete each cleared row from :events (mirrors hide_selected, lines 1728-1734).
    socket = Enum.reduce(cleared_rows, socket, &stream_delete(&2, :events, &1))

    {:noreply, socket}
  end
  ```
- Keep the handler returning `{:noreply, socket}`; preserve "running ones stay / nothing
  deleted" semantics.

### 5. Verify the empty-state still behaves
- The empty-state block (line 3095) requires `@workflow_progress == %{} and @swimlanes == []`.
  After clearing, with no running lanes, both should be empty and the "No AI Developer
  Workflows found." card should show. Confirm no `@swimlanes` left referencing cleared rows
  (they are recomputed from `@event_buffer` in `render/1` via `assign(:swimlanes, …)` at
  line 2847).

### 6. Add a LiveView integration test (reproduces before, passes after)
- Create `test/repo_builder_web/live/test_adws_clear_swimlanes_test.exs` using
  `use RepoBuilderWeb.ConnCase, async: false`. Mirror the conventions in
  `test_release_hidden_logs_test.exs` (agent creation, log persistence, `list_recent_global`
  assertion) and `test_unified_adw_swimlane_cards_test.exs` (`wait_render/3` poller, ADWS view
  toggle, `has_element?` assertions). Include four test cases:

  **Test 1 — button disabled with empty view (regression guard):**
  ```elixir
  test "CLEAR is disabled when no agents or workflows are present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()
    # No agents, no events → button must be disabled
    refute has_element?(view, "#clear-workflows:not([disabled])")
    assert has_element?(view, "#no-adws")
  end
  ```

  **Test 2 — the bug: button enables on idle swimlane (core fix):**
  ```elixir
  test "CLEAR enables when a non-running agent swimlane is on screen (the bug fix)", %{conn: conn} do
    {:ok, agent} = Agents.create_agent(%{name: "idle-agent-#{uniq()}", harness: "fake", provider: :anthropic})
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    # Broadcast an event for the idle agent → swimlane card appears
    Dashboard.broadcast_event(agent.id, %Event.TextDelta{harness: :fake, text: "evt"})
    assert wait_render(view, "swimlane-#{agent.id}")

    # BUG BEFORE FIX: button would be disabled (only considers workflow_progress).
    # After fix: any_clearable_swimlanes?/1 returns true → button enabled.
    assert has_element?(view, "#clear-workflows:not([disabled])")

    render_click(view, "clear_workflows")

    refute has_element?(view, "#swimlane-#{agent.id}")
    assert has_element?(view, "#no-adws")
  end
  ```

  **Test 3 — durable clear: DB rows hidden after CLEAR:**
  ```elixir
  test "CLEAR soft-hides the worker's logs in the DB so the clear survives reconnect", %{conn: conn} do
    {:ok, agent} = Agents.create_agent(%{name: "dur-agent-#{uniq()}", harness: "fake", provider: :anthropic})
    marker = "marker-#{uniq()}"

    {:ok, _log} = Logs.persist_event(
      %Event.TextDelta{harness: :fake, text: marker},
      %{agent_id: agent.id, session_id: "s-#{uniq()}"}
    )

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    Dashboard.broadcast_event(agent.id, %Event.TextDelta{harness: :fake, text: marker})
    assert wait_render(view, "swimlane-#{agent.id}")

    render_click(view, "clear_workflows")

    # The persisted row is now hidden — won't reappear on reconnect
    payloads = Logs.list_recent_global(500, false) |> Enum.map(& &1.payload["text"])
    refute marker in payloads
  end
  ```

  **Test 4 — running lanes survive CLEAR:**
  ```elixir
  test "CLEAR removes idle swimlanes but keeps running ones", %{conn: conn} do
    {:ok, idle_agent} = Agents.create_agent(%{name: "idle-#{uniq()}", harness: "fake", provider: :anthropic})
    {:ok, running_agent} = Agents.create_agent(%{name: "run-#{uniq()}", harness: "fake", provider: :anthropic})
    {:ok, running_agent} = Agents.set_status(running_agent.id, :running)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    Dashboard.broadcast_event(idle_agent.id, %Event.TextDelta{harness: :fake, text: "i"})
    Dashboard.broadcast_event(running_agent.id, %Event.TextDelta{harness: :fake, text: "r"})
    Dashboard.broadcast_agent_updated(running_agent)  # sets @statuses to :running

    assert wait_render(view, "swimlane-#{idle_agent.id}")
    assert wait_render(view, "swimlane-#{running_agent.id}")

    render_click(view, "clear_workflows")

    refute has_element?(view, "#swimlane-#{idle_agent.id}")
    assert has_element?(view, "#swimlane-#{running_agent.id}")
  end
  ```

  Required aliases: `alias RepoBuilder.{Agents, Dashboard, Logs}` and
  `alias RepoBuilder.Harness.Event`. Add the `uniq/0` and `wait_render/3` private helpers
  (copy from `test_unified_adw_swimlane_cards_test.exs`).

### 7. Run the full validation gate
- Execute every command in **Validation Commands**; all must be green with zero new warnings
  (compiler + Dialyzer) and zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_adws_clear_swimlanes_test.exs` - The new LiveView
  test fails before the fix (button disabled / swimlane not cleared) and passes after.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Scope of durability:** worker swimlanes (UUID `agent_key`) are durably hidden via
  `Logs.hide_logs_for_agents/1`, consistent with how `clear_workflows` already soft-hides
  finished workflow runs and how `clear_filters` uses `hide_all_logs/0`. Orchestrator-derived
  lanes (`"orch-…"` keys) are cleared view-only; persisting those is governed by the orchestrator
  chat/backfill path and is intentionally out of scope for this surgical fix.
- **Shared buffer caveat:** `@event_buffer` also backs the LOGS `:events` stream, so clearing a
  swimlane removes that agent's rows from the LOGS view as well. This matches the sibling
  `clear_filters` behaviour (which clears the whole buffer) and the soft-hide model (reversible
  via the settings "show hidden" toggle); call it out in the button `title`.
- **No migration / no schema change** — `agent_logs.hidden` already exists and is the soft-hide
  mechanism used by the existing CLEAR paths.
- **Tidewave used while root-causing:** `Phoenix.LiveView.Debug.socket/1` on the live PID
  confirmed `workflow_progress == %{}` with 3 populated swimlanes; reuse it to verify the fix
  live. `get_logs`/`list_recent_global` confirm hidden-flag behaviour on reconnect.
