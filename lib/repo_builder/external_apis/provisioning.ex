defmodule RepoBuilder.ExternalApis.Provisioning do
  @moduledoc """
  Turns a set of provisioned `ExternalApi.t()` rows into the same three adapter
  fragments `RepoBuilder.Harness.McpTools` produces for the static catalog
  (issue-external-api-mcp-provisioning) — the DYNAMIC analogue, operating on DB rows
  instead of a closed atom set.

    * `mcp_servers/1` — the `mcpServers` JSON fragment (http/sse bearer-header or stdio
      command/args shapes),
    * `allowed_tools/1` — the Claude `--allowedTools` wildcard patterns,
    * `secret_keys/1` — the `{server_key, env_var}` pairs the worker child env needs,
    * `instructions/1` — the charter fragment prepended to a provisioned worker's prompt.

  The literal token is NEVER inlined — only the `${SECRET_NAME}` placeholder, which the
  CLI expands from the worker's child env at read time (the same mechanism firecrawl
  uses). The worker spawn paths MERGE this fragment with the static `McpTools` one.
  """
  alias RepoBuilder.ExternalApis.ExternalApi

  @doc """
  The `mcpServers` JSON fragment (`name => server_spec`) for the provisioned APIs. Per
  transport: http/sse carry the auth header with a `${SECRET}` placeholder; stdio carries
  `command`/`args` (env injected at the session boundary, not here). `%{}` for `[]`.
  """
  @spec mcp_servers([ExternalApi.t()]) :: %{String.t() => map()}
  def mcp_servers(apis) when is_list(apis) do
    Map.new(apis, fn %ExternalApi{name: name} = api -> {name, server_spec(api)} end)
  end

  @doc """
  The Claude `--allowedTools` patterns: each row's explicit `allowed_tools` if set, else
  the default `mcp__<name>__*` wildcard. `[]` for `[]`.
  """
  @spec allowed_tools([ExternalApi.t()]) :: [String.t()]
  def allowed_tools(apis) when is_list(apis) do
    Enum.flat_map(apis, fn
      %ExternalApi{allowed_tools: [_ | _] = patterns} -> patterns
      %ExternalApi{name: name} -> ["mcp__#{name}__*"]
    end)
  end

  @doc """
  The `{server_key, secret_name}` pairs for rows whose `auth_scheme != :none` and that
  carry a `secret_name`. `Session.Server.api_secrets/1` resolves each from the vault into
  the worker child env. `[]` for a public (`:none`) API.
  """
  @spec secret_keys([ExternalApi.t()]) :: [{String.t(), String.t()}]
  def secret_keys(apis) when is_list(apis) do
    for %ExternalApi{name: name, auth_scheme: scheme, secret_name: secret} <- apis,
        scheme != :none,
        is_binary(secret) and secret != "",
        do: {name, secret}
  end

  @doc """
  A charter fragment concatenating each provisioned API's description/instructions/doc
  URLs, prepended to the worker system prompt so it knows HOW to use the API. `""` for
  `[]` (back-compatible — the worker prompt is byte-identical with no provisions).
  """
  @spec instructions([ExternalApi.t()]) :: String.t()
  def instructions([]), do: ""

  def instructions(apis) when is_list(apis) do
    body = Enum.map_join(apis, "\n\n", &api_instructions/1)

    """
    Provisioned external APIs / MCP servers (call their `mcp__<name>__*` tools directly):

    #{body}
    """
    |> String.trim_trailing()
  end

  # --- per-transport / per-auth knowledge ---

  @spec server_spec(ExternalApi.t()) :: map()
  defp server_spec(%ExternalApi{transport: :stdio, command: command, args: args}) do
    %{"command" => command, "args" => args || [], "env" => %{}}
  end

  defp server_spec(%ExternalApi{transport: transport, url: url} = api)
       when transport in [:http, :sse] do
    base = %{"type" => to_string(transport), "url" => url}

    case auth_headers(api) do
      headers when map_size(headers) == 0 -> base
      headers -> Map.put(base, "headers", headers)
    end
  end

  # The auth header carrying the `${SECRET}` placeholder — never the literal token.
  @spec auth_headers(ExternalApi.t()) :: %{optional(String.t()) => String.t()}
  defp auth_headers(%ExternalApi{auth_scheme: :bearer, secret_name: secret} = api)
       when is_binary(secret) do
    %{header_name(api) => "Bearer ${#{secret}}"}
  end

  defp auth_headers(%ExternalApi{auth_scheme: :header, secret_name: secret} = api)
       when is_binary(secret) do
    %{header_name(api) => "${#{secret}}"}
  end

  defp auth_headers(_api), do: %{}

  @spec header_name(ExternalApi.t()) :: String.t()
  defp header_name(%ExternalApi{auth_header: header}) when is_binary(header) and header != "",
    do: header

  defp header_name(_api), do: "Authorization"

  @spec api_instructions(ExternalApi.t()) :: String.t()
  defp api_instructions(%ExternalApi{} = api) do
    [
      "- #{api.name}#{describe(api.description)}",
      indent(api.instructions),
      doc_line(api.doc_urls)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec describe(String.t() | nil) :: String.t()
  defp describe(description) when is_binary(description) and description != "",
    do: " — #{description}"

  defp describe(_description), do: ""

  @spec indent(String.t() | nil) :: String.t()
  defp indent(instructions) when is_binary(instructions) and instructions != "",
    do: "  #{String.replace(String.trim(instructions), "\n", "\n  ")}"

  defp indent(_instructions), do: ""

  @spec doc_line([String.t()]) :: String.t()
  defp doc_line([_ | _] = urls), do: "  Docs: #{Enum.join(urls, ", ")}"
  defp doc_line(_urls), do: ""
end
