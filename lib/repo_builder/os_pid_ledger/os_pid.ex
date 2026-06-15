defmodule RepoBuilder.OsPidLedger.OsPid do
  @moduledoc """
  Durable record of a live OS child pid for boot-time orphan reaping
  (BUILD_PROMPT.md §6/§8).

  The `marker` (also injected into the child env as `REPO_BUILDER_SESSION_MARKER`)
  is what lets the `OrphanReaper` prove a live OS process is OURS before signalling
  it — never kill by bare pid (a pid may have been recycled).

  M2 writes/deletes these rows from the session runtime; M3's `OrphanReaper` reads
  them on boot. `agent_id` is a plain binary_id here and is promoted to a real FK
  in M3 once the `agents` table exists.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          os_pid: integer() | nil,
          marker: String.t() | nil,
          argv_hash: String.t() | nil,
          node: String.t() | nil,
          started_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "os_pid_ledger" do
    field :agent_id, :binary_id
    field :session_id, :string
    field :os_pid, :integer
    field :marker, :string
    field :argv_hash, :string
    field :node, :string
    field :started_at, :utc_datetime_usec
  end

  @required [:session_id, :os_pid, :marker, :node, :started_at]
  @optional [:agent_id, :argv_hash]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(os_pid, params) do
    os_pid
    |> cast(params, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:marker)
  end
end
