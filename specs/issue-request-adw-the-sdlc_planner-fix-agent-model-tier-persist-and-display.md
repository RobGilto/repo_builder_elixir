# Bug: Agent-model tier persistence and modal display (unified fix + regression suite)

## Metadata
adw_id: `the`
issue_number: `request`

## Description
Two independent bugs combine to make orchestrator-assigned agent-model tiers
(`fast`/`main`/`heavy`/`leader`) invisible or wrong in the AGENT MODELS modal.
Both bugs are documented in their own spec files:

- `specs/issue-request-adw-the-sdlc_planner-fix-agent-models-modal-not-reflecting-orchestrator-config.md`
  (concurrent read-modify-write lost-update race + modal not showing concrete model ids).
- `specs/issue-agent-models-adw-local-sdlc_planner-fix-roster-cascade-clobber.md`
  (LiveView `agent_model_attrs/2` no-op cascade clobbering stored model on reconnect).

This plan is the **unified verification and validation** artifact that closes both
issues: it confirms all three code-level fixes are in place and complete, that all
required regression tests exist with meaningful assertions, and drives a full green
validation suite.

## Problem Statement
**Three defects combined** to produce the symptom "tiers set by the orchestrator do
not persist / are not reflected in the modal":

1. **Lost-update race** — `set_agent_model/3` did an unsynchronized read-modify-write
   over HTTP, so four concurrent `configure_tier` calls overwrote each other's
   categories. Some or all tiers silently disappeared after tool calls that each
   individually returned `configured`.

2. **Missing concrete model id in options list** — `agent_model_rows/1` built
   `model_options` from the registry's curated tier-alias list
   (`["opus","sonnet","haiku"]`), which never contained the concrete ids the
   orchestrator assigns (`claude-haiku-4-5`, etc.). The `<select>` fell back to the
   blank `no model` default instead of marking the stored id `selected`.

3. **No-op cascade clobber** — `agent_model_attrs/2` branched on `_target` alone,
   so a same-value harness `change` event (emitted by LiveView reconnect
   reconciliation) unconditionally wiped `provider`+`model` to `nil` and persisted
   the wipe, destroying the operator's saved choice.

## Solution Statement

### Verified-complete code fixes (all three already present in `main`)

**Fix #1 — atomic write (`set_agent_model/3`):**
Wraps the read-merge-write in a single `Repo.transaction/1` with a `SELECT … FOR
UPDATE` row lock (`from(o in Orchestrator, where: o.id == ^id, lock: "FOR UPDATE")`).
Concurrent tier writes now serialize; each sees the prior writers' committed roster;
entries accumulate without loss. The public `@spec` and return contract are unchanged.
`broadcast_orchestrator_updated/1` is called after the transaction commits.
→ `lib/repo_builder/orchestrator.ex` lines 286–318 + helpers `merge_agent_model!/3`.

**Fix #2 — prepend stored model in `agent_model_rows/1`:**
For each tier row, after computing `base = model_options_for(harness, provider)`,
prepends the assigned model when it is absent from `base`:
`model_options = if(model in [nil, "" | base], do: base, else: [model | base])`.
This matches the header dropdown's existing "Current" optgroup pattern and makes any
stored model selectable regardless of the registry's curation.
→ `lib/repo_builder_web/live/console_live.ex` lines 309–336.

**Fix #3 — value-aware cascade in `agent_model_attrs/2`:**
The harness branch now compares `nilify_blank(params["harness"]) == stored[:harness]`;
if equal (no-op change), it returns the stored harness/provider/model intact. The
provider branch similarly preserves the stored model when the provider is unchanged.
Only genuine value changes cascade-clear downstream fields.
→ `lib/repo_builder_web/live/console_live.ex` lines 1712–1745.

### Verified-present regression tests (all three already written)

All tests exist and cover the right scenarios (verified by inspection):

- `test/repo_builder/orchestrators_agent_models_test.exs`
  — sequential accumulation (4 successive writes → 4 entries) + concurrent
    accumulation (`Task.async_stream` with `Sandbox.mode({:shared, self()})`,
    `max_concurrency: 4` → 4 entries, no lost updates).
- `test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs`
  — no-op harness change preserves stored provider+model; genuine harness change still
    clears them (regression guard for Fix #3).
- `test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs`
  — seeds all four tiers at concrete Anthropic ids via context; asserts `4/4 configured`
    counter and that each tier's concrete id is the `selected` option (regression guard
    for Fixes #1 and #2).

## Relevant Files
- `lib/repo_builder/orchestrator.ex` — Fix #1 (`set_agent_model/3`, `merge_agent_model!/3`).
- `lib/repo_builder_web/live/console_live.ex` — Fix #2 (`agent_model_rows/1`) and Fix #3 (`agent_model_attrs/2`).
- `lib/repo_builder_web/components/console_components.ex` — `agent_models_modal/1` (no change expected; reference for DOM selectors used in tests).
- `lib/repo_builder/orchestrator/tools.ex` — `configure_tier/2` → `set_agent_model/3` (tool entry; no change).
- `test/repo_builder/orchestrators_agent_models_test.exs` — Fix #1 regression (sequential + concurrent).
- `test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs` — Fix #3 regression.
- `test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs` — Fixes #1 + #2 regression.
- `BUILD_PROMPT.md` §3 (typed standard), §8 (persistence/context rules), §9 (LiveView dashboard).
- `ai_docs/typed-elixir-standard.md` — typed coding standard (always-on requirement).
- `AGENTS.md` — Phoenix v1.8 + LiveView + Ecto test conventions.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Verify Fix #1 is complete in `orchestrator.ex`
- Open `lib/repo_builder/orchestrator.ex`, locate `set_agent_model/3` (around line 286).
- Confirm the function body is wrapped in `Repo.transaction/1` using
  `from(o in Orchestrator, where: o.id == ^id, lock: "FOR UPDATE")` to lock the row before reading.
- Confirm `Repo.rollback(:not_found)` is called when the row is `nil`.
- Confirm `merge_agent_model!/3` calls `update_record/2` and `Repo.rollback(:not_found)` on write error.
- Confirm `broadcast_orchestrator_updated/1` is called **outside** the transaction (after `Repo.transaction/1` returns).
- Confirm the public `@spec` still reads
  `{:ok, Orchestrator.t()} | {:error, :not_found | :invalid_category}` (no leaked
  transaction-tuple shape).
- If any of the above is absent, apply the correction now (see spec file #1 Step 2 for the
  authoritative prescription).

### 2. Verify Fix #2 is complete in `console_live.ex` (`agent_model_rows/1`)
- Open `lib/repo_builder_web/live/console_live.ex`, locate `agent_model_rows/1` (around line 308).
- Confirm each row's `model_options` is computed as:
  `if(model in [nil, "" | base], do: base, else: [model | base])` (or equivalent
  `Enum.uniq/1`-based form that prepends when absent).
- Confirm the row map still has the same shape (`:category`, `:harness`, `:provider`,
  `:model`, `:harness_options`, `:provider_options`, `:model_options`) with no removed fields.
- If the prepend guard is absent, apply it now (see spec file #1 Step 3).

### 3. Verify Fix #3 is complete in `console_live.ex` (`agent_model_attrs/2`)
- Locate `agent_model_attrs/2` (around line 1712).
- Confirm the harness branch compares the submitted harness against `stored[:harness]`
  (atom-keyed, not string-keyed — the row maps from `agent_model_rows/1` use atom keys).
- Confirm a match → returns `%{"harness" => stored[:harness], "provider" => stored[:provider], "model" => stored[:model]}`.
- Confirm a mismatch → returns `%{"harness" => submitted, "provider" => nil, "model" => nil}`.
- Confirm the provider branch preserves `stored[:model]` when provider is unchanged.
- Confirm the `@spec` reads
  `@spec agent_model_attrs(map(), map()) :: %{optional(String.t()) => String.t() | nil}`.
- If any clause is missing, apply the correction (see spec file #2 Step 1).

### 4. Verify regression tests exist and are well-formed
- Open `test/repo_builder/orchestrators_agent_models_test.exs`. Confirm:
  - Sequential accumulation test: 4 successive `set_agent_model/3` calls → `map_size == 4`.
  - Concurrent test: `Sandbox.mode(Repo, {:shared, self()})` is set;
    `Task.async_stream` with `max_concurrency: 4`; `map_size == 4` after.
- Open `test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs`. Confirm:
  - No-op harness change test: stores `{pi, zai, glm-5.2}`, fires same-harness `change`,
    asserts provider/model survive.
  - Genuine harness change test: fires different-harness `change`, asserts downstream cleared.
- Open `test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs`. Confirm:
  - Seeds all four tiers via `Orchestrators.set_agent_model/3`.
  - Asserts `has_element?(view, "#agent-models-modal", "4/4 configured")`.
  - For each tier, asserts the concrete model id is `selected` in the row's model `<select>`.
  - Negative guard: blank "no model" option is NOT selected for a configured tier.
- If any test file is absent or any assertion is missing, add it now per the authoritative spec.

### 5. Run the targeted regression tests first
```
scripts/pg.sh start
mix test test/repo_builder/orchestrators_agent_models_test.exs \
         test/repo_builder_web/live/test_agent_model_cascade_persist_test.exs \
         test/repo_builder_web/live/test_agent_models_modal_reflects_config_test.exs \
         --warnings-as-errors
```
All three files must pass with zero failures. If any fail, diagnose and fix before proceeding.

### 6. Run the full validation suite
```
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
```
Fix every failure (in that order) before reporting success. Do not proceed if any command
is non-green.

## Acceptance Criteria
- `set_agent_model/3` is wrapped in a `Repo.transaction` with `FOR UPDATE` lock; four concurrent calls for the four categories produce `map_size == 4` in the DB (no lost updates).
- `agent_model_rows/1` always includes the stored model in `model_options`, so a concrete Anthropic id assigned by the orchestrator renders as the `selected` option in the modal even if the registry's curated list omits it.
- `agent_model_attrs/2` is value-aware: a same-value harness/provider `change` event (LiveView reconnect) does NOT wipe stored downstream fields; only a genuine value change cascades.
- All three regression test files pass with zero failures.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` are all green.

## Validation Commands
Execute every command to validate the work with zero regressions.

- `mix compile --warnings-as-errors` — Compile clean; gradual checker + warnings-as-errors pass.
- `mix test --warnings-as-errors` — Full ExUnit suite, zero failures.
- `mix format --check-formatted` — Formatting.
- `mix credo --strict` — Lint incl. the `@spec` convention.
- `mix dialyzer` — Contract checking; `set_agent_model/3` return type must remain
  `{:ok, Orchestrator.t()} | {:error, :not_found | :invalid_category}` with no new warnings.

## Notes
- All three code-level fixes were verified present in the source as of 2026-06-21.
  All three regression test files were also verified present with meaningful assertions.
  The primary remaining work is running the validation suite and closing any gap found.
- **Key data-shape gotcha:** `agent_model_rows/1` returns maps with atom keys
  (`:harness`, `:provider`, `:model`). The `handle_event("set_agent_model", …)` handler
  reads `stored = Enum.find(socket.assigns.agent_model_rows, %{}, …)` and then
  `agent_model_attrs/2` accesses `stored[:harness]` — correct, as these are atom keys.
  The resulting attrs map uses string keys (`"harness"`, `"provider"`, `"model"`) to
  match what `set_agent_model/3` expects from its JSONB write.
- **Out of scope:** other `metadata` read-modify-writes (e.g. `set_model/2`'s
  `record_recent_model`) share the same race shape but are not driven by burst-concurrent
  tool calls and are not part of this fix's scope. The `put_metadata_locked/3` helper
  (used by `set_timezone/2`) already uses the same `FOR UPDATE` pattern — it is the
  correct reference if those functions ever need hardening.
- **Authoritative specs for the individual defects** (honored as the source of truth):
  - `specs/issue-request-adw-the-sdlc_planner-fix-agent-models-modal-not-reflecting-orchestrator-config.md`
  - `specs/issue-agent-models-adw-local-sdlc_planner-fix-roster-cascade-clobber.md`
