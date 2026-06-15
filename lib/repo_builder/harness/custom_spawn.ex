defmodule RepoBuilder.Harness.CustomSpawn do
  @moduledoc """
  OPTIONAL harness behaviour (BUILD_PROMPT.md §4.2).

  Implement ONLY if an adapter must spawn/drive the child itself instead of using
  the generic erlexec runtime (§6). If absent, the runtime owns spawning, stdin,
  interrupt, and termination via the mandatory `RepoBuilder.Harness.command/1`.

  All four callbacks are `@optional_callbacks` so a minimal adapter (implementing
  only the mandatory behaviour) compiles cleanly under `--warnings-as-errors`.

  The stdin callback is `send_input/2`, deliberately NOT `send/2`, to avoid
  shadowing `Kernel.send/2` (matching the §6 runtime helper `send_stdin/2`).
  """

  @typedoc "Opaque, adapter-owned handle to a live harness child process."
  @type session :: term()

  @callback start_session(RepoBuilder.Harness.start_opts()) ::
              {:ok, session()} | {:error, term()}
  @callback send_input(session(), iodata()) :: :ok | {:error, term()}
  @callback interrupt(session()) :: :ok
  @callback terminate(session()) :: :ok

  @optional_callbacks start_session: 1, send_input: 2, interrupt: 1, terminate: 1
end
