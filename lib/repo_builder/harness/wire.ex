defmodule RepoBuilder.Harness.Wire do
  @moduledoc """
  Permissive WIRE types for the untrusted harness JSON boundary (BUILD_PROMPT.md
  §3 rule 6 / §6 step 3), defined with TypeCheck `@type!` so the pinned `type_check`
  dependency is actually exercised.

  A decoded JSONL frame is validated here as a well-formed JSON object (string keys,
  JSON-shaped values) carrying a `"type"` discriminator BEFORE it is handed to an
  adapter's `normalize/2`. This is the wire-type ≠ domain-type separation: stringly
  external data is checked against the permissive wire shape, then normalized into
  the strict canonical `Event` structs — never poured directly into a domain struct.

  `conforms?/2` is intended to be called optionally from `normalize/2` or the
  runtime `handle_line`. It never raises.
  """
  use TypeCheck

  defmodule Types do
    @moduledoc """
    The permissive wire types, in a NESTED module so `Wire.conforms?/2` can drive them
    through TypeCheck's COMPILE-TIME `conforms?/2` macro (which inlines a statically
    boolean `match?/2`) instead of the runtime `dynamic_conforms?/2`. The macro cannot
    reference a `@type!` defined in its own compilation module — hence the split. This
    also keeps Dialyzer clean: the runtime form calls the `@type!`-generated `frame/0`
    builder, which Dialyzer reads as `:no_return`, poisoning `conforms?` into a
    false-positive `extra_range`. The inlined macro has no such call. Pinned to
    type_check 0.13.7 (latest; no newer release supports Elixir 1.20).
    """
    use TypeCheck

    @typedoc "A JSON value as produced by `Jason.decode/1` (string-keyed objects)."
    @type! json_value ::
             nil
             | boolean()
             | number()
             | binary()
             | [any()]
             | %{optional(binary()) => any()}

    @typedoc "A harness wire frame: a string-keyed JSON object."
    @type! frame :: %{optional(binary()) => json_value()}
  end

  @doc """
  True when `value` is a well-formed JSON object (string keys, JSON-shaped values)
  carrying a binary `"type"` discriminator. Total — never raises.

  Validates against the `Types.frame()` wire type via TypeCheck's compile-time
  `conforms?/2` macro — genuinely exercising the pinned `type_check` dependency. The
  `harness` argument lets future adapters specialize the contract per harness without
  changing call sites.
  """
  @spec conforms?(term(), atom()) :: boolean()
  def conforms?(value, _harness) when is_map(value) do
    case Map.get(value, "type") do
      type when is_binary(type) -> TypeCheck.conforms?(value, Types.frame())
      _ -> false
    end
  end

  def conforms?(_value, _harness), do: false
end
