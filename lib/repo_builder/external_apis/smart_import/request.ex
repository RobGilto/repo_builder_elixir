defmodule RepoBuilder.ExternalApis.SmartImport.Request do
  @moduledoc """
  An ephemeral MCP smart-import request (issue-external-api-mcp-provisioning).

  Carries everything `RepoBuilder.ExternalApis.SmartImport.Server` needs to run ONE
  one-shot, non-persisted Fast-tier harness session and reply to the requesting
  LiveView: the correlation id, the strict-JSON instruction prompt, the resolved
  harness/provider/model from the orchestrator's `fast` roster entry, and the pid to
  message the `{:smart_import_result, request_id, _}` back to. Mirrors
  `RepoBuilder.Explain.Request`.
  """
  use TypedStruct

  typedstruct enforce: true do
    field :request_id, String.t()
    field :prompt, String.t()
    field :harness, String.t()
    field :provider, String.t(), enforce: false
    field :model, String.t()
    field :reply_to, pid()
  end
end
