defmodule RepoBuilder.Plugins.QualityGate do
  @moduledoc """
  The typed QUALITY-GATE descriptor and its WIRE → DOMAIN boundary
  (quality-gate-plugins).

  A gate descriptor is a JSON file declaring, for one stack, an ORDERED list of quality
  `Stage`s — the five-stage green gate (format · lint · type · test · mutation/property)
  the orchestrator runs at each workstream phase's `:test` stage. Each stage is a
  capability-tokenized shell `command` (e.g. `"{{FORMAT_COMMAND}} --check"`), a `strict`
  flag (a red stage halts the gate), a `cadence` (`:per_phase` run every phase, or
  `:pre_merge` run once at workstream close), and a `diagnostic` format so the fix-worker
  gets located, self-correctable findings.

  Like `Manifest`, the descriptor is untrusted external data: `from_wire/1` validates a
  decoded JSON map against a permissive TypeCheck `@type! wire`, then NORMALIZES it into
  this strict struct — the wire-type ≠ domain-type discipline (BUILD_PROMPT.md §3 rule 6).
  It NEVER raises: malformed JSON, a missing field, an unknown cadence/diagnostic each
  return a tagged `{:error, reason}`.
  """
  use TypedStruct
  use TypeCheck

  @cadences [:per_phase, :pre_merge]
  @cadence_strings Enum.map(@cadences, &Atom.to_string/1)
  @diagnostics [:file_line, :summary, :none]
  @diagnostic_strings Enum.map(@diagnostics, &Atom.to_string/1)

  # The typed-enforcement variants a type stage may be tagged with. Declared here so the
  # atoms exist at compile time for `String.to_existing_atom/1` in `variantish/1`.
  @variants [:standard, :strict, :off]
  @variant_strings Enum.map(@variants, &Atom.to_string/1)

  @typedoc "When a stage runs: every phase (`:per_phase`) or once at workstream close (`:pre_merge`)."
  @type cadence :: :per_phase | :pre_merge

  @typedoc "How a stage's output is parsed for the fix-worker."
  @type diagnostic :: :file_line | :summary | :none

  @type reason ::
          :invalid_json
          | :invalid_descriptor
          | :missing_required_fields
          | :invalid_stages
          | :invalid_stage
          | :unknown_cadence
          | :unknown_diagnostic

  typedstruct module: Stage, enforce: true do
    @typedoc "One ordered gate stage: a tokenized command with a strict flag, cadence, and diagnostic."
    field :id, String.t()
    field :label, String.t()
    field :command, String.t()
    field :strict, boolean(), default: true
    # `cadence` / `diagnostic` are the parent module's closed atom sets (validated in
    # `parse_stage/1` against the declared lists); typed as `atom()` here since a nested
    # typedstruct cannot reference its own parent module's types without a circular alias.
    field :cadence, atom(), default: :per_phase
    field :diagnostic, atom(), default: :file_line
    field :continue_on_fail, boolean(), default: false
    # The `typed_enforcement` variant this stage belongs to, when the descriptor encodes
    # a type stage in two forms: `:standard` (plain checker), `:strict` (strict checker +
    # coverage sub-stage). `nil` ⇒ the stage applies regardless of typed_enforcement.
    field :variant, atom() | nil, enforce: false
  end

  typedstruct enforce: true do
    field :stack, String.t()
    field :stages, [Stage.t()], default: []
  end

  defmodule Wire do
    @moduledoc """
    The permissive wire types in a NESTED module so `QualityGate.conforms?/1` drives them
    through TypeCheck's COMPILE-TIME `conforms?/2` macro (statically boolean `match?/2`)
    rather than the runtime `dynamic_conforms?/2` — keeping the boundary Dialyzer-clean,
    exactly as `Manifest.Wire` does.
    """
    use TypeCheck

    @typedoc "A JSON value as produced by `Jason.decode/1`."
    @type! wire_value ::
             nil
             | boolean()
             | number()
             | binary()
             | [any()]
             | %{optional(binary()) => any()}

    @typedoc "A wire gate descriptor: a string-keyed JSON object."
    @type! wire :: %{optional(binary()) => wire_value()}
  end

  @doc "The closed set of stage cadences."
  @spec cadences() :: [cadence(), ...]
  def cadences, do: @cadences

  @doc "The closed set of diagnostic formats."
  @spec diagnostics() :: [diagnostic(), ...]
  def diagnostics, do: @diagnostics

  @doc """
  Parse a raw gate-descriptor JSON string into a typed `QualityGate`. Total — returns
  `{:error, reason}` on any malformed input, never raises.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, reason()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, raw} -> from_wire(raw)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc "Read + parse a gate descriptor from an absolute JSON file path."
  @spec read(String.t()) :: {:ok, t()} | {:error, reason() | :enoent}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, json} -> parse(json)
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc """
  Normalize one untrusted wire descriptor map into a typed `QualityGate`. Never raises;
  a missing `stack`/`stages`, a non-list `stages`, or an unknown cadence/diagnostic each
  return a tagged error.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, reason()}
  def from_wire(raw) when is_map(raw) do
    if string_keyed?(raw), do: normalize(raw), else: {:error, :invalid_descriptor}
  end

  def from_wire(_raw), do: {:error, :invalid_descriptor}

  @doc """
  Whether a decoded value conforms to the permissive wire shape via the TypeCheck
  `@type! wire` — the genuine runtime wire-type boundary. Total; never raises.
  """
  @spec conforms?(term()) :: boolean()
  def conforms?(value) when is_map(value), do: TypeCheck.conforms?(value, Wire.wire())
  def conforms?(_value), do: false

  @spec string_keyed?(map()) :: boolean()
  defp string_keyed?(value), do: Enum.all?(Map.keys(value), &is_binary/1)

  @spec normalize(map()) :: {:ok, t()} | {:error, reason()}
  defp normalize(%{"stack" => stack, "stages" => stages}) when is_binary(stack) do
    with {:ok, parsed} <- parse_stages(stages) do
      {:ok, %__MODULE__{stack: stack, stages: parsed}}
    end
  end

  defp normalize(_raw), do: {:error, :missing_required_fields}

  @spec parse_stages(term()) :: {:ok, [Stage.t()]} | {:error, reason()}
  defp parse_stages(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
        case parse_stage(raw) do
          {:ok, stage} -> {:cont, {:ok, [stage | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_stages(_list), do: {:error, :invalid_stages}

  @spec parse_stage(term()) :: {:ok, Stage.t()} | {:error, reason()}
  defp parse_stage(%{"id" => id, "command" => command} = raw)
       when is_binary(id) and is_binary(command) do
    with {:ok, cadence} <- cast_cadence(Map.get(raw, "cadence", "per_phase")),
         {:ok, diagnostic} <- cast_diagnostic(Map.get(raw, "diagnostic", "file_line")) do
      {:ok,
       %Stage{
         id: id,
         label: stringish(raw["label"]) || id,
         command: command,
         strict: boolish(raw["strict"], true),
         cadence: cadence,
         diagnostic: diagnostic,
         continue_on_fail: boolish(raw["continue_on_fail"], false),
         variant: variantish(raw["variant"])
       }}
    end
  end

  defp parse_stage(_raw), do: {:error, :invalid_stage}

  @spec cast_cadence(term()) :: {:ok, cadence()} | {:error, :unknown_cadence}
  defp cast_cadence(value) when is_binary(value) do
    if value in @cadence_strings,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, :unknown_cadence}
  end

  defp cast_cadence(_value), do: {:error, :unknown_cadence}

  @spec cast_diagnostic(term()) :: {:ok, diagnostic()} | {:error, :unknown_diagnostic}
  defp cast_diagnostic(value) when is_binary(value) do
    if value in @diagnostic_strings,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, :unknown_diagnostic}
  end

  defp cast_diagnostic(_value), do: {:error, :unknown_diagnostic}

  # `variant` is a closed member of the typed-enforcement set; an unknown/absent value ⇒
  # nil (stage applies regardless of enforcement level). `to_existing_atom` against the
  # declared set keeps untrusted JSON off `to_atom/1`.
  @spec variantish(term()) :: atom() | nil
  defp variantish(value) when is_binary(value) do
    if value in @variant_strings, do: String.to_existing_atom(value), else: nil
  end

  defp variantish(_value), do: nil

  @spec stringish(term()) :: String.t() | nil
  defp stringish(value) when is_binary(value), do: value
  defp stringish(_value), do: nil

  @spec boolish(term(), boolean()) :: boolean()
  defp boolish(value, _default) when is_boolean(value), do: value
  defp boolish(_value, default), do: default
end
