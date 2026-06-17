# Feature: Orchestrator self-configuration tools (read & update runtime config)

## Metadata
issue_number: `the`
adw_id: `orchestrator`
issue_json: `agent`

## Feature Description
Give the orchestrator agent first-class tools to **read and update its own runtime
configuration** so it can self-unblock instead of dead-ending on the operator.
Today the orchestrator can create, command, inspect, update, and delete worker
agents — but the one thing that actually gates whether *any* of that works (which
harness/provider/model a worker tier resolves to, and the orchestrator's own
provider/model) is configurable **only** by the human operator through the
console. When no tier has a model assigned, the orchestrator hits a wall: it
correctly diagnoses "no usable worker tier is configured" and then has to ask the
operator to go fix config by hand.

This feature adds three harness-blind tools to `RepoBuilder.Orchestrator.Tools`,
advertised through the single `ToolCatalog` source of truth (so they appear
identically over Claude's MCP and the pi extension):

1. **`get_config`** — read the orchestrator's current `{harness, provider, model}`,
   the full worker-tier roster (`fast`/`main`/`heavy`/`leader` → harness/provider/
   model, with "unassigned" surfaced explicitly), the registered harnesses, and the
   **available models** per harness/provider (live pi catalog + static registry).
   This is the "what can I configure and what's currently broken" read.
2. **`configure_tier`** — assign `{harness, provider, model}` to a worker tier
   (`fast`/`main`/`heavy`/`leader`). This is the direct unblock for the pasted
   conversation: the orchestrator assigns a model to (say) `fast`, then spawns by
   `category` as designed.
3. **`set_orchestrator_config`** — set the orchestrator's *own* provider and/or
   model (and optionally switch its harness), for the manual-fallback path where
   the orchestrator runs a worker on its own harness.

Every tool is pure delegation to the existing `RepoBuilder.Orchestrators` context
(`set_agent_model/3`, `set_provider/2`, `set_model/2`, `set_harness/2`,
`agent_models/1`, `recent_models/2`) plus read-only `Harness.Registry` and
`Harness.Pi.Models` lookups. **No new schema, no new migration, no new `Repo`
caller** — the orchestrator's "configuration" is already DB-backed durable data
(orchestrator row + `metadata["agent_models"]` roster); these tools just expose
the existing write seam to the agent.

## User Story
As the **operator driving the orchestrator agent**
I want **the orchestrator to read and update its own tier/provider/model configuration through tools**
So that **when a tier is unassigned or its own model is unset, it can configure itself and complete the task instead of stalling and handing the problem back to me**.

## Problem Statement
The orchestrator's autonomy is capped by a configuration seam it cannot reach. In
the pasted run:
- All four tiers (`fast`/`main`/`heavy`/`leader`) were unassigned, so
  `create_agent` with `category` is impossible (`resolve_category/2` returns
  `"no model selected for category …"`).
- The manual fallback (a `pi` worker with an explicit `model`) errored on session
  start (provider/credential config the agent also can't touch).
- The orchestrator has **no tool** to assign a tier model, set a provider, or even
  *read back* which tiers are unassigned in a structured way — it can only see the
  prose in its own system prompt.

Result: a trivial "create test1.md" request ends in a configuration write the
agent is structurally unable to perform. The whole point of the platform — a
meta-agent that coordinates work — is defeated by a config gap it can describe but
not close.

## Solution Statement
Add the missing config **read** and **write** surface to the harness-blind tool
layer, reusing the existing typed `Orchestrators` context functions verbatim:

- `get_config` composes a structured snapshot from `Orchestrators.fetch/1`,
  `Orchestrators.agent_models/1`, `Orchestrators.agent_categories/0`,
  `Registry.known/0`, and the available-models catalog
  (`Registry.orchestrator_models/2` + `Harness.Pi.Models.all/0`).
- `configure_tier` validates the `category` and a non-blank `model`, then calls
  `Orchestrators.set_agent_model/3` (which already validates the category).
- `set_orchestrator_config` routes optional `harness`/`provider`/`model` to
  `Orchestrators.set_harness/2`, `set_provider/2`, and `set_model/2` in a fixed,
  safe order (harness first, since it resets provider/model defaults; then
  provider, which resets model; then model last), returning the final row.

The three tools are registered once in `ToolCatalog` (consumed by the MCP
controller, the pi extension manifest, and the system prompt), mirrored in the pi
extension TypeScript, and the system prompt gains an operating rule instructing the
agent to **self-configure a tier when it finds one unassigned** rather than
reporting a blocker. Because the harness identity stays an open string validated
against the registry, nothing in the canonical `Event` types, the `Agent`/
`Orchestrator` schemas, or the runtime changes.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/tools.ex` — **primary change.** Harness-blind tool
  logic; add `get_config`, `configure_tier`, `set_orchestrator_config` handlers and
  their `dispatch/3` clauses. Reuse existing helpers (`fetch_string/2`,
  `blank_to_nil/1`, `changeset_reason/1`, `normalize_reason/1`). Every new private
  fn carries an `@spec` per §3.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — **single source of truth** for
  tool name/description/JSON-Schema. Add the three new `tool_def()`s here; the MCP
  `tools/list`, the pi manifest, and the system prompt all read from this.
- `lib/repo_builder/orchestrators.ex` — the typed context (only `Repo` caller for
  `orchestrators`). Already exposes everything needed: `fetch/1`,
  `set_agent_model/3`, `set_provider/2`, `set_model/2`, `set_harness/2`,
  `agent_models/1`, `agent_categories/0`, `recent_models/2`. **Read to reuse; no
  change expected** unless a small read helper is convenient (see Notes).
- `lib/repo_builder/orchestrator/orchestrator.ex` — orchestrator schema (open
  `harness`/`provider` strings, closed `status` enum). Read for field shapes used
  by `get_config`'s response.
- `lib/repo_builder/orchestrator/system_prompt.ex` — inject an operating rule so the
  agent actually uses the new tools to self-unblock; tools/categories blocks already
  render from `ToolCatalog`/roster, so the new tools surface automatically.
- `lib/repo_builder/harness/registry.ex` — read-only source for `known/0`,
  `orchestrator_models/2`, `orchestrator_defaults/2` used by `get_config`.
- `lib/repo_builder/harness/pi/models.ex` — live `%{provider => [model]}` catalog
  (`all/0`) folded into `get_config`'s available-models map (fail-soft, disabled in
  test env via `:pi_models_discovery`).
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — no code change
  (it maps over `ToolCatalog.tools()` already), but its test asserts the advertised
  tool set and must be updated.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — mirror the three new tool
  definitions so the pi binding advertises them (logic stays in Elixir; this is a
  pure binding).
- `test/repo_builder/orchestrator/tools_test.exs` — add unit coverage for the three
  tools (happy paths + error branches) using the keyless `fake` harness.
- `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs` — update
  the advertised-tools assertion to include the new names.
- `test/repo_builder_web/live/test_orchestrator_agent_test.exs` — if it asserts the
  catalog/parity or tool count, update it (verify during research).
- `BUILD_PROMPT.md` — §3 (typed style), §8 (contexts are the only `Repo` callers),
  §10 (open harness identity / registry seam). Authoritative constraints.
- `.claude/commands/conditional_docs.md` routes: this task touches orchestrator
  tooling + persistence-context reuse, so the **(always)** row
  (`ai_docs/typed-elixir-standard.md`) and `BUILD_PROMPT.md` §8/§10 apply.

### New Files
- *(none required.)* All changes are additive edits to existing modules and tests.
  No new schema/migration/context/LiveView is introduced.

## Implementation Plan
### Phase 1: Foundation
Confirm the reuse surface and lock the tool contracts before writing handlers.
Read `Orchestrators` to confirm the exact signatures and return shapes
(`set_agent_model/3` returns `{:ok, t} | {:error, :not_found | :invalid_category}`;
`set_provider/2`/`set_model/2`/`set_harness/2` return `{:ok, t} | {:error,
:not_found}`). Decide the JSON-Schema for each tool in `ToolCatalog` (names,
required fields, enums for `category`). No behavior change yet.

### Phase 2: Core Implementation
Implement the three handlers in `Tools`, add their `dispatch/3` clauses, and add
the matching `ToolCatalog` definitions. Keep every handler in the existing
`{:ok, map()} | {:error, reason()}` contract, never raising (the outer `call/3`
rescue/catch already backstops). Add `@spec`s on all new private functions. Mirror
the catalog entries into the pi extension TypeScript. Extend the system prompt with
the self-configuration operating rule.

### Phase 3: Integration
The MCP controller and pi extension pick up the new tools automatically from the
catalog (the controller already maps `ToolCatalog.tools()`; the system prompt
already renders `tools_block/0`). Update the controller test's advertised-tool
assertion and any parity/count test. Add `Tools` unit tests. Run the full green
gate to prove zero regressions, and validate live via Tidewave `project_eval`
(call `Tools.call("get_config", id, %{})` and `Tools.call("configure_tier", …)`
against the live app).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Research and confirm reuse signatures
- Read `lib/repo_builder/orchestrators.ex` and confirm signatures/return tuples for
  `fetch/1`, `set_agent_model/3`, `set_provider/2`, `set_model/2`, `set_harness/2`,
  `agent_models/1`, `agent_categories/0`, `recent_models/2`.
- Grep the test suite for places that assert the orchestrator tool **set/count** or
  catalog/pi-extension **parity** (`ToolCatalog.names()`,
  `orchestrator_mcp_controller_test`, `test_orchestrator_agent_test`) so every such
  assertion is updated in step 8/9. Command:
  `grep -rn "ToolCatalog\|tools/list\|configure_tier\|get_config\|set_orchestrator_config" lib test priv`.

### 2. Add the three tool definitions to `ToolCatalog`
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, append three `tool_def()`
  entries to `tools/0` (keep the existing stable order; add at the end):
  - **`get_config`** — description: "Read this orchestrator's current configuration:
    its own harness/provider/model, the worker-tier roster (fast/main/heavy/leader
    with each tier's harness/provider/model or 'unassigned'), the registered
    harnesses, and the available models per harness/provider. Use this first when a
    spawn fails with 'no model selected' to see what needs configuring."
    `input_schema`: `{"type":"object","properties":{},"required":[]}`.
  - **`configure_tier`** — description: "Assign a harness/provider/model to a worker
    tier (fast/main/heavy/leader) so `create_agent` with that `category` can spawn.
    `model` is required; `harness` defaults to the orchestrator's harness; `provider`
    is optional (open identity). Use this to self-unblock when a tier is
    unassigned." `input_schema`: required `["category","model"]`, properties
    `category` (enum `["fast","main","heavy","leader"]`), `harness`, `provider`,
    `model`.
  - **`set_orchestrator_config`** — description: "Update this orchestrator's own
    configuration. Provide any of `harness` (validated against the registry;
    switching resets provider/model to that harness's defaults), `provider` (resets
    model), and `model`. At least one is required." `input_schema`: required `[]`
    but enforced in the handler that ≥1 field is present; properties `harness`,
    `provider`, `model`.
- `mix compile --warnings-as-errors` to confirm the pure-data change is clean.

### 3. Implement `get_config` in `Tools`
- Add `defp dispatch("get_config", orchestrator_id, _args), do: get_config(orchestrator_id)`.
- Implement `@spec get_config(Ecto.UUID.t()) :: result()`:
  - `with {:ok, orch} <- Orchestrators.fetch(orchestrator_id)` (map `{:error,
    :not_found}` → `{:error, :orchestrator_not_found}` to match `resolve_harness/2`).
  - Build the response map:
    - `"orchestrator" => %{"harness" => orch.harness, "provider" => orch.provider,
      "model" => orch.model}`.
    - `"tiers" =>` map over `Orchestrators.agent_categories/0`, reading
      `Orchestrators.agent_models(orch)`; for each category emit `%{"harness" => …,
      "provider" => …, "model" => …, "assigned" => is_binary(model) and model != ""}`.
    - `"harnesses" => Registry.known()`.
    - `"available_models" =>` a `%{harness => %{provider => [model]}}`-ish view:
      for the orchestrator harness, merge `Harness.Pi.Models.all/0` (pi live catalog)
      with `Registry.orchestrator_models/2` per known provider; keep it small and
      fail-soft (empty maps are fine — pi discovery is disabled in test env).
  - Return `{:ok, response}`.
- Add an `@spec`'d private helper `tier_view/2` (category, roster) → map.

### 4. Implement `configure_tier` in `Tools`
- Add `defp dispatch("configure_tier", orchestrator_id, args), do: configure_tier(orchestrator_id, args)`.
- Implement `@spec configure_tier(Ecto.UUID.t(), map()) :: result()`:
  - `with {:ok, category} <- fetch_string(args, "category"),
         {:ok, model} <- fetch_string(args, "model")` (model required — refuses to
    assign a blank, mirroring the "no silent un-runnable tier" invariant).
  - Resolve harness: `blank_to_nil(args["harness"])` or fall through to the
    orchestrator's harness via the existing `resolve_harness/2`.
  - Call `Orchestrators.set_agent_model(orchestrator_id, category, %{"harness" =>
    harness, "provider" => blank_to_nil(args["provider"]), "model" => model})`.
  - On `{:ok, orch}` → `{:ok, %{"status" => "configured", "category" => category,
    "harness" => harness, "provider" => …, "model" => model}}`.
  - On `{:error, :invalid_category}` → `{:error, "invalid category: #{category}"}`.
  - On `{:error, :not_found}` → `{:error, :orchestrator_not_found}`.

### 5. Implement `set_orchestrator_config` in `Tools`
- Add `defp dispatch("set_orchestrator_config", orchestrator_id, args), do: set_orchestrator_config(orchestrator_id, args)`.
- Implement `@spec set_orchestrator_config(Ecto.UUID.t(), map()) :: result()`:
  - Extract `harness`/`provider`/`model` via `blank_to_nil/1`; if all three are nil,
    return `{:error, "no config fields provided"}`.
  - Apply in fixed order, short-circuiting on the first error (each step returns
    `{:ok, t} | {:error, :not_found}`):
    1. if `harness` present → `Orchestrators.set_harness/2` (validated vs registry;
       a bad harness surfaces `{:error, :not_found}` from `update_record/2` — map to
       a clear `"invalid or unknown harness"` reason by checking
       `Registry.known/0` membership first and returning `{:error, "not a
       registered harness: #{harness}"}` before the call).
    2. if `provider` present → `Orchestrators.set_provider/2`.
    3. if `model` present → `Orchestrators.set_model/2`.
  - Re-`fetch/1` the final row and return `{:ok, %{"harness" => …, "provider" => …,
    "model" => …}}`.
  - Implement this as a small `@spec`'d reducer/`with` chain; keep each branch typed
    `{:ok, Orchestrator.t()} | {:error, reason()}`.

### 6. Extend the system prompt with a self-configuration rule
- In `lib/repo_builder/orchestrator/system_prompt.ex`, add operating rules after the
  existing category rule, e.g.:
  - "If a tier shows `(unassigned — cannot spawn here)` or a spawn fails with 'no
    model selected', call `get_config` to inspect available harnesses/models, then
    `configure_tier` to assign one — do NOT stop and ask the operator unless no
    model is available at all."
  - "Use `set_orchestrator_config` to change your own provider/model when needed."
- The `tools_block/0` already renders the new tools from `ToolCatalog`; no other
  prompt wiring needed.

### 7. Mirror the new tools in the pi extension
- In `priv/orchestrator/pi_extension/orchestrator-tools.ts`, add three entries to the
  `tools` array matching the catalog (name, description, `parameters` JSON-Schema).
  The default-export loop already registers every entry and forwards to the Elixir
  endpoint, so no handler logic is needed.

### 8. Add unit tests for the three tools
- In `test/repo_builder/orchestrator/tools_test.exs`, add `describe` blocks:
  - **`get_config`**: returns `{:ok, cfg}` with `cfg["orchestrator"]`,
    `cfg["tiers"]` (a `heavy` tier shows `"assigned" => false` before assignment,
    `true` after `Orchestrators.set_agent_model/3`), and `cfg["harnesses"]`
    containing `"fake"`.
  - **`configure_tier`**: assigning `%{"category" => "fast", "model" => "m",
    "harness" => "fake", "provider" => "minimax"}` returns `{:ok, %{"status" =>
    "configured"}}`, and a subsequent `create_agent` with `%{"category" => "fast"}`
    now succeeds (end-to-end unblock — mirrors the pasted conversation). Missing
    `model` → `{:error, _}`. Bad category → `{:error, _}`.
  - **`set_orchestrator_config`**: setting `%{"model" => "x"}` then `fetch/1` shows
    the model; empty args → `{:error, "no config fields provided"}`; an unregistered
    `harness` → `{:error, _}` (and the orchestrator row is unchanged).
- Use the existing `orchestrator("fake")` helper and `uniq/0`.

### 9. Update controller/parity tests
- In `test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs`, update
  the `tools/list` assertion to include `"get_config"`, `"configure_tier"`,
  `"set_orchestrator_config"` (assert membership, not an exact-length equality, so
  future tools don't break it — but if it currently asserts a count, bump it).
- If `test/repo_builder_web/live/test_orchestrator_agent_test.exs` or any test
  asserts catalog↔pi-extension parity or a tool count, update it (from the step-1
  grep).

### 10. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are
  green. Then validate live behavior via Tidewave `project_eval` (see that section).

## Testing Strategy
### Unit Tests
- `get_config` returns a well-formed snapshot; tier `assigned` flag flips correctly
  after `configure_tier`; `harnesses` reflects the registry.
- `configure_tier` writes through `Orchestrators.set_agent_model/3`; the round-trip
  enables `create_agent` by `category` (the core acceptance: agent self-unblocks).
- `set_orchestrator_config` applies harness/provider/model in the safe order and
  rejects empty input and unregistered harnesses.
- Error normalization: every failure is an atom or string reason (never a raw
  changeset/tuple leaking out), consistent with the existing `reason()` contract and
  the MCP `isError: true` envelope.
- Each tool emits a `system_logs` row via the existing `log_invocation/4` wrapper
  (assert at least the happy-path "ok" log for one tool).

### Edge Cases
- `configure_tier` with a blank/missing `model` → rejected (no silent un-runnable
  tier).
- `configure_tier` with an invalid `category` (not in fast/main/heavy/leader) →
  `{:error, :invalid_category}` surfaced as a clear string.
- `get_config` when pi model discovery is disabled (test env): `available_models`
  is present but may be empty — must not raise or block (fail-soft `Pi.Models.all/0`).
- `set_orchestrator_config` with only `provider` set (no model) — model is reset to
  nil by `set_provider/2`; assert the returned `model` is nil (the operator/agent
  then picks one).
- `set_orchestrator_config` with an unknown `orchestrator_id` → `{:error,
  :orchestrator_not_found}` (no crash, MCP returns `isError: true`).
- Unknown tool name still returns `{:error, :unknown_tool}` (regression guard on the
  catch-all `dispatch/3`).

## Acceptance Criteria
- The orchestrator exposes `get_config`, `configure_tier`, and
  `set_orchestrator_config` over BOTH bindings (MCP `tools/list` and the pi
  extension manifest), advertised from the single `ToolCatalog`.
- From a cold state with all tiers unassigned, the orchestrator can: call
  `get_config` (see every tier `assigned: false`), call `configure_tier` to assign
  a model to a tier, then `create_agent` with that `category` succeeds — i.e. the
  exact pasted-conversation blocker is resolvable by the agent itself with no
  operator console action.
- `set_orchestrator_config` updates the orchestrator's own harness/provider/model
  through the existing `Orchestrators` context and persists across a re-`fetch/1`.
- No new schema, migration, context, or direct `Repo` access is introduced; all DB
  writes go through `RepoBuilder.Orchestrators` (§8 honored).
- The harness identity stays an open registry-validated string; `Event`, `Agent`,
  `Orchestrator` types and the runtime are unchanged (§10 honored).
- The system prompt instructs the agent to self-configure a tier when one is
  unassigned rather than reporting a blocker.
- The full green gate passes with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker
  and `warnings_as_errors` pass.
- `mix test test/repo_builder/orchestrator/tools_test.exs --warnings-as-errors` —
  the new orchestrator tool unit tests pass.
- `mix test test/repo_builder_web/controllers/orchestrator_mcp_controller_test.exs --warnings-as-errors`
  — the MCP `tools/list` advertises the new tools.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures (no regressions
  to the existing 146-test gate).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an
  `@spec`" convention.
- `mix dialyzer` — `@spec`/contract checking clean, no new warnings, no stale ignore
  filters.
- **Live (Tidewave `project_eval`)** — against the running app
  (`http://localhost:4000/tidewave/mcp`), evaluate:
  ```elixir
  {:ok, o} = RepoBuilder.Orchestrators.get_or_create_default()
  RepoBuilder.Orchestrator.Tools.call("get_config", o.id, %{})
  RepoBuilder.Orchestrator.Tools.call("configure_tier", o.id,
    %{"category" => "fast", "model" => "claude-sonnet-4-6", "harness" => "claude"})
  RepoBuilder.Orchestrator.Tools.call("create_agent", o.id,
    %{"name" => "probe-#{System.unique_integer([:positive])}", "category" => "fast"})
  ```
  Assert: `get_config` returns the tier roster with `assigned` flags; `configure_tier`
  returns `{:ok, %{"status" => "configured"}}`; the subsequent `create_agent` by
  `category` returns `{:ok, _}` (the self-unblock works end-to-end).
- **(optional)** `pg.sh start` first if Postgres isn't running this session.

## Notes
- **Scope decision — "configuration files" → durable runtime config.** The user's
  phrasing is "update configuration files." In this platform the orchestrator's
  configuration is **DB-backed durable data** (the `orchestrators` row + its
  `metadata["agent_models"]` tier roster), NOT flat files. The harness *registry*
  lives in `config/config.exs`, which is **compile-time** and must not be mutated at
  runtime (it would desync the BEAM's loaded config and isn't persistable). So this
  feature gives the agent tools over exactly the config that was blocking it — the
  tier roster and its own provider/model — via the existing typed context, which is
  the safe, in-architecture equivalent of "edit the config." If genuine file-editing
  for *worker* sandboxes is wanted later, that belongs to worker tooling (a worker
  with filesystem access), not the orchestrator's meta-config surface — call it out
  as a follow-up rather than widening this feature.
- **Why not just expose `set_provider`/`set_model` as raw tools?** Bundling them
  behind `set_orchestrator_config` with a fixed apply order avoids the agent setting
  a model and then wiping it by switching harness/provider in the wrong sequence
  (each setter intentionally resets downstream fields). `get_config` gives the agent
  the read it needs to make a correct single call.
- **No new dependency** is required; everything reuses `Orchestrators`, `Registry`,
  and `Pi.Models`.
- **Catalog is the single source of truth.** Add tool defs ONLY in `ToolCatalog`;
  the MCP controller, system prompt, and (by mirror) the pi extension all flow from
  it. The pi `.ts` mirror is a binding, not logic — keep its `parameters` in lockstep
  with the catalog `input_schema` (the step-1 grep should confirm whether a parity
  test enforces this; if so, it will catch drift).
- **Pi live catalog is fail-soft and disabled in test** (`:pi_models_discovery`),
  so `get_config`'s `available_models` may be empty under test — assert presence of
  the key, not specific models.
- Consider a tiny optional read helper on `Orchestrators` (e.g.
  `roster_snapshot/1`) if `get_config` gets unwieldy, but prefer composing existing
  public functions to keep the context surface minimal.
```
