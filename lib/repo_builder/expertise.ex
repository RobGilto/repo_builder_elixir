defmodule RepoBuilder.Expertise do
  @moduledoc """
  The self-improving, code-validated domain MENTAL MODEL (self-healing orchestrator, Phase 5 —
  Voyager-style skill memory). Persisted as versioned `.md` files per domain (often a stack
  layer name), exactly like `Orchestrator.Templates`: a writable `experts_dir` SHADOWS a
  read-only built-in `priv/orchestrator/experts/<domain>/NNNN.md` seed root, append-only with
  free history + `restore/2` + plugin/command-pack portability (no DB migration).

  Two faces:

    * REUSE — `render/1` injects the current model body into a prompt / the stack contract;
      `question/2` is the read-only consumer (returns the model for a domain, makes NO edits).
    * LEARN — `save/3` appends the NEXT version (the ACT→LEARN→REUSE loop's write), trimmed to
      a size cap and re-validated (frontmatter parses, body non-empty).

  This module owns ALL expertise filesystem I/O; every public function is `@spec`'d, returns
  tagged tuples, and never raises on the expected paths.
  """

  @type t :: %{
          domain: String.t(),
          body: String.t(),
          version: pos_integer(),
          updated_at: DateTime.t()
        }

  @type reason :: atom() | String.t()

  @max_body_bytes 16_000
  @max_save_attempts 5
  @version_file_regex ~r/\A(\d+)\.md\z/
  @domain_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc "All domains that have a mental model (across both roots), sorted."
  @spec domains() :: [String.t()]
  def domains do
    read_roots()
    |> Enum.reduce(MapSet.new(), &collect_domains/2)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc "Fetch the CURRENT (highest) version of `domain`'s mental model."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, reason()}
  def fetch(domain) when is_binary(domain) do
    entries = version_entries(domain)

    case Map.keys(entries) do
      [] -> {:error, :not_found}
      keys -> read_version(domain, Enum.max(keys), entries)
    end
  end

  @doc "Render `domain`'s current mental-model body for prompt injection — `\"\"` when absent."
  @spec render(String.t()) :: String.t()
  def render(domain) when is_binary(domain) do
    case fetch(domain) do
      {:ok, %{body: body}} -> body
      {:error, _reason} -> ""
    end
  end

  def render(_domain), do: ""

  @doc """
  The read-only REUSE consumer: return `domain`'s current mental model so a caller can answer a
  domain question from it (citing `module:line`). Makes NO edits — `question` is here for the
  contract; the body is the answer basis.
  """
  @spec question(String.t(), String.t()) :: {:ok, t()} | {:error, reason()}
  def question(domain, _question) when is_binary(domain), do: fetch(domain)

  @doc """
  Append a NEW version of `domain`'s mental model with `body` (the LEARN write). Validates the
  domain name + a non-empty body, trims to the size cap, computes the next version across both
  roots, and writes it atomically to the writable root (never overwrites a version).
  """
  @spec save(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def save(domain, body, _opts \\ []) do
    with :ok <- validate_domain(domain),
         :ok <- validate_body(body) do
      base = %{domain: domain, body: cap(body), version: 1, updated_at: DateTime.utc_now()}
      write_next_version(base, @max_save_attempts)
    end
  end

  @doc "Promote version `k` to a NEW current version (non-destructive restore)."
  @spec restore(String.t(), pos_integer()) :: {:ok, t()} | {:error, reason()}
  def restore(domain, version) when is_binary(domain) and is_integer(version) do
    with {:ok, source} <- fetch_version(domain, version) do
      save(domain, source.body)
    end
  end

  @doc "Fetch a specific version of `domain`'s mental model."
  @spec fetch_version(String.t(), pos_integer()) :: {:ok, t()} | {:error, reason()}
  def fetch_version(domain, version) when is_binary(domain) and is_integer(version) do
    entries = version_entries(domain)

    case Map.has_key?(entries, version) do
      true -> read_version(domain, version, entries)
      false -> {:error, :not_found}
    end
  end

  # --- serialize / parse ---

  @spec to_markdown(t()) :: String.t()
  defp to_markdown(%{domain: domain, body: body, version: version, updated_at: updated_at}) do
    """
    ---
    domain: "#{domain}"
    version: #{version}
    updated_at: "#{DateTime.to_iso8601(updated_at)}"
    ---

    #{body}
    """
  end

  @spec from_markdown(String.t(), String.t(), pos_integer()) :: {:ok, t()} | {:error, reason()}
  defp from_markdown(markdown, domain, version) do
    case String.split(markdown, ~r/^---\s*$/m, parts: 3) do
      [leading, yaml, body] ->
        if String.trim(leading) == "",
          do: build_model(yaml, body, domain, version),
          else: {:error, :missing_frontmatter}

      _other ->
        {:error, :missing_frontmatter}
    end
  end

  @spec build_model(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, t()} | {:error, reason()}
  defp build_model(yaml, body, domain, version) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) ->
        {:ok,
         %{
           domain: domain,
           body: String.trim(body),
           version: version,
           updated_at: parse_datetime(map["updated_at"])
         }}

      _other ->
        {:error, :invalid_frontmatter}
    end
  end

  # --- versioning / IO (mirrors Orchestrator.Templates) ---

  @spec write_next_version(t(), non_neg_integer()) :: {:ok, t()} | {:error, reason()}
  defp write_next_version(_base, 0), do: {:error, :version_conflict}

  defp write_next_version(base, attempts) do
    next = max_version(base.domain) + 1
    model = %{base | version: next, updated_at: DateTime.utc_now()}
    path = version_path(writable_root(), base.domain, next)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.open(path, [:write, :exclusive]) do
        {:ok, io} ->
          _ = IO.binwrite(io, to_markdown(model))
          _ = File.close(io)
          {:ok, model}

        {:error, :eexist} ->
          write_next_version(base, attempts - 1)

        {:error, posix} ->
          {:error, posix}
      end
    end
  end

  @spec read_version(String.t(), pos_integer(), %{pos_integer() => String.t()}) ::
          {:ok, t()} | {:error, reason()}
  defp read_version(domain, version, entries) do
    path = Map.fetch!(entries, version)

    with {:ok, raw} <- read_utf8(path) do
      from_markdown(raw, domain, version)
    end
  end

  @spec read_utf8(String.t()) :: {:ok, String.t()} | {:error, reason()}
  defp read_utf8(path) do
    case File.read(path) do
      {:ok, content} -> if String.valid?(content), do: {:ok, content}, else: {:error, :not_utf8}
      {:error, posix} -> {:error, posix}
    end
  end

  @spec version_entries(String.t()) :: %{pos_integer() => String.t()}
  defp version_entries(domain) do
    Enum.reduce(read_roots(), %{}, fn root, acc ->
      collect_versions(Path.join(root, domain), acc)
    end)
  end

  @spec read_roots() :: [String.t()]
  defp read_roots, do: [builtin_root(), writable_root()]

  @spec collect_versions(String.t(), %{pos_integer() => String.t()}) ::
          %{pos_integer() => String.t()}
  defp collect_versions(dir, acc) do
    case File.ls(dir) do
      {:ok, files} -> Enum.reduce(files, acc, &put_version(dir, &1, &2))
      {:error, _posix} -> acc
    end
  end

  @spec put_version(String.t(), String.t(), %{pos_integer() => String.t()}) ::
          %{pos_integer() => String.t()}
  defp put_version(dir, file, acc) do
    case Regex.run(@version_file_regex, file) do
      [_match, digits] -> Map.put(acc, String.to_integer(digits), Path.join(dir, file))
      _no_match -> acc
    end
  end

  @spec max_version(String.t()) :: non_neg_integer()
  defp max_version(domain) do
    case Map.keys(version_entries(domain)) do
      [] -> 0
      keys -> Enum.max(keys)
    end
  end

  @spec collect_domains(String.t(), MapSet.t(String.t())) :: MapSet.t(String.t())
  defp collect_domains(root, acc) do
    case File.ls(root) do
      {:ok, entries} -> Enum.reduce(entries, acc, &put_domain(root, &1, &2))
      {:error, _posix} -> acc
    end
  end

  @spec put_domain(String.t(), String.t(), MapSet.t(String.t())) :: MapSet.t(String.t())
  defp put_domain(root, entry, acc) do
    if File.dir?(Path.join(root, entry)), do: MapSet.put(acc, entry), else: acc
  end

  @spec version_path(String.t(), String.t(), pos_integer()) :: String.t()
  defp version_path(root, domain, version) do
    padded = version |> Integer.to_string() |> String.pad_leading(4, "0")
    Path.join([root, domain, "#{padded}.md"])
  end

  # --- validation / config ---

  # Inference-only specs — the concrete error atoms narrow below the `reason()` range,
  # which Dialyzer rejects as a contract supertype.
  defp validate_domain(domain) when is_binary(domain) do
    if Regex.match?(@domain_regex, domain), do: :ok, else: {:error, :invalid_domain}
  end

  defp validate_domain(_domain), do: {:error, :invalid_domain}

  defp validate_body(body) when is_binary(body) do
    if String.trim(body) == "", do: {:error, :empty_body}, else: :ok
  end

  defp validate_body(_body), do: {:error, :invalid_body}

  @spec cap(String.t()) :: String.t()
  defp cap(body), do: String.slice(body, 0, @max_body_bytes)

  @spec writable_root() :: String.t()
  defp writable_root do
    case Application.get_env(:repo_builder, :orchestrator, [])[:experts_dir] do
      dir when is_binary(dir) -> dir
      _nil -> Path.expand("~/.repo_builder/experts")
    end
  end

  @spec builtin_root() :: String.t()
  defp builtin_root do
    case Application.get_env(:repo_builder, :orchestrator, [])[:experts_builtin_dir] do
      dir when is_binary(dir) -> dir
      _nil -> Application.app_dir(:repo_builder, "priv/orchestrator/experts")
    end
  end

  @spec parse_datetime(term()) :: DateTime.t()
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_other), do: DateTime.utc_now()
end
