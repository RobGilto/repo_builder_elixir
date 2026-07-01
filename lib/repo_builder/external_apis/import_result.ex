defmodule RepoBuilder.ExternalApis.ImportResult do
  @moduledoc """
  The shared outcome of MCP smart import (issue-external-api-mcp-provisioning): the
  product of BOTH the deterministic parser (`RepoBuilder.ExternalApis.McpImport`) and the
  Fast-agent fallback (`RepoBuilder.ExternalApis.SmartImport`).

  `action: :register` carries an `api_params` draft ready for the existing register form /
  `RepoBuilder.ExternalApis.ExternalApi.changeset/2`; `action: :question` carries a single
  clarifying `question` plus whatever partial draft could be derived.

  Any literal token found in the pasted config is staged in `secret_value` for the
  Deposit-a-secret form — it is NEVER placed in `api_params`, NEVER persisted on the row,
  and NEVER sent to the LLM (BUILD_PROMPT §6, reference-not-value).
  """
  use TypedStruct

  @typedoc "Whether the import yielded a ready draft or needs the operator to answer."
  @type action :: :register | :question

  @typedoc "Where the result came from — a pure parse or the Fast agent."
  @type source :: :deterministic | :agent

  typedstruct enforce: true do
    field :action, action()
    field :api_params, %{optional(String.t()) => term()}, default: %{}
    field :secret_name, String.t() | nil, enforce: false
    field :secret_value, String.t() | nil, enforce: false
    field :question, String.t() | nil, enforce: false
    field :source, source()
  end
end
