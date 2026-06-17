defmodule RepoBuilderWeb.TestAgentTemplatesTabTest do
  @moduledoc """
  Integration test for the "Agent Templates" settings tab (see
  specs/issue-spec-adw-this-sdlc_planner-subagent-templates.md).

  Opens the tab, saves a template via the form, edits + saves again (version bump),
  restores an older version non-destructively, and deletes — verifying the persisted
  files via the `Templates` context at each step.

  `async: false`: shared Ecto sandbox + a per-run tmp template root (and an empty
  built-in root so the shipped `code-scout` does not perturb the assertions).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrator.Templates

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)

    writable =
      Path.join(System.tmp_dir!(), "rb_tab_writable_#{System.unique_integer([:positive])}")

    builtin = Path.join(System.tmp_dir!(), "rb_tab_builtin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(writable)
    File.mkdir_p!(builtin)

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

  test "save, version, restore, and delete a template through the tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-value-tab=templates]") |> render_click()
    assert has_element?(view, "#agent-template-form")

    # Save v1 via the form.
    view
    |> form("#agent-template-form")
    |> render_submit(%{
      "name" => "reviewer",
      "description" => "Reviews diffs.",
      "system_prompt" => "You review code.",
      "model" => "",
      "category" => "main"
    })

    assert {:ok, v1} = Templates.fetch("reviewer")
    assert v1.version == 1
    assert v1.body == "You review code."
    assert v1.category == "main"
    assert has_element?(view, "#agent-template-row-reviewer")

    # Edit + save v2; version history now lists v2 + v1.
    view
    |> form("#agent-template-form")
    |> render_submit(%{
      "name" => "reviewer",
      "description" => "Reviews diffs carefully.",
      "system_prompt" => "You review code thoroughly.",
      "model" => "",
      "category" => "main"
    })

    assert {:ok, v2} = Templates.fetch("reviewer")
    assert v2.version == 2
    assert has_element?(view, "#agent-template-restore-2")
    assert has_element?(view, "#agent-template-restore-1")

    # Restore v1 → a new current v3 mirroring v1's body.
    view |> element("#agent-template-restore-1") |> render_click()

    assert {:ok, v3} = Templates.fetch("reviewer")
    assert v3.version == 3
    assert v3.body == "You review code."

    # Delete removes the whole writable history.
    view |> element("#agent-template-delete") |> render_click()

    assert {:error, :not_found} = Templates.fetch("reviewer")
    refute has_element?(view, "#agent-template-row-reviewer")
  end
end
