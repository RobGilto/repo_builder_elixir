defmodule RepoBuilder.Harness do
  @moduledoc """
  MANDATORY harness behaviour (BUILD_PROMPT.md §4.2).

  A minimal adapter implements ONLY these two callbacks — `command/1` and
  `normalize/2`. The generic erlexec session runtime (§6) provides spawning, line
  framing, stdin, interrupt, and termination uniformly. Everything downstream of
  `normalize/2` is harness-blind.

  An adapter that needs bespoke spawning ADDITIONALLY implements the optional
  `RepoBuilder.Harness.CustomSpawn` behaviour.
  """
  alias RepoBuilder.Harness.Event

  @typedoc """
  Options passed to `command/1`. `:sink` is the pid that receives canonical events
  / raw chunks; `:secrets` are runtime-resolved credentials (§6) — NEVER logged and
  NEVER placed in argv (visible in `ps`); the adapter puts them in the child `env`.
  """
  @type start_opts :: %{
          required(:prompt) => String.t(),
          required(:model) => String.t() | nil,
          required(:cwd) => Path.t(),
          required(:sink) => pid(),
          optional(:config) => map(),
          optional(:secrets) => map(),
          optional(:price_table) => map()
        }

  @typedoc "Adapter-private per-session context returned by command/1 and threaded into normalize/2."
  @type session_ctx :: term()

  @doc """
  Build the argv + env to spawn this harness in streaming-JSON mode, plus an
  adapter-private `session_ctx` threaded back into `normalize/2`. Pure; no side
  effects. Credentials come from `opts.secrets` and go in `env` — never argv,
  never logged.
  """
  @callback command(start_opts()) ::
              {exe :: String.t(), args :: [String.t()], env :: [{String.t(), String.t()}],
               session_ctx()}

  @doc """
  Normalize ONE raw decoded JSONL frame into zero-or-more canonical events.
  Must NEVER raise on a malformed/unknown frame; return `:skip` instead.
  """
  @callback normalize(raw :: map(), session_ctx()) ::
              {:ok, [Event.t()]} | :skip | {:error, term()}
end
