defmodule RepoBuilder.Agents.Holding do
  @moduledoc """
  Pure, harness-blind helpers for the worker HOLDING protocol
  (issue holding-status-for-blocked-agents).

  A worker that cannot proceed because it is blocked on an external/human action — a
  browser login, a credential, a manual step only a human can do — must NOT report
  success and must NOT be treated as failed. It is HELD: a clean, resumable stop. This
  module is the detection half of a **platform-detects / worker-acts** split that mirrors
  `RepoBuilder.Agents.Handover`:

    * the WORKER owns the *signal* — it ends its final message with the `:holding <reason>`
      token (`parse_signal/1`), taught to every spawned worker via `protocol_clause/0`;
    * the PLATFORM owns the *fallback* — a conservative phrase scan (`detect/1`) catches
      the original Playwright-login incident, where the worker did not know to signal, WITHOUT
      false-positiving on ordinary successful completions;
    * `classify/1` combines them (signal wins), the session runtime rewrites the terminal
      `Done` to `reason: :held_pending_input`, and the orchestrator Queue resumes it with
      `holding_resume_prompt/2` once the blocking condition clears.

  This module holds NO process state and touches NO harness or `Repo`: it is signal
  parsing, a phrase scan, and prompt text — so it is fully testable in isolation.
  """

  # The `:holding <reason>` final-message convention (NOT a canonical Event variant — a
  # lightweight text token so the protocol stays harness-agnostic, exactly like
  # `Handover`'s `:handover <path>`). Captures the REST of the line as the reason.
  @signal_regex ~r/:holding\s+(.+)/

  # A small, deliberately narrow set of "blocked on an external/human action" phrases.
  # Kept short so a normal successful completion is NEVER mis-flagged as holding (the
  # heuristic exists only to catch the original incident where the worker did not signal).
  # The matched phrase IS the surfaced reason. Compared case-insensitively.
  @holding_phrases [
    "waiting for you to log in",
    "log in to the browser",
    "requires a browser login",
    "please sign in",
    "authenticate in the browser",
    "manual login required"
  ]

  @doc """
  Parse the `:holding <reason>` signal from a worker's final message. Matches the LAST
  `:holding <reason>` token (a worker may quote the contract earlier), trims trailing
  punctuation/backticks, and returns `{:ok, reason}` with the rest of that line as the
  reason; `nil`/no match/empty reason ⇒ `:none`.
  """
  @spec parse_signal(String.t() | nil) :: {:ok, String.t()} | :none
  def parse_signal(text) when is_binary(text) do
    case Regex.scan(@signal_regex, text) do
      [] ->
        :none

      matches ->
        [_full, raw] = List.last(matches)

        case raw |> String.trim() |> String.replace(~r/[`.,;:)\]]+$/u, "") |> String.trim() do
          "" -> :none
          reason -> {:ok, reason}
        end
    end
  end

  def parse_signal(_text), do: :none

  @doc """
  Best-effort heuristic: scan the worker's terminal text for a small, documented set of
  "blocked on an external/human action" phrases (case-insensitive). Returns
  `{:ok, matched_phrase}` for the first phrase found, else `:none`. Deliberately
  conservative — see the `@holding_phrases` note — so normal completions never match.
  """
  @spec detect(String.t() | nil) :: {:ok, String.t()} | :none
  def detect(text) when is_binary(text) do
    downcased = String.downcase(text)

    case Enum.find(@holding_phrases, &String.contains?(downcased, &1)) do
      nil -> :none
      phrase -> {:ok, phrase}
    end
  end

  def detect(_text), do: :none

  @doc """
  Classify a worker's terminal text as holding: the explicit `:holding <reason>` signal
  first (`parse_signal/1`), then the conservative phrase heuristic (`detect/1`). The
  signal always wins. `:none` when neither is present.
  """
  @spec classify(String.t() | nil) :: {:ok, String.t()} | :none
  def classify(text) do
    case parse_signal(text) do
      {:ok, reason} -> {:ok, reason}
      :none -> detect(text)
    end
  end

  @doc """
  The worker-facing protocol clause appended to every spawned worker's system prompt, so
  every worker learns to signal a HOLDING stop instead of falsely reporting success when
  it is blocked on an external/human action.
  """
  @spec protocol_clause() :: String.t()
  def protocol_clause do
    """
    ## Blocked on external input (holding)
    If you cannot proceed because you are blocked on an external or human action — a
    browser login, a credential, an account approval, or any manual step that only a human
    can perform — do NOT report success and do NOT pretend the task is complete.

    1. State plainly, in your final message, what you are blocked on and what a human must
       do to unblock you.
    2. End your final message with EXACTLY `:holding <short reason>` on its own line
       (e.g. `:holding browser login required`), then STOP.

    You will be placed in a HOLDING state (NOT retired, NOT failed): your session is
    preserved. Once the blocking condition is resolved you will be resumed to continue from
    where you left off — do not start unrelated work in the meantime.
    """
    |> String.trim_trailing()
  end

  @doc """
  The orchestrator auto-resume turn for a worker that stopped in a HOLDING state: it names
  the worker + the blocking reason, makes clear it is BLOCKED (not done, not failed), is
  NOT deleted, and keeps its resumable session. Once the condition is cleared, resume it
  with `command_agent`; otherwise leave it holding.
  """
  @spec holding_resume_prompt(String.t(), String.t()) :: String.t()
  def holding_resume_prompt(name, reason) do
    "Worker \"#{name}\" is HOLDING — it stopped because it is blocked on an external or " <>
      "human action (#{reason}), NOT because it finished. It has NOT been deleted and its " <>
      "session is preserved. Once the blocking condition is resolved (e.g. the login is " <>
      "done), resume it with `command_agent` to continue from where it left off. If the " <>
      "condition is not yet cleared, leave it holding — do NOT delete it."
  end
end
