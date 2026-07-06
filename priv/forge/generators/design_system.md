# Generator: Design System (`design_system`)

> A native generator (no single upstream artifact): emit a stack-aware design-system
> descriptor the platform resolves per project and injects into every UI worker's charter.
> See `ai_docs/design-system-plugins.md` and `ai_docs/meta-artifacts.md`.

You generate ONE design-system JSON file and write it to
`design/<surface>-<framework>.json` (e.g. `design/web-phoenix.json`,
`design/tui-bubbletea.json`). It captures the target repo's REAL component vocabulary +
design tokens so agents build UI from a known system instead of regressing to generic
markup.

## Inputs (contract)

- `{{SPEC}}` — the operator's description of the design system (surface, framework,
  which component library / tokens to enumerate).
- `{{PROJECT_CONTEXT}}` — the target repo's stack, capabilities, and conventions.

## What to do

1. From `{{PROJECT_CONTEXT}}` determine the UI **surface** (`web` or `tui`) and the
   **framework** (Phoenix, React, Ink, Bubble Tea, Ratatui, Textual, Ratatouille, …).
2. Read the repo's actual UI code (its component module(s), theme/token files) and
   enumerate the components that already exist — prefer the repo's own names/tags over
   invented ones.
3. Emit the descriptor. Reference the anti-slop rubric rather than restating it.

## Output Format

Emit a single JSON object matching the shape `RepoBuilder.Plugins.DesignSystem` consumes:

```json
{
  "surface": "web",
  "stack": "elixir",
  "framework": "phoenix",
  "paradigm": "none",
  "tokens": {
    "accent": "one accent; never a purple gradient default",
    "spacing": "4/8px grid",
    "type_scale": "~1.25, cap 4 sizes"
  },
  "components": [
    {
      "name": "input",
      "tag": "<.input>",
      "package": "core_components",
      "when_to_use": "every form field",
      "example": "<.input field={@form[:email]} type=\"email\" />"
    }
  ],
  "rules": [
    "Reach for an existing component tag before hand-rolling markup.",
    "Follow the ui-ux-foundations rubric; reject the AI-slop tells."
  ],
  "references": [
    "lib/repo_builder_web/components/core_components.ex",
    "plugin_library/ui-ux-mvp/skills/ui-ux-foundations/SKILL.md"
  ]
}
```

## Rules

- `surface` MUST be `web`, `tui`, or `any`; `stack` and `framework` are required strings.
- `paradigm` MUST be `immediate`, `mvu`, `retained`, or `none`. For a TUI it is
  load-bearing — it tells the agent how much scaffolding a full app needs (immediate-mode
  = full hand-written loop; mvu = Model/Init/Update/View; retained ≈ none). Use `none` for
  web/prompt surfaces.
- Each `components[]` entry MUST carry a `name`; `tag`/`package`/`when_to_use`/`example`
  are optional but strongly preferred — they are what a worker copies.
- `rules[]` encode the do/don't + the per-framework code-gen rules AND the dead-dep bias
  (never scaffold blessed/npyscreen/tui-rs). Keep them short and imperative.
- Point `references[]` at the repo's real component module + the `ui-ux-mvp` skills; do not
  duplicate their prose into `rules`.
- Emit ONLY the JSON file — no prose around it.
