defmodule RepoBuilder.Orchestrator.SystemPromptPrimerTest do
  @moduledoc """
  The agentic-layer adaptor primer injection: when the orchestrator's working dir maps
  to a registered Project carrying a stored `context_primer`, the system prompt embeds
  it; when no project matches (or the working dir is nil) the prompt is unchanged.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt}
  alias RepoBuilder.Projects

  defp orchestrator(working_dir) do
    %Orchestrator{
      name: "default",
      harness: "fake",
      provider: nil,
      model: nil,
      working_dir: working_dir,
      metadata: %{}
    }
  end

  test "injects the active project's primer when the working dir maps to a project" do
    root = Path.join(System.tmp_dir!(), "rb_primer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".claude/commands"))
    File.write!(Path.join(root, "mix.exs"), "defmodule X.MixProject do end")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, _project} =
      Projects.create_and_profile(%{"name" => "primed", "root_path" => root})

    prompt = SystemPrompt.build(orchestrator(root))

    assert prompt =~ "Target project:"
    assert prompt =~ "Stack: elixir (mix)"
    assert prompt =~ "test: `mix test`"
  end

  test "no primer when the working dir does not map to a project" do
    prompt = SystemPrompt.build(orchestrator("/tmp/some/unregistered/path"))
    refute prompt =~ "Target project:"
  end

  test "no primer when no working dir is set" do
    prompt = SystemPrompt.build(orchestrator(nil))
    refute prompt =~ "Target project:"
  end
end
