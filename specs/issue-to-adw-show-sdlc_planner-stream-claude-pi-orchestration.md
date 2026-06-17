# Feature: Live token-by-token streaming for Claude AND pi orchestration

## Metadata
issue_number: `to`
adw_id: `show`
issue_json: `streaming`

## Feature Description
Make the orchestration console at `/` (`RepoBuilderWeb.ConsoleLive`) render the
orchestrator's reply as a **single, smoothly-growing chat bubble that fills in
token-by-token as the harness streams**, identically for both the **Claude** and
**pi** harnesses. Today the console technically receives streaming `text_delta`
events, but it renders them wrong: every delta mints a *new* chat bubble, so a
single answer appears as a cascade of dozens of one-token fragments **followed by
a duplicate full-text bubble** (because each adapter emits incremental deltas AND
a finalized full-text block for the same message). The result reads as broken
rather than "live."

This feature introduces a harness-blind streaming-text model: incremental deltas
coalesce into one in-progress bubble that updates in place (throttled so a fast
provider can't flood the WebSocket), and the authoritative finalized block
finalizes that bubble exactly once (no duplication). It also stops persisting the
token-level partials to `agent_logs` so the database stays lean and reconnect
backfill renders one clean message per turn instead of replaying token shards.

Because the change is expressed entirely in the **canonical event contract**
(`Event.TextDelta`) plus the harness-blind console/runtime that consume it, it
works for every current and future orchestrator-capable harness with no
per-harness UI code — the open-identity design seam (§10) is preserved.

## User Story
As an **operator driving the orchestrator from the console**
I want to **watch the orchestrator's answer stream in live, as one coherent
growing message, whether I'm running the Claude or the pi harness**
So that **I get immediate, readable feedback that the agent is working and what
it is saying — instead of a jumble of duplicated one-token fragments — and the
experience is identical across harnesses.**

## Problem Statement
The console's text handling has three concrete defects, all rooted in how
`Event.TextDelta` is consumed:

1. **Fragmentation.** `ConsoleLive.handle_info/2` for `%Event.TextDelta{}`
   (`lib/repo_builder_web/live/console_live.ex:584` and `:572` for thinking)
   calls `record_event/3`, which calls `maybe_chat/3` → `append_chat/3`. Each
   delta becomes its **own** chat message in `@messages`. A streamed answer of
   N tokens produces N bubbles.
2. **Duplication.** Both adapters emit the same text twice — once incrementally,
   once finalized:
   - `RepoBuilder.Harness.Claude.normalize/2` emits a `TextDelta` per
     `stream_event` `text_delta` frame (`claude.ex:167`) **and** a `TextDelta`
     for the finalized `assistant` `text` block (`claude.ex:227`).
   - `RepoBuilder.Harness.Pi.normalize/2` emits a `TextDelta` per
     `message_update` `text_delta` frame (`pi.ex:109`) **and** a `TextDelta` for
     the finalized `message_end` text (`pi.ex:147`).
   With no way to tell incremental from finalized, the console renders both.
3. **Persistence flood + dirty backfill.** `Session.Server.dispatch/2`
   (`session/server.ex:381`) persists **every** canonical event, including every
   token-level partial, to `agent_logs` (worker path and orchestrator path).
   Token streaming therefore writes thousands of rows per turn, and
   `ConsoleLive.backfill_events/1` (`console_live.ex:243` →
   `Logs.list_recent_global/1` → `chat_for_row/1`) replays each shard as a
   separate bubble on reconnect.

The canonical `Event.TextDelta` struct (`lib/repo_builder/harness/event.ex:52`)
carries `text` and `thinking?` but **no signal distinguishing an incremental
delta from a finalized block** — so neither the runtime nor the UI can coalesce
or de-duplicate.

## Solution Statement
Add one optional boolean to the canonical contract — `partial?` on
`Event.TextDelta` — exactly mirroring the existing `thinking?` flag (additive,
`default: false`, keeps the closed 8-variant sum type and the open `harness`
identity intact; no schema migration). Adapters tag incremental deltas
`partial?: true` and finalized blocks `partial?: false`. Then the two harness-blind
consumers branch on it:

- **Session runtime (`Session.Server`)** broadcasts partials live but **does not
  persist** them; finalized text is persisted as today. `agent_logs` stays lean;
  reconnect backfill renders one message per turn.
- **Console (`ConsoleLive`)** coalesces `partial?: true` deltas into a per-agent
  **streaming buffer** (a plain assign, throttled with a ~50 ms flush tick per
  the research below — the "in-progress bubble lives in an assign, finalized
  messages live in the list" pattern). On a `partial?: false` finalized delta it
  finalizes the bubble into `@messages` exactly once and clears the buffer; a
  `Done`/`Error` flush promotes any leftover buffer as a safety net (providers
  like zai/GLM may stream partials with a `message_end` that already finalizes;
  the flush covers the rare no-finalize case).

This is harness-blind: Claude and pi differ only in *which raw frames* set
`partial?`, inside their own `normalize/2`. Adding a third streaming harness
later needs zero console/runtime change. The same partials are intentionally kept
**out of the center raw-event log** (one finalized row per turn, as today) so the
observability ledger and its bounded buffer aren't flooded either — the live
token flow shows in the chat panel, the ledger shows the finalized event.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/harness/event.ex` — **edit.** Add `field :partial?, boolean(),
  default: false` to the `TextDelta` typedstruct; update its `@moduledoc` note.
  The keystone contract change; everything else keys off it.
- `lib/repo_builder/harness/claude.ex` — **edit.** Set `partial?: true` on the
  `stream_event` `text_delta` clause (`:167`); leave the finalized `assistant`
  `text`/`thinking` blocks (`assistant_block/2`, `:227`/`:230`) as
  `partial?: false` (the default). No other behavior change.
- `lib/repo_builder/harness/pi.ex` — **edit.** Set `partial?: true` on the
  `message_update` `text_delta` (`:109`) and `thinking_delta` (`:125`) clauses;
  leave `message_end` finalized text (`append_text/4`, `:321`) as
  `partial?: false`.
- `lib/repo_builder/session/server.ex` — **edit.** In `dispatch/2` (`:381`) gate
  persistence with a `persist?/1` predicate that returns `false` for
  `%Event.TextDelta{partial?: true}` (broadcast still fires for the live UI;
  worker and orchestrator persistence both skip partials). Lifecycle/status
  updates unaffected.
- `lib/repo_builder_web/live/console_live.ex` — **edit (core UI).** Add a
  `@streaming` assign (`%{agent_id => %{text: String.t(), thinking: String.t()}}`)
  and a `@stream_pending` accumulator + flush timer. Rewrite the `TextDelta`
  `handle_info` clauses to branch on `partial?`; add `handle_info(:flush_stream,
  …)`; flush/promote leftover buffers on `Done`/`Error`. Render the live
  streaming bubble(s) in the `<:messages>` slot after the finalized `@messages`.
  Reset `@streaming`/`@stream_pending` in `mount/3` and on reconnect backfill.
- `lib/repo_builder_web/components/console_components.ex` — **edit.** Add a typed
  `streaming_bubble/1` function component (attr `content`, `thinking?`, `label`,
  `time`) — a growing assistant/thinking bubble with a blinking caret — used for
  the in-progress buffer. Mirrors `chat_message/1` / `thinking_bubble/1`.
- `assets/css/app.css` — **edit.** Add `.cns-bubble--streaming` + a `cns-caret`
  blink keyframe for the live bubble. (App.css already uses the required v4
  `@import "tailwindcss"` syntax — keep it.)
- `lib/repo_builder/logs.ex` — **reference / minor.** `event_payload/2` for
  `TextDelta` (`:217`) already persists `%{"text", "thinking"}`; with partials
  skipped upstream, only finalized text persists — confirm no change needed
  (optionally add `"partial" => false` for clarity). `list_recent_global/1` and
  `chat_for_row/1` (in `console_live.ex:1183`) backfill correctly once partials
  aren't stored.
- `lib/repo_builder/dashboard.ex` — **reference.** `broadcast_event/2` (the
  `console:events` global feed) is the seam the console subscribes to; unchanged.
- `lib/repo_builder/orchestrator/server.ex` — **reference.** Subscribes to the
  orchestrator session topic for session-id/cost/status/in-process tool dispatch
  only; `partial?` doesn't affect it (verify no `TextDelta`-shape assumptions).
- `assets/js/app.js` — **reference.** The existing `AutoScroll` hook already pins
  the chat to the bottom on patch with a user-scroll-up pause; the growing
  streaming bubble triggers `updated()` and auto-follows for free. No JS change
  expected (confirm).
- `test/support/fixtures/claude_stream.jsonl`, `test/support/fixtures/pi_stream.jsonl`,
  `test/support/fixtures/pi_zai_stream.jsonl` — **reference.** Real captured
  streams used by the normalizer tests; assert `partial?` against them.
- `test/repo_builder/harness/claude_normalize_test.exs`,
  `test/repo_builder/harness/pi_normalize_test.exs` — **edit.** Add assertions
  that partial vs finalized deltas carry the right `partial?`.
- `test/repo_builder_web/live/test_orchestration_console_test.exs`,
  `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` — **edit.**
  These already assert per-delta chat behavior; update for the coalesced model.
- `BUILD_PROMPT.md` — **reference.** §4 (canonical event contract / TextDelta),
  §4.3 (Claude/pi mapping tables — note the "local parser defers to message_end"
  line for pi), §6 (session runtime persist+broadcast), §9 (LiveView streams,
  reconnect-seed rule).
- `AGENTS.md` — **reference.** Phoenix v1.8 + LiveView guidelines (streams,
  `to_form`, colocated hooks, `<Layouts.app>`), typed-standard reminders.
- `ai_docs/typed-elixir-standard.md` — **reference (always).** `@spec` on every
  public fn, `typedstruct`/`@enforce_keys`, precise types, tagged tuples.
- `/home/robert/projects/indieDevDan/ai_docs/streaming_pi_in_phoenix.md` —
  **reference.** External research doc on streaming pi in Phoenix. Confirms:
  `--mode json` is the streaming mode (already used); strict JSONL framing on
  `\n` only (already implemented in `Session.Server.split_lines/1`); **Rule 9 —
  cap/throttle the response assign so thousands of `text_delta`/sec don't flood
  the WebSocket** (this feature's flush-tick); pin `--provider`/`--model` in
  server contexts (already done in `Pi.command/1`). Validates the design; no
  framing/transport change required.

### New Files
- `test/repo_builder_web/live/test_streaming_console_test.exs` — `Phoenix.LiveViewTest`
  integration test that mounts `ConsoleLive`, broadcasts a partial→finalized→done
  `TextDelta` sequence over `console:events` for **both** `harness: :claude` and
  `harness: :pi`, and asserts: (a) a single streaming bubble grows as partials
  arrive, (b) it finalizes to exactly one orchestrator message with the full
  text, (c) **no duplicate** bubble, (d) the thinking channel coalesces
  separately, (e) a partial-only sequence ending in `Done` (no finalized block)
  still promotes the buffered text once.

## Implementation Plan
### Phase 1: Foundation — contract + adapters
Extend the canonical `Event.TextDelta` with the additive `partial?` flag and make
both adapters tag incremental vs finalized deltas. This is the single source of
truth every downstream consumer keys off; doing it first keeps the compiler and
normalizer tests green before any UI work. No migration, no schema change — the
flag lives only in the in-memory struct and (optionally) the JSONB payload.

### Phase 2: Core Implementation — runtime persistence gate + console coalescing
1. **Runtime:** gate `Session.Server.dispatch/2` so partial text deltas broadcast
   but never persist (lean `agent_logs`, clean backfill).
2. **Console:** add the per-agent streaming buffer + throttled flush tick, rewrite
   the `TextDelta` handlers to coalesce partials and finalize on the authoritative
   block, and add the `streaming_bubble` component + CSS. This is where the
   visible behavior changes for both harnesses at once.

### Phase 3: Integration — backfill, reconnect, lifecycle, tests, validation
Wire the streaming buffer into mount/reconnect (reset to empty; finalized history
comes from the persisted-rows backfill), flush leftover buffers on `Done`/`Error`,
update the existing normalizer + console tests for the coalesced model, add the
new LiveView streaming integration test, and run the full green gate plus a live
Tidewave/IEx smoke check.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add `partial?` to the canonical `TextDelta` event
- In `lib/repo_builder/harness/event.ex`, inside the `TextDelta` `typedstruct`,
  add `field :partial?, boolean(), default: false` (place it next to
  `thinking?`). Update the module's `@moduledoc` to document `partial?`
  ("`true` for an incremental token delta; `false` for a finalized/whole block —
  consumers coalesce partials and finalize on the non-partial block").
- This is additive and backward-compatible (every existing constructor omits it →
  `false`), so the sum type stays closed and Dialyzer stays green.
- Run `mix compile --warnings-as-errors` to confirm clean.

### 2. Tag Claude deltas partial vs finalized
- In `lib/repo_builder/harness/claude.ex`, the `stream_event` `text_delta` clause
  (`normalize/2` at `:167`) builds `%Event.TextDelta{harness: :claude, text: text,
  raw: raw}` — add `partial?: true`.
- Leave `assistant_block/2` (`:227` text, `:230` thinking) at the default
  `partial?: false` (these are the finalized whole blocks).
- These are the only two edits in this adapter.

### 3. Tag pi deltas partial vs finalized
- In `lib/repo_builder/harness/pi.ex`, the `message_update` `text_delta` clause
  (`:109`) and `thinking_delta` clause (`:125`) build incremental
  `%Event.TextDelta{…}` — add `partial?: true` to each.
- Leave `append_text/4` (`:321`, used by the `message_end` finalized path) at the
  default `partial?: false`.

### 4. Update normalizer tests for the partial flag
- In `test/repo_builder/harness/claude_normalize_test.exs` and
  `test/repo_builder/harness/pi_normalize_test.exs`, add assertions that a
  `stream_event`/`message_update` delta yields `partial?: true` and a finalized
  `assistant`/`message_end` text yields `partial?: false`. Drive them from the
  existing fixtures (`claude_stream.jsonl`, `pi_stream.jsonl`,
  `pi_zai_stream.jsonl`) so real captured frames are exercised, including the
  zai/GLM `message_end`-only (no-partials) case (must be `partial?: false`).
- Run `mix test test/repo_builder/harness/` — green.

### 5. Stop persisting partial text deltas in the session runtime
- In `lib/repo_builder/session/server.ex` `dispatch/2` (`:381`), add a private
  `@spec persist?(Event.t()) :: boolean()` predicate returning `false` for
  `%Event.TextDelta{partial?: true}` and `true` otherwise. Guard both
  `persist_quietly/2` (worker path, `agent_db_id`) and
  `persist_orchestrator_quietly/2` (orchestrator path, `orchestrator_db_id`) with
  it. The PubSub broadcast (`broadcast_event/2` and the per-agent topic) and the
  `saw_output?`/`saw_terminal?`/lane logic stay unconditional, so the live UI
  still sees every partial and lifecycle tracking is unchanged.
- Confirm `Logs.persist_event/2` is otherwise untouched; finalized text deltas
  persist as before (one row per finalized message).

### 6. Add the streaming-bubble component + CSS
- In `lib/repo_builder_web/components/console_components.ex`, add a typed
  `streaming_bubble/1` (`attr :content, :string, required: true`,
  `attr :thinking?, :boolean, default: false`, `attr :label, :string`,
  `attr :time, :string, default: ""`) with `@spec streaming_bubble(map()) ::
  Phoenix.LiveView.Rendered.t()`. Render an orchestrator-style bubble
  (`cns-bubble--orch` for text, `cns-bubble--thinking` when `thinking?`) plus a
  trailing `<span class="cns-caret"/>` so the live text shows a blinking cursor.
  Give it a stable element id (e.g. `id={"streaming-#{...}"}`) for test selectors.
- In `assets/css/app.css`, add `.cns-bubble--streaming` and a `cns-caret` blink
  keyframe (no `@apply`; raw CSS per AGENTS.md).

### 7. Add the per-agent streaming buffer + throttled flush to ConsoleLive
- In `lib/repo_builder_web/live/console_live.ex` `mount/3` initial assigns
  (around `:81`), add `streaming: %{}`, `stream_pending: %{}`,
  `stream_flush_ref: nil`. Add a module attr `@stream_flush_ms 50`.
- Add `@spec` private helpers:
  - `accumulate_partial(socket, agent_id, channel, text)` where `channel` is
    `:text | :thinking` — append `text` to `@stream_pending[agent_id][channel]`
    and `schedule_flush/1` if no timer is pending.
  - `schedule_flush(socket)` — if `stream_flush_ref` is nil, set it to
    `Process.send_after(self(), :flush_stream, @stream_flush_ms)`.
  - `finalize_stream_channel(socket, agent_id, channel)` — drop that channel from
    both `@streaming` and `@stream_pending` for the agent (called when the
    finalized block for that channel arrives).
  - `flush_streaming_agent(socket, agent_id)` — promote any remaining buffered
    text for an agent into `@messages` as finalized chat entries (used by
    `Done`/`Error`), then clear the agent's buffers.
- Rewrite the `TextDelta` handlers:
  - `handle_info({:agent_event, agent_id, %Event.TextDelta{partial?: true,
    thinking?: t} = e}, socket)` → `accumulate_partial(socket, agent_id,
    channel(t), e.text)`; return `{:noreply, …}`. Do **not** call `record_event`
    (no center-log row, no per-token counter) for partials.
  - `handle_info({:agent_event, agent_id, %Event.TextDelta{thinking?: true} = e},
    socket)` (now implicitly `partial?: false`) → `finalize_stream_channel(…,
    :thinking)` then the existing `record_event` thinking path (one permanent
    thinking message + one center row).
  - `handle_info({:agent_event, agent_id, %Event.TextDelta{} = e}, socket)`
    (`partial?: false` text) → `finalize_stream_channel(…, :text)` then the
    existing `record_event` response path.
- Add `handle_info(:flush_stream, socket)`: merge `@stream_pending` into
  `@streaming` (commit accumulated text → triggers one render), clear
  `@stream_pending`, set `stream_flush_ref: nil`. If pending still has content
  after merge it won't — pending is fully drained each tick; new partials between
  ticks reschedule.
- In the existing `Done` and `Error` handlers (`:653`, `:669`), call
  `flush_streaming_agent(socket, agent_id)` before/with the existing logic so any
  partial-only stream (no finalized block) still promotes its text once and the
  buffer clears.
- In `backfill_events/1` (`:243`), reset `streaming: %{}`, `stream_pending: %{}`,
  `stream_flush_ref: nil` so a reconnect starts from persisted finalized history
  only (no stale in-flight buffer).

### 8. Render the live streaming bubbles in the chat panel
- In the `<:messages>` slot of the `command_panel` (around `console_live.ex:1047`),
  after the `@messages` for-comprehension, render the in-flight buffers:
  for each `{agent_id, %{text: txt, thinking: think}}` in `@streaming`, emit a
  `<.streaming_bubble>` for non-empty `txt` (respecting nothing extra) and, when
  `@show_thinking?` and `think` is non-empty, a `thinking?` streaming bubble.
  Use stable ids (`streaming-text-#{agent_id}` / `streaming-think-#{agent_id}`)
  so LiveView patches the text node in place and tests can select it.
- Confirm the existing `AutoScroll` hook (`assets/js/app.js`) keeps the panel
  pinned to the bottom as the bubble grows (its `updated()` fires on each patch);
  no JS change expected.

### 9. Create the LiveView streaming integration test
- Create `test/repo_builder_web/live/test_streaming_console_test.exs` using
  `Phoenix.LiveViewTest`. For each harness atom in `[:claude, :pi]`:
  - `{:ok, view, _html} = live(conn, "/")`.
  - Broadcast over `RepoBuilder.PubSub` topic `"console:events"` the tuple
    `{:agent_event, agent_id, %Event.TextDelta{harness: h, text: "Hel",
    partial?: true}}`, then `"lo"` partial, asserting the growing
    `#streaming-text-#{agent_id}` bubble contains `"Hello"` (use
    `render(view)` / `has_element?/2`; allow for the ~50 ms flush by asserting
    after a `render/1` round-trip or by sending a follow-up event that forces a
    flush — prefer driving `:flush_stream` deterministically via a final event
    rather than `Process.sleep`).
  - Broadcast the finalized `%Event.TextDelta{harness: h, text: "Hello",
    partial?: false}` and assert: exactly one finalized orchestrator chat message
    with `"Hello"`, and the `#streaming-text-#{agent_id}` element is **gone**
    (no duplication).
  - Separately assert the **partial-only + Done** path: partials then
    `%Event.Done{harness: h, ok: true, reason: :agent_end}` promotes the buffered
    text to one message and clears the bubble.
  - Assert the thinking channel coalesces independently and respects
    `@show_thinking?`.
- Follow AGENTS.md LiveView test rules: select by element id (`element/2`,
  `has_element?/2`), never raw-HTML assertions; use `start_supervised!` for any
  process; no `Process.sleep`.

### 10. Update the existing console tests for the coalesced model
- Update `test/repo_builder_web/live/test_orchestration_console_test.exs` and
  `test/repo_builder_web/live/test_orchestration_console_ui_test.exs` where they
  assume one chat bubble per `text_delta`. Partials now coalesce; finalized text
  yields one message. Keep them asserting on element ids, not text-fragility.

### 11. Optional live smoke check via Tidewave
- With the app running (`scripts/pg.sh start`; `iex -S mix phx.server`), use
  Tidewave `project_eval` to broadcast a synthetic partial→finalized→done
  `TextDelta`/`Done` sequence on `"console:events"` for `:claude` and `:pi` and
  visually confirm one growing-then-finalized bubble (or capture a Playwright
  screenshot of `http://localhost:4000`). Use Tidewave `get_logs` to confirm no
  persistence/Dialyzer warnings fired. (Live CLI runs are the only manual step;
  this synthetic check needs no external CLI.)

### 12. Run the full validation suite
- Run every command in **Validation Commands** below; fix anything that is not
  green before considering the feature complete.

## Testing Strategy
### Unit Tests
- **Adapter normalizers** (`claude_normalize_test.exs`, `pi_normalize_test.exs`):
  incremental `stream_event`/`message_update` deltas → `partial?: true`; finalized
  `assistant`/`message_end` text → `partial?: false`; thinking deltas carry both
  `thinking?: true` and the correct `partial?`; zai/GLM `message_end`-only stays
  `partial?: false`. Existing `:skip`/usage/tool assertions stay green.
- **Session runtime persistence gate**: a focused test (extend an existing
  `session/server` or `logs` test, or add to the new test where feasible) that
  asserts a `%TextDelta{partial?: true}` event is broadcast but produces **no**
  `agent_logs` row, while a `partial?: false` text delta produces exactly one
  row. Verify via the `Logs` context (never `Repo` directly).
- **Console coalescing** (new `test_streaming_console_test.exs`): growing bubble,
  single finalize, no duplicate, independent thinking channel, partial-only+Done
  promotion — for both `:claude` and `:pi`.

### Edge Cases
- **Finalized block with no preceding partials** (zai/GLM, Fake harness): renders
  as one finalized bubble; no empty streaming bubble lingers.
- **Partials then terminal `Error`/`idle_timeout`** (hung provider): leftover
  buffer is flushed/promoted once, bubble cleared, error still surfaces.
- **Interleaved partials from two concurrent agents**: per-`agent_id` buffers keep
  the two growing bubbles separate (no cross-contamination into one message).
- **Reconnect mid-stream**: `mount`/`backfill_events` resets the buffer; only
  persisted finalized messages reappear (no token shards), matching the §9
  reconnect-seed rule.
- **Thinking hidden** (`@show_thinking?` false): thinking partials still coalesce
  server-side but the thinking streaming bubble is not rendered; toggling it on
  mid-stream reveals the in-progress thinking bubble.
- **Empty/whitespace-only finalized text**: finalize clears the buffer without
  emitting an empty message (guard non-empty, matching `append_text/4`).
- **Flush throttle**: a burst of many partials within one 50 ms window collapses
  into a single render (assert the WebSocket isn't driven per-token — verify by
  the deterministic flush-on-event approach, not timing).

## Acceptance Criteria
- Running the orchestrator under **Claude** streams the reply as **one** growing
  chat bubble that finalizes to **one** message — no per-token fragments, no
  duplicate full-text bubble.
- Running the orchestrator under **pi** produces the **identical** streaming UX,
  with no harness-specific UI code (the difference is only which raw frames set
  `partial?` inside each adapter's `normalize/2`).
- The thinking pane streams independently and still respects `@show_thinking?`.
- Token-level partials are **broadcast but not persisted**: an N-token turn writes
  exactly one finalized `agent_logs` text row, and a console reconnect backfills
  one clean message (no token shards).
- A partial-only stream that ends in `Done`/`Error` (no finalized block) still
  shows the answer once; a finalized-only stream (no partials) shows it once.
- The live response assign is throttled (≤ one render per `@stream_flush_ms`),
  so a fast provider cannot flood the socket (research Rule 9 satisfied).
- `@spec` on every new public function; new struct field is typed via
  `typedstruct`; no `any()`/`map()` where a precise type fits.
- The full green gate passes with zero regressions (commands below).

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is up (once per session).
- `scripts/patch_deps.sh` — only if `mix deps.get` ran since last compile (no new
  deps are added by this feature, so normally skip).
- `mix test test/repo_builder_web/live/test_streaming_console_test.exs` — the new
  streaming integration test (both harnesses) passes.
- `mix test test/repo_builder/harness/claude_normalize_test.exs test/repo_builder/harness/pi_normalize_test.exs`
  — adapter `partial?` tagging verified against real fixtures.
- `mix test test/repo_builder_web/live/test_orchestration_console_test.exs test/repo_builder_web/live/test_orchestration_console_ui_test.exs`
  — existing console tests pass under the coalesced model.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type
  checker and `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) green.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, including "every public function has an `@spec`".
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore
  filters.

## Notes
- **No new dependencies.** The whole feature is contract + consumers; `mix.exs`
  is untouched. (`Req`/SSE patterns from the research are not needed — the
  harness already streams NDJSON over erlexec, framed by `Session.Server`.)
- **Why a struct flag, not adapter-side suppression.** `normalize/2` is stateless
  per frame, so an adapter cannot know whether partials preceded a finalized
  block; the clean, harness-blind signal is a typed flag on the event, consumed
  by the (stateful) console and runtime. This mirrors the existing `thinking?`
  flag precedent and keeps the "add a harness = one module" seam (§10) intact —
  the canonical `Event` sum type stays 8 variants with an open `harness` identity.
- **Throttle interval.** `@stream_flush_ms = 50` (~20 fps) is the
  community-validated sweet spot (Ben Reinhart's LiveView streaming series; the
  `Process.send_after` flush-tick is the standard scaling layer over 1:1
  forwarding; Chris McCord's "Req + `:into` + `send` to LiveView" confirms the
  send-to-pid model). Bump to 100 ms if many concurrent sessions are observed.
  Sources: https://benreinhart.com/blog/openai-streaming-elixir-phoenix-part-3/ ·
  https://elixirforum.com/t/any-tips-on-streaming-llm-responses-from-phoenix-sockets/65574 ·
  https://fly.io/phoenix-files/building-a-chat-app-with-liveview-streams/
- **Streams vs assign.** The in-progress bubble deliberately lives in a **plain
  assign** (`@streaming`), not a LiveView stream — streams are for append-only
  finalized rows; a value that mutates every token is the documented anti-pattern.
  Finalized messages remain in the existing `@messages` list (bounded to
  `@messages_limit`); the center raw-event ledger remains a LiveView stream of
  finalized events. (For a future scale-up, finalized chat history could move to
  a true `stream/4`, but that's out of scope here.)
- **Dedup policy.** The finalized `partial?: false` block is treated as
  authoritative: it finalizes the bubble and the partials (which lived only in the
  transient buffer, never in `@messages`) are discarded — so there is never both a
  delta-built and a block-built copy. The `Done`/`Error` flush is the safety net
  for providers that stream partials without a finalizing block.
- **In-progress repo state.** The working tree has concurrent unrelated specs
  (agent-CRUD, settings modal, `show_thinking?` toggle, activity orb). This plan
  is additive to those — notably it reuses the just-added `@show_thinking?`
  assign for the thinking streaming bubble and the `AutoScroll` hook. Rebase/merge
  carefully around the already-modified `console_live.ex`, `console_components.ex`,
  and the two console test files.
- **Tidewave validation.** Prefer `project_eval` to broadcast synthetic event
  sequences on `"console:events"` and `get_logs` to confirm no persistence/Dialyzer
  noise, over ad-hoc IEx — no external CLI required for this synthetic check.
