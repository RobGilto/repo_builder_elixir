defmodule RepoBuilder.Explain.Request do
  @moduledoc """
  An ephemeral "explain these logs" request (issue-explain).

  Carries everything `RepoBuilder.Explain.Server` needs to run ONE one-shot,
  non-persisted Fast-tier harness session and reply to the requesting LiveView:
  the correlation id, the fully built troubleshooting prompt, the resolved
  harness/provider/model from the orchestrator's `fast` roster entry, and the pid
  to message the `{:explain_result, request_id, _}` back to.
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
