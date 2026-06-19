defmodule RepoBuilder.Orchestrator.CommandAgentAutonomousTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Harness.Claude
  alias RepoBuilder.Orchestrator.Tools

  @flag "--dangerously-skip-permissions"

  describe "worker_session_config/1" do
    test "marks the worker session autonomous via the atom :autonomous key" do
      config = Tools.worker_session_config(%Agent{config: %{"provider" => "anthropic"}})

      assert config[:autonomous] == true
      # The worker's own (string-keyed) config is preserved.
      assert config["provider"] == "anthropic"
    end

    test "the resulting config makes the Claude adapter emit the skip-permissions flag" do
      config = Tools.worker_session_config(%Agent{config: %{}})
      {"claude", args, _env, _ctx} = Claude.command(%{prompt: "do it", config: config})

      assert @flag in args
    end
  end
end
