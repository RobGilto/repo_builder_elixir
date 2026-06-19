# Bug: Agent rail cards display the harness instead of the model

## Metadata
issue_number: `show`
adw_id: `the`
issue_json: `harness,`

## Bug Description
On the orchestration console at `http://localhost:4000/`, each worker agent is rendered
as a rich "agent card" in the left rail (`RepoBuilderWeb.ConsoleComponents.agent_card/1`).
The footer line of that card is meant to display the agent's **model** (e.g.
`claude-opus-4-8`, `gpt-5`, …) next to its running cost.

Instead, the card displays the agent's **harness** (e.g. `claude`, `pi`, `fake`).

- **Expected:** the footer shows the agent's model identifier (`agent.model`), falling
  back to the harness only when no model is set.
- **Actual:** the footer always shows the harness, because the model value is never
  passed into the component, so the component's `@model || @harness` fallback always
  resolves to the harness.

## Problem Statement
The `agent_card` function component supports a `model` attribute and renders
`{@model || @harness || "—"}` (`lib/repo_builder_web/components/console_components.ex:298`),
but the call site in `ConsoleLive` (`lib/repo_builder_web/live/console_live.ex:2231`)
only passes `harness={agent.harness}` and never passes `model={agent.model}`. With
`@model` defaulting to `nil`, the component's fallback always renders the harness.

## Solution Statement
Pass the agent's model through to the component at the call site:
add `model={agent.model}` to the `<.agent_card .../>` invocation in `ConsoleLive`.
The component, attribute declaration (`attr :model, :string, default: nil`), and the
`RepoBuilder.Agents.Agent` schema (`field :model, :string`) already support this — the
only missing wiring is the single assign at the call site. The existing
`{@model || @harness || "—"}` fallback is preserved so agents with no model still show
the harness (and `"—"` when neither is set).

## Steps to Reproduce
1. Start Postgres (`scripts/pg.sh start`) and the app (`mix phx.server`).
2. Open `http://localhost:4000/`.
3. Have the orchestrator spawn a worker agent that has a model set (e.g. an
   orchestrator-created worker whose `worker_changeset` cast a `model` value), or seed an
   agent with a non-nil `model`.
4. Observe the worker's card in the left "Agents" rail.
5. **Bug:** the footer line (above the cost badge) shows the harness string (e.g. `claude`)
   rather than the model (e.g. `claude-opus-4-8`).

## Root Cause Analysis
The rich agent card renders its footer as:

```elixir
# lib/repo_builder_web/components/console_components.ex:298
<span class="truncate">{@model || @harness || "—"}</span>
```

The component declares both attributes with `nil` defaults:

```elixir
# lib/repo_builder_web/components/console_components.ex:230-231
attr :harness, :string, default: nil
attr :model, :string, default: nil
```

But the only call site passes the harness and omits the model:

```elixir
# lib/repo_builder_web/live/console_live.ex:2231
<.agent_card
  id={agent.id}
  name={agent.name}
  status={Map.get(@statuses, agent.id, agent.status)}
  harness={agent.harness}        # model={agent.model} is missing
  ...
/>
```

`@agents` is a list of `RepoBuilder.Agents.Agent` structs (loaded via
`Agents.list_agents/0` in `load_agents/1`), and that schema **does** carry a `model`
field (`lib/repo_builder/agents/agent.ex:43`, cast in `worker_changeset/2`). Because the
call site never forwards `agent.model`, `@model` stays `nil` and the `@model || @harness`
fallback always yields the harness. The fix is to forward the already-available value.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — Contains the `<.agent_card .../>` call
  site (~line 2231) that is missing the `model={agent.model}` assign. This is the single
  line that needs to change.
- `lib/repo_builder_web/components/console_components.ex` — Defines `agent_card/1`
  (attrs at lines 227-246, render at 253-303). Already correct: declares `attr :model`
  and renders `{@model || @harness || "—"}`. Read-only reference to confirm the contract.
- `lib/repo_builder/agents/agent.ex` — `Agent` schema/struct; confirms `model` is a real
  `:string` field carried on every agent (so `agent.model` is safe to reference).
- `BUILD_PROMPT.md` — §9 (LiveView dashboard) and §3 (typed style) authority for the fix.

### New Files
- `test/repo_builder_web/live/test_agent_card_model_display_test.exs` — A
  `Phoenix.LiveViewTest` integration test that mounts `ConsoleLive` with a worker agent
  that has a `model` set and asserts the rendered agent card shows the model, not the
  harness. Fails before the fix, passes after.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and confirm the root cause
- Read `lib/repo_builder_web/components/console_components.ex` lines 227-303 to confirm the
  component already accepts `model` and renders `{@model || @harness || "—"}`.
- Read `lib/repo_builder_web/live/console_live.ex` around line 2231 to confirm the
  `<.agent_card .../>` call passes `harness={agent.harness}` but not `model`.
- Optionally use Tidewave `project_eval` to inspect a live agent
  (`RepoBuilder.Agents.list_agents/0 |> Enum.map(&{&1.name, &1.harness, &1.model})`) to
  confirm agents carry a non-nil `model` while the rail shows the harness.

### 2. Write a failing LiveView integration test
- Create `test/repo_builder_web/live/test_agent_card_model_display_test.exs`.
- Use the existing test support (`RepoBuilder.SessionCase` / `RepoBuilderWeb.ConnCase`,
  matching the pattern in the existing `test/repo_builder_web/live/test_agent_card_*`
  tests) to seed an agent with a distinct `harness` (e.g. `"claude"`) and a distinct
  `model` (e.g. `"claude-opus-4-8"`).
- Mount `ConsoleLive` at `/`, render the agent rail (non-collapsed), and assert the agent
  card HTML contains the model string and does NOT show the bare harness in the model
  footer slot. Run it and confirm it FAILS against the current code.

### 3. Apply the surgical fix
- In `lib/repo_builder_web/live/console_live.ex`, add `model={agent.model}` to the
  `<.agent_card .../>` invocation (immediately alongside `harness={agent.harness}` at
  ~line 2235). Change nothing else.

### 4. Confirm the test now passes
- Re-run the new test; it must PASS.

### 5. Run full validation
- Run every command in `Validation Commands` and ensure zero errors and zero regressions.
- Optionally capture a screenshot of `http://localhost:4000` via Tidewave Web vision mode
  (or Playwright MCP) showing a worker card displaying the model as visual proof.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_agent_card_model_display_test.exs` — The new
  integration test passes (and demonstrably failed before the one-line fix).
- `mix compile --warnings-as-errors` — Compile clean; gradual set-theoretic type checker
  and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — Full ExUnit suite passes with zero failures.
- `mix format --check-formatted` — Code is formatted.
- `mix credo --strict` — Lint passes, including the `@spec`-on-public-functions rule.
- `mix dialyzer` — No new contract warnings; no stale ignore filters.

## Notes
- This is a single-line wiring fix at the call site; the component, its attribute
  contract, and the `Agent` schema field all already exist — nothing about types,
  structs, or specs changes, so the typed-Elixir gates (§3) are unaffected.
- The `{@model || @harness || "—"}` fallback is intentionally preserved: agents with no
  model (e.g. some manually-created agents) still show the harness, and agents with
  neither show `"—"`. The bug was only that `@model` was never supplied.
- The compact rail variant (`agent_rail_compact/1`) intentionally shows only an initial +
  status dot and no model/harness text, so it needs no change.
- No new dependencies are required.
