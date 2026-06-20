# Bug: Worker report files silently truncated at ~10 KB by `Redact.scrub_term/1`

## Metadata
issue_number: `n/a (filed from ai_docs/bug-reports/worker-report-truncation.md)`
adw_id: `n/a (manual /bug invocation)`
issue_json: `{"title":"Worker report files silently truncated at ~10KB by Redact.scrub_term/1","body":"Worker agent report files written to ai_docs/worker-reports/*.md are capped at ~10,000 bytes of body text and terminated with a …[truncated] marker. spill_report/4 sources its text from the already-truncated DB event-log payload rather than the untruncated in-memory worker result, because Logs.event_payload/2 routes the canonical assistant TextDelta text through Redact.scrub_term/1 (which caps any binary over @max_blob_bytes=10_000). The recovery path designed to defeat the 2000-char preview cap is therefore fed pre-amputated text. Severity: High — silently destroys worker output; orchestrators proceed on a false premise of completeness."}`

## Bug Description
Worker agent report files written to `ai_docs/worker-reports/<worker-slug>-<log_no>.md` are
silently capped at ~10,000 bytes of body text and terminated with a `…[truncated]` marker. The
spilled files *look* complete but are missing large trailing sections, so an orchestrator that
reads them proceeds on a false premise of completeness and acts on half-evidence.

**Expected:** a worker producing >10 KB of final output yields a report file containing the
**full** output, ending at the natural end of the worker's message with no truncation marker.

**Actual:** the file is cut at exactly `@max_blob_bytes` (10,000 bytes) of body text plus the
14-byte `…[truncated]` suffix, regardless of how much more the worker actually produced.

Byte proof from the live `ai_docs/worker-reports/` directory (see
`ai_docs/worker-report-truncation-investigation.md` §2c):

| File | Size | Tail |
|---|---|---|
| `scout-adw-docs-7653.md` | 10,055 bytes | `…[truncated]` |
| `scout-adw-docs-7747.md` | 10,055 bytes | `…[truncated]` |
| `scout-current-setup-7695.md` | 10,060 bytes | `…[truncated]` |

`report_body/2` = `"# Worker report: #{worker.name} (#{worker.status})\n\n#{text}\n"`. Header for
`scout-adw-docs (idle)` = 40 bytes → `40 + 10_000 + 14 + 1 = 10_055` ✓. The byte-aligned cut at
exactly the blob cap (not a token boundary) uniquely fingerprints
`Redact.scrub_term/1`'s `binary_part(bin, 0, @max_blob_bytes)`.

## Problem Statement
The canonical assistant text (`Event.TextDelta.text`) — the one field the worker-report spill
path needs at full fidelity — is the one field that gets amputated. `Logs.event_payload/2`
routes that text through `Redact.scrub_term/1` at persist time, and the scrubber truncates any
binary blob over `@max_blob_bytes` (10,000 bytes). `spill_report/4` later re-reads the persisted
(already-truncated) payload via `result_text/1`, so the report file faithfully records the
amputated text. The full, unscrubbed text exists only on the in-flight PubSub broadcast and is
never retained anywhere the spill path can reach.

## Solution Statement
**Option A (surgical, recommended and already applied in the working tree):** store
`Event.TextDelta.text` **verbatim** in `event_payload/2` instead of routing it through
`Redact.scrub_term/1`. The assistant text is the model's own flat-string output — it carries no
nested credential keys to mask — so exempting it from the scrubber is safe. The `raw` escape
hatch is still scrubbed in `persist_event/2`, so secret redaction and the oversized-blob storage
guard for wire frames are unaffected. `spill_report/4` then receives full-fidelity text and the
file ends complete. The `@worker_text_cap` 2000-char `final_message` API preview cap and its
spill-to-file recovery path are intentional and left untouched.

**Current state of the working tree (uncommitted — confirm and lock with tests):**
- `lib/repo_builder/logs.ex:376-378` already stores `%{"text" => event.text, "thinking" => …}`
  verbatim (was `Redact.scrub_term(...)`), with an explanatory comment citing this issue.
- `lib/repo_builder/orchestrator/tools.ex` docstrings (`spill_report/4`, `maybe_spill_report/3`,
  `truncation_marker/1`) already corrected to describe the verbatim source accurately.

**The real remaining gap:** the existing regression test
(`test/repo_builder/orchestrator/worker_report_truncation_test.exs`) only exercises an
`Event.Done` with a **5,000-char** `result` — under the 10 KB cap — so it would **not** have
caught this bug and does not lock the fix. This plan adds a regression test that drives a
`TextDelta` of **>10 KB** end-to-end (persist → `result_text/1` → `spill_report/4`) and asserts
the spilled file contains the complete text with no `…[truncated]`/`...[truncated]` marker, plus
a unit test pinning that `Redact.scrub_term/1` still caps oversized `raw` blobs (guard intact).

## Steps to Reproduce
1. Dispatch a worker that produces a long final report (a scout summarizing several large
   `ai_docs/` files), well over 10 KB of output.
2. Let the worker complete; observe `ai_docs/worker-reports/<worker-slug>-<log_no>.md`.
3. The file ends mid-sentence with `…[truncated]` at exactly ~10,055 bytes.

Deterministic, no live run: persist a finalized `Event.TextDelta{text: <binary > 10_000 bytes>,
partial?: false}` for a worker, then call `check_agent_status`; the spilled file cuts at the
blob boundary. (This is exactly the scenario the new regression test encodes.)

## Root Cause Analysis
Data flow (see `ai_docs/worker-report-truncation-investigation.md` §2):

1. Worker streams text deltas; `Harness.Pi`'s `message_end` normalizer emits a finalized
   `Event.TextDelta{text: <full report>, partial?: false}`.
2. `Logs.persist_event/2` → `event_payload/2` (`logs.ex:376`, pre-fix) wraps the canonical
   `event.text` in `Redact.scrub_term/1` **before persisting** to `agent_logs.payload`.
3. `Redact.scrub_term/1` (`redact.ex:39-41`) caps any binary over `@max_blob_bytes` (10,000) and
   appends `@truncated_suffix`.
4. `spill_report/4` (`tools.ex:1168-1180`) writes the report file with **no cap of its own**,
   but sources its text from `worker_final_message_with_log/1` → `result_text/1`
   (`tools.ex:1199-1205`), which reads the **already-truncated** `payload["text"]`.
5. The report file therefore records the truncated text.

The 10 KB cap (`@max_blob_bytes`) is a legitimate storage guard for the `raw` escape hatch
(screenshots, base64, huge tool frames). The bug is that `event_payload/2` routed the canonical
assistant text — which needs full fidelity — through that same blob-truncating scrubber.

**Ruled out** (per the investigation): the model `max_tokens`/output cap (the app passes none to
`pi`; a token cap would not land at a fixed byte boundary), the `(see attached image)`
placeholder (harness-external, not present in the files), and the intentional 2000-char
`@worker_text_cap` `final_message` preview (raising it does not fix files capped earlier at 10 KB).

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/logs.ex` — `event_payload/2` (`:365-380`); the `Event.TextDelta` clause must
  store `event.text` verbatim (NOT via `Redact.scrub_term/1`). This is the single behavioral fix.
- `lib/repo_builder/harness/redact.ex` — `@max_blob_bytes 10_000`, `@truncated_suffix`,
  `scrub_term/1` binary clause (`:15-16,39-43`). Unchanged by the fix, but its oversized-blob
  guard over `raw` must be preserved and pinned by a test (no regression to secret/blob scrubbing).
- `lib/repo_builder/orchestrator/tools.ex` — `spill_report/4` (`:1166-1180`), `maybe_spill_report/3`
  (`:1147-1155`), `result_text/1` (`:1199-1207`), and their docstrings. Docstrings already
  corrected in the working tree to describe the verbatim source; verify they remain accurate.
- `test/repo_builder/orchestrator/worker_report_truncation_test.exs` — existing regression suite;
  extend it (or add the new file below) with a `TextDelta` >10 KB end-to-end case.
- `test/repo_builder/harness/redact_test.exs` — existing redaction unit tests; confirm the
  oversized-`raw`-blob truncation assertion still holds after the fix.

Conditional docs (from `.claude/commands/conditional_docs.md`):
- `ai_docs/typed-elixir-standard.md` — the always row (changing any public function/struct/spec).
- `BUILD_PROMPT.md` §4 (event contract) + §4.1 (redaction) + §6 (secrets) — harness event
  normalization and `raw` redaction boundary.
- `BUILD_PROMPT.md` §13 — FakeHarness / persistence test conventions.

### New Files
- `test/repo_builder/orchestrator/worker_report_full_fidelity_test.exs` — a focused regression
  test proving a finalized `Event.TextDelta` whose text exceeds `@max_blob_bytes` (10 KB) is
  persisted verbatim and spilled in full, with no `…[truncated]`/`...[truncated]` marker.
  (Alternatively, add these cases to the existing `worker_report_truncation_test.exs`; a separate
  file keeps the >10 KB / verbatim concern isolated and named for the bug.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the behavioral fix is present in `logs.ex`
- Verify `lib/repo_builder/logs.ex` `event_payload/2`'s `%Event.TextDelta{}` clause returns
  `%{"text" => event.text, "thinking" => event.thinking?}` **without** `Redact.scrub_term/1`.
- Verify the explanatory comment above it cites the issue and notes that `raw` is still scrubbed
  in `persist_event/2` (secret redaction unaffected). If the working-tree change is missing or
  partially reverted, re-apply exactly this one-line change.
- Confirm no other `event_payload/2` clause (e.g. `Event.Error`) was loosened — only the
  canonical `TextDelta` text is exempted; `Error` payloads and the `raw` fallback stay scrubbed.

### 2. Confirm the docstrings describe the verbatim source
- In `lib/repo_builder/orchestrator/tools.ex`, verify `spill_report/4` and `maybe_spill_report/3`
  docstrings state the text comes from the verbatim canonical payload (not the 10 KB-capped
  scrub) and that the file carries the worker's complete output. Correct any residual wording
  that still implies the old (truncated) source.

### 3. Add the end-to-end >10 KB regression test
- Create `test/repo_builder/orchestrator/worker_report_full_fidelity_test.exs`
  (`use RepoBuilder.SessionCase, async: false`, `@tag :tmp_dir`), mirroring the helpers in
  `worker_report_truncation_test.exs` (`orchestrator/0`, `create_worker/2`, `persist/2`).
- Persist a finalized **`Event.TextDelta`** (NOT `Event.Done`) whose `text` is a unique,
  verifiable binary **larger than 10,000 bytes** — e.g.
  `long = String.duplicate("Z", 12_000) <> "END-OF-REPORT-SENTINEL"`. Use `partial?: false` /
  `thinking?: false` so it is treated as canonical final assistant text.
- Call `Tools.call("check_agent_status", orch.id, %{"name" => name})` and assert:
  - `result["report_file"]` is a non-absolute path under `ai_docs/worker-reports/`.
  - the spilled body (`File.read!`) **contains the full `long` string including the trailing
    sentinel** — proving no 10 KB amputation.
  - the body does **not** contain `"…[truncated]"` nor `"...[truncated]"`.
  - `byte_size(body) > 12_000` (sanity: the file is larger than the old 10 KB cap).
- Add a complementary assertion at the persistence boundary: after `persist/2`, read the worker's
  latest `:text_delta` log and assert `payload["text"]` equals `long` verbatim (no marker) — this
  pins the `logs.ex` fix directly, independent of the spill path.
- Confirm this test **fails** if the `Redact.scrub_term/1` wrapper is reintroduced in `logs.ex`
  (temporarily re-add it locally, watch it fail, then revert) — this is the bug-reproducing assertion.

### 4. Pin the redaction guard (no regression)
- In `test/repo_builder/harness/redact_test.exs`, confirm the existing "truncates oversized blobs"
  test still asserts that a >`@max_blob_bytes` binary inside a scrubbed `raw` map is truncated and
  carries `@truncated_suffix`. If it is keyed to the old `…` suffix, align it with the current
  `"...[truncated]"` value in `redact.ex`. This proves the storage guard for `raw` is intact and the
  fix only exempted the canonical `event.text` path.

### 5. Run the full validation gate
- Run every command in `Validation Commands` and ensure zero failures, zero new warnings, and a
  clean format/credo/dialyzer pass.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/orchestrator/worker_report_full_fidelity_test.exs` — the new >10 KB
  end-to-end regression test passes (full text spilled, no truncation marker).
- `mix test test/repo_builder/orchestrator/worker_report_truncation_test.exs` — the existing spill
  regression suite still passes (no regression to the 2000-char preview cap / spill recovery path).
- `mix test test/repo_builder/harness/redact_test.exs` — secret scrubbing and the oversized-`raw`
  blob guard still hold.
- `mix compile --warnings-as-errors` — compile clean; the gradual set-theoretic type checker and
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed cases) with zero failures.
- `mix format --check-formatted` — code is formatted.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

Reproduction before/after: re-adding `Redact.scrub_term/1` around the `TextDelta` payload in
`logs.ex` makes the new test fail (spilled body cut at ~10 KB with the truncation suffix);
removing it again (the fix) makes it pass (full text, no marker).

## Notes
- No new dependencies. The change is one line of behavior in `logs.ex` plus tests and docstrings.
- The fix deliberately leaves three intentional mechanisms intact: (1) the 2000-char
  `@worker_text_cap` `final_message` API preview with its spill-to-file recovery, (2) the `raw`
  escape-hatch redaction in `persist_event/2`, and (3) the `@max_blob_bytes` oversized-blob guard
  for wire frames. Only the canonical assistant text is exempted from the byte cap.
- Out of scope / follow-up note for the developer: `result_text/1` for `:done` events reads
  `payload["result"]`, which (for `Event.Done`) is the **scrubbed `raw`** and would still cap a
  >10 KB result. Real worker reports arrive as finalized `TextDelta` (per the harness normalizer),
  so this is not the observed bug; if a future worker surfaces its full report via a `Done`
  `result` field instead, the same exemption reasoning would apply to that path. Do not widen scope
  here unless a `Done`-path truncation is actually reproduced.
- Runtime verification available via Tidewave (`http://localhost:4000/tidewave/mcp`): use
  `project_eval` to round-trip a >10 KB `Event.TextDelta` through `Logs.persist_event/2` and read
  the stored `payload["text"]` back, and `execute_sql_query` to inspect the `agent_logs` row's
  payload length directly.
- This bug is at the `Orchestrator.Tools`/persistence boundary, not the LiveView UI, so no
  `Phoenix.LiveViewTest` integration test is required (the new test exercises the Tools boundary).
