# Feature: Resolve orchestrator-spawned worker models to the latest of their family

## Metadata
issue_number: `the`
adw_id: `orchestrator`
issue_json: `create`

## Feature Description
When the orchestrator creates worker agents and assigns them a model, the model
string is currently passed through **verbatim** to the harness adapter. For Claude
this means a concrete pinned id like `claude-sonnet-4-5` or `claude-opus-4-5` runs
that *specific, possibly older* model instead of the latest of its family. The same
problem applies to pi: a selected `claude-opus-4-1` (anthropic via pi) or
`MiniMax-M2` keeps running even after a newer sibling (`claude-opus-4-5`,
`MiniMax-M3`) is available.

This feature introduces a **single, harness-blind model-resolution seam** that maps
the operator/orchestrator-selected model to the *latest* model of the same family
before the worker is persisted and spawned:

- **Claude** — a concrete `claude-<family>-<version>` id resolves to the family
  alias (`opus` / `sonnet` / `haiku` / `fable`), which the `claude` CLI itself
  always resolves to the newest model of that family. This needs zero
  "latest-version" maintenance and is bulletproof for Claude.
- **pi** (and any other harness with a model catalog) — the selected model resolves
  to the newest catalog entry sharing the same family stem, derived from the
  *latest-first* ordered catalog (`Pi.Models` live list, then the static
  `Registry.orchestrator_models/2` list). Fail-soft: when no newer sibling can be
  determined, the original selection is returned unchanged.

The resolution is applied at the two points where the orchestrator "selects a model"
for a worker: `create_agent` (the worker spec) and `configure_tier` (the roster
entry), so the worker row is persisted — and therefore displayed, priced, and
spawned — with the latest model.

## User Story
As an operator running the orchestration console
I want every worker the orchestrator spawns to run the **latest** model of the
family I selected (especially Claude, but also pi providers)
So that I never accidentally pay for or get worse results from a stale pinned model
when a newer one of the same family is already available.

## Problem Statement
Selecting a concrete model id (now possible since the header/agent-models dropdowns
offer pinned ids, e.g. `claude-opus-4-5`, `claude-sonnet-4-5`, pi's
`claude-opus-4-1`, `MiniMax-M2`) pins the worker to that exact version forever. The
`claude` CLI only auto-upgrades the family **aliases** (`opus`/`sonnet`/`haiku`) — a
concrete id is honored literally. pi likewise runs whatever string it is given. There
is no place in the spawn path that maps a selection to the newest sibling, so workers
silently run older models.

## Solution Statement
Add `RepoBuilder.Harness.ModelResolver` — a harness-blind module with a single public
`latest/3` (`harness`, `provider`, `model`) that returns the newest model of the
selected family:

- For `"claude"`, regex-match `claude-(opus|sonnet|haiku|fable)…` and return the
  family alias (already-an-alias and unknown strings pass through unchanged). The CLI
  resolves the alias to the latest.
- For every other harness, compute a **family stem** of the selection (strip the
  trailing version token) and return the first (latest-first) entry in the merged
  ordered catalog (`Pi.Models.list/1` ++ `Registry.orchestrator_models/2`) whose stem
  matches; otherwise return the input unchanged.

Call `ModelResolver.latest/3` from `RepoBuilder.Orchestrator.Tools` at the
`resolve_agent_spec` / `resolve_category` boundary (the `create_agent` path) and in
`configure_tier`, so the resolved model is what gets persisted on the worker / roster
and subsequently spawned. The resolver is fail-soft and pure (catalog reads are
already cached/fail-soft), so no behavior regresses when pi is absent or the family is
unrecognized.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/tools.ex` — the harness-blind orchestrator tool
  logic. `create_agent/2` → `resolve_agent_spec/2` → `resolve_category/2` resolve the
  worker's `{harness, provider, model}` before `Agents.create_worker/2`;
  `configure_tier/2` writes a roster entry via `Orchestrators.set_agent_model/3`.
  These are the two "selects a model" boundaries where resolution is injected.
- `lib/repo_builder/harness/registry.ex` — `orchestrator_models/2` returns the static,
  *latest-first* model list per `harness`+`provider` (the catalog ordering the
  resolver relies on). Single source for `config :repo_builder, :harnesses`.
- `lib/repo_builder/harness/pi/models.ex` — live `pi --list-models` catalog
  (`list/1`, `all/0`), cached + fail-soft, disabled in test. The pi side of the
  catalog the resolver consults for the newest sibling.
- `lib/repo_builder/harness/claude.ex` — already carries `@model_aliases`
  (`opus`→`claude-opus-4-8`, etc.) for *pricing canonicalization* and passes
  `opts[:model]` verbatim to `--model`. Confirms the CLI resolves the family alias to
  the latest; the resolver's Claude branch produces those same aliases.
- `config/config.exs` — the `:harnesses` registry; the Claude `orchestrator.models`
  list (aliases + concrete ids, latest-first) and pi's per-provider lists. No change
  required for Claude resolution; informs the pi family-stem logic and tests.
- `lib/repo_builder/orchestrator.ex` — `Orchestrators` context: `agent_models/1`,
  `agent_categories/0`, `set_agent_model/3`. Confirms where roster entries live
  (no signature change needed).
- `BUILD_PROMPT.md` §4 (event/harness contract), §10 (extensibility — harness-blind
  logic lives in Elixir once; adding/altering harness behavior is config + one
  module), §3 (typed style guide).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every
  public function, precise types, `@type`, no needless `any()`/`map()`).

### New Files
- `lib/repo_builder/harness/model_resolver.ex` — `RepoBuilder.Harness.ModelResolver`
  with `@spec latest(harness :: String.t() | nil, provider :: String.t() | nil,
  model :: String.t() | nil) :: String.t() | nil`. Pure, fail-soft, harness-blind.
- `test/repo_builder/harness/model_resolver_test.exs` — unit tests for Claude alias
  collapsing, pi family-stem resolution against an injected catalog, and pass-through
  fallbacks/edge cases.
- `test/repo_builder/orchestrator/tools_model_latest_test.exs` — integration test
  proving `create_agent` and `configure_tier` persist the resolved (latest) model.

## Implementation Plan
### Phase 1: Foundation
Build the standalone `ModelResolver` module with its two resolution strategies
(Claude alias collapse; catalog-ordered family-stem match) and full unit coverage.
It depends only on `Registry` and `Pi.Models`, both already fail-soft, so it is
independently testable with no orchestrator/session wiring.

### Phase 2: Core Implementation
Wire `ModelResolver.latest/3` into `RepoBuilder.Orchestrator.Tools` at the two
model-selection boundaries — `resolve_agent_spec/2` (covering both the explicit-arg
and `resolve_category/2` branches) and `configure_tier/2` — so the resolved model is
the value persisted on the worker row and the roster entry.

### Phase 3: Integration
Add an integration test driving `Tools.call("create_agent", …)` and
`Tools.call("configure_tier", …)` to assert the persisted worker/roster model is the
resolved latest. Verify end-to-end against the running app via Tidewave `project_eval`
that `ModelResolver.latest("claude", "anthropic", "claude-sonnet-4-5")` → `"sonnet"`
and run the full validation gate (compile/test/format/credo/dialyzer) for zero
regressions.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative context
- Read `ai_docs/typed-elixir-standard.md` (always row) and `BUILD_PROMPT.md` §10 +
  §4 before writing code, so the new module honors the typed standard and the
  "harness-blind logic in Elixir once" rule.

### 2. Create `RepoBuilder.Harness.ModelResolver`
- New file `lib/repo_builder/harness/model_resolver.ex`.
- `@moduledoc` explaining the seam: maps an operator/orchestrator-selected model to
  the latest of its family; harness-blind; fail-soft (unknown family / absent catalog
  ⇒ input returned unchanged); pure (no process state).
- Public `@spec latest(String.t() | nil, String.t() | nil, String.t() | nil) ::
  String.t() | nil` and `def latest(harness, provider, model)`.
  - `nil`/`""` model ⇒ return as-is.
  - `harness == "claude"` ⇒ `latest_claude(model)`:
    - Module attribute `@claude_families ~w(opus sonnet haiku fable)`.
    - If `model` is already one of `@claude_families`, return it unchanged.
    - Regex `~r/^claude-(opus|sonnet|haiku|fable)\b/` on `model`: on match return the
      captured family (the alias the CLI resolves to latest); no match ⇒ `model`.
  - any other harness ⇒ `latest_from_catalog(harness, provider, model)`:
    - Build the ordered, latest-first, deduped candidate list:
      `Pi.Models.list(provider) ++ Registry.orchestrator_models(harness, provider)`
      then `Enum.uniq/1`.
    - Compute `stem = family_stem(model)`; find the first candidate `c` with
      `family_stem(c) == stem`; return it, else `model`.
- `@spec family_stem(String.t()) :: String.t()` — strip a trailing version token so
  versioned siblings collapse to one family key while distinct variants stay
  separate. Use a conservative regex that removes a trailing run of
  version-ish segments only: e.g. `~r/[-_](?:v?\d+(?:[.\-]\d+)*|M\d+|\d{8})$/i`
  applied once (e.g. `claude-opus-4-1` → `claude-opus`, `MiniMax-M2` → `MiniMax`,
  `gpt-5` → `gpt-5` stays distinct from `gpt-5-mini` which keeps `-mini`). Document
  the heuristic and its deliberate conservatism (better to NOT upgrade than to
  cross-upgrade `gpt-5-mini` → `gpt-5`).
- Every public function gets an `@spec`; use precise `String.t()`/list types, no
  `any()`/`map()`. Private helpers may omit `@impl`-style specs only where the typed
  standard allows, but prefer specs on non-trivial privates.

### 3. Unit-test `ModelResolver` (write tests before wiring)
- New file `test/repo_builder/harness/model_resolver_test.exs`.
- Claude: `latest("claude", "anthropic", "claude-sonnet-4-5") == "sonnet"`;
  `"claude-opus-4-5" -> "opus"`; `"claude-haiku-4-5" -> "haiku"`; alias passthrough
  (`"opus" -> "opus"`); unknown (`"claude-frobnicate-9" -> unchanged`); nil/"" ⇒ as-is.
- pi/catalog: with `Application.put_env(:repo_builder, :pi_models_discovery, false)`
  (so only the static registry list is used — deterministic in test), assert that a
  selection resolves to the latest-first registry sibling for that provider (e.g. for
  the test `:harnesses` pi `openai` list, an older entry resolves to the first listed
  model of the same stem; a model with no sibling passes through). Cover the
  `gpt-5-mini` vs `gpt-5` non-cross-upgrade case explicitly.
- Fallback: unknown harness ⇒ input unchanged; empty catalog ⇒ input unchanged.

### 4. Wire resolution into the worker-spec boundary in `Tools`
- In `lib/repo_builder/orchestrator/tools.ex`, alias the new module
  (`alias RepoBuilder.Harness.ModelResolver`).
- In `resolve_agent_spec/2`, after building the spec map (both the explicit-arg
  branch and the value returned from `resolve_category/2`), map the resolved `:model`
  through `ModelResolver.latest(spec.harness, spec.provider, spec.model)`. Keep it a
  single chokepoint: prefer resolving the `model` field of the `%{harness:, provider:,
  model:}` map once, right before it is returned, so both branches are covered without
  duplication.
- Confirm the persisted worker uses the resolved model: `create_agent/2` already reads
  `spec.model` into `params["model"]`, so no further change is needed there.

### 5. Wire resolution into `configure_tier/2`
- In `configure_tier/2`, resolve the `model` through
  `ModelResolver.latest(harness, provider, model)` before building `attrs` /
  calling `Orchestrators.set_agent_model/3`, and return the resolved model in the
  `{:ok, …}` payload so the orchestrator sees what was actually stored.
- Leave `Orchestrators` / `Registry` signatures unchanged (resolution is a Tools-layer
  concern; the context stays a thin persistence boundary per §8/§10).

### 6. Integration test for the Tools boundary (LiveView not required)
- New file `test/repo_builder/orchestrator/tools_model_latest_test.exs`.
- Using the existing orchestrator/agent test fixtures (mirror
  `test/repo_builder/orchestrators_agent_models_test.exs` and the `tools` tests),
  drive `Tools.call("create_agent", orch_id, %{"name" => …, "harness" => "claude",
  "model" => "claude-sonnet-4-5"})` and assert the created worker's `model` is
  `"sonnet"`. Drive `Tools.call("configure_tier", orch_id, %{"category" => "heavy",
  "model" => "claude-opus-4-5", "harness" => "claude"})` and assert the persisted
  roster entry (`Orchestrators.agent_models/1`) stores `"opus"`.
- Add a pi-side case with `:pi_models_discovery` disabled asserting catalog-ordered
  resolution against the test registry list (or document why it passes through).

### 7. (No UI change) — confirm display correctness
- The header/agent-models dropdowns and worker rail already render `worker.model`;
  because resolution happens before persistence, the UI now shows the resolved family
  alias / latest id with no template change. No new LiveView test is required for this
  feature (no new interaction), but spot-check via Tidewave Web vision mode against
  `http://localhost:4000` is optional visual proof.

### 8. Runtime verification via Tidewave
- Use `project_eval` to assert the live behavior:
  `RepoBuilder.Harness.ModelResolver.latest("claude", "anthropic",
  "claude-sonnet-4-5")` returns `"sonnet"`, and
  `latest("pi", "anthropic", "claude-opus-4-1")` resolves to the newest anthropic
  sibling in the live catalog (or unchanged when pi is absent).

### 9. Run the full validation gate
- Run every command in **Validation Commands** and fix any failure before declaring
  done. Zero failures, zero new warnings, zero new Dialyzer findings.

## Testing Strategy
### Unit Tests
- `ModelResolver` Claude branch: concrete id → family alias for opus/sonnet/haiku/
  fable; alias passthrough; unknown family passthrough; `nil`/`""` handling.
- `ModelResolver` catalog branch: family-stem grouping picks the latest-first sibling;
  conservative stem prevents `gpt-5-mini` → `gpt-5` cross-upgrade; empty/absent
  catalog and unknown harness pass through unchanged.
- `Tools.create_agent` persists the resolved model on the worker row.
- `Tools.configure_tier` persists the resolved model in the roster and echoes it.

### Edge Cases
- Already-alias Claude selection (`opus`) — must NOT be re-mangled.
- Claude id with a non-standard family (`claude-experimental-x`) — pass through.
- pi model with no version suffix (`glm-4.6` vs `glm-4.5-air`) — `-air` variant must
  stay its own family (no cross-upgrade to `glm-4.6`).
- pi discovery disabled (test env) — resolution falls back to the static registry list
  and never shells out.
- `nil` provider and `nil`/blank model — return unchanged, no crash.
- Unknown harness string — return unchanged (fail-soft, no registry entry).
- Catalog momentarily empty (cold cache) — return unchanged rather than blank.

## Acceptance Criteria
- A worker created via `create_agent` with `model: "claude-sonnet-4-5"` is persisted
  and spawned with model `"sonnet"` (CLI resolves to latest sonnet); `"claude-opus-4-5"`
  → `"opus"`; `"claude-haiku-4-5"` → `"haiku"`.
- A `configure_tier` call with a concrete Claude id stores the family alias in the
  roster and returns it in the tool result.
- For pi (`harness != "claude"`), a selected model resolves to the newest catalog
  sibling of the same family when one exists, and to the original selection otherwise.
- No cross-family upgrade occurs (e.g. `gpt-5-mini` never becomes `gpt-5`,
  `glm-4.5-air` never becomes `glm-4.6`).
- Resolution is fail-soft: pi absent / test env / unknown family ⇒ original selection
  preserved; no crash and no blank model.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass
  with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/harness/model_resolver_test.exs` — the resolver unit
  tests (Claude alias collapse, pi catalog family-stem resolution, fallbacks).
- `mix test test/repo_builder/orchestrator/tools_model_latest_test.exs` — the
  Tools-boundary integration test (create_agent + configure_tier persist the latest
  model).
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type
  checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero
  failures.
- `mix format --check-formatted` — formatting gate.
- `mix credo --strict` — lint incl. the "@spec on every public function" gate.
- `mix dialyzer` — contract checking, no new warnings, no stale ignore filters.

## Notes
- **Why resolve at creation, not at command time.** The request is "when the
  orchestrator creates agents and selects their models." Resolving at the
  `create_agent`/`configure_tier` boundary persists the latest model on the worker/
  roster, so it is visible, priced, and spawned consistently. A future enhancement
  could *re-resolve* at `command_agent` time so long-lived workers pick up a newer
  latest on their next run — deliberately out of scope here to avoid surprising an
  operator who pinned a specific version expecting it to stick for that worker. If
  desired later, add a one-line `ModelResolver.latest/3` call where `command_agent/2`
  builds `opts.model`.
- **Claude alias vs concrete latest.** Mapping concrete Claude ids to the family
  *alias* (rather than to a hard-coded "latest concrete id") is intentional: it
  delegates "what is latest" to the `claude` CLI, needs zero config maintenance when a
  new family member ships, and stays consistent with the existing pricing
  canonicalization in `Harness.Claude` (`@model_aliases`). The displayed worker model
  becomes the alias (e.g. `sonnet`); the cost badge still prices it correctly because
  `Pricing.derive/3` canonicalizes the alias.
- **pi family-stem heuristic is deliberately conservative.** Cross-provider naming is
  inconsistent (`gpt-5` vs `gpt-5-mini`, `MiniMax-M2`/`M3`, `claude-opus-4-1`/`4-5`).
  The stem regex only strips a trailing version token, so when in doubt the resolver
  declines to upgrade rather than risk a wrong-family jump. The catalog it walks is
  already declared *latest-first* (see the repeated "latest first" comments in
  `config/config.exs`), which is the ordering the resolver depends on — keep that
  ordering invariant when editing the registry lists.
- No new dependencies; no migration; no schema change. Pure logic + two call sites +
  tests. The orchestrator MCP tool catalog/JSON schema is unchanged (resolution is
  internal to the existing `create_agent`/`configure_tier` tools).
- Runtime verification uses Tidewave `project_eval` per the project's preferred
  validation path (no ad-hoc IEx/curl).
```