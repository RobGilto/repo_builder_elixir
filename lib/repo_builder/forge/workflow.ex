defmodule RepoBuilder.Forge.Workflow do
  @moduledoc """
  The forge ADW (forge-meta-artifact-generation, Phase 3): a deterministic
  `render → generate → validate → package` pipeline with a bounded validate→generate
  retry edge — exactly the fixed-shape, retry-on-failure machine the platform's
  `WorkflowEngine` already embodies, specialized to authoring one plugin.

  Generation is the only non-deterministic step: it drives a REAL harness session in an
  isolated scratch workspace (so a hallucinated write can never touch the target repo)
  to produce the artifact file(s). The session transport is behind an injectable
  `:generate_runner` seam — the default drives `Session` (dogfooding the core); tests
  inject a canned runner via the registry-seam discipline. Every transition persists
  through the `Forge` context and broadcasts on a per-artifact topic.

  Phase 3 ends a successful run at `:packaged` (the validated scratch dir recorded as
  `output_path`). Phase 4 extends `package/3` to synthesize a real plugin and run it
  through the install → activate lifecycle.
  """
  require Logger

  alias RepoBuilder.Forge
  alias RepoBuilder.Forge.{Artifact, Generator, Packager, Validator}
  alias RepoBuilder.Forge.Generator.Def
  alias RepoBuilder.Plugins
  alias RepoBuilder.Projects
  alias RepoBuilder.Session

  @pubsub RepoBuilder.PubSub

  @typedoc "A request handed to the generate runner seam."
  @type generate_request :: %{
          kind: Generator.kind(),
          harness: String.t(),
          prompt: String.t(),
          scratch_dir: String.t(),
          agent_id: String.t()
        }

  @typedoc "A generated file, relative to the scratch dir, plus its content."
  @type file :: %{path: String.t(), content: String.t()}

  @typedoc "The generate-runner seam: a request in, written files (or an error) out."
  @type generate_runner :: (generate_request() -> {:ok, [file()]} | {:error, term()})

  @doc "Subscribe the caller to `{:forge_progress, Artifact.t()}` updates for `artifact_id`."
  @spec subscribe(Ecto.UUID.t()) :: :ok
  def subscribe(artifact_id) when is_binary(artifact_id) do
    _ = Phoenix.PubSub.subscribe(@pubsub, topic(artifact_id))
    :ok
  end

  @doc """
  Run the forge ADW for `artifact` to a terminal state. Returns the final `Artifact`
  (status `:packaged`/`:installed` on success, `:failed` otherwise). Synchronous — wrap
  in a `Task` for the live UI. `opts`:

    * `:generate_runner` — override the generation transport (tests inject a canned one).
    * `:harness` — override the generation harness (default: configured `generation_harness`).

  Always `{:ok, Artifact.t()}` — every failure path is folded into a `:failed` artifact
  rather than surfaced as an error tuple, so callers handle one shape.
  """
  @spec run(Artifact.t(), keyword()) :: {:ok, Artifact.t()}
  def run(%Artifact{} = artifact, opts \\ []) do
    with {:ok, def_t} <- Generator.fetch(artifact.kind),
         {:ok, prompt} <- render(def_t, artifact) do
      runner = Keyword.get(opts, :generate_runner, default_runner())
      harness = Keyword.get(opts, :harness) || generation_harness()
      loop(artifact, def_t, prompt, runner, harness, max_retries())
    else
      {:error, reason} -> {:ok, fail(artifact, reason)}
    end
  end

  # --- render ---

  @doc "Render the generator prompt for `artifact`: project context + spec into the template."
  @spec render(Def.t(), Artifact.t()) :: {:ok, String.t()} | {:error, term()}
  def render(%Def{} = def_t, %Artifact{} = artifact) do
    case File.read(Generator.template_path(def_t)) do
      {:ok, template} ->
        rendered =
          template
          |> String.replace("{{PROJECT_CONTEXT}}", project_context(artifact.project_id))
          |> String.replace("{{SPEC}}", artifact.spec || "")

        {:ok, rendered}

      {:error, reason} ->
        {:error, {:template_unreadable, reason}}
    end
  end

  @spec project_context(Ecto.UUID.t() | nil) :: String.t()
  defp project_context(nil), do: "(platform-wide artifact — no single target project.)"

  defp project_context(project_id) do
    case Projects.get_project(project_id) do
      %{context_primer: primer} when is_binary(primer) and primer != "" -> primer
      %{name: name} -> "Target project: #{name} (no detected stack profile yet)."
      _ -> "(unknown project.)"
    end
  end

  # --- generate → validate (with retry edge) ---

  @spec loop(Artifact.t(), Def.t(), String.t(), generate_runner(), String.t(), non_neg_integer()) ::
          {:ok, Artifact.t()}
  defp loop(artifact, def_t, prompt, runner, harness, retries_left) do
    artifact = transition(artifact, :generating)
    scratch = scratch_dir(artifact)
    _ = File.mkdir_p(scratch)

    request = %{
      kind: def_t.kind,
      harness: harness,
      prompt: prompt,
      scratch_dir: scratch,
      agent_id: "forge-#{artifact.id}-#{retries_left}"
    }

    case runner.(request) do
      {:ok, files} ->
        validate(artifact, def_t, prompt, runner, harness, retries_left, scratch, files)

      {:error, reason} ->
        retry_or_fail(artifact, def_t, prompt, runner, harness, retries_left, {:generate, reason})
    end
  end

  @spec validate(
          Artifact.t(),
          Def.t(),
          String.t(),
          generate_runner(),
          String.t(),
          non_neg_integer(),
          String.t(),
          [file()]
        ) :: {:ok, Artifact.t()}
  defp validate(artifact, def_t, prompt, runner, harness, retries_left, scratch, files) do
    artifact = transition(artifact, :validating)

    case Validator.validate(def_t.kind, files) do
      :ok ->
        {:ok, package(artifact, def_t, scratch)}

      {:error, reasons} ->
        retry_or_fail(
          artifact,
          def_t,
          prompt,
          runner,
          harness,
          retries_left,
          {:validation, reasons}
        )
    end
  end

  @spec retry_or_fail(
          Artifact.t(),
          Def.t(),
          String.t(),
          generate_runner(),
          String.t(),
          non_neg_integer(),
          term()
        ) :: {:ok, Artifact.t()}
  defp retry_or_fail(artifact, _def_t, _prompt, _runner, _harness, 0, reason) do
    {:ok, fail(artifact, reason)}
  end

  defp retry_or_fail(artifact, def_t, prompt, runner, harness, retries_left, reason) do
    Logger.info("forge #{artifact.id} retrying after #{inspect(reason)} (#{retries_left} left)")
    loop(artifact, def_t, prompt, runner, harness, retries_left - 1)
  end

  # --- package → install → activate (Phase 4) ---

  # Synthesize a real plugin from the validated scratch dir, mark `:packaged`, then install
  # it and activate it for THIS project only (`nil` project = platform-wide), marking
  # `:installed`. A packaging/install failure folds into `:failed` — the target repo is
  # never touched (generation ran in scratch).
  @spec package(Artifact.t(), Def.t(), String.t()) :: Artifact.t()
  defp package(artifact, def_t, scratch) do
    case Packager.package(artifact, def_t, scratch) do
      {:ok, %{id: id, dir: dir}} ->
        artifact = transition(artifact, :packaged, %{output_path: dir, plugin_id: id})
        install_and_activate(artifact, id)

      {:error, reason} ->
        fail(artifact, {:package, reason})
    end
  end

  @spec install_and_activate(Artifact.t(), String.t()) :: Artifact.t()
  defp install_and_activate(artifact, id) do
    with {:ok, _plugin} <- Plugins.Installer.install(install_source(), id, "latest"),
         {:ok, _activation} <- Plugins.activate(artifact.project_id, id) do
      transition(artifact, :installed, %{plugin_id: id})
    else
      {:error, reason} -> fail(artifact, {:install, reason})
    end
  end

  # --- transitions + persistence ---

  # No @spec: the merged `extra` map is built from specific atom keys, so an inference-only
  # spec avoids a dialyzer `contract_supertype` (private fn, credo-exempt).
  defp transition(artifact, status, extra \\ %{}) do
    case Forge.mark_status(artifact, status, extra) do
      {:ok, updated} ->
        broadcast(updated)
        updated

      {:error, _changeset} ->
        artifact
    end
  end

  # No @spec: the reason is a union of internal failure tuples; an inference-only spec
  # avoids a dialyzer `contract_supertype` against `term()` (private fn, credo-exempt).
  defp fail(artifact, reason) do
    transition(artifact, :failed, %{error: %{"reason" => inspect(reason)}})
  end

  @spec broadcast(Artifact.t()) :: :ok
  defp broadcast(%Artifact{id: id} = artifact) when is_binary(id) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic(id), {:forge_progress, artifact})
    :ok
  end

  defp broadcast(_artifact), do: :ok

  @spec topic(Ecto.UUID.t()) :: String.t()
  defp topic(artifact_id), do: "forge:#{artifact_id}"

  # --- the default (production) generate runner: a real harness session ---

  @spec default_runner() :: generate_runner()
  defp default_runner do
    case config()[:generate_runner] do
      fun when is_function(fun, 1) -> fun
      _ -> &session_generate/1
    end
  end

  @doc """
  The production generate transport: refuse a no-op/`fake` harness, drive a real
  `Session` in the scratch cwd, await its terminal event, then collect every file the
  agent wrote. Total — returns `{:error, reason}` rather than raising.
  """
  @spec session_generate(generate_request()) :: {:ok, [file()]} | {:error, term()}
  def session_generate(%{harness: harness} = request) do
    if real_harness?(harness) do
      drive_session(request)
    else
      {:error, :no_real_harness}
    end
  end

  @spec drive_session(generate_request()) :: {:ok, [file()]} | {:error, term()}
  defp drive_session(%{
         agent_id: agent_id,
         harness: harness,
         prompt: prompt,
         scratch_dir: scratch
       }) do
    _ = Phoenix.PubSub.subscribe(@pubsub, "agent:#{agent_id}:events")

    case Session.Supervisor.start_session(
           agent_id: agent_id,
           harness: harness,
           prompt: prompt,
           cwd: scratch,
           isolation_mode: :direct
         ) do
      {:ok, _pid} ->
        await_session(scratch)

      {:error, reason} ->
        _ = Phoenix.PubSub.unsubscribe(@pubsub, "agent:#{agent_id}:events")
        {:error, {:session_start, reason}}
    end
  end

  @spec await_session(String.t()) :: {:ok, [file()]} | {:error, term()}
  defp await_session(scratch) do
    receive do
      {:harness_event, %{__struct__: RepoBuilder.Harness.Event.Done}} ->
        {:ok, collect_files(scratch)}

      {:harness_event, %{__struct__: RepoBuilder.Harness.Event.Error} = error} ->
        {:error, {:generation_failed, Map.get(error, :reason)}}

      {:harness_event, _other} ->
        await_session(scratch)
    after
      session_timeout_ms() -> {:error, :generation_timeout}
    end
  end

  @doc "Collect every file written under `scratch`, as `%{path: relative, content: binary}`."
  @spec collect_files(String.t()) :: [file()]
  def collect_files(scratch) do
    scratch
    |> walk()
    |> Enum.flat_map(fn abs ->
      case File.read(abs) do
        {:ok, content} -> [%{path: Path.relative_to(abs, scratch), content: content}]
        {:error, _} -> []
      end
    end)
  end

  @spec walk(String.t()) :: [String.t()]
  defp walk(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(&walk(Path.join(path, &1)))

      true ->
        []
    end
  end

  # --- config ---

  @spec scratch_dir(Artifact.t()) :: String.t()
  defp scratch_dir(%Artifact{id: id}) do
    base = Keyword.get(config(), :scratch_base, "priv/forge_scratch")
    Path.join(Path.expand(base, File.cwd!()), to_string(id))
  end

  @spec generation_harness() :: String.t()
  defp generation_harness, do: Keyword.get(config(), :generation_harness, "claude")

  @spec install_source() :: String.t()
  defp install_source, do: Keyword.get(config(), :default_source, "library")

  @spec max_retries() :: non_neg_integer()
  defp max_retries, do: Keyword.get(config(), :max_retries, 1)

  @spec session_timeout_ms() :: pos_integer()
  defp session_timeout_ms, do: Keyword.get(config(), :session_timeout_ms, 600_000)

  @spec real_harness?(term()) :: boolean()
  defp real_harness?(harness),
    do: is_binary(harness) and String.trim(harness) != "" and harness != "fake"

  @spec config() :: keyword()
  defp config, do: Application.get_env(:repo_builder, :forge, [])
end
