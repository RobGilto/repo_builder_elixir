# Generator: slash command (`command_pack`)

> Vendored & re-cast from `meta-properties/meta-prompts/slash-command-generator`
> (the `meta-prompt`). Distilled to the 6-section command anatomy and made
> **capability-token aware** so generated commands are stack-portable rather than
> wired to one toolchain. See `ai_docs/meta-artifacts.md` for the doctrine.

You generate ONE custom slash command and write it to the package-relative path
`commands/<name>.md` (the platform activates it into the project's
`.claude/commands/` on install). The file is invoked by an operator as
`/<name>`. Follow the anatomy EXACTLY: real YAML frontmatter, then the six
sections below, nothing more.

## Inputs (contract)

- `{{SPEC}}` — the operator's natural-language description of the command to build.
- `{{PROJECT_CONTEXT}}` — the detected stack, capabilities, and conventions of the
  target repo (rendered from `Projects.ContextPrimer`). Condition every choice on this.

## Capability tokens (stack portability)

Do NOT hard-wire a toolchain. When the command needs a project capability, reference
it through a capability token so the same command works across stacks:

- `{{TEST_COMMAND}}` — the project's test command (e.g. `mix test`, `npm test`).
- `{{SPEC_DIR}}` — where the project keeps specs/plans.

Resolve tokens from `{{PROJECT_CONTEXT}}`; if a capability is genuinely absent, omit
the step rather than inventing a command for a stack the repo does not use.

## Output Format

Generate the file content EXACTLY as below. The frontmatter is REAL YAML between
`---` delimiters (NOT inside a code block).

```markdown
---
description: <one-line, third-person description for the /help menu>
argument-hint: [arg-1] [arg-2]
allowed-tools: Read, Write, Edit, Bash
---

# <Command Title>

## Purpose

<1–3 sentences: what the command does and why it exists.>

## Variables

<Dynamic args ($1, $2, $ARGUMENTS) and static config values.>

## Codebase Structure

<Optional — only the directories this command touches.>

## Instructions

- <Rule / constraint Claude must follow.>
- <Reference capability tokens, never hard-wired toolchains.>

## Workflow

1. <First action.>
2. <Continue as needed.>
3. Now follow the `Report` section to report the completed work.

## Report

<Exact output format: markdown structure + what to include.>
```

## Rules

- The `description` MUST be third person and ≤ 1024 characters.
- The command `<name>` MUST be kebab-case (lowercase letters, digits, hyphens).
- Keep the body focused — one command, one capability.
- `allowed-tools` only when restricting access; otherwise omit it.
