# Meta-artifacts & the Forge

The platform can **author** the tooling a specialized repo needs — a stack-correct
slash command, a domain sub-agent, an Agent Skill, an ADW workflow — package it as a
valid `agentic.plugin/1`, and activate it **for that project only**. This subsystem is
`RepoBuilder.Forge`.

## Doctrine: open identity, closed contract

The Forge folds an external workshop — `/data/1.Projects/meta-properties/` — into the
platform. That workshop's founding rules are the *same* open-identity / closed-contract
seam the platform already runs for harnesses and plugins:

| meta-properties rule | repo_builder analog |
|---|---|
| One artifact, one folder. | One plugin = one package. |
| Inputs/outputs are contracts. | The `agentic.plugin/1` wire→domain boundary (`Plugins.Manifest.parse/1`) + the per-kind `Forge.Validator`. |
| Promote, don't accumulate. | A technique → a generated plugin → an activated, versioned capability; lineage recorded in `forge_artifacts`. |

So generating a plugin is just another deterministic ADW: render a generator prompt,
drive a real harness session to write the artifact, validate it, package it, and hand it
to the existing install → activate-per-project lifecycle.

## The generator catalog

Distilled, capability-token-aware copies of the upstream meta-artifacts live in-tree at
`priv/forge/generators/`. Each is keyed by a `Forge.Generator` kind and targets a
`Plugins.Contribution` kind:

| Generator kind | Template | meta-properties source | Contribution kind | Produces |
|---|---|---|---|---|
| `:command` | `priv/forge/generators/command.md` | `meta-prompts/slash-command-generator` | `:command_pack` | `.claude/commands/<name>.md` |
| `:agent` | `priv/forge/generators/agent.md` | `meta-agents/subagent-generator/AGENT-strict.md` | `:agent_template` | `.claude/agents/<name>.md` |
| `:skill` | `priv/forge/generators/skill.md` | `meta-skills/creating-new-skills` | `:skill` | `skills/<name>/SKILL.md` |
| `:workflow` | `priv/forge/generators/workflow.md` | (composed) | `:workflow_type` | `workflows/<slug>.json` |

Every template carries a `{{PROJECT_CONTEXT}}` slot, filled at render time from
`Projects.ContextPrimer` so generated tooling fits the target repo's stack.

## Provenance

- **Source repo**: `/data/1.Projects/meta-properties/` (the `meta-prompts`,
  `meta-agents`, and `meta-skills` workshops).
- **Sweep date**: 2026-06-25.
- The templates are a *distilled* vendor copy (re-cast to be capability-token aware and
  hermetic), not a verbatim mirror. Revisit if the upstream generator set grows or churns.

## Demo: forge a command, activate it, resolve it

The whole loop, end to end (the `/forge` UI does this with a human in the loop). The
`generate_runner` here stands in for a real harness writing the artifact; in production it
is a real `Session`:

```elixir
{:ok, project} = RepoBuilder.Projects.create_project(%{name: "demo", root_path: "/tmp/demo"})
{:ok, artifact} = RepoBuilder.Forge.request(%{kind: "command", spec: "a /smoke-test command", project_id: project.id})

# A canned generate runner (the seam the Fake-backed CI path uses):
runner = fn %{scratch_dir: dir} ->
  file = Path.join([dir, "commands", "smoke-test.md"])
  File.mkdir_p!(Path.dirname(file))
  File.write!(file, "---\ndescription: Runs the smoke test.\n---\n\n# Smoke Test\n\n## Purpose\n## Workflow\n## Report\n")
  {:ok, [%{path: "commands/smoke-test.md", content: File.read!(file)}]}
end

{:ok, %{status: :installed, plugin_id: id}} = RepoBuilder.Forge.Workflow.run(artifact, generate_runner: runner)
RepoBuilder.Plugins.active?(project.id, id)        #=> true  (this repo only)
RepoBuilder.Plugins.active?(Ecto.UUID.generate(), id) #=> false
```

The bundled `plugin_library/forge-meta/` proves the same path without a generator: it
ships a `context_fragment` (how to forge) + a sample `command_pack`, installable via
`RepoBuilder.Plugins.Installer.install("library", "forge-meta")`.

## The `:skill` contribution kind

Skills are the one genuinely new extension point this work adds. An Agent Skill
(`SKILL.md` bundle) is structurally distinct from a command pack or an agent template, so
it earns its own kind in the closed `Plugins.Contribution` union — the doctrine's
sanctioned "adding a kind is a deliberate core edit." The asset is a `skills/` directory
of `<name>/SKILL.md` bundles; `Plugins.SkillPack` materializes the active skills into the
project's `.claude/skills/`.
