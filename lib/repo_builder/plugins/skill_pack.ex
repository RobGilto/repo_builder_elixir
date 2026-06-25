defmodule RepoBuilder.Plugins.SkillPack do
  @moduledoc """
  Resolver/loader for the `:skill` contribution kind (forge-meta-artifact-generation,
  Phase 4) — the home an Agent Skill bundle lands in, the analog of `Commands.Resolver`
  for `command_pack`.

  A `:skill` contribution's asset is a `skills/` directory of `<name>/SKILL.md` bundles.
  `Plugins.Activation` already resolves the active `:skill` contributions per project (the
  closed-set compute is kind-generic); this module enumerates the bundles behind those
  contributions and MATERIALIZES the active ones into a project's `.claude/skills/` so the
  harness running in that repo discovers them. Materialization is scoped to the requesting
  project — a skill forged for one repo never leaks to another.
  """
  alias RepoBuilder.Plugins.Activation

  @typedoc "One resolved skill bundle: its name and the source directory holding `SKILL.md`."
  @type bundle :: %{name: String.t(), source_dir: String.t()}

  @doc """
  The active skill bundles for `project_id` (`nil` = platform), flattened across every
  enabled `:skill` contribution, in priority order.
  """
  @spec skills(Ecto.UUID.t() | nil) :: [bundle()]
  def skills(project_id) do
    project_id
    |> Activation.contributions(:skill)
    |> Enum.flat_map(&bundles_in(&1.abs_path))
  end

  @doc """
  Materialize the active skills for `project_id` into `target_root`'s `.claude/skills/`.
  Each bundle is copied to `<target_root>/.claude/skills/<name>/`. Returns the list of
  materialized skill names. Total — a copy failure on one bundle is skipped, never raises.
  """
  @spec materialize(Ecto.UUID.t() | nil, String.t()) :: {:ok, [String.t()]}
  def materialize(project_id, target_root) when is_binary(target_root) do
    skills_root = Path.join([target_root, ".claude", "skills"])
    _ = File.mkdir_p(skills_root)

    materialized =
      project_id
      |> skills()
      |> Enum.flat_map(fn %{name: name, source_dir: source_dir} ->
        target = Path.join(skills_root, name)
        _ = File.rm_rf(target)

        case File.cp_r(source_dir, target) do
          {:ok, _copied} -> [name]
          {:error, _reason, _file} -> []
        end
      end)

    {:ok, materialized}
  end

  @spec bundles_in(String.t() | nil) :: [bundle()]
  defp bundles_in(nil), do: []

  defp bundles_in(skills_dir) do
    case File.ls(skills_dir) do
      {:ok, entries} ->
        for name <- Enum.sort(entries),
            source_dir = Path.join(skills_dir, name),
            File.dir?(source_dir),
            File.regular?(Path.join(source_dir, "SKILL.md")),
            do: %{name: name, source_dir: source_dir}

      {:error, _reason} ->
        []
    end
  end
end
