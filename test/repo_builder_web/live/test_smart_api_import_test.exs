defmodule RepoBuilderWeb.SmartApiImportTest do
  @moduledoc """
  Integration test for MCP smart import on the Registered APIs panel
  (issue-external-api-mcp-provisioning): pasting a well-formed config auto-registers a row
  and stages the embedded token into the Deposit-a-secret form; an ambiguous config shows a
  clarifying question and pre-fills the register form; free-form input with no Fast agent
  shows an actionable message; and a stubbed Fast-agent async reply pre-fills the form.

  `async: false` so the shared Ecto sandbox reaches the LiveView process; the deterministic
  path needs no model, so most assertions never touch a harness.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.ExternalApis
  alias RepoBuilder.ExternalApis.ImportResult
  alias RepoBuilder.ExternalApis.SmartImport

  defp open_tab(view), do: render_click(view, "select_settings_tab", %{"tab" => "external_apis"})

  defp submit_blob(view, blob) do
    view
    |> form("#smart-import-form", %{"blob" => blob})
    |> render_submit()
  end

  test "pasting a single http server config auto-registers and stages the token", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open_tab(view)
    assert has_element?(view, "#smart-import-box")

    blob =
      ~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http","headers":{"Authorization":"Bearer sk-live-77"}}}})

    submit_blob(view, blob)

    # The row was created via the existing register write path (closed-contract validation).
    api = Enum.find(ExternalApis.list_for_scope(nil), &(&1.name == "pixellab"))
    assert api
    assert api.transport == :http
    assert api.auth_scheme == :bearer
    assert api.secret_name == "PIXELLAB_API_KEY"
    assert has_element?(view, "#api-list-user #api-row-#{api.id}")

    # The token is staged into the deposit form value — never on the registry row.
    html = render(view)
    assert html =~ "sk-live-77"
    deposit_value = view |> element(~s(#deposit-api-secret-form input[name="value"])) |> render()
    assert deposit_value =~ "sk-live-77"
    refute Map.has_key?(api, :token)
    # The deposit name is pre-filled with the derived secret name.
    assert view
           |> element(~s(#deposit-api-secret-form input[name="name"]))
           |> render() =~ "PIXELLAB_API_KEY"
  end

  test "an ambiguous config shows a clarifying question and pre-fills the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open_tab(view)

    # Two servers → a question, with the first pre-drafted.
    blob =
      ~s({"mcpServers":{"alpha":{"url":"https://a.example/mcp","type":"http"},"beta":{"command":"npx"}}})

    submit_blob(view, blob)

    assert has_element?(view, "#smart-import-status")
    assert render(view) =~ "2 servers"
    # The register form is pre-filled with the first server's name.
    assert view |> element(~s(#register-api-form input[name="api[name]"])) |> render() =~ "alpha"
    # Nothing was auto-registered.
    assert ExternalApis.list_for_scope(nil) == []
  end

  test "free-form input with no Fast agent shows an actionable message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open_tab(view)

    submit_blob(view, "please register the pixellab mcp for me")

    # No orchestrator/Fast tier in this bare session → actionable error, nothing registered.
    assert render(view) =~ "MCP config"
    assert ExternalApis.list_for_scope(nil) == []
  end

  test "a superseded async Fast-agent reply is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open_tab(view)

    # A well-formed register reply tagged with a request id that does NOT match the live one
    # (the operator never dispatched it, or dispatched a newer one) must be dropped.
    {:ok, %ImportResult{} = result} =
      SmartImport.parse_agent_reply(
        ~s({"action":"register","api":{"name":"agentsvc","transport":"http","url":"https://svc.example/mcp"}})
      )

    send(view.pid, {:smart_import_result, "stale-request-id", {:ok, result}})
    _ = render(view)

    refute has_element?(view, "#api-list-user li[id^='api-row-']")
    assert ExternalApis.list_for_scope(nil) == []
  end
end
