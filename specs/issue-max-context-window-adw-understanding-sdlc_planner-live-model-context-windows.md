# Feature: Live, model-accurate context-window sizing for the orchestrator and spawned agents

## Metadata
issue_number: `max-context-window`
adw_id: `understanding`
issue_json: `per`

## Feature Description
Today every context-window bar in the console — both the right-rail **ORCHESTRATOR**
panel (`command_panel/1`) and each left-rail **agent card** (`agent_card/1`) — renders a
hardcoded denominator of `200k` and computes its fill percentage against a hardcoded
`200_000` (`console_components.ex:295`, `:931`, and `context_pct/1` at
`console_components.ex:3233`). This is wrong the moment an agent or the orchestrator runs
on any model whose real context window is **not** 200k: a `claude-sonnet-4-6` worker
(1,000,000-token window) shows a bar that pins to ~near-full at 200k of usage and reads
"`/200k`", while a 1M-window model is really only ~20% full; conversely a model with a
smaller window would under-report pressure.

There is already a harness-blind resolver — `RepoBuilder.Orchestrator.ContextWindow`
(`size/2`, `usage_fraction/3`) — that reads the operator-tunable
`config :repo_builder, :context_windows` map and returns the correct per-`{harness, model}`
window. But it is consumed by **only one place**: the `report_cost` orchestrator tool
(`lib/repo_builder/orchestrator/tools.ex:975,985`). The UI never calls it. And the config
map itself is sparse and static — it only declares two Claude models and a 200k default,
so even the resolver under-serves the many models the platform can drive (pi providers,
ADW, etc.).

This feature makes the context-window size **model-accurate and live** end-to-end:

1. **Get the real window per assigned model.** Layer the `ContextWindow` resolver so it
   draws on (a) the operator config override, then (b) a **live/derived source** — pi's
   own `pi --list-models` output (already shelled by `RepoBuilder.Harness.Pi.Models`) plus
   a built-in catalog of known Claude/common model windows — then (c) the configured
   default. "Live understanding" = pi's actual advertised windows for the providers the
   operator is authed for, refreshed on the existing TTL cache, with a sane built-in
   fallback for harnesses that don't advertise a window in their stream/CLI (Claude).
2. **Reflect it to the orchestrator and to every spawned agent.** Thread the assigned
   `harness`+`model` into both cards and compute `{used}k / {window}k` and the fill
   percentage against the **resolved** window — so each card tells the truth for the model
   that card's agent (or the orchestrator) is actually running.

## User Story
As an operator driving multiple agents and an orchestrator across different harnesses and
models
I want each context-window bar to reflect the **real maximum context window of the model
that agent/orchestrator is assigned**, sourced live where the harness advertises it
So that I can trust the "how full is the context" signal to decide when to compact, clear,
or hand off — instead of reading a fiction pinned to a hardcoded 200k.

## Problem Statement
The console reports context-window occupancy against a hardcoded 200,000-token denominator
in every card, regardless of the model assigned to that agent or the orchestrator. The one
resolver that knows model-specific windows (`ContextWindow.size/2`) is bypassed by the UI,
and its backing config is a sparse, fully static, operator-maintained map with no live
source — so the platform has no live understanding of the true maximum context window per
model, and surfaces a misleading occupancy bar for any non-200k model.

## Solution Statement
Make `RepoBuilder.Orchestrator.ContextWindow` the single, model-aware, layered resolver and
wire it into the UI for both the orchestrator and spawned agents:

1. **Layered resolution (foundation).** `ContextWindow.size/2` resolves in strict
   precedence: **(1)** operator `{harness, model}` config override (unchanged, still wins);
   **(2)** a **derived/live** lookup — for `"pi"`, the window advertised by
   `pi --list-models` (via an extended `Pi.Models`); for `"claude"` (and other known ids),
   a built-in `@known_windows` catalog of published model windows; **(3)** the configured
   `:default` (200k). Still returns `pos_integer()`, still harness-blind at the call site,
   still never raises.
2. **Live pi source.** Extend `RepoBuilder.Harness.Pi.Models` to capture a context-window
   column from `pi --list-models` when present (it currently parses `provider model` and
   discards the rest), exposing `context_window/1 :: String.t() -> pos_integer() | nil`,
   backed by the existing `:persistent_term` TTL cache and test kill-switch. Fail-soft:
   absent column / pi absent / disabled ⇒ `nil` ⇒ resolver falls through to the catalog or
   default.
3. **Built-in known-model catalog.** A small, documented `@known_windows` map in
   `ContextWindow` for the models the platform ships defaults for (Claude Sonnet/Opus/Haiku,
   common pi/zai/openai ids) so Claude — which does not advertise its window in the stream —
   resolves correctly without operator config. Operator config still overrides it.
4. **Reflect to the UI.** `agent_card/1` already receives `harness`/`model`; compute the
   resolved window there and render `{ktok(used)} / {ktok(window)}` with a fill computed by a
   new `context_pct/2` taking `(tokens, window)`. Add `harness`/`model` attrs to
   `command_panel/1` and thread the orchestrator's `harness`/`model` from `ConsoleLive`, so
   the orchestrator bar uses its own model's window too.

No schema, migration, or DB-write change — this is a read/derive + render-path feature. The
`report_cost` tool already calls `ContextWindow.size/2`, so it inherits the improved
resolution for free (verify, don't re-wire).

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/context_window.ex` — **Primary.** The harness-blind
  resolver. Extend `size/2` to the layered precedence (config → derived/live → default),
  add the `@known_windows` built-in catalog and a private derive step that consults
  `Pi.Models.context_window/1` for the `"pi"` harness. Keep `usage_fraction/3` semantics
  (unclamped) intact.
- `lib/repo_builder/harness/pi/models.ex` — **Live source.** Extend `parse/1` to also
  capture a context-window column when `pi --list-models` emits one, and add
  `@spec context_window(String.t() | nil) :: pos_integer() | nil` reading the cached map.
  Keep it fail-soft, non-blocking, and disabled under `:pi_models_discovery` in test.
- `lib/repo_builder_web/components/console_components.ex` — **UI (both cards).**
  - `agent_card/1` (`~238`–`~308`): already has `:harness`/`:model` attrs (`241`–`242`);
    resolve the window and replace the hardcoded `/ 200k` (`295`) and the
    `context_pct(@context_tokens)` call (`262`) with window-aware rendering.
  - `command_panel/1` (`~881`–`~936`): add `attr :harness`/`attr :model`; replace the
    hardcoded `/ 200k` (`931`) and `context_pct(@context_tokens)` (`896`).
  - `context_pct/1` (`3233`): change to `context_pct/2` (`tokens, window`) computing
    `min(100, div(tokens * 100, max(window, 1)))`; keep `ktok/1` (`3236`) for the number.
- `lib/repo_builder_web/live/console_live.ex` — **Threading.**
  - Agent card render site (`~2881`–`2898`): `harness`/`model` are already passed; no change
    needed beyond confirming they flow.
  - Orchestrator `command_panel` render site (`~3081`–`3091`): pass `harness={...}` and
    `model={...}` from the loaded orchestrator struct (the assign already drives
    `@orchestrator_context`; reuse the same orchestrator source).
- `lib/repo_builder/orchestrator/tools.ex` (`~963`–`1000`) — `report_cost/1` already uses
  `ContextWindow.size/2` + `usage_fraction/3`; **verify only** it now reports model-accurate
  windows; no rewire expected.
- `config/config.exs` (`~261`–`269`) — the `:context_windows` map. Keep the operator-override
  contract; the built-in catalog + pi-live source now mean this map is for **overrides only**,
  not the sole source. Update the surrounding comment to reflect the new layering.
- `lib/repo_builder/orchestrator/orchestrator.ex` — confirm the orchestrator schema carries
  `harness` + `model` (it does: `tools.ex` reads `orch.harness`/`orch.model`); read-only.
- `lib/repo_builder/agents/agent.ex` — confirm the agent schema carries `harness` + `model`
  (the card render passes `agent.harness`/`agent.model`); read-only.
- `BUILD_PROMPT.md` — §3 typed style, §8 DB-behind-context, §9 LiveView, §10 extensibility
  (open `harness :: atom()` — the resolver must stay harness-blind and not hardcode a closed
  set of harnesses).
- `.claude/commands/conditional_docs.md` — routes harness/event tasks to `BUILD_PROMPT.md`
  §4/§10 and the typed standard; LiveView tasks to §9 + `AGENTS.md`.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (every public fn `@spec`,
  precise types, tagged tuples).

### New Files
- `test/repo_builder/orchestrator/context_window_resolution_test.exs` — unit tests for the
  layered precedence: config override wins; pi-live source used for `"pi"`; built-in catalog
  used for known Claude models with no override; `:default` fallback for unknown; nil-model
  handled; `usage_fraction/3` unchanged (incl. >1.0 over-occupancy).
- `test/repo_builder_web/live/test_model_context_windows_test.exs` —
  `Phoenix.LiveViewTest` integration: seed agents on different models (e.g. a
  `claude-sonnet-4-6` agent and a `claude-opus-4-8` agent) with persisted usage, mount `/`,
  and assert each agent card renders its model's real window (`/1000k` vs `/200k`) and a
  fill percentage computed against that window; assert the orchestrator panel renders its own
  model's window.
- (Pi.Models parse-with-context tests may extend `test/repo_builder/harness/pi_models_test.exs`.)

## Implementation Plan
### Phase 1: Foundation — make the resolver model-accurate and live
Turn `ContextWindow` from a config-only lookup into a layered resolver, and give pi a live
window source. This is purely additive at the resolver boundary: the public signatures
(`size/2`, `usage_fraction/3`) and their return types are unchanged, so every existing caller
(today only `report_cost/1`) keeps working and immediately benefits.

### Phase 2: Core Implementation — reflect the resolved window in the UI
Replace the two hardcoded `/ 200k` renders and the hardcoded `context_pct/1` denominator with
window-aware rendering driven by the resolved window for the card's assigned `harness`+`model`.
Thread `harness`/`model` into `command_panel/1` for the orchestrator.

### Phase 3: Integration — prove parity across orchestrator, agents, and the cost tool
Verify the `report_cost` tool, the orchestrator panel, and every agent card all agree on the
same resolved window for a given `{harness, model}`, with the live pi source and built-in
catalog feeding all three through the one resolver. Add tests + run the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Research + confirm the contract
- Read `BUILD_PROMPT.md` §3 (typed), §9 (LiveView), §10 (open harness identity), and
  `.claude/commands/conditional_docs.md`.
- Confirm the orchestrator schema (`orchestrator.ex`) and agent schema (`agent.ex`) both
  carry `harness` and `model` fields (Tidewave `get_ecto_schemas` or `get_source_location`).
- With the app running, capture the **actual** `pi --list-models` output to confirm whether a
  context-window column exists and its position/header
  (Tidewave `project_eval`: `System.cmd(System.find_executable("pi"), ["--list-models"])` or a
  shell run). The parse in Step 3 must match the real column layout; if pi does **not** emit a
  window column, the pi-live layer degrades to `nil` and the built-in catalog/default covers
  it — document the observed format in the `Pi.Models` moduledoc.

### 2. Add the built-in known-model catalog + layered resolution (ContextWindow)
- In `lib/repo_builder/orchestrator/context_window.ex`:
  - Add `@known_windows %{{harness, model} => pos_integer()}` documenting published windows
    for the models the platform ships (at minimum: `{"claude","claude-sonnet-4-6"} =>
    1_000_000`, `{"claude","claude-opus-4-8"} => 200_000`, plus any Haiku/known pi/zai ids you
    can cite). Add a moduledoc note that these are built-in defaults, **overridable** by
    `config :repo_builder, :context_windows`.
  - Refactor `size/2` to resolve in precedence: **(1)** config `{harness, model}` override →
    **(2)** `derive/2` (pi-live then `@known_windows`) → **(3)** configured `:default`
    (200k). Each layer guards `is_integer and > 0`. Keep `size/2`'s `@spec ... ::
    pos_integer()` and `when is_binary(harness)`.
  - Add `@spec derive(String.t(), String.t() | nil) :: pos_integer() | nil` (private) that
    returns `Pi.Models.context_window(model)` when `harness == "pi"`, else
    `Map.get(@known_windows, {harness, model})`. Must never raise.
  - Leave `usage_fraction/3` and the `:default` fallback semantics exactly as-is.

### 3. Add the live pi context-window source (Pi.Models)
- In `lib/repo_builder/harness/pi/models.ex`:
  - Decide the cached shape. Prefer keeping `all/0` returning `%{provider => [model]}` for the
    existing dropdown callers and store windows in a **separate** persistent-term entry (e.g.
    `{__MODULE__, :windows} => %{model => pos_integer()}`) populated in the same `refresh/0`
    pass, so the dropdown contract is untouched. (Alternative: a parallel `windows/0` derived
    from a richer parse — choose whichever keeps existing `parse/1` tests green; document the
    choice.)
  - Extend the parse to capture a context-window integer per model **when the column is
    present** (defensive: tolerate rows with no window column → omit that model from the
    windows map). Strip thousands separators / `k`/`m` suffixes if pi formats them; otherwise
    parse a bare integer.
  - Add `@spec context_window(String.t() | nil) :: pos_integer() | nil` returning the cached
    window for a model (triggers the same background refresh path as `all/0`; returns `nil`
    when unknown, disabled, or pi absent).
  - Keep `enabled?/0` (test kill-switch `:pi_models_discovery`) gating all shell-outs.

### 4. Window-aware rendering helper (console_components)
- Change `context_pct/1` → `@spec context_pct(non_neg_integer(), pos_integer()) ::
  non_neg_integer()` computing `min(100, div(tokens * 100, max(window, 1)))`. Update both
  callers.
- Keep `ktok/1` for the displayed numbers; render the denominator as `ktok(window)` so it
  reads e.g. `/1000k` for a 1M model.

### 5. agent_card/1 — reflect the agent's model window
- In `agent_card/1`, resolve the window from the already-present `@harness`/`@model`:
  `window = ContextWindow.size(@harness || "", @model)` (assign it alongside `:ctx_pct`).
  Guard the `nil` harness (the attr defaults to `nil`) — `size/2` requires a binary harness,
  so coerce `@harness || ""` which falls through to `:default`.
- Replace `context_pct(assigns.context_tokens)` with `context_pct(context_tokens, window)`
  and replace the literal `/ 200k` (`~295`) with `{ktok(@window)}`.
- Alias `RepoBuilder.Orchestrator.ContextWindow` in `console_components.ex` (add to the
  module's `alias`es).

### 6. command_panel/1 — reflect the orchestrator's model window
- Add `attr :harness, :string, default: nil` and `attr :model, :string, default: nil` to
  `command_panel/1`. Resolve `window` the same way and replace the literal `/ 200k` (`~931`)
  and `context_pct(@context_tokens)` (`~896`).
- In `console_live.ex` at the `command_panel` render site (`~3081`), pass `harness={...}` and
  `model={...}` from the orchestrator struct that already feeds `@orchestrator_context`
  (resolve the orchestrator the same way `orchestrator_context_for/1` does; if the struct is
  not already an assign, add a small `@orchestrator_harness`/`@orchestrator_model` assign
  seeded in `mount`/on-switch next to where `@orchestrator_context` is set — keep DB access
  behind contexts).

### 7. Update config comment + verify report_cost
- In `config/config.exs` (`~261`), update the `:context_windows` comment to state it is now an
  **override** layer over the built-in catalog and pi-live source (not the sole source). Leave
  the existing entries (harmless overrides).
- Verify `report_cost/1` (`tools.ex:975,985`) now returns the model-accurate `context_window`
  with no code change (it already calls `ContextWindow.size/2`).

### 8. Unit tests — resolver + pi parse
- Create `test/repo_builder/orchestrator/context_window_resolution_test.exs`:
  - config override wins over catalog/default;
  - `"claude"`/`"claude-sonnet-4-6"` resolves to 1M via the catalog with **no** config entry
    (use `Application.put_env`/restore or test the catalog directly);
  - unknown `{harness, model}` falls back to `:default`;
  - nil model handled;
  - `usage_fraction/3` still unclamped (>1.0 when context exceeds window).
- Extend `test/repo_builder/harness/pi_models_test.exs`: parsing output **with** a context
  column populates `context_window/1`; parsing the legacy `provider model` output leaves
  `context_window/1 => nil` and `all/0` unchanged; `:pi_models_discovery` disabled ⇒ `nil`.

### 9. LiveView integration test — both cards reflect the model window
- Create `test/repo_builder_web/live/test_model_context_windows_test.exs`:
  - Seed two agents on different models (`claude-sonnet-4-6` → 1M, `claude-opus-4-8` → 200k)
    with persisted `usage` rows (reuse the `Logs`/Repo seed pattern from
    `test_agent_card_context_tokens_test.exs`); `live/2` the console.
  - Assert each agent card renders its model's denominator (`/1000k` vs `/200k`) via
    `element/2`/`render/1`, and that the fill width differs for the same token count against
    the two windows.
  - Assert the orchestrator `command_panel` renders the orchestrator model's window.
  - Confirm the test **fails** before Steps 4–6 (hardcoded 200k) and **passes** after.

### 10. Validate
- Run every command in **Validation Commands**; fix until green.
- Live check (Tidewave `project_eval`):
  `RepoBuilder.Orchestrator.ContextWindow.size("claude", "claude-sonnet-4-6")` → `1_000_000`;
  if pi is installed, `RepoBuilder.Harness.Pi.Models.context_window(<a-real-pi-model>)` returns
  a positive integer (or `nil` with documented reason).
- Optional visual proof: reload `/` and confirm an agent on a 1M model shows `/1000k` with a
  proportionally smaller fill (Tidewave Web vision mode or Playwright screenshot of
  `http://localhost:4000`).

## Testing Strategy
### Unit Tests
- `ContextWindow` layered precedence (config > catalog/pi-live > default), nil-model,
  harness-blind behavior for an unknown harness, and unchanged `usage_fraction/3` semantics
  (including over-occupancy > 1.0).
- `Pi.Models`: defensive parse that captures a context column when present and degrades to
  `nil` when absent; existing `parse/1`/`all/0` provider→models contract preserved; test
  kill-switch respected.

### Edge Cases
- **nil model / nil harness** on an agent or orchestrator → resolver coerces to default
  (200k); card still renders a valid bar.
- **pi unavailable / disabled in test** → `context_window/1` returns `nil`; resolver falls to
  catalog/default; no shell-out in the suite.
- **pi emits no window column** (older pi) → windows map empty; pi models still resolve via
  catalog/default.
- **Over-occupancy** (context_tokens > window, e.g. a resumed Claude session at 1M) →
  `context_pct/2` clamps the **bar** to 100% but `usage_fraction/3`/`report_cost` still report
  the true >100% (unchanged contract).
- **Operator override present** for a model the catalog also knows → override wins (no
  regression for the two existing config entries).
- **Sonnet vs Opus on the same token count** → visibly different denominators and fills,
  proving per-model accuracy.

## Acceptance Criteria
- Each agent card renders `{used}k / {window}k` where `{window}` is the resolved window for
  that agent's assigned `{harness, model}` (e.g. `/1000k` for `claude-sonnet-4-6`, `/200k`
  for `claude-opus-4-8`), and the fill % is computed against that window.
- The orchestrator panel renders its own assigned model's window the same way.
- `ContextWindow.size/2` resolves with precedence config-override → pi-live/built-in-catalog →
  `:default`, returns `pos_integer()`, and never raises (incl. nil model).
- `RepoBuilder.Harness.Pi.Models.context_window/1` returns a `pos_integer()` for a model whose
  `pi --list-models` row carries a window, and `nil` otherwise (or when disabled/absent), with
  the existing `all/0` provider→models contract unchanged.
- `report_cost/1` reports the model-accurate `context_window` with no code change.
- No schema, migration, or DB-write change; all DB access stays behind contexts.
- The full green gate passes with zero regressions; the new LiveView test fails pre-change and
  passes post-change.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/orchestrator/context_window_resolution_test.exs` — resolver
  precedence + fallback + nil handling.
- `mix test test/repo_builder/harness/pi_models_test.exs` — pi window parse + fail-soft +
  unchanged dropdown contract.
- `mix test test/repo_builder_web/live/test_model_context_windows_test.exs` — both cards
  render the assigned model's real window and a window-relative fill.
- `mix test test/repo_builder_web/live/` — no LiveView regressions (existing console/agent-card
  context tests still green).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker + warnings
  pass.
- `mix test --warnings-as-errors` — full ExUnit suite green, zero regressions.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint incl. every-public-fn-`@spec`.
- `mix dialyzer` — `@spec`/contract checking with no new warnings, no stale ignore filters.
- Tidewave (live app): `project_eval`
  `RepoBuilder.Orchestrator.ContextWindow.size("claude", "claude-sonnet-4-6")` returns
  `1_000_000`; reload `/` and confirm a 1M-model agent card reads `/1000k`.

## Notes
- **Why a built-in catalog for Claude rather than "live".** Claude's `stream-json` does not
  advertise its context window, and querying the model's window cheaply at runtime is not
  available through the CLI; the published windows are stable constants, so a small built-in
  catalog (overridable by operator config) is the correct "source of truth" for Claude. pi is
  the harness that genuinely advertises windows (`pi --list-models`), so that path is the
  "live understanding" the request asks for. The layering means each harness uses the best
  source available to it, all behind one resolver.
- **Harness-blindness (BUILD_PROMPT.md §10).** The resolver must not hardcode a closed set of
  harnesses in its public contract. The only place a harness string is matched is the private
  `derive/2` (a `"pi"` special-case for the live source) — adding a future live source for a
  new harness is one extra clause there, with config-override and the catalog working for any
  harness with zero code change.
- **`report_cost` parity is free.** Because the tool already routes through
  `ContextWindow.size/2`/`usage_fraction/3`, improving the resolver fixes the orchestrator's
  self-reported `context_window`/`context_usage_pct` and the high-usage warning threshold
  (`@high_usage_threshold 0.8`) at the same time — verify, don't duplicate.
- **No double-counting of occupancy.** This feature only changes the **denominator** (window)
  and its display; the **numerator** (`context_size/1` = input + cache_read + cache_creation)
  is the already-correct value from the prior agent-card-context fix
  (`issue-per-agent-token_context`). Do not alter the numerator.
- **Future consideration.** The DB-backed `cost_center/model_price.ex` could grow a
  `context_window` column to make windows operator-editable in the UI rather than config-only;
  out of scope here, but the layered resolver leaves room to add a DB layer between config and
  catalog later.
