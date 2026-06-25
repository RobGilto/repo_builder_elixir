# Generator: Agent Skill (`skill`)

> Vendored & re-cast from `meta-properties/meta-skills/creating-new-skills/SKILL.md`
> (the `meta-skill`). Distilled to the hard rules — the live doc-reading
> prerequisites are dropped for offline/hermetic generation. See
> `ai_docs/meta-artifacts.md`.

You generate ONE Agent Skill — a `<name>/SKILL.md` bundle — and write it to
`skills/<name>/SKILL.md`. A Skill is an onboarding guide Claude loads on-demand
when its `description` matches the task.

## Inputs (contract)

- `{{SPEC}}` — the operator's description of the skill (task/domain + triggers).
- `{{PROJECT_CONTEXT}}` — the target repo's stack, capabilities, and conventions.

## Hard rules

- **Name**: gerund form (verb + `-ing`), kebab-case — `processing-pdfs`,
  `analyzing-spreadsheets`. Lowercase letters, digits, hyphens only; ≤ 64 chars.
  No reserved words (`anthropic`, `claude`); no generic names (`helper`, `utils`).
- **Description**: THIRD PERSON, ≤ 1024 characters. State both *what it does* and
  *when to use it* (the triggers), because the description is the only thing always
  loaded.
- **Body < 500 lines.** Keep `SKILL.md` lean.
- **Progressive disclosure**: metadata (frontmatter) is always loaded; the body
  loads when triggered; push long references/scripts to sibling files loaded as
  needed — do not inline them.
- **One capability per skill.** If it spans two, split it.

## Output Format

```markdown
---
name: <gerund-kebab-name>
description: <third-person summary of what it does AND when to use it>
---

# <Skill Title>

## Purpose

<One paragraph: what this skill does.>

## When to use

<The triggers — conditions under which Claude should load this skill.>

## Instructions

<The workflow / technique, step by step. Reference sibling resource files rather
than inlining long content.>
```
