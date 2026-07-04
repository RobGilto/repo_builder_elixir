defmodule RepoBuilder.Adw.Scaffold do
  @moduledoc """
  Deterministic generator for portable Python ADW scripts materialized from a saved
  combo. PURE string render (`render/1`) plus a filesystem writer (`generate/1`) that
  writes `adws/adw_<name>_iso.py` / `adws/adw_<name>_local_iso.py` / `adws/adw_<name>_direct.py`,
  chmods `0755`, and refuses to clobber an existing file. Never raises.

  Three templates, one per flavor:

    * `:iso` — reproduces `adws/adw_new.py:make_script(name, steps, local=false)`
      BYTE-FOR-BYTE (the subprocess-chaining GitHub composite, twin of
      `adws/adw_plan_build_iso.py`). A golden fixture pins the parity.
    * `:local_iso` — a thin MONOLITHIC script (single `<adw-id>` + `run.json` local
      contract) that delegates step-threading to `adw_modules.workflow_ops.run_local_workflow`.
      It deliberately does NOT emit the broken chaining form `adw_new.py --local` would.
    * `:direct` — like `:local_iso` but runs steps in the CURRENT CHECKOUT in place
      (`isolated=False`) — no throwaway worktree, no new branch, ships via direct commit.

  This is Elixir-native and deterministic (no `uv` needed) so `mix test` covers it; the
  `@tag :external` parity test asserts it cannot drift from `adw_new.py` when `uv` is present.
  """

  @type step :: :plan | :patch | :build | :test | :review | :document | :ship
  @type flavor :: :iso | :local_iso | :direct
  @type reason :: atom() | {atom(), term()}

  @type request :: %{
          required(:name) => String.t(),
          required(:steps) =>
            [RepoBuilder.Adw.StepSpec.t()] | [{step(), String.t() | nil}] | [step()],
          required(:flavor) => flavor(),
          optional(:root) => String.t(),
          optional(:overwrite) => boolean()
        }

  @type generated :: %{path: String.t(), name: String.t(), script: String.t()}

  # Step allowlist parity with `adws/adw_new.py:VALID_STEPS`.
  @valid_steps [:plan, :patch, :build, :test, :review, :document, :ship]

  @doc """
  Pure render of the combo's Python script text for its flavor. Validates the name
  (slugifiable stem) and the non-empty, allowlisted step list first. Never writes.
  """
  @spec render(request()) :: {:ok, String.t()} | {:error, reason()}
  def render(request) when is_map(request) do
    raw_steps = Map.get(request, :steps, [])

    with {:ok, stem} <- stem(Map.get(request, :name)),
         {:ok, steps} <- steps(raw_steps),
         {:ok, flavor} <- flavor(Map.get(request, :flavor)) do
      case flavor do
        :iso -> {:ok, render_iso(stem, steps)}
        :local_iso -> {:ok, render_local_iso(stem, steps, raw_steps)}
        :direct -> {:ok, render_direct(stem, steps, raw_steps)}
      end
    end
  end

  def render(_request), do: {:error, :invalid_request}

  @doc """
  Render + write the script under `<root>/adws/`, `chmod 0755`. Refuses to overwrite an
  existing file unless `overwrite: true` (`{:error, :exists}`). Returns the absolute path,
  the filename stem, and the written text. Total — filesystem errors map to `{:error, _}`.
  """
  @spec generate(request()) :: {:ok, generated()} | {:error, reason()}
  def generate(request) when is_map(request) do
    with {:ok, stem} <- stem(Map.get(request, :name)),
         {:ok, _steps} <- steps(Map.get(request, :steps)),
         {:ok, flavor} <- flavor(Map.get(request, :flavor)),
         {:ok, script} <- render(request) do
      path = script_path(request, stem, flavor)
      overwrite? = Map.get(request, :overwrite, false) == true

      if File.exists?(path) and not overwrite? do
        {:error, :exists}
      else
        write(path, script, stem)
      end
    end
  end

  def generate(_request), do: {:error, :invalid_request}

  @doc "The absolute script path a request would write to (no I/O)."
  @spec script_path(request(), String.t(), flavor()) :: String.t()
  def script_path(request, stem, flavor) do
    suffix =
      case flavor do
        :local_iso -> "_local_iso"
        :direct -> "_direct"
        _ -> "_iso"
      end

    root = Map.get(request, :root) || File.cwd!()
    Path.join([root, "adws", "adw_#{stem}#{suffix}.py"])
  end

  @doc "The step allowlist (atoms), parity with `adw_new.py:VALID_STEPS`."
  @spec valid_steps() :: [:build | :document | :patch | :plan | :review | :ship | :test, ...]
  def valid_steps, do: @valid_steps

  # --- internals ---

  @spec write(String.t(), String.t(), String.t()) :: {:ok, generated()} | {:error, reason()}
  defp write(path, script, stem) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, script),
         :ok <- File.chmod(path, 0o755) do
      {:ok, %{path: path, name: stem, script: script}}
    else
      {:error, posix} -> {:error, posix}
    end
  rescue
    error -> {:error, {:write_failed, Exception.message(error)}}
  end

  @spec stem(term()) :: {:ok, String.t()} | {:error, reason()}
  defp stem(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if slug == "", do: {:error, :invalid_name}, else: {:ok, slug}
  end

  defp stem(_name), do: {:error, :missing_name}

  @spec steps(term()) :: {:ok, [step()]} | {:error, reason()}
  defp steps(steps) when is_list(steps) and steps != [] do
    # Accept StepSpec structs, plain atoms, and {step, prompt} tuples; extract the atom.
    atoms =
      Enum.map(steps, fn
        %{name: s} -> s
        {s, _prompt} -> s
        s -> s
      end)

    case Enum.reject(atoms, &(&1 in @valid_steps)) do
      [] -> {:ok, atoms}
      [bad | _rest] -> {:error, {:invalid_step, bad}}
    end
  end

  defp steps([]), do: {:error, :no_steps}
  defp steps(_other), do: {:error, :invalid_steps}

  @spec flavor(term()) :: {:error, :invalid_flavor} | {:ok, :iso | :local_iso | :direct}
  defp flavor(nil), do: {:ok, :iso}
  defp flavor(flavor) when flavor in [:iso, :local_iso, :direct], do: {:ok, flavor}
  defp flavor(_other), do: {:error, :invalid_flavor}

  # ---- :iso template (byte-parity with adw_new.py make_script(local=false)) ----

  @spec render_iso(String.t(), [step()]) :: String.t()
  defp render_iso(stem, steps) do
    script_name = "adw_#{stem}_iso.py"
    title = title_words(String.replace(stem, "_", " "))
    step_names = Enum.map_join(steps, " + ", &Atom.to_string/1)

    doc_steps =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "#{i}. adw_#{step}_iso.py - #{cap(step)} phase"
      end)

    usage_lines =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        ~s|        print("  #{i}. #{cap(step)}")|
      end)

    steps_block = Enum.map_join(steps, "\n\n", &iso_step_block/1)

    """
    #!/usr/bin/env -S uv run
    # /// script
    # dependencies = ["python-dotenv", "pydantic"]
    # ///

    \"\"\"
    ADW #{title} Iso - Compositional workflow for isolated #{step_names}

    Usage: uv run #{script_name} <issue-number> [adw-id]

    This script runs:
    #{doc_steps}

    The scripts are chained together via persistent state (adw_state.json).
    \"\"\"

    import subprocess
    import sys
    import os

    # Add the parent directory to Python path to import modules
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from adw_modules.workflow_ops import ensure_adw_id


    def main():
        \"\"\"Main entry point.\"\"\"
        if len(sys.argv) < 2:
            print("Usage: uv run #{script_name} <issue-number> [adw-id]")
            print("\\nThis runs the isolated #{step_names} workflow:")
    #{usage_lines}
            sys.exit(1)

        issue_number = sys.argv[1]
        adw_id = sys.argv[2] if len(sys.argv) > 2 else None

        # Ensure ADW ID exists with initialized state
        adw_id = ensure_adw_id(issue_number, adw_id)
        print(f"Using ADW ID: {adw_id}")

        # Get the directory where this script is located
        script_dir = os.path.dirname(os.path.abspath(__file__))

    #{steps_block}

        print(f"\\n=== ISOLATED WORKFLOW COMPLETED ===")
        print(f"ADW ID: {adw_id}")
        print(f"All phases completed successfully!")


    if __name__ == "__main__":
        main()
    """
  end

  @spec iso_step_block(step()) :: String.t()
  defp iso_step_block(step) do
    var = Atom.to_string(step)
    upper = String.upcase(var)

    # Heredoc ends with a newline; trim it so blocks join with exactly one blank line.
    String.trim_trailing(
      """
          #{var}_cmd = [
              "uv",
              "run",
              os.path.join(script_dir, "adw_#{var}_iso.py"),
              issue_number,
              adw_id,
          ]
          print(f"\\n=== ISOLATED #{upper} PHASE ===")
          print(f"Running: {' '.join(#{var}_cmd)}")
          #{var} = subprocess.run(#{var}_cmd)
          if #{var}.returncode != 0:
              print("Isolated #{var} phase failed")
              sys.exit(1)
      """,
      "\n"
    )
  end

  # ---- :local_iso template (monolithic; single <adw-id> + run.json contract) ----

  @spec render_local_iso(String.t(), [step()], list()) :: String.t()
  defp render_local_iso(stem, steps, raw_steps) do
    script_name = "adw_#{stem}_local_iso.py"
    workflow_name = "adw_#{stem}_local_iso"
    title = title_words(String.replace(stem, "_", " "))
    step_names = Enum.map_join(steps, " + ", &Atom.to_string/1)
    steps_list = steps_list_python(steps, raw_steps)

    """
    #!/usr/bin/env -S uv run
    # /// script
    # dependencies = ["python-dotenv", "pydantic"]
    # ///

    \"\"\"
    ADW #{title} Local Iso - GitHub-optional #{step_names} in an isolated worktree

    Usage: uv run #{script_name} <adw-id>

    The single positional argument is the whole CLI contract: the launcher writes
    agents/<adw_id>/run.json (status pending) BEFORE spawning, and this workflow pulls
    all task context from that record (local launch contract, see
    adw_modules/local_ops.py). The default path makes ZERO GitHub or network calls.

    Steps: #{step_names}

    This is a GENERATED combo (RepoBuilder.Adw.Scaffold). Step-threading is delegated to
    adw_modules.workflow_ops.run_local_workflow so every generated local composite runs
    against the single-<adw-id> + run.json contract instead of the broken chaining form.
    \"\"\"

    import sys

    from dotenv import load_dotenv

    from adw_modules import local_ops
    from adw_modules.utils import check_env_vars, setup_logger
    from adw_modules.workflow_ops import run_local_workflow

    WORKFLOW_NAME = "#{workflow_name}"
    STEPS = [#{steps_list}]


    def main():
        \"\"\"Main entry point.\"\"\"
        load_dotenv()

        if len(sys.argv) < 2:
            print("Usage: uv run #{script_name} <adw-id>")
            print("\\nError: the run record agents/<adw-id>/run.json is the task")
            print("context — create it first (local_ops.create_run or the")
            print("orchestrator app), then launch with its adw-id.")
            sys.exit(1)

        adw_id = sys.argv[1]
        logger = setup_logger(adw_id, WORKFLOW_NAME)
        logger.info(f"{WORKFLOW_NAME} starting - ID: {adw_id}")

        # Validate environment (CLAUDE_CODE_PATH is the only hard requirement)
        check_env_vars(logger)

        # Load and validate the run record — it IS the launch context
        run = local_ops.load_run(adw_id)
        if run is None:
            print(f"No run record at agents/{adw_id}/run.json")
            logger.error(f"Missing or corrupt run record for {adw_id}")
            sys.exit(1)

        run_local_workflow(adw_id, STEPS, logger)


    if __name__ == "__main__":
        main()
    """
  end

  # ---- :direct template (monolithic; single <adw-id> + run.json; no worktree) ----

  @spec render_direct(String.t(), [step()], list()) :: String.t()
  defp render_direct(stem, steps, raw_steps) do
    script_name = "adw_#{stem}_direct.py"
    workflow_name = "adw_#{stem}_direct"
    title = title_words(String.replace(stem, "_", " "))
    step_names = Enum.map_join(steps, " + ", &Atom.to_string/1)
    steps_list = steps_list_python(steps, raw_steps)

    """
    #!/usr/bin/env -S uv run
    # /// script
    # dependencies = ["python-dotenv", "pydantic"]
    # ///

    \"\"\"
    ADW #{title} Direct - GitHub-optional #{step_names} in the current checkout (no worktree)

    Usage: uv run #{script_name} <adw-id>

    The single positional argument is the whole CLI contract: the launcher writes
    agents/<adw_id>/run.json (status pending) BEFORE spawning, and this workflow pulls
    all task context from that record (local launch contract, see
    adw_modules/local_ops.py). The default path makes ZERO GitHub or network calls.

    Steps: #{step_names}

    This is a GENERATED combo (RepoBuilder.Adw.Scaffold). Step-threading is delegated to
    adw_modules.workflow_ops.run_local_workflow with isolated=False so every step runs
    against the current checkout in place — no throwaway worktree, no branch, ships via a
    direct commit on the current branch.
    \"\"\"

    import sys

    from dotenv import load_dotenv

    from adw_modules import local_ops
    from adw_modules.utils import check_env_vars, setup_logger
    from adw_modules.workflow_ops import run_local_workflow

    WORKFLOW_NAME = "#{workflow_name}"
    STEPS = [#{steps_list}]


    def main():
        \"\"\"Main entry point.\"\"\"
        load_dotenv()

        if len(sys.argv) < 2:
            print("Usage: uv run #{script_name} <adw-id>")
            print("\\nError: the run record agents/<adw-id>/run.json is the task")
            print("context — create it first (local_ops.create_run or the")
            print("orchestrator app), then launch with its adw-id.")
            sys.exit(1)

        adw_id = sys.argv[1]
        logger = setup_logger(adw_id, WORKFLOW_NAME)
        logger.info(f"{WORKFLOW_NAME} starting - ID: {adw_id}")

        # Validate environment (CLAUDE_CODE_PATH is the only hard requirement)
        check_env_vars(logger)

        # Load and validate the run record — it IS the launch context
        run = local_ops.load_run(adw_id)
        if run is None:
            print(f"No run record at agents/{adw_id}/run.json")
            logger.error(f"Missing or corrupt run record for {adw_id}")
            sys.exit(1)

        run_local_workflow(adw_id, STEPS, logger, isolated=False)


    if __name__ == "__main__":
        main()
    """
  end

  # Python `str.title()` for a single lowercase step word (capitalize first letter).
  @spec cap(step()) :: String.t()
  defp cap(step), do: step |> Atom.to_string() |> String.capitalize()

  # Python `str.title()` for a space-separated stem: capitalize each word.
  @spec title_words(String.t()) :: String.t()
  defp title_words(string) do
    string
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Build the Python STEPS list expression for monolithic templates.
  # A step with no model stays as a plain string: `"plan"`.
  # A step with a model becomes a dict: `{"step": "plan", "model": "opus"}`.
  # When no step has a model, the output is byte-identical to the old plain-string form
  # so GeneratedDriftTest / golden fixtures stay green for model-less combos.
  @spec steps_list_python([step()], list()) :: String.t()
  defp steps_list_python(steps, raw_steps) do
    # Build an index of step-atom → model from raw_steps (StepSpec structs, tuples, atoms).
    # For duplicated step names (e.g. plan, test, plan again) this takes the model for the
    # LAST occurrence; the index is only used as a hint for the template (best-effort).
    model_index =
      Enum.zip(steps, raw_steps)
      |> Enum.reduce(%{}, fn {atom, raw}, acc ->
        model =
          case raw do
            %{model: m} when is_binary(m) and m != "" -> m
            _ -> nil
          end

        if model, do: Map.put(acc, atom, model), else: acc
      end)

    Enum.map_join(steps, ", ", fn s ->
      case Map.get(model_index, s) do
        nil -> ~s("#{s}")
        model -> ~s({"step": "#{s}", "model": "#{model}"})
      end
    end)
  end
end
