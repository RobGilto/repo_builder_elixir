defmodule RepoBuilder.Adw.StepSpec do
  @moduledoc """
  A single step in a saved ADW combo. Carries the canonical step name (atom from the
  allowlist), an optional custom prompt, and optional per-step `harness`/`provider`/`model`
  overrides. Blank/nil fields mean "inherit the build-level default."

  ## Wire format (JSON sidecar)
  `from_json/1` accepts three legacy shapes for backward-compatibility:
    - plain string `"plan"` or atom `:plan` → name only, all optional fields nil
    - `%{"name" => "plan", "prompt" => "..."}` legacy two-field map
    - `%{"name" => "plan", "prompt" => ..., "harness" => ..., "provider" => ..., "model" => ...}` full map
  `to_json/1` always emits the full string-keyed map (omits fields whose value is nil).

  `from_builder_map/1` converts a LiveView builder step map
  `%{name: "plan", prompt: ..., harness: ..., provider: ..., model: ...}` into a `StepSpec`.
  """

  use TypedStruct

  @type reason :: atom() | {atom(), term()}

  # Step allowlist — parity with `adws/adw_new.py:VALID_STEPS` and `Scaffold.valid_steps/0`.
  # Fixed string→atom map so untrusted wire strings never reach `String.to_atom/1`.
  @step_atoms %{
    "plan" => :plan,
    "patch" => :patch,
    "build" => :build,
    "test" => :test,
    "review" => :review,
    "document" => :document,
    "ship" => :ship
  }

  typedstruct enforce: true do
    field :name, atom()
    field :prompt, String.t() | nil, enforce: false
    field :harness, String.t() | nil, enforce: false
    field :provider, String.t() | nil, enforce: false
    field :model, String.t() | nil, enforce: false
  end

  @doc """
  Decode one step from its JSON wire representation into a `StepSpec`.
  Accepts: plain string/atom (name-only), legacy `%{"name","prompt"}` map, and the full
  five-field map. Returns `{:error, {:invalid_step, name}}` for unknown step names.
  Never raises.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, reason()}
  def from_json(step) when is_atom(step) and not is_nil(step) do
    from_json(Atom.to_string(step))
  end

  def from_json(step) when is_binary(step) do
    case Map.fetch(@step_atoms, step) do
      {:ok, atom} ->
        {:ok, %__MODULE__{name: atom, prompt: nil, harness: nil, provider: nil, model: nil}}

      :error ->
        {:error, {:invalid_step, step}}
    end
  end

  def from_json(%{"name" => name} = map) when is_binary(name) do
    case Map.fetch(@step_atoms, name) do
      {:ok, atom} ->
        {:ok,
         %__MODULE__{
           name: atom,
           prompt: blank(Map.get(map, "prompt")),
           harness: blank(Map.get(map, "harness")),
           provider: blank(Map.get(map, "provider")),
           model: blank(Map.get(map, "model"))
         }}

      :error ->
        {:error, {:invalid_step, name}}
    end
  end

  def from_json(%__MODULE__{} = spec), do: {:ok, spec}

  def from_json(_other), do: {:error, :invalid_step}

  @doc "Serialize a `StepSpec` to its string-keyed JSON wire map. Omits nil fields."
  @spec to_json(t()) :: %{required(String.t()) => term()}
  def to_json(%__MODULE__{} = spec) do
    base = %{"name" => Atom.to_string(spec.name)}

    base
    |> maybe_put("prompt", spec.prompt)
    |> maybe_put("harness", spec.harness)
    |> maybe_put("provider", spec.provider)
    |> maybe_put("model", spec.model)
  end

  @doc """
  Build a `StepSpec` from a LiveView builder step map. Accepts atom or string keys.
  Blank strings normalize to nil. Unknown step names return `{:error, {:unknown_step, name}}`.
  """
  @spec from_builder_map(map()) :: {:ok, t()} | {:error, reason()}
  def from_builder_map(map) when is_map(map) do
    name = field(map, :name)

    case Map.fetch(@step_atoms, to_string(name || "")) do
      {:ok, atom} ->
        {:ok,
         %__MODULE__{
           name: atom,
           prompt: blank(field(map, :prompt)),
           harness: blank(field(map, :harness)),
           provider: blank(field(map, :provider)),
           model: blank(field(map, :model))
         }}

      :error ->
        {:error, {:unknown_step, to_string(name || "")}}
    end
  end

  def from_builder_map(_other), do: {:error, :invalid_step}

  @doc "The step allowlist (atoms), parity with `Scaffold.valid_steps/0`."
  @spec valid_steps() :: [atom(), ...]
  def valid_steps, do: Map.values(@step_atoms)

  # --- private ---

  @spec field(map(), :harness | :model | :name | :prompt | :provider) :: term()
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(_other), do: nil

  @spec maybe_put(map(), String.t(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
