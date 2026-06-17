defmodule RepoBuilder.Orchestrator.Template do
  @moduledoc """
  A single subagent template — a named, versioned worker recipe (description +
  system-prompt body + optional model/category/harness) stored as a markdown file
  with YAML frontmatter (the portable `.claude/agents/*.md` format). This module is
  the typed domain value plus the frontmatter PARSE/SERIALIZE/VALIDATE pair; ALL
  filesystem I/O lives in `RepoBuilder.Orchestrator.Templates`.

  The `tools` frontmatter field from the reference format is intentionally dropped —
  our workers inherit harness-default tools (per-worker allowlisting is out of scope).
  """
  use TypedStruct

  alias RepoBuilder.Orchestrators

  @type reason :: atom() | String.t()
  @type author :: :operator | :orchestrator

  typedstruct enforce: true do
    field :name, String.t()
    field :description, String.t()
    field :body, String.t()
    field :model, String.t() | nil, default: nil
    field :category, String.t() | nil, default: nil
    field :harness, String.t() | nil, default: nil
    field :version, pos_integer()
    field :author, author()
    field :updated_at, DateTime.t()
  end

  @name_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc """
  Parse a complete template markdown document into a flat string-keyed attrs map
  (frontmatter keys + `"body"`). Splits on the leading `---` fences, reads the
  frontmatter with `YamlElixir`, and takes the remainder as the body. Never raises.
  """
  @spec from_markdown(String.t()) :: {:ok, map()} | {:error, reason()}
  def from_markdown(markdown) when is_binary(markdown) do
    case split_frontmatter(markdown) do
      {:ok, yaml, body} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, map} when is_map(map) ->
            {:ok, Map.put(map, "body", String.trim(body))}

          {:ok, _other} ->
            {:error, :invalid_frontmatter}

          {:error, _reason} ->
            {:error, :invalid_frontmatter}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def from_markdown(_other), do: {:error, :invalid_markdown}

  @doc """
  Serialize a `Template` into a complete markdown document: a flat YAML frontmatter
  block (built by hand — no serializer dependency) followed by the body.
  """
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = template) do
    lines =
      [
        {"name", template.name},
        {"description", template.description},
        {"version", template.version},
        {"author", Atom.to_string(template.author)},
        {"updated_at", DateTime.to_iso8601(template.updated_at)},
        {"model", template.model},
        {"category", template.category},
        {"harness", template.harness}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{yaml_scalar(value)}" end)

    "---\n#{lines}\n---\n\n#{template.body}\n"
  end

  @doc """
  Validate a string-keyed attrs map: `name` kebab-case + non-empty, `description`
  and `body` non-empty, and `category` (when present) one of the worker tiers.
  """
  @spec validate(map()) :: :ok | {:error, reason()}
  def validate(attrs) when is_map(attrs) do
    with :ok <- validate_name(attrs["name"]),
         :ok <- validate_non_empty(attrs["description"], :description),
         :ok <- validate_non_empty(attrs["body"], :body) do
      validate_category(attrs["category"])
    end
  end

  def validate(_other), do: {:error, :invalid_attrs}

  @spec validate_name(term()) :: :ok | {:error, :invalid_name | :missing_name}
  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, :invalid_name}
  end

  defp validate_name(_name), do: {:error, :missing_name}

  @spec validate_non_empty(term(), :description | :body) :: :ok | {:error, atom()}
  defp validate_non_empty(value, _field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_attrs}, else: :ok
  end

  defp validate_non_empty(_value, field), do: {:error, :"missing_#{field}"}

  @spec validate_category(term()) :: :ok | {:error, :invalid_category}
  defp validate_category(nil), do: :ok

  defp validate_category(category) when is_binary(category) do
    if category in Orchestrators.agent_categories(),
      do: :ok,
      else: {:error, :invalid_category}
  end

  defp validate_category(_category), do: {:error, :invalid_category}

  # Split a `---`-fenced document into {frontmatter_yaml, body}. Tolerant of a
  # leading blank line; a doc with no frontmatter is an error.
  @spec split_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | {:error, reason()}
  defp split_frontmatter(markdown) do
    case String.split(markdown, ~r/^---\s*$/m, parts: 3) do
      [leading, yaml, body] ->
        if String.trim(leading) == "",
          do: {:ok, yaml, body},
          else: {:error, :missing_frontmatter}

      _other ->
        {:error, :missing_frontmatter}
    end
  end

  # Flat YAML scalar emission: integers verbatim; strings double-quoted with the two
  # characters that would break a quoted scalar (`\` and `"`) escaped.
  @spec yaml_scalar(String.t() | integer()) :: String.t()
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)

  defp yaml_scalar(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end
end
