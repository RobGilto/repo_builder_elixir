# Feature: Orchestrator log-lookup tools (fetch agent_logs by `log-<n>` — single, range, or array)

## Metadata
issue_number: `needs`
adw_id: `to`
issue_json: `{"title":"Orchestrator needs log tools to find logs easily","body":"Orchestrater needs to have log tools to find logs easily. See example log-8219 to log-8228 and build orch tooling so they can call and get critical log information from single, to ranged, to an array list."}`

## Feature Description
Every persisted canonical event (`agent_logs`) carries a durable, human-readable, best-effort-chronological number stamped by an owned DB sequence and surfaced everywhere in the console as the `log-<n>` label (`RepoBuilder.Logs.log_label/1`, e.g. `log-8219`). Operators and workers reference these numbers constantly ("see log-8219 to log-8228"), but the **orchestrator agent has no tool to fetch a log by its number**. Today the orchestrator can only read events indirectly: `check_agent_status` tails a *worker's* recent events (by worker name, not by log number) and `read_system_logs` reads the *separate* `system_logs` table. There is no path from a concrete `log-<n>` reference to that row's critical content.

This feature adds a single new orchestrator tool — **`get_logs`** — that resolves a `log-<n>` reference in three shapes:

1. **Single** — `log-8219` (or just `8219`).
2. **Range** — `log-8219..log-8228` (inclusive), the "log-8219 to log-8228" case.
3. **Array list** — `[8219, 8225, 8228]` (an explicit set of numbers).

For each resolved log it returns the **critical information**: the `log-<n>` label, owner (worker `agent_id` or `orchestrator_id`), `session_id`, `event_type`, `harness`/`provider`/`model`, an excerpt of the event's text/payload, token usage + USD cost, and timestamp — drawn straight from the existing canonical store. The tool is harness-blind (one Elixir implementation reached identically by the Claude MCP binding, the pi extension, and the in-process Fake loop), never raises, and is bounded so a wide range can never overflow the tool result.

## User Story
As the orchestrator agent (and the operator driving it)
I want to fetch the critical content of specific persisted logs by their `log-<n>` number — one, a `log-A..log-B` range, or an explicit list
So that when I (or a worker, or the operator) reference `log-8219` … `log-8228` I can immediately pull up exactly what those events were, without re-tailing a whole worker's history or dropping to SQL.

## Problem Statement
- The console stamps and displays a durable `log-<n>` on every event (`Logs.log_label/1`), and people reference those numbers, but **no orchestrator tool resolves a number back to its row**.
- `check_agent_status` reads events **by worker name** with a recency tail — you cannot ask "what is log-8219?" and you cannot span a range like `log-8219..log-8228` that may cross workers/orchestrator turns.
- `read_system_logs` targets the **`system_logs`** table (orchestrator tool-invocation audit lines), a different table from `agent_logs`; it has no `log_no` lookup at all.
- There is **no `RepoBuilder.Logs` read keyed on `log_no`** (single, range, or set) — `agent_logs` is only ever read by `agent_id`, `orchestrator_id`, or the manager's filter/offset pagination.
- The result of any orchestrator tool must stay small (the platform has a known large-tool-result stdout-overflow concern — `@worker_text_cap`, issue-log-2389), so a naive "give me logs 1..100000" must be **bounded**, not unbounded.

## Solution Statement
1. Extend the **`RepoBuilder.Logs`** context (the sole `Repo` caller for `agent_logs`) with one new `@spec`'d, bounded reader: **`logs_by_numbers/2`** — given a concrete, deduped list of `log_no` integers (and an optional `:include_hidden?`), return the matching `AgentLog.t()` rows ordered by `log_no`. Keep all `Repo`/`Ecto.Query` inside the context.
2. Add a single new orchestrator tool **`get_logs`** to `RepoBuilder.Orchestrator.Tools` that:
   - parses the request into a concrete number set from any of `log` (single), `from`+`to` (inclusive range), or `numbers` (array), accepting both bare integers and `"log-<n>"` strings;
   - **clamps the requested count** to a hard cap (`@max_log_lookup`, e.g. 100 numbers) and the expanded range so an enormous span can't overflow;
   - calls `Logs.logs_by_numbers/2` and maps each row through a compact `log_detail/1` summary (label, owner, type, text excerpt capped at `@worker_text_cap`, usage/cost, timestamp);
   - returns `{:ok, %{"logs" => [...], "count" => n, "requested" => r, "missing" => [...]}}` (numbers with no row are reported, never an error), and **never raises** (`call/3`'s rescue/catch contract).
3. Advertise the tool identically through both bindings: add its definition to **`RepoBuilder.Orchestrator.ToolCatalog`** (consumed by the MCP `tools/list` response and the system prompt) and mirror it in the **pi extension** manifest (`priv/orchestrator/pi_extension/orchestrator-tools.ts`).
4. Cover everything with context unit tests, orchestrator-tool unit tests (each input shape + bounds + missing + hidden), and an end-to-end MCP-controller assertion that the tool is advertised and callable.

**No new dependency and no migration** are required: `log_no` (DB sequence, `read_after_writes: true`), `hidden`, `payload`, `usage`, and the owner columns already exist on `agent_logs`; this feature only adds read paths and a tool binding.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — §3 typed style guide (every public fn `@spec`'d; precise types over `map()`/`any()`; `{:ok, t()} | {:error, reason()}`), §4 harness event contract + redaction, §8 persistence (web/OTP never touch `Repo`; contexts only), §10 extensibility (harness-blind tool logic). Authoritative architecture.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (the **(always)** conditional-docs row, plus the "Ecto schemas/contexts" row): `@spec` on every new public function, a `@type`/`@typep` for the parsed number set, precise return types.
- `lib/repo_builder/logs.ex` — the **only** `Repo` caller for `agent_logs`. Add `logs_by_numbers/2` here. Mirror the existing `list_recent/2`, `list_recent_global/2`, `filter_hidden/2`, and the `query_agent_logs/3` clamping pattern. Reuse `log_label/1` (already defined) and `context_size/1` for the summary.
- `lib/repo_builder/logs/agent_log.ex` — the `agent_logs` schema. Fields used by the summary: `log_no` (int, DB sequence), `agent_id`/`orchestrator_id` (owner), `session_id`, `event_type` (Ecto.Enum), `harness`/`provider`/`model`, `payload` (scrubbed map), `usage` (embedded `Usage`), `hidden`, `inserted_at`. **No change needed.**
- `lib/repo_builder/logs/usage.ex` — embedded `Usage` value object (`input_tokens`/`output_tokens`/`cache_read`/`cache_creation`/`cost_usd` Decimal) for the per-log token/cost fields in the summary.
- `lib/repo_builder/orchestrator/tools.ex` — `call/3` (single never-raising entry point + `log_invocation/3`), the `dispatch/3` table (add a `"get_logs"` clause), and the existing read tools to mirror: `read_system_logs/1` (arg parsing, `positive_int`/`non_neg_int`, summary mapping), `check_agent_status/2` + `log_summary/1`/`log_summary_text/1` (the text-excerpt + truncation pattern), `blank_to_nil/1`, `to_iso/1`, `decimal_to_string/1`. Add the new handler, `log_detail/1`, the number-parsing helpers, and the `@max_log_lookup` cap here.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — the single source of truth for tool definitions advertised over MCP and in the system prompt. Add the `get_logs` `tool_def` (name/description/`input_schema`). `names/0` then includes it automatically.
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — the MCP JSON-RPC endpoint; `tools/list` maps `ToolCatalog.tools()` and `tools/call` routes to `Tools.call/3`. No code change (it's catalog-driven), but it's the surface the integration assertion exercises.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — the pi binding's mirrored `tools` array (the Elixir endpoint is the validation source of truth; this advertises the tool to pi). Add a matching `get_logs` entry.
- `lib/repo_builder/orchestrator/system_prompt.ex` — injects `ToolCatalog.tools()` into the prompt; confirm the new tool renders (no code change expected). A one-line mention of `get_logs` near the existing log/observability guidance is optional but recommended.
- `test/repo_builder/orchestrator/tools_test.exs` — the harness-blind tool test conventions (`RepoBuilder.SessionCase`, `orchestrator/1` helper, Fake harness, `uniq/0`). Mirror for the new tool's tests if co-locating, or use the new file below.
- `test/support/session_case.ex` / `test/support/data_case.ex` — `SessionCase` (for the tool test, which touches orchestrator + sandbox) and `DataCase` (for the pure context test).

### New Files
- `test/repo_builder/logs/logs_by_numbers_test.exs` — `RepoBuilder.DataCase` unit tests for `Logs.logs_by_numbers/2`: returns rows for the given numbers ordered by `log_no`, ignores absent numbers, honors `include_hidden?`, and handles the empty list as a `[]` no-op.
- `test/repo_builder/orchestrator/get_logs_test.exs` — `RepoBuilder.SessionCase` unit tests for the `get_logs` tool via `Tools.call("get_logs", orch_id, args)`: single (`log`), range (`from`/`to`, inclusive, accepting `"log-N"` and bare int), array (`numbers`), the count cap (`@max_log_lookup`), `missing` numbers reported, hidden excluded by default / included with the flag, owner field correctness (worker vs orchestrator row), text-excerpt truncation, and the `{:error, ...}` branch for no valid selector.

## Implementation Plan
### Phase 1: Foundation
Extend `RepoBuilder.Logs` with the single bounded reader `logs_by_numbers/2`, `@spec`'d, keeping `Ecto.Query` in the context. Write its `DataCase` unit test first (TDD) and make it pass. This is the only DB-facing change and has no dependency on the tool layer.

### Phase 2: Core Implementation
Add the `get_logs` handler to `RepoBuilder.Orchestrator.Tools`: the `dispatch/3` clause, the request parser (single / range / array → a deduped, capped, sorted integer list, accepting `"log-<n>"` or bare ints), the `log_detail/1` summary mapper (reusing the `log_summary_text/1` excerpt + `truncate_text/2` + `to_iso/1`/`decimal_to_string/1` helpers), and the `@max_log_lookup` cap. Drive it with `test/repo_builder/orchestrator/get_logs_test.exs` (TDD), covering every input shape and bound.

### Phase 3: Integration
Advertise the tool through both bindings: add the `get_logs` `tool_def` to `ToolCatalog` (auto-included in `tools/list`, `names/0`, and the system prompt) and the mirrored entry to the pi extension manifest. Assert via the MCP controller that `tools/list` includes `get_logs` and `tools/call` routes to it. Optionally add a one-line `get_logs` mention to the system prompt's observability guidance. Run the full validation suite.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs
- Read `BUILD_PROMPT.md` §3 (typed style), §4 (event contract + redaction — the summary must not re-expose anything `payload` doesn't already carry; `payload` is already scrubbed), §8 (only contexts touch `Repo`), §10 (harness-blind tool logic). Read the **(always)** + Ecto rows of `ai_docs/typed-elixir-standard.md`. Confirm: every new public fn gets an `@spec`; the tool layer calls only the `Logs` context; types are precise.

### 2. Extend the `RepoBuilder.Logs` context (TDD: write `test/repo_builder/logs/logs_by_numbers_test.exs` first)
- Add `@spec logs_by_numbers([integer()], keyword()) :: [AgentLog.t()]` (option: `:include_hidden?` boolean, default `false`).
- Implementation: `[] -> []` guard; otherwise `AgentLog |> where([l], l.log_no in ^numbers) |> filter_hidden(include_hidden?) |> order_by([l], asc: l.log_no) |> Repo.all()`. Reuse the existing private `filter_hidden/2`.
- Keep it `@spec`'d and inside the context (no `Repo`/`Ecto.Query` leaks to callers).
- Unit tests (DataCase): seed several `agent_logs` rows (via `persist_event/2`/`persist_orchestrator_event/2` so `log_no` is stamped) with known relative numbers; assert `logs_by_numbers/2` returns exactly the requested rows ordered ascending by `log_no`, ignores numbers with no row, excludes `hidden` rows by default and includes them with `include_hidden?: true`, and returns `[]` for `[]`.

### 3. Add the `get_logs` tool handler (`lib/repo_builder/orchestrator/tools.ex`) — TDD with `test/repo_builder/orchestrator/get_logs_test.exs`
- Add `defp dispatch("get_logs", _orchestrator_id, args), do: get_logs(args)` to the dispatch table (a read tool — orchestrator-id-independent, like `read_system_logs`).
- Add the module attribute `@max_log_lookup 100` (max distinct log numbers resolved in one call) with a comment tying it to the stdout-overflow concern (mirror `@worker_text_cap`'s rationale).
- Implement `@spec get_logs(map()) :: result()`:
  - Parse a concrete number set from, in precedence order, `numbers` (array of int/`"log-N"`), then `from`+`to` (inclusive range), then `log` (single). If none yields a valid number, return `{:error, "provide one of: log, from+to, or numbers"}`.
  - Normalize each entry with a `parse_log_no/1` helper accepting a bare integer, an integer-as-string, or a `"log-<n>"` string (reuse/mirror `blank_to_nil/1`); drop unparseable entries.
  - Dedup + sort ascending; **cap to `@max_log_lookup`** (take the first N after sort) so a huge range is bounded; remember whether the request was truncated.
  - Call `Logs.logs_by_numbers(numbers, include_hidden?: include_hidden?)` where `include_hidden?` comes from an optional boolean `include_hidden` arg (default false).
  - Map rows through `log_detail/1`; compute `missing` = requested numbers with no returned row.
  - Return `{:ok, %{"logs" => details, "count" => length(details), "requested" => length(requested), "missing" => missing, "capped" => capped?}}`.
- Implement `@spec log_detail(Logs.AgentLog.t()) :: map()` returning: `"log" => Logs.log_label(row.log_no)`, `"log_no" => row.log_no`, `"owner" => owner_label(row)` (e.g. `"worker:<agent_id>"` / `"orchestrator:<orchestrator_id>"`), `"session_id"`, `"event_type" => to_string(row.event_type)`, `"harness"`/`"provider"`/`"model"`, `"text"` (the `log_summary_text/1` excerpt run through `truncate_text/2` with `@worker_text_cap`, omitted when nil), `"usage"` (input/output/cache/cost via `decimal_to_string/1`, omitted when no `usage`), and `"at" => to_iso(row.inserted_at)`.
- Reuse existing private helpers: `log_summary_text/1`, `truncate_text/2`, `to_iso/1`, `decimal_to_string/1`, `blank_to_nil/1`, `positive_int/2`/`non_neg_int/2`. Add small `@spec`'d/inference-only helpers (`parse_log_no/1`, `owner_label/1`) following the file's existing inference-only-spec convention where Dialyzer would reject a hand-written supertype.
- The tool is automatically logged by `call/3`'s `log_invocation/3` (args keys only) — no extra work.
- Unit tests (SessionCase): for an orchestrator on the Fake harness, seed `agent_logs` rows with known `log_no`s, then assert via `Tools.call("get_logs", orch.id, args)`:
  - **single**: `%{"log" => "log-<n>"}` and `%{"log" => n}` both return that one row's detail.
  - **range**: `%{"from" => "log-<a>", "to" => "log-<b>"}` returns the inclusive set ordered ascending; bare ints also work.
  - **array**: `%{"numbers" => [a, "log-<b>", c]}` returns those rows; order normalized.
  - **cap**: a range wider than `@max_log_lookup` returns `"capped" => true` and at most `@max_log_lookup` logs.
  - **missing**: a number with no row appears in `"missing"`, not as an error.
  - **hidden**: a hidden row is excluded by default and included with `%{"include_hidden" => true}`.
  - **owner**: a worker-owned row reports `worker:…`; an orchestrator-owned row (`persist_orchestrator_event/2`) reports `orchestrator:…`.
  - **no selector**: `%{}` returns `{:error, _}`.

### 4. Advertise the tool in the catalog (`lib/repo_builder/orchestrator/tool_catalog.ex`)
- Add a `get_logs` `tool_def` with a description explaining the three shapes and that it reads the durable `log-<n>` numbers shown in the console (distinct from `read_system_logs`, which reads the separate system-log audit table, and from `check_agent_status`, which tails a worker by name). Input schema (all optional, at least one required by the handler):
  - `log`: `{"type" => "string", "description" => "A single log number, e.g. \"log-8219\" or \"8219\"."}` (also accepts integer at the handler).
  - `from` / `to`: string|int — inclusive range bounds (`log-8219`..`log-8228`).
  - `numbers`: `{"type" => "array", "items" => %{"type" => ["integer","string"]}, "description" => "Explicit list of log numbers."}`.
  - `include_hidden`: `{"type" => "boolean", "description" => "Include soft-hidden (cleared) rows (default false)."}`.
  - Note in the description the `@max_log_lookup` cap.
- `ToolCatalog.names/0` and the MCP `tools/list` pick it up automatically.

### 5. Mirror the tool in the pi extension manifest (`priv/orchestrator/pi_extension/orchestrator-tools.ts`)
- Add a `get_logs` entry to the `tools` array matching the catalog shape (`name`, `description`, `parameters` with `log`/`from`/`to`/`numbers`/`include_hidden`). Keep the wording aligned with the Elixir catalog (the comment block states the Elixir endpoint is the validation source of truth).

### 6. (Optional) System-prompt mention (`lib/repo_builder/orchestrator/system_prompt.ex`)
- The tool already renders from `ToolCatalog.tools()`. Optionally add one line to the observability guidance pointing the orchestrator at `get_logs` for resolving `log-<n>` references. Re-run `test/repo_builder/orchestrator/system_prompt_test.exs` if it asserts the tool list.

### 7. MCP-controller integration assertion
- In `test/repo_builder/orchestrator/get_logs_test.exs` (or the existing MCP controller test if present), assert the JSON-RPC `tools/list` response includes a tool named `get_logs`, and that a `tools/call` for `get_logs` with a seeded range routes through `Tools.call/3` and returns the expected `logs`/`missing` payload. This proves the binding is live, not just the internal function.

### 8. Runtime verification via Tidewave
- `project_eval`: call `RepoBuilder.Logs.logs_by_numbers([<n1>, <n2>], include_hidden?: false)` and `RepoBuilder.Orchestrator.Tools.call("get_logs", <orch_id>, %{"from" => "log-<a>", "to" => "log-<b>"})` against live data; confirm the shapes.
- `execute_sql_query`: `SELECT log_no, event_type, hidden FROM agent_logs ORDER BY log_no DESC LIMIT 10` to pick real numbers to look up and confirm the tool returns them.
- `get_logs` (Tidewave): inspect logs/stacktraces if a call errors.

### 9. Run the Validation Commands
- Run every command in **Validation Commands**; fix any failure; re-run until all green with zero regressions.

## Testing Strategy
### Unit Tests
- **Context (`logs_by_numbers_test.exs`, DataCase):** `logs_by_numbers/2` returns exactly the requested rows ordered ascending by `log_no`; ignores absent numbers; excludes hidden by default and includes with `include_hidden?: true`; `[]` → `[]`.
- **Tool (`get_logs_test.exs`, SessionCase):** every input shape (single string + single int, inclusive range, array — mixing `"log-N"` and bare ints), the `@max_log_lookup` cap (`"capped" => true`, bounded count), `missing` reporting, hidden include/exclude, owner labeling (worker vs orchestrator row), text-excerpt truncation at `@worker_text_cap`, and the no-selector `{:error, _}` branch.
- **MCP binding:** `tools/list` advertises `get_logs`; `tools/call` for `get_logs` routes through `Tools.call/3` and returns the payload.

### Edge Cases
- No selector provided (`%{}`) → `{:error, ...}`, never a crash.
- Inverted range (`from > to`) → empty/normalized set (no rows), not an error.
- Range far larger than the cap → bounded to `@max_log_lookup`, `"capped" => true`.
- Mixed `"log-8219"`, `"8219"`, `8219` forms all resolve to the same number; unparseable entries (`"foo"`, `nil`) are dropped silently.
- Numbers with no row → reported under `"missing"`, not an error.
- Hidden (cleared) rows excluded by default; surfaced only with `include_hidden: true`.
- A `nil`/non-persisted `log_no` is never matched (lookup is by concrete number).
- Very long event text is truncated to `@worker_text_cap` so the tool result stays small (stdout-overflow guard).
- `usage`-less rows omit the `"usage"` key; unpriced rows keep cost `nil` (the nil-vs-0 distinction).
- The tool never raises — any internal failure is caught by `call/3` and returned as `{:error, ...}`.

## Acceptance Criteria
- `RepoBuilder.Logs.logs_by_numbers/2` exists, is `@spec`'d, is the only new `Repo` caller, returns the requested `agent_logs` rows ordered by `log_no`, and honors `include_hidden?`.
- A new orchestrator tool **`get_logs`** resolves a single number, an inclusive `from..to` range, and an explicit `numbers` array (accepting both `"log-<n>"` and bare integers), returning each log's critical info (label, owner, type, text excerpt, usage/cost, time).
- The tool **bounds** the resolved count to `@max_log_lookup` and reports `capped`/`missing`; it **never raises**.
- `get_logs` is advertised identically by the MCP `tools/list` (via `ToolCatalog`) and the pi extension manifest, and `tools/call` routes to `Tools.call/3`.
- The tool layer calls only the `RepoBuilder.Logs` context (never `Repo`); every new public function has an `@spec`.
- All **Validation Commands** pass with zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/logs/logs_by_numbers_test.exs` — context lookup unit tests pass.
- `mix test test/repo_builder/orchestrator/get_logs_test.exs` — `get_logs` tool unit + MCP-binding tests (single/range/array, cap, missing, hidden, owner, no-selector) pass.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green (zero failures, zero regressions).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an `@spec`" rule.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **No migration / no new dependency.** `log_no` (owned DB sequence, `read_after_writes: true`), `hidden`, `payload` (already secret-redacted at persist time, §4.1), `usage`, and the owner columns already exist on `agent_logs`. This is purely additive read paths + a tool binding.
- **Why a new tool, not an extension of `check_agent_status` or `read_system_logs`:** `check_agent_status` is keyed on a *worker name* with a recency tail (cannot address a number, cannot span workers); `read_system_logs` reads the *separate* `system_logs` table (orchestrator tool-audit lines), which has no `log_no`. The `log-<n>` numbers people reference live on `agent_logs` and had no lookup at all — `get_logs` closes that gap.
- **Bounding is mandatory.** Orchestrator tool results are surfaced into the agent's context and the platform has a known large-tool-result stdout-overflow concern (`@worker_text_cap`, issue-log-2389). The handler caps the resolved number set (`@max_log_lookup`) and truncates each event's text excerpt, reporting `capped` so the orchestrator can paginate/narrow rather than silently lose data.
- **Redaction is already handled.** The summary reads `payload`, which is the scrubbed copy persisted by `Logs.persist_event/2` (the live broadcast keeps the full `raw`; only the DB copy is scrubbed). `get_logs` therefore cannot re-expose secrets that aren't already redacted.
- **Not a UI feature.** This adds an orchestrator *agent tool*, not console UI, so no `Phoenix.LiveViewTest` is required (the console already renders `log-<n>` via `log_label/1`); the integration coverage is the MCP-controller binding assertion instead. A future enhancement could add a console "jump to log-<n>" affordance reusing `logs_by_numbers/2`.
- **Harness parity.** Per §10, the logic lives once in `Tools.get_logs/1`; the Claude MCP binding, the pi extension, and the Fake loop all reach it identically — the pi manifest entry and the catalog entry are advertisement only.
- **Possible follow-ups:** support a mixed request (e.g. a range plus extra numbers in one call), a `by_owner`/`event_type` filter on the lookup, or cursor-style continuation when `capped` is true.
