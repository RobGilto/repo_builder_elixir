# Worker report: scout-truncation (idle)

Investigation complete. Full findings written to **`ai_docs/worker-report-truncation-investigation.md`**.

## Summary — the three truncation points

**1. `final_message` 2000-char cap (intentional, NOT the bug)**
- `lib/repo_builder/orchestrator/tools.ex:34` — `@worker_text_cap 2_000`
- Applied at `:322` via `truncate_text/2` (`:1209`); suffix string built at `truncation_marker/1` (`:1220-1222`)
- Hardcoded module attr. Documented behavior with the spill-to-file recovery path.

**2. Report-FILE truncation — THE ROOT CAUSE**
- The `…[truncated]` marker comes from `lib/repo_builder/harness/redact.ex:16-17,46-49` (`@max_blob_bytes 10_000` + `@truncated_suffix "…[truncated]"`).
- It is applied to the canonical assistant text at **`lib/repo_builder/logs.ex:369`** — `event_payload/2` wraps `TextDelta` text in `Redact.scrub_term/1` *before persisting*.
- `spill_report/4` (`tools.ex:1163-1177`) writes **no cap of its own** — but it sources its text from `worker_final_message_with_log/1` → `result_text/1` (`:1230-1238`), which reads the **already-truncated DB payload**. The docstring's "complete, untruncated text" claim is false.
- **Byte proof:** the 3 files are 10 055 / 10 060 / 10 055 bytes = `40-byte header + 10 000 cap + 14-byte marker + 1 newline`. Exact match.

**3. `(see attached image)` (harness-external, NOT in this repo)**
- `grep` over `lib/`, `config/`, `deps/` → zero hits. It is emitted by the vendored `@earendil-works/pi-ai` provider lib: `providers/openai-completions.js:778` (plus `mistral.js:489`, `google-shared.js:183`, `anthropic.js:103`).
- It's a **tool-result text placeholder** (outbound harness→provider) when a tool returns only images — not an output-cap fallback. The current report files do **not** contain it (only `…[truncated]`); the lone mention in `scout-adw-docs-7747.md` is the worker *describing* the truncation.

## Key conclusions
- **Root cause (D):** Not a `max_tokens` issue. The Elixir app passes no output cap to `pi` (`command/1`, `pi.ex:64-84`); GLM models have huge budgets (`glm-5` → 101 376). A token cap wouldn't cut at a fixed byte boundary. The deterministic 10 KB byte-aligned cut fingerprints `Redact.scrub_term/1` exactly.
- **Best fix surface (E):** `lib/repo_builder/logs.ex:367-373` — stop running the model's own canonical `event.text` through `Redact.scrub_term/1` (it carries no secrets; scrubbing belongs only on `raw`). That single change restores full-fidelity text to `spill_report`. Knob `@max_blob_bytes` (`redact.ex:17`, currently `10_000`) is the cap itself; raising it globally is a weaker stopgap.
