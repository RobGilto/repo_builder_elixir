defmodule RepoBuilderWeb.ProjectComponents do
  @moduledoc """
  Typed function components for the agentic-layer adaptor UI: the global project
  switcher, a repo-health panel, the capability + command-pack panel (resolved command
  with provenance), and the plan-preview card reused by the planning wizard.
  """
  use Phoenix.Component

  alias RepoBuilder.Projects.Project

  @doc """
  The global project switcher chip. Emits `select_project` (`phx-change`) with the
  chosen `project_id` (blank = the unscoped "all / platform" view).
  """
  attr :projects, :list, required: true
  attr :active_project_id, :string, default: nil
  # The live orchestrator bound to the active project (orchestrator↔project binding): its
  # name, working dir, and latest context-window occupancy, so the operator can see WHICH
  # brain is live. Optional (nil ⇒ the chip is hidden) for back-compat with bare callers.
  attr :orchestrator_name, :string, default: nil
  attr :orchestrator_working_dir, :string, default: nil
  attr :orchestrator_context, :integer, default: 0
  attr :rest, :global

  @spec switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def switcher(assigns) do
    ~H"""
    <form
      id="project-switcher"
      phx-change="select_project"
      class="inline-flex items-center gap-2"
      {@rest}
    >
      <span class="text-xs uppercase tracking-wide text-zinc-400">Project</span>
      <select
        name="project_id"
        class="rounded border border-zinc-600 bg-zinc-800 px-2 py-1 text-sm"
      >
        <option value="" selected={is_nil(@active_project_id)}>All / platform</option>
        <option
          :for={project <- @projects}
          value={project.id}
          selected={project.id == @active_project_id}
        >
          {project.name}
        </option>
      </select>
      <span
        :if={@orchestrator_name}
        id="active-orchestrator"
        class="inline-flex items-center gap-1 rounded bg-zinc-800/60 px-2 py-0.5 text-xs text-zinc-300 transition-colors"
        title={@orchestrator_working_dir || "no working directory"}
      >
        <span class="text-zinc-500">brain:</span>
        <span class="font-mono">{@orchestrator_name}</span>
        <span :if={@orchestrator_context > 0} class="text-zinc-500">
          · {@orchestrator_context} tok
        </span>
      </span>
    </form>
    """
  end

  @doc "Repo-health summary: stack badges, branch, isolation mode."
  attr :project, Project, required: true

  @spec repo_health(map()) :: Phoenix.LiveView.Rendered.t()
  def repo_health(assigns) do
    ~H"""
    <div class="rounded border border-zinc-700 p-4 space-y-2">
      <h3 class="font-semibold">Repo health</h3>
      <div class="flex flex-wrap gap-2 text-xs">
        <span class="rounded bg-violet-900 px-2 py-0.5">{stack_label(@project.stack)}</span>
        <span class="rounded bg-zinc-700 px-2 py-0.5">
          branch: {@project.default_branch || "—"}
        </span>
        <span class="rounded bg-zinc-700 px-2 py-0.5">isolation: {@project.isolation_mode}</span>
        <span class="rounded bg-zinc-700 px-2 py-0.5">pack: {pack_label(@project)}</span>
      </div>
      <p class="text-xs text-zinc-400 break-all">{@project.root_path}</p>
      <p :if={@project.git_remote} class="text-xs text-zinc-400 break-all">
        remote: {@project.git_remote}
      </p>
    </div>
    """
  end

  @doc "Capability + command-pack panel: each resolved command with its provenance."
  attr :resolved, :list, required: true
  attr :capabilities, :map, default: %{}

  @spec command_pack_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def command_pack_panel(assigns) do
    ~H"""
    <div class="rounded border border-zinc-700 p-4 space-y-3">
      <h3 class="font-semibold">Capability map &amp; resolved commands</h3>

      <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
        <div :for={{label, value} <- capability_rows(@capabilities)}>
          <dt class="inline text-zinc-400">{label}:</dt>
          <dd class="inline font-mono">{value}</dd>
        </div>
      </dl>

      <table class="w-full text-xs">
        <thead>
          <tr class="text-left text-zinc-400">
            <th class="py-1">Command</th>
            <th class="py-1">Resolved from (provenance)</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @resolved} class="border-t border-zinc-800">
            <td class="py-1 font-mono">/{r.name}</td>
            <td class="py-1 text-zinc-300">{r.provenance}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Plan-preview card: resolved steps (with provenance) + the cost/context estimate."
  attr :plan, :map, required: true

  @spec plan_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def plan_preview(assigns) do
    ~H"""
    <div class="rounded border border-cyan-800 p-4 space-y-3">
      <h3 class="font-semibold">Plan preview</h3>
      <ol class="list-decimal pl-5 space-y-2 text-sm">
        <li :for={step <- @plan.steps}>
          <span class="font-mono">{step.name}</span>
          <span class="text-xs text-zinc-400">({step.provenance})</span>
          <pre class="mt-1 whitespace-pre-wrap rounded bg-zinc-900 p-2 text-xs text-zinc-300">{step.preview}</pre>
        </li>
      </ol>
      <div class="flex flex-wrap gap-3 text-xs">
        <span class="rounded bg-zinc-700 px-2 py-0.5">
          est. context: {@plan.estimate.context_tokens} tok
        </span>
        <span class="rounded bg-zinc-700 px-2 py-0.5">
          est. cost: {@plan.estimate.cost_band}
        </span>
      </div>
    </div>
    """
  end

  # --- helpers ---

  @spec stack_label(map() | nil) :: String.t()
  defp stack_label(%{"language" => language} = stack) do
    case stack["build_tool"] do
      tool when is_binary(tool) and tool != "" -> "#{language} (#{tool})"
      _ -> to_string(language)
    end
  end

  defp stack_label(_stack), do: "unknown"

  @spec pack_label(Project.t()) :: String.t()
  defp pack_label(%Project{command_pack: pack, command_pack_version: version}) do
    "#{pack}@#{version}"
  end

  @spec capability_rows(map()) :: [{String.t(), String.t()}]
  defp capability_rows(capabilities) do
    [
      {"language", "language"},
      {"test", "test_command"},
      {"build", "build_command"},
      {"lint", "lint_command"},
      {"format", "format_command"},
      {"typecheck", "typecheck_command"},
      {"run", "run_command"},
      {"package manager", "package_manager"},
      {"spec dir", "spec_dir"},
      {"test dir", "test_dir"}
    ]
    |> Enum.map(fn {label, key} -> {label, present(Map.get(capabilities, key))} end)
  end

  @spec present(term()) :: String.t()
  defp present(nil), do: "—"
  defp present(""), do: "—"
  defp present(value) when is_list(value), do: Enum.join(value, ", ")
  defp present(value), do: to_string(value)
end
