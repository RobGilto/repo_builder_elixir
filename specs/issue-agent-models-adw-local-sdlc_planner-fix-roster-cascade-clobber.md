# Bug: Agent-models roster choices wiped by spurious harness cascade (don't persist across restarts)

## Metadata
issue_number: `N/A (operator-reported in console UI)`
adw_id: `local`
issue_json: `{"title":"Agent-models modal: set choices do not persist between restarts","body":"In the AGENT MODELS modal (#agent-models-modal), the per-tier harness/provider/model selections I make appear to save (Saved ✓) but are gone after a restart — the model/provider come back blank while only the harness sticks."}`

## Bug Description
In the AGENT MODELS modal (`#agent-models-modal`, `RepoBuilderWeb.ConsoleComponents.agent_models_modal/1`), the operator assigns each worker tier (`fast`/`main`/`heavy`/`leader`) a `{harness, provider, model}`. The selection is persisted to `orchestrators.metadata["agent_models"]` and a transient "Saved ✓" chip confirms it.

**Symptom:** the operator reports the chosen models/providers "do not persist between restarts" — after a LiveView reconnect / server restart the tier rows come back with the **harness still set but the provider and model blank** (`nil`).

**Expected:** once a tier's model is chosen and saved, it stays put until the operator deliberately changes it. A reconnect, a re-render, or re-opening the modal must not silently clear it.

**Actual:** the persisted `provider`/`model` get overwritten with `nil`, leaving a harness-only entry (which the orchestrator then treats as "no model selected — won't spawn").

## Problem Statement
The per-tier `<form phx-change="set_agent_model">` cascade decides what to clear based purely on **which input fired the change** (`_target`), not on whether that input's value **actually changed**. A `change` event on the harness `<select>` that carries the *same* harness value still runs the "harness changed" branch and unconditionally wipes `provider` and `model` to `nil`. Such spurious/no-op `change` events are emitted during LiveView form reconciliation on reconnect (after a server restart) and whenever the operator opens the harness dropdown and re-selects the same harness. The result is the saved model being clobbered.

## Solution Statement
Make the cascade **value-aware** instead of `_target`-aware: only clear `provider`+`model` when the submitted `harness` differs from the tier's currently-stored harness, and only clear `model` when the submitted `provider` differs from the tier's currently-stored provider. A `change` event that does not actually change the harness/provider must be a no-op for the downstream fields (it preserves the stored `provider`/`model`).

This is the minimal, surgical fix: it lives entirely in the `set_agent_model` LiveView event handler / `agent_model_attrs/1` helper in `console_live.ex`. No schema, migration, or context-layer change is required — `Orchestrators.set_agent_model/3` already persists correctly (verified at runtime).

## Steps to Reproduce
1. Open `http://localhost:4000`, open the AGENT MODELS modal (toggle `#agent-models-toggle`).
2. On the `main` row pick harness `pi`, provider `zai`, model `glm-5.2`. Confirm it persists:
   `SELECT metadata->'agent_models'->'main' FROM orchestrators WHERE name='default';` → shows `model: "glm-5.2"`.
3. Fire a `change` event on that row's **harness** `<select>` **without changing its value** (this is what a LiveView reconnect / re-opening the dropdown and re-picking the same harness does):
   ```js
   const s = document.querySelector('#agent-model-main select[name="harness"]');
   s.dispatchEvent(new Event('change', { bubbles: true }));
   ```
4. Re-query the DB → `main` is now `{harness: "pi", provider: null, model: null}` — the model was wiped even though nothing actually changed.

(Confirmed live via Tidewave `browser_eval` + `execute_sql_query` during root-cause: the same-value harness `change` clobbered a stored `glm-5.2` to `nil`.)

## Root Cause Analysis
`lib/repo_builder_web/live/console_live.ex` `agent_model_attrs/1` branches on the form's `_target`:

```elixir
defp agent_model_attrs(%{"_target" => ["harness" | _]} = params),
  do: %{"harness" => nilify_blank(params["harness"]), "provider" => nil, "model" => nil}

defp agent_model_attrs(%{"_target" => ["provider" | _]} = params),
  do: %{"harness" => ..., "provider" => nilify_blank(params["provider"]), "model" => nil}

defp agent_model_attrs(params),
  do: %{"harness" => ..., "provider" => ..., "model" => ...}
```

The cascade assumes "the harness input fired ⇒ the harness changed ⇒ clear downstream". That assumption is false: an HTML/LiveView `change` event on the harness select can fire with an unchanged value (notably during form reconciliation on LiveView reconnect after a server restart, and on re-selecting the same option). When it does, the harness branch nils `provider`+`model`, and `Orchestrators.set_agent_model/3` faithfully persists the wipe — destroying the operator's saved choice. Because reconnect is exactly what happens on "restart", the operator perceives this as "my choices don't persist between restarts".

The backend persistence layer is **not** at fault: runtime testing confirmed `Orchestrators.set_agent_model/3` stores and `agent_model_rows/1` re-displays both claude and pi selections correctly across a page reload. The defect is solely the cascade's clobber-on-no-op behavior in the LiveView handler.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — owns `handle_event("set_agent_model", ...)` (~L567) and `agent_model_attrs/1` (~L1340), the `_target`-based cascade that is the root cause. The fix compares the submitted harness/provider against the currently-stored tier entry (`Orchestrators.agent_models/1` on the socket's orchestrator) before deciding to cascade-clear.
- `lib/repo_builder/orchestrator.ex` — `agent_models/1` (read the current roster to compare against), `set_agent_model/3` (the correct, unchanged persistence path). Read-only reference; **no change expected** here.
- `lib/repo_builder_web/components/console_components.ex` — `agent_models_modal/1` (~L1790) renders the per-tier `<form phx-change="set_agent_model">`. Read-only reference for the form/select structure (`name="harness|provider|model"`, `id="agent-model-#{category}"`).
- `BUILD_PROMPT.md` — §3 typed style guide (keep `@spec`s, precise types), §9 LiveView dashboard conventions. Authoritative for the fix's style.
- `test/repo_builder_web/live/` — location for the new `Phoenix.LiveViewTest` regression test.

### New Files
- `test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs` — a `Phoenix.LiveViewTest` integration test that drives the `set_agent_model` event with a no-op harness change and asserts the stored model survives (fails before the fix, passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Make the cascade value-aware in `console_live.ex`
- In `handle_event("set_agent_model", %{"category" => category} = params, socket)`, fetch the tier's currently-stored entry from the socket's orchestrator: read `Orchestrators.agent_models(orchestrator)` (or reuse `socket.assigns.agent_model_rows` for that `category`) to get the stored `harness`/`provider`.
- Change `agent_model_attrs/1` (or introduce `agent_model_attrs/2` taking the stored entry) so the cascade is driven by an **actual value change**, not just `_target`:
  - Harness branch: clear `provider`+`model` **only if** `nilify_blank(params["harness"]) != stored_harness`; otherwise preserve the submitted `provider`/`model` (i.e., fall through to the no-clear behavior).
  - Provider branch: clear `model` **only if** `nilify_blank(params["provider"]) != stored_provider`; otherwise preserve `model`.
  - Model branch (catch-all): unchanged — persist `{harness, provider, model}` as posted.
- Keep it typed: preserve/extend the `@spec` (e.g. `@spec agent_model_attrs(map(), map()) :: %{optional(String.t()) => String.t() | nil}`), no raising, return the same `%{String.t() => String.t() | nil}` shape that `set_agent_model/3` expects.
- Rationale: a no-op harness/provider `change` event (LiveView reconnect reconciliation, or re-picking the same option) becomes a no-op for downstream fields, so a saved model is never silently wiped.

### 2. Add a LiveView regression test
- Create `test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs` using `RepoBuilderWeb.ConnCase` + `Phoenix.LiveViewTest`.
- Arrange: ensure the default orchestrator exists and a tier (e.g. `main`) is configured with a full `{harness, provider, model}` (call `Orchestrators.set_agent_model/3` directly, or render the LV and drive the three selects).
- Act: render `ConsoleLive` at `/`, then trigger the `set_agent_model` event simulating a **no-op harness change** for that tier — i.e. submit `%{"_target" => ["harness"], "category" => "main", "harness" => <same harness>, "provider" => "", "model" => ""}` (mirrors what the browser sends on a spurious harness `change`). Prefer `render_change([phx-change form], params)` against the row form `#agent-model-main`.
- Assert: after the event, `Orchestrators.agent_models(orchestrator)["main"]` still has the original `provider` and `model` (NOT `nil`). This fails on `main` today (clobbered to `nil`) and passes after the fix.
- Add a second assertion for the genuine case: a harness change to a *different* harness DOES clear `provider`+`model` (preserve existing cascade semantics — no regression).

### 3. Optional UI proof via Tidewave
- Re-run the reproduction in the browser (`browser_eval`): configure `main` to `{pi, zai, glm-5.2}`, dispatch a same-value harness `change`, then `execute_sql_query` to confirm `model` survives. Optionally capture a screenshot of `http://localhost:4000` with the modal open showing the model still selected.

### 4. Run the full validation suite
- Run every command in `Validation Commands` and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs` — the new regression test; fails before the fix, passes after.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the public-function `@spec` convention.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Manual before/after reproduction (Tidewave): set `main` to `{pi, zai, glm-5.2}`, dispatch a same-value harness `change` on `#agent-model-main select[name="harness"]`, then
`SELECT metadata->'agent_models'->'main' FROM orchestrators WHERE name='default';`
— **before:** `model` becomes `null`; **after:** `model` stays `"glm-5.2"`.

## Notes
- No new dependencies; no migration. The persistence layer (`Orchestrators.set_agent_model/3`, `metadata["agent_models"]`) is correct and verified at runtime — the fix is confined to the LiveView cascade decision.
- Root cause was confirmed live during planning via Tidewave: `browser_eval` dispatched a no-op harness `change` and `execute_sql_query` showed a stored `glm-5.2` clobbered to `nil`; the same harness/provider/model writes otherwise persist and survive a page reload.
- Keep the existing genuine-cascade behavior intact: switching to a *different* harness/provider must still clear the now-invalid downstream selections (their option lists change with the parent). Only the *no-op* case must stop clearing.
- Consider (optional, not required for the fix) hardening the component so the harness/provider `<select>` doesn't emit no-op `change` events, but the handler-side value comparison is the authoritative, sufficient fix and also guards the agent/tool path semantics.
