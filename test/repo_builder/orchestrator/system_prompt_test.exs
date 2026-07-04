defmodule RepoBuilder.Orchestrator.SystemPromptTest do
  @moduledoc """
  Tests the `{{SUBAGENT_MAP}}` injection in the orchestrator system prompt: it lists
  the available subagent templates and renders the empty-state fallback when none.

  `async: false` — mutates the shared `:repo_builder, :orchestrator` app env to point
  the template roots at hermetic tmp dirs.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt, Templates}

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)

    writable =
      Path.join(System.tmp_dir!(), "rb_sp_writable_#{System.unique_integer([:positive])}")

    builtin = Path.join(System.tmp_dir!(), "rb_sp_builtin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(writable)
    File.mkdir_p!(builtin)

    # Point BOTH roots at empty tmp dirs so the shipped built-in does not leak in.
    config =
      original
      |> Keyword.put(:agents_dir, writable)
      |> Keyword.put(:agents_builtin_dir, builtin)

    Application.put_env(:repo_builder, :orchestrator, config)

    on_exit(fn ->
      Application.put_env(:repo_builder, :orchestrator, original)
      File.rm_rf(writable)
      File.rm_rf(builtin)
    end)

    :ok
  end

  defp orchestrator do
    %Orchestrator{
      name: "default",
      harness: "fake",
      provider: nil,
      model: nil,
      metadata: %{}
    }
  end

  test "the subagent map lists a seeded template" do
    {:ok, _} =
      Templates.save(%{
        "name" => "code-scout",
        "description" => "Read-only scout.",
        "body" => "You scout."
      })

    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "Available subagent templates"
    assert prompt =~ "- code-scout: Read-only scout."
  end

  test "renders the empty-state fallback when there are no templates" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "No subagent templates yet"
  end

  test "the AVAILABLE ADW TYPES block lists the catalog's workflow types" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "Available ADW types"
    assert prompt =~ "- plan_build:"
    assert prompt =~ "- plan_build_review_fix:"
  end

  test "ports the o3s prose: ultrathink, slash-command, and conductor framing" do
    prompt = SystemPrompt.build(orchestrator())

    # ultrathink thinking-mode guidance for the command_agent command field.
    assert prompt =~ "ultrathink"
    # Control-owned slash-command expansion guidance (works on every harness).
    assert prompt =~ "SLASH COMMANDS:"
    assert prompt =~ "Available slash commands"
    # Narrative framing.
    assert prompt =~ "conductor of this multi-agent orchestra"
    # Worker roles are DATA-DRIVEN from the subagent-template registry (self-healing
    # Phase 5), printed ONCE as the merged templates-&-roles block (dedupe refactor).
    # The empty-state still names the conventional roles.
    assert prompt =~ "Available subagent templates & worker roles"
    assert prompt =~ "builder/reviewer/tester/documenter/debugger"
  end

  test "includes the context-management block referencing report_cost + compaction" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "Context management:"
    assert prompt =~ "report_cost"
    assert prompt =~ "compact_agent"
    assert prompt =~ "/compact"
  end

  test "documents the firecrawl research-tools grant" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "RESEARCH TOOLS"
    assert prompt =~ "firecrawl"
    assert prompt =~ ~s(tools: ["firecrawl"])
  end

  test "teaches the focus discipline (set_focus before commanding workers)" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "set_focus"
    assert prompt =~ "clear_focus"
    assert prompt =~ "DECLARE YOUR FOCUS"
  end

  test "teaches the quality-gate protocol at the :test stage (repo-bound render)" do
    # The quality gate is repo-gated (dedupe refactor): it only renders when the
    # orchestrator has a working directory / project to run it against. The DB is
    # needed because a working_dir triggers the registered-project lookup.
    :ok = Sandbox.checkout(RepoBuilder.Repo)

    dir = Path.join(System.tmp_dir!(), "rb_sp_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    prompt = SystemPrompt.build(%{orchestrator() | working_dir: dir})

    assert prompt =~ "Quality gate (per-phase rigorous testing"
    assert prompt =~ "run_quality_gate"
    assert prompt =~ "format · lint · type · test · mutation"
    assert prompt =~ ~r/mutation.*pre_merge/s
    assert prompt =~ ~r/test:.*QUALITY GATE/s
  end

  test "documents clear_context and the clear-vs-compact distinction" do
    prompt = SystemPrompt.build(orchestrator())

    assert prompt =~ "clear_context"
    # The clear-vs-compact distinction: blank window for NEW unrelated work.
    assert prompt =~ "blank context window"
    assert prompt =~ ~r/Prefer this over `compact_agent`/
    # The proactive-at-80% rule still names both levers.
    assert prompt =~ ~r/80%.*clear_context/s
  end
end
