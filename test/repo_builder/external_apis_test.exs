defmodule RepoBuilder.ExternalApisTest do
  @moduledoc """
  Context coverage for the registered external API / MCP provider registry
  (issue-external-api-mcp-provisioning): scope resolution (owned vs effective),
  project-shadows-platform, disabled exclusion, the changeset validation matrix, per-scope
  name uniqueness, and that the token is never persisted on the row (only the reference).
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.ExternalApis
  alias RepoBuilder.ExternalApis.ExternalApi
  alias RepoBuilder.Projects

  defp project(_context) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "api-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/api-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  defp pixellab_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "pixellab",
        "provider" => "Pixellab",
        "transport" => "http",
        "url" => "https://api.pixellab.ai/mcp",
        "auth_scheme" => "bearer",
        "secret_name" => "PIXELLAB_API_KEY",
        "doc_urls" => ["https://api.pixellab.ai/mcp/docs"],
        "description" => "Image generation MCP"
      },
      overrides
    )
  end

  describe "create/1 + changeset validation" do
    test "registers a valid http+bearer API and never stores a token" do
      assert {:ok, %ExternalApi{} = api} = ExternalApis.create(pixellab_params())
      assert api.name == "pixellab"
      assert api.transport == :http
      assert api.auth_scheme == :bearer
      assert api.secret_name == "PIXELLAB_API_KEY"
      assert api.status == :active

      # The row carries only the secret REFERENCE — no token-bearing field exists.
      refute Map.has_key?(api, :token)
      refute Map.has_key?(api, :secret_value)
    end

    test "requires name and transport" do
      assert {:error, changeset} = ExternalApis.create(%{})
      assert %{name: _, transport: _} = errors_on(changeset)
    end

    test "rejects an invalid MCP server key" do
      assert {:error, changeset} = ExternalApis.create(pixellab_params(%{"name" => "Bad Name"}))
      assert errors_on(changeset)[:name]
    end

    test "http transport requires a url" do
      assert {:error, changeset} =
               ExternalApis.create(pixellab_params(%{"url" => nil}))

      assert errors_on(changeset)[:url]
    end

    test "stdio transport requires a command" do
      params = %{
        "name" => "fc",
        "transport" => "stdio",
        "auth_scheme" => "none"
      }

      assert {:error, changeset} = ExternalApis.create(params)
      assert errors_on(changeset)[:command]
    end

    test "bearer/header auth requires a secret_name in env-var shape" do
      assert {:error, changeset} =
               ExternalApis.create(pixellab_params(%{"secret_name" => nil}))

      assert errors_on(changeset)[:secret_name]

      assert {:error, changeset} =
               ExternalApis.create(pixellab_params(%{"secret_name" => "lower_case"}))

      assert errors_on(changeset)[:secret_name]
    end

    test "name is unique within the platform scope" do
      assert {:ok, _} = ExternalApis.create(pixellab_params())
      assert {:error, changeset} = ExternalApis.create(pixellab_params())
      assert errors_on(changeset)[:name]
    end
  end

  describe "scope resolution" do
    setup :project

    test "list_for_scope returns rows OWNED by exactly that scope", %{project: project} do
      {:ok, _platform} = ExternalApis.create(pixellab_params())

      {:ok, _proj} =
        ExternalApis.create(pixellab_params(%{"name" => "proj_api", "project_id" => project.id}))

      assert ["pixellab"] = Enum.map(ExternalApis.list_for_scope(nil), & &1.name)
      assert ["proj_api"] = Enum.map(ExternalApis.list_for_scope(project.id), & &1.name)
    end

    test "list_in_scope_for is platform + project, active only", %{project: project} do
      {:ok, _platform} = ExternalApis.create(pixellab_params())

      {:ok, _proj} =
        ExternalApis.create(pixellab_params(%{"name" => "proj_api", "project_id" => project.id}))

      {:ok, _disabled} =
        ExternalApis.create(
          pixellab_params(%{
            "name" => "off_api",
            "project_id" => project.id,
            "status" => "disabled"
          })
        )

      names = Enum.map(ExternalApis.list_in_scope_for(project.id), & &1.name)
      assert "pixellab" in names
      assert "proj_api" in names
      refute "off_api" in names
    end

    test "a project row shadows a same-named platform row", %{project: project} do
      {:ok, platform} =
        ExternalApis.create(pixellab_params(%{"description" => "platform one"}))

      {:ok, proj} =
        ExternalApis.create(
          pixellab_params(%{"project_id" => project.id, "description" => "project one"})
        )

      assert [resolved] = ExternalApis.list_in_scope_for(project.id)
      assert resolved.id == proj.id
      refute resolved.id == platform.id
      assert resolved.description == "project one"
    end

    test "fetch_by_names drops unknown and disabled names", %{project: project} do
      {:ok, _} = ExternalApis.create(pixellab_params())

      {:ok, _} =
        ExternalApis.create(pixellab_params(%{"name" => "off_api", "status" => "disabled"}))

      resolved = ExternalApis.fetch_by_names(project.id, ["pixellab", "off_api", "nope"])
      assert ["pixellab"] = Enum.map(resolved, & &1.name)
    end
  end

  describe "update/2 + delete/1" do
    test "update edits a registration" do
      {:ok, api} = ExternalApis.create(pixellab_params())
      assert {:ok, updated} = ExternalApis.update(api, %{"description" => "new"})
      assert updated.description == "new"
    end

    test "delete removes a registration" do
      {:ok, api} = ExternalApis.create(pixellab_params())
      assert :ok = ExternalApis.delete(api.id)
      assert {:error, :not_found} = ExternalApis.get(api.id)
    end
  end
end
