# Conditional Documentation Router

> Read during the **research** phase of planning (`feature`/`bug`/`chore`) and at
> `prime` time. This is a triage map: load a heavy reference doc **only when** the
> task matches its condition, so context stays lean. Match every row that applies
> and add the listed docs to your plan's `Relevant Files`.

## How to use

1. Read the task (issue title/body or the user's request).
2. For each row below, decide if the **Condition** applies.
3. For every matching row, read the listed docs and cite them in the plan.
4. The **always** row applies to every implementation task.

## Routing table

| Condition — your task involves… | Read these docs |
|---|---|
| **(always)** writing or changing any public function, struct, schema, or behaviour | `ai_docs/typed-elixir-standard.md` — the typed coding standard (enforced; see `.credo.exs` + `mix dialyzer`) |
| Architecture, milestones, or any cross-cutting design question | `BUILD_PROMPT.md` (the authoritative spec) |
| Harness adapters, event normalization, or the canonical event contract | `BUILD_PROMPT.md` §4 (event contract) + §10 (extensibility); `ai_docs/typed-elixir-standard.md` (rule 6, wire vs domain) |
| The session runtime, erlexec/muontrap, OS-process lifecycle, or orphan reaping | `BUILD_PROMPT.md` §6; `ai_docs/adw-primitives.md` |
| The workflow/ADW engine, step state machine, or run resumption | `BUILD_PROMPT.md` §7; `ai_docs/adw-orchestration.md` |
| Oban — workers, queues, cron, webhooks, durable triggers, idempotency | `BUILD_PROMPT.md` §7 (durable split) + §13 (Oban testing); `ai_docs/adw-orchestration.md` |
| Ecto schemas, migrations, contexts, JSONB, Enum, or the cost float→Decimal boundary | `BUILD_PROMPT.md` §8; `ai_docs/typed-elixir-standard.md` (rule 10) |
| The LiveView dashboard, streams, swimlanes, `assign_async`, or reconnect handling | `BUILD_PROMPT.md` §9; `AGENTS.md` (Phoenix v1.8 + LiveView guidelines) |
| Adding or swapping a harness/provider | `BUILD_PROMPT.md` §10 (add a harness = one module + config) |
| Plugins, the plugin store/library, manifest/contributions, install or activation lifecycle, or the `agentic_plugins/` dir | `ai_docs/plugin-authoring.md` (the authoring reference) + `BUILD_PROMPT.md` §10 (the open-identity/closed-contract doctrine it generalizes) |
| Forging tooling / generating plugins (the `RepoBuilder.Forge` subsystem, generators, the `:skill` kind, per-project specialization) | `ai_docs/meta-artifacts.md` (the doctrine + generator catalog) + `ai_docs/plugin-authoring.md` (the packaging boundary) |
| The quality gate — the per-phase five-stage green gate (format·lint·type·test·mutation), the `:quality_gate` kind, gate descriptors, `run_quality_gate`, `typed_enforcement`, or adding a stack gate | `ai_docs/quality-gate-plugins.md` (authoring a gate for a stack) + `ai_docs/typed-elixir-standard.md` (the standard it generalizes) |
| Secrets, credential sourcing, or `raw` redaction | `BUILD_PROMPT.md` §4.1 (redaction) + §6 (secrets); `ai_docs/secrets-vault.md` (the per-project encrypted vault + name-only orchestrator exposure + threat model) |
| Tests, Mox, the FakeHarness, normalizer property tests, or crash-isolation tests | `BUILD_PROMPT.md` §13; `ai_docs/typed-elixir-standard.md` (Enforcement) |
| Anything touching the existing Python ADW scripts | `adws/README.md` (scripts are Astral `uv` single-file Python) |
| planf3 HTML plans — authoring (`/planf3`), executing/updating a `specs/*.html` plan, the placeholder-image library, or `PLANF3_IMAGES`/`ADW_PLAN_COMMAND` | `.claude/commands/planf3.md` (the planner command) + `ai_docs/planf3/` (lifecycle workflows) + `specs/planf3-html-plans-for-heavy-adw-planner.html` (the incorporation spec) |

## Human-facing docs (`docs/`)

`docs/` holds **prose written for people**, not machine-routed reference material —
read these when you want the *why* and the *reasoning* behind the practices above,
or when onboarding/reflecting rather than implementing.

| Read when… | Doc |
|---|---|
| You want the rationale behind the typed standard, the green gate, and the functional style — the abstracted principles, not the rules themselves | `docs/engineering-principles.md` — reflection on why typed + functional + gate-enforced development works; transferable principles. The enforceable *rules* still live in `ai_docs/typed-elixir-standard.md`. |

## Notes

- When in doubt, the **(always)** row plus `BUILD_PROMPT.md` is the safe minimum.
- Runtime verification for any of the above is available via **Tidewave** MCP
  (`http://localhost:4000/tidewave/mcp`): `project_eval`, `execute_sql_query`,
  `get_logs`, `get_docs`, `get_source_location`, `get_ecto_schemas`.
