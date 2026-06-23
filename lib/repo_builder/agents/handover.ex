defmodule RepoBuilder.Agents.Handover do
  @moduledoc """
  Pure, harness-blind helpers for the graceful worker handover protocol
  (issue graceful-agent-handover-on-context-limit).

  When an orchestrator-spawned worker approaches the end of its usable context window
  it must wind down gracefully rather than degrade or silently overflow. The protocol
  splits responsibilities **platform-detects / worker-acts**:

    * the PLATFORM owns the *trigger* — it knows real occupancy (`ContextWindow.size/2`
      + the latest `usage` row) and decides when a worker crossed `threshold/0`, then
      issues a one-shot `[WIND DOWN — CONTEXT LIMIT]` directive (`wind_down_prompt/1`);
    * the WORKER owns the *content* — it writes a handover document to
      `ai_docs/<name>-handover.md` (receipt of the original ask + achieved + remaining)
      and ends its final message with the `:handover <path>` token (`parse_signal/1`);
    * the platform then *reaps* the worker and tells the orchestrator it was retired
      (`retired_resume_prompt/2`, or `forced_retire_resume_prompt/1` when the worker
      ignored the directive and returned without a doc).

  This module holds NO process state and touches NO harness: the threshold comes from
  config, occupancy delegates to `RepoBuilder.Orchestrator.ContextWindow`, and the rest
  is signal parsing and prompt text — so it is fully testable in isolation.
  """

  alias RepoBuilder.Orchestrator.ContextWindow

  # Fallback when no `:handover_threshold` is configured. Mirrors config/config.exs.
  @default_threshold 0.8

  # The `:handover <path>` final-message convention (NOT a canonical Event variant —
  # a lightweight text token so the protocol stays harness-agnostic; see the spec Notes).
  @signal_regex ~r/:handover\s+(\S+)/

  @doc """
  The handover occupancy threshold (a fraction in `0.0..1.0`). Reads
  `config :repo_builder, :orchestrator, :handover_threshold` (default `0.8`). Shared by
  the wind-down decision and `report_cost`'s high-usage warning so they never drift.
  """
  @spec threshold() :: float()
  def threshold do
    case Application.get_env(:repo_builder, :orchestrator, [])[:handover_threshold] do
      f when is_float(f) and f > 0 -> f
      _absent -> @default_threshold
    end
  end

  @doc """
  Context-window occupancy (`context_tokens / window`) for a worker, delegating to
  `ContextWindow.usage_fraction/3`. A nil/unknown harness yields `0.0` (the wind-down
  never fires spuriously when the window is unknown).
  """
  @spec occupancy(String.t() | nil, String.t() | nil, non_neg_integer()) :: float()
  def occupancy(harness, model, context_tokens)
      when is_binary(harness) and is_integer(context_tokens) and context_tokens >= 0 do
    ContextWindow.usage_fraction(context_tokens, harness, model)
  end

  def occupancy(_harness, _model, _context_tokens), do: 0.0

  @doc "Whether `fraction` has reached the handover threshold (inclusive at the boundary)."
  @spec over_threshold?(float()) :: boolean()
  def over_threshold?(fraction) when is_float(fraction), do: fraction >= threshold()
  def over_threshold?(_fraction), do: false

  @doc """
  Parse the `:handover <path>` signal from a worker's final message. Matches the LAST
  `:handover <path>` token (a worker may quote the contract earlier), trims trailing
  punctuation/backticks, and returns `{:ok, path}`; `nil`/no match/empty path ⇒ `:none`.
  """
  @spec parse_signal(String.t() | nil) :: {:ok, String.t()} | :none
  def parse_signal(text) when is_binary(text) do
    case Regex.scan(@signal_regex, text) do
      [] ->
        :none

      matches ->
        [_full, raw] = List.last(matches)

        case raw |> String.trim() |> String.replace(~r/[`.,;:)\]]+$/u, "") do
          "" -> :none
          path -> {:ok, path}
        end
    end
  end

  def parse_signal(_text), do: :none

  @doc """
  The one-shot `[WIND DOWN — CONTEXT LIMIT]` directive turn sent to a worker that
  crossed the threshold. Restates the `original_ask` (the receipt) verbatim when present
  so the worker can quote it, and states the `ai_docs/<name>-handover.md` layout +
  the `:handover <path>` final-message contract.
  """
  @spec wind_down_prompt(String.t() | nil) :: String.t()
  def wind_down_prompt(original_ask) do
    """
    [WIND DOWN — CONTEXT LIMIT]

    You are approaching the end of your usable context window. You cannot reliably count
    your own tokens, so trust this signal: wind down NOW and hand your work over cleanly
    instead of starting new work.
    #{original_ask_block(original_ask)}
    Do this, in order:
    1. Write a handover document to `ai_docs/<descriptive-name>-handover.md` in the working
       directory. Begin it with a header that is a RECEIPT of the original ask (quote it
       verbatim), then an "## Achieved" section (what you completed) and a "## Remaining"
       section (what is left to do, in enough detail that a FRESH worker can continue).
    2. End your reply with EXACTLY this token, on its own line:
       `:handover <relative-path-to-doc>` (e.g. `:handover ai_docs/elixir-port-handover.md`).
    3. STOP. Do not start any new work after emitting the `:handover` signal — you will be
       retired once it is seen.
    """
    |> String.trim_trailing()
  end

  @doc """
  The orchestrator auto-resume turn after a worker handed over: it states the worker was
  retired (deleted), links its handover doc, and tells the orchestrator to read the doc
  and spawn a fresh worker to continue if the task isn't done.
  """
  @spec retired_resume_prompt(String.t(), String.t()) :: String.t()
  def retired_resume_prompt(name, doc_path) do
    "Worker \"#{name}\" reached its context limit, performed a graceful handover, and " <>
      "HAS BEEN RETIRED (deleted) — do NOT try to `command_agent` or `check_agent_status` " <>
      "it again. Its handover document is at `#{doc_path}` (a receipt of the original ask " <>
      "+ what it achieved + what remains). To continue the task, READ that document and " <>
      "spawn a FRESH worker seeded with it if the work isn't finished."
  end

  @doc """
  The orchestrator auto-resume turn for a worker that was issued a wind-down directive but
  returned WITHOUT writing a handover doc — force-retired so it can't get stuck over budget.
  """
  @spec forced_retire_resume_prompt(String.t()) :: String.t()
  def forced_retire_resume_prompt(name) do
    "Worker \"#{name}\" reached its context limit and was issued a wind-down directive, " <>
      "but returned WITHOUT writing a handover document. It HAS BEEN RETIRED (deleted) to " <>
      "avoid running over budget — do NOT try to `command_agent` or `check_agent_status` it " <>
      "again. Re-dispatch a FRESH worker if its task still needs to be completed."
  end

  @doc """
  The worker-facing protocol clause appended to every spawned worker's system prompt, so
  every worker learns how to recognize a `[WIND DOWN]` directive, the
  `ai_docs/<name>-handover.md` layout, and the `:handover <path>` contract.
  """
  @spec protocol_clause() :: String.t()
  def protocol_clause do
    """
    ## Context-limit handover
    If you receive a turn beginning with `[WIND DOWN — CONTEXT LIMIT]`, the platform has
    detected you are near the end of your usable context window. You cannot reliably count
    your own tokens, so trust this signal. When you see it:

    1. Write a handover document to `ai_docs/<descriptive-name>-handover.md` in the working
       directory. Start it with a header that is a RECEIPT of the original ask (quote the
       request verbatim), then an "## Achieved" section (what you completed) and a
       "## Remaining" section (what is left, in enough detail for a fresh worker to continue).
    2. End your final message with EXACTLY `:handover <relative-path>`
       (e.g. `:handover ai_docs/elixir-port-handover.md`).
    3. STOP — do NOT keep working after emitting `:handover`. You will be retired (your
       session reaped) once the signal is seen; a fresh worker continues from your document.
    """
    |> String.trim_trailing()
  end

  # The receipt block interpolated into the wind-down directive; cleanly omitted when no
  # original ask was recorded.
  @spec original_ask_block(String.t() | nil) :: String.t()
  defp original_ask_block(original_ask) when is_binary(original_ask) do
    trimmed = String.trim(original_ask)

    if trimmed == "" do
      ""
    else
      "\nThe original ask you were dispatched with (your receipt — quote it in the doc header):\n\n> #{trimmed}\n"
    end
  end

  defp original_ask_block(_original_ask), do: ""
end
