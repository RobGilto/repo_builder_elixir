# Generator: ADW workflow type (`workflow_type`)

> A native generator (no single upstream artifact): emit a data-defined ADW that
> the platform's deterministic `WorkflowEngine` can run. See
> `ai_docs/meta-artifacts.md` and `ai_docs/plugin-authoring.md`.

You generate ONE workflow-type JSON file and write it to
`workflows/<slug>.json`. It defines a fixed-shape ADW: a list of named steps,
each driving a harness session, wired by deterministic edges.

## Inputs (contract)

- `{{SPEC}}` — the operator's description of the workflow (the phases it should run).
- `{{PROJECT_CONTEXT}}` — the target repo's stack, capabilities, and conventions.

## Output Format

Emit a single JSON object matching the shape `WorkflowEngine.Step` consumes:

```json
{
  "slug": "<kebab-slug>",
  "label": "<Human Label>",
  "description": "<one line, third person>",
  "steps": [
    {
      "name": "plan",
      "prompt_template": "Plan the work for: {{input}}",
      "on_success": "build",
      "on_failure": "abort"
    },
    {
      "name": "build",
      "prompt_template": "Build from the plan: {{plan}}",
      "on_success": "done",
      "on_failure": "abort"
    }
  ]
}
```

## Rules

- `slug` MUST be kebab-case; `description` third person.
- Each step's `on_success`/`on_failure` edge MUST be `done`, `abort`, or the
  `name` of a SIBLING step (no dangling targets).
- A step's `prompt_template` references prior step outputs via `{{step_name}}`
  and the run input via `{{input}}`.
- `harness` is OPTIONAL per step — omit it to inherit the run's harness.
- The first step in `steps` is the entry point.
