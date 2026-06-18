defmodule RepoBuilder.ExplainTest do
  @moduledoc """
  Unit tests for the ephemeral explain-logs context (issue-explain): prompt building
  from selected rows and Fast-tier resolution (including the no-Fast-agent path).
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Explain
  alias RepoBuilder.Orchestrator.Orchestrator

  defp orchestrator(agent_models) do
    %Orchestrator{metadata: %{"agent_models" => agent_models}}
  end

  defp row(overrides) do
    Map.merge(
      %{
        log_no: 7,
        line: 3,
        category: :tool,
        kind: "bash",
        agent: "worker-1",
        body: "tool=bash input=%{\"cmd\" => \"echo hi\"}",
        time: "12:00:00"
      },
      Map.new(overrides)
    )
  end

  describe "fast_config/1" do
    test "returns the roster's fast entry harness/provider/model" do
      orch =
        orchestrator(%{
          "fast" => %{"harness" => "fake", "provider" => "anthropic", "model" => "fake-model-1"}
        })

      assert {:ok, %{harness: "fake", provider: "anthropic", model: "fake-model-1"}} =
               Explain.fast_config(orch)
    end

    test "provider is nil when blank" do
      orch =
        orchestrator(%{"fast" => %{"harness" => "fake", "provider" => "", "model" => "m"}})

      assert {:ok, %{provider: nil}} = Explain.fast_config(orch)
    end

    test "returns {:error, :no_fast_agent} when the model is blank" do
      orch = orchestrator(%{"fast" => %{"harness" => "fake", "model" => ""}})
      assert {:error, :no_fast_agent} = Explain.fast_config(orch)
    end

    test "returns {:error, :no_fast_agent} when the harness is blank" do
      orch = orchestrator(%{"fast" => %{"harness" => "", "model" => "m"}})
      assert {:error, :no_fast_agent} = Explain.fast_config(orch)
    end

    test "returns {:error, :no_fast_agent} when there is no fast entry" do
      assert {:error, :no_fast_agent} = Explain.fast_config(orchestrator(%{}))
    end
  end

  describe "build_prompt/1" do
    test "asks for ONE paragraph with no preamble or bullet lists" do
      prompt = Explain.build_prompt([row([])])

      assert prompt =~ "ONE paragraph"
      assert prompt =~ "No preamble, no bullet lists"
    end

    test "serializes every selected row's full body with log/category/kind/agent/time" do
      rows = [
        row(log_no: 7, category: :tool, kind: "bash", agent: "worker-1", body: "FIRST BODY"),
        row(log_no: 8, category: :response, kind: "text", agent: "worker-2", body: "SECOND BODY")
      ]

      prompt = Explain.build_prompt(rows)

      assert prompt =~ "log-7 [tool/bash] worker-1 @ 12:00:00"
      assert prompt =~ "FIRST BODY"
      assert prompt =~ "log-8 [response/text] worker-2 @ 12:00:00"
      assert prompt =~ "SECOND BODY"
    end

    test "uses the full body, not a truncation" do
      big = String.duplicate("x", 500)
      prompt = Explain.build_prompt([row(body: big)])
      assert prompt =~ big
    end

    test "falls back to line number when log_no is nil" do
      prompt = Explain.build_prompt([row(log_no: nil, line: 42)])
      assert prompt =~ "log-42 ["
    end
  end
end
