defmodule RepoBuilder.Repo do
  use Ecto.Repo,
    otp_app: :repo_builder,
    adapter: Ecto.Adapters.Postgres
end
