---
command: prime
version: 1.0.0
---

# Prime
> Execute the following sections to understand the codebase then summarize your understanding.

## Run
git ls-files

## Read
BUILD_PROMPT.md - the authoritative architecture/spec for this Elixir/Phoenix orchestration platform (tech stack, typed style guide, harness event contract, supervision tree, session runtime, workflow engine, persistence, LiveView dashboard, extensibility, milestones, testing).
README.md
AGENTS.md - agent/contributor conventions for this repo (if present).
mix.exs - dependency pins, Dialyzer config, and mix aliases.
adws/README.md
.claude/commands/conditional_docs.md - if present, a guide for determining which documentation to read based on the upcoming task.

## Note
This is an Elixir/Phoenix/OTP app. Validate with `mix` (`mix compile --warnings-as-errors`, `mix test`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`). Runtime intelligence is available via **Tidewave** (Phoenix MCP at `http://localhost:4000/tidewave/mcp`): `project_eval`, `execute_sql_query`, `get_logs`, `get_docs`, `get_source_location`, `get_ecto_schemas`.
