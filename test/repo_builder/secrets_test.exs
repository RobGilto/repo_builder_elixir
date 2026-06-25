defmodule RepoBuilder.SecretsTest do
  @moduledoc """
  Context coverage for the per-project encrypted vault
  (issue-per-project-encrypted-secrets-vault): put/list/delete, rotation, the
  decrypt-into-env round-trip, masked reads that never leak the value, per-project +
  platform(NULL) uniqueness, and the fail-closed-no-key path.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Projects
  alias RepoBuilder.Secrets
  alias RepoBuilder.Secrets.ProjectSecret

  defp project(_context) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "vault-#{System.unique_integer([:positive])}",
        "root_path" => "/tmp/vault-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  describe "put_secret/3 + list_names/1" do
    setup :project

    test "stores a masked row carrying name + last_four but never the value", %{project: project} do
      assert {:ok, %ProjectSecret{} = secret} =
               Secrets.put_secret(project.id, "STRIPE_API_KEY", "sk_live_4242")

      assert secret.name == "STRIPE_API_KEY"
      assert secret.last_four == "4242"
      # ciphertext is opaque and not the plaintext.
      refute secret.ciphertext == "sk_live_4242"

      assert [%{name: "STRIPE_API_KEY", last_four: "4242"} = entry] =
               Secrets.list_names(project.id)

      refute Map.has_key?(entry, :value)
      refute Map.has_key?(entry, :ciphertext)
    end

    test "rejects a non-env-var name", %{project: project} do
      assert {:error, changeset} = Secrets.put_secret(project.id, "not a name", "v")
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rotation overwrites in place (same name, new value)", %{project: project} do
      {:ok, _} = Secrets.put_secret(project.id, "TOKEN", "old-value")
      {:ok, _} = Secrets.put_secret(project.id, "TOKEN", "new-value-9999")

      assert [%{name: "TOKEN", last_four: "9999"}] = Secrets.list_names(project.id)
      assert %{"TOKEN" => "new-value-9999"} = Secrets.resolve_env(project.id)
    end
  end

  describe "resolve_env/1 + active_values/1" do
    setup :project

    test "round-trips every secret into a name => value env map", %{project: project} do
      {:ok, _} = Secrets.put_secret(project.id, "A_KEY", "alpha")
      {:ok, _} = Secrets.put_secret(project.id, "B_KEY", "bravo")

      assert %{"A_KEY" => "alpha", "B_KEY" => "bravo"} = Secrets.resolve_env(project.id)
      assert Enum.sort(Secrets.active_values(project.id)) == ["alpha", "bravo"]
    end

    test "nil / unknown project resolves to empty", _context do
      assert Secrets.resolve_env(nil) == %{}
      assert Secrets.resolve_env(Ecto.UUID.generate()) == %{}
      assert Secrets.active_values(nil) == []
    end
  end

  describe "delete_secret/2" do
    setup :project

    test "removes the row", %{project: project} do
      {:ok, _} = Secrets.put_secret(project.id, "GONE", "value")
      assert :ok = Secrets.delete_secret(project.id, "GONE")
      assert Secrets.list_names(project.id) == []
    end
  end

  describe "scoping + uniqueness" do
    setup :project

    test "the same name is distinct per project and for the platform (NULL)", %{project: project} do
      {:ok, _} = Secrets.put_secret(project.id, "SHARED", "project-value")
      {:ok, _} = Secrets.put_secret(nil, "SHARED", "platform-value-7777")

      # The partial unique indexes let the SAME name coexist across scopes (the insert
      # above did not collide), and the rows stay separate.
      assert %{"SHARED" => "project-value"} = Secrets.resolve_env(project.id)
      assert [%{name: "SHARED", last_four: "alue"}] = Secrets.list_names(project.id)
      assert [%{name: "SHARED", last_four: "7777"}] = Secrets.list_names(nil)

      # resolve_env(nil) is fail-closed by design (the injection seam never passes nil).
      assert Secrets.resolve_env(nil) == %{}
    end
  end

  describe "fail-closed when the master key is unset" do
    setup :project

    test "put_secret surfaces a clear changeset error", %{project: project} do
      original = Application.get_env(:repo_builder, RepoBuilder.Secrets)
      Application.delete_env(:repo_builder, RepoBuilder.Secrets)
      on_exit(fn -> Application.put_env(:repo_builder, RepoBuilder.Secrets, original) end)

      assert {:error, changeset} = Secrets.put_secret(project.id, "KEY", "value")
      assert %{value: [msg]} = errors_on(changeset)
      assert msg =~ "SECRETS_KEY"
    end
  end
end
