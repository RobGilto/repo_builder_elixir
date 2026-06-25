defmodule RepoBuilder.Plugins.Manifest do
  @moduledoc """
  The typed plugin manifest (`plugin.json`, schema `agentic.plugin/1`) and its
  WIRE → DOMAIN boundary.

  A plugin package's `plugin.json` is untrusted external data. `parse/1` decodes it
  with `Jason.decode/1`, validates the decoded value against a permissive TypeCheck
  `@type! wire` (string-keyed JSON object), then NORMALIZES it into this strict
  struct — the wire-type ≠ domain-type discipline (BUILD_PROMPT.md §3 rule 6). It
  NEVER raises: malformed JSON, an unknown contribution kind, a missing required
  field, or a bad semver each return a tagged `{:error, reason}`.

  Identity (`id`) is an OPEN string, like a harness key (§10); the closed contract is
  the set of `Contribution` kinds.
  """
  use TypedStruct
  use TypeCheck

  alias RepoBuilder.Plugins.Contribution

  @schema "agentic.plugin/1"

  typedstruct enforce: true do
    field :id, String.t()
    field :name, String.t()
    field :version, String.t()
    field :description, String.t(), enforce: false
    field :author, String.t(), enforce: false
    field :compat, map(), default: %{}
    field :requires, map(), default: %{}
    field :contributions, [Contribution.t()], default: []
    field :code, map(), enforce: false
    field :checksum, String.t(), enforce: false
    field :source, String.t(), enforce: false
  end

  defmodule Wire do
    @moduledoc """
    The permissive wire types, in a NESTED module so `Manifest.conforms?/1` can drive
    them through TypeCheck's COMPILE-TIME `conforms?/2` macro (statically boolean
    `match?/2`) instead of the runtime `dynamic_conforms?/2`. The macro cannot reference
    a `@type!` defined in its own compilation module — hence the split. This also keeps
    `conforms?/1` Dialyzer-clean: the runtime form calls the `@type!`-generated `wire/0`
    builder, which Dialyzer reads as `:no_return`, poisoning `conforms?` into a
    false-positive `extra_range`. The inlined macro has no such call. Pinned to
    type_check 0.13.7 (latest; no newer release supports Elixir 1.20).
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

    @typedoc "A wire manifest: a string-keyed JSON object."
    @type! wire :: %{optional(binary()) => wire_value()}
  end

  @type reason ::
          :invalid_json
          | :invalid_manifest
          | :missing_required_fields
          | :bad_version
          | :invalid_contributions
          | :unknown_kind
          | :invalid_contribution

  @doc "The manifest filename inside a plugin package."
  @spec filename() :: String.t()
  def filename, do: "plugin.json"

  @doc "The supported manifest schema tag."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Parse a raw `plugin.json` string into a typed `Manifest`. Total — returns
  `{:error, reason}` on any malformed input, never raises.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, reason()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, raw} -> from_map(raw)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc "Read + parse a package's `plugin.json` from its directory."
  @spec read(String.t()) :: {:ok, t()} | {:error, reason() | :enoent}
  def read(dir) when is_binary(dir) do
    path = Path.join(dir, filename())

    case File.read(path) do
      {:ok, json} -> parse(json)
      {:error, _} -> {:error, :enoent}
    end
  end

  @doc "Normalize an already-decoded wire map into a typed `Manifest`."
  @spec from_map(term()) :: {:ok, t()} | {:error, reason()}
  def from_map(raw) when is_map(raw) do
    if string_keyed?(raw), do: normalize(raw), else: {:error, :invalid_manifest}
  end

  def from_map(_raw), do: {:error, :invalid_manifest}

  @doc """
  Whether a decoded value conforms to the permissive wire shape via the TypeCheck
  `@type! wire` — the genuine runtime wire-type boundary (BUILD_PROMPT.md §3 rule 6).
  Total; never raises.
  """
  @spec conforms?(term()) :: boolean()
  def conforms?(value) when is_map(value), do: TypeCheck.conforms?(value, Wire.wire())
  def conforms?(_value), do: false

  # Structural gate for control flow (a JSON object loads with string keys). Kept
  # separate from `conforms?/1` so the `{:ok, …}` success path stays statically visible.
  @spec string_keyed?(map()) :: boolean()
  defp string_keyed?(value), do: Enum.all?(Map.keys(value), &is_binary/1)

  @spec normalize(map()) :: {:ok, t()} | {:error, reason()}
  defp normalize(%{"id" => id, "name" => name, "version" => version} = raw)
       when is_binary(id) and is_binary(name) and is_binary(version) do
    with {:ok, _v} <- valid_version(version),
         {:ok, contributions} <- parse_contributions(Map.get(raw, "contributions", [])) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: version,
         description: stringish(raw["description"]),
         author: stringish(raw["author"]),
         compat: mapish(raw["compat"]),
         requires: mapish(raw["requires"]),
         contributions: contributions,
         code: code_or_nil(raw["code"]),
         checksum: stringish(raw["checksum"]),
         source: stringish(raw["source"])
       }}
    end
  end

  defp normalize(_raw), do: {:error, :missing_required_fields}

  @spec valid_version(String.t()) :: {:ok, Version.t()} | {:error, :bad_version}
  defp valid_version(version) do
    case Version.parse(version) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :bad_version}
    end
  end

  @spec parse_contributions(term()) :: {:ok, [Contribution.t()]} | {:error, reason()}
  defp parse_contributions(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
        case Contribution.from_wire(raw) do
          {:ok, contribution} -> {:cont, {:ok, [contribution | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_contributions(_list), do: {:error, :invalid_contributions}

  @doc """
  Whether the manifest's declared `compat.platform` requirement is satisfied by
  `platform_version`. No requirement ⇒ compatible. A malformed requirement ⇒ false.
  """
  @spec compat?(t(), String.t()) :: boolean()
  def compat?(%__MODULE__{compat: compat}, platform_version) do
    case compat["platform"] || compat[:platform] do
      nil ->
        true

      requirement when is_binary(requirement) ->
        match_requirement?(platform_version, requirement)

      _ ->
        true
    end
  end

  @spec match_requirement?(String.t(), String.t()) :: boolean()
  defp match_requirement?(version, requirement) do
    Version.match?(version, requirement)
  rescue
    Version.InvalidVersionError -> false
    Version.InvalidRequirementError -> false
  end

  @doc """
  Whether the manifest carries a code layer (BEAM modules to load). Used by the
  installer/loader trust gate.
  """
  @spec code?(t()) :: boolean()
  def code?(%__MODULE__{code: code}), do: is_map(code) and map_size(code) > 0

  @doc """
  Verify every contribution's declared asset `path` exists under `base_dir`.
  Contributions without a path (e.g. a code-registered harness) are skipped.
  """
  @spec validate_assets(t(), String.t()) :: :ok | {:error, {:missing_asset, String.t()}}
  def validate_assets(%__MODULE__{contributions: contributions}, base_dir) do
    Enum.reduce_while(contributions, :ok, fn
      %Contribution{path: nil}, _acc ->
        {:cont, :ok}

      %Contribution{path: path}, _acc ->
        if File.exists?(Path.join(base_dir, path)),
          do: {:cont, :ok},
          else: {:halt, {:error, {:missing_asset, path}}}
    end)
  end

  @doc "The running platform version (the `:repo_builder` app vsn), for `compat?/2`."
  @spec platform_version() :: String.t()
  def platform_version do
    case Application.spec(:repo_builder, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  @spec stringish(term()) :: String.t() | nil
  defp stringish(value) when is_binary(value), do: value
  defp stringish(_value), do: nil

  @spec mapish(term()) :: map()
  defp mapish(value) when is_map(value), do: value
  defp mapish(_value), do: %{}

  @spec code_or_nil(term()) :: map() | nil
  defp code_or_nil(value) when is_map(value), do: value
  defp code_or_nil(_value), do: nil
end
