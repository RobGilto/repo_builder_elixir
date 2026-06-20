# Bug: Worker report files silently truncated at ~10KB by `Redact.scrub_term/1`

**Severity:** High — silently destroys worker output. The spilled report *files* appear to be
complete but are missing large sections, so orchestrators proceed on a false premise of
completeness and act on half-evidence. The recovery path designed to defeat truncation is
itself fed truncated input.

**Status:** Confirmed (read-only root-caused). Full investigation:
`ai_docs/worker-report-truncation-investigation.md`.

---

## Summary

Worker agent report files written to `ai_docs/worker-reports/*.md` are capped at ~10,000 bytes
of body text and terminated with a `…[truncated]` marker. The truncation happens because the
report-file writer (`spill_report/4`) sources its text from the **already-truncated DB
event-log payload** rather than the untruncated in-memory worker result.

The `Redact` 10KB cap (`@max_blob_bytes`) is a storage guard intended for the `raw` wire-frame
escape hatch. But `Logs.event_payload/2` routes the **canonical assistant text** through the
same scrubber at persistence time, and that capped text is what flows downstream into the
report file. The `spill_report/4` recovery path — built specifically to carry full output past
the orchestrator's 2000-char preview cap — therefore faithfully records amputated text.

---

## Reproduction

1. Dispatch a worker that produces a long final report — e.g. a scout summarizing multiple
   large `ai_docs/` files, well over 10KB of output.
2. Let the worker complete. Observe the report file written to
   `ai_docs/worker-reports/<worker-slug>-<log_no>.md`.
3. The file ends mid-sentence with `…[truncated]`.

To reproduce deterministically without a live run, dispatch any worker whose finalized
`Event.TextDelta.text` exceeds 10,000 bytes; the spill file will cut at exactly that boundary.

---

## Evidence — byte proof (deterministic)

Three affected files in `ai_docs/worker-reports/`:

| File | Size | Tail |
|---|---|---|
| `scout-adw-docs-7653.md` | 10,055 bytes | `…[truncated]` |
| `scout-adw-docs-7747.md` | 10,055 bytes | `…[truncated]` |
| `scout-current-setup-7695.md` | 10,060 bytes | `…[truncated]` |

`report_body/2` format is `"# Worker report: #{worker.name} (#{worker.status})\n\n#{text}\n"`.

- Header for `scout-adw-docs (idle)` = **40 bytes**: `40 + 10,000 (redact cap) + 14 ("…[truncated]") + 1 ("\n") = 10,055` ✓
- Header for `scout-current-setup (idle)` = **45 bytes**: `45 + 10,000 + 14 + 1 = 10,060` ✓

Control group — two reports that never hit the cap end cleanly (no marker):

| File | Size | Tail |
|---|---|---|
| `demo-debugger-7191.md` | 8,686 bytes | clean |
| `prompt-builder-runner-7377.md` | 3,753 bytes | clean |

The byte-aligned cut at exactly `@max_blob_bytes` (not a token boundary) uniquely fingerprints
`Redact.scrub_term/1`'s `binary_part(bin, 0, @max_blob_bytes)`.

---

## Root cause — data flow

1. Worker streams text deltas; the harness emits a finalized
   `Event.TextDelta{text: <full report>, partial?: false}`.
2. `Logs.event_payload/2` (`lib/repo_builder/logs.ex:369`) wraps each `TextDelta`'s canonical
   text in `Redact.scrub_term/1` **before persisting** to the `agent_logs` DB table.
3. `Redact.scrub_term/1` (`lib/repo_builder/harness/redact.ex:16-17,46-49`) caps any binary
   blob over `@max_blob_bytes 10_000` bytes and appends `@truncated_suffix "…[truncated]"`.
4. `spill_report/4` (`lib/repo_builder/orchestrator/tools.ex:1163-1177`) writes the report file
   with **no cap of its own**, but sources its text from `worker_final_message_with_log/1` →
   `result_text/1` (`:1230-1238`), which reads the **already-truncated DB payload**
   (`payload["text"]` / `payload["result"]`).
5. The report file therefore faithfully records the truncated text.

The full, unscrubbed text lives only on the live PubSub event broadcast by
`Session.Server.dispatch/2`; it is never retained in a form the spill path can reach. The
`spill_report/4` docstring advertises writing "the full message" (i.e. the complete worker
output) — that guarantee does not hold, because the `text` argument it receives is already
amputated upstream.

---

## What is NOT the cause (ruled out)

- **Model output cap / `max_tokens`:** Not the cause. The Elixir app passes no output cap to
  the `pi` harness (`Harness.Pi.command/1` spawns only `--mode`, `--provider`, `--model`,
  `--approve`, thinking, and MCP flags). GLM-class models support ~100K+ token output windows.
  A token cap would cut at a token boundary, not a deterministic byte-aligned 10KB.
- **`(see attached image)` placeholder:** Not present in the report files. It originates in the
  vendored `@earendil-works/pi-ai` provider library (`providers/openai-completions.js:778`,
  `mistral.js:489`, `google-shared.js:183`, `anthropic.js:103`) as a tool-result image
  placeholder (outbound harness→provider), not an output-cap fallback. The only mention of it
  in `ai_docs/worker-reports/` is a worker *describing* the truncation it observed (meta-
  narrative), not the placeholder being injected.
- **The orchestrator's 2000-char `final_message` cap** (`tools.ex:34`, `@worker_text_cap 2_000`):
  Intentional, documented behavior with a spill-to-file recovery path. This is the *signal* that
  pointed at the report file; it is not itself the bug. Raising it does not fix the files — they
  are capped earlier, tighter, at 10KB.

---

## Affected code locations

| Location | Role |
|---|---|
| `lib/repo_builder/harness/redact.ex:16-17` | `@max_blob_bytes 10_000` + `@truncated_suffix "…[truncated]"` |
| `lib/repo_builder/harness/redact.ex:46-49` | `scrub_term/1` binary-truncation clause |
| `lib/repo_builder/logs.ex:369` | `event_payload/2` routes canonical `TextDelta` text through the scrubber pre-persistence |
| `lib/repo_builder/orchestrator/tools.ex:1163-1177` | `spill_report/4` — writes the report file (sources from already-truncated payload) |
| `lib/repo_builder/orchestrator/tools.ex:1230-1238` | `result_text/1` / `worker_final_message_with_log/1` — reads the truncated DB payload |
| `lib/repo_builder/orchestrator/tools.ex:1163` | `spill_report/4` docstring — advertises "the full message" (inaccurate given pre-truncated input) |

---

## Suggested fix

**Primary (Option A — surgical, recommended):** Make `spill_report/4` (and
`worker_final_message_with_log/1`) source the report text from the **untruncated in-memory
worker result** (live session state / the finalized `TextDelta` retained on the dispatch path)
rather than re-reading the truncated DB payload. Report files then carry the complete output.
Keep the DB `Redact` cap as-is — it is a reasonable storage guard for `agent_logs.payload`.
Also correct the `spill_report/4` docstring so it no longer implies completeness it cannot
deliver from its current data source.

Equivalent targeted variant: in `logs.ex:367-373`, stop routing the canonical `event.text`
through `Redact.scrub_term/1` (assistant text carries no secrets); apply secret-scrubbing only
to `raw` (tool args, tool results, provider frames) and store `event.text` verbatim. This alone
restores full-fidelity text to the spill path.

**Secondary (Option B — safety net):** Raise `@max_blob_bytes` in `redact.ex` so the DB
payload and any other downstream consumer tolerate larger outputs. A band-aid on its own (it
still imposes *some* ceiling and weakens the oversized-blob guard for all persisted events);
pair with Option A.

Both options keep the intentional 2000-char `final_message` API cap and the `raw` redaction
intact; they only stop the recovery file from being fed pre-amputated text.

---

## Acceptance criteria

- A worker producing >10KB of output yields a report file containing the **full** output,
  ending at the natural end of the worker's message with no `…[truncated]` marker.
- The `agent_logs` DB row may remain capped (Redact is a storage guard), but the spilled report
  file must not inherit that cap.
- The `spill_report/4` docstring accurately describes the source of the text it writes.
- Existing short reports (<10KB) remain byte-identical (no regression in the control group).
