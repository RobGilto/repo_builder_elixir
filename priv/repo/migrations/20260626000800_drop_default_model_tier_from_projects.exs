defmodule RepoBuilder.Repo.Migrations.DropDefaultModelTierFromProjects do
  use Ecto.Migration

  # The dormant per-project `default_model_tier` column is removed: model allocation is
  # fully covered by the four-tier worker roster (per-project, inheriting the global
  # default in `app_settings`). Reversible — `change/0` re-adds the nullable column on
  # rollback (no data restored; it was never read).
  def change do
    alter table(:projects) do
      remove :default_model_tier, :string
    end
  end
end
