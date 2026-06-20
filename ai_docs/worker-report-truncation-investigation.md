# Investigation: worker report truncation (3 truncation points)

**Status:** read-only investigation. **Date:** 2026-06-20.
**Scope:** locate the three truncation points, identify the root cause of the broken
report *files*, and list the config knobs that control each.

## TL;DR

| # | Truncation point | Location | Limit | Configurable? | Is it the bug? |
|---|---|---|---|---|---|
| 1 | Orchestrator `final_message` 2000-char cap | `lib/repo_builder/orchestrator/tools.ex:34` (`@worker_text_cap 2_000`), applied at `:322` / `truncate_text/2` at `:1209` | 2000 chars | Hardcoded module attr | **No** — intentional, documented, has the spill-to-file recovery path |
| 2 | **Report FILE ends mid-sentence with `…[truncated]`** | `lib/repo_builder/harness/redact.ex:16-17,46-49` (`@max_blob_bytes 10_000` + `@truncated_suffix "…[truncated]"`), invoked from `lib/repo_builder/logs.ex:369` | **10 000 bytes** | Hardcoded module attr | **YES — this is the root cause** |
| 3 | `(see attached image)` placeholder | External to this repo: `@earendil-works/pi-ai` provider lib (`providers/openai-completions.js:778`, `mistral.js:489`, `google-shared.js:183`) | n/a (tool-result text placeholder) | No (vendored in node module) | **No** — not present in the current report files; harness-external |

The report *files* are broken because **`spill_report/4` writes text that has already
been amputated to 10 KB at persist time**. The 2000-char cap (point 1) and the
`(see attached image)` (point 3) are red herrings for the file-truncation symptom.

---

## 1. Orchestrator-side `final_message` 2000-char cap (intentional)

**File:** `lib/repo_builder/orchestrator/tools.ex`

```elixir
# :34
@worker_text_cap 2_000
```

Applied when `check_agent_status` builds its tool result:

```elixir
# :321-322
full = worker_final_message_with_log(logs)
final_message = full |> full_message_text() |> truncate_or_nil()
```

```elixir
# :1209-1212  (truncate_text/2)
defp truncate_text(text, cap) do
  if String.length(text) <= cap,
    do: text,
    else: String.slice(text, 0, cap) <> truncation_marker(cap)
end

# :1220-1222  (the exact suffix quoted in the bug report)
defp truncation_marker(cap),
  do:
    "… (truncated at #{cap} chars — read this result's `report_file` path for the full output, or ask the worker for an ai_docs/ file)"
```

- **Trigger:** `check_agent_status` tool invocation whenever a worker's final text > 2000 chars.
- **Limit:** 2000 **characters** (codepoint-based slice; `truncate_text/2`).
- **Configurable:** No — hardcoded module attribute `@worker_text_cap`. Interpolated into the
  worker system prompt (`worker_reporting_clause/0`, `:1108-1110`) so the doc limit tracks the
  enforced one.
- **Recovery path:** the truncated preview is paired with a `report_file` path
  (`maybe_spill_report/3` at `:333`) that is *supposed* to carry the full, untruncated text.
  That recovery path is itself broken — see §2.

---

## 2. Report-FILE truncation — THE ROOT CAUSE

### 2a. Where the report file is written

**File:** `lib/repo_builder/orchestrator/tools.ex`

```elixir
# :1147-1153  — spill is triggered only when text > @worker_text_cap (2000 chars)
@spec maybe_spill_report(Ecto.UUID.t(), Agents.Agent.t(), {String.t(), Logs.AgentLog.t()} | nil) ::
        String.t() | nil
defp maybe_spill_report(orchestrator_id, worker, {text, log}) do
  if String.length(text) > @worker_text_cap,
    do: spill_report(orchestrator_id, worker, text, log),
    else: nil
end

# :1163-1177  — writes `report_body(worker, text)` to ai_docs/worker-reports/<slug>-<log_no>.md
defp spill_report(orchestrator_id, worker, text, log) do
  working_dir = orchestrator_working_dir(orchestrator_id)
  root = working_dir || File.cwd!()
  rel = Path.join("ai_docs/worker-reports", report_filename(worker, log))
  abs = Path.join(root, rel)
  with :ok <- File.mkdir_p(Path.dirname(abs)),
       :ok <- File.write(abs, report_body(worker, text)) do
    if working_dir, do: rel, else: abs
  else
    {:error, _reason} -> nil
  end
end
```

`spill_report` itself applies **no length limit** — it writes whatever `text` it is handed.
The docstring (`:1140-1146`) explicitly claims it writes "the complete, untruncated text".

### 2b. The `text` it receives has already been truncated — the real culprit

The `text` comes from `worker_final_message_with_log/1` → `result_text/1`, which reads the
**persisted `agent_logs.payload`**:

```elixir
# tools.ex :1230-1238
defp result_text(%{event_type: :done, payload: payload}) when is_map(payload),
  do: blank_to_nil(payload["result"]) || blank_to_nil(payload["final_text"])

defp result_text(%{event_type: :text_delta, payload: payload}) when is_map(payload) do
  if payload["thinking"] == true, do: nil, else: blank_to_nil(payload["text"])
end
```

That persisted payload is built in `lib/repo_builder/logs.ex`, where the canonical assistant
text is run through the **secret-redaction scrubber** — and the scrubber also truncates any
binary blob over 10 000 bytes:

```elixir
# lib/repo_builder/logs.ex :367-373
# Persist the canonical text (+ thinking flag) rather than the raw harness frame …
defp event_payload(%Event.TextDelta{} = event, _raw) do
  Redact.scrub_term(%{"text" => event.text, "thinking" => event.thinking?})
end
defp event_payload(_event, raw), do: raw
```

```elixir
# lib/repo_builder/harness/redact.ex :16-17, 46-49
@max_blob_bytes 10_000
@truncated_suffix "…[truncated]"
…
def scrub_term(bin) when is_binary(bin) and byte_size(bin) > @max_blob_bytes do
  binary_part(bin, 0, @max_blob_bytes) <> @truncated_suffix
end
```

`Logs.persist_event/2` calls `Redact.scrub/1` first (`logs.ex:35`), so even the in-flight `raw`
fallback is capped; and the `TextDelta` branch (`:369`) runs the *canonical* `event.text`
through `scrub_term/1` directly. The full, unscrubbed text lives only on the live PubSub event
broadcast by `Session.Server.dispatch/2` — it is **never retained** in a form the spill path can
reach.

### 2c. Byte-count proof (matches the symptom exactly)

The three truncated report files are:

```
scout-adw-docs-7653.md      10055 bytes   ends: …[truncated]
scout-current-setup-7695.md 10060 bytes   ends: …[truncated]
scout-adw-docs-7747.md      10055 bytes   ends: …[truncated]
```

Report body format (`report_body/2`, tools.ex `:1186-1188`):
```
"# Worker report: #{worker.name} (#{worker.status})\n\n#{text}\n"
```

Header for these workers (`# Worker report: scout-adw-docs (idle)\n\n`) = **40 bytes**.
So `40 (header) + 10 000 (redact cap) + 14 ("…[truncated]") + 1 ("\n") = 10 055 bytes` ✓.
(`scout-current-setup` header is 45 bytes → 10 060 ✓.) The arithmetic is exact.

### 2d. Mechanism summary (the bug)

1. Worker (glm-5.2) streams a long final report.
2. `RepoBuilder.Harness.Pi` `message_end` normalizer (`pi.ex:234-256`) emits a finalized
   `Event.TextDelta{text: <full report>, partial?: false}`.
3. `Logs.persist_event/2` → `event_payload/2` (`logs.ex:369`) → `Redact.scrub_term/1`
   → text **truncated to 10 000 bytes + `…[truncated]`** before it ever hits the DB.
4. Later, `check_agent_status` → `worker_final_message_with_log/1` → `result_text/1`
   reads the already-truncated `payload["text"]`.
5. `spill_report/4` writes that already-truncated string to disk → the file ends
   mid-sentence with `…[truncated]`.

The spill path was designed to defeat the 2000-char cap, but its input is sourced *downstream*
of a tighter, earlier cap (10 KB) that predates it. So the "complete, untruncated" guarantee
in the docstring is false.

### 2e. Why the 10 KB cap exists

`@max_blob_bytes` is part of the secret-scrubbing layer (`redact.ex` moduledoc: "masks known
credential keys … AND truncates oversized blobs"). It guards the `raw` escape hatch against
dumping huge wire frames (screenshots, base64, long tool outputs) into `agent_logs.payload`.
The bug is that **`event_payload/2` routes the canonical `event.text` through the same scrubber**
— so the one field the spill needs at full fidelity is the one field that gets amputated.

---

## 3. `(see attached image)` placeholder (harness-external)

This string does **not exist anywhere in the repo_builder_elixir codebase** (`grep` over
`lib/`, `config/`, `deps/` returns nothing). It is emitted by the **`@earendil-works/pi-ai`**
provider library bundled inside the `pi` Node CLI that the Elixir app spawns as a subprocess.

Locations in the vendored node module (read-only, external to this repo):

```
…/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/providers/
  openai-completions.js:778   content: sanitizeSurrogates(hasText ? textResult : "(see attached image)")
  google-shared.js:183        … hasImages ? "(see attached image)" : "";
  mistral.js:489              return isError ? "[tool error] (see attached image)" : "(see attached image)";
  anthropic.js:103            text: "(see attached image)",
```

### 3a. What it actually is

It is a **tool-result text placeholder** (outbound, harness → provider), not an output-cap
fallback. From `openai-completions.js:766-780`:

```js
const toolMsg = transformedMessages[j];
const textResult = toolMsg.content.filter(isTextContentBlock).map(b=>b.text).join("\n");
const hasImages = toolMsg.content.some((c) => c.type === "image");
const hasText = textResult.length > 0;
const toolResultMsg = {
  role: "tool",
  content: sanitizeSurrogates(hasText ? textResult : "(see attached image)"),
  tool_call_id: toolMsg.toolCallId,
};
```

When a previous tool call returned **only image content (no text)**, the OpenAI-compatible
Chat Completions API requires a non-empty `content` string on the `tool` message, so the
provider substitutes `(see attached image)`. The `zai`/GLM provider inherits this
OpenAI-completions path (the GLM models route through `api: "openai-completions"` or
`"bedrock-converse-stream"` in `pi-ai/dist/models.generated.js`).

### 3b. Why it is not the file-truncation bug

- The three current report files end with `…[truncated]`, **not** with `(see attached image)`.
- The only occurrence of the phrase in `ai_docs/worker-reports/` is in
  `scout-adw-docs-7747.md` line 3, where the worker is *describing* the truncation it saw in
  *other* reports (meta-narrative), not where the placeholder was injected.
- The placeholder is emitted on the **tool-result** role, which `pi.ex` deliberately drops from
  the assistant-text channel (`pi.ex:230-235` skips `message_end` for `role: "toolResult"`).
- For it to leak into a worker's *final assistant* text, either (a) the glm model echoed the
  placeholder back verbatim, or (b) a prior run's aggregation differed. Either way it is a
  transient, harness/provider-side artifact, not a deterministic truncation in this codebase.

**Conclusion for point 3:** there is no Elixir code that injects `(see attached image)`. If it
reappears, the fix lives in the `pi-ai` provider lib (vendored) or in how image-only tool
results are surfaced to glm — out of scope for this repo except by upgrading the pi CLI / pi-ai
package.

---

## 4. Is a `max_tokens` / output cap the underlying cause? — **No.**

- The Elixir app passes **no** `max_tokens` / `--max-tokens` / output limit to the `pi`
  subprocess. Verified in `RepoBuilder.Harness.Pi.command/1` (`pi.ex:64-84`): the only spawn
  flags are `--mode json`, `--provider`, `--model`, `--approve`, thinking flags, and MCP flags.
- No `max_tokens` / `max_output_tokens` anywhere in `config/` or `lib/repo_builder/{harness,session}/`.
- The pi-ai model registry gives GLM-class models a large output budget
  (e.g. `zai.glm-5` → `maxTokens: 101376`, `models.generated.js:1658-1672`), so an
  output-token cap would not produce a deterministic cut at ~10 KB.
- The truncation lands at **exactly** 10 000 bytes + a 14-byte marker, byte-aligned — a token
  cap would land at a token boundary, not a fixed byte count. This fingerprint uniquely
  matches `Redact.scrub_term/1`'s `binary_part(bin, 0, @max_blob_bytes)`, not a model stop.

So D's hypothesis (model hits output cap → harness injects placeholder) does **not** explain
the broken files. The 10 KB byte-cap in `redact.ex` does.

---

## 5. Config knobs / fix surfaces

All current values and locations:

| Knob | Current | Location | Effect if changed |
|---|---|---|---|
| `@worker_text_cap` | `2_000` (chars) | `lib/repo_builder/orchestrator/tools.ex:34` | Only the API preview length. Raising it does **not** fix files (they're capped earlier at 10 KB). |
| `@max_blob_bytes` | `10_000` (bytes) | `lib/repo_builder/harness/redact.ex:17` | Raising it lets longer text survive into `agent_logs.payload` and therefore into the report file — but it also weakens the oversized-blob guard for *all* persisted events, and still imposes *some* ceiling. A targeted fix is preferable. |
| `@truncated_suffix` | `"…[truncated]"` | `lib/repo_builder/harness/redact.ex:16` | Cosmetic only. |
| `pi` model `maxTokens` | model-specific (e.g. glm-5 = 101376) | `pi-ai/dist/models.generated.js` (vendored, external) | Not the cause; do not touch for this bug. |

### Recommended fix directions (for the builder — not applied here)

The cleanest fixes target the **data source** mismatch, not the limits:

1. **Stop routing canonical `event.text` through `Redact.scrub_term/1`.** In
   `lib/repo_builder/logs.ex:367-373`, the `TextDelta`/text payload is the model's own
   assistant output — it carries no secrets. Apply secret-scrubbing only to `raw`
   (tool args, tool results, provider frames), and store `event.text` verbatim. This alone
   makes `spill_report` receive full-fidelity text and the file ends complete.
2. **Or: make `spill_report` source from the unscrubbed in-flight text.** Retain the worker's
   finalized `TextDelta` text (unscrubbed) on the session/dispatch path long enough for the
   spill to read it, instead of re-reading the truncated DB payload. Bigger change, keeps the
   10 KB DB guard intact.
3. **As a stopgap:** raise `@max_blob_bytes` for the canonical-text path only (e.g. exempt
   `event.text` from the byte cap while keeping it for `raw`). Lowest risk, smallest diff.

All three keep the intentional 2000-char `final_message` API cap and the `raw` redaction
intact; they only stop the recovery file from being fed pre-amputated text.

---

## 6. Evidence appendix — actual file tails

```
=== ai_docs/worker-reports/scout-adw-docs-7653.md (10055 bytes) ===
…review verdict (`ReviewResult` JSON), test results (`List[TestResult]`/`List[E2ETestResult]`), …[truncated]

=== ai_docs/worker-reports/scout-adw-docs-7747.md (10055 bytes) ===
…uv single-file header:
  ```python
  #!/usr/bin/env -S uv run
  # /// script
  # dependencies = ["python-dotenv", "pydantic"]
  # ///
  ```
- `mai…[truncated]

=== ai_docs/worker-reports/scout-current-setup-7695.md (10060 bytes) ===
…`adw_plan_w_scouts_build_review.py`: `STEPS = [scout_architecture /scout architecture, scout_tests /scout tests, pla…[truncated]
```

All three cut at 10 000 bytes of body text (header offsets account for the 10 055 / 10 060
totals). The two non-truncated reports in the same dir are short enough to never hit the cap:

```
demo-debugger-7191.md            8686 bytes   (ends cleanly, no marker)
prompt-builder-runner-7377.md    3753 bytes   (ends cleanly, no marker)
```

— which is consistent with the cap hypothesis (only >10 KB reports get amputated).
