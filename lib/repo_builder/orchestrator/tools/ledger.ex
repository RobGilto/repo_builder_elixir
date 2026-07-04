defmodule RepoBuilder.Orchestrator.Tools.Ledger do
  @moduledoc """
  Leadership / ledger tools (self-healing Phase 3): goal + definition-of-done,
  progress heartbeats, mid-run reflections, completion reporting, and the
  read-only path-jailed `inspect_repo` verification tool. Extracted verbatim
  from the monolithic `Orchestrator.Tools` (audit F3) — behaviour is
  byte-identical.
  """

  import RepoBuilder.Orchestrator.Tools.Shared,
    only: [
      blank_to_nil: 1,
      broadcast_ledger: 1,
      changeset_reason: 1,
      fetch_string: 2,
      orchestrator_project_id: 1
    ]

  alias RepoBuilder.Logs
  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrator.Reflections
  alias RepoBuilder.Orchestrator.SurfaceDetector
  alias RepoBuilder.Orchestrator.Tools.Shared
  alias RepoBuilder.Orchestrators

  @type reason :: Shared.reason()
  @type result :: Shared.result()

  # Caps for the read-only `inspect_repo` tool (self-healing Phase 3): bound the returned
  # text so a large file / huge diff can never overflow the orchestrator's stdout framing
  # (same rationale as the shared worker-text cap — see issue-log-2389).
  @inspect_read_cap 8_000
  @inspect_files_cap 200

  @spec set_goal(Ecto.UUID.t(), map()) :: result()
  def set_goal(orchestrator_id, args) do
    with {:ok, goal} <- fetch_string(args, "goal"),
         {:ok, dod} <- fetch_string(args, "definition_of_done") do
      attrs = %{
        goal: goal,
        definition_of_done: dod,
        plan: args["plan"],
        project_id: orchestrator_project_id(orchestrator_id)
      }

      case Ledgers.upsert_goal(orchestrator_id, attrs) do
        {:ok, ledger} ->
          _ = broadcast_ledger(orchestrator_id)
          {:ok, %{"status" => "goal_set", "ledger_id" => ledger.id, "goal" => ledger.goal}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_reason(changeset)}
      end
    end
  end

  @spec record_progress(Ecto.UUID.t(), map()) :: result()
  def record_progress(orchestrator_id, args) do
    attrs = %{
      "satisfied" => args["satisfied"],
      "looping" => args["looping"],
      "made_progress" => args["made_progress"],
      "next_agent" => args["next_agent"],
      "next_instruction" => args["next_instruction"],
      "summary" => args["summary"]
    }

    case Ledgers.record_progress(orchestrator_id, attrs) do
      {:ok, entry} ->
        _ = broadcast_ledger(orchestrator_id)
        {:ok, %{"status" => "recorded", "entry_id" => entry.id}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @spec get_ledger(Ecto.UUID.t()) :: result()
  def get_ledger(orchestrator_id) do
    case Ledgers.view(orchestrator_id) do
      nil -> {:ok, %{"status" => "no_goal"}}
      view -> {:ok, ledger_tool_map(view)}
    end
  end

  @spec report_complete(Ecto.UUID.t(), map()) :: result()
  def report_complete(orchestrator_id, args) do
    summary = blank_to_nil(args["summary"])
    recommendations = blank_to_nil(args["recommendations"])
    # Capture the goal BEFORE marking done (mark_done deactivates the ledger) so the reflection
    # can be scoped to it.
    goal = current_goal(orchestrator_id)

    case Ledgers.mark_done(orchestrator_id) do
      {:ok, _ledger} ->
        _ = broadcast_ledger(orchestrator_id)
        _ = notify_complete(orchestrator_id, summary, recommendations)
        _ = record_completion_reflection(orchestrator_id, goal, summary)
        {:ok, %{"status" => "done", "summary" => summary}}

      {:error, :no_active_ledger} ->
        {:error, :no_active_ledger}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_reason(changeset)}
    end
  end

  @doc """
  Read-only repo inspection scoped to the orchestrator's working_dir (path-jailed, capped),
  so the leader can verify "done" against the ACTUAL tree, not a worker's self-report.
  """
  @spec inspect_repo(Ecto.UUID.t(), map()) :: result()
  def inspect_repo(orchestrator_id, args) do
    with {:ok, op} <- fetch_string(args, "op"),
         {:ok, dir} <- resolve_working_dir(orchestrator_id) do
      case op do
        "git_status" -> git_status(dir)
        "changed_files" -> changed_files(dir)
        "read_file" -> read_file_jailed(dir, args["path"])
        "surfaces" -> detect_surfaces(dir)
        _ -> {:error, :invalid_op}
      end
    end
  end

  # On-demand verbal lesson write (self-healing Phase 5 — Reflexion): the LLM-callable
  # counterpart to the automatic completion/escalation writes, so a lesson learned MID-run
  # can be banked instead of lost at session end. Scoped to the orchestrator's bound project;
  # the goal defaults to the active ledger goal when omitted. Fail-soft via Reflections.record/1.
  @spec record_reflection(Ecto.UUID.t(), map()) :: result()
  def record_reflection(orchestrator_id, args) do
    with {:ok, lesson} <- fetch_string(args, "lesson") do
      case Reflections.record(%{
             lesson: lesson,
             goal: blank_to_nil(args["goal"]) || current_goal(orchestrator_id),
             orchestrator_id: orchestrator_id,
             project_id: orchestrator_project_id(orchestrator_id)
           }) do
        {:ok, reflection} ->
          {:ok, %{"status" => "recorded", "reflection_id" => reflection.id}}

        :error ->
          {:error, :reflection_not_recorded}
      end
    end
  end

  @spec current_goal(Ecto.UUID.t()) :: String.t() | nil
  defp current_goal(orchestrator_id) do
    case Ledgers.current(orchestrator_id) do
      %{goal: goal} -> goal
      _none -> nil
    end
  end

  # Capture a verbal lesson on completion (self-healing Phase 5 — Reflexion) so the next run for
  # this project starts ahead. Fail-soft via Reflections.record/1.
  @spec record_completion_reflection(Ecto.UUID.t(), String.t() | nil, String.t() | nil) :: :ok
  defp record_completion_reflection(orchestrator_id, goal, summary) do
    lesson = summary || "completed goal: #{goal || "(unnamed)"}"

    _ =
      Reflections.record(%{
        lesson: lesson,
        goal: goal,
        orchestrator_id: orchestrator_id,
        project_id: orchestrator_project_id(orchestrator_id)
      })

    :ok
  end

  # Inference-only spec — the concrete string-keyed map narrows below a `map()` range.
  defp ledger_tool_map(view) do
    %{
      "goal" => view.goal,
      "definition_of_done" => view.definition_of_done,
      "status" => to_string(view.status),
      "stall_count" => view.stall_count,
      "plan" => view.plan,
      "focus" => view.focus,
      "focus_set_at" => view.focus_set_at,
      "progress" => progress_tool_map(view.progress)
    }
  end

  # Inference-only spec — the concrete string-keyed map narrows below a hand-written
  # `map() | nil`, which Dialyzer rejects as a contract supertype.
  defp progress_tool_map(nil), do: nil

  defp progress_tool_map(progress) do
    %{
      "satisfied" => progress.satisfied,
      "on_track" => progress.on_track,
      "looping" => progress.looping,
      "made_progress" => progress.made_progress,
      "next_agent" => progress.next_agent,
      "next_instruction" => progress.next_instruction,
      "summary" => progress.summary
    }
  end

  @spec notify_complete(Ecto.UUID.t(), String.t() | nil, String.t() | nil) :: :ok
  defp notify_complete(orchestrator_id, summary, recommendations) do
    message = "orchestrator reported goal complete" <> if(summary, do: ": #{summary}", else: "")

    _ =
      Logs.create_system_log(%{
        level: :info,
        message: message,
        metadata: %{
          "orchestrator_id" => orchestrator_id,
          "action" => "report_complete",
          "recommendations" => recommendations
        }
      })

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # The orchestrator's working_dir, validated to exist (inspect_repo needs a real tree).
  @spec resolve_working_dir(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, reason()}
  defp resolve_working_dir(orchestrator_id) do
    case Orchestrators.fetch(orchestrator_id) do
      {:ok, %{working_dir: dir}} when is_binary(dir) and dir != "" ->
        if File.dir?(dir), do: {:ok, dir}, else: {:error, :working_dir_missing}

      {:ok, _orchestrator} ->
        {:error, :no_working_dir}

      {:error, :not_found} ->
        {:error, :orchestrator_not_found}
    end
  end

  # Front-end SURFACE detection (iterative-ui-ux polish phase): classify the built repo's
  # user-facing surface(s) so the brain can decide whether to append a `:ui_ux` phase. An
  # empty list ⇒ no front end ⇒ skip UI/UX. Never raises (SurfaceDetector is fail-soft).
  @spec detect_surfaces(String.t()) :: result()
  defp detect_surfaces(dir) do
    {:ok, surfaces} = SurfaceDetector.detect(dir)
    {:ok, %{"op" => "surfaces", "surfaces" => Enum.map(surfaces, &to_string/1)}}
  end

  @spec git_status(String.t()) :: result()
  defp git_status(dir) do
    case run_git(dir, ["status", "--short", "--branch"]) do
      {:ok, output} -> {:ok, %{"op" => "git_status", "output" => cap_text(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec changed_files(String.t()) :: result()
  defp changed_files(dir) do
    case run_git(dir, ["status", "--porcelain"]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.take(@inspect_files_cap)
          |> Enum.map(&parse_porcelain/1)

        {:ok, %{"op" => "changed_files", "files" => files, "count" => length(files)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_porcelain(String.t()) :: %{String.t() => String.t()}
  defp parse_porcelain(line) do
    %{
      "status" => line |> String.slice(0, 2) |> String.trim(),
      "path" => line |> String.slice(3..-1//1) |> to_string() |> String.trim()
    }
  end

  # Read a file STRICTLY under `dir` (path-jailed): reject any path that escapes the working
  # dir or descends into `.git`, cap the returned content, and refuse non-regular files.
  @spec read_file_jailed(String.t(), term()) :: result()
  defp read_file_jailed(_dir, path) when not is_binary(path) or path == "",
    do: {:error, "missing required argument: path"}

  defp read_file_jailed(dir, path) do
    base = Path.expand(dir)
    target = Path.expand(path, base)
    rel = Path.relative_to(target, base)

    cond do
      not jailed?(target, base) -> {:error, :path_outside_working_dir}
      ".git" in Path.split(rel) -> {:error, :path_forbidden}
      not File.regular?(target) -> {:error, :not_a_file}
      true -> read_capped(path, target)
    end
  end

  @spec jailed?(String.t(), String.t()) :: boolean()
  defp jailed?(target, base), do: target == base or String.starts_with?(target, base <> "/")

  @spec read_capped(String.t(), String.t()) :: result()
  defp read_capped(path, target) do
    case File.read(target) do
      {:ok, content} ->
        {:ok,
         %{
           "op" => "read_file",
           "path" => path,
           "content" => cap_text(content),
           "truncated" => byte_size(content) > @inspect_read_cap
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  # Run a git subcommand in `dir`, returning trimmed stdout or a normalized error string.
  # Never raises (a missing git / bad dir is surfaced as an error, not a tool crash).
  @spec run_git(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp run_git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output |> String.trim() |> cap_text()}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    _kind, reason -> {:error, inspect(reason)}
  end

  @spec cap_text(String.t()) :: String.t()
  defp cap_text(text) when is_binary(text), do: String.slice(text, 0, @inspect_read_cap)
end
