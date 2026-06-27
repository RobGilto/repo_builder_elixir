defmodule RepoBuilder.Orchestrator.WorkerFleet do
  @moduledoc """
  Deterministic, LLM-free classifier of an orchestrator's dispatched worker fleet —
  the cheap replacement for the autonomous drive loop polling live workers with billed
  turns (see `specs/issue-plan-adw-plan-sdlc_planner-deterministic-worker-fleet-gate.md`).

  The autonomous `RepoBuilder.Orchestrator.Driver` used to re-engage the orchestrator's
  expensive LLM turn just to discover *is my worker still alive / progressing / done?* —
  knowledge already present in cheap runtime state. This module answers it from a single
  indexed query (`Agents.live_workers_for/1`) plus a `SessionRegistry` liveness probe
  (`Session.Supervisor.whereis/1`) and the existing `heartbeat_at` column. Zero tokens.

  Fleet states:

    * `:active`     — ≥1 non-archived worker in `:running`/`:holding` whose session
      process is alive AND that is genuinely working (a `:holding` worker is alive-by-
      definition; a `:running` worker counts only while its `heartbeat_at` is within the
      progress grace). The event-driven holding pattern will re-engage the orchestrator
      when one of these terminates, so the Driver must stand down — no polling.
    * `:quiescent`  — workers exist but none are progressing (no live process, or all
      heartbeats stale). A legitimate, OCCASIONAL drive-nudge target.
    * `:empty`      — no live workers. Normal drive territory.

  Failure mode is conservative: if the DB/registry can't be read the fleet is reported
  `:active` so the Driver stands down (a missed backstop nudge is recovered by the next
  tick / the event-driven path — far cheaper than a poll storm).
  """

  require Logger

  alias RepoBuilder.Agents
  alias RepoBuilder.Session

  @type fleet_state :: :active | :quiescent | :empty

  @default_progress_grace_ms 90_000

  @doc """
  Classify `orchestrator_id`'s live worker fleet into `:active` / `:quiescent` / `:empty`.
  Token-free: one indexed query + a registry lookup per worker. Fail-soft to `:active`.
  """
  @spec classify(Ecto.UUID.t()) :: fleet_state()
  def classify(orchestrator_id) do
    case Agents.live_workers_for(orchestrator_id) do
      [] -> :empty
      workers -> if Enum.any?(workers, &progressing?/1), do: :active, else: :quiescent
    end
  rescue
    error ->
      Logger.warning("WorkerFleet.classify failed for #{orchestrator_id}: #{inspect(error)}")
      :active
  catch
    _kind, _reason -> :active
  end

  @doc """
  Whether the autonomous Driver may drive `orchestrator_id` this tick: true only when the
  fleet is NOT `:active` (i.e. `:empty` or `:quiescent`). An `:active` fleet is re-engaged
  event-driven by the holding pattern, never polled.
  """
  @spec drivable?(Ecto.UUID.t()) :: boolean()
  def drivable?(orchestrator_id), do: classify(orchestrator_id) != :active

  # A worker counts as progressing when its session process is alive AND it is either
  # legitimately blocked (`:holding`) or heartbeating within the progress grace.
  @spec progressing?(Agents.live_worker()) :: boolean()
  defp progressing?(%{id: id, status: status, heartbeat_at: heartbeat_at}) do
    alive?(id) and (status == :holding or fresh_heartbeat?(heartbeat_at))
  end

  @spec alive?(Ecto.UUID.t()) :: boolean()
  defp alive?(worker_id), do: is_pid(Session.Supervisor.whereis(worker_id))

  @spec fresh_heartbeat?(DateTime.t() | nil) :: boolean()
  defp fresh_heartbeat?(nil), do: false

  defp fresh_heartbeat?(%DateTime{} = heartbeat_at) do
    DateTime.diff(DateTime.utc_now(), heartbeat_at, :millisecond) <= progress_grace_ms()
  end

  @spec progress_grace_ms() :: pos_integer()
  defp progress_grace_ms do
    Application.get_env(:repo_builder, :orchestrator, [])[:worker_progress_grace_ms] ||
      @default_progress_grace_ms
  end
end
