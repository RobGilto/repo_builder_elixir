defmodule RepoBuilder.Orchestrator.Workstreams do
  @moduledoc """
  Context for the durable WORKSTREAM layer (orchestration-adw-loop) — the orchestrator's
  top-level unit of work AND its external memory. The ONLY `Repo` caller for
  `orchestrator_workstreams`/`orchestrator_workstream_phases`. Every public function is
  `@spec`'d and returns tagged tuples (or, for the read indexes, plain lists).

  Three integrated capabilities live here:

    * **Decomposition** — `create_workstream/2` seeds a running workstream; `plan_phases/3`
      persists the work-decomposer's right-sized phase breakdown in one transaction.
    * **Execution** — `record_stage/3` drives each phase's `spec → implement → test →
      review` machine (with the `review → fix → review` branch), promoting the next phase on
      a passed review and accounting stalls toward `:blocked`.
    * **Memory** — `list_workstreams/1` (the compact rehydration INDEX) and
      `get_workstream/2` (the full rehydration RECORD) let the brain `compact_self` and
      re-read just enough to continue: goal/DoD, per-phase `spec_path`, completed vs
      remaining, the current pointer, and the single `next_action`.

  A `workstream_ref` resolves by id OR title (operator/brain ergonomics).
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias RepoBuilder.Orchestrator.{Workstream, WorkstreamPhase}
  alias RepoBuilder.Repo

  @type reason :: :not_found | :no_current_phase | :invalid_stage | :invalid_outcome | atom()
  @type stage :: WorkstreamPhase.stage()
  @type outcome :: :passed | :failed | :blocked

  @typedoc "One compact row of the rehydration INDEX (`list_workstreams/1`)."
  @type index_row :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          status: Workstream.status(),
          phase: String.t(),
          current_stage: WorkstreamPhase.current_stage() | nil,
          next_action: String.t(),
          stall_count: non_neg_integer()
        }

  @typedoc "One phase inside the full rehydration RECORD (`get_workstream/2`)."
  @type phase_view :: %{
          position: pos_integer(),
          title: String.t(),
          description: String.t() | nil,
          definition_of_done: String.t() | nil,
          spec_path: String.t() | nil,
          status: WorkstreamPhase.status(),
          current_stage: WorkstreamPhase.current_stage(),
          stages: map(),
          completed: [String.t()],
          remaining: [String.t()]
        }

  @typedoc "The full rehydration RECORD for one workstream (`get_workstream/2`)."
  @type full_record :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          goal: String.t() | nil,
          definition_of_done: String.t() | nil,
          status: Workstream.status(),
          stall_count: non_neg_integer(),
          current_phase_position: non_neg_integer(),
          next_action: String.t(),
          phases: [phase_view()]
        }

  # The work stages in pipeline order; the pointer after `:review` is the terminal `:done`.
  @stage_order [:spec, :implement, :test, :review]

  # Bounded fix/retry attempts before a phase is forced `:blocked` (no infinite review→fix
  # loop). A passed stage resets the workstream's `stall_count` to 0.
  @stall_limit 3

  # --- create / plan ---

  @doc "Create a fresh `:running` workstream (no phases yet). `attrs`: title, goal, definition_of_done."
  @spec create_workstream(Ecto.UUID.t(), map()) ::
          {:ok, Workstream.t()} | {:error, Ecto.Changeset.t()}
  def create_workstream(orchestrator_id, attrs) do
    params =
      %{
        orchestrator_id: orchestrator_id,
        title: fetch(attrs, :title),
        goal: fetch(attrs, :goal),
        definition_of_done: fetch(attrs, :definition_of_done),
        status: :running
      }

    %Workstream{} |> Workstream.changeset(params) |> Repo.insert()
  end

  @doc """
  Persist the decomposer's ordered phase breakdown for a workstream, in one transaction.
  `phases` is a list of `%{title, description, definition_of_done}` maps. The first phase is
  seeded `:running`/`current_stage: :spec` and the workstream's `current_phase_position` is
  set to it. Existing phases (a re-plan) are replaced. Positions are 1-based.
  """
  @spec plan_phases(Ecto.UUID.t(), String.t(), [map()]) ::
          {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
  def plan_phases(orchestrator_id, ref, phases) when is_list(phases) do
    with {:ok, workstream} <- resolve(orchestrator_id, ref) do
      if phases == [] do
        {:error, :no_phases}
      else
        insert_phases(workstream, phases)
      end
    end
  end

  def plan_phases(_orchestrator_id, _ref, _phases), do: {:error, :invalid_phases}

  @spec insert_phases(Workstream.t(), [map()]) ::
          {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
  defp insert_phases(workstream, phases) do
    multi =
      phases
      |> Enum.with_index(1)
      |> Enum.reduce(reset_phases_multi(workstream), fn {phase, position}, multi ->
        Multi.insert(multi, {:phase, position}, phase_changeset(workstream, phase, position))
      end)
      |> Multi.update(
        :workstream,
        Workstream.changeset(workstream, %{current_phase_position: 1, status: :running})
      )

    case Repo.transaction(multi) do
      {:ok, _changes} -> {:ok, load(workstream.id)}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec reset_phases_multi(Workstream.t()) :: Multi.t()
  defp reset_phases_multi(%Workstream{id: id}) do
    Multi.delete_all(
      Multi.new(),
      :clear_phases,
      from(p in WorkstreamPhase, where: p.workstream_id == ^id)
    )
  end

  @spec phase_changeset(Workstream.t(), map(), pos_integer()) :: Ecto.Changeset.t()
  defp phase_changeset(%Workstream{id: id}, phase, position) do
    {status, current_stage} = if position == 1, do: {:running, :spec}, else: {:pending, :spec}

    WorkstreamPhase.changeset(%WorkstreamPhase{}, %{
      workstream_id: id,
      position: position,
      title: fetch(phase, :title),
      description: fetch(phase, :description),
      definition_of_done: fetch(phase, :definition_of_done),
      status: status,
      current_stage: current_stage
    })
  end

  # --- record_stage (the per-phase state machine) ---

  @doc """
  Record the CURRENT phase's `stage` outcome and advance the machine. `attrs`:
  `stage` (spec|implement|test|review), `outcome` (passed|failed|blocked), and optional
  `artifact`/`worker`/`note`. A spec stage's `artifact` is also captured as the phase's
  `spec_path`.

  Advancement: a `passed` non-review stage advances `current_stage`
  (spec→implement→test→review); a `passed` review marks the phase `:done` and promotes the
  next `:pending` phase to `:running`; a `failed` review keeps `current_stage: :review` (the
  fix branch); any other `failed` retries the same stage; `blocked` blocks the phase +
  workstream. A passed stage resets `stall_count`; a no-advance bumps it, and once it hits
  the limit the phase + workstream go `:blocked` (no infinite loop).
  """
  @spec record_stage(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
  def record_stage(orchestrator_id, ref, attrs) do
    with {:ok, workstream} <- resolve(orchestrator_id, ref),
         {:ok, stage} <- cast_stage(fetch(attrs, :stage)),
         {:ok, outcome} <- cast_outcome(fetch(attrs, :outcome)),
         {:ok, phase} <- current_phase(workstream) do
      apply_stage(workstream, phase, stage, outcome, attrs)
    end
  end

  @spec apply_stage(Workstream.t(), WorkstreamPhase.t(), stage(), outcome(), map()) ::
          {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
  defp apply_stage(workstream, phase, stage, outcome, attrs) do
    stages = Map.put(phase.stages, to_string(stage), stage_record(outcome, attrs))
    spec_path = maybe_spec_path(phase, stage, attrs)
    {phase_attrs, ws_attrs} = transition(workstream, phase, stage, outcome)
    phase_attrs = phase_attrs |> Map.put(:stages, stages) |> Map.put(:spec_path, spec_path)

    multi =
      Multi.new()
      |> Multi.update(:phase, WorkstreamPhase.changeset(phase, phase_attrs))
      |> promote_next_phase(workstream, phase, outcome, stage)
      |> Multi.update(:workstream, Workstream.changeset(workstream, ws_attrs))

    case Repo.transaction(multi) do
      {:ok, _changes} -> {:ok, load(workstream.id)}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Compute {phase_attrs, workstream_attrs} for one recorded stage outcome. Inference-only
  # spec — the concrete attr maps narrow below a hand-written `{map(), map()}` range.
  defp transition(_workstream, _phase, :review, :passed) do
    {%{status: :done, current_stage: :done}, %{stall_count: 0}}
  end

  defp transition(_workstream, _phase, stage, :passed) do
    {%{status: :running, current_stage: next_stage(stage)}, %{stall_count: 0}}
  end

  defp transition(workstream, _phase, :review, :failed) do
    bumped = workstream.stall_count + 1
    blocked_or(bumped, %{current_stage: :review})
  end

  defp transition(workstream, _phase, stage, :failed) do
    bumped = workstream.stall_count + 1
    blocked_or(bumped, %{current_stage: stage})
  end

  defp transition(_workstream, _phase, _stage, :blocked) do
    {%{status: :blocked}, %{status: :blocked}}
  end

  # Bump the stall counter; once it reaches the limit the phase + workstream go `:blocked`.
  # Inference-only spec — the concrete attr maps narrow below a `{map(), map()}` range.
  defp blocked_or(stall_count, phase_attrs) when stall_count >= @stall_limit do
    {Map.put(phase_attrs, :status, :blocked), %{stall_count: stall_count, status: :blocked}}
  end

  defp blocked_or(stall_count, phase_attrs) do
    {Map.put(phase_attrs, :status, :running), %{stall_count: stall_count}}
  end

  # On a passed review, promote the immediate next `:pending` phase to `:running` and move
  # the workstream's `current_phase_position` to it. Any other outcome is a no-op.
  @spec promote_next_phase(Multi.t(), Workstream.t(), WorkstreamPhase.t(), outcome(), stage()) ::
          Multi.t()
  defp promote_next_phase(multi, workstream, phase, :passed, :review) do
    case next_pending_phase(workstream, phase.position) do
      %WorkstreamPhase{} = next ->
        multi
        |> Multi.update(
          :next_phase,
          WorkstreamPhase.changeset(next, %{status: :running, current_stage: :spec})
        )
        |> Multi.update(
          :advance,
          Workstream.changeset(workstream, %{current_phase_position: next.position})
        )

      nil ->
        multi
    end
  end

  defp promote_next_phase(multi, _workstream, _phase, _outcome, _stage), do: multi

  @spec next_pending_phase(Workstream.t(), pos_integer()) :: WorkstreamPhase.t() | nil
  defp next_pending_phase(%Workstream{id: id}, position) do
    Repo.one(
      from(p in WorkstreamPhase,
        where: p.workstream_id == ^id and p.position > ^position and p.status == :pending,
        order_by: [asc: p.position],
        limit: 1
      )
    )
  end

  # Inference-only spec — the concrete string-keyed stage map narrows below a `map()` range.
  defp stage_record(outcome, attrs) do
    %{
      "status" => to_string(outcome),
      "worker" => fetch(attrs, :worker),
      "artifact" => fetch(attrs, :artifact),
      "note" => fetch(attrs, :note)
    }
  end

  @spec maybe_spec_path(WorkstreamPhase.t(), stage(), map()) :: String.t() | nil
  defp maybe_spec_path(_phase, :spec, attrs), do: fetch(attrs, :artifact) || nil
  defp maybe_spec_path(phase, _stage, _attrs), do: phase.spec_path

  # Only ever called for a passed NON-review stage (review has its own transition clause),
  # so `:review` never reaches here — the pipeline's terminal `:done` is set directly there.
  @spec next_stage(:spec | :implement | :test) :: :implement | :test | :review
  defp next_stage(:spec), do: :implement
  defp next_stage(:implement), do: :test
  defp next_stage(:test), do: :review

  # --- close ---

  @doc "Close a workstream `:done` or `:abandoned`."
  @spec close_workstream(Ecto.UUID.t(), String.t(), atom() | String.t()) ::
          {:ok, Workstream.t()} | {:error, reason() | Ecto.Changeset.t()}
  def close_workstream(orchestrator_id, ref, status) do
    with {:ok, workstream} <- resolve(orchestrator_id, ref),
         {:ok, status} <- cast_close_status(status) do
      workstream |> Workstream.changeset(%{status: status}) |> Repo.update()
    end
  end

  # --- read: rehydration index + record ---

  @doc "The compact rehydration INDEX: one row per workstream (read this at turn start)."
  @spec list_workstreams(Ecto.UUID.t()) :: [index_row()]
  def list_workstreams(orchestrator_id) do
    orchestrator_id |> all_with_phases() |> Enum.map(&index_row/1)
  end

  @doc "Workstreams with a dispatchable next step (scheduler input): `:running`, not all-done."
  @spec ready_workstreams(Ecto.UUID.t()) :: [index_row()]
  def ready_workstreams(orchestrator_id) do
    orchestrator_id
    |> all_with_phases()
    |> Enum.filter(&ready?/1)
    |> Enum.map(&index_row/1)
  end

  @doc "The full rehydration RECORD for one workstream (goal/DoD, phases, pointer, next_action)."
  @spec get_workstream(Ecto.UUID.t(), String.t()) :: {:ok, full_record()} | {:error, reason()}
  def get_workstream(orchestrator_id, ref) do
    with {:ok, workstream} <- resolve(orchestrator_id, ref) do
      {:ok, record(workstream)}
    end
  end

  @doc """
  All of an orchestrator's workstreams as full RECORDs (phases preloaded) — the console
  Workstreams-panel feed. Newest first.
  """
  @spec list_records(Ecto.UUID.t()) :: [full_record()]
  def list_records(orchestrator_id) do
    orchestrator_id |> all_with_phases() |> Enum.map(&record/1)
  end

  # --- views ---

  @spec index_row(Workstream.t()) :: index_row()
  defp index_row(%Workstream{} = workstream) do
    phases = phases_list(workstream)
    current = current_phase_struct(workstream, phases)

    %{
      id: workstream.id,
      title: workstream.title,
      status: workstream.status,
      phase: "#{workstream.current_phase_position}/#{length(phases)}",
      current_stage: current && current.current_stage,
      next_action: next_action(workstream, phases, current),
      stall_count: workstream.stall_count
    }
  end

  @spec record(Workstream.t()) :: full_record()
  defp record(%Workstream{} = workstream) do
    phases = phases_list(workstream)
    current = current_phase_struct(workstream, phases)

    %{
      id: workstream.id,
      title: workstream.title,
      goal: workstream.goal,
      definition_of_done: workstream.definition_of_done,
      status: workstream.status,
      stall_count: workstream.stall_count,
      current_phase_position: workstream.current_phase_position,
      next_action: next_action(workstream, phases, current),
      phases: Enum.map(phases, &phase_view/1)
    }
  end

  @spec phase_view(WorkstreamPhase.t()) :: phase_view()
  defp phase_view(%WorkstreamPhase{} = phase) do
    %{
      position: phase.position,
      title: phase.title,
      description: phase.description,
      definition_of_done: phase.definition_of_done,
      spec_path: phase.spec_path,
      status: phase.status,
      current_stage: phase.current_stage,
      stages: phase.stages,
      completed: completed_stages(phase),
      remaining: remaining_stages(phase)
    }
  end

  @spec completed_stages(WorkstreamPhase.t()) :: [String.t()]
  defp completed_stages(%WorkstreamPhase{stages: stages}) do
    @stage_order
    |> Enum.filter(fn stage -> get_in(stages, [to_string(stage), "status"]) == "passed" end)
    |> Enum.map(&to_string/1)
  end

  @spec remaining_stages(WorkstreamPhase.t()) :: [String.t()]
  defp remaining_stages(%WorkstreamPhase{stages: stages}) do
    @stage_order
    |> Enum.reject(fn stage -> get_in(stages, [to_string(stage), "status"]) == "passed" end)
    |> Enum.map(&to_string/1)
  end

  # The single next action a brain should take to advance this workstream.
  @spec next_action(Workstream.t(), [WorkstreamPhase.t()], WorkstreamPhase.t() | nil) ::
          String.t()
  defp next_action(%Workstream{status: :done}, _phases, _current), do: "done — close or move on"
  defp next_action(%Workstream{status: :abandoned}, _phases, _current), do: "abandoned"

  defp next_action(%Workstream{status: :blocked}, _phases, _current),
    do: "blocked — replan this workstream or escalate"

  defp next_action(%Workstream{}, [], _current),
    do: "decompose: spawn work-decomposer, then plan_phases"

  defp next_action(%Workstream{}, _phases, nil),
    do: "all phases complete — verify and close_workstream(done)"

  defp next_action(%Workstream{}, _phases, %WorkstreamPhase{status: :done}),
    do: "all phases complete — verify and close_workstream(done)"

  defp next_action(%Workstream{}, _phases, %WorkstreamPhase{} = phase) do
    "#{stage_action(phase)} for phase #{phase.position} (#{phase.title})"
  end

  @spec stage_action(WorkstreamPhase.t()) :: String.t()
  defp stage_action(%WorkstreamPhase{current_stage: :spec}),
    do:
      "spec: run /feature|/bug|/chore|/plan, capture spec_path via record_stage(spec, passed, artifact:)"

  defp stage_action(%WorkstreamPhase{current_stage: :implement, spec_path: spec_path}),
    do:
      "implement: /implement #{spec_path || "<spec_path>"}, then record_stage(implement, passed)"

  defp stage_action(%WorkstreamPhase{current_stage: :test}),
    do: "test: /test, then record_stage(test, passed)"

  defp stage_action(%WorkstreamPhase{current_stage: :review, stages: stages}) do
    if get_in(stages, ["review", "status"]) == "failed",
      do: "fix: address review failures, then /review and record_stage(review, passed)",
      else: "review: /review, then record_stage(review, passed)"
  end

  defp stage_action(%WorkstreamPhase{current_stage: :done}),
    do: "phase done — next phase promoted"

  # --- resolution / loading ---

  @doc "Resolve a `workstream_ref` (id OR title), scoped to the orchestrator."
  @spec resolve(Ecto.UUID.t(), String.t()) :: {:ok, Workstream.t()} | {:error, :not_found}
  def resolve(orchestrator_id, ref) when is_binary(ref) do
    case by_id(orchestrator_id, ref) || by_title(orchestrator_id, ref) do
      %Workstream{} = workstream -> {:ok, workstream}
      nil -> {:error, :not_found}
    end
  end

  def resolve(_orchestrator_id, _ref), do: {:error, :not_found}

  @spec by_id(Ecto.UUID.t(), String.t()) :: Workstream.t() | nil
  defp by_id(orchestrator_id, ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, id} ->
        Repo.one(
          from(w in with_phases_query(),
            where: w.orchestrator_id == ^orchestrator_id and w.id == ^id
          )
        )

      :error ->
        nil
    end
  end

  @spec by_title(Ecto.UUID.t(), String.t()) :: Workstream.t() | nil
  defp by_title(orchestrator_id, title) do
    Repo.one(
      from(w in with_phases_query(),
        where: w.orchestrator_id == ^orchestrator_id and w.title == ^title,
        order_by: [desc: w.inserted_at, desc: w.id],
        limit: 1
      )
    )
  end

  @spec load(Ecto.UUID.t()) :: Workstream.t()
  defp load(id) do
    Repo.one!(from(w in with_phases_query(), where: w.id == ^id))
  end

  @spec all_with_phases(Ecto.UUID.t()) :: [Workstream.t()]
  defp all_with_phases(orchestrator_id) do
    Repo.all(
      from(w in with_phases_query(),
        where: w.orchestrator_id == ^orchestrator_id,
        order_by: [desc: w.inserted_at, desc: w.id]
      )
    )
  end

  @spec with_phases_query() :: Ecto.Query.t()
  defp with_phases_query do
    from(w in Workstream, preload: [phases: ^from(p in WorkstreamPhase, order_by: p.position)])
  end

  @spec phases_list(Workstream.t()) :: [WorkstreamPhase.t()]
  defp phases_list(%Workstream{phases: phases}) when is_list(phases), do: phases
  defp phases_list(%Workstream{}), do: []

  @spec current_phase(Workstream.t()) :: {:ok, WorkstreamPhase.t()} | {:error, :no_current_phase}
  defp current_phase(%Workstream{} = workstream) do
    case current_phase_struct(workstream, phases_list(workstream)) do
      %WorkstreamPhase{} = phase -> {:ok, phase}
      nil -> {:error, :no_current_phase}
    end
  end

  @spec current_phase_struct(Workstream.t(), [WorkstreamPhase.t()]) :: WorkstreamPhase.t() | nil
  defp current_phase_struct(%Workstream{current_phase_position: position}, phases) do
    Enum.find(phases, fn p -> p.position == position end)
  end

  @spec ready?(Workstream.t()) :: boolean()
  defp ready?(%Workstream{status: :running} = workstream) do
    case current_phase_struct(workstream, phases_list(workstream)) do
      %WorkstreamPhase{status: status} -> status not in [:blocked, :done]
      nil -> phases_list(workstream) == []
    end
  end

  defp ready?(%Workstream{}), do: false

  # --- casting ---

  @spec cast_stage(term()) :: {:ok, stage()} | {:error, :invalid_stage}
  defp cast_stage(stage) when stage in @stage_order, do: {:ok, stage}

  defp cast_stage(stage) when is_binary(stage) do
    case Enum.find(@stage_order, &(to_string(&1) == stage)) do
      nil -> {:error, :invalid_stage}
      atom -> {:ok, atom}
    end
  end

  defp cast_stage(_stage), do: {:error, :invalid_stage}

  @spec cast_outcome(term()) :: {:ok, outcome()} | {:error, :invalid_outcome}
  defp cast_outcome(outcome) when outcome in [:passed, :failed, :blocked], do: {:ok, outcome}

  defp cast_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "passed" -> {:ok, :passed}
      "failed" -> {:ok, :failed}
      "blocked" -> {:ok, :blocked}
      _ -> {:error, :invalid_outcome}
    end
  end

  defp cast_outcome(_outcome), do: {:error, :invalid_outcome}

  @spec cast_close_status(term()) :: {:ok, :done | :abandoned} | {:error, :invalid_status}
  defp cast_close_status(status) when status in [:done, :abandoned], do: {:ok, status}
  defp cast_close_status("done"), do: {:ok, :done}
  defp cast_close_status("abandoned"), do: {:ok, :abandoned}
  defp cast_close_status(_status), do: {:error, :invalid_status}

  # Read `key` from a map that may use atom OR string keys (in-process vs MCP dispatch).
  # Inference-only spec — the success typing narrows the key below a hand-written `atom()`.
  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
