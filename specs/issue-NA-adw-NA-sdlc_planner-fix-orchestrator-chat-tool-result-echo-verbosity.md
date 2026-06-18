# Bug: Orchestrator chat is flooded with raw tool-result JSON (pi surfaces tool results as assistant text)

## Metadata
issue_number: `NA`
adw_id: `NA`
issue_json: `{}` (interactive `/bug` invocation — operator report: "check from log-1832 onwards why so verbose on the chat")

## Bug Description
The orchestrator (right-hand) chat pane is extremely verbose: from **log-1832** onward,
nearly every orchestrator meta-tool call produces a chat bubble containing the **raw JSON
result of that tool**, on top of the orchestrator's actual prose. A prior fix already
restricted the chat to orchestrator *finalized text* only (thinking + `tool_call`/
`tool_result` events are excluded from chat and live in the center event stream). The new
verbosity is that the orchestrator's **TEXT channel itself** now carries tool-result JSON.

Concrete evidence (persisted `agent_logs`, pi orchestrator / glm-5.1):

| seq_no | event_type | content (snippet) |
|---|---|---|
| 1837 | `tool_call` | `tool_execution_start` `configure_tier` |
| 1838 | `tool_result` | `tool_execution_end` → `{"category":"fast",…,"status":"configured"}` |
| **1839** | **`text_delta`** | `{"text":"{\"category\":\"fast\",…\"status\":\"configured\"}","thinking":false}` ← **duplicate of the tool result, as assistant text** |

The same pattern repeats for `get_config` (1832), `create_agent`/`command_agent`
(1851, 1856, 1869), and the error path (1844 `invalid agent: …`). Each tool's result is
emitted **twice**: once correctly as a `tool_result` event (kept out of chat, shown in the
event stream) and once as an assistant `text_delta` (shown in the chat as an
`ORCHESTRATOR` bubble of raw JSON).

Separately, the orchestrator also narrates every micro-step ("Tiers are all unassigned.
This is a trivial task, so I'll configure the fast tier…", "Worker is running and already
calling tools. Let me give it a moment…" — 1834, 1835, 1846, 1847, 1880, 1881). That is
genuine prose (not the focus of this bug) but compounds the noise.

- **Expected:** the orchestrator chat shows only the orchestrator's human-directed prose
  (status updates, answers). Tool-result JSON belongs to the `tool_result` event in the
  center event stream, never duplicated into chat.
- **Actual:** every tool result is echoed verbatim into chat as orchestrator text.

## Problem Statement
pi's `message_end` assistant turn includes the tool-result text as a `{"type":"text"}`
content block, and the pi normalizer harvests **all** `type:"text"` blocks as assistant
`TextDelta`s. So tool-result JSON is normalized into the orchestrator's TEXT channel,
which the chat renders — duplicating what the `tool_result` event already captured and
drowning the conversation in machine output.

## Solution Statement
Stop tool-result content from reaching the orchestrator chat. The fix is at the pi
normalizer boundary (`RepoBuilder.Harness.Pi.normalize/2`, the `message_end` → `pi_text`
→ `join_blocks` text-extraction path): the assistant text emitted from a `message_end`
must exclude tool-result-echo blocks, so only the orchestrator's authored prose becomes a
`TextDelta`.

The exact discriminator must be confirmed from a live raw pi `message_end` frame (Step 1):
pi tags content blocks by `type`, so the harvest should be narrowed to **only genuine
assistant text blocks**, excluding any block that represents a tool result/echo (e.g.
`type` in `{"tool_result","toolResult","tool_use","tool_call"}`, or a text block whose
content equals the immediately-preceding `tool_execution_end` result). `join_blocks/2`
already filters to `type:"text"`, so if pi nests the tool result inside a `type:"text"`
block, the fix narrows by structure (the enclosing block/role) or by de-duplicating
against the just-seen tool result.

Secondary (NOT the core fix; note only): the step-by-step narration verbosity is prose
behavior — address via the orchestrator system prompt ("report concisely; do not echo
tool outputs or narrate every internal step"), out of scope for this surgical fix.

## Steps to Reproduce
1. Run a pi orchestrator turn that calls meta-tools (e.g. "create a file" → it calls
   `get_config`/`configure_tier`/`create_agent`/`command_agent`).
2. Watch the right-hand chat: each tool produces an `ORCHESTRATOR` bubble of raw JSON
   identical to the tool's result.
3. Confirm in the DB:
   ```sql
   SELECT seq_no, event_type, left(payload->>'text','60')
   FROM agent_logs WHERE seq_no >= 1832 AND event_type = 'text_delta' ORDER BY seq_no;
   ```
   Multiple `text_delta` rows hold tool-result JSON (e.g. 1839, 1851, 1856, 1869).

Deterministic regression target: feed a representative pi `message_end` frame (whose
`message.content` contains a tool-result-echo text block) through
`RepoBuilder.Harness.Pi.normalize/2` and assert it does NOT yield a `TextDelta` for the
tool-result content (only for genuine prose).

## Root Cause Analysis
- The orchestrator chat is fed by finalized orchestrator `TextDelta` events (the prior
  chat/events-separation fix keeps thinking + `tool_call`/`tool_result` out of chat).
- For pi, finalized assistant text comes from `normalize(%{"type" => "message_end"} …)`
  (`lib/repo_builder/harness/pi.ex:176-194`), which calls
  `pi_text(message, "text")` → `join_blocks(message["content"], "text")`
  (`pi.ex:327-348`). `join_blocks/2` collects EVERY content block with `"type" => "text"`
  and joins their text.
- pi's `message_end` for a tool-using turn includes the tool-result content as a
  `type:"text"` block (confirmed indirectly: the persisted `text_delta` log-1839 is the
  exact `configure_tier` result, and persisted text deltas come only from `message_end`
  — partial `message_update` text deltas are broadcast-only, never persisted). So
  `join_blocks` harvests the tool-result echo as assistant text → `TextDelta` → chat.
- Net: tool results are surfaced twice — as the canonical `tool_result` event (correct,
  event-stream only) and as an assistant `TextDelta` (wrong, chat). The `tool_result`
  normalize clause (`pi.ex:218-229`) is correct; the leak is the `message_end` text
  harvest pulling in the same content.

(Claude path uses a different normalizer; verify it does not have the analogous harvest —
if Claude assistant messages keep tool results in `tool_result`/`tool_use` blocks only,
`join_blocks`-style harvesting won't affect it. Confirm in Step 1.)

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/pi.ex` — PRIMARY. `normalize(%{"type" => "message_end"}…)`
  (176-194), `pi_text/2` (327-336), `join_blocks/2` (338-348). Narrow the assistant-text
  harvest so tool-result-echo blocks are excluded. Also the `tool_execution_end` clause
  (218-229) is the correct path that already captures the result.
- `lib/repo_builder/harness/event.ex` — the canonical `Event.TextDelta` / `Event.ToolResult`
  shapes the normalizer emits (for reference; no change expected).
- `lib/repo_builder_web/live/console_live.ex` — the chat sink: finalized `TextDelta`
  handler attaches the `chat:` entry (orchestrator text → chat). Confirms that any
  `TextDelta` the normalizer emits will appear in chat; the fix must stop the bad
  `TextDelta` at the source. A defensive secondary guard could live here if normalizer
  discrimination proves unreliable.
- `lib/repo_builder/orchestrator/system_prompt.ex` — for the SECONDARY narration note
  only (instruct concise reporting / no tool-output echo); not the core fix.
- `test/repo_builder/harness/pi_normalize_test.exs` — existing pi normalizer tests; extend
  with the regression case.
- `BUILD_PROMPT.md` — §4 canonical harness event contract (TextDelta vs ToolResult), §4.3
  pi adapter; the fix must preserve the canonical event semantics.
- `.claude/commands/conditional_docs.md` — check for any harness/normalizer doc to include.

### New Files
- (Optional) `test/repo_builder_web/live/test_orchestrator_chat_tool_echo_test.exs` — a
  `Phoenix.LiveViewTest` that broadcasts an orchestrator `tool_result` + the offending
  `message_end`-derived events and asserts the chat shows the prose but NOT the tool-result
  JSON. Prefer extending `pi_normalize_test.exs` first (cheaper, deterministic); add the
  LiveView test if end-to-end coverage is wanted.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Capture the real pi frame (decisive diagnostic)
- Read `BUILD_PROMPT.md` §4/§4.3 and `.claude/commands/conditional_docs.md`.
- Capture a live raw pi `message_end` frame for a tool-using turn (Tidewave `get_logs`,
  or instrument `normalize/2` to log `raw` for `message_end`, or run a pi orchestrator
  turn and inspect the broadcast `raw`). Determine the EXACT structure of
  `message.content`: what `type` the tool-result-echo block has, and whether a genuine
  prose block coexists in the same `message_end`. This decides the discriminator.
- Confirm the Claude normalizer does not have the analogous leak (inspect a Claude
  `message`/assistant frame’s blocks).

### 2. Add a focused failing normalizer test (red)
- In `test/repo_builder/harness/pi_normalize_test.exs`, add a case using the real
  `message_end` shape from Step 1: assert `Pi.normalize/2` yields a `TextDelta` for the
  genuine prose block and NONE for the tool-result-echo block. (Also keep a case proving
  `tool_execution_end` still yields the `ToolResult`.) Run; confirm it fails today.

### 3. Narrow the assistant-text harvest in the pi normalizer
- In `pi.ex`, change the `message_end` text extraction so `join_blocks/2` (or a new
  guard in `pi_text/2`/`message_end`) excludes tool-result-echo blocks per Step 1's
  discriminator — e.g. only harvest blocks whose `type == "text"` AND that are not a
  tool result/echo (exclude `tool_result`/`toolResult`/`tool_use` types, or de-dup a
  `type:"text"` block whose content equals the turn's `tool_execution_end` result).
- Keep the `tool_execution_end` clause (218-229) unchanged — it remains the canonical
  tool-result event. Preserve all `@spec`s and the `{:ok, [Event.t()]} | :skip` contract.

### 4. (Secondary, note-only) reduce narration verbosity
- If desired, tighten `orchestrator/system_prompt.ex` to instruct concise reporting and
  no echoing of tool outputs/internal steps. Out of scope for the core fix; do only if
  explicitly requested.

### 5. Verify end-to-end
- Re-run the normalizer test (green). Optionally add/​run the LiveView chat test.
- Manually (Tidewave/browser): run a pi orchestrator turn; confirm the chat shows prose
  only and the tool-result JSON now appears solely in the center event stream
  (`tool_result` rows), de-duplicated.

### 6. Run the Validation Commands
- Run every command below; fix any failure introduced. Confirm the pre-existing erlexec
  spawn cases (now resolved) and the orchestrator-restriction tests remain green.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/harness/pi_normalize_test.exs` — the new regression case
  passes (tool-result echo no longer becomes assistant text; genuine prose still does).
- `mix test test/repo_builder_web/live/test_orchestrator_chat_tool_echo_test.exs` — if the
  optional LiveView test is added, the chat excludes tool-result JSON.
- `mix test test/repo_builder/harness/` — pi/claude normalizer + harness suites stay green.
- `mix compile --warnings-as-errors` — clean compile; gradual type checker + warnings gate.
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint passes (incl. `@spec` gate).
- `mix dialyzer` — no new contract warnings.

## Notes
- This is the pi-specific counterpart to the earlier chat/events-separation work: that
  change removed thinking + tool EVENTS from the chat; this one removes tool-result
  content that leaks back in through the TEXT channel via pi's `message_end` harvest.
- Keep the fix in the normalizer (source of truth for canonical events) rather than
  filtering JSON-shaped strings at the chat layer — string/JSON heuristics are fragile and
  would also hide legitimate prose that happens to contain JSON. Only fall back to a
  chat-layer guard if Step 1 shows pi gives no reliable structural discriminator.
- The narration verbosity (micro-step prose) is a separate, prompt-level concern; do not
  conflate it with this structural fix.
- No new dependencies; no schema/migration; DB-access boundary (§8) untouched.
```
