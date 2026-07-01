defmodule RepoBuilder.ExternalApis.McpImport do
  @moduledoc """
  Pure, deterministic MCP-config parser for smart import
  (issue-external-api-mcp-provisioning).

  Maps the common MCP config shapes — a Claude-Desktop / `.mcp.json`
  `{"mcpServers": {name => server}}` map, or a bare single-server object — onto the
  `RepoBuilder.ExternalApis.ExternalApi.changeset/2` field set, producing a
  `RepoBuilder.ExternalApis.ImportResult`. No `Repo`, no I/O, no LLM: a free, offline,
  exhaustively testable front-end (mirroring `RepoBuilder.Plans.Planner`'s
  deterministic-when-possible doctrine), so smart import works even before any Fast tier
  is assigned.

  Secret-safe: any literal token embedded in the config (a `Bearer <tok>` header, a
  custom auth header, an `env` credential) is stripped into `secret_value` for the
  Deposit-a-secret form. The token NEVER lands in `api_params` (BUILD_PROMPT §6).

  `{:needs_agent, hint}` signals the input is not recognizable structured config (e.g.
  free-form prose) and should fall back to the Fast agent.
  """
  alias RepoBuilder.ExternalApis.ImportResult

  @typedoc "Recognized config → draft, fall-back-to-agent, or a hard parse error."
  @type parse_result :: {:ok, ImportResult.t()} | {:needs_agent, String.t()} | {:error, :empty}

  # Mirror the schema's name/secret shapes so the produced params satisfy the contract.
  @name_format ~r/^[a-z][a-z0-9_-]*$/
  @secret_format ~r/^[A-Z][A-Z0-9_]*$/

  @transports ~w(http sse stdio)

  @doc """
  Parse a pasted `blob` into an `ImportResult` draft, a `{:needs_agent, hint}` fall-back,
  or `{:error, :empty}` for blank input.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(blob) when is_binary(blob) do
    case extract_json(blob) do
      {:ok, json} -> from_json(json)
      :empty -> {:error, :empty}
      :not_json -> {:needs_agent, "input is not JSON; interpreting it as a description"}
    end
  end

  def parse(_blob), do: {:error, :empty}

  # --- JSON extraction ---

  @spec extract_json(String.t()) :: {:ok, map()} | :empty | :not_json
  defp extract_json(blob) do
    case String.trim(blob) do
      "" ->
        :empty

      trimmed ->
        case Jason.decode(strip_fences(trimmed)) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _other -> :not_json
        end
    end
  end

  # Tolerate a Markdown ```json … ``` fence around the config.
  @spec strip_fences(String.t()) :: String.t()
  defp strip_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  # --- shape dispatch ---

  @spec from_json(map()) :: {:ok, ImportResult.t()} | {:needs_agent, String.t()}
  defp from_json(%{"mcpServers" => servers}) when is_map(servers) and map_size(servers) > 0 do
    case Map.to_list(servers) do
      [{name, server}] when is_map(server) ->
        {:ok, map_server(name, server)}

      [{_name, _bad}] ->
        {:needs_agent, "the server entry was not an object"}

      pairs ->
        {:ok, multi_question(pairs)}
    end
  end

  defp from_json(%{"mcpServers" => _empty}),
    do: {:needs_agent, "the mcpServers map was empty or malformed"}

  defp from_json(server) when is_map(server) do
    if single_server?(server) do
      case server_name(server) do
        nil -> {:needs_agent, "the config has no server name; say which server this is"}
        name -> {:ok, map_server(name, server)}
      end
    else
      {:needs_agent, "unrecognized config shape"}
    end
  end

  # A bare object is a single server when it carries any connection detail.
  @spec single_server?(map()) :: boolean()
  defp single_server?(server) do
    Enum.any?(["url", "command", "transport", "type"], &Map.has_key?(server, &1))
  end

  @spec server_name(map()) :: String.t() | nil
  defp server_name(server) do
    case server["name"] do
      name when is_binary(name) and name != "" -> name
      _other -> nil
    end
  end

  # Multiple servers in one map: ask the operator to disambiguate, but pre-draft the
  # first so the form is partially filled.
  @spec multi_question([{String.t(), term()}]) :: ImportResult.t()
  defp multi_question(pairs) do
    names = Enum.map_join(pairs, ", ", fn {name, _server} -> name end)
    {first_name, first_server} = hd(pairs)

    draft =
      if is_map(first_server),
        do: map_server(first_name, first_server),
        else: %ImportResult{action: :question, source: :deterministic}

    %{
      draft
      | action: :question,
        question:
          "Found #{length(pairs)} servers: #{names}. Register them one at a time, or tell " <>
            "me which to register (the form is pre-filled with the first, #{first_name})."
    }
  end

  # --- per-server mapping ---

  @spec map_server(String.t(), map()) :: ImportResult.t()
  defp map_server(raw_name, server) do
    name = sanitize_name(raw_name)
    transport = transport_for(server)
    auth = extract_auth(server, name || raw_name)

    params =
      %{
        "name" => name,
        "transport" => transport,
        "url" => string_or_nil(server["url"]),
        "command" => string_or_nil(server["command"]),
        "args" => string_list(server["args"]),
        "auth_scheme" => auth.scheme,
        "auth_header" => auth.header,
        "secret_name" => auth.secret_name,
        "description" => string_or_nil(server["description"])
      }
      |> drop_nil_values()

    %ImportResult{
      action: action_for(name, transport, server),
      api_params: params,
      secret_name: auth.secret_name,
      secret_value: auth.value,
      question: question_for(name, transport, server),
      source: :deterministic
    }
  end

  # Register only when name + transport + the transport's connection detail are all
  # present and unambiguous; otherwise ask exactly what's missing.
  defp action_for(name, transport, server) do
    cond do
      is_nil(name) -> :question
      is_nil(transport) -> :question
      transport in ["http", "sse"] and is_nil(string_or_nil(server["url"])) -> :question
      transport == "stdio" and is_nil(string_or_nil(server["command"])) -> :question
      true -> :register
    end
  end

  @spec question_for(String.t() | nil, String.t() | nil, map()) :: String.t() | nil
  defp question_for(nil, _transport, _server),
    do: "What should this server be named? (lowercase letters, digits, _ or -)"

  defp question_for(_name, nil, _server),
    do: "Is this an http, sse, or stdio MCP server? I couldn't infer the transport."

  defp question_for(_name, transport, server) when transport in ["http", "sse"] do
    if is_nil(string_or_nil(server["url"])), do: "What is the server URL?", else: nil
  end

  defp question_for(_name, "stdio", server) do
    if is_nil(string_or_nil(server["command"])),
      do: "What command launches this server?",
      else: nil
  end

  defp question_for(_name, _transport, _server), do: nil

  # --- transport inference ---

  @spec transport_for(map()) :: String.t() | nil
  defp transport_for(server) do
    case normalize_transport(server["transport"] || server["type"]) do
      transport when transport in @transports -> transport
      _other -> infer_transport(server)
    end
  end

  @spec normalize_transport(term()) :: String.t() | nil
  defp normalize_transport(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_transport(_value), do: nil

  @spec infer_transport(map()) :: String.t() | nil
  defp infer_transport(server) do
    cond do
      is_binary(string_or_nil(server["command"])) -> "stdio"
      is_binary(url = string_or_nil(server["url"])) -> if sse_url?(url), do: "sse", else: "http"
      true -> nil
    end
  end

  @spec sse_url?(String.t()) :: boolean()
  defp sse_url?(url), do: url |> String.downcase() |> String.ends_with?("/sse")

  # --- auth + secret extraction (secret-safe) ---

  @typep auth :: %{
           scheme: String.t(),
           header: String.t() | nil,
           secret_name: String.t() | nil,
           value: String.t() | nil
         }

  @spec extract_auth(map(), String.t()) :: auth()
  defp extract_auth(server, base_name) do
    headers = as_string_map(server["headers"])
    env = as_string_map(server["env"])

    cond do
      bearer = bearer_header(headers) ->
        {header_key, token} = bearer

        %{
          scheme: "bearer",
          header: canonical_header(header_key),
          secret_name: default_secret_name(base_name),
          value: token
        }

      custom = custom_auth_header(headers) ->
        {header_key, token} = custom

        %{
          scheme: "header",
          header: header_key,
          secret_name: default_secret_name(base_name),
          value: token
        }

      secret = env_secret(env) ->
        {env_name, value} = secret
        %{scheme: "bearer", header: nil, secret_name: env_name, value: value}

      true ->
        %{scheme: "none", header: nil, secret_name: nil, value: nil}
    end
  end

  # An `Authorization: Bearer <token>` header → bearer scheme + staged token.
  @spec bearer_header(map()) :: {String.t(), String.t()} | nil
  defp bearer_header(headers) do
    Enum.find_value(headers, fn {key, value} ->
      with true <- String.downcase(key) == "authorization",
           %{"tok" => tok} <- Regex.named_captures(~r/^\s*bearer\s+(?<tok>.+?)\s*$/i, value) do
        {key, placeholder_or(tok)}
      else
        _ -> nil
      end
    end)
  end

  # Any other non-empty header → custom-header scheme; stage its (token-ish) value.
  @spec custom_auth_header(map()) :: {String.t(), String.t()} | nil
  defp custom_auth_header(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) != "authorization" and is_binary(value) and value != "" do
        {key, placeholder_or(value)}
      end
    end)
  end

  # An env var whose NAME is env-var-shaped → treat as the injected credential.
  @spec env_secret(map()) :: {String.t(), String.t()} | nil
  defp env_secret(env) do
    Enum.find_value(env, fn {key, value} ->
      if Regex.match?(@secret_format, key), do: {key, placeholder_or(value)}
    end)
  end

  # A `${PLACEHOLDER}` value is a reference, not a real token — don't stage it.
  @spec placeholder_or(String.t()) :: String.t() | nil
  defp placeholder_or(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or Regex.match?(~r/^\$\{?[A-Za-z0-9_]+\}?$/, trimmed),
      do: nil,
      else: trimmed
  end

  defp placeholder_or(_value), do: nil

  # Canonicalize the Authorization header casing for the schema's `auth_header`.
  @spec canonical_header(String.t()) :: String.t() | nil
  defp canonical_header(key) do
    if String.downcase(key) == "authorization", do: nil, else: key
  end

  # Derive an env-var-shaped secret name from the server name (PIXELLAB → PIXELLAB_API_KEY).
  @spec default_secret_name(String.t()) :: String.t()
  defp default_secret_name(base_name) do
    upper =
      base_name
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "_")
      |> String.trim("_")

    upper = if upper == "" or not Regex.match?(~r/^[A-Z]/, upper), do: "API_#{upper}", else: upper

    if String.ends_with?(upper, "_API_KEY"), do: upper, else: "#{upper}_API_KEY"
  end

  # --- value coercion ---

  @spec sanitize_name(term()) :: String.t() | nil
  defp sanitize_name(name) when is_binary(name) do
    candidate =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")

    if candidate != "" and Regex.match?(@name_format, candidate), do: candidate, else: nil
  end

  defp sanitize_name(_name), do: nil

  @spec string_or_nil(term()) :: String.t() | nil
  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_value), do: nil

  @spec string_list(term()) :: [String.t()]
  defp string_list(list) when is_list(list),
    do: list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

  defp string_list(_other), do: []

  @spec as_string_map(term()) :: %{String.t() => String.t()}
  defp as_string_map(map) when is_map(map) do
    for {key, value} <- map, is_binary(key), into: %{}, do: {key, to_string(value)}
  end

  defp as_string_map(_other), do: %{}

  defp drop_nil_values(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)
end
