defmodule RepoBuilder.Adw.Combo do
  @moduledoc """
  A saved ADW-Builder "combo": the ordered step chain, the `:iso`/`:local_iso`
  flavor, and the default spec + initial prompt an operator wants to reuse. This
  module is the typed DOMAIN value plus the wire (JSON sidecar) PARSE/SERIALIZE/
  VALIDATE pair; all filesystem I/O lives in `RepoBuilder.Adw.Combos` (the
  "no scattered I/O" doctrine, BUILD_PROMPT.md §8).

  ## Wire vs domain (typed-elixir-standard rule 6)
  The on-disk sidecar is an untrusted string-keyed JSON object (steps + flavor as
  strings). `from_json/1` normalizes it into this strict struct (steps as
  `StepSpec.t()` values, flavor as `:iso | :local_iso | :direct`); `to_json/1`
  renders back to the stringly wire map. Neither raises.
  """
  use TypedStruct

  alias RepoBuilder.Adw.StepSpec

  @type reason :: atom() | String.t()
  @type flavor :: :iso | :local_iso | :direct

  @flavors %{"iso" => :iso, "local_iso" => :local_iso, "direct" => :direct}

  typedstruct enforce: true do
    field :name, String.t()
    field :steps, [StepSpec.t()]
    field :flavor, flavor()
    field :spec, String.t() | nil, default: nil
    field :initial_prompt, String.t() | nil, default: nil
    field :harness, String.t() | nil, enforce: false
    field :script_path, String.t()
    field :updated_at, DateTime.t()
  end

  @doc """
  Validate a combo attrs map (atom OR string keys): `name` must slugify to a
  non-empty filename stem, `steps` must be a non-empty list drawn from the
  allowlist, and `flavor` (when present) must be `:iso | :local_iso | :direct`. Total.
  """
  @spec validate(map()) :: :ok | {:error, reason()}
  def validate(attrs) when is_map(attrs) do
    with {:ok, _stem} <- slugify_name(get(attrs, :name)),
         {:ok, _steps} <- parse_steps(get(attrs, :steps)),
         {:ok, _flavor} <- parse_flavor(get(attrs, :flavor)) do
      validate_harness(get(attrs, :harness))
    end
  end

  def validate(_other), do: {:error, :invalid_attrs}

  @doc "Serialize a combo into its string-keyed JSON sidecar map."
  @spec to_json(t()) :: %{optional(String.t()) => term()}
  def to_json(%__MODULE__{} = combo) do
    %{
      "name" => combo.name,
      "steps" => Enum.map(combo.steps, &StepSpec.to_json/1),
      "flavor" => Atom.to_string(combo.flavor),
      "spec" => combo.spec,
      "initial_prompt" => combo.initial_prompt,
      "harness" => combo.harness,
      "script_path" => combo.script_path,
      "updated_at" => DateTime.to_iso8601(combo.updated_at)
    }
  end

  @doc """
  Decode a string-keyed sidecar map into a `Combo`. Rejects a missing/invalid name,
  empty/unknown steps, or unknown flavor; blank spec/prompt normalize to `nil`.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, reason()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- fetch_string(map, "name"),
         {:ok, steps} <- parse_steps(Map.get(map, "steps")),
         {:ok, flavor} <- parse_flavor(Map.get(map, "flavor")) do
      {:ok,
       %__MODULE__{
         name: name,
         steps: steps,
         flavor: flavor,
         spec: blank(Map.get(map, "spec")),
         initial_prompt: blank(Map.get(map, "initial_prompt")),
         harness: blank(Map.get(map, "harness")),
         script_path: to_string(Map.get(map, "script_path", "")),
         updated_at: parse_datetime(Map.get(map, "updated_at"))
       }}
    end
  end

  def from_json(_other), do: {:error, :invalid_json}

  @doc """
  Map a display name to the `adw_<stem>` filename stem: lowercase, non-alphanumeric
  runs → single underscore, trimmed. Rejects a name that slugifies to empty (which
  also blocks path-separator-only / traversal names). Never raises.
  """
  @spec slugify_name(term()) :: {:ok, String.t()} | {:error, reason()}
  def slugify_name(name) when is_binary(name) do
    stem =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if stem == "", do: {:error, :invalid_name}, else: {:ok, stem}
  end

  def slugify_name(_name), do: {:error, :missing_name}

  @doc """
  Normalize a steps list into `[StepSpec.t()]`. Accepts all legacy shapes:
  - Old wire: plain strings/atoms, `{atom, prompt}` tuples, `%{"name","prompt"}` maps
  - New wire: `%{"name","prompt","harness","provider","model"}` maps
  - In-memory: `StepSpec` structs passed through unchanged
  Delegates each entry to `StepSpec.from_json/1` for backward-compatible parsing.
  """
  @spec parse_steps(term()) :: {:ok, [StepSpec.t()]} | {:error, reason()}
  def parse_steps(steps) when is_list(steps) and steps != [] do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case parse_step(step) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = err -> err
    end
  end

  def parse_steps([]), do: {:error, :no_steps}
  def parse_steps(_other), do: {:error, :invalid_steps}

  @spec parse_step(term()) :: {:ok, StepSpec.t()} | {:error, reason()}
  defp parse_step(%StepSpec{} = spec), do: {:ok, spec}

  defp parse_step({step, prompt}) when is_atom(step) and not is_nil(step) do
    case StepSpec.from_json(Atom.to_string(step)) do
      {:ok, spec} -> {:ok, %{spec | prompt: prompt_or_nil(prompt)}}
      err -> err
    end
  end

  defp parse_step(step) when is_atom(step) and not is_nil(step) do
    StepSpec.from_json(Atom.to_string(step))
  end

  defp parse_step(other), do: StepSpec.from_json(other)

  @spec prompt_or_nil(term()) :: String.t() | nil
  defp prompt_or_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp prompt_or_nil(_other), do: nil

  @spec parse_flavor(term()) :: {:ok, flavor()} | {:error, reason()}
  defp parse_flavor(nil), do: {:ok, :iso}
  defp parse_flavor(flavor) when flavor in [:iso, :local_iso, :direct], do: {:ok, flavor}

  defp parse_flavor(flavor) when is_binary(flavor) do
    case Map.fetch(@flavors, flavor) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_flavor, flavor}}
    end
  end

  defp parse_flavor(_other), do: {:error, :invalid_flavor}

  @spec validate_harness(term()) :: :ok | {:error, :invalid_harness}
  defp validate_harness(nil), do: :ok
  defp validate_harness(""), do: :ok
  defp validate_harness(h) when is_binary(h), do: :ok
  defp validate_harness(_other), do: {:error, :invalid_harness}

  @spec get(map(), :flavor | :harness | :name | :steps) :: any()
  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :"missing_#{key}"}
    end
  end

  @spec blank(term()) :: String.t() | nil
  defp blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank(_other), do: nil

  @spec parse_datetime(term()) :: DateTime.t()
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_other), do: DateTime.utc_now()
end
