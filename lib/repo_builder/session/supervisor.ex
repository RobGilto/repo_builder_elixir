defmodule RepoBuilder.Session.Supervisor do
  @moduledoc """
  Typed API over the application-started `RepoBuilder.SessionSupervisor`
  (a `DynamicSupervisor`), the `RepoBuilder.SessionRegistry`, and the
  `RepoBuilder.Session.Admission` gate (BUILD_PROMPT.md §5/§6).

  `start_session/1` acquires an admission slot, then starts a `:temporary`
  `Session.Server` child (releasing the slot if the start itself fails). All
  targeting (`stop`, `send_stdin`, `interrupt`) is by the registered agent id.
  """
  alias RepoBuilder.Budget
  alias RepoBuilder.Budget.Scope
  alias RepoBuilder.Prompts.SlashExpander
  alias RepoBuilder.Session.{Admission, Server}

  @sup RepoBuilder.SessionSupervisor
  @registry RepoBuilder.SessionRegistry

  @type start_error :: :at_capacity | {:budget_exceeded, Budget.Cap.t()} | term()

  @doc """
  Start a live session for `opts` (`:agent_id`, `:harness`, `:prompt`, and the
  optional `:session_id`/`:model`/`:config`/`:secrets`/`:agent_db_id`).

  Before acquiring an admission slot it consults the budget breaker
  (issue-budget-guardrails) for the session's scopes (global + any
  `:orchestrator_id`/`:workflow_run_id` in `opts`); a tripped `:pause`/`:hard_stop`
  cap refuses the start with `{:error, {:budget_exceeded, cap}}` (an `:alert` cap never
  refuses, preserving back-compat).
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, start_error()}
  def start_session(opts) do
    opts = expand_prompt(opts)

    case Budget.Guard.check(scopes_for(opts)) do
      :ok -> acquire_and_start(opts)
      {:error, _budget} = error -> error
    end
  end

  # Control-owned slash-command expansion (the single seam every live session passes
  # through). Rewrites `opts[:prompt]` so a `/command` invocation expands to its
  # `.claude/commands/<name>.md` body on EVERY interactive harness — fixing pi, which
  # has no native expansion. The `adw` harness is skipped: the portable Python ADW
  # engine performs its own `/plan→/build→…` dispatch in the target repo, so
  # pre-expanding would break it. A blank/nil prompt is left untouched.
  @spec expand_prompt(keyword()) :: keyword()
  defp expand_prompt(opts) do
    prompt = opts[:prompt]

    new_prompt =
      if to_string(opts[:harness]) == "adw" or blank?(prompt),
        do: prompt,
        else: SlashExpander.expand(prompt, opts[:cwd])

    Keyword.put(opts, :prompt, new_prompt)
  end

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  @spec acquire_and_start(keyword()) :: {:ok, pid()} | {:error, start_error()}
  defp acquire_and_start(opts) do
    case Admission.acquire() do
      :ok ->
        case DynamicSupervisor.start_child(@sup, {Server, opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Admission.release()
            {:ok, pid}

          {:error, reason} ->
            Admission.release()
            {:error, reason}
        end

      {:error, :at_capacity} = error ->
        error
    end
  end

  @spec scopes_for(keyword()) :: [Scope.scope_ref()]
  defp scopes_for(opts) do
    Scope.scopes_for(%{
      orchestrator_id: opts[:orchestrator_id],
      workflow_run_id: opts[:workflow_run_id]
    })
  end

  @doc "Stop a live session by agent id."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(agent_id) do
    case whereis(agent_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@sup, pid)
    end
  end

  @doc "Resolve the live session pid for an agent id, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Send data to a live session's stdin."
  @spec send_stdin(String.t(), iodata()) :: :ok
  def send_stdin(agent_id, data), do: Server.send_stdin(agent_id, data)

  @doc "Interrupt a live session (SIGTERM→SIGKILL of its child)."
  @spec interrupt(String.t()) :: :ok
  def interrupt(agent_id), do: Server.interrupt(agent_id)
end
