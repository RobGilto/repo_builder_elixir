defmodule RepoBuilder.Orchestrator.TemplateToolsTest do
  @moduledoc """
  Self-healing Phase 5 parity gap: the re-introduced `tools` frontmatter field is a per-worker
  capability allowlist that round-trips through the template store and is recorded onto the
  worker's config at `create_agent` time. `async: false`: overrides the writable templates root.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Agents
  alias RepoBuilder.Orchestrator.{Templates, Tools}
  alias RepoBuilder.Orchestrators

  setup do
    dir = Path.join(System.tmp_dir!(), "agents-#{System.unique_integer([:positive])}")
    original = Application.get_env(:repo_builder, :orchestrator, [])
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :agents_dir, dir))

    on_exit(fn ->
      Application.put_env(:repo_builder, :orchestrator, original)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "the tools allowlist round-trips through save/fetch" do
    name = "scout-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Templates.save(%{
        "name" => name,
        "description" => "read-only scout",
        "body" => "you are a read-only scout",
        "tools" => ["Read", "Grep", "Glob"]
      })

    assert {:ok, fetched} = Templates.fetch(name)
    assert fetched.tools == ["Read", "Grep", "Glob"]
  end

  test "create_agent records the template's tools as the worker's allowed_tools" do
    name = "scout-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Templates.save(%{
        "name" => name,
        "description" => "read-only scout",
        "body" => "scout body",
        "harness" => "fake",
        "model" => "fake-model",
        "tools" => ["Read", "Grep"]
      })

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    {:ok, result} =
      Tools.call("create_agent", orch.id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "subagent_template" => name,
        "harness" => "fake"
      })

    agent = Agents.get_agent(result["id"])
    assert agent.config["allowed_tools"] == ["Read", "Grep"]
  end

  test "a template with no tools records no allowlist (back-compatible)" do
    name = "builder-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Templates.save(%{
        "name" => name,
        "description" => "builder",
        "body" => "build it",
        "harness" => "fake",
        "model" => "fake-model"
      })

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    {:ok, result} =
      Tools.call("create_agent", orch.id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "subagent_template" => name,
        "harness" => "fake"
      })

    agent = Agents.get_agent(result["id"])
    refute Map.has_key?(agent.config, "allowed_tools")
  end
end
