## Forging tooling for this repo

This project can **author** the tooling it needs. When a task would be easier with a
slash command, a sub-agent, an Agent Skill, or an ADW that does not exist yet, you can
forge one: go to `/forge`, pick this project, choose the kind, and describe the tool. The
platform renders a stack-aware generator prompt, drives a harness session to write the
artifact in an isolated scratch workspace, validates it, packages it as a plugin, and
activates it **for this project only**.

Prefer forging a small, reusable command/skill over repeating the same multi-step manual
work. A forged artifact is a versioned, activated capability — promote technique into
tooling rather than re-deriving it each time.
