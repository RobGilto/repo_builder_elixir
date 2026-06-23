# Agentic Layer Adaptor

The platform is a deterministic, harness-blind orchestration core that adapts to **any**
target repository. This doc describes the adaptor seam and the command-pack authoring
guide. It deliberately extends existing seams — it does not touch the canonical `Event`
sum type, the registry, or the session-runtime contract.

## The Project seam

A target repo is a first-class `RepoBuilder.Projects.Project`:

```
{name, root_path, git_remote, default_branch, stack, capabilities,
 command_pack, command_pack_version, default_harness, default_model_tier,
 budget_cap_usd, isolation_mode, context_primer, status}
```

Everything else scopes to a project through a **nullable** `project_id` FK on `agents`,
`workflow_runs`, and `plans`. `nil` = "the platform itself" — today's behaviour. The
seeded default project (`priv/repo/seeds.exs`) gives legacy global rows a logical home.

- `RepoBuilder.Projects` — the only `Repo` caller for `projects`. `create_and_profile/1`
  registers + profiles in one step; `refresh_profile/1` re-profiles.
- `RepoBuilder.Projects.Profiler` — fail-silent repo profiler: git metadata, stack
  heuristics, discovered `.claude/commands`/`AGENTS.md`/ADWs, and a capability map.
- `RepoBuilder.Projects.Capabilities` — the typed per-stack capability map (the small
  values that vary by language) with per-stack defaults and operator overrides.
- `RepoBuilder.Projects.ContextPrimer` — renders the profile into the orchestrator
  system-prompt block (`orchestrator/system_prompt.ex` injects it for the active project).

## Command resolution (the three layers)

The "every command assumes one toolchain" problem is solved by separating *what varies*
from *what's written once*:

| Layer | Holds | Varies per | Extends |
|-------|-------|-----------|---------|
| Capability map | test/build/lint/format/typecheck/run commands, package manager, dirs | stack | `Profiler` → `project.capabilities` |
| Command packs | versioned dirs of command `.md` bodies | stack *and* version | `priv/command_packs` |
| Resolver | precedence walk + token fill + provenance | active project | `SlashExpander`, `TokenRegistry`, `Builder.render/2` |

Resolution precedence for a command name (first match wins), via
`RepoBuilder.Commands.Resolver.resolve/2`:

```
1. <project.root>/.claude/commands/<name>.md      # the target repo wins (adaptor principle)
2. priv/command_packs/<pinned_pack>/<pinned_version>/commands/<name>.md
3. priv/command_packs/<detected_stack>/<latest>/commands/<name>.md
4. priv/command_packs/generic/<latest>/commands/<name>.md
   └─ then fill {{TEST_COMMAND}} … from project.capabilities, attach provenance
```

Repo-local bodies are returned verbatim (the repo knows itself); pack bodies get the
capability tokens filled. The result is a `RepoBuilder.Commands.Resolved`
(`{body, layer, pack, version, provenance}`).

## Capability tokens (the anti-duplication core)

The closed set lives in `RepoBuilder.PromptStandard.TokenRegistry.capability_tokens/0`:

```
{{TEST_COMMAND}} {{BUILD_COMMAND}} {{LINT_COMMAND}} {{FORMAT_COMMAND}}
{{TYPECHECK_COMMAND}} {{RUN_COMMAND}} {{PACKAGE_MANAGER}}
{{SPEC_DIR}} {{SOURCE_DIRS}} {{TEST_DIR}}
```

A single token-templated command body in the `generic` pack works across every stack
that supplies these values — **no per-language copy needed for the common case**.

## Command-pack authoring guide

A pack is `priv/command_packs/<pack>/<version>/commands/**/*.md`. Built-in packs ship in
`priv/command_packs/`; operator packs live in a configurable dir
(`config :repo_builder, :command_packs, operator_dir: "…"`).

1. **Pick the pack id.** `generic` is the token-templated base. Stack packs (`elixir`,
   `python-uv`, `node`, `rust`, `go`) override only the commands whose prose genuinely
   diverges from the generic body. The `"auto"` pin resolves the pack from the project's
   detected stack (`Commands.Pack.stack_pack_id/1`).
2. **Version it.** Directory names are versions; `"latest"` resolves to the newest
   (semver-aware, e.g. `1.0.0`). A project pins `{command_pack, command_pack_version}` so
   evolving a pack never silently changes a pinned project's behaviour.
3. **Write the command file.** Each `<name>.md` has YAML frontmatter (`description`,
   optional `argument-hint`) and a body. Use capability tokens for anything that varies by
   stack; use `$ARGUMENTS`/`$1`…`$N` for invocation arguments. A `:`-namespaced command
   name maps to nested dirs (`experts:ws:q` → `commands/experts/ws/q.md`).
4. **Add a new stack** in three steps: (a) add detection markers in
   `Projects.Profiler` + defaults in `Projects.Capabilities`; (b) map the language to a
   pack id in `Commands.Pack.stack_pack_id/1`; (c) — usually nothing else, because the
   `generic` pack's token-templated bodies already work. Add a stack pack only for the
   commands whose prose truly differs.

## Worktree isolation

`RepoBuilder.Projects.Worktree.checkout/2` provisions
`git worktree add <scratch>/<run_id> -b adw/<run_id> <base>` when a project's
`isolation_mode` is `:worktree`; the session runtime (`session/server.ex`) honours
`opts[:isolation_mode]` and cleans up via `git worktree remove` (the branch survives for
the PR handoff, recorded on the `workflow_run`). A non-git repo or any git failure falls
through to the direct cwd, so `:direct` (the default) is always safe.

## Planning-Mode Wizard

`RepoBuilder.Plans.Planner.resolve/1` is pure (no side effects, no model call): it turns
`{project, goal, workflow_type}` into a previewable, costed plan — stack-correct step
previews via the resolver, a context estimate via `Orchestrator.ContextWindow`, and a
deterministic cost band. `PlanningLive` (`/plan`) walks the operator through it and, on
confirm, persists a durable `RepoBuilder.Plans.Plan` and launches the run via the existing
`WorkflowEngine` path, scoped to the project.
