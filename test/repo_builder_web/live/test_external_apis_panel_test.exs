defmodule RepoBuilderWeb.ExternalApisPanelTest do
  @moduledoc """
  Integration test for the Registered APIs settings panel
  (issue-external-api-mcp-provisioning): register a user-scope Pixellab API in the
  console, assert it renders in the user-scope list and is in the orchestrator's effective
  provision set, deposit its secret (masked, never plaintext), register a project-scope API
  that shows only in the project list, and delete one.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{ExternalApis, Projects, Secrets}

  defp open_tab(view), do: render_click(view, "select_settings_tab", %{"tab" => "external_apis"})

  defp select_project(view, id), do: render_click(view, "select_project", %{"project_id" => id})

  defp pixellab_fields(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY",
        "doc_urls" => "https://api.pixellab.ai/mcp/docs",
        "description" => "Image generation MCP",
        "scope" => "user"
      },
      overrides
    )
  end

  setup do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "panel-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/panel-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  test "register a user-scope API, deposit its secret, scope a project API, delete", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, "/")
    select_project(view, project.id)
    open_tab(view)
    assert has_element?(view, "#external-apis-panel")
    assert has_element?(view, "#register-api-form")

    # Register a user-scope (platform) Pixellab API.
    view
    |> form("#register-api-form", %{"api" => pixellab_fields()})
    |> render_submit()

    api = Enum.find(ExternalApis.list_for_scope(nil), &(&1.name == "pixellab"))
    assert api
    assert is_nil(api.project_id)
    assert api.transport == :http
    assert api.secret_name == "PIXELLAB_API_KEY"
    assert api.doc_urls == ["https://api.pixellab.ai/mcp/docs"]

    # It renders in the user-scope list and is in the orchestrator's effective set.
    assert has_element?(view, "#api-list-user #api-row-#{api.id}")
    assert "pixellab" in Enum.map(ExternalApis.list_in_scope_for(project.id), & &1.name)

    # No token is ever stored on the row — only the secret reference.
    refute Map.has_key?(api, :token)

    # Deposit the referenced secret into the vault — masked, never plaintext.
    view
    |> form("#deposit-api-secret-form", %{
      "scope" => "user",
      "name" => "PIXELLAB_API_KEY",
      "value" => "sk_pixellab_secret_4242"
    })
    |> render_submit()

    assert [%{name: "PIXELLAB_API_KEY", last_four: "4242"} = entry] = Secrets.list_names(nil)
    refute Map.has_key?(entry, :value)

    # Register a project-scope API — it shows only in the project list.
    view
    |> form("#register-api-form", %{
      "api" => pixellab_fields(%{"name" => "proj_only", "scope" => "project"})
    })
    |> render_submit()

    proj = Enum.find(ExternalApis.list_for_scope(project.id), &(&1.name == "proj_only"))
    assert proj
    assert proj.project_id == project.id
    assert has_element?(view, "#api-list-project #api-row-#{proj.id}")
    refute has_element?(view, "#api-list-user #api-row-#{proj.id}")

    # Delete the user-scope API — it disappears from the list.
    render_click(view, "delete_api", %{"id" => api.id})
    refute has_element?(view, "#api-row-#{api.id}")
    assert Enum.find(ExternalApis.list_for_scope(nil), &(&1.name == "pixellab")) == nil
  end
end
