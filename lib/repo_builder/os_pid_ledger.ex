defmodule RepoBuilder.OsPidLedger do
  @moduledoc """
  Context for the durable os_pid ledger (BUILD_PROMPT.md §6/§8) — the ONLY caller
  of `Repo` for `os_pid_ledger` rows.

  The session runtime inserts a row before consuming output and deletes it (by
  marker, idempotently) on terminate; the boot-time `OrphanReaper` (M3) reads
  `list_for_node/1`.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.OsPidLedger.OsPid
  alias RepoBuilder.Repo

  @doc "Insert one ledger row from attrs."
  @spec insert(map()) :: {:ok, OsPid.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %OsPid{}
    |> OsPid.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Delete the ledger row(s) for a marker. Idempotent — a missing row is fine."
  @spec delete_by_marker(String.t()) :: :ok
  def delete_by_marker(marker) do
    Repo.delete_all(from(o in OsPid, where: o.marker == ^marker))
    :ok
  end

  @doc "All ledger rows recorded for a node — the OrphanReaper's boot input."
  @spec list_for_node(String.t()) :: [OsPid.t()]
  def list_for_node(node_name) do
    Repo.all(from(o in OsPid, where: o.node == ^node_name))
  end
end
