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
