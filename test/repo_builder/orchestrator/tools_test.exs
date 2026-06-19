defmodule RepoBuilder.Orchestrator.ToolsTest do
  @moduledoc """
  Unit tests for the harness-blind orchestrator tool logic (issue-c). Workers run
  on the keyless Fake harness; the Repo is the test sandbox. Covers each tool's
  happy path plus its `{:error, reason}` branches (unknown agent, duplicate name,
  unknown harness, unknown tool).
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Orchestrators, Workflows}
  alias RepoBuilder.Orchestrator.{Templates, Tools}

  defp uniq, do: System.unique_integer([:positive])

  # Drain spawned worker/workflow sessions before the sandbox owner exits so they
  # don't crash on a torn-down connection or leak events into a later test.
  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp orchestrator(harness \\ "fake") do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: harness})
    orch
  end

  describe "create_agent" do
    test "creates a worker scoped to the orchestrator and broadcasts agent_created" do
      :ok = RepoBuilder.Dashboard.subscribe_events()
      orch = orchestrator()
      name = "worker-#{uniq()}"

      assert {:ok, result} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert result["name"] == name
      assert result["harness"] == "fake"
      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.orchestrator_id == orch.id
      assert_receive {:agent_created, %{name: ^name}}
    end

    test "defaults the harness from the orchestrator when omitted" do
      orch = orchestrator("fake")
      name = "worker-#{uniq()}"

      assert {:ok, %{"harness" => "fake"}} =
               Tools.call("create_agent", orch.id, %{"name" => name})
    end

    test "missing name is an error" do
      orch = orchestrator()
      assert {:error, _reason} = Tools.call("create_agent", orch.id, %{"harness" => "fake"})
    end

    test "category resolves the worker's harness/provider/model from the roster" do
      orch = orchestrator("fake")

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "heavy", %{
          "harness" => "fake",
          "provider" => "minimax",
          "model" => "MiniMax-M3"
        })

      name = "heavy-#{uniq()}"

      assert {:ok, result} =
               Tools.call("create_agent", orch.id, %{"name" => name, "category" => "heavy"})

      assert result["model"] == "MiniMax-M3"
      assert result["provider"] == "minimax"

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.model == "MiniMax-M3"
      # The open provider rides in config (the enum column can't hold it).
      assert worker.config["provider"] == "minimax"
    end

    test "a category with no assigned model is rejected" do
      orch = orchestrator("fake")

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "fast", %{"harness" => "fake", "model" => ""})

      assert {:error, reason} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "x-#{uniq()}",
                 "category" => "fast"
               })

      assert reason =~ "no model selected for category fast"
    end

    test "duplicate name within one orchestrator is rejected" do
      orch = orchestrator()
      name = "dup-#{uniq()}"

      assert {:ok, _} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:error, _reason} =
               Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})
    end

    test "the same name under a DIFFERENT orchestrator is allowed" do
      name = "shared-#{uniq()}"
      a = orchestrator()
      b = orchestrator()
      assert {:ok, _} = Tools.call("create_agent", a.id, %{"name" => name, "harness" => "fake"})
      assert {:ok, _} = Tools.call("create_agent", b.id, %{"name" => name, "harness" => "fake"})
    end

    test "unknown harness is rejected (harness openness preserved via registry)" do
      orch = orchestrator()

      assert {:error, _reason} =
               Tools.call("create_agent", orch.id, %{"name" => "x-#{uniq()}", "harness" => "nope"})
    end
  end

  describe "subagent templates" do
    setup do
      original = Application.get_env(:repo_builder, :orchestrator)
      tmp = Path.join(System.tmp_dir!(), "rb_tools_templates_#{uniq()}")
      File.mkdir_p!(tmp)
      Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :agents_dir, tmp))

      on_exit(fn ->
        Application.put_env(:repo_builder, :orchestrator, original)
        File.rm_rf(tmp)
      end)

      :ok
    end

    test "save_agent_template persists a version readable by Templates.fetch and list" do
      name = "reviewer-#{uniq()}"

      assert {:ok, %{"status" => "saved", "version" => 1}} =
               Tools.call("save_agent_template", orchestrator().id, %{
                 "name" => name,
                 "description" => "Reviews diffs.",
                 "system_prompt" => "You review code."
               })

      assert {:ok, template} = Templates.fetch(name)
      assert template.author == :orchestrator
      assert template.body == "You review code."

      assert {:ok, %{"templates" => templates}} =
               Tools.call("list_agent_templates", orchestrator().id, %{})

      assert Enum.any?(templates, &(&1["name"] == name))
    end

    test "get_agent_template returns the current body + frontmatter" do
      name = "scout-#{uniq()}"

      {:ok, _} =
        Tools.call("save_agent_template", orchestrator().id, %{
          "name" => name,
          "description" => "Scouts.",
          "system_prompt" => "Find things.",
          "category" => "fast"
        })

      assert {:ok, view} = Tools.call("get_agent_template", orchestrator().id, %{"name" => name})
      assert view["body"] == "Find things."
      assert view["category"] == "fast"
    end

    test "create_agent with subagent_template applies the body+model and records provenance" do
      orch = orchestrator()
      template_name = "tw-#{uniq()}"

      {:ok, _} =
        Tools.call("save_agent_template", orch.id, %{
          "name" => template_name,
          "description" => "Writes tests.",
          "system_prompt" => "You write ExUnit tests.",
          "model" => "fake-model-7"
        })

      worker_name = "worker-#{uniq()}"

      assert {:ok, %{"model" => "fake-model-7"}} =
               Tools.call("create_agent", orch.id, %{
                 "name" => worker_name,
                 "harness" => "fake",
                 "subagent_template" => template_name
               })

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, worker_name)
      # The reporting clause (issue-2541) is appended to every worker prompt.
      assert worker.system_prompt =~ "You write ExUnit tests."
      assert worker.system_prompt =~ "Reporting results"
      assert worker.config["template_name"] == template_name
      assert worker.config["template_version"] == 1
    end

    test "an explicit system_prompt overrides the template body" do
      orch = orchestrator()
      template_name = "ov-#{uniq()}"

      {:ok, _} =
        Tools.call("save_agent_template", orch.id, %{
          "name" => template_name,
          "description" => "Default.",
          "system_prompt" => "template body"
        })

      worker_name = "worker-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => worker_name,
          "harness" => "fake",
          "subagent_template" => template_name,
          "system_prompt" => "explicit override"
        })

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, worker_name)
      assert worker.system_prompt =~ "explicit override"
      assert worker.system_prompt =~ "Reporting results"
    end

    test "an unknown subagent_template returns a helpful error" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("create_agent", orch.id, %{
                 "name" => "worker-#{uniq()}",
                 "harness" => "fake",
                 "subagent_template" => "does-not-exist"
               })

      assert reason =~ "unknown subagent_template does-not-exist"
    end
  end

  describe "list_agents" do
    test "lists only this orchestrator's workers" do
      a = orchestrator()
      b = orchestrator()

      {:ok, _} =
        Tools.call("create_agent", a.id, %{"name" => "a1-#{uniq()}", "harness" => "fake"})

      {:ok, _} =
        Tools.call("create_agent", b.id, %{"name" => "b1-#{uniq()}", "harness" => "fake"})

      assert {:ok, %{"agents" => [_], "count" => 1}} = Tools.call("list_agents", a.id, %{})
    end
  end

  describe "command_agent" do
    test "dispatches to a known worker and persists its resume session id" do
      orch = orchestrator()
      name = "cmd-#{uniq()}"

      {:ok, _} =
        Tools.call("create_agent", orch.id, %{
          "name" => name,
          "harness" => "fake",
          "model" => "fake-model-1"
        })

      assert {:ok, %{"status" => "dispatched", "name" => ^name}} =
               Tools.call("command_agent", orch.id, %{"name" => name, "prompt" => "do it"})

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert is_binary(worker.session_id)
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("command_agent", orch.id, %{"name" => "ghost", "prompt" => "x"})
    end

    test "missing prompt is an error" do
      orch = orchestrator()
      name = "cmd2-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})
      assert {:error, _reason} = Tools.call("command_agent", orch.id, %{"name" => name})
    end
  end

  describe "check_agent_status" do
    test "returns status, cost, and a recent-event tail" do
      orch = orchestrator()
      name = "stat-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, result} = Tools.call("check_agent_status", orch.id, %{"name" => name})
      assert result["name"] == name
      assert is_binary(result["cost_usd"])
      assert is_list(result["recent_events"])
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("check_agent_status", orch.id, %{"name" => "ghost"})
    end
  end

  describe "interrupt_agent" do
    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()
      assert {:error, :not_found} = Tools.call("interrupt_agent", orch.id, %{"name" => "ghost"})
    end

    test "interrupts a known worker" do
      orch = orchestrator()
      name = "int-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, %{"status" => "interrupted"}} =
               Tools.call("interrupt_agent", orch.id, %{"name" => name})
    end
  end

  describe "start_adw" do
    test "launches the seeded workflow and returns a run id" do
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{"input" => "ship it", "harness" => "fake"})

      assert is_binary(run_id)
      # Let the spawned runner reach a terminal state before the sandbox owner exits,
      # so its step sessions don't crash on a torn-down connection.
      assert_run_terminal(run_id)
    end
  end

  defp assert_run_terminal(run_id, attempts \\ 80) do
    case Workflows.get_run(run_id) do
      %{status: status} when status in [:succeeded, :failed, :aborted] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        assert_run_terminal(run_id, attempts - 1)

      _ ->
        flunk("workflow #{run_id} did not reach a terminal state")
    end
  end

  describe "update_agent" do
    test "updates model/system_prompt/harness on a created worker" do
      orch = orchestrator()
      name = "upd-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, result} =
               Tools.call("update_agent", orch.id, %{
                 "name" => name,
                 "model" => "fake-model-9",
                 "system_prompt" => "be terse",
                 "harness" => "fake"
               })

      assert result["model"] == "fake-model-9"

      assert {:ok, worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert worker.model == "fake-model-9"
      assert worker.system_prompt == "be terse"
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("update_agent", orch.id, %{"name" => "ghost", "model" => "x"})
    end

    test "no updatable fields is an error and writes nothing" do
      orch = orchestrator()
      name = "noop-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:error, reason} = Tools.call("update_agent", orch.id, %{"name" => name})
      assert reason =~ "no updatable fields"
    end

    test "an unregistered harness is rejected" do
      orch = orchestrator()
      name = "badh-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:error, _reason} =
               Tools.call("update_agent", orch.id, %{"name" => name, "harness" => "nope"})
    end
  end

  describe "delete_agent" do
    test "deletes a created worker and broadcasts agent_deleted" do
      :ok = RepoBuilder.Dashboard.subscribe_events()
      orch = orchestrator()
      name = "del-#{uniq()}"
      {:ok, _} = Tools.call("create_agent", orch.id, %{"name" => name, "harness" => "fake"})

      assert {:ok, %{"status" => "deleted", "name" => ^name}} =
               Tools.call("delete_agent", orch.id, %{"name" => name})

      assert {:error, :not_found} = Agents.get_by_name_for_orchestrator(orch.id, name)
      assert_receive {:agent_deleted, %{name: ^name}}
    end

    test "unknown worker is {:error, :not_found}" do
      orch = orchestrator()
      assert {:error, :not_found} = Tools.call("delete_agent", orch.id, %{"name" => "ghost"})
    end
  end

  describe "read_system_logs" do
    test "returns paged summaries after a tool call has logged" do
      orch = orchestrator()
      # Any tool call writes a system_logs row via log_invocation/4.
      {:ok, _} = Tools.call("list_agents", orch.id, %{})

      assert {:ok, %{"logs" => logs, "count" => count}} =
               Tools.call("read_system_logs", orch.id, %{})

      assert is_list(logs)
      assert count == length(logs)
    end

    test "message_contains narrows results" do
      orch = orchestrator()
      {:ok, _} = Tools.call("list_agents", orch.id, %{})

      assert {:ok, %{"logs" => logs}} =
               Tools.call("read_system_logs", orch.id, %{"message_contains" => "list_agents"})

      assert Enum.any?(logs)
      assert Enum.all?(logs, &(&1["message"] =~ "list_agents"))
    end

    test "level filter narrows and a blank/invalid level is ignored" do
      orch = orchestrator()
      {:ok, _} = Tools.call("list_agents", orch.id, %{})

      assert {:ok, %{"logs" => info_logs}} =
               Tools.call("read_system_logs", orch.id, %{"level" => "info"})

      assert Enum.all?(info_logs, &(&1["level"] == "info"))

      assert {:ok, %{"logs" => _}} =
               Tools.call("read_system_logs", orch.id, %{"level" => "bogus"})
    end
  end

  describe "check_adw" do
    test "returns the run status for a valid run id" do
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{"input" => "ship it", "harness" => "fake"})

      assert {:ok, %{"status" => status}} =
               Tools.call("check_adw", orch.id, %{"run_id" => run_id})

      assert is_binary(status)
      assert_run_terminal(run_id)
    end

    test "unknown UUID is {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("check_adw", orch.id, %{"run_id" => Ecto.UUID.generate()})
    end

    test "a non-UUID run_id is {:error, \"invalid run_id\"}" do
      orch = orchestrator()
      assert {:error, "invalid run_id"} = Tools.call("check_adw", orch.id, %{"run_id" => "nope"})
    end
  end

  describe "get_config" do
    test "returns the orchestrator config, tier roster, and registered harnesses" do
      orch = orchestrator()

      assert {:ok, cfg} = Tools.call("get_config", orch.id, %{})
      assert %{"harness" => "fake"} = cfg["orchestrator"]
      assert "fake" in cfg["harnesses"]
      assert is_map(cfg["available_models"])

      # Every tier is unassigned before any model is set.
      assert cfg["tiers"]["heavy"]["assigned"] == false
      assert cfg["tiers"]["fast"]["assigned"] == false
    end

    test "a tier flips to assigned: true after set_agent_model/3" do
      orch = orchestrator()

      {:ok, _} =
        Orchestrators.set_agent_model(orch.id, "heavy", %{
          "harness" => "fake",
          "model" => "big-model"
        })

      assert {:ok, cfg} = Tools.call("get_config", orch.id, %{})
      assert cfg["tiers"]["heavy"]["assigned"] == true
      assert cfg["tiers"]["heavy"]["model"] == "big-model"
    end

    test "logs an ok system_log for the happy path" do
      orch = orchestrator()
      {:ok, _} = Tools.call("get_config", orch.id, %{})

      logs = RepoBuilder.Logs.query_system_logs(message_contains: "get_config")
      assert Enum.any?(logs, &(&1.message =~ "ok"))
    end

    test "unknown orchestrator id is {:error, :orchestrator_not_found}" do
      assert {:error, :orchestrator_not_found} =
               Tools.call("get_config", Ecto.UUID.generate(), %{})
    end
  end

  describe "configure_tier" do
    test "assigns a tier and a subsequent create_agent by category succeeds" do
      orch = orchestrator()

      assert {:ok, %{"status" => "configured", "category" => "fast"}} =
               Tools.call("configure_tier", orch.id, %{
                 "category" => "fast",
                 "model" => "m",
                 "harness" => "fake",
                 "provider" => "minimax"
               })

      name = "worker-#{uniq()}"

      assert {:ok, %{"name" => ^name, "model" => "m"}} =
               Tools.call("create_agent", orch.id, %{"name" => name, "category" => "fast"})

      assert {:ok, _worker} = Agents.get_by_name_for_orchestrator(orch.id, name)
    end

    test "missing model is {:error, _}" do
      orch = orchestrator()

      assert {:error, _} =
               Tools.call("configure_tier", orch.id, %{"category" => "fast"})
    end

    test "an invalid category is {:error, _}" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("configure_tier", orch.id, %{"category" => "bogus", "model" => "m"})

      assert reason =~ "invalid category"
    end
  end

  describe "set_orchestrator_config" do
    test "setting a model persists across a re-fetch" do
      orch = orchestrator()

      assert {:ok, %{"model" => "x"}} =
               Tools.call("set_orchestrator_config", orch.id, %{"model" => "x"})

      assert {:ok, %{model: "x"}} = Orchestrators.fetch(orch.id)
    end

    test "empty args is {:error, \"no config fields provided\"}" do
      orch = orchestrator()

      assert {:error, "no config fields provided"} =
               Tools.call("set_orchestrator_config", orch.id, %{})
    end

    test "an unregistered harness is rejected and leaves the row unchanged" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("set_orchestrator_config", orch.id, %{"harness" => "nope"})

      assert reason =~ "not a registered harness"
      assert {:ok, %{harness: "fake"}} = Orchestrators.fetch(orch.id)
    end
  end

  describe "dispatch" do
    test "unknown tool is {:error, :unknown_tool}" do
      orch = orchestrator()
      assert {:error, :unknown_tool} = Tools.call("nope", orch.id, %{})
    end
  end
end
