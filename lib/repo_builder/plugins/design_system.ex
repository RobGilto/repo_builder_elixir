defmodule RepoBuilder.Plugins.DesignSystem do
  @moduledoc """
  The typed DESIGN-SYSTEM descriptor and its WIRE → DOMAIN boundary
  (design-system-plugins).

  A design-system descriptor is a JSON file declaring, for one UI `surface` (`web` or
  `tui`) and `framework`, the design language a worker should build within: a `tokens`
  map (color ramp, spacing/type scale, styling notes), an ordered `components` inventory
  (each a real component tag/package + when-to-use + example), free-text `rules`
  (do/don't, the anti-AI-slop bias, per-framework code-gen rules), and a `paradigm`
  (`immediate` / `mvu` / `retained` / `none`) that tells the agent how much scaffolding a
  full app needs. It is the machine-readable analog of the prose `ui-ux-mvp` skills.

  Like `QualityGate`, the descriptor is untrusted external data: `from_wire/1` validates a
  decoded JSON map against a permissive TypeCheck `@type! wire`, then NORMALIZES it into
  this strict struct — the wire-type ≠ domain-type discipline (BUILD_PROMPT.md §3 rule 6).
  It NEVER raises: malformed JSON, a missing field, an unknown surface/paradigm each
  return a tagged `{:error, reason}`.
  """
  use TypedStruct
  use TypeCheck

  # `:any` is the surface of the framework-agnostic `generic` base descriptor.
  @surfaces [:web, :tui, :any]
  @surface_strings Enum.map(@surfaces, &Atom.to_string/1)

  # The rendering/state paradigm (design-factors §4.1). `:none` ⇒ not a full-screen app
  # (web pages, prompt wizards) — no MVU/immediate-mode scaffolding implied.
  @paradigms [:immediate, :mvu, :retained, :none]
  @paradigm_strings Enum.map(@paradigms, &Atom.to_string/1)

  @typedoc "The UI surface a descriptor targets: server/web, terminal/TUI, or `:any` (the generic base)."
  @type surface :: :web | :tui | :any

  @typedoc "The rendering/state paradigm dictating scaffolding volume (design-factors §4.1)."
  @type paradigm :: :immediate | :mvu | :retained | :none

  @type reason ::
          :invalid_json
          | :invalid_descriptor
          | :missing_required_fields
          | :invalid_components
          | :invalid_component
          | :unknown_surface
          | :unknown_paradigm

  typedstruct module: Component, enforce: true do
    @typedoc "One inventory component: a real tag/package plus when-to-use and an example."
    field :name, String.t()
    field :tag, String.t(), enforce: false
    field :package, String.t(), enforce: false
    field :when_to_use, String.t(), enforce: false
    field :example, String.t(), enforce: false
  end

  typedstruct enforce: true do
    # `surface` / `paradigm` are the parent module's closed atom sets (validated in
    # `normalize/1` against the declared lists); typed as `atom()`-narrowed via the
    # `surface()`/`paradigm()` types on the parent, set only through the casts.
    field :surface, surface()
    field :stack, String.t()
    field :framework, String.t()
    field :paradigm, paradigm(), default: :none
    field :tokens, map(), default: %{}
    field :components, [Component.t()], default: []
    field :rules, [String.t()], default: []
    field :references, [String.t()], default: []
  end

  defmodule Wire do
    @moduledoc """
    The permissive wire types in a NESTED module so `DesignSystem.conforms?/1` drives them
    through TypeCheck's COMPILE-TIME `conforms?/2` macro (statically boolean `match?/2`)
    rather than the runtime `dynamic_conforms?/2` — keeping the boundary Dialyzer-clean,
    exactly as `QualityGate.Wire` / `Manifest.Wire` do.
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

    @typedoc "A wire design-system descriptor: a string-keyed JSON object."
    @type! wire :: %{optional(binary()) => wire_value()}
  end

  @doc "The closed set of UI surfaces."
  @spec surfaces() :: [surface(), ...]
  def surfaces, do: @surfaces

  @doc "The closed set of rendering paradigms."
  @spec paradigms() :: [paradigm(), ...]
  def paradigms, do: @paradigms

  @doc """
  Parse a raw design-system-descriptor JSON string into a typed `DesignSystem`. Total —
  returns `{:error, reason}` on any malformed input, never raises.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, reason()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, raw} -> from_wire(raw)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc "Read + parse a design-system descriptor from an absolute JSON file path."
  @spec read(String.t()) :: {:ok, t()} | {:error, reason() | :enoent}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, json} -> parse(json)
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc """
  Normalize one untrusted wire descriptor map into a typed `DesignSystem`. Never raises;
  a missing `surface`/`stack`/`framework`, an unknown surface/paradigm, or a malformed
  component each return a tagged error.
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
  defp normalize(%{"surface" => surface, "stack" => stack, "framework" => framework} = raw)
       when is_binary(surface) and is_binary(stack) and is_binary(framework) do
    with {:ok, surface_atom} <- cast_surface(surface),
         {:ok, paradigm} <- cast_paradigm(Map.get(raw, "paradigm", "none")),
         {:ok, components} <- parse_components(Map.get(raw, "components", [])) do
      {:ok,
       %__MODULE__{
         surface: surface_atom,
         stack: stack,
         framework: framework,
         paradigm: paradigm,
         tokens: mapish(raw["tokens"]),
         components: components,
         rules: stringlist(raw["rules"]),
         references: stringlist(raw["references"])
       }}
    end
  end

  defp normalize(_raw), do: {:error, :missing_required_fields}

  @spec parse_components(term()) :: {:ok, [Component.t()]} | {:error, reason()}
  defp parse_components(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
        case parse_component(raw) do
          {:ok, component} -> {:cont, {:ok, [component | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_components(_list), do: {:error, :invalid_components}

  @spec parse_component(term()) :: {:ok, Component.t()} | {:error, reason()}
  defp parse_component(%{"name" => name} = raw) when is_binary(name) do
    {:ok,
     %Component{
       name: name,
       tag: stringish(raw["tag"]),
       package: stringish(raw["package"]),
       when_to_use: stringish(raw["when_to_use"]),
       example: stringish(raw["example"])
     }}
  end

  defp parse_component(_raw), do: {:error, :invalid_component}

  # Only ever called with the guaranteed-binary `surface` from `normalize/1`, so a
  # non-binary clause is unreachable (the compiler proves it) — spec narrowed to String.t().
  @spec cast_surface(String.t()) :: {:ok, surface()} | {:error, :unknown_surface}
  defp cast_surface(value) do
    if value in @surface_strings,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, :unknown_surface}
  end

  @spec cast_paradigm(term()) :: {:ok, paradigm()} | {:error, :unknown_paradigm}
  defp cast_paradigm(value) when is_binary(value) do
    if value in @paradigm_strings,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, :unknown_paradigm}
  end

  defp cast_paradigm(_value), do: {:error, :unknown_paradigm}

  @spec stringish(term()) :: String.t() | nil
  defp stringish(value) when is_binary(value), do: value
  defp stringish(_value), do: nil

  @spec mapish(term()) :: map()
  defp mapish(value) when is_map(value), do: value
  defp mapish(_value), do: %{}

  @spec stringlist(term()) :: [String.t()]
  defp stringlist(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp stringlist(_value), do: []
end
