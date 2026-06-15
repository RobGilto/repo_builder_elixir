defmodule RepoBuilder.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  # Oban's own tables use BIGINT job ids — do NOT force binary_id (§8). Created by
  # Oban.Migration; coexists fine with the app-wide binary_id schemas.
  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
