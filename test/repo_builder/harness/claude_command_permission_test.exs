defmodule RepoBuilder.Harness.ClaudeCommandPermissionTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Claude

  @flag "--dangerously-skip-permissions"

  defp args(config) do
    {"claude", args, _env, _ctx} = Claude.command(%{prompt: "do it", config: config})
    args
  end

  test "an autonomous session (config :autonomous) gets the skip-permissions flag" do
    assert @flag in args(%{autonomous: true})
  end

  test "the orchestrator session (config :orchestrator) gets the skip-permissions flag" do
    assert @flag in args(%{orchestrator: true})
  end

  test "a plain (non-autonomous) session does NOT get the skip-permissions flag" do
    refute @flag in args(%{})
  end

  test "a STRING-keyed autonomous flag does NOT match (adapter reads atom keys)" do
    # Guards the atom-vs-string trap: worker.config is JSONB with string keys, so the
    # caller must set the atom key. A string key must not silently appear to work.
    refute @flag in args(%{"autonomous" => true})
  end
end
