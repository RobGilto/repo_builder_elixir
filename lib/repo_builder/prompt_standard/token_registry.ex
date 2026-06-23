defmodule RepoBuilder.PromptStandard.TokenRegistry do
  @moduledoc """
  The closed registry of allowed `{{TOKEN}}` sentinels for Population B prompts (port of
  the Python `TOKEN_REGISTRY` frozenset in `prompt_builder/models.py`).

  Adding a token requires updating the orchestrator's system-prompt loader as well; extend
  this set only when that loader is updated.

  Capability tokens (agentic-layer adaptor, Phase 3) are a documented, closed sub-set
  filled by `RepoBuilder.Commands.Resolver` from the active project's capability map so
  one token-templated command body works across every stack. See `capability_tokens/0`.
  """
  @capability_tokens [
    "{{TEST_COMMAND}}",
    "{{BUILD_COMMAND}}",
    "{{LINT_COMMAND}}",
    "{{FORMAT_COMMAND}}",
    "{{TYPECHECK_COMMAND}}",
    "{{RUN_COMMAND}}",
    "{{PACKAGE_MANAGER}}",
    "{{SPEC_DIR}}",
    "{{SOURCE_DIRS}}",
    "{{TEST_DIR}}"
  ]

  @tokens MapSet.new(["{{SUBAGENT_MAP}}", "{{HARNESS_CATALOG}}"] ++ @capability_tokens)

  @doc "The registry as a `MapSet` (for set arithmetic in the validator)."
  @spec set() :: MapSet.t(String.t())
  def set, do: @tokens

  @doc "The registry as a sorted list (for deterministic, human-readable messages)."
  @spec list() :: [String.t()]
  def list, do: @tokens |> MapSet.to_list() |> Enum.sort()

  @doc "Whether `token` (e.g. `\"{{SUBAGENT_MAP}}\"`) is in the closed registry."
  @spec member?(String.t()) :: boolean()
  def member?(token) when is_binary(token), do: MapSet.member?(@tokens, token)

  @doc "The closed list of capability `{{TOKEN}}`s the command resolver fills (sorted)."
  @spec capability_tokens() :: [String.t()]
  def capability_tokens, do: Enum.sort(@capability_tokens)
end
