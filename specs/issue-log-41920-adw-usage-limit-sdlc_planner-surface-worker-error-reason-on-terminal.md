# Bug: Worker usage-limit errors are invisible to the orchestrator — it re-dispatches a doomed pi worker instead of switching harness

## Metadata
issue_number: `log-41920`
adw_id: `usage-limit`
issue_json: `n/a — freeform bug report; reference logs log-41920 to log-42046`

## Bug Description

When a harness provider's per-session usage limit is exhausted (e.g. the `zai` provider behind the `pi` harness emits a `429 Usage limit reached for 5 hour` error), pi's `auto_retry` mechanism retries three times, all fail, and pi normalizes the terminal as `%Event.Error{reason: :auto_retry_exhausted, retryable: false, message: "429 Usage limit reached..."}`.

The `Session.Server` broadcasts a `worker_terminal` event with `ok?: false` but **does not include the error reason or message** in the payload. The `Queue.auto_resume_prompt/2` therefore only knows "Worker X finished with errors" — the specific cause is invisible to the orchestrator.

**Observed behavior (logs 41920–42046):**
- Worker `autocomplete-impl` (pi/zai) hits the 429 usage limit, exits with `auto_retry_exhausted` (log 41933).
- The Queue sends the orchestrator a generic "Worker autocomplete-impl finished with errors and returned" resume prompt.
- The orchestrator (now running on Claude) reads the prompt, concludes "recurring pi-harness flakiness" (log 41948), and dispatches a **new pi worker** (`gate-fixer`) to retry.
- That new worker immediately hits the **same** 429 usage limit (logs 41960+).
- The cycle repeats; no work completes during the 5-hour limit window.

**Expected behavior:**
- The `worker_terminal` broadcast includes the terminal error's `reason` and `message`.
- The auto-resume prompt surfaced to the orchestrator explicitly names the cause: "Worker X failed because: 429 Usage limit reached for 5 hour — the pi/zai usage limit is exhausted."
- The orchestrator can now make an informed decision: switch the workers to a different harness (claude, or a different pi provider), wait for the limit to reset, or escalate.

## Problem Statement

`Session.Server.maybe_emit_worker_terminal/2` only extracts `final_text` from terminal events — and only from `%Event.Done{}` (via `terminal_text/1`). For `%Event.Error{}` events (which carry the usage-limit message) it emits `final_text: nil`, discarding the actionable failure context.

`Queue.auto_resume_prompt/2` maps `ok?: false` to the generic phrase "finished with errors" with no error detail. The orchestrator brain has no signal to distinguish a hard usage-limit exhaustion from transient flakiness, and re-dispatches into the same dead end.

## Solution Statement

Two minimal, surgical changes:

1. **`Session.Server`** — in `maybe_emit_worker_terminal/2`, extract the error reason and message from `%Event.Error{}` terminal events and add `error_reason` and `error_message` fields to the broadcast payload. Extend `terminal_text/1` to also return the error message for `%Event.Error{}` so both fields arrive in `final_text` (for the dedup/handover path) and in the new typed fields (for orchestrator routing).

2. **`Queue`** — in `auto_resume_prompt/2` (the generic `ok?: false` branch), prepend the error detail when `error_message` is present in the info map, so the orchestrator prompt reads: "Worker X **failed** and returned. **Error: 429 Usage limit reached for 5 hour — the pi usage limit is exhausted.** Consider switching workers to a different harness or provider. Review and decide next steps…". No new routing branch is needed; a clear, machine-readable sentence in the prompt is sufficient — the orchestrator brain already knows how to act on explicit information.

## Steps to Reproduce

1. Configure worker agents to use the `pi` harness with the `zai` provider.
2. Set a goal and dispatch workers until the zai 5-hour usage quota is exhausted (or simulate by temporarily injecting a hard error into pi's normalize path).
3. Observe the Queue's auto-resume prompt — it says only "finished with errors" with no error context.
4. Observe the orchestrator re-dispatching a new pi/zai worker that immediately fails again.

## Root Cause Analysis

**Path A — data discarded at broadcast time (`Session.Server`):**

```elixir
# lib/repo_builder/session/server.ex
defp terminal_text(%Event.Done{final_text: text}) when is_binary(text), do: text
defp terminal_text(_event), do: nil  # ← Event.Error{message: "429…"} returns nil
```

And in `maybe_emit_worker_terminal/2`:
```elixir
RepoBuilder.Dashboard.broadcast_worker_terminal(orchestrator_id, %{
  ...
  final_text: terminal_text(event),   # nil for Error events
  holding?: holding?,
  ...
})
```
`%Event.Error{message: "429 Usage limit reached...", reason: :auto_retry_exhausted}` exists in `event` but nothing carries it forward.

**Path B — context-free re-engage prompt (`Queue`):**

```elixir
# lib/repo_builder/orchestrator/queue.ex
defp auto_resume_prompt(_orchestrator_id, info) do
  name = Map.get(info, :name) || "a worker"
  outcome = if Map.get(info, :ok?), do: "completed successfully", else: "finished with errors"
  base = "Worker #{name} #{outcome} and returned. Review its work and decide the next steps..."
  prepend_resume_context(orchestrator_id, info, base)
end
```

`outcome` is `"finished with errors"` — no mention of WHY. The orchestrator receives this and guesses "flakiness".

**Combined effect:** The orchestrator has no way to know the failure is a hard quota exhaustion that will block every pi/zai worker until the reset time. It re-dispatches into the same dead end.

## Relevant Files

- **`lib/repo_builder/session/server.ex`** — `maybe_emit_worker_terminal/2` (line ~946) and `terminal_text/1` (line ~1089). The fix adds error extraction here.
- **`lib/repo_builder/orchestrator/queue.ex`** — `auto_resume_prompt/2` (line ~1022). The fix includes error context in the resume prompt here.
- **`lib/repo_builder/harness/event.ex`** — `%Event.Error{}` struct definition. Referenced only; no changes needed — the existing `message` and `reason` fields are what we surface.
- **`lib/repo_builder/dashboard.ex`** — `broadcast_worker_terminal/2` (line ~264). The payload type annotation and doc may need a minor update to document the new optional fields.
- **`ai_docs/typed-elixir-standard.md`** — always-required typed standard reference.

### New Files

- **`test/repo_builder_web/live/test_usage_limit_worker_terminal_test.exs`** — LiveView integration test that:
  1. Spawns a fake pi worker that emits `%Event.Error{reason: :auto_retry_exhausted, message: "429 Usage limit reached"}` as its terminal event.
  2. Asserts the auto-resume prompt delivered to the orchestrator contains both the error reason and the error message.

## Step by Step Tasks

### Task 1 — Extend `terminal_text/1` to extract message from `%Event.Error{}`

In `lib/repo_builder/session/server.ex`, add a clause for `%Event.Error{}`:

```elixir
# Before:
defp terminal_text(%Event.Done{final_text: text}) when is_binary(text), do: text
defp terminal_text(_event), do: nil

# After:
defp terminal_text(%Event.Done{final_text: text}) when is_binary(text), do: text
defp terminal_text(%Event.Error{message: msg}) when is_binary(msg) and msg != "", do: msg
defp terminal_text(_event), do: nil
```

This ensures the error message lands in `final_text` (already broadcast) so the handover/holding detection path also sees it.

### Task 2 — Add `error_reason` and `error_message` fields to the `worker_terminal` broadcast

Still in `lib/repo_builder/session/server.ex`, in `maybe_emit_worker_terminal/2`, extract error fields from the terminal event before broadcasting:

```elixir
RepoBuilder.Dashboard.broadcast_worker_terminal(orchestrator_id, %{
  worker_id: agent_id,
  name: name,
  ok?: ok?,
  context_tokens: state.context_tokens,
  final_text: terminal_text(event),
  holding?: holding?,
  holding_reason: holding_reason(event),
  workstream_id: worker_workstream_id(agent_id),
  # New: error reason + message for failed workers (nil for ok? true)
  error_reason: worker_error_reason(event),
  error_message: worker_error_message(event)
})
```

Add two private helpers after `terminal_text/1`:

```elixir
@spec worker_error_reason(Event.t()) :: atom() | nil
defp worker_error_reason(%Event.Error{reason: reason}), do: reason
defp worker_error_reason(_event), do: nil

@spec worker_error_message(Event.t()) :: String.t() | nil
defp worker_error_message(%Event.Error{message: msg}) when is_binary(msg) and msg != "", do: msg
defp worker_error_message(_event), do: nil
```

### Task 3 — Include error detail in the Queue's auto-resume prompt

In `lib/repo_builder/orchestrator/queue.ex`, update the generic `auto_resume_prompt/2` fallback clause (the `ok?: false` path) to prepend the error detail when present:

```elixir
# Before:
defp auto_resume_prompt(_orchestrator_id, info) do
  name = Map.get(info, :name) || "a worker"
  outcome = if Map.get(info, :ok?), do: "completed successfully", else: "finished with errors"
  base = "Worker #{name} #{outcome} and returned. Review its work and decide the next steps " <>
    "(report back, dispatch follow-up work, or stop)."
  prepend_resume_context(orchestrator_id, info, base)
end

# After:
defp auto_resume_prompt(orchestrator_id, info) do
  name = Map.get(info, :name) || "a worker"

  base =
    if Map.get(info, :ok?) do
      "Worker #{name} completed successfully and returned. Review its work and decide the next " <>
        "steps (report back, dispatch follow-up work, or stop)."
    else
      error_detail = worker_error_detail(info)
      "Worker #{name} failed and returned.#{error_detail} Review the failure and decide the " <>
        "next steps: retry with a different harness/model/provider if the error is a " <>
        "provider-level limit or exhaustion, or investigate and fix the root cause."
    end

  prepend_resume_context(orchestrator_id, info, base)
end

@spec worker_error_detail(map()) :: String.t()
defp worker_error_detail(info) do
  msg = Map.get(info, :error_message)
  reason = Map.get(info, :error_reason)

  cond do
    is_binary(msg) and msg != "" ->
      " Error (#{reason}): #{msg}."

    is_atom(reason) and not is_nil(reason) ->
      " Error reason: #{reason}."

    true ->
      ""
  end
end
```

### Task 4 — Update `dashboard.ex` doc/type for `broadcast_worker_terminal/2`

In `lib/repo_builder/dashboard.ex`, update the `@spec` and `@doc` for `broadcast_worker_terminal/2` to document the new optional `error_reason` and `error_message` fields in the info map:

```elixir
@spec broadcast_worker_terminal(Ecto.UUID.t(), %{
        required(:worker_id) => String.t(),
        required(:ok?) => boolean(),
        optional(:name) => String.t() | nil,
        optional(:context_tokens) => non_neg_integer(),
        optional(:final_text) => String.t() | nil,
        optional(:holding?) => boolean(),
        optional(:holding_reason) => String.t() | nil,
        optional(:workstream_id) => Ecto.UUID.t() | nil,
        optional(:error_reason) => atom() | nil,
        optional(:error_message) => String.t() | nil
      }) :: :ok
```

### Task 5 — Write the integration test

Create `test/repo_builder_web/live/test_usage_limit_worker_terminal_test.exs`:

The test should:
1. Set up an orchestrator with auto-resume enabled.
2. Simulate a pi worker emitting `%Event.Error{reason: :auto_retry_exhausted, message: "429 Usage limit reached for 5 hour. Your limit will reset at 2026-07-02 21:28:56", harness: :pi}` as its terminal event via `Dashboard.broadcast_worker_terminal/2` with the new fields populated (or test via `Session.Server` path with a FakeHarness that returns this error).
3. Assert that the `Queue` auto-resume prompt delivered to the orchestrator contains:
   - The error reason (`:auto_retry_exhausted`)
   - The error message fragment ("Usage limit reached")
   - The word "harness/model/provider" (the decision prompt)
4. Assert the prompt does NOT say only "finished with errors" without the error detail.

Use `RepoBuilder.OrchestratorCase` (or `RepoBuilder.DataCase`) for DB access and a stubbed Queue starter to capture the prompt without spawning a real harness session.

### Task 6 — Run validation commands

Run all validation commands listed below in sequence.

## Validation Commands

```sh
# Run the new targeted test first — should pass after the fix, fail before
mix test test/repo_builder_web/live/test_usage_limit_worker_terminal_test.exs

# Full suite — zero regressions
mix test --warnings-as-errors

# Compile clean (gradual types + warnings-as-errors)
mix compile --warnings-as-errors

# Format check
mix format --check-formatted

# Credo strict (every public function has @spec)
mix credo --strict

# Dialyzer — no new warnings, no stale ignores
mix dialyzer
```

## Notes

- **The fix is prompt-only — no harness routing change.** Automatically switching a worker to a different harness/model on usage-limit exhaustion would require the platform to maintain a harness-preference fallback list (model switcher). That is a follow-on feature. The current bug is that the orchestrator brain cannot see the error reason at all; once it can, it can make the switch decision itself using `create_agent` with a different harness/model.

- **`auto_retry_exhausted` vs `rate_limit`**: The pi harness currently uses `reason: :auto_retry_exhausted` for ALL failed retry exhaustions, not just usage limits. A finer `reason: :usage_limit` variant could be added to `%Event.Error{}` in the future by inspecting the `finalError` message for "429 Usage limit" in `Harness.Pi.normalize/2`. This plan defers that; surfacing the raw `message` is sufficient for the orchestrator to act on.

- **`get_logs` tool gap (secondary)**: The user also noted the orchestrator "did not read the logs." This is a brain behavior issue (the orchestrator should use `get_logs` to diagnose worker failures), not a platform bug. The fix here makes the diagnosis unnecessary: the resume prompt delivers the error detail directly.

- **Tested harness**: The `FakeHarness` in `test/support/` should already produce `%Event.Error{}` events; the new test can use it with a custom error message injected via its config.
