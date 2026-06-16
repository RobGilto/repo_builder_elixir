defmodule RepoBuilder.Repo.Migrations.AddProviderToOrchestrators do
  use Ecto.Migration

  def change do
    alter table(:orchestrators) do
      # Open provider identity (pi supports 30+ providers), validated loosely at the
      # changeset boundary like :harness — NOT a closed DB enum. Nullable: existing
      # rows and pi orchestrators may legitimately have no explicit provider.
      add :provider, :string
    end
  end
end
