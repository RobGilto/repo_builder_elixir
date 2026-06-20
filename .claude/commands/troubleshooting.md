---
description: Diagnose a symptom or error by reproducing it, isolating the root cause, and proposing a minimal fix for this Elixir, Phoenix, Ecto, and OTP codebase.
argument-hint: <symptom or error report>
---

# Purpose
Guide a structured, evidence-driven diagnosis of the symptom or error the operator reports. Move methodically through three phases — **reproduce** the failure reliably, **isolate its root cause** with hard evidence (logs, traces, DB state, typed return values), then **propose the minimal fix** that addresses the cause without introducing regressions. This is a general-purpose diagnostic aid for this repo's stack (Elixir / Phoenix / Ecto / OTP); it is deliberately not hardcoded to any single module.

## Variables

symptom: $1 — the error message, stack trace, or observed misbehavior to diagnose
  (the operator passes this as the command argument). If $1 is empty or ambiguous, stop
  and ask the operator to restate the symptom before proceeding.

## Instructions

- This is an Elixir / Phoenix / Ecto / OTP codebase. Reason about the failure in those
  terms first; do not reach for tooling or patterns from other ecosystems.
- Reproduce before you theorize. A failure you cannot reproduce is a failure you cannot
  confidently fix.
- Drive every claim with evidence: actual logs, stack traces, DB rows, compiler output, or
  typed return values — never intuition. Prefer the runtime intelligence already wired into
  this app (Tidewave over MCP: `get_logs` for real stacktraces, `project_eval` to reproduce
  a call in the live process, `execute_sql_query` to inspect the DB state behind the bug)
  over guesswork.
- Isolate the root cause, not the loudest symptom. Keep peeling layers (request → LiveView
  → context → Ecto query → DB; or message → GenServer/Task → supervisor → Registry) until
  you reach the line whose change makes the failure disappear.
- Propose the MINIMAL change that fixes the cause and prevents regressions. Do not refactor
  opportunistically while diagnosing.
- Respect the repo's enforced typed standard: preserve `@spec`s, `@enforce_keys`/
  `typedstruct` structs, precise types, and `{:ok, _} | {:error, reason}` tagged tuples over
  raising. Keep all DB access behind `@spec`'d context modules. The build runs
  `--warnings-as-errors`, `mix credo --strict`, and `mix dialyzer` — your proposed fix must
  keep all three green.
- Never present a fix as confirmed until you have shown the failing case reproduce-red (or
  explained precisely why it cannot be reproduced here) and reasoned about regressions.

## Expertise

Stack-specific failure signatures to check early — use these as hypotheses to confirm with
evidence, never as a shortcut past reproduction:

- **LiveView / HEEx:** an assign used before it is set; a `stream/3` item re-rendered without
  `stream_insert/3` after a toggling assign changes; `@form[:field]` vs raw changeset access;
  a missing `current_scope` (route not in the right `live_session`, or not passed to
  `<Layouts.app>`); `phx-update` misuse on a streamed collection.
- **Ecto:** a missing `preload` on an association read in a template; `validate_number/2`
  with a non-existent `:allow_nil` option; a programmatically-set field (`user_id`) listed in
  `cast/3` instead of set explicitly; `Changeset.get_field/2` vs struct dot-access on a
  changeset; a query missing `import Ecto.Query`.
- **OTP:** a `DynamicSupervisor`/`Registry` referenced without its registered name; a
  `Task.async_stream/3` missing `timeout: :infinity`; a GenServer crashing because a child
  spec lacks the required `name`; `Process.sleep/1`/`Process.alive?/1` misused for
  synchronization (prefer `Process.monitor/1` + `:sys.get_state/1`).
- **Compilation / types:** a failure only under `--warnings-as-errors` (an unused variable, a
  `mix format` drift, a Credo `Specs` violation); a Dialyzer contract that narrowed after a
  change; `String.to_atom/1` on user input.
- **HTTP:** anything still using `:httpoison`/`:tesla`/`:httpc` — this repo standardizes on
  `Req`; a migration of intent from another client is a common regression source.

## Workflow

1. **Capture the symptom.** Restate the reported failure in one sentence: what component,
   what input/trigger, what was expected, and what actually happened. If `$1` is empty or
   ambiguous, STOP and ask the operator to clarify before doing anything else.
2. **Reproduce.** Find the cheapest reliable reproduction. Prefer, in order: a focused ExUnit
   case, a `project_eval` call against the live app, or a `mix` task / `iex -S mix` snippet.
   Record the exact reproduction recipe. If it cannot be reproduced, say so explicitly and
   narrow the conditions under which it occurs.
3. **Gather evidence.** Pull the real stack trace (`get_logs`), the offending code
   (`get_source_location`/`get_docs` when a library boundary is involved), and the relevant DB
   state (`execute_sql_query`). Capture actual values, not assumptions.
4. **Form a falsifiable hypothesis.** State, in one line, the specific line/module/value you
   believe is wrong and WHY (map the evidence onto it). Design the smallest check that would
   prove it wrong.
5. **Isolate the root cause.** Confirm the hypothesis against the reproduction. If it does
   not hold, discard it and return to step 4 with the new evidence — do not patch around a
   symptom you have not root-caused.
6. **Propose the minimal fix.** Describe the smallest change that addresses the cause:
   which file(s), which function, what the diff is, and why it is sufficient. Note any
   regression risk and the test that would guard it.
7. **Validate.** List the commands that prove the fix and prove no regressions
   (`mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix credo --strict`,
   `mix dialyzer`), and the reproduction command that flips from red to green.

## Report

Return a concise diagnosis with exactly these sections:

- **Symptom:** one-sentence restatement of the reported failure.
- **Reproduction:** the exact recipe (or an explicit "could not reproduce" + the conditions
  that would).
- **Evidence:** the key log line / value / row that pinpoints the cause.
- **Root cause:** the specific line/module/value that is wrong, and why.
- **Minimal fix:** the smallest diff (file, function, change) and why it is sufficient.
- **Regression risk & guard:** what could break, and the test that protects it.
- **Validation commands:** the commands that prove the fix and prove no regressions.
