defmodule RepoBuilder.Session.ToolSecretsTest do
  @moduledoc """
  Tests that `Session.Server.resolve_secrets/2` folds `FIRECRAWL_API_KEY` into the
  child env ONLY when the worker config enables firecrawl (issue firecrawl-grant),
  pulling the value from the `:tool_secrets` runtime block, and that an explicit
  per-session `:secrets` override still wins last.

  `async: false` — mutates the shared `:repo_builder, :tool_secrets` app env.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Session.Server

  setup do
    original = Application.get_env(:repo_builder, :tool_secrets)

    Application.put_env(:repo_builder, :tool_secrets, %{
      "firecrawl" => %{"FIRECRAWL_API_KEY" => "fc-test-secret"}
    })

    on_exit(fn ->
      if original do
        Application.put_env(:repo_builder, :tool_secrets, original)
      else
        Application.delete_env(:repo_builder, :tool_secrets)
      end
    end)

    :ok
  end

  test "folds the key in when firecrawl is enabled" do
    secrets = Server.resolve_secrets([config: %{"tools" => ["firecrawl"]}], "claude")
    assert secrets["FIRECRAWL_API_KEY"] == "fc-test-secret"
  end

  test "absent when no tools are enabled" do
    secrets = Server.resolve_secrets([config: %{}], "claude")
    refute Map.has_key?(secrets, "FIRECRAWL_API_KEY")
  end

  test "absent when only an unknown tool is requested" do
    secrets = Server.resolve_secrets([config: %{"tools" => ["bogus"]}], "claude")
    refute Map.has_key?(secrets, "FIRECRAWL_API_KEY")
  end

  test "a nil configured key never reaches the env" do
    Application.put_env(:repo_builder, :tool_secrets, %{
      "firecrawl" => %{"FIRECRAWL_API_KEY" => nil}
    })

    secrets = Server.resolve_secrets([config: %{"tools" => ["firecrawl"]}], "claude")
    refute Map.has_key?(secrets, "FIRECRAWL_API_KEY")
  end

  test "an explicit per-session secret override wins last" do
    secrets =
      Server.resolve_secrets(
        [config: %{"tools" => ["firecrawl"]}, secrets: %{"FIRECRAWL_API_KEY" => "override"}],
        "claude"
      )

    assert secrets["FIRECRAWL_API_KEY"] == "override"
  end
end
