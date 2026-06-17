# Feature: Orchestrator Cost Report + Context-Window Awareness + `/compact` Guidance

## Metadata
issue_number: `spec`
adw_id: `this`
issue_json: `out` (interactive request — no GitHub issue)

## Feature Description
Give the orchestrator self-awareness of its own spend and context-window pressure, and a
first-class way to relieve that pressure on its workers. Three tightly-coupled capabilities,
ported from the reference `orchestrator_3_stream` (`report_cost` tool + the PreCompact hook +
the "Context Window Management" prompt section):

1. **`report_cost` tool** — a read-only orchestrator tool reporting its session id, status,
   running USD cost, cumulative input/output/total tokens, and **context-window usage %**,
   with a warning when usage is high. (Reference: `agent_manager.py` `report_cost_tool`.)
2. **Context-window awareness** — the substrate `report_cost` needs: persist the orchestrator's
   cumulative token usage on its row (today only `total_cost_usd` is tracked), plus a
   per-harness/model **context-window size** lookup so "usage %" is meaningful across harnesses
   (the reference hardcoded 200k for Claude only).
3. **`/compact` guidance + tool** — the orchestrator can already dispatch `/compact` to a
   worker via `command_agent` (both Claude and pi honor it). We add (a) a thin `compact_agent`
   convenience tool and (b) a "Context management" block in the orchestrator system prompt
   telling the brain to watch `report_cost` and compact workers (or suggest compaction to the
   operator) as they approach their limit.

These three ship together because `report_cost` and `/compact` guidance both depend on the
same missing primitive — context-window usage tracking — so splitting them would duplicate
that groundwork.

## User Story
As the **orchestrator brain (and the operator watching it)**
I want to **see my own cost and context-window usage, and compact workers that are filling up**
So that **I can manage long multi-agent sessions without silently hitting context limits or
runaway spend, and proactively free up worker context before it degrades their output.**

## Problem Statement
The orchestrator tracks `total_cost_usd` and `session_id` on its row but exposes neither to
itself (no tool surfaces cost/usage; `get_config` only reports harness/provider/model config).
It does NOT track cumulative tokens at all, and there is no notion of a context-window size
anywhere in the platform, so the brain cannot reason about "how full am I / is this worker?"
There is also no guidance or ergonomic affordance for relieving context pressure, even though
`/compact` works when manually dispatched. The reference solves all three; we have none of it.

## Solution Statement
1. **Track tokens on the orchestrator row — two distinct semantics.** Add three plain-integer
   columns: cumulative **`input_tokens`/`output_tokens`** (lifetime throughput, for the cost
   report) AND **`context_tokens`** (the LATEST turn's `input+output`, OVERWRITTEN each
   `Event.Usage` — the context-window OCCUPANCY signal). One `@spec`'d
   `Orchestrators.add_usage/3` does both (accumulate the two counters, overwrite
   `context_tokens`), wired into `Orchestrator.Server` on each `Event.Usage` (parallel to the
   existing `add_cost/2` path). This mirrors the console's existing `context_tokens` semantics
   (`put_context(agent_id, input+output)` — latest turn, not cumulative).
   - **Why two semantics:** cumulative tokens answer "how much have I spent" (cost); the latest
     turn's tokens answer "how full is my context window right now" (compaction). A cumulative
     ratio is the WRONG compaction signal — it blows past 100% on any long resumed session even
     when the live context is fine. Occupancy must come from the latest turn.
2. **Add a context-window lookup.** A small `RepoBuilder.Orchestrator.ContextWindow` helper
   backed by `config :repo_builder, :context_windows` (a `%{default => integer, {harness,
   model} => integer}` map) with a sane default (200_000) and per-model overrides — harness-
   blind at the call site. `usage_fraction/3` is computed from `context_tokens` (occupancy),
   and is **NOT clamped**: a value >1.0 (>100%) is reported verbatim because exceeding the
   window is exactly the condition the brain/operator needs to see.
3. **Add the `report_cost` tool** to `ToolCatalog` (Claude MCP) AND the pi extension TS defs,
   dispatched via `Tools.call`, returning session id/status/cost/tokens/usage-% + a high-usage
   warning.
4. **Add the `compact_agent` tool** (thin sugar over `command_agent(name, "/compact")`) to both
   bindings + `Tools`, and a "Context management" block to `SystemPrompt.build/1` instructing
   the brain when/how to use `report_cost` and compaction.
5. Cover with context unit tests (usage accumulation), a `ContextWindow` test, `Tools` tests
   (report_cost math + warning threshold, compact_agent dispatch), and a `SystemPrompt` test
   for the new block.

## Relevant Files
Use these files to implement the feature:

### New Files
- `priv/repo/migrations/<timestamp>_add_token_usage_to_orchestrators.exs` — adds
  `input_tokens :bigint NOT NULL DEFAULT 0`, `output_tokens :bigint NOT NULL DEFAULT 0`
  (cumulative), and `context_tokens :bigint NOT NULL DEFAULT 0` (latest-turn occupancy).
  Generate with `mix ecto.gen.migration add_token_usage_to_orchestrators`.
- `lib/repo_builder/orchestrator/context_window.ex` — `RepoBuilder.Orchestrator.ContextWindow`:
  `@spec size(harness :: String.t(), model :: String.t() | nil) :: pos_integer()` reading the
  `:context_windows` config map (per-(harness,model) override → default), and
  `@spec usage_fraction(context_tokens :: non_neg_integer(), harness, model) :: float()` —
  `context_tokens / size`, UNCLAMPED (may exceed 1.0); guards size > 0 to avoid div-by-zero.
- `test/repo_builder/orchestrator/context_window_test.exs` — override lookup, default fallback,
  fraction math, the unclamped >1.0 case, and zero-tokens → 0.0 (no div-by-zero).
- `test/repo_builder/orchestrator/cost_report_test.exs` — `report_cost` token/cost/usage-%
  assembly + the high-usage warning threshold; `compact_agent` dispatches `/compact`.

### Existing Files
- `lib/repo_builder/orchestrator/orchestrator.ex` — add `input_tokens`/`output_tokens`/
  `context_tokens` to the schema, `@type t`, and the `cast/3` list (non-negative integers;
  `validate_number ≥ 0`).
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators`) — the ONLY `Repo` caller.
  Add `@spec add_usage(Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) :: {:ok,
  Orchestrator.t()} | {:error, :not_found}` that ACCUMULATES `input_tokens`/`output_tokens`
  (lifetime) AND OVERWRITES `context_tokens` with this call's `input+output` (latest-turn
  occupancy), in one read-modify-write (like `add_cost/2`); nil/0 args are no-op-safe. Plus a
  `@spec token_totals(Orchestrator.t()) :: %{input:.., output:.., total:.., context:..}`
  convenience for the tool/UI.
- `lib/repo_builder/orchestrator/server.ex` — in the `handle_info({:harness_event,
  %Event.Usage{}}, ...)` clause (which already calls `add_cost/2`), also call
  `Orchestrators.add_usage/3` with the event's `input_tokens`/`output_tokens`.
- `lib/repo_builder/harness/event.ex` — referenced only: `Event.Usage` already carries
  `input_tokens`/`output_tokens`/`cost_usd` (confirm; no change).
- `lib/repo_builder/orchestrator/tool_catalog.ex` — add `report_cost` (no args) and
  `compact_agent` (`name`) tool defs.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — add the same two tool defs (pi
  hardcodes its tool list; logic stays in Elixir `Tools`).
- `lib/repo_builder/orchestrator/tools.ex` — add dispatch clauses + `@spec`'d handlers:
  `report_cost` (read the orchestrator row → `ContextWindow` → assemble the report map) and
  `compact_agent` (resolve worker by name → dispatch `/compact` via the existing
  `command_agent` path). Reuse `result()`.
- `lib/repo_builder/orchestrator/system_prompt.ex` — add a `context_management_block/0`
  (guidance: call `report_cost` to check usage; `compact_agent`/`command_agent(name,
  "/compact")` a worker near its limit; suggest compaction to the operator at high usage) and
  reference it in `build/1`.
- `lib/repo_builder_web/components/console_components.ex` — OPTIONAL: surface the orchestrator's
  context-usage % in the header/cost pill (we already render per-agent context tokens). Keep
  minimal; the tool is the primary surface.
- `lib/repo_builder_web/live/console_live.ex` — OPTIONAL: if surfacing in the header, add the
  orchestrator usage assign (derive from the row on orchestrator selection). No new event needed.
- `config/config.exs` — add `config :repo_builder, :context_windows, %{default: 200_000}` with a
  couple of documented per-model overrides.
- `ai_docs/typed-elixir-standard.md` — the **(always)** typed-standard row.
- `BUILD_PROMPT.md` §8 (persistence/migrations, the float→Decimal cost boundary — tokens are
  plain ints), §4 (the canonical `Event.Usage`), §10 (dual tool binding).

## Implementation Plan
### Phase 1: Foundation
Persist orchestrator token usage (migration + schema + `add_usage/3` context fn) and wire its
accumulation into `Orchestrator.Server` on `Event.Usage`. Add the `ContextWindow` lookup. Lock
with context + ContextWindow unit tests. This is the substrate the tools need.

### Phase 2: Core Implementation
Add the `report_cost` and `compact_agent` tools to both bindings + `Tools`, and the context-
management guidance block in `SystemPrompt`. Cover with `Tools` + `SystemPrompt` tests.

### Phase 3: Integration
Verify the loop (usage accrues on the row across turns → `report_cost` reflects it with the
right usage-% per harness/model → high-usage warning fires → `compact_agent` dispatches
`/compact`). Optionally surface usage % in the console header. Lock with the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the token-usage columns (migration)
- Run `mix ecto.gen.migration add_token_usage_to_orchestrators`.
- In `change/0`: `alter table(:orchestrators) do add :input_tokens, :bigint, null: false,
  default: 0; add :output_tokens, :bigint, null: false, default: 0; add :context_tokens,
  :bigint, null: false, default: 0 end`. No backfill.

### 2. Extend the orchestrator schema + changeset
- In `orchestrator.ex`: add `input_tokens`/`output_tokens`/`context_tokens` as
  `non_neg_integer()` to `@type t`; add the three `field ..., :integer, default: 0`; add all
  three to `cast/3`; `validate_number(..., greater_than_or_equal_to: 0)` on each.

### 3. Add the `add_usage/3` + `token_totals/1` context functions
- In `RepoBuilder.Orchestrators`: `add_usage(id, input, output)` ACCUMULATES `input_tokens`/
  `output_tokens` AND OVERWRITES `context_tokens` with `input + output` (read-modify-write via
  the existing `update_fields/2`, matching the `add_cost/2` style), returning the tagged tuple;
  `nil`/0 args are no-op-safe (treat nil as 0). `token_totals/1` returns `%{input:.., output:..,
  total:.., context:..}`.

### 4. Write the context unit test
- Extend `test/repo_builder/orchestrators_provider_test.exs` (or a new file): `add_usage/3`
  accumulates across calls; default totals are 0; `{:error, :not_found}` for a bogus id;
  `token_totals/1` sums correctly.

### 5. Accumulate usage in the orchestrator server
- In `orchestrator/server.ex`, the `Event.Usage` handler already does `add_cost/2`; add
  `_ = Orchestrators.add_usage(state.orchestrator_id, event.input_tokens, event.output_tokens)`.

### 6. Add the context-window lookup
- Create `lib/repo_builder/orchestrator/context_window.ex`: `size/2` (per-(harness,model)
  override → `:default`), `usage_fraction/3` = `context_tokens / size`, **UNCLAMPED** (a >1.0
  value is returned verbatim — exceeding the window is the signal we want visible), guarding
  `size > 0`. Add `config :repo_builder, :context_windows, %{default: 200_000, ...}`.
- `test/repo_builder/orchestrator/context_window_test.exs`: override hit, default fallback,
  fraction math, and the explicit >1.0 (no-clamp) case + the zero-tokens (0.0) case.

### 7. Add the `report_cost` + `compact_agent` tools (both bindings)
- In `tool_catalog.ex`: add `report_cost` (no args; "Report this orchestrator's session id,
  status, cost, tokens, and context-window usage %") and `compact_agent` (`name`; "Compact a
  worker's context by dispatching /compact to it").
- In `pi_extension/orchestrator-tools.ts`: mirror both defs.
- In `tools.ex`: dispatch + `@spec`'d handlers — `report_cost` reads the row, reports cumulative
  `input_tokens`/`output_tokens`/total + USD cost + session/status, and computes context usage %
  from `context_tokens` via `ContextWindow.usage_fraction/3` (using the orchestrator's
  harness+model), returning a map incl. a `warning` when occupancy ≥ 0.8 (the report shows a
  >100% value plainly when over); `compact_agent` resolves the worker by name and dispatches
  `/compact` through the existing `command_agent` code path (reuse, don't duplicate).

### 8. Add the Tools unit tests
- `test/repo_builder/orchestrator/cost_report_test.exs`: seed cumulative tokens + a
  `context_tokens` + cost on an orchestrator (via `add_usage/3` + `add_cost/2`), assert
  `report_cost` returns session id/status/cost/cumulative tokens and the correct occupancy-%
  computed from `context_tokens` for its harness/model; assert the warning appears at ≥80% and
  is absent below; assert a `context_tokens` > window reports >100% (no clamp) with a warning;
  `compact_agent` on a known worker dispatches `/compact` (assert via the command path / a Fake
  worker), and an unknown worker returns a helpful `{:error, ...}`.

### 9. Add the context-management guidance to the system prompt
- In `system_prompt.ex`, add `context_management_block/0` (when/how to call `report_cost`,
  `compact_agent`/`command_agent(name, "/compact")`, and to suggest compaction to the operator
  at high usage) and reference it in `build/1`. Add/extend a SystemPrompt test asserting the
  block is present and mentions `report_cost` + compaction.

### 10. (Optional) Surface orchestrator context usage in the console header
- If included: add an `orchestrator_context_pct` assign (derived from the row's `context_tokens`
  + `ContextWindow`) on orchestrator selection and render it near the cost pill in
  `console_components.ex`. Add a LiveView assertion. Skip if time-boxed — the tool is primary.

### 11. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green. Confirm
  `mix ecto.rollback` then `mix ecto.migrate` round-trips the migration.

## Testing Strategy
### Unit Tests
- **Context (`Orchestrators`)**: `add_usage/3` accumulates input+output across calls; defaults
  are 0; `{:error, :not_found}` for unknown id; `token_totals/1` sums.
- **ContextWindow**: per-(harness,model) override wins; default fallback; `usage_fraction/3`
  math; UNCLAMPED >1.0 case; zero-tokens → 0.0 (no div-by-zero).
- **Tools**: `report_cost` assembles session/status/cost/cumulative tokens + occupancy-% (from
  `context_tokens`) and the ≥80% warning boundary (and no warning below; >100% reported plainly);
  `compact_agent` dispatches `/compact` to a known worker and errors helpfully on unknown.
- **Usage semantics**: `add_usage/3` accumulates input/output across calls but OVERWRITES
  `context_tokens` with the latest `input+output` (assert a 2nd call's `context_tokens` reflects
  only the 2nd call, while cumulative counters sum both).
- **SystemPrompt**: the context-management block renders and references `report_cost` +
  compaction.

### Edge Cases
- Zero tokens / fresh orchestrator → occupancy 0%, no warning, no division-by-zero.
- `context_tokens` ≥ window (a big turn exceeds the model's window) → occupancy reported >100%
  UNCLAMPED, warning present (clamping would hide that you're over — the whole point of the
  signal).
- **Cumulative vs. occupancy** must not be conflated: cumulative `input_tokens`/`output_tokens`
  grow forever and feed the cost report; occupancy comes ONLY from the latest-turn
  `context_tokens`. A long resumed session has huge cumulative tokens but its occupancy tracks
  the live window — assert this distinction so the compaction signal stays correct.
- Unknown/absent model → `ContextWindow` falls back to `:default` size (never crashes).
- `compact_agent` on a non-existent or non-running worker → `{:error, ...}` (no crash); on a
  worker with no live session, `/compact` is dispatched on next command (document behavior).
- `Event.Usage` with nil/absent token fields → `add_usage/3` treats as 0 (no-op-safe).
- Cost stays on the existing float→Decimal boundary (§8); tokens are plain integers — do NOT
  route tokens through the Decimal path.

## Acceptance Criteria
- The orchestrator row accumulates cumulative `input_tokens`/`output_tokens` AND overwrites
  `context_tokens` (latest-turn occupancy) across turns via `add_usage/3`, wired from
  `Event.Usage` in `Orchestrator.Server`.
- A `ContextWindow` lookup returns a per-(harness,model) size with a configurable default, and
  `usage_fraction/3` is unclamped (reports >100% when over).
- `report_cost` (Claude MCP + pi extension) returns session id, status, USD cost, cumulative
  input/output/total tokens, and context-window occupancy % (from `context_tokens`), with a
  high-usage warning at ≥80%.
- `compact_agent` dispatches `/compact` to a named worker (sugar over `command_agent`), and the
  system prompt's context-management block guides the brain to use both.
- No regression to existing cost tracking; tokens never touch the Decimal cost path.
- All five green-gate commands pass, plus the new context, ContextWindow, Tools, and
  SystemPrompt tests.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the token-usage migration cleanly (then confirm `mix ecto.rollback`
  + `mix ecto.migrate` round-trips).
- `mix test test/repo_builder/orchestrator/context_window_test.exs` — the lookup.
- `mix test test/repo_builder/orchestrator/cost_report_test.exs` — report_cost + compact_agent.
- `mix test test/repo_builder/orchestrators_provider_test.exs` — usage accumulation.
- `mix compile --warnings-as-errors` — clean compile under the gradual type checker.
- `mix test --warnings-as-errors` — full suite green.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean (every new public function has an `@spec`).
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

Optional runtime validation via **Tidewave** (`http://localhost:4000/tidewave/mcp`):
- `project_eval`: `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |> (fn o -> RepoBuilder.Orchestrators.add_usage(o.id, 1000, 500) end).()` then `RepoBuilder.Orchestrator.Tools.call("report_cost", o.id, %{})` to eyeball the report.
- `execute_sql_query`: `select input_tokens, output_tokens, total_cost_usd from orchestrators;`.

## Notes
- **No new dependencies.** Uses existing Ecto, the canonical `Event.Usage`, and the typed
  contract. The only `config` change is the `:context_windows` map.
- **Why the three ship together:** `report_cost` and `/compact` guidance both need
  context-window usage tracking; that shared primitive (token columns + `ContextWindow`) is
  built once here. Splitting would duplicate it.
- **`/compact` is mostly guidance + sugar:** dispatching `/compact` already works via
  `command_agent`; `compact_agent` is a thin, testable convenience and a future hook point for
  PreCompact-style observability (we have no harness SDK hooks — we normalize CLI stream events
  — so the reference's "reset token counters on PreCompact" is replaced by our own
  `add_usage`-based tracking).
- **Context-window source of truth:** a config map keeps it harness-blind and operator-tunable;
  pi's live model catalog could later supply real per-model window sizes (Future Consideration).
- **Companion spec:** pairs with `issue-spec-adw-this-sdlc_planner-subagent-templates.md`. The
  two are independent; either can land first. Both add tools, so both must touch `ToolCatalog`
  AND the pi extension (§10 dual binding).
```
