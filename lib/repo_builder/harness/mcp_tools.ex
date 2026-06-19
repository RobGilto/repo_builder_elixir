defmodule RepoBuilder.Harness.McpTools do
  @moduledoc """
  Harness-agnostic catalog of the grantable worker MCP research tools (issue
  firecrawl-grant). The SINGLE place that knows a tool's MCP server shape, its
  Claude allow-list patterns, and which env-var secret it needs — so adding a
  second tool later is a data edit here, not adapter surgery.

  Both the Claude and pi worker spawn paths consume the same `mcp_servers/1`
  fragment; `Session.Server.resolve_secrets/2` consumes `secret_keys/1` to fold the
  right env key into a granted worker's child env. The literal secret value is NEVER
  written into the JSON fragment — only the `${FIRECRAWL_API_KEY}` placeholder, which
  the CLI expands from the process env at read time.
  """

  # Closed atom set of known tools. NEVER `String.to_atom/1` on the untrusted config
  # `"tools"` list — `enabled/1` maps through this string→atom lookup and drops unknowns.
  @type tool :: :firecrawl

  @known %{"firecrawl" => :firecrawl}

  @doc "The known tool names, in catalog order."
  @spec known() :: [String.t()]
  def known, do: Map.keys(@known)

  @doc """
  Parse a worker config's `"tools"` list (string keys from JSONB, possibly nil) into
  the closed atom set, dropping any unknown names. Order/uniqueness preserved.
  """
  @spec enabled([String.t()] | nil) :: [tool()]
  def enabled(tools) when is_list(tools) do
    tools
    |> Enum.map(fn name -> Map.get(@known, to_string(name)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def enabled(_tools), do: []

  @doc """
  The `mcpServers` JSON fragment (a JSON-encodable map) declaring the stdio MCP
  server for each enabled tool. The credential is referenced as a `${VAR}`
  placeholder so the literal key never lands on disk. `%{}` for an empty list.
  """
  @spec mcp_servers([tool()]) :: %{String.t() => map()}
  def mcp_servers(tools) when is_list(tools) do
    Map.new(tools, fn tool -> {server_key(tool), server_spec(tool)} end)
  end

  @doc """
  The Claude `--allowedTools` patterns for the enabled tools (one wildcard per
  server). `[]` for an empty list.
  """
  @spec allowed_tools([tool()]) :: [String.t()]
  def allowed_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool -> "mcp__#{server_key(tool)}__*" end)
  end

  @doc """
  The `{server_key, env_var_name}` pairs the enabled tools need, used by
  `Session.Server.resolve_secrets/2` to pull each value from the `:tool_secrets`
  runtime config.
  """
  @spec secret_keys([tool()]) :: [{String.t(), String.t()}]
  def secret_keys(tools) when is_list(tools) do
    Enum.map(tools, fn tool -> {server_key(tool), secret_var(tool)} end)
  end

  # --- per-tool knowledge (the only firecrawl-specific code) ---

  @spec server_key(tool()) :: String.t()
  defp server_key(:firecrawl), do: "firecrawl"

  @spec secret_var(tool()) :: String.t()
  defp secret_var(:firecrawl), do: "FIRECRAWL_API_KEY"

  # Inference-only spec — the concrete server map narrows below a hand-written
  # `map()` spec, which Dialyzer rejects as a supertype under :underspecs.
  defp server_spec(:firecrawl) do
    %{
      "command" => "npx",
      "args" => ["-y", "firecrawl-mcp"],
      "env" => %{"FIRECRAWL_API_KEY" => "${FIRECRAWL_API_KEY}"}
    }
  end
end
