defmodule RepoBuilder.Forge.Generator do
  @moduledoc """
  The CLOSED generator registry (forge-meta-artifact-generation) — the Forge's keystone
  seam, mirroring `Harness.Registry` and `Plugins.Contribution`: a closed set of
  generator KINDS, each mapping to its vendored prompt template, its per-kind validator,
  and the `Plugins.Contribution` kind it ultimately lands as.

  Adding a generator kind is a deliberate edit here (a new extension point); the open
  side is the natural-language `spec` an operator forges with.

      :command  → command_pack    (.claude/commands/<name>.md)
      :agent    → agent_template  (.claude/agents/<name>.md)
      :skill    → skill           (skills/<name>/SKILL.md)
      :workflow → workflow_type    (workflows/<slug>.json)
  """
  alias RepoBuilder.Forge.Generator.Def

  @typedoc "The closed set of generator kinds (open spec, closed contract)."
  @type kind :: :command | :agent | :skill | :workflow

  @type def_t :: Def.t()

  # The closed registry. `template` is the filename under the configured generators dir;
  # `asset_subdir` is where the packaged artifact lands inside the plugin package.
  @defs %{
    command: %Def{
      kind: :command,
      template: "command.md",
      contribution_kind: :command_pack,
      asset_subdir: "commands"
    },
    agent: %Def{
      kind: :agent,
      template: "agent.md",
      contribution_kind: :agent_template,
      asset_subdir: "agents"
    },
    skill: %Def{
      kind: :skill,
      template: "skill.md",
      contribution_kind: :skill,
      asset_subdir: "skills"
    },
    workflow: %Def{
      kind: :workflow,
      template: "workflow.md",
      contribution_kind: :workflow_type,
      asset_subdir: "workflows"
    }
  }

  @kinds Map.keys(@defs)
  @kind_strings Enum.map(@kinds, &Atom.to_string/1)

  @doc "The closed list of generator kinds."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @doc "The closed list of generator kinds as wire strings (for changeset `validate_inclusion`)."
  @spec kind_strings() :: [String.t(), ...]
  def kind_strings, do: @kind_strings

  @doc "Whether `value` is one of the closed generator kinds."
  @spec kind?(term()) :: boolean()
  def kind?(value), do: value in @kinds

  @doc """
  Cast an untrusted wire string to a closed generator kind atom — `to_existing_atom`
  against the pre-declared set only, never `to_atom/1` on untrusted input.
  """
  @spec cast_kind(term()) :: {:ok, kind()} | {:error, :unknown_generator}
  def cast_kind(string) when is_binary(string) do
    if string in @kind_strings,
      do: {:ok, String.to_existing_atom(string)},
      else: {:error, :unknown_generator}
  end

  def cast_kind(_string), do: {:error, :unknown_generator}

  @doc "Fetch the generator definition for `kind`, or `{:error, :unknown_generator}`."
  @spec fetch(kind() | String.t()) :: {:ok, def_t()} | {:error, :unknown_generator}
  def fetch(kind) when is_atom(kind) do
    case Map.fetch(@defs, kind) do
      {:ok, def_t} -> {:ok, def_t}
      :error -> {:error, :unknown_generator}
    end
  end

  def fetch(kind) when is_binary(kind) do
    case cast_kind(kind) do
      {:ok, atom} -> fetch(atom)
      error -> error
    end
  end

  @doc "Absolute path to the vendored template backing `kind`."
  @spec template_path(def_t()) :: String.t()
  def template_path(%Def{template: template}) do
    Path.join(generators_dir(), template)
  end

  @doc "Absolute path to the configured generators directory."
  @spec generators_dir() :: String.t()
  def generators_dir do
    config()
    |> Keyword.get(:generators_dir, "priv/forge/generators")
    |> Path.expand(File.cwd!())
  end

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :forge, [])
end
