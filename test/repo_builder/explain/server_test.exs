defmodule RepoBuilder.Explain.ServerTest do
  @moduledoc """
  The ephemeral explain runner (issue-explain): over the keyless Fake harness it
  accumulates finalized text and replies `{:explain_result, request_id, {:ok, text}}`
  to the requesting pid, persisting nothing.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Explain.{Request, Server}

  test "runs a Fake session and replies with the explanation text" do
    request = %Request{
      request_id: "test-#{System.unique_integer([:positive])}",
      prompt: "explain these logs",
      harness: "fake",
      provider: nil,
      model: "fake-model-1",
      reply_to: self()
    }

    assert {:ok, _pid} = Server.start(request)

    request_id = request.request_id
    assert_receive {:explain_result, ^request_id, {:ok, text}}, 5_000
    assert text == "Hello world"
  end
end
