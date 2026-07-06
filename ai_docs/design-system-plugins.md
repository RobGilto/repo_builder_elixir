# Design System Plugins (`design-system-plugins`)

> How the platform gives agents a **design language they follow every time** — a
> stack-aware component vocabulary + tokens + rules, resolved per the target project's
> detected UI **surface** (web / TUI) and **framework**, injected into every UI worker's
> charter, and pullable on demand via an MCP tool. It closes the "agents produce generic
> UI" gap at its root: the problem is a *missing design system*, not a missing generator.
>
> Structurally this mirrors the quality-gate stack (`ai_docs/quality-gate-plugins.md`):
> resolve a stack-aware descriptor, then serve it to agents. Adding a design system for a
> new framework is **one package, zero core change**; the descriptor kind
> (`:design_system`) is the one deliberate core edit.

## Moving parts

| Responsibility | Module / asset |
|---|---|
| Closed contribution kind | `:design_system` in `RepoBuilder.Plugins.Contribution` |
| Descriptor domain (never-raises wire→domain) | `RepoBuilder.Plugins.DesignSystem` (+ nested `Component`, `Wire`) |
| Resolver (precedence + provenance) | `RepoBuilder.Orchestrator.DesignResolver` |
| Surface/framework detection | `RepoBuilder.Projects.Profiler` (`stack["surface"]` / `stack["framework"]`) |
| Charter injection (compact block) | `RepoBuilder.Orchestrator.DesignContract` → `create_agent/2` + `SystemPrompt` + `ContextPrimer` |
| On-demand full inventory (MCP tool) | `resolve_design_system` — `ToolCatalog` + `Tools` + `Tools.DesignSystem` |
| Builtins | `priv/design_systems/{generic,web-*,tui-*}.json` |
| Distribution | `plugin_library/design-system-*/` sample plugins |

## Resolution precedence

`DesignResolver.resolve/1` walks, first match wins, tagged with its `source`:

1. **plugin** — the highest-priority active `:design_system` contribution
   (`Activation.contributions(project_id, :design_system)`). An active plugin **wins over
   the builtin default**.
2. **builtin** — `priv/design_systems/<surface>-<framework>.json` for the project's
   detected `{surface, framework}` (e.g. `web-phoenix`, `tui-bubbletea`).
3. **tui default** — when the surface is `tui` but no framework matched, the language's
   default TUI framework (the reference's §1 router): `elixir→ratatouille`, `go→bubbletea`,
   `rust→ratatui`, `python→textual`, `node→ink`. TUI has "no single default — pick by
   language".
4. **generic** — `priv/design_systems/generic.json` (framework-agnostic tokens + the
   anti-slop rubric). The `DesignContract` renders `""` for the generic base, so a non-UI
   worker's prompt is byte-identical to today's.

## Descriptor format

A design-system descriptor is a JSON file. `DesignSystem.parse/1` validates it against a
permissive TypeCheck wire type and normalizes it into a strict struct — never raises.

```json
{
  "surface": "web | tui | any",
  "stack": "elixir",
  "framework": "phoenix",
  "paradigm": "immediate | mvu | retained | none",
  "tokens": { "accent": "…", "spacing": "4/8px grid" },
  "components": [
    { "name": "input", "tag": "<.input>", "package": "core_components",
      "when_to_use": "every form field", "example": "<.input field={@form[:email]} />" }
  ],
  "rules": ["Reach for an existing component tag before hand-rolling markup."],
  "references": ["lib/repo_builder_web/components/core_components.ex"]
}
```

- Required: `surface`, `stack`, `framework`. A component requires `name`; `tag`/`package`/
  `when_to_use`/`example` are optional.
- `paradigm` (design-factors §4.1) is load-bearing for TUIs: it tells the agent how much
  scaffolding a full app needs (immediate-mode = full hand-written loop; MVU =
  Model/Init/Update/View; retained ≈ none). `none` for web/prompt surfaces.
- `rules` encode the per-framework code-gen rules and the **dead-dep bias** (never scaffold
  blessed/npyscreen/tui-rs). They lead the worker's charter.

## Adding a design system for a new framework

Parallels the quality-gate "add a stack" recipe:

1. **Builtin** — author `priv/design_systems/<surface>-<framework>.json` (e.g.
   `web-svelte.json`, `tui-textual.json`). Source TUI content from
   `specs/tui-framework-decision-reference.md`.
2. **Resolver key** — add `{surface, framework} => "<name>"` to `DesignResolver.@stack_designs`
   (and, for a new TUI language default, `@tui_defaults`).
3. **Detection** — if the framework isn't yet detected, add a dep marker to
   `Projects.Profiler` (`tui_framework/2` or `web_framework/2`).
4. **(optional) Plugin** — ship it as `plugin_library/design-system-<name>/` declaring a
   `design_system` contribution. An active plugin overrides the builtin — no core edit.
5. **Test** — assert the descriptor parses and the resolver selects it (see
   `test/repo_builder/plugins/design_system_test.exs` and `.../orchestrator/design_resolver_test.exs`).

## Relationship to the `ui-ux-mvp` skills

The `plugin_library/ui-ux-mvp` skills (foundations rubric, anti-slop list, web/desktop/TUI
polish) stay as the **prose/principles** layer. A descriptor's `rules` and `references`
*cite* them — they are not duplicated. The descriptor is the machine-readable,
surface-/framework-specific **vocabulary + tokens + paradigm**; the skills are the
human-readable cross-surface **principles**; the review stage uses both. For Phoenix
specifically, note HEEx ≠ JSX — the design system points at `core_components` + Petal/daisyUI,
not a JSX generator.
