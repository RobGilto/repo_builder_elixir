defmodule RepoBuilder.Repo.Migrations.RepairInconsistentOrchestratorModels do
  use Ecto.Migration

  @moduledoc """
  One-time data repair for the "pi provider dropdown shows only anthropic" bug.

  Before the `Orchestrators.set_model/2` consistency guard landed, an operator could set
  a model foreign to the orchestrator's persisted harness — e.g. a `zai` model
  (`glm-4.6`) on a `claude` orchestrator — producing an orphan `{claude, nil, glm-4.6}`
  triple. The header's provider dropdown is derived from the persisted `harness`, so a
  `claude` row offered only `anthropic`, even though the model chip advertised a zai
  model. That made `zai` (and every non-anthropic pi provider) unselectable.

  This migration nulls the `model` on any orchestrator row whose `model` is recognisably
  foreign to its `harness` (per `RepoBuilder.Harness.Registry.model_offered_by_harness?/3`,
  which is lenient: only models that appear in SOME other harness's curated list — or, for
  pi, the live `pi --list-models` catalog — are treated as foreign; legitimately-unknown
  concrete ids are left alone). `provider` is left as-is so the operator's prior choice is
  preserved; the row simply no longer advertises a model it cannot run under its harness.

  Idempotent: only touches self-contradictory rows; a second run is a no-op. `down/0` is a
  no-op (data repair is irreversible by nature — the original foreign model string is not
  recoverable from the row alone, and re-introducing it would re-create the bug).
  """

  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Repo

  alias RepoBuilder.Orchestrator.Orchestrator

  import Ecto.Query

  def up do
    # Only run when the app modules are loaded (the migration executes under the app, but
    # guard with `Code.ensure_loaded?/1` so a partial boot never crashes).
    if Code.ensure_loaded?(Orchestrator) and Code.ensure_loaded?(Registry) do
      repair_inconsistent_rows()
    end
  end

  def down, do: :ok

  @spec repair_inconsistent_rows() :: :ok
  defp repair_inconsistent_rows do
    orchestrators =
      Repo.all(
        from(o in Orchestrator,
          where: not is_nil(o.model),
          select: %{id: o.id, harness: o.harness, provider: o.provider, model: o.model}
        )
      )

    Enum.reduce(orchestrators, 0, fn row, acc ->
      # `model_offered_by_harness?/3` is lenient (legitimately-unknown ids ⇒ true); only
      # recognisably cross-harness models (e.g. a `zai` model on a `claude` row) are
      # flagged. The `pi` branch consults the live catalog when discovery is enabled.
      if Registry.model_offered_by_harness?(row.harness, row.provider, row.model) do
        acc
      else
        {1, _} =
          Repo.update_all(from(o in Orchestrator, where: o.id == ^row.id), set: [model: nil])

        acc + 1
      end
    end)
    |> then(fn count -> :ok = log_repaired(count) end)
  end

  @spec log_repaired(non_neg_integer()) :: :ok
  defp log_repaired(count) do
    # Best-effort logging; never fail the migration on IO.
    IO.puts("[repair_inconsistent_orchestrator_models] nulled #{count} foreign model(s)")
    :ok
  end
end
