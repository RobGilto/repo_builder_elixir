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
  alias RepoBuilder.{Agents, Logs, Orchestrators, Session, WorkflowEngine, Workflows}
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.Orchestrator

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
  defp dispatch("update_agent", orchestrator_id, args), do: update_agent(orchestrator_id, args)
  defp dispatch("delete_agent", orchestrator_id, args), do: delete_agent(orchestrator_id, args)

  defp dispatch("read_system_logs", _orchestrator_id, args), do: read_system_logs(args)

  defp dispatch("check_adw", _orchestrator_id, args), do: check_adw(args)
  defp dispatch("get_config", orchestrator_id, _args), do: get_config(orchestrator_id)

  defp dispatch("configure_tier", orchestrator_id, args),
    do: configure_tier(orchestrator_id, args)

  defp dispatch("set_orchestrator_config", orchestrator_id, args),
    do: set_orchestrator_config(orchestrator_id, args)

  defp dispatch(_tool, _orchestrator_id, _args), do: {:error, :unknown_tool}

  # --- tools ---

  @spec create_agent(Ecto.UUID.t(), map()) :: result()
  defp create_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, spec} <- resolve_agent_spec(orchestrator_id, args) do
      params = %{
        "name" => name,
        "harness" => spec.harness,
        "model" => spec.model,
        "system_prompt" => blank_to_nil(args["system_prompt"]),
        # The worker's `provider` column is a closed enum that can't hold pi's open
        # provider set, so the real provider rides in `config` and is threaded into
        # the session at command time.
        "config" => provider_config(spec.provider)
      }

      case Agents.create_worker(orchestrator_id, params) do
        {:ok, agent} ->
          _ = Dashboard.broadcast_agent_created(agent)

          {:ok,
           %{
             "id" => agent.id,
             "name" => agent.name,
             "harness" => agent.harness,
             "provider" => spec.provider,
             "model" => agent.model,
             "status" => to_string(agent.status)
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  # Resolve the worker's {harness, provider, model} from a `category` (the operator's
  # roster) when given, else from explicit args. A category with no assigned model is
  # rejected so the orchestrator can't silently spawn an un-runnable worker.
  @spec resolve_agent_spec(Ecto.UUID.t(), map()) ::
          {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t() | nil}}
          | {:error, reason()}
  defp resolve_agent_spec(orchestrator_id, args) do
    case blank_to_nil(args["category"]) do
      nil ->
        with {:ok, harness} <- resolve_harness(orchestrator_id, args) do
          {:ok,
           %{
             harness: harness,
             provider: blank_to_nil(args["provider"]),
             model: blank_to_nil(args["model"])
           }}
        end

      category ->
        resolve_category(orchestrator_id, category)
    end
  end

  @spec resolve_category(Ecto.UUID.t(), String.t()) ::
          {:ok, %{harness: String.t(), provider: String.t() | nil, model: String.t() | nil}}
          | {:error, reason()}
  defp resolve_category(orchestrator_id, category) do
    with {:ok, orchestrator} <- Orchestrators.fetch(orchestrator_id) do
      entry = Map.get(Orchestrators.agent_models(orchestrator), category, %{})

      case blank_to_nil(entry["model"]) do
        nil ->
          {:error, "no model selected for category #{category}"}

        model ->
          {:ok,
           %{
             harness: blank_to_nil(entry["harness"]) || orchestrator.harness,
             provider: blank_to_nil(entry["provider"]),
             model: model
           }}
      end
    end
  end

  # Inference-only spec — the concrete provider map narrows below a hand-written
  # `map()` spec, which Dialyzer rejects as a supertype under :underspecs.
  defp provider_config(nil), do: %{}
  defp provider_config(provider), do: %{"provider" => provider}

  @spec command_agent(Ecto.UUID.t(), map()) :: result()
  defp command_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, prompt} <- fetch_string(args, "prompt"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name),
         :ok <- ensure_worker_model(worker) do
      session_id = worker.session_id || generate_session_id()
      _ = Agents.set_session(worker.id, session_id)

      opts = [
        agent_id: worker.id,
        agent_db_id: worker.id,
        session_id: session_id,
        harness: worker.harness,
        prompt: prompt,
        model: worker.model,
        provider: worker_provider(worker)
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

  @spec update_agent(Ecto.UUID.t(), map()) :: result()
  defp update_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name),
         {:ok, params} <- worker_update_params(args) do
      case Agents.update_worker(worker, params) do
        {:ok, updated} ->
          {:ok,
           %{
             "id" => updated.id,
             "name" => updated.name,
             "harness" => updated.harness,
             "model" => updated.model,
             "status" => to_string(updated.status)
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec delete_agent(Ecto.UUID.t(), map()) :: result()
  defp delete_agent(orchestrator_id, args) do
    with {:ok, name} <- fetch_string(args, "name"),
         {:ok, worker} <- Agents.get_by_name_for_orchestrator(orchestrator_id, name) do
      # Reap any live session first so deleting the row leaves no orphaned child;
      # a worker with no live session returns `{:error, :not_found}`, ignored.
      _ = Session.Supervisor.stop_session(worker.id)

      case Agents.delete_agent(worker) do
        {:ok, _deleted} ->
          _ = Dashboard.broadcast_agent_deleted(worker)
          {:ok, %{"status" => "deleted", "id" => worker.id, "name" => worker.name}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec read_system_logs(map()) :: result()
  defp read_system_logs(args) do
    opts = [
      limit: positive_int(args["limit"], 50),
      offset: non_neg_int(args["offset"], 0),
      level: blank_to_nil(args["level"]),
      message_contains: blank_to_nil(args["message_contains"])
    ]

    logs = opts |> Logs.query_system_logs() |> Enum.map(&system_log_summary/1)
    {:ok, %{"logs" => logs, "count" => length(logs)}}
  end

  @spec check_adw(map()) :: result()
  defp check_adw(args) do
    with {:ok, raw} <- fetch_string(args, "run_id"),
         {:ok, run_id} <- ensure_uuid(raw) do
      case Workflows.get_run(run_id) do
        nil -> {:error, :not_found}
        run -> {:ok, run_summary(run)}
      end
    end
  end

  # --- self-configuration tools ---

  # Inference-only spec — the fully-concrete snapshot map narrows below the
  # hand-written `result()` contract, which Dialyzer rejects as a supertype under
  # :underspecs (mirrors `provider_config/1`).
  defp get_config(orchestrator_id) do
    with {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
      roster = Orchestrators.agent_models(orch)

      tiers =
        Map.new(Orchestrators.agent_categories(), fn category ->
          {category, tier_view(category, roster)}
        end)

      {:ok,
       %{
         "orchestrator" => %{
           "harness" => orch.harness,
           "provider" => orch.provider,
           "model" => orch.model
         },
         "tiers" => tiers,
         "harnesses" => Registry.known(),
         "available_models" => available_models(orch.harness)
       }}
    end
  end

  @spec configure_tier(Ecto.UUID.t(), map()) :: result()
  defp configure_tier(orchestrator_id, args) do
    with {:ok, category} <- fetch_string(args, "category"),
         {:ok, model} <- fetch_string(args, "model"),
         {:ok, harness} <- resolve_harness(orchestrator_id, args) do
      provider = blank_to_nil(args["provider"])
      attrs = %{"harness" => harness, "provider" => provider, "model" => model}

      case Orchestrators.set_agent_model(orchestrator_id, category, attrs) do
        {:ok, _orch} ->
          {:ok,
           %{
             "status" => "configured",
             "category" => category,
             "harness" => harness,
             "provider" => provider,
             "model" => model
           }}

        {:error, :invalid_category} ->
          {:error, "invalid category: #{category}"}

        {:error, :not_found} ->
          {:error, :orchestrator_not_found}
      end
    end
  end

  @spec set_orchestrator_config(Ecto.UUID.t(), map()) :: result()
  defp set_orchestrator_config(orchestrator_id, args) do
    harness = blank_to_nil(args["harness"])
    provider = blank_to_nil(args["provider"])
    model = blank_to_nil(args["model"])

    if is_nil(harness) and is_nil(provider) and is_nil(model) do
      {:error, "no config fields provided"}
    else
      # Apply in a fixed, safe order — harness first (it resets provider/model to the
      # harness defaults), then provider (resets model), then model last.
      with {:ok, _} <- apply_harness(orchestrator_id, harness),
           {:ok, _} <- apply_provider(orchestrator_id, provider),
           {:ok, _} <- apply_model(orchestrator_id, model),
           {:ok, orch} <- fetch_orchestrator(orchestrator_id) do
        {:ok, %{"harness" => orch.harness, "provider" => orch.provider, "model" => orch.model}}
      end
    end
  end

  @spec apply_harness(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_harness(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_harness(orchestrator_id, harness) do
    if harness in Registry.known() do
      route_config(Orchestrators.set_harness(orchestrator_id, harness))
    else
      {:error, "not a registered harness: #{harness}"}
    end
  end

  @spec apply_provider(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_provider(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_provider(orchestrator_id, provider),
    do: route_config(Orchestrators.set_provider(orchestrator_id, provider))

  @spec apply_model(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t() | :skip} | {:error, reason()}
  defp apply_model(_orchestrator_id, nil), do: {:ok, :skip}

  defp apply_model(orchestrator_id, model),
    do: route_config(Orchestrators.set_model(orchestrator_id, model))

  @spec route_config({:ok, Orchestrator.t()} | {:error, :not_found}) ::
          {:ok, Orchestrator.t()} | {:error, reason()}
  defp route_config({:ok, orch}), do: {:ok, orch}
  defp route_config({:error, :not_found}), do: {:error, :orchestrator_not_found}

  # Map the context's `:not_found` to the tool-layer `:orchestrator_not_found` reason
  # (mirrors `resolve_harness/2`).
  @spec fetch_orchestrator(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, reason()}
  defp fetch_orchestrator(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, orchestrator} -> {:ok, orchestrator}
      {:error, :not_found} -> {:error, :orchestrator_not_found}
    end
  end

  @spec tier_view(String.t(), %{optional(String.t()) => map()}) :: map()
  defp tier_view(category, roster) do
    entry = Map.get(roster, category, %{})
    model = blank_to_nil(entry["model"])

    %{
      "harness" => entry["harness"],
      "provider" => entry["provider"],
      "model" => model,
      "assigned" => not is_nil(model)
    }
  end

  # The available models for the orchestrator's harness: merge the live pi catalog
  # (empty in test/when pi is absent) with the static registry lists per provider.
  # Fail-soft: an empty map is a valid answer.
  @spec available_models(String.t()) :: %{String.t() => %{String.t() => [String.t()]}}
  defp available_models(harness) do
    pi_catalog = PiModels.all()

    providers =
      pi_catalog |> Map.keys() |> Enum.concat(registry_providers(harness)) |> Enum.uniq()

    by_provider =
      Map.new(providers, fn provider ->
        models =
          (Map.get(pi_catalog, provider, []) ++ Registry.orchestrator_models(harness, provider))
          |> Enum.uniq()

        {provider, models}
      end)

    %{harness => by_provider}
  end

  @spec registry_providers(String.t()) :: [String.t()]
  defp registry_providers(harness) do
    harness
    |> Registry.orchestrator_defaults()
    |> Map.get(:models, %{})
    |> Map.keys()
  end

  # --- helpers ---

  @spec ensure_worker_model(Agents.Agent.t()) :: :ok | {:error, reason()}
  defp ensure_worker_model(%{model: model, name: name}) do
    if blank_to_nil(model), do: :ok, else: {:error, "no model selected for #{name}"}
  end

  @spec worker_provider(Agents.Agent.t()) :: String.t() | nil
  defp worker_provider(%{config: config}), do: blank_to_nil(config["provider"])

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

  # Inference-only spec (mirrors `positive_int/2`): callers pass a literal default,
  # which dialyzer narrows below a hand-written `non_neg_integer()` second arg.
  defp non_neg_int(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n, default), do: default

  # Collect only the present, non-blank updatable worker fields; an empty change
  # set is rejected so an `update_agent` with only `name` is a no-op error.
  @spec worker_update_params(map()) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, reason()}
  defp worker_update_params(args) do
    params =
      %{}
      |> put_present("harness", blank_to_nil(args["harness"]))
      |> put_present("model", blank_to_nil(args["model"]))
      |> put_present("system_prompt", blank_to_nil(args["system_prompt"]))

    if params == %{}, do: {:error, "no updatable fields provided"}, else: {:ok, params}
  end

  # Inference-only spec — callers pass literal string keys, which dialyzer narrows
  # below a hand-written `String.t()` second arg (mirrors `positive_int/2`).
  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  @spec ensure_uuid(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, reason()}
  defp ensure_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid run_id"}
    end
  end

  @spec system_log_summary(Logs.SystemLog.t()) :: map()
  defp system_log_summary(log) do
    %{
      "id" => log.id,
      "level" => to_string(log.level),
      "message" => log.message,
      "at" => to_iso(log.inserted_at)
    }
  end

  @spec run_summary(Workflows.WorkflowRun.t()) :: map()
  defp run_summary(run) do
    %{
      "run_id" => run.id,
      "status" => to_string(run.status),
      "current_step" => run.current_step,
      # Preserve the unpriced (NULL) vs 0 distinction — nil stays nil, never "0".
      "cost_usd" => decimal_to_string(run.total_cost_usd),
      "artifacts" => run.artifacts
    }
  end

  @spec decimal_to_string(Decimal.t() | nil) :: String.t() | nil
  defp decimal_to_string(%Decimal{} = cost), do: Decimal.to_string(cost)
  defp decimal_to_string(_other), do: nil

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
