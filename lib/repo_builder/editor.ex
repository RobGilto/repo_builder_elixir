defmodule RepoBuilder.Editor do
  @moduledoc """
  Context for opening files in the operator's configured editor (Cursor / VS Code / etc).
  Validates the path is an absolute, existing regular file before shelling out.
  The editor command is config-driven — never derived from user/tool input — so it
  cannot become a command-injection sink.

  Disabled by default in `config/test.exs` so CI never shells out to an editor.

  ## Configuration

      config :repo_builder, :editor,
        enabled: true,
        command: ["cursor"]   # argv[0] = binary, rest = extra args before the path

  Runtime overrides via `RB_EDITOR_CMD` (space-split) and `RB_EDITOR_ENABLED` in
  `config/runtime.exs`.
  """

  @typedoc "Reason for failure."
  @type reason :: :disabled | :invalid_path | :not_found | {:exit, integer()}

  @doc """
  Open `path` in the configured editor.

  Validates that:
  - `path` is a binary.
  - `Path.type(path) == :absolute`.
  - `File.regular?(path)` — must be an existing regular file.
  - Editor integration is enabled in config.

  On success calls `System.cmd(cmd, extra_args ++ [path])` and returns `{:ok, path}`.
  Returns `{:error, reason()}` for any failure (never raises).
  """
  @spec open(String.t()) :: {:ok, String.t()} | {:error, reason()}
  def open(path) when is_binary(path) do
    with :ok <- check_enabled(),
         :ok <- validate_path(path) do
      run_editor(path)
    end
  end

  def open(_path), do: {:error, :invalid_path}

  # --- private ----------------------------------------------------------------

  @spec check_enabled() :: :ok | {:error, :disabled}
  defp check_enabled do
    cfg = Application.get_env(:repo_builder, :editor, [])

    if Keyword.get(cfg, :enabled, false) == true do
      :ok
    else
      {:error, :disabled}
    end
  end

  @spec validate_path(String.t()) :: :ok | {:error, :invalid_path | :not_found}
  defp validate_path(path) do
    cond do
      Path.type(path) != :absolute -> {:error, :invalid_path}
      not File.regular?(path) -> {:error, :not_found}
      true -> :ok
    end
  end

  @spec run_editor(String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp run_editor(path) do
    [cmd | extra_args] = editor_command()

    try do
      case System.cmd(cmd, extra_args ++ [path], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, path}
        {_output, code} -> {:error, {:exit, code}}
      end
    rescue
      _error -> {:error, {:exit, 127}}
    end
  end

  @spec editor_command() :: nonempty_list(String.t())
  defp editor_command do
    cfg = Application.get_env(:repo_builder, :editor, [])
    Keyword.get(cfg, :command, ["cursor"])
  end
end
