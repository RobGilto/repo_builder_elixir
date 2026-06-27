defmodule RepoBuilder.Commands.Provisioner do
  @moduledoc """
  Closes the ADW command-resolution gap (issue-adw-portable-commands). The portable
  Python ADW harness (`adws/adw_modules/adw_runner.py`) and the `claude-agent-sdk`
  (`setting_sources=["project"]`) both resolve slash commands ONLY from
  `<cwd>/.claude/commands/<name>.md` — so a fresh "foster" repo that ships none fails
  its pre-flight before step 1. The Elixir orchestrator already knows how to resolve
  those commands for *any* repo via `Commands.Resolver` (repo-local → plugin → pinned →
  stack → generic, with capability-token fill); this module is the thin WRITER that
  materializes that resolved set into the target repo's `.claude/commands/` at launch
  time, so the Python pre-flight and the SDK both find the files.

  Doctrine, mirroring the resolver's precedence:

    * **Idempotent** — only writes a command file when one does not already exist.
    * **Repo-owned files always win** — a repo that ships its own `<name>.md` is never
      clobbered (and never appears in the provisioned list).
    * **Fail-soft** — never raises; a provisioning miss degrades to the existing loud
      Python pre-flight error rather than crashing the launch. Only a hard IO failure
      (e.g. an unwritable target dir) returns `{:error, _}`.

  Each provisioned file carries a `provisioned_by: repo_builder` frontmatter marker so
  it is distinguishable from a hand-authored repo command (and a future refresh/cleanup
  can target only platform-seeded files). The file shape round-trips cleanly through
  `Orchestrator.Template.from_markdown/1`, so a later run re-reads it as a repo-local
  command without surprise.
  """
  alias RepoBuilder.Commands.{Resolved, Resolver}
  alias RepoBuilder.Definitions.Adw
  alias RepoBuilder.Projects.Project

  # The ADW step set the generic pack always satisfies — the safe fallback when a script
  # is unreadable or declares no slash commands.
  @standard_commands ~w(plan build review test fix)

  # Matches a quoted slash command in an ADW script — both the portable
  # `Step("plan", "/plan")` form and the `*_iso.py` `slash_command="/test"` form. The
  # optional `(?:\s[^"]*)?` drops an arg suffix (`"/scout architecture"` → `scout`),
  # mirroring `adw_runner.command_name/1`.
  @slash_command_regex ~r/"\/([a-z][a-z0-9_]*)(?:\s[^"]*)?"/

  @doc """
  Resolve + provision the command set an `adw` needs into the project's repo. Composes
  `required_commands/1` with `provision/2`.
  """
  @spec provision_for_adw(Project.t(), Adw.t()) :: {:ok, [String.t()]} | {:error, term()}
  def provision_for_adw(%Project{} = project, %Adw{} = adw) do
    provision(project, required_commands(adw))
  end

  @doc """
  Provision the named commands into `<project.root_path>/.claude/commands/`, returning
  the names actually written (existing repo-owned files are skipped and excluded).

  Reserves `{:error, _}` for a hard IO failure (e.g. an unwritable target dir); an
  individual command that fails to resolve or write is skipped, never fatal.
  """
  @spec provision(Project.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def provision(%Project{root_path: root} = project, names)
      when is_binary(root) and is_list(names) do
    dir = Path.join([root, ".claude", "commands"])

    with :ok <- File.mkdir_p(dir) do
      provisioned =
        names
        |> Enum.map(&strip_slash/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.flat_map(&provision_one(project, dir, &1))

      {:ok, provisioned}
    end
  rescue
    error -> {:error, error}
  end

  def provision(%Project{}, _names), do: {:error, :no_root_path}

  @doc """
  The slash-command names an ADW declares, in first-seen order, de-duplicated and
  slash-stripped — parsed from the script at `adw.path`. Falls back to the standard
  `plan/build/review/test/fix` set when the script is unreadable or declares none (the
  generic pack guarantees those resolve).
  """
  @spec required_commands(Adw.t()) :: [String.t()]
  def required_commands(%Adw{path: path}) do
    with {:ok, source} <- File.read(path),
         [_ | _] = commands <- extract_commands(source) do
      commands
    else
      _ -> @standard_commands
    end
  end

  # Write one command if absent; return [name] when written, [] when skipped/unresolved.
  @spec provision_one(Project.t(), String.t(), String.t()) :: [String.t()]
  defp provision_one(project, dir, name) do
    path = Path.join(dir, name <> ".md")

    # `File.regular?` → repo owns this command; never clobber (resolver's repo-local win).
    with false <- File.regular?(path),
         {:ok, %Resolved{} = resolved} <- Resolver.resolve(project, name),
         :ok <- File.write(path, render(resolved)) do
      [name]
    else
      _ -> []
    end
  end

  # A valid command file: a provenance-bearing frontmatter block + the resolved body. The
  # comment is for humans; `provisioned_by` is the machine-readable cleanup marker.
  @spec render(Resolved.t()) :: String.t()
  defp render(%Resolved{} = resolved) do
    """
    ---
    # provisioned-by: repo_builder (layer: #{resolved.layer}, pack: #{resolved.pack || "none"}) — safe to edit or delete
    provisioned_by: repo_builder
    ---

    #{resolved.body}
    """
  end

  @spec extract_commands(String.t()) :: [String.t()]
  defp extract_commands(source) do
    @slash_command_regex
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  @spec strip_slash(String.t()) :: String.t()
  defp strip_slash(name) when is_binary(name),
    do: name |> String.trim() |> String.trim_leading("/")
end
