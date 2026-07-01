defmodule RepoBuilder.Projects.CapabilityTokens do
  @moduledoc """
  The SHARED capability-token machinery (quality-gate-plugins): the `{{TOKEN}}` →
  `Capabilities` field map and the `fill/2` templating that both `Commands.Resolver`
  (command bodies) and `Orchestrator.GateResolver` (gate stage commands) drive.

  Extracted from `Commands.Resolver` so the two callers can never drift on which tokens
  exist or how a nil field is stringified (nil → `""`, a list → comma-joined). Pure and
  fail-silent — never raises.
  """
  alias RepoBuilder.Projects.Capabilities
  alias RepoBuilder.PromptStandard.Builder

  # Capability `{{TOKEN}}` → the `Capabilities` struct field it is filled from. The gate
  # tokens (`MUTATION_COMMAND`, `TYPECHECK_STRICT_COMMAND`, `TYPE_COVERAGE_COMMAND`) live
  # here alongside the command-pack tokens so both resolvers share one registry.
  @token_fields %{
    "{{TEST_COMMAND}}" => :test_command,
    "{{BUILD_COMMAND}}" => :build_command,
    "{{LINT_COMMAND}}" => :lint_command,
    "{{FORMAT_COMMAND}}" => :format_command,
    "{{TYPECHECK_COMMAND}}" => :typecheck_command,
    "{{TYPECHECK_STRICT_COMMAND}}" => :typecheck_strict_command,
    "{{TYPE_COVERAGE_COMMAND}}" => :type_coverage_command,
    "{{MUTATION_COMMAND}}" => :mutation_command,
    "{{RUN_COMMAND}}" => :run_command,
    "{{PACKAGE_MANAGER}}" => :package_manager,
    "{{SPEC_DIR}}" => :spec_dir,
    "{{SOURCE_DIRS}}" => :source_dirs,
    "{{TEST_DIR}}" => :test_dir
  }

  @doc "The `{{TOKEN}}` → capability field map."
  @spec token_fields() :: %{optional(String.t()) => atom()}
  def token_fields, do: @token_fields

  @doc """
  Fill `{{TOKEN}}` capability tokens in `body` from a `Capabilities` struct. Uses the
  `Builder.render/2` machinery; on any error (e.g. an unrelated `{{…}}` in the body) it
  falls back to a direct replace of just the capability tokens, so filling never fails.
  """
  @spec fill(String.t(), Capabilities.t()) :: String.t()
  def fill(body, %Capabilities{} = caps) do
    tokens = token_map(caps)

    case Builder.render(body, tokens) do
      {:ok, rendered} -> rendered
      {:error, _} -> Enum.reduce(tokens, body, fn {t, v}, acc -> String.replace(acc, t, v) end)
    end
  end

  @doc "The full `{{TOKEN}} => value` map for a capability struct (nil → \"\", list → comma-joined)."
  @spec token_map(Capabilities.t()) :: %{optional(String.t()) => String.t()}
  def token_map(%Capabilities{} = caps) do
    Map.new(@token_fields, fn {token, field} -> {token, stringify(Map.get(caps, field))} end)
  end

  @doc "The raw capability VALUE for a `{{TOKEN}}` (nil when the token is unknown or the field is nil)."
  @spec value_for(String.t(), Capabilities.t()) :: String.t() | nil
  def value_for(token, %Capabilities{} = caps) do
    case Map.get(@token_fields, token) do
      nil -> nil
      field -> blank_to_nil(stringify(Map.get(caps, field)))
    end
  end

  @spec stringify(term()) :: String.t()
  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_list(value), do: Enum.join(value, ", ")
  defp stringify(value), do: to_string(value)

  @spec blank_to_nil(String.t()) :: String.t() | nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
