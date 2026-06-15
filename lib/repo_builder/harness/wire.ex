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

  @doc """
  True when `value` is a well-formed JSON object (string keys, JSON-shaped values)
  carrying a binary `"type"` discriminator. Total — never raises.

  Uses the `@type! frame` wire type via TypeCheck's RUNTIME conformance
  (`dynamic_conforms?/2`). The compile-time `conforms?/2` macro cannot reference a
  `@type!` defined in this same module during its own compilation, so the runtime
  variant is used here — which also genuinely exercises the wire type. The
  `harness` argument lets future adapters specialize the contract per harness
  without changing call sites.
  """
  @spec conforms?(term(), atom()) :: boolean()
  def conforms?(value, _harness) when is_map(value) do
    TypeCheck.dynamic_conforms?(value, frame()) and is_binary(Map.get(value, "type"))
  end

  def conforms?(_value, _harness), do: false
end
