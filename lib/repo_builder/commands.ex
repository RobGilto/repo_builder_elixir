defmodule RepoBuilder.Commands do
  @moduledoc """
  Public context for stack-aware command resolution (agentic-layer adaptor, Phase 3).
  A thin facade over `Commands.Resolver` (precedence + capability-token fill +
  provenance) and `Commands.Pack` (versioned pack discovery), so callers — the
  SlashExpander, the orchestrator system prompt, the project dashboard, and the
  planning wizard — depend on one stable surface.
  """
  alias RepoBuilder.Commands.{Pack, Provisioner, Resolved, Resolver}
  alias RepoBuilder.Definitions.Adw
  alias RepoBuilder.Projects.Project

  @doc "Resolve a single command name for a project (see `Resolver.resolve/2`)."
  @spec resolve(Project.t(), String.t()) :: {:ok, Resolved.t()} | {:error, :not_found}
  def resolve(%Project{} = project, name), do: Resolver.resolve(project, name)

  @doc "Resolve every command available to a project, higher-precedence layers winning."
  @spec resolve_all(Project.t()) :: [Resolved.t()]
  def resolve_all(%Project{} = project), do: Resolver.resolve_all(project)

  @doc "All discovered command packs (`<id>@<version>`)."
  @spec list_packs() :: [Pack.t()]
  def list_packs, do: Pack.list()

  @doc "All versions of a pack id, newest first."
  @spec pack_versions(String.t()) :: [String.t()]
  def pack_versions(id), do: Pack.versions(id)

  @doc """
  Seed the slash commands an ADW needs into the target project's `.claude/commands/`,
  so the portable Python ADW harness + SDK resolve them (see `Commands.Provisioner`).
  Idempotent, repo-owned files win, fail-soft.
  """
  @spec provision_adw_commands(Project.t(), Adw.t()) :: {:ok, [String.t()]} | {:error, term()}
  def provision_adw_commands(%Project{} = project, %Adw{} = adw),
    do: Provisioner.provision_for_adw(project, adw)
end
