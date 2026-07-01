defmodule RepoBuilder.ExternalApis.SmartImport.ServerTest do
  @moduledoc """
  The ephemeral smart-import runner (issue-external-api-mcp-provisioning): over the keyless
  Fake harness it runs one non-persisted Fast session and replies
  `{:smart_import_result, request_id, result}` to the requesting pid. The Fake harness
  emits canned prose (not a JSON envelope), so the reply is `{:error, :bad_agent_reply}` —
  which still proves the full runner → session → reply wiring end-to-end, persisting
  nothing.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.ExternalApis.SmartImport.{Request, Server}

  test "runs a Fake session and replies via the smart-import channel" do
    request = %Request{
      request_id: "test-#{System.unique_integer([:positive])}",
      prompt: "interpret this MCP config",
      harness: "fake",
      provider: nil,
      model: "fake-model-1",
      reply_to: self()
    }

    assert {:ok, _pid} = Server.start(request)

    request_id = request.request_id
    assert_receive {:smart_import_result, ^request_id, result}, 5_000
    # The canned Fake reply is prose, not a JSON envelope.
    assert {:error, :bad_agent_reply} = result
  end
end
