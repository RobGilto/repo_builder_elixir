defmodule RepoBuilder.PromptStandard.Frontmatter do
  @moduledoc """
  Pure YAML-frontmatter splitter for the prompt standard (port of the Python
  `_FRONTMATTER_RE` / `_extract_frontmatter` / `_detect_population` helpers in
  `prompt_builder/validator.py`).

  Unlike `RepoBuilder.Orchestrator.Template.from_markdown/1`, this splitter keeps the three
  outcomes the validator must distinguish separate: frontmatter **presence** (population
  detection + H1), **malformed YAML** (H1 parse failure), and a parsed **`{:ok, map, body}`**.
  The YAML map is left string-keyed — it is the wire boundary and untrusted keys are never
  atomized (typed-standard rule 6). Never raises (rule 8).
  """
  # Anchored, DOTALL — direct port of the Python `^---\s*\n(.*?)\n---\s*\n` with re.DOTALL.
  @frontmatter_re ~r/\A---\s*\n(.*?)\n---\s*\n/s

  @type parsed ::
          {:ok, %{optional(String.t()) => term()}, String.t()} | :absent | {:error, :malformed}

  @doc "Whether the content opens with a `---` … `---` YAML frontmatter fence."
  @spec present?(String.t()) :: boolean()
  def present?(content) when is_binary(content), do: Regex.match?(@frontmatter_re, content)

  @doc """
  Split content into `{:ok, frontmatter_map, body}` when a valid YAML fence is present,
  `:absent` when there is no fence, or `{:error, :malformed}` when the fence is present but
  the YAML does not parse to a mapping. An empty frontmatter block parses to `%{}`.
  """
  @spec parse(String.t()) :: parsed()
  def parse(content) when is_binary(content) do
    case Regex.run(@frontmatter_re, content, return: :index) do
      [{0, full_len}, {group_start, group_len} | _] ->
        yaml = binary_part(content, group_start, group_len)
        body = binary_part(content, full_len, byte_size(content) - full_len)
        parse_yaml(yaml, body)

      _no_match ->
        :absent
    end
  end

  @doc """
  The body after the closing fence (whole content when no fence is present). Extracted
  purely from the fence position, so it is available even when the YAML is malformed —
  matching the Python `content[m.end():]` behavior.
  """
  @spec body(String.t()) :: String.t()
  def body(content) when is_binary(content) do
    case Regex.run(@frontmatter_re, content, return: :index) do
      [{0, full_len} | _] -> binary_part(content, full_len, byte_size(content) - full_len)
      _no_match -> content
    end
  end

  @spec parse_yaml(String.t(), String.t()) ::
          {:ok, %{optional(String.t()) => term()}, String.t()} | {:error, :malformed}
  defp parse_yaml(yaml, body) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map, body}
      # `yaml.safe_load(...) or {}` in Python — empty/None frontmatter is an empty mapping.
      {:ok, nil} -> {:ok, %{}, body}
      {:ok, _non_map} -> {:error, :malformed}
      {:error, _reason} -> {:error, :malformed}
    end
  end
end
