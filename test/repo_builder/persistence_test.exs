defmodule RepoBuilder.PersistenceTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.{Agents, Logs, Workflows}
  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Logs.AgentLog
  alias RepoBuilder.Repo

  defp agent_fixture(attrs \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        Map.merge(
          %{
            name: "agent-#{System.unique_integer([:positive])}",
            harness: "claude",
            provider: :anthropic
          },
          attrs
        )
      )

    agent
  end

  describe "Agents context (Enum + JSONB round-trip, constraints)" do
    test "round-trips provider/status Enums and the config JSONB map" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "a1",
          harness: "pi",
          provider: :openai,
          config: %{"k" => "v"}
        })

      reloaded = Agents.get_agent(agent.id)
      assert reloaded.provider == :openai
      assert reloaded.status == :idle
      assert reloaded.config == %{"k" => "v"}
    end

    test "returns {:error, changeset} on a duplicate name (proves the unique index exists)" do
      _ = agent_fixture(%{name: "dup"})

      assert {:error, %Ecto.Changeset{} = cs} =
               Agents.create_agent(%{name: "dup", harness: "claude", provider: :local})

      assert "has already been taken" in errors_on(cs).name
    end

    test "rejects an unregistered harness at the write boundary" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Agents.create_agent(%{name: "x", harness: "nope", provider: :local})

      assert "is not a registered harness" in errors_on(cs).harness
    end

    test "set_status updates the agent" do
      agent = agent_fixture()
      assert {:ok, updated} = Agents.set_status(agent.id, :running)
      assert updated.status == :running
    end
  end

  describe "Logs.persist_event (redaction, usage, cost boundary)" do
    test "scrubs secrets in the persisted payload while leaving the input event untouched" do
      agent = agent_fixture()

      raw = %{
        "type" => "text_delta",
        "text" => "hi",
        "api_key" => "sk-secret",
        "nested" => %{"authorization" => "Bearer x"}
      }

      event = %Event.TextDelta{harness: :claude, text: "hi", raw: raw}

      {:ok, log} = Logs.persist_event(event, %{agent_id: agent.id, session_id: "s1"})

      assert log.payload["api_key"] == "[REDACTED]"
      assert log.payload["nested"]["authorization"] == "[REDACTED]"
      assert log.payload["text"] == "hi"
      # The in-flight event keeps full detail.
      assert event.raw["api_key"] == "sk-secret"
    end

    test "persists Usage with cost float->Decimal; nil cost stays NULL, 0.0 becomes Decimal 0" do
      agent = agent_fixture()

      {:ok, priced} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 10, output_tokens: 5, cost_usd: 0.25},
          %{agent_id: agent.id, session_id: "s"}
        )

      assert Decimal.equal?(priced.usage.cost_usd, Decimal.new("0.25"))
      assert priced.usage.input_tokens == 10

      {:ok, unpriced} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 1, output_tokens: 1, cost_usd: nil},
          %{agent_id: agent.id, session_id: "s"}
        )

      assert unpriced.usage.cost_usd == nil

      {:ok, zero} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 1, output_tokens: 1, cost_usd: 0.0},
          %{agent_id: agent.id, session_id: "s"}
        )

      assert Decimal.equal?(zero.usage.cost_usd, Decimal.new(0))
    end

    test "cost_rollup! sums only priced usage" do
      agent = agent_fixture()

      {:ok, _} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 1, output_tokens: 1, cost_usd: 0.10},
          %{agent_id: agent.id, session_id: "s"}
        )

      {:ok, _} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 1, output_tokens: 1, cost_usd: nil},
          %{agent_id: agent.id, session_id: "s"}
        )

      {:ok, _} =
        Logs.persist_event(
          %Event.Usage{harness: :pi, input_tokens: 1, output_tokens: 1, cost_usd: 0.05},
          %{agent_id: agent.id, session_id: "s"}
        )

      assert Decimal.equal?(Logs.cost_rollup!(agent.id), Decimal.new("0.15"))
    end

    test "list_recent returns rows in chronological order" do
      agent = agent_fixture()

      {:ok, _} =
        Logs.persist_event(
          %Event.TextDelta{harness: :pi, text: "one", raw: %{"text" => "one"}},
          %{agent_id: agent.id, session_id: "s"}
        )

      {:ok, _} =
        Logs.persist_event(
          %Event.TextDelta{harness: :pi, text: "two", raw: %{"text" => "two"}},
          %{agent_id: agent.id, session_id: "s"}
        )

      bodies = agent.id |> Logs.list_recent() |> Enum.map(& &1.payload["text"])
      assert bodies == ["one", "two"]
    end

    test "a bad agent FK returns {:error, changeset}, not a raw Postgrex error" do
      bad_id = Ecto.UUID.generate()
      event = %Event.TextDelta{harness: :pi, text: "x"}

      assert {:error, %Ecto.Changeset{}} =
               Logs.persist_event(event, %{agent_id: bad_id, session_id: "s"})
    end

    test "the persisted event_type Enum round-trips" do
      agent = agent_fixture()

      {:ok, log} =
        Logs.persist_event(%Event.ToolCall{harness: :pi, name: "bash"}, %{
          agent_id: agent.id,
          session_id: "s"
        })

      assert Repo.get(AgentLog, log.id).event_type == :tool_call
    end
  end

  describe "Workflows runs (source of truth + cost NULL preservation)" do
    setup do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "wf-#{System.unique_integer([:positive])}",
          steps: [%{"name" => "plan"}]
        })

      %{workflow: wf}
    end

    test "create/update run transitions persist", %{workflow: wf} do
      {:ok, run} =
        Workflows.create_run(%{workflow_id: wf.id, status: :queued, current_step: "plan"})

      assert run.status == :queued
      {:ok, run} = Workflows.update_run(run, %{status: :running, current_step: "build"})
      assert Workflows.get_run(run.id).current_step == "build"
    end

    test "add_run_cost preserves NULL until a priced amount arrives, then accumulates", %{
      workflow: wf
    } do
      {:ok, run} = Workflows.create_run(%{workflow_id: wf.id, status: :running})
      assert run.total_cost_usd == nil

      {:ok, run} = Workflows.add_run_cost(run, nil)
      assert run.total_cost_usd == nil

      {:ok, run} = Workflows.add_run_cost(run, Decimal.new("0.20"))
      {:ok, run} = Workflows.add_run_cost(run, Decimal.new("0.05"))
      assert Decimal.equal?(run.total_cost_usd, Decimal.new("0.25"))
    end

    test "workflow steps JSONB list round-trips", %{workflow: wf} do
      reloaded = Workflows.get_workflow(wf.id)
      assert [%{"name" => "plan"}] = reloaded.steps
    end
  end
end
