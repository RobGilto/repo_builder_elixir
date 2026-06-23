# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     RepoBuilder.Repo.insert!(%RepoBuilder.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Idempotently seed the Cost Center price catalog (issue-cost-center). Safe to re-run:
# refreshes `:seed` rows, preserves operator `:manual` edits, never duplicates.
{:ok, seeded} = RepoBuilder.CostCenter.seed_prices()
IO.puts("Seeded #{seeded} model price rows.")

# Idempotently seed the platform's own Project (agentic-layer adaptor) so existing
# global agents/runs (project_id == nil) have a logical "platform itself" home, and
# the console's project switcher always has a default. Re-running is safe — the unique
# name constraint means we only insert when absent.
platform_root = File.cwd!()

case RepoBuilder.Repo.get_by(RepoBuilder.Projects.Project, root_path: platform_root) do
  nil ->
    {:ok, project} =
      RepoBuilder.Projects.create_project(%{
        "name" => "repo_builder_elixir (platform)",
        "root_path" => platform_root,
        "default_branch" => "main",
        "isolation_mode" => "direct"
      })

    IO.puts("Seeded default platform project #{project.id}.")

  %RepoBuilder.Projects.Project{} = project ->
    IO.puts("Default platform project already present (#{project.id}).")
end
