# Bug: PI orchestrator's provider dropdown shows only "anthropic" — zai (and other pi providers) are unselectable

## Metadata
issue_number: `0`
adw_id: `local`
issue_json: `{}`

## Bug Description

When the operator selects the **PI** harness on a project's orchestrator (the console header harness toggle, `PI` segment), the **provider `<select>` dropdown renders only the `anthropic` option** — so the operator cannot pick `zai` (or `openai`, `google`, `deepseek`, …) as the pi provider and therefore cannot select a zai model (e.g. `glm-5.2`).

Expected: after clicking `PI`, the provider dropdown lists all 16 pi providers from the registry config (`anthropic`, `openai`, `google`, `xai`, `deepseek`, `mistral`, `groq`, `cerebras`, `fireworks`, `together`, `openrouter`, **`zai`**, `minimax`, `kimi-coding`, `nvidia`, `huggingface`).

Actual: only `anthropic` is offered, which is `claude`'s provider list — i.e. the header is rendering **claude's** provider options while the operator believes they have selected **pi**.

## Problem Statement

The backend is healthy — `RepoBuilder.Harness.Registry.orchestrator_defaults("pi")[:providers]` returns all 16 providers (verified live via Tidewave `project_eval`), `RepoBuilder.Harness.Pi.Models.list("zai")` returns GLM models, the orchestrator changeset accepts `zai` (open `:string`), and the `default` platform orchestrator is persisted as `pi`/`zai`/`glm-5.2`. So this is **not** a config/registry omission.

The symptom is reproducible only for project-bound orchestrators (e.g. `orch:catchPhrase`) that are persisted with `harness = "claude"` while carrying a **stale, harness-incompatible `model`** (e.g. `glm-5.2`, a zai model). Several such inconsistent rows already exist in the live DB:

| name | harness | provider | model |
|---|---|---|---|
| `orch:catchPhrase` | `claude` | `nil` | `glm-5.2` (a **zai** model) |
| `orch:testingGround` | `fake` | `nil` | `claude-opus-4-8` |

Because the header's provider dropdown is derived from the **persisted `harness`** (`provider_options_for(orchestrator.harness)`), a `claude` orchestrator correctly offers only `anthropic`. The operator sees the `glm-5.2` model chip ("Current") and reasonably believes they are on `pi`, but the harness is actually `claude` — so the provider dropdown cannot surface `zai`.

The specific problem to solve: (1) **prevent** the inconsistent state where an orchestrator's `{harness, provider, model}` triple is self-contradictory (a `claude` harness holding a `zai` model with a `nil` provider), and (2) **ensure** the harness toggle's `set_harness` cascade always lands the orchestrator in a coherent state whose provider dropdown matches the selected harness, so zai is selectable once pi is chosen.

## Solution Statement

Two-part fix, both surgical:

1. **`Orchestrators.set_model/2` must reset `provider` to `nil` when the new model is foreign to the current harness's known models.** Today `set_model` only writes `model` + clears `session_id` and records recents — it leaves `provider` untouched. So an operator can set a zai model on a `claude` orchestrator, producing the `claude`/`nil`/`glm-5.2` orphan state. When the chosen model is not offered by the current harness (`Registry.orchestrator_models(harness, provider)` plus the live pi catalog for the pi harness), `set_model` should clear `provider` (forcing the operator to re-pick a provider that actually offers that model) — OR, better, **refuse** the model on a mismatched harness and surface a flash, mirroring the open-identity discipline. The minimal, low-friction choice: clear `provider` on mismatch and let the operator pick a matching provider; this keeps the triple consistent without a hard reject.

2. **`Orchestrators.set_harness/2` already clears `model` and `session_id` and resets `provider` to the harness's `default_provider`** (`apply_harness_defaults/2`). This is correct — flipping to `pi` yields `provider: nil` (pi has no forced default) and the header re-derives `provider_options` from `pi`, surfacing all 16 providers. The bug is therefore **not** in `set_harness`; it is that the inconsistent rows were created via `set_model` on a `claude` orchestrator (loophole #1). Closing loophole #1 is the root-cause fix.

3. **One-time data repair**: backfill the existing inconsistent orchestrator rows so the header dropdown immediately matches reality. For any row whose `model` is not in its `harness`'s known model set (registry curated list +, for pi, the live `PiModels` catalog), null the `model` (and, if `provider` is `nil`, leave it — the operator re-picks). This is idempotent and safe; it only touches self-contradictory rows.

This is the minimal change set: one function guard in `set_model/2`, one backfill migration/script, and a LiveView integration test proving the cascade. No schema, no event contract, no new harness, no new dependency.

## Steps to Reproduce

1. Start the app (`mix phx.server`), open `http://localhost:4000/`.
2. If the active project's orchestrator is `claude` (the common default — the global `default_agent_models` roster seeds every tier as `claude`/`anthropic`), the header harness toggle shows `CLAUDE` active and the provider dropdown shows only `anthropic`.
3. Click `PI` in the harness toggle → `set_harness` fires → `apply_harness_defaults` resets `{provider: nil, model: nil, session_id: nil}` and the header re-derives `provider_options` from pi. **At this point zai IS selectable.** (This path is healthy.)
4. **The broken path**: instead of switching harness first, the operator picks a model from the model dropdown's "Recently selected" / "Current" optgroup (e.g. `glm-5.2` from a prior zai session) **while the harness is still `claude`**. `set_model` writes `glm-5.2` but leaves `harness = "claude"`, `provider = nil`. The header now shows `glm-5.2` as the model but the provider dropdown is still claude's (`anthropic` only). The operator cannot select `zai` because the harness is `claude`.
5. Symptom observed: "when selecting the PI harness, there is only anthropic as a provider selection" — this is the operator's reading of step 4's end state (the model chip looks like a zai model, but the harness was never actually flipped, so only anthropic shows).

## Root Cause Analysis

**Direct cause**: `RepoBuilder.Orchestrator.set_model/2` (lib/repo_builder/orchestrator.ex, ~line 707) writes `model` without consulting the current `harness`/`provider` consistency. It records recents keyed by provider, but it does NOT verify that the model belongs to the current harness's provider, nor does it clear/reset `provider` when the model is foreign to the harness. This allows the `{claude, nil, glm-5.2}` orphan state, where the model dropdown advertises a zai model while the harness is claude — and the provider dropdown (derived from `harness`) correctly shows only `anthropic`, making zai unselectable.

**Why the header looks wrong**: `ConsoleLive.assign_orchestrator_selection/2` computes `provider_options: provider_options_for(orchestrator.harness)`. For `claude`, `provider_options_for("claude")` falls through to `[default_provider]` = `["anthropic"]` because `claude`'s registry entry has NO `:providers` key (only `:models` keyed by `"anthropic"`). So the dropdown is a faithful reflection of the persisted harness — the data, not the rendering, is wrong.

**Why `set_harness` is not the culprit**: `set_harness` → `apply_harness_defaults/2` correctly resets `{provider: default_provider, model: nil, session_id: nil}` on every harness switch (lib/repo_builder/orchestrator.ex:107-122). Flipping to `pi` yields `provider: nil` and the header recomputes the full 16-provider list. Verified live: the `default` platform orchestrator is persisted `pi`/`zai`/`glm-5.2` and works end-to-end.

**Contributing factor**: the model dropdown's "Recently selected" optgroup (`Orchestrators.recent_models/2`, keyed by provider) can surface a zai model even when the operator has since switched the harness to claude, inviting the inconsistent `set_model` call. The recents list is provider-scoped but NOT harness-scoped, so a model remembered under `zai` is offered while the harness is `claude`.

**Evidence (Tidewave `project_eval`, live app)**:
- `RepoBuilder.Harness.Registry.orchestrator_defaults("pi")[:providers]` ⇒ 16 providers incl. `"zai"`.
- `RepoBuilder.Harness.Pi.Models.list("zai")` ⇒ `["glm-4.5-air","glm-4.7","glm-5","glm-5-turbo","glm-5.1","glm-5.2","glm-5v-turbo"]`.
- `RepoBuilder.Orchestrator.Orchestrator` rows include `{orch:catchPhrase, claude, nil, glm-5.2}` and `{orch:testingGround, fake, nil, claude-opus-4-8}` — both self-contradictory.
- `default` platform orchestrator ⇒ `{pi, zai, glm-5.2}` (healthy — zai IS selectable here).

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/orchestrator.ex` — `set_model/2` (the loophole) and `apply_harness_defaults/2`/`set_harness/2` (reference for the correct cascade). The guard goes here.
- `lib/repo_builder/harness/registry.ex` — `orchestrator_models/2` and `orchestrator_defaults/1` — used to decide whether a model belongs to the current harness (the consistency check).
- `lib/repo_builder/harness/pi/models.ex` — `PiModels.list/1` — for the pi harness, the live catalog (`pi --list-models`) is authoritative for model membership; the static registry list is the fallback. The consistency check must consult both for `pi`.
- `lib/repo_builder_web/live/console_live.ex` — `set_model` handler (~line 1062), `model_options_for/2`, `assign_orchestrator_selection/2`. No change expected here (the fix is in the context), but the integration test drives these events.
- `lib/repo_builder_web/components/console_components.ex` — `header_bar/1` provider/model dropdown rendering (~line 40-190). Reference only.
- `BUILD_PROMPT.md` §3 (typed style), §8 (contexts/`Repo`), §9 (LiveView dashboard), §10 (open harness/provider identity).
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (`@spec`, tagged tuples, no raises).

### New Files
- `test/repo_builder_web/live/test_pi_provider_dropdown_test.exs` — Phoenix.LiveViewTest proving zai is selectable on the pi harness and that setting a foreign model cannot orphan the harness/provider/model triple.
- `priv/repo/migrations/<ts>_repair_inconsistent_orchestrator_models.exs` — one-time backfill that nulls models not offered by their orchestrator's harness (idempotent; only touches the inconsistent rows).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Add a harness-consistency helper to the Registry
- Add `RepoBuilder.Harness.Registry.model_offered_by_harness?/2` (`@spec model_offered_by_harness?(String.t(), String.t(), String.t() | nil) :: boolean()`): returns `true` when `model` is in the harness's known model set for `provider`. For `pi`, consult `RepoBuilder.Harness.Pi.Models.list(provider)` first, then fall back to `orchestrator_models("pi", provider)`; for other harnesses, consult `orchestrator_models(harness, provider)`. A `nil`/`""` model is always "offered" (no-op). This is the single reader for the consistency check; keep it fail-soft (unknown harness ⇒ `false`).

### Guard `set_model/2` to keep the triple consistent
- In `lib/repo_builder/orchestrator.ex` `set_model/2` (~line 707): after fetching the orchestrator, if `model` is present and NOT `Registry.model_offered_by_harness?(orchestrator.harness, orchestrator.provider, model)`, **clear `provider`** in the same `update_fields` write (set `provider: nil`). Rationale: the model is foreign to the current harness+provider; nulling `provider` forces the operator to pick a provider that actually offers it (the dropdown will then surface zai when they select pi). Do NOT silently change `harness` — that would surprise the operator; clearing `provider` is the minimal, honest correction.
- Keep `@spec` precise: `set_model(Ecto.UUID.t(), String.t() | nil) :: {:ok, Orchestrator.t()} | {:error, :not_found}`. Return a tagged tuple (already does). No raise.
- Record recents only when the triple is consistent (model is offered by the harness+provider); otherwise skip the recents update so the foreign model is not re-offered later from a stale provider key.

### Make `recent_models/2` harness-aware (defense in depth)
- Currently `recent_models/2` is keyed by provider only. Optionally extend it to filter recents to models the current harness offers (consult `Registry.model_offered_by_harness?/3`), so the model dropdown never advertises a zai model while the harness is `claude`. This is defense in depth on top of the `set_model` guard; keep it minimal.

### One-time backfill migration
- `mix ecto.gen.migration repair_inconsistent_orchestrator_models`
- In `up/0`: for every `orchestrators` row, if `model IS NOT NULL` and the model is not offered by its harness (per the same `Registry.model_offered_by_harness?/3` check, callable via the migrated app module), set `model = NULL` (leave `provider` as-is). Implement the membership check in Elixir in the migration by calling `RepoBuilder.Harness.Registry` (the migration runs under the app, so module calls are fine) — but guard with `Code.ensure_loaded?/1` so a partial boot never crashes. `down/0` is a no-op (data repair is irreversible by nature).
- Keep it idempotent: only touches rows where the model is foreign; a second run is a no-op.

### LiveView integration test
- Create `test/repo_builder_web/live/test_pi_provider_dropdown_test.exs`.
- Test 1 (the healthy path): start a console LiveView on a project whose orchestrator is seeded `pi`; assert `has_element?(view, "#orchestrator-provider option[value='zai']")` — fails before any fix only if the orchestrator was seeded claude; use the `pi`-seeded orchestrator to prove zai surfaces.
- Test 2 (the loophole, the real regression): seed an orchestrator as `claude`/`anthropic`/`claude-opus-4-8`; render the view; assert the provider dropdown has only `anthropic`; then `render_change` `"set_model"` with a zai model (`glm-5.2`) — assert the orchestrator's persisted `provider` becomes `nil` (re-fetch via `Orchestrators.fetch/1`) and that the model dropdown no longer advertises `glm-5.2` as "Current" while the harness is claude.
- Test 3 (the cascade): from a `claude` orchestrator, `phx-click` `"set_harness"` with `"pi"`; assert the provider dropdown now contains `zai` (`has_element?(view, "#orchestrator-provider option[value='zai']")`) and the model dropdown offers GLM models.
- Use `start_supervised!/1` for any processes; no `Process.sleep`. Reference the real DOM ids (`#orchestrator-provider`, `#orchestrator-model`, `#orchestrator-harness`, `harness-pi`).

### Validation
- Run the `Validation Commands` below end-to-end; every one must pass with zero warnings/errors.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_pi_provider_dropdown_test.exs` — the new regression test (fails before the fix, passes after).
- `mix ecto.migrate` — apply the backfill migration cleanly.
- `mix test --warnings-as-errors` — full suite green.
- `mix compile --warnings-as-errors` — gradual set-theoretic type checker + `warnings_as_errors` clean.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — every public function has an `@spec` (incl. the new `Registry.model_offered_by_harness?/3`).
- `mix dialyzer` — no new warnings, no stale ignore filters.

## Notes
- The bug is a **data-consistency** defect, not a config/rendering defect. The registry, live pi catalog, changeset, and header rendering are all correct; zai is selectable the moment the harness is genuinely `pi`. The operator-facing symptom arises because `set_model/2` lets a model be set that is foreign to the persisted harness, after which the provider dropdown (correctly) reflects that harness — claude ⇒ anthropic only.
- The minimal fix clears `provider` (not `harness`) on a foreign-model `set_model`, because silently flipping the harness would surprise the operator and could spawn a different adapter than intended; nulling `provider` is honest and forces an explicit, dropdown-driven provider pick.
- Verified live via Tidewave (`http://localhost:4000/tidewave/mcp`, `project_eval`): the `default` platform orchestrator (`pi`/`zai`/`glm-5.2`) works, confirming zai is reachable end-to-end once the harness is pi.
- No new dependency required. `:req` is already present but unused by this fix. No changes to `mix.exs`.
