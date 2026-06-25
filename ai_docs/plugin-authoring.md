# Plugin Authoring Reference (`agentic.plugin/1`)

> The reference for building plugins for `repo_builder_elixir`. A **plugin** is a
> versioned package that *contributes* to a **closed set of extension points**.
> Plugins are authored in the local **folder library** (`plugin_library/`),
> distributed through a **store**, **installed live** into `agentic_plugins/`, and
> **activated per project** — switching the orchestrator's bound project recomputes
> the effective behaviour set.
>
> Design doctrine: this generalizes BUILD_PROMPT.md §10's harness seam — **open
> identity (the plugin `id`), closed contract (the contribution kinds)**. Adding a
> *plugin* is one package, zero core change; adding a *kind* is a deliberate core
> edit.

## Package layout

```
<plugin-id>/
  plugin.json                  # the manifest (REQUIRED, schema "agentic.plugin/1")
  commands/                    # :command_pack — capability-tokenized *.md bodies
    feature.md
  workflows/                   # :workflow_type — ADW definitions as data
    my_sdlc.json
  agents/                      # :agent_template — markdown-with-frontmatter templates
    my_reviewer/0001.md
  skills/                      # :skill — Agent Skill bundles (<name>/SKILL.md)
    processing-invoices/SKILL.md
  context/                     # :context_fragment — system-prompt markdown
    primer.md
  capabilities/                # :capability — stack markers + capability defaults
    rules.json
  lib/                         # OPTIONAL :harness_adapter etc. — BEAM modules (code layer)
    my_harness.ex
  README.md
```

The manifest filename is always `plugin.json`. Assets are referenced by **relative
path** from the package root.

## The manifest

```json
{
  "schema": "agentic.plugin/1",
  "id": "elixir-phoenix-way",
  "name": "Elixir / Phoenix Way",
  "version": "1.0.0",
  "description": "Phoenix-flavoured ADWs, commands, and review agents.",
  "author": "your-handle",
  "compat":  { "platform": ">= 3.0.0" },
  "requires": { "capabilities": ["test_command"] },
  "contributions": [
    { "kind": "command_pack",    "path": "commands" },
    { "kind": "workflow_type",   "path": "workflows/phoenix_sdlc.json" },
    { "kind": "agent_template",  "path": "agents" },
    { "kind": "context_fragment","path": "context/phoenix.md" },
    { "kind": "capability",      "path": "capabilities/elixir.json" }
  ],
  "code": { "modules": ["lib/my_harness.ex"], "on_load": "MyHarness.Plugin" },
  "checksum": "sha256:…"
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | ✓ | Open string identity (kebab-case). Unique per install. |
| `name` | ✓ | Human label. |
| `version` | ✓ | **Semver** (validated). |
| `description` / `author` | | Free text. |
| `compat.platform` | | Version requirement checked against the running `:repo_builder` vsn. |
| `requires` | | Advisory capability/dep requirements. |
| `contributions` | | List of `{kind, path, …}`. Unknown kinds are rejected. |
| `code` | | Optional code layer — see **Code plugins**. |
| `checksum` | | `sha256:<hex>` of the package, verified on install when trust requires it. |

Parsing is a strict wire→domain boundary (`RepoBuilder.Plugins.Manifest.parse/1`):
malformed JSON, an unknown contribution kind, a missing required field, or a bad
semver all return a tagged error and never crash.

## Contribution kinds (the closed contract)

| Kind | Asset | Wires into | Effect when the plugin is active for a project |
|---|---|---|---|
| `command_pack` | `commands/` dir of `*.md` | `Commands.Resolver` (a `:plugin` precedence layer) | Adds/overrides slash commands; capability tokens (`{{TEST_COMMAND}}` …) are filled per project. |
| `workflow_type` | a `*.json` file | `WorkflowEngine.Catalog` | Adds a launchable ADW type (data-defined steps). |
| `agent_template` | `agents/` dir | `Orchestrator.Templates` / `Definitions` | Adds agent/subagent templates. |
| `skill` | `skills/` dir of `<name>/SKILL.md` | `Plugins.SkillPack` | Materializes Agent Skills into the active project's `.claude/skills/` (forge-meta-artifact-generation). |
| `context_fragment` | a `*.md` file | `Projects.ContextPrimer` | Appends a fragment to the orchestrator system prompt. |
| `capability` | a `*.json` file | `Projects.Profiler` / `Capabilities` | Adds stack markers + per-language command defaults. |
| `harness_adapter` | (code) | `Harness.Registry` overlay | Registers a new harness — see **Code plugins**. |
| `mcp_tools` | a descriptor | per-orchestrator MCP endpoint | **Reserved.** Kind exists so the contract is complete; wiring is follow-on. |

### `workflow_type` data shape

A `workflow_type` JSON file is a single ADW definition. Its `steps` are exactly the
canonical JSONB step shape the engine already hydrates (`WorkflowEngine.Step`):

```json
{
  "slug": "phoenix_sdlc",
  "label": "Phoenix SDLC",
  "description": "Plan → build → test → review, Phoenix-flavoured.",
  "steps": [
    { "name": "plan",  "prompt_template": "Plan: {{input}}", "on_success": "build",  "on_failure": "abort" },
    { "name": "build", "prompt_template": "Build: {{plan}}",  "on_success": "review", "on_failure": "abort" },
    { "name": "review","prompt_template": "Review: {{build}}","on_success": "done",   "on_failure": "abort" }
  ]
}
```

`harness` is optional per step — when omitted, the launching project's default
harness is substituted at resolve time. Edges must be a sibling step name, `done`,
or `abort`.

## Lifecycle

1. **Author** in `plugin_library/<id>/` (or publish to a store).
2. **Install** — `RepoBuilder.Plugins.Installer.install(source_key, id, version)` fetches
   from a source, verifies the manifest + checksum/trust, unpacks into
   `agentic_plugins/<id>@<version>/`, and records a durable `plugins` row.
3. **Activate** — `RepoBuilder.Plugins.activate(project_id, id)` binds the plugin to a
   project (`nil` project = the platform itself). Switching the orchestrator's project
   recomputes the effective contribution set (`RepoBuilder.Plugins.Activation`).
4. **Uninstall** — `Installer.uninstall(id)` deactivates everywhere, removes the dir,
   deletes the row.

Declarative contributions take effect on the next activation resolve (live, zero
recompile). Code contributions take effect on `Loader.reload/0` or a node restart.

## Code plugins (the power layer) and the trust model

A plugin may ship BEAM modules under `lib/` and declare a `code` block. At load the
`RepoBuilder.Plugins.Loader` `Code.require_file/1`s each module then calls the
`on_load/1` of the module named in `code.on_load`, which must implement
`RepoBuilder.Plugins.Code`:

```elixir
defmodule MyHarness.Plugin do
  @behaviour RepoBuilder.Plugins.Code

  @impl true
  def on_load(_ctx) do
    # e.g. register a harness adapter into the runtime overlay
    RepoBuilder.Plugins.HarnessOverlay.put("my-harness", %{
      module: MyHarness.Adapter, exe: "my-cli", default_model: nil, price_table: %{}
    })
    :ok
  end
end
```

The canonical use is a new **harness adapter**: the plugin implements
`RepoBuilder.Harness` (mandatory `command/1` + `normalize/2`, optionally
`CustomSpawn`) and registers itself in the overlay — satisfying the §10 "add a
harness = one module" promise from a *dropped-in plugin*, with zero edits to
`Event`/`Agent`/runtime.

> **Trust boundary — read this.** Code plugins execute arbitrary BEAM code in-node;
> there is no true sandbox on the BEAM. Loading is gated by:
> - `config :repo_builder, :plugins, trust: %{allow_code: …}` — when `false`, code
>   plugins are refused at install/load.
> - mandatory checksum verification (`trust.require_checksum`), with a signature hook
>   reserved (`trust.require_signature`).
> - an explicit operator confirmation in the `/plugins` install UI for code-bearing
>   manifests.
> The remote store NEVER auto-installs a code plugin without confirmation. Plugin
> code must follow the same typed standard as the core (`ai_docs/typed-elixir-standard.md`).

## Typed standard for plugin code

Plugin `lib/` modules are held to the platform's enforced standard: an `@spec` on
every public function (`@impl` callbacks exempt), `typedstruct`/`@enforce_keys` for
domain data, precise types over `any()`/`map()`, tagged-tuple returns over raising,
and never `String.to_atom/1` on untrusted input.
