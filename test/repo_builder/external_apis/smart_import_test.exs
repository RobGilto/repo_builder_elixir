defmodule RepoBuilder.ExternalApis.SmartImportTest do
  @moduledoc """
  The smart-import orchestration context (issue-external-api-mcp-provisioning):
  deterministic short-circuit (no model hit), Fast-agent dispatch via the stubbed `:runner`
  seam when input is free-form, and strict-JSON reply parsing.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.ExternalApis.{ImportResult, SmartImport}
  alias RepoBuilder.ExternalApis.SmartImport.Request

  # Stub runner: records the dispatch instead of starting a real Fast-tier session.
  defmodule RunnerStub do
    @moduledoc false
    @spec start(Request.t()) :: {:ok, pid()}
    def start(%Request{} = request) do
      pid = Application.get_env(:repo_builder, :smart_import_test_pid)
      send(pid, {:dispatched, request})
      {:ok, self()}
    end
  end

  setup do
    Application.put_env(:repo_builder, SmartImport, runner: {RunnerStub, :start, 1})
    Application.put_env(:repo_builder, :smart_import_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:repo_builder, SmartImport)
      Application.delete_env(:repo_builder, :smart_import_test_pid)
    end)

    :ok
  end

  describe "import/2 — deterministic short-circuit" do
    test "well-formed JSON returns synchronously and never dispatches the agent" do
      blob = ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http"}}})

      assert {:ok, %ImportResult{action: :register, source: :deterministic}} =
               SmartImport.import(nil, blob)

      refute_receive {:dispatched, _request}
    end

    test "blank input is an error and never dispatches" do
      assert {:error, :empty} = SmartImport.import(nil, "  ")
      refute_receive {:dispatched, _request}
    end
  end

  describe "import/2 — Fast-agent fallback" do
    test "free-form input with a Fast tier dispatches the runner" do
      orchestrator = orchestrator_with_fast()

      assert {:ok, {:async, request_id}} =
               SmartImport.import(orchestrator, "please register the pixellab MCP")

      assert_receive {:dispatched, %Request{request_id: ^request_id, harness: "fake"}}
    end

    test "free-form input with no Fast tier returns :no_fast_agent" do
      orchestrator = orchestrator_without_fast()
      assert {:error, :no_fast_agent} = SmartImport.import(orchestrator, "register something")
      refute_receive {:dispatched, _request}
    end

    test "free-form input with no orchestrator returns :no_orchestrator" do
      assert {:error, :no_orchestrator} = SmartImport.import(nil, "register something")
    end
  end

  describe "parse_agent_reply/1" do
    test "a register envelope maps to an ImportResult" do
      reply =
        ~s({"action":"register","api":{"name":"pixellab","transport":"http","url":"https://api.pixellab.ai/mcp","auth_scheme":"bearer","secret_name":"PIXELLAB_API_KEY"}})

      assert {:ok, %ImportResult{action: :register, source: :agent} = result} =
               SmartImport.parse_agent_reply(reply)

      assert result.api_params["name"] == "pixellab"
      assert result.api_params["transport"] == "http"
      assert result.secret_name == "PIXELLAB_API_KEY"
    end

    test "a question envelope carries the question" do
      reply = ~s({"action":"question","question":"Is this http or sse?","api":{"name":"x"}})

      assert {:ok, %ImportResult{action: :question} = result} =
               SmartImport.parse_agent_reply(reply)

      assert result.question == "Is this http or sse?"
    end

    test "tolerates a ```json fence" do
      reply =
        "```json\n{\"action\":\"register\",\"api\":{\"name\":\"a\",\"transport\":\"stdio\",\"command\":\"npx\"}}\n```"

      assert {:ok, %ImportResult{action: :register}} = SmartImport.parse_agent_reply(reply)
    end

    test "an out-of-vocabulary transport is dropped, not crashed" do
      reply = ~s({"action":"register","api":{"name":"a","transport":"carrier-pigeon"}})
      assert {:ok, %ImportResult{} = result} = SmartImport.parse_agent_reply(reply)
      refute Map.has_key?(result.api_params, "transport")
    end

    test "garbage is a bad reply" do
      assert {:error, :bad_agent_reply} = SmartImport.parse_agent_reply("not json at all")
      assert {:error, :bad_agent_reply} = SmartImport.parse_agent_reply(~s({"action":"nope"}))
    end
  end

  # --- fixtures ---

  defp orchestrator_with_fast do
    {:ok, orchestrator} =
      RepoBuilder.Orchestrators.create(%{
        name: "smart-import-orch-#{System.unique_integer([:positive])}",
        harness: "fake"
      })

    {:ok, orchestrator} =
      RepoBuilder.Orchestrators.set_agent_model(orchestrator.id, "fast", %{
        "harness" => "fake",
        "provider" => nil,
        "model" => "fake-model-1"
      })

    orchestrator
  end

  defp orchestrator_without_fast do
    {:ok, orchestrator} =
      RepoBuilder.Orchestrators.create(%{
        name: "smart-import-orch-#{System.unique_integer([:positive])}",
        harness: "fake"
      })

    orchestrator
  end
end
