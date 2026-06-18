# Bug: Orchestrator-assigned agent-model tiers are not reflected in the Agent Models modal

## Metadata
issue_number: `request`
adw_id: `the`
issue_json: `orchestrator`

## Bug Description
The operator asked the orchestrator (a `pi` / `glm-5.1` / `zai` session) to assign the four
worker-model tiers (`fast`, `main`, `heavy`, `leader`). The orchestrator drove the
`configure_tier` tool four times and each call returned
`{"status":"configured", ...}` with the concrete Anthropic ids:

| Tier   | Reported model        |
|--------|-----------------------|
| fast   | `claude-haiku-4-5`    |
| main   | `claude-sonnet-4-5`   |
| heavy  | `claude-opus-4-5`     |
| leader | `claude-opus-4-5`     |

Yet the **AGENT MODELS** modal in `ConsoleLive` (screenshot in the report) shows:

- Header counter: **`2/4 configured`** (expected `4/4`).
- All four **model** dropdowns: **`no model (won't spawn)…`** (expected the assigned id selected).
- `fast` + `leader` show `provider = anthropic`; `main` + `heavy` show `provider…` (blank).

**Expected vs actual.** Expected: after the orchestrator configures all four tiers, the
modal reflects four configured tiers, each with its harness/provider/model selected, and
each tier is spawnable. Actual: only two tiers retained any data at all, and even those two
render with an empty model selection — so the operator cannot see or trust what was set, and
the orchestrator believes it can spawn into tiers the UI shows as unset.

## Problem Statement
Two **independent** defects combine to produce the symptom. Both must be fixed for the
operator's end-to-end scenario ("set all four tiers, see all four reflected") to work:

1. **Data loss (explains `2/4` and the blank `main`/`heavy`):** the four `configure_tier`
   tool calls each perform an *unsynchronized read-modify-write* of the single orchestrator
   row's `metadata["agent_models"]` JSON map. Because the four calls arrive as **concurrent**
   HTTP requests, concurrent stale reads overwrite one another (lost updates) and only a
   subset of the four category writes survives — even though every individual tool call
   reports `configured`.

2. **Display (explains the survivors still showing `no model`):** the modal builds each
   row's model `<option>` list from the harness registry's curated list. For the `claude`
   harness that list is the **abstract tier aliases** `["opus", "sonnet", "haiku"]`, which
   does **not** contain the concrete ids the orchestrator assigns
   (`claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-opus-4-5`). The model `<select>` only
   marks an option `selected` when the stored model is present among its options, so a
   stored-but-unlisted model renders as the blank `no model (won't spawn)…` default.

## Solution Statement
- **Fix #1 (root cause of data loss):** make `RepoBuilder.Orchestrators.set_agent_model/3`
  atomic. Wrap the read-merge-write in a single DB transaction that locks the orchestrator
  row (`SELECT … FOR UPDATE`) before merging the category entry into
  `metadata["agent_models"]`, so concurrent tier writes serialize and accumulate instead of
  clobbering each other. This is the minimal, idiomatic Ecto/Postgres fix and changes no
  public behavior or return contract.

- **Fix #2 (display):** in `ConsoleLive.agent_model_rows/1`, guarantee the currently-assigned
  model id is always present in the row's `model_options` (prepend it when the registry list
  omits it), mirroring the existing `model_extra` "Current" handling already used by the
  orchestrator-model header dropdown in `ConsoleComponents.orchestrator_console_header/1`.
  This makes any stored model render as `selected` regardless of whether the registry curates
  it.

Both fixes are surgical: Fix #1 is contained to one private read-modify-write in the
`Orchestrators` context; Fix #2 is contained to one row-builder in `ConsoleLive`. No schema,
migration, tool-contract, or harness-event change is required.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, then `iex -S mix phx.server`) and open
   `http://localhost:4000`.
2. Drive the orchestrator to assign all four tiers to concrete Anthropic ids (as in the
   report), or reproduce the data-loss directly in code (deterministic, no UI):
   ```elixir
   # Tidewave project_eval — concurrent writers, the real failure mode:
   {:ok, orch} = RepoBuilder.Orchestrators.get_or_create_default("claude")

   ~w(fast main heavy leader)
   |> Task.async_stream(
     fn cat ->
       RepoBuilder.Orchestrators.set_agent_model(orch.id, cat, %{
         "harness" => "claude", "provider" => "anthropic",
         "model" => "claude-opus-4-5"
       })
     end,
     max_concurrency: 4, timeout: :infinity
   )
   |> Stream.run()

   {:ok, after} = RepoBuilder.Orchestrators.fetch(orch.id)
   RepoBuilder.Orchestrators.agent_models(after) |> map_size()
   # BUG: < 4 (lost updates). EXPECTED: 4.
   ```
3. Open the **AGENT MODELS** modal (the agents toggle in the console header).
4. Observe the counter shows `<4>/4 configured` and every model dropdown reads
   `no model (won't spawn)…` even for tiers that did persist a model.

## Root Cause Analysis
**Defect A — lost-update race in `set_agent_model/3`.**
`lib/repo_builder/orchestrator.ex`:
```elixir
def set_agent_model(id, category, attrs) when category in @agent_categories do
  case fetch(id) do                                   # (1) read snapshot of metadata
    {:ok, %Orchestrator{metadata: metadata}} ->
      entry = %{...}
      roster = Map.put(Map.get(metadata, "agent_models", %{}), category, entry)  # (2) merge
      with {:ok, updated} <-
             update_fields(id, %{metadata: Map.put(metadata, "agent_models", roster)}) do  # (3) write whole map
        ...
```
Steps (1)→(3) are not atomic. Orchestrator tool calls from real harnesses are delivered over
HTTP to `RepoBuilderWeb.OrchestratorMcpController.rpc/2` (`tools/call`), and **each request is
served by its own process** — they are not serialized through `Orchestrator.Server` (only the
in-process `Fake` loop serializes tool calls via `handle_info({:harness_event, %ToolCall{}}, …)`).
When the orchestrator fires `configure_tier` for all four tiers in quick succession, several
handlers read the same stale `metadata` at step (1), each computes a `roster` containing only
*its* category plus whatever it read, and the last writer at step (3) wins — dropping the other
categories' entries. Each call still returns `{:ok, …}` ("configured"), so the loss is silent.
The observed `2/4` (rather than `1/4`) is just one possible interleaving.

**Defect B — assigned model id absent from the modal's option list.**
The modal (`ConsoleComponents.agent_models_modal/1`) renders the model `<select>` as:
```elixir
<option value="" selected={row.model in [nil, ""]}>no model (won't spawn)…</option>
<option :for={m <- row.model_options} value={m} selected={row.model == m}>{m}</option>
```
`row.model_options` comes from `ConsoleLive.agent_model_rows/1` →
`model_options_for(harness, provider)` → for `claude`,
`HarnessRegistry.orchestrator_models("claude", "anthropic")`, which is configured in
`config/config.exs` as `models: %{"anthropic" => ["opus", "sonnet", "haiku"]}` (abstract tier
aliases). The orchestrator stores concrete ids (`claude-haiku-4-5`, `claude-sonnet-4-5`,
`claude-opus-4-5`), none of which appear in that list. Therefore no `<option>` matches
`row.model`, the only `selected` option is the blank fallback, and the select displays
`no model (won't spawn)…`. (The `provider` select is unaffected because
`provider_options_for("claude")` yields `["anthropic"]`, which contains the stored provider —
consistent with the screenshot's `fast`/`leader` showing `anthropic`.) Note the orchestrator
header's own model dropdown already solves this exact problem via the `model_extra` "Current"
optgroup in `ConsoleComponents` — the per-tier rows simply never got the same treatment.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator.ex` — the `Orchestrators` context; **Fix #1** lives in
  `set_agent_model/3`. Already `import Ecto.Query, only: [from: 2]` and aliases `Repo`, so the
  locking query and transaction are in-module with no new imports beyond widening the
  `from/2` import (or using a keyword `lock:`). `update_record/2` is reused for the write.
- `lib/repo_builder_web/live/console_live.ex` — `agent_model_rows/1` builds the modal rows;
  **Fix #2** prepends the assigned model into `model_options`. `configured_tier_count/1` and
  `model_options_for/2` are the neighbors to keep consistent.
- `lib/repo_builder_web/components/console_components.ex` — `agent_models_modal/1` renders the
  rows; reference the existing `orchestrator_console_header/1` `model_extra` pattern (no change
  required here, but it is the template for Fix #2's behavior). No edit expected unless a row
  needs an explicit "Current" affordance.
- `lib/repo_builder/orchestrator/tools.ex` — `configure_tier/2` → `Orchestrators.set_agent_model/3`
  is the tool entry the orchestrator drives; read-only confirmation that the tool contract and
  return shape are unchanged by Fix #1.
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — confirms the concurrent
  per-request delivery path (`tools/call` → `Tools.call`) that makes the race reachable.
- `config/config.exs` — the `:harnesses` registry; shows the curated `claude/anthropic` model
  list is tier aliases, not concrete ids (the source of Defect B). **Do not** "fix" this by
  stuffing concrete ids in config — Fix #2 is the correct, registry-agnostic fix.
- `BUILD_PROMPT.md` §8 (persistence; DB access behind `@spec`'d contexts), §3 (typed standard),
  §9 (LiveView dashboard) — authoritative constraints the fix must honor.
- `AGENTS.md` — Phoenix v1.8 + LiveView + Ecto conventions for the test and changes.
- `.claude/commands/conditional_docs.md` routing — matched rows for this task:
  - *Ecto schemas, migrations, contexts, JSONB…* → `BUILD_PROMPT.md` §8;
    `ai_docs/typed-elixir-standard.md` (rule 10).
  - *The LiveView dashboard, streams…* → `BUILD_PROMPT.md` §9; `AGENTS.md`.
  - *(always)* → `ai_docs/typed-elixir-standard.md` (typed coding standard).

### New Files
- `test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs` — a
  `Phoenix.LiveViewTest` integration test that seeds an orchestrator whose `agent_models`
  metadata holds all four tiers at concrete Anthropic ids, mounts `ConsoleLive`, and asserts
  the modal renders `4/4 configured` and the assigned model option `selected` for each tier
  (fails before Fix #2, passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative context
- Read `BUILD_PROMPT.md` §3 (typed standard), §8 (persistence / context rules), §9 (LiveView).
- Read `ai_docs/typed-elixir-standard.md` (rules 1, 5, 10).
- Re-read `lib/repo_builder/orchestrator.ex` (`set_agent_model/3`, `fetch/1`, `update_fields/2`,
  `update_record/2`) and `lib/repo_builder_web/live/console_live.ex`
  (`agent_model_rows/1`, `configured_tier_count/1`, `model_options_for/2`).

### 2. Fix #1 — make `set_agent_model/3` atomic (eliminate the lost-update race)
- In `lib/repo_builder/orchestrator.ex`, rewrite the body of
  `set_agent_model(id, category, attrs) when category in @agent_categories` to perform the
  read-merge-write inside a single `Repo.transaction/1` that **locks the orchestrator row**
  before reading its `metadata`:
  - Acquire the row with a `FOR UPDATE` lock, e.g.
    `Repo.one(from o in Orchestrator, where: o.id == ^id, lock: "FOR UPDATE")`.
    (Widen the `import Ecto.Query` to include `where`/`lock` as needed, or keep using `from/2`
    with the `lock:` keyword — `from/2` is already imported.)
  - On `nil`, `Repo.rollback(:not_found)`.
  - Otherwise build `entry` (unchanged: `harness`/`provider`/`model` via `attr/2` +
    `_updated_at` ISO8601), compute
    `roster = Map.put(Map.get(orch.metadata, "agent_models", %{}), category, entry)`, and write
    via the existing `update_record(orch, %{metadata: Map.put(orch.metadata, "agent_models", roster)})`.
    On `{:error, _}` from the write, `Repo.rollback(:not_found)` (preserve the current
    `:not_found` error contract).
  - Unwrap the transaction result so the function STILL returns
    `{:ok, Orchestrator.t()} | {:error, :not_found | :invalid_category}` exactly as its `@spec`
    declares (do not leak the `{:ok, term}`/`{:error, term}` transaction tuple shape).
  - Broadcast `RepoBuilder.Dashboard.broadcast_orchestrator_updated(updated)` on the `{:ok, _}`
    path, as today. Keep the broadcast **outside** the transaction (or at its tail) so a PubSub
    call never holds the row lock longer than necessary.
- Keep the second clause `set_agent_model(_id, _category, _attrs), do: {:error, :invalid_category}`
  unchanged.
- Preserve the `@spec` and `@doc`. Do not change the public signature.
- Rationale: a row-level `FOR UPDATE` lock serializes concurrent writers on the same
  orchestrator, so each tier write observes the prior writers' committed `agent_models` and
  the four entries accumulate. Minimal and idiomatic per `BUILD_PROMPT.md` §8.

### 3. Fix #2 — always surface the assigned model in the modal row options
- In `lib/repo_builder_web/live/console_live.ex`, update `agent_model_rows/1` so each row's
  `model_options` is guaranteed to include the stored model id:
  - Compute `base = if(harness, do: model_options_for(harness, provider), else: [])`.
  - Compute `model = entry["model"]` and prepend it when present and absent:
    `options = if model in [nil, "" | base], do: base, else: [model | base]`
    (or an equivalent `Enum.uniq([model | base])` that drops `nil`/`""`). Keep the assigned
    id first so it reads as the current selection.
  - Use that `options` for the row's `:model_options`.
- Leave `configured_tier_count/1` unchanged — it already counts the raw stored `row.model`, so
  once Fix #1 persists all four it correctly reports `4/4`.
- Keep `@spec`s precise; the row map shape is unchanged.

### 4. Add the LiveView integration test (reproduces Defect B, guards the display fix)
- Create `test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs`.
- In `setup`, build/seed the singleton default orchestrator with `harness: "claude"` and
  `metadata["agent_models"]` set to all four tiers at concrete ids, e.g. via the context
  (preferred — exercises Fix #1 too) by calling
  `Orchestrators.set_agent_model(id, cat, %{"harness" => "claude", "provider" => "anthropic", "model" => id_for_cat})`
  for each of `fast`/`main`/`heavy`/`leader`, OR by inserting the orchestrator with the
  metadata directly. Use `get_or_create_default("claude")` to obtain the id.
- Mount `ConsoleLive` at `/` with `Phoenix.LiveViewTest.live/2`.
- Assertions (use `element/2`/`has_element?/2` and selectors keyed on the DOM ids the modal
  already provides — `#agent-models-modal`, `#agent-model-fast`, … per
  `agent_models_modal/1`):
  - The configured counter shows `4/4` — assert on the counter element's text, e.g.
    `assert render(view) =~ "4/4 configured"` scoped via a `LazyHTML` filter on the modal
    panel, or assert the element exists.
  - For each tier, the assigned model option is rendered **selected**. Prefer a structural
    assertion: `has_element?(view, "#agent-model-fast select[name=model] option[selected]", "claude-haiku-4-5")`
    (the assigned id, not the blank `no model` fallback). Add the analogous assertion for
    `main` (`claude-sonnet-4-5`), `heavy` and `leader` (`claude-opus-4-5`).
  - Negative guard: assert the blank fallback option is **not** the selected one for a
    configured tier (e.g. the `no model (won't spawn)` option is not `selected` in
    `#agent-model-fast`).
- This test FAILS before Fix #2 (the assigned option is absent, so the blank option is
  selected) and PASSES after. If the metadata is seeded via the context, it also exercises
  Fix #1's accumulation (all four present).

### 5. Add a context regression test for the atomic write (Fix #1)
- In an existing or new context test (e.g. extend `test/repo_builder/orchestrators_provider_test.exs`
  or add `test/repo_builder/orchestrators_agent_models_test.exs` if not already covering this),
  add:
  - A **sequential** test asserting that four successive `set_agent_model/3` calls (one per
    category) leave all four entries present in `agent_models/1` with their models — a plain
    accumulation guard that must hold.
  - A **concurrent** test asserting no lost updates: spawn the four category writes with
    `Task.async_stream/3` (`max_concurrency: 4`) against the same orchestrator id, await all,
    then assert `map_size(Orchestrators.agent_models(reloaded)) == 4` and each model matches.
    Because this crosses process boundaries, set the Ecto sandbox to shared mode for this test
    (`Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`) so the spawned tasks see the
    same connection/transaction visibility; document why in a comment. This test is the direct
    regression guard for the race and should be reliable (not flaky) with the `FOR UPDATE` lock
    in place.
- Keep every new public/test helper `@spec`-free only where ExUnit idioms apply; production
  code keeps `@spec`s.

### 6. Run the full validation suite
- Run every command in **Validation Commands** and fix any failure until all are green.
- Confirm the new LiveView test and the concurrency regression test pass, and that the existing
  `test/repo_builder_web/live/test_agent_models_modal_test.exs` (if present) still passes.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs` — the
  new LiveView integration test: fails before Fix #2, passes after.
- `mix test test/repo_builder/orchestrators_agent_models_test.exs test/repo_builder/orchestrators_provider_test.exs` —
  context tests including the sequential + concurrent no-lost-update guards for Fix #1.
- `mix test test/repo_builder_web/live/test_agent_models_modal_test.exs` — existing modal test,
  zero regressions.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker +
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" rule.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters (the
  `set_agent_model/3` return contract must remain `{:ok, Orchestrator.t()} | {:error, :not_found | :invalid_category}`).

## Notes
- **No new dependency** is required; `Repo.transaction/1`, `Ecto.Query` `lock:`, and
  `Task.async_stream/3` are all already available.
- **Why fix the display, not the config:** the registry's `claude/anthropic` list is
  deliberately the abstract tier aliases (`opus`/`sonnet`/`haiku`) that drive the *header*
  model dropdown; the orchestrator legitimately assigns concrete ids from pi's much larger live
  catalog. The modal must therefore render any stored id, which is exactly what the existing
  `model_extra` "Current" pattern does for the header — Fix #2 brings the per-tier rows to
  parity rather than hard-coding ids into config.
- **Scope discipline:** other `metadata` read-modify-writes in the context (e.g.
  `set_model/2`'s `recent_models`) share the same race shape but are out of scope for this
  surgical bug fix and are far less likely to be driven by burst-concurrent tool calls. If a
  future issue surfaces them, the same `FOR UPDATE` transaction pattern applies; mention but do
  not change them here.
- **Tidewave during root-cause:** prefer `project_eval` to run the concurrent-writer snippet in
  *Steps to Reproduce* against the live app to observe `map_size < 4` before the fix and `== 4`
  after, and `execute_sql_query` (`select metadata->'agent_models' from orchestrators`) to
  inspect the persisted roster directly. Optionally capture a screenshot of
  `http://localhost:4000` with the modal open as visual proof the four tiers render with their
  models selected after the fix.
```

specs/issue-request-adw-the-sdlc_planner-fix-agent-models-modal-not-reflecting-orchestrator-config.md
