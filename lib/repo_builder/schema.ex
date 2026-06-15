defmodule RepoBuilder.Schema do
  @moduledoc """
  Shared base macro for all application schemas (BUILD_PROMPT.md §8).

  Centralizes the app-wide conventions so they cannot drift per-schema:

    * binary_id (UUID) primary keys,
    * binary_id foreign keys,
    * microsecond UTC timestamps.

  `use RepoBuilder.Schema` instead of `use Ecto.Schema`. Note: Oban's own tables
  use bigint ids and are NOT created via this macro (§8).
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
