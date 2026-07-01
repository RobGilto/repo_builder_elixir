defmodule RepoBuilder.Plugins.Contribution do
  @moduledoc """
  The CLOSED set of plugin contribution kinds — the plugin system's keystone
  contract, modelled on the canonical `Harness.Event` sum type (BUILD_PROMPT.md
  §4/§10): a closed set of kinds, an OPEN plugin identity.

  A plugin's manifest declares zero-or-more contributions; each names a `kind` from
  the closed union and a relative `path` to the asset that backs it. Adding a NEW
  KIND is a deliberate core edit (it means a new extension point); adding a new
  PLUGIN is just a package — zero core change.

  Kinds and the asset each expects:

    * `:command_pack`     — a `commands/` dir of capability-tokenized `*.md` bodies
    * `:workflow_type`    — a JSON file: `{slug, label, description, steps[]}`
    * `:agent_template`   — an `agents/` dir of markdown-with-frontmatter templates
    * `:skill`            — a `skills/` dir of `<name>/SKILL.md` Agent Skill bundles
      (forge-meta-artifact-generation; materialized into `.claude/skills/` by
      `RepoBuilder.Plugins.SkillPack`)
    * `:context_fragment` — a markdown file appended to the orchestrator system prompt
    * `:capability`       — a JSON file of stack markers + capability defaults
    * `:quality_gate`     — a JSON gate descriptor: an ordered, stack-aware set of
      quality stages (format · lint · type · test · mutation) the orchestrator runs at
      each workstream phase's `:test` stage (see `RepoBuilder.Plugins.QualityGate`)
    * `:harness_adapter`  — registered by a code plugin (see `RepoBuilder.Plugins.Code`)
    * `:mcp_tools`        — a tool-bundle descriptor (kind reserved; wiring is follow-on)
  """
  use TypedStruct

  @typedoc "The closed set of contribution kinds (open plugin id, closed contract)."
  @type kind ::
          :command_pack
          | :workflow_type
          | :agent_template
          | :skill
          | :context_fragment
          | :capability
          | :quality_gate
          | :harness_adapter
          | :mcp_tools

  @kinds ~w(command_pack workflow_type agent_template skill context_fragment capability quality_gate harness_adapter mcp_tools)a
  @kind_strings Enum.map(@kinds, &Atom.to_string/1)

  typedstruct enforce: true do
    @typedoc "One declared contribution: a closed `kind`, a relative asset `path`, and free `meta`."
    field :kind, kind()
    field :path, String.t(), enforce: false
    field :meta, map(), default: %{}
  end

  @doc "The closed list of contribution kinds, in declaration order."
  @spec kinds() :: [kind(), ...]
  def kinds, do: @kinds

  @doc "Whether `value` is one of the closed kinds."
  @spec kind?(term()) :: boolean()
  def kind?(value), do: value in @kinds

  @doc """
  Cast an untrusted wire string to a closed kind atom. Uses
  `String.to_existing_atom/1` against the pre-declared set — never `to_atom/1` on
  untrusted input (§3 rule 6).
  """
  @spec cast_kind(term()) :: {:ok, kind()} | {:error, :unknown_kind}
  def cast_kind(string) when is_binary(string) do
    if string in @kind_strings do
      {:ok, String.to_existing_atom(string)}
    else
      {:error, :unknown_kind}
    end
  end

  def cast_kind(_string), do: {:error, :unknown_kind}

  @doc """
  Normalize one untrusted wire contribution map (`%{"kind" => ..., "path" => ...}`)
  into a typed `Contribution`. Never raises; unknown kinds are rejected.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, :unknown_kind | :invalid_contribution}
  def from_wire(%{"kind" => kind_str} = raw) when is_binary(kind_str) do
    case cast_kind(kind_str) do
      {:ok, kind} ->
        {:ok,
         %__MODULE__{
           kind: kind,
           path: wire_path(raw["path"]),
           meta: Map.drop(raw, ["kind", "path"])
         }}

      {:error, _} = error ->
        error
    end
  end

  def from_wire(_raw), do: {:error, :invalid_contribution}

  @spec wire_path(term()) :: String.t() | nil
  defp wire_path(path) when is_binary(path), do: path
  defp wire_path(_path), do: nil
end
