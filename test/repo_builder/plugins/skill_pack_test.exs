defmodule RepoBuilder.Plugins.SkillPackTest do
  @moduledoc """
  The `:skill` contribution kind activates per project and materializes into
  `.claude/skills/` (forge-meta-artifact-generation, Phase 4).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Plugins
  alias RepoBuilder.Plugins.SkillPack
  alias RepoBuilder.Projects

  defp make_project do
    uniq = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{name: "skp-#{uniq}", root_path: "/tmp/skp-#{uniq}"})

    project
  end

  # Install a plugin on disk (a tmp install dir) carrying one `:skill` contribution, and
  # return its id + the project it's activated for.
  defp install_skill_plugin(name) do
    uniq = System.unique_integer([:positive])
    id = "skills-#{uniq}"
    install_path = Path.join(System.tmp_dir!(), "rb_skillpack_#{uniq}")
    bundle = Path.join([install_path, "skills", name])
    File.mkdir_p!(bundle)

    File.write!(
      Path.join(bundle, "SKILL.md"),
      "---\nname: #{name}\ndescription: x\n---\n# #{name}\n"
    )

    on_exit(fn -> File.rm_rf(install_path) end)

    manifest = %{
      "schema" => "agentic.plugin/1",
      "id" => id,
      "name" => id,
      "version" => "1.0.0",
      "contributions" => [%{"kind" => "skill", "path" => "skills"}]
    }

    {:ok, _} =
      Plugins.install_record(%{
        plugin_id: id,
        version: "1.0.0",
        source: "library",
        install_path: install_path,
        manifest: manifest,
        status: :installed
      })

    id
  end

  test "skills/1 resolves active skill bundles for the project only" do
    id = install_skill_plugin("processing-invoices")
    project_id = make_project().id
    {:ok, _} = Plugins.activate(project_id, id)

    assert [%{name: "processing-invoices", source_dir: source_dir}] = SkillPack.skills(project_id)
    assert File.regular?(Path.join(source_dir, "SKILL.md"))

    # Absent for a different project.
    assert SkillPack.skills(Ecto.UUID.generate()) == []
  end

  test "materialize/2 copies active skills into the target's .claude/skills/" do
    id = install_skill_plugin("analyzing-spreadsheets")
    project_id = make_project().id
    {:ok, _} = Plugins.activate(project_id, id)

    target = Path.join(System.tmp_dir!(), "rb_skilltarget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(target)
    on_exit(fn -> File.rm_rf(target) end)

    assert {:ok, ["analyzing-spreadsheets"]} = SkillPack.materialize(project_id, target)

    assert File.regular?(
             Path.join([target, ".claude", "skills", "analyzing-spreadsheets", "SKILL.md"])
           )
  end
end
