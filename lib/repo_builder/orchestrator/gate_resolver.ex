defmodule RepoBuilder.Orchestrator.GateResolver do
  @moduledoc """
  Resolve the ACTIVE quality gate for a project (quality-gate-plugins). Walks a precedence
  chain and returns the first descriptor found, token-filled and variant-selected:

      1. active plugin — a `:quality_gate` contribution (`Activation.contributions/2`)
      2. builtin stack — `priv/quality_gates/<stack>.json` for the project's detected stack
      3. generic       — `priv/quality_gates/generic.json`

  Each stage's capability-tokenized `command` is filled from the project's capabilities via
  `CapabilityTokens`; a stage whose required token is EMPTY is dropped (never emit a broken
  command). The type stage is encoded in two forms in the descriptor (`variant: "standard"`
  / `"strict"`) and this resolver selects one by `capabilities.typed_enforcement`:

    * `:off`      — the type stage is dropped entirely
    * `:standard` — the plain `{{TYPECHECK_COMMAND}}` stage is kept
    * `:strict`   — the strict checker + annotation-coverage sub-stage are kept, UNLESS a
      required strict token is empty, in which case it DEGRADES to `:standard` and flags it

  Pure and fail-silent — never raises. `{:error, :none}` only when no descriptor is found.
  """
  use TypedStruct

  alias RepoBuilder.Plugins.Activation
  alias RepoBuilder.Plugins.QualityGate
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.Projects.CapabilityTokens
  alias RepoBuilder.Projects.Project

  # Detected-stack language → builtin gate descriptor stack key. Anything else ⇒ "generic".
  @stack_gates %{
    "elixir" => "elixir",
    "python" => "python",
    "rust" => "rust",
    "go" => "go",
    "node" => "typescript",
    "typescript" => "typescript",
    "ts" => "typescript",
    "ruby" => "ruby"
  }

  # Any `{{TOKEN}}` in a stage command.
  @token_re ~r/\{\{[A-Z_]+\}\}/

  typedstruct module: ResolvedStage, enforce: true do
    @typedoc "One token-filled, ready-to-run gate stage."
    field :id, String.t()
    field :label, String.t()
    field :command, String.t()
    field :strict, boolean()
    field :cadence, QualityGate.cadence()
    field :diagnostic, QualityGate.diagnostic()
    field :continue_on_fail, boolean()
  end

  typedstruct enforce: true do
    @typedoc "The resolved, ordered, token-filled gate for a project."
    field :stack, String.t()
    field :source, atom()
    field :typed_enforcement, Capabilities.typed_enforcement()
    field :degraded, boolean(), default: false
    field :stages, [ResolvedStage.t()], default: []
  end

  @doc """
  Resolve the active gate for `project`. `{:error, :none}` when no descriptor resolves
  (e.g. the generic builtin is missing — should not happen in a normal install).
  """
  @spec resolve(Project.t()) :: {:ok, t()} | {:error, :none}
  def resolve(%Project{} = project) do
    caps = capabilities(project)

    case descriptor(project) do
      {:ok, source, %QualityGate{} = gate} -> {:ok, build(gate, source, caps)}
      :error -> {:error, :none}
    end
  end

  # The first descriptor across the precedence chain, tagged with its source.
  @spec descriptor(Project.t()) :: {:ok, atom(), QualityGate.t()} | :error
  defp descriptor(%Project{} = project) do
    Enum.find_value(
      [
        {:plugin, fn -> plugin_descriptor(project) end},
        {:builtin, fn -> builtin_descriptor(stack_key(project)) end},
        {:generic, fn -> builtin_descriptor("generic") end}
      ],
      :error,
      fn {source, load} ->
        case load.() do
          {:ok, gate} -> {:ok, source, gate}
          _ -> false
        end
      end
    )
  end

  # The highest-priority active `:quality_gate` plugin contribution that parses. Fail-silent:
  # a DB/plugin error (or a call from a process without DB access) falls through to builtin.
  @spec plugin_descriptor(Project.t()) :: {:ok, QualityGate.t()} | :error
  defp plugin_descriptor(%Project{id: project_id}) do
    project_id
    |> Activation.contributions(:quality_gate)
    |> Enum.find_value(:error, fn %Activation.Resolved{abs_path: path} ->
      case path && QualityGate.read(path) do
        {:ok, gate} -> {:ok, gate}
        _ -> false
      end
    end)
  rescue
    _error -> :error
  end

  @spec builtin_descriptor(String.t()) :: {:ok, QualityGate.t()} | :error
  defp builtin_descriptor(stack) do
    case QualityGate.read(builtin_path(stack)) do
      {:ok, gate} -> {:ok, gate}
      _ -> :error
    end
  end

  @doc "Absolute path to a builtin gate descriptor for `stack` under `priv/quality_gates/`."
  @spec builtin_path(String.t()) :: String.t()
  def builtin_path(stack) when is_binary(stack) do
    Application.app_dir(:repo_builder, "priv/quality_gates/#{stack}.json")
  end

  @spec stack_key(Project.t()) :: String.t()
  defp stack_key(%Project{} = project) do
    language = capabilities(project).language
    Map.get(@stack_gates, language, "generic")
  end

  @spec capabilities(Project.t()) :: Capabilities.t()
  defp capabilities(%Project{capabilities: caps, stack: stack}) do
    if is_map(caps) and map_size(caps) > 0,
      do: Capabilities.from_map(caps),
      else: Capabilities.detect(stack || %{})
  end

  # Build the ResolvedGate: select the type-stage variant, fill tokens, drop empty stages.
  @spec build(QualityGate.t(), atom(), Capabilities.t()) :: t()
  defp build(%QualityGate{stack: stack, stages: stages}, source, %Capabilities{} = caps) do
    # `typed_enforcement` is a closed atom with a `:strict` struct default, so it is never nil.
    enforcement = caps.typed_enforcement
    {keep_variant, degraded} = variant_decision(stages, enforcement, caps)

    resolved =
      stages
      |> Enum.filter(&variant_kept?(&1, keep_variant))
      |> Enum.map(&fill_stage(&1, caps))
      |> Enum.reject(&is_nil/1)

    %__MODULE__{
      stack: stack,
      source: source,
      typed_enforcement: enforcement,
      degraded: degraded,
      stages: resolved
    }
  end

  # Decide which type-variant to keep and whether `:strict` degraded to `:standard`.
  @spec variant_decision(
          [QualityGate.Stage.t()],
          Capabilities.typed_enforcement(),
          Capabilities.t()
        ) :: {atom() | nil, boolean()}
  defp variant_decision(_stages, :off, _caps), do: {:none, false}
  defp variant_decision(_stages, :standard, _caps), do: {:standard, false}

  defp variant_decision(stages, :strict, caps) do
    strict_stages = Enum.filter(stages, &(&1.variant == :strict))

    if strict_stages != [] and Enum.all?(strict_stages, &fillable?(&1.command, caps)),
      do: {:strict, false},
      else: {:standard, true}
  end

  # Keep a stage: a non-type stage (variant nil) always; a type stage only when its variant
  # matches the selected one (`:none` keeps no type stage — the `:off` policy).
  @spec variant_kept?(QualityGate.Stage.t(), atom() | nil) :: boolean()
  defp variant_kept?(%QualityGate.Stage{variant: nil}, _keep), do: true
  defp variant_kept?(%QualityGate.Stage{variant: variant}, keep), do: variant == keep

  # Fill a stage's command; drop it (nil) when a required token is empty.
  @spec fill_stage(QualityGate.Stage.t(), Capabilities.t()) :: ResolvedStage.t() | nil
  defp fill_stage(%QualityGate.Stage{} = stage, caps) do
    if fillable?(stage.command, caps) do
      %ResolvedStage{
        id: stage.id,
        label: stage.label,
        command: CapabilityTokens.fill(stage.command, caps),
        strict: stage.strict,
        cadence: stage.cadence,
        diagnostic: stage.diagnostic,
        continue_on_fail: stage.continue_on_fail
      }
    end
  end

  # A command is fillable when every `{{TOKEN}}` it references has a non-empty capability
  # value. A command with NO tokens (a literal) is always fillable.
  @spec fillable?(String.t(), Capabilities.t()) :: boolean()
  defp fillable?(command, caps) do
    @token_re
    |> Regex.scan(command)
    |> List.flatten()
    |> Enum.all?(&(CapabilityTokens.value_for(&1, caps) != nil))
  end
end
