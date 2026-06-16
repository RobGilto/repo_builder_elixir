defmodule RepoBuilder.Orchestrator.Tools do
  @moduledoc """
  The orchestrator's agent-management tool LOGIC, implemented ONCE in harness-blind
  Elixir (issue-c). Every harness binding — Claude's native MCP, the pi extension,
  the in-process Fake loop — reaches this exact module, so tool behavior is
  identical regardless of harness.

  `call/3` is the single entry point: it dispatches a tool name to its handler,
  NEVER raises (every failure becomes `{:error, reason()}`), and logs each
  invocation as a `system_logs` row. Handlers drive only the platform's existing
  seams: `Agents`, `Session.Supervisor`, `WorkflowEngine`, `Logs`, and the
  `Dashboard` console feed.
  """
  alias RepoBuilder.{Agents, Logs, Orchestrators, Session, WorkflowEngine}
  alias RepoBuilder.Dashboard

  # Changeset failures are stringified at the boundary (`changeset_reason/1`), so a
  # reason that escapes a tool is always an atom or a string.
  @type reason :: atom() | String.t()
  @type result :: {:ok, map()} | {:error, reason()}

  @doc """
  Execute a single orchestrator tool. `tool` is a catalog name; `args` is the
  decoded JSON arguments map (string keys). Returns a normalized tagged tuple and
  never raises.
  """
  @spec call(String.t(), Ecto.UUID.t(), map()) :: result()
  def call(tool, orchestrator_id, args) when is_binary(tool) and is_map(args) do
    result = dispatch(tool, orchestrator_id, args)
    log_invocation(tool, orchestrator_id, args, result)
    result
  rescue
    error -> {:error, "tool crashed: #{Exception.message(error)}"}
  catch
    kind, value -> {:error, "tool #{kind}: #{inspect(value)}"}
  end

  def call(_tool, _orchestrator_id, _args), do: {:error, :invalid_arguments}

  # --- dispatch ---

  @spec dispatch(String.t(), Ecto.UUID.t(), map()) :: result()
  defp dispatch("create_agent", orchestrator_id, args), do: create_agent(orchestrator_id, args)
  defp dispatch("command_agent", orchestrator_id, args), do: command_agent(orchestrator_id, args)
  defp dispatch("list_agents", orchestrator_id, _args), do: list_agents(orchestrator_id)

  defp dispatch("check_agent_status", orchestrator_id, args),
    do: check_agent_status(orchestrator_id, args)

  defp dispatch("interrupt_agent", orchestrator_id, args),
    do: interrupt_agent(orchestrator_id, args)

  defp dispatch("start_adw", orchestrator_id, args), do: start_adw(orchestrator_id, args)
  defp dispatch(_tool, _orchestrator_id, _args), do: {:error, :unknown_tool}

  # --- tools ---

  @spec create_agent(Ecto.UUID.t(), map()) :: result()
  defp create_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      params = %{
        "name" => name,
        "harness" => harness,
        "model" => blank_to_nil(args["model"]),
        "system_prompt" => blank_to_nil(args["system_prompt"])
      }

      case Agents.create_worker(orchestrator_id, params) do
        {:ok, agent} ->
          _ = Dashboard.broadcast_agent_created(agent)

          {:ok,
           %{
             "id" => agent.id,
             "name" => agent.name,
             "harness" => agent.harness,
             "status" => to_string(agent.status)
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec command_agent(Ecto.UUID.t(), map()) :: result()
  defp command_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, prompt} <- fetch_string(args, "prompt"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      session_id = worker.session_id || generate_session_id()
      _ = Agents.set_session(worker.id, session_id)

      opts = [
        agent_id: worker.id,
        agent_db_id: worker.id,
        session_id: session_id,
        harness: worker.harness,
        prompt: prompt,
        model: worker.model
      ]

      case Session.Supervisor.start_session(opts) do
        {:ok, _pid} ->
          _ = Agents.set_status(worker.id, :running)
          {:ok, %{"status" => "dispatched", "agent_id" => worker.id, "name" => worker.name}}

        {:error, :at_capacity} ->
          {:error, :at_capacity}

        {:error, reason} ->
          {:error, normalize_reason(reason)}
      end
    end
  end

  @spec list_agents(Ecto.UUID.t()) :: result()
  defp list_agents(orchestrator_id) do
    workers =
      orchestrator_id
      |> Agents.list_for_orchestrator()
      |> Enum.map(
        &%{
          "id" => &1.id,
          "name" => &1.name,
          "harness" => &1.harness,
          "status" => to_string(&1.status),
          "model" => &1.model
        }
      )

    {:ok, %{"agents" => workers, "count" => length(workers)}}
  end

  @spec check_agent_status(Ecto.UUID.t(), map()) :: result()
  defp check_agent_status(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      limit = positive_int(args["limit"], 20)
      tail = worker.id |> Logs.list_recent(limit) |> Enum.map(&log_summary/1)
      cost = worker.id |> Logs.cost_rollup!() |> Decimal.to_string()

      {:ok,
       %{
         "id" => worker.id,
         "name" => worker.name,
         "status" => to_string(worker.status),
         "cost_usd" => cost,
         "recent_events" => tail
       }}
    end
  end

  @spec interrupt_agent(Ecto.UUID.t(), map()) :: result()
  defp interrupt_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      :ok = Session.Supervisor.interrupt(worker.id)
      {:ok, %{"status" => "interrupted", "name" => worker.name}}
    end
  end

  @spec start_adw(Ecto.UUID.t(), map()) :: result()
  defp start_adw(orchestrator_id, args) do
    with {:ok, input} <- fetch_string(args, "input"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      name = "orch-adw-#{System.unique_integer([:positive])}"

      with {:ok, workflow} <- WorkflowEngine.create_example_workflow(name, harness),
           {:ok, run_id, _pid} <-
             WorkflowEngine.start_workflow(workflow, inputs: %{"input" => input}) do
        {:ok, %{"status" => "started", "run_id" => run_id}}
      else
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_reason(changeset)}
        {:error, reason} -> {:error, normalize_reason(reason)}
      end
    end
  end

  # --- helpers ---

  @spec resolve_harness(Ecto.UUID.t(), map()) :: {:ok, String.t()} | {:error, reason()}
  defp resolve_harness(orchestrator_id, args) do
    case blank_to_nil(args["harness"]) do
      nil ->
        case Orchestrators.fetch(orchestrator_id) do
          {:ok, orchestrator} -> {:ok, orchestrator.harness}
          {:error, :not_found} -> {:error, :orchestrator_not_found}
        end

      harness ->
        {:ok, harness}
    end
  end

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp fetch_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  @spec log_summary(Logs.AgentLog.t()) :: map()
  defp log_summary(log) do
    %{"event_type" => to_string(log.event_type), "at" => to_iso(log.inserted_at)}
  end

  @spec to_iso(DateTime.t() | nil) :: String.t() | nil
  defp to_iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp to_iso(_other), do: nil

  @spec changeset_reason(Ecto.Changeset.t()) :: String.t()
  defp changeset_reason(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    case errors do
      %{name: [_ | _]} -> "duplicate or invalid name"
      _ -> "invalid agent: #{inspect(errors)}"
    end
  end

  @spec normalize_reason(term()) :: reason()
  defp normalize_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Inference-only spec — the lone caller passes the literal default 20, which
  # dialyzer narrows below a hand-written `pos_integer()` second arg.
  defp positive_int(n, _default) when is_integer(n) and n > 0, do: n
  defp positive_int(_n, default), do: default

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "worker-" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @spec log_invocation(String.t(), Ecto.UUID.t(), map(), result()) :: :ok
  defp log_invocation(tool, orchestrator_id, args, result) do
    {level, outcome} =
      case result do
        {:ok, _} -> {:info, "ok"}
        {:error, reason} -> {:warn, inspect(reason)}
      end

    _ =
      Logs.create_system_log(%{
        level: level,
        message: "orchestrator tool #{tool}: #{outcome}",
        metadata: %{
          "tool" => tool,
          "orchestrator_id" => orchestrator_id,
          "args" => redact_args(args)
        }
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Keep tool args out of the system log when they could carry a prompt body; we
  # log only the keys present, never the values (§4.1 spirit).
  @spec redact_args(map()) :: [String.t()]
  defp redact_args(args), do: Map.keys(args)
end
