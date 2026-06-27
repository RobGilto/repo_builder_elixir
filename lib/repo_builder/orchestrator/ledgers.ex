defmodule RepoBuilder.Orchestrator.Ledgers do
  @moduledoc """
  Context for the durable Task + Progress Ledgers (self-healing orchestrator, Phase 3). The
  ONLY `Repo` caller for `task_ledgers`/`progress_entries`. Every public function is
  `@spec`'d and returns tagged tuples; the write path is fail-soft where a hiccup must never
  break the turn that called it.

  The Magentic-One dual ledger: `upsert_goal/2` seeds/refreshes the orchestrator's single
  `:active` Task Ledger (objective + definition-of-done + plan); `record_progress/2` appends
  a per-turn Progress entry; the drive loop (Phase 4) reads `latest_progress/1` and drives
  the `stall_count` ladder via `bump_stall/1`/`reset_stall/1`; a goal ends via `mark_done/2`,
  `mark_escalated/2`, or `mark_abandoned/1`.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Orchestrator.{ProgressEntry, TaskLedger}
  alias RepoBuilder.Repo

  @type reason :: :no_active_ledger | Ecto.Changeset.t()

  @typedoc "The latest Progress entry, flattened for the console / `ledger_updated` broadcast."
  @type progress_view :: %{
          satisfied: boolean(),
          on_track: boolean(),
          looping: boolean(),
          made_progress: boolean(),
          next_agent: String.t() | nil,
          next_instruction: String.t() | nil,
          summary: String.t() | nil,
          at: DateTime.t() | nil
        }

  @typedoc "The active ledger + its latest progress, flattened for the console."
  @type view :: %{
          id: Ecto.UUID.t() | nil,
          orchestrator_id: Ecto.UUID.t() | nil,
          goal: String.t() | nil,
          definition_of_done: String.t() | nil,
          plan: [map()],
          status: TaskLedger.status(),
          stall_count: non_neg_integer(),
          progress: progress_view() | nil
        }

  @doc "The orchestrator's single `:active` Task Ledger, or nil when no goal is being driven."
  @spec current(Ecto.UUID.t()) :: TaskLedger.t() | nil
  def current(orchestrator_id) do
    Repo.one(
      from(l in TaskLedger,
        where: l.orchestrator_id == ^orchestrator_id and l.status == :active,
        limit: 1
      )
    )
  end

  @doc """
  Seed or refresh the orchestrator's active goal. With an existing `:active` ledger it
  updates the objective/definition-of-done/plan/facts/guesses in place; otherwise it creates
  a fresh `:active` ledger. `attrs` requires `:goal` and `:definition_of_done`; `:plan` is an
  optional list of step maps. Returns the (created/updated) ledger.
  """
  @spec upsert_goal(Ecto.UUID.t(), map()) :: {:ok, TaskLedger.t()} | {:error, Ecto.Changeset.t()}
  def upsert_goal(orchestrator_id, attrs) do
    params = Map.put(normalize(attrs), :orchestrator_id, orchestrator_id)

    case current(orchestrator_id) do
      %TaskLedger{} = ledger ->
        ledger |> TaskLedger.changeset(params) |> Repo.update()

      nil ->
        %TaskLedger{} |> TaskLedger.changeset(Map.put(params, :status, :active)) |> Repo.insert()
    end
  end

  @doc """
  Append a Progress entry to the orchestrator's active ledger. `attrs` carries any of
  `satisfied/on_track/looping/made_progress/next_agent/next_instruction/summary/turn_agent_id`.
  `{:error, :no_active_ledger}` when no goal is set.
  """
  @spec record_progress(Ecto.UUID.t(), map()) ::
          {:ok, ProgressEntry.t()} | {:error, reason()}
  def record_progress(orchestrator_id, attrs) do
    case current(orchestrator_id) do
      %TaskLedger{} = ledger -> insert_progress(ledger, attrs)
      nil -> {:error, :no_active_ledger}
    end
  end

  @doc """
  Backstop auto-record (called on turn flush): if the active ledger has NO Progress entry
  newer than `since` (the turn's start), the brain did not record this turn — write a minimal
  entry (`made_progress: false`, outcome in the summary) so the ledger never gaps. A no-op
  when there is no active ledger or the brain already recorded. Fail-soft.
  """
  @spec auto_record_progress(Ecto.UUID.t(), String.t() | nil, :ok | :error, DateTime.t()) :: :ok
  def auto_record_progress(orchestrator_id, turn_agent_id, outcome, since) do
    case current(orchestrator_id) do
      %TaskLedger{} = ledger ->
        if has_progress_since?(ledger, since) do
          :ok
        else
          _ =
            insert_progress(ledger, %{
              turn_agent_id: turn_agent_id,
              made_progress: false,
              on_track: outcome == :ok,
              summary: "auto-recorded: turn ended #{outcome} (no explicit progress report)"
            })

          :ok
        end

      nil ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "The most recent Progress entry for the orchestrator's active ledger, or nil."
  @spec latest_progress(Ecto.UUID.t()) :: ProgressEntry.t() | nil
  def latest_progress(orchestrator_id) do
    case current(orchestrator_id) do
      %TaskLedger{id: id} -> latest_progress_for_ledger(id)
      nil -> nil
    end
  end

  @doc "Increment the active ledger's stall counter (drive-loop stagnation). Returns the ledger."
  @spec bump_stall(Ecto.UUID.t()) :: {:ok, TaskLedger.t()} | {:error, reason()}
  def bump_stall(orchestrator_id) do
    update_active(orchestrator_id, fn ledger ->
      %{stall_count: ledger.stall_count + 1}
    end)
  end

  @doc "Reset the active ledger's stall counter to 0 (real progress was made)."
  @spec reset_stall(Ecto.UUID.t()) :: {:ok, TaskLedger.t()} | {:error, reason()}
  def reset_stall(orchestrator_id) do
    update_active(orchestrator_id, fn _ledger -> %{stall_count: 0} end)
  end

  @doc "Mark the active goal `:done` (verified complete). `attrs` is reserved for future use."
  @spec mark_done(Ecto.UUID.t(), map()) :: {:ok, TaskLedger.t()} | {:error, reason()}
  def mark_done(orchestrator_id, _attrs \\ %{}) do
    update_active(orchestrator_id, fn _ledger -> %{status: :done} end)
  end

  @doc "Mark the active goal `:escalated` (blocked, awaiting the human)."
  @spec mark_escalated(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, TaskLedger.t()} | {:error, reason()}
  def mark_escalated(orchestrator_id, _reason \\ nil) do
    update_active(orchestrator_id, fn _ledger -> %{status: :escalated} end)
  end

  @doc "Mark the active goal `:abandoned` (operator dropped it)."
  @spec mark_abandoned(Ecto.UUID.t()) :: {:ok, TaskLedger.t()} | {:error, reason()}
  def mark_abandoned(orchestrator_id) do
    update_active(orchestrator_id, fn _ledger -> %{status: :abandoned} end)
  end

  @doc """
  A flat, render-ready view of the orchestrator's current ledger + its latest Progress entry
  for the console / `ledger_updated` broadcast. `nil` when no goal is set.
  """
  @spec view(Ecto.UUID.t()) :: view() | nil
  def view(orchestrator_id) do
    case current(orchestrator_id) do
      %TaskLedger{} = ledger ->
        progress = latest_progress_for_ledger(ledger.id)

        %{
          id: ledger.id,
          orchestrator_id: ledger.orchestrator_id,
          goal: ledger.goal,
          definition_of_done: ledger.definition_of_done,
          plan: ledger.plan,
          status: ledger.status,
          stall_count: ledger.stall_count,
          progress: progress_view(progress)
        }

      nil ->
        nil
    end
  end

  # --- private ---

  @spec insert_progress(TaskLedger.t(), map()) ::
          {:ok, ProgressEntry.t()} | {:error, Ecto.Changeset.t()}
  defp insert_progress(%TaskLedger{id: ledger_id}, attrs) do
    %ProgressEntry{}
    |> ProgressEntry.changeset(Map.put(stringless(attrs), :task_ledger_id, ledger_id))
    |> Repo.insert()
  end

  @spec has_progress_since?(TaskLedger.t(), DateTime.t()) :: boolean()
  defp has_progress_since?(%TaskLedger{id: ledger_id}, since) do
    Repo.exists?(
      from(p in ProgressEntry,
        where: p.task_ledger_id == ^ledger_id and p.inserted_at >= ^since
      )
    )
  end

  @spec latest_progress_for_ledger(Ecto.UUID.t()) :: ProgressEntry.t() | nil
  defp latest_progress_for_ledger(ledger_id) do
    Repo.one(
      from(p in ProgressEntry,
        where: p.task_ledger_id == ^ledger_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        limit: 1
      )
    )
  end

  # Apply `fun.(ledger)` (a partial-params map) to the active ledger and persist.
  @spec update_active(Ecto.UUID.t(), (TaskLedger.t() -> map())) ::
          {:ok, TaskLedger.t()} | {:error, reason()}
  defp update_active(orchestrator_id, fun) do
    case current(orchestrator_id) do
      %TaskLedger{} = ledger ->
        ledger |> TaskLedger.changeset(fun.(ledger)) |> Repo.update()

      nil ->
        {:error, :no_active_ledger}
    end
  end

  @spec progress_view(ProgressEntry.t() | nil) :: progress_view() | nil
  defp progress_view(nil), do: nil

  defp progress_view(%ProgressEntry{} = p) do
    %{
      satisfied: p.satisfied,
      on_track: p.on_track,
      looping: p.looping,
      made_progress: p.made_progress,
      next_agent: p.next_agent,
      next_instruction: p.next_instruction,
      summary: p.summary,
      at: p.inserted_at
    }
  end

  # Cast tool-supplied attrs (string OR atom keys) to the subset the goal changeset accepts.
  @spec normalize(map()) :: map()
  defp normalize(attrs) do
    %{
      goal: fetch(attrs, :goal),
      definition_of_done: fetch(attrs, :definition_of_done),
      facts: fetch(attrs, :facts),
      guesses: fetch(attrs, :guesses),
      plan: normalize_plan(fetch(attrs, :plan)),
      project_id: fetch(attrs, :project_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Progress attrs may arrive atom-keyed (in-process tool dispatch) or string-keyed (MCP);
  # the changeset casts atom keys, so coerce string keys to atoms for the known fields.
  @spec stringless(map()) :: map()
  defp stringless(attrs) do
    %{
      turn_agent_id: fetch(attrs, :turn_agent_id),
      satisfied: fetch(attrs, :satisfied),
      on_track: fetch(attrs, :on_track),
      looping: fetch(attrs, :looping),
      made_progress: fetch(attrs, :made_progress),
      next_agent: fetch(attrs, :next_agent),
      next_instruction: fetch(attrs, :next_instruction),
      summary: fetch(attrs, :summary)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @spec normalize_plan(term()) :: [map()] | nil
  defp normalize_plan(plan) when is_list(plan) do
    Enum.map(plan, fn
      step when is_binary(step) -> %{"step" => step, "status" => "pending"}
      %{} = step -> step
      other -> %{"step" => to_string(other), "status" => "pending"}
    end)
  end

  defp normalize_plan(_plan), do: nil

  # Read `key` from a map that may use atom OR string keys.
  @spec fetch(map(), atom()) :: term()
  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
