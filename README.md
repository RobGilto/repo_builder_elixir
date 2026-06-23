# repo_builder

`repo_builder` is a harness-agnostic AI agent orchestration platform built on Elixir, Phoenix, and OTP (no Ash). It generalizes the "deterministic orchestration of non-deterministic AI agents" pattern: humans, cron, and webhooks compose **deterministic** workflows (for example `plan -> build -> review -> fix`) whose step order and branching are fixed and **durable** (they survive a node restart), while the intelligent work inside each step is delegated to a **swappable, supervised external AI harness CLI** running as a child process. The defining constraint is that the platform is **not locked to one harness**: Claude Code CLI and the `pi` CLI ship today, and adding a third is one adapter module plus one config entry — proven by an included no-op Cursor adapter, with zero edits to the core.

## Features

- **Harness-agnostic execution** — a two-callback adapter contract (`command/1` + `normalize/2`) behind a single registry seam; Claude, `pi`, Cursor (no-op proof), and a Fake test adapter.
- **Durable, composable workflows** — chained ADWs modeled as state machines whose transitions are persisted before they happen, so in-flight runs resume after a crash or node restart.
- **Real-time LiveView dashboard** — a swimlane view streaming live logs, tool-calls, cost, and status with flat server memory (LiveView streams).
- **Three trigger paths** — interactive (LiveView), scheduled (Oban cron), and signed HMAC webhooks.
- **Supervised session runtime** — one `erlexec`-backed GenServer per live child, with partial-line and multibyte-safe NDJSON buffering, idle timeout, stdout-overflow backpressure, and an admission concurrency gate.
- **Zero-orphan guarantee** — a durable OS-pid ledger plus a boot-time, marker-verified OrphanReaper.
- **Secret-safe persistence** — events are redacted before they hit the database; the live broadcast keeps full detail.
- **Typed-Elixir standard** — `@spec` on every public function, `typedstruct`/`@enforce_keys`, tagged tuples, `--warnings-as-errors`, Credo `--strict`, and Dialyzer, all enforced in CI.

## Architecture

A deterministic core drives non-deterministic agents. Workflows are durable state machines; the intelligence inside each step is an external CLI spoken to over a normalized event stream. There are two execution paths that share the same canonical contract: the **live path** (a `WorkflowEngine.Runner` state machine feeding the LiveView dashboard) and the **durable path** (Oban workers that persist each transition and reconcile in-flight runs after a restart).

The canonical boundary is `RepoBuilder.Harness.Event`: a closed 8-variant `typedstruct` sum type carrying an **open** `harness :: atom()` identity plus a raw escape hatch. Because the identity is open, a new harness needs no change to the event types — only a new adapter and a config entry.

Module map:

- **Harness contract** (`lib/repo_builder/harness*`)
  - `RepoBuilder.Harness` — mandatory `@behaviour` (`command/1` + `normalize/2`)
  - `RepoBuilder.Harness.CustomSpawn` — optional `@behaviour`
  - `RepoBuilder.Harness.Event` — closed 8-variant sum type, open `harness` identity, raw escape hatch
  - `Wire` — TypeCheck `@type!` boundary; `Redact` — secret scrubbing of the persisted raw
  - `Registry` — single source of truth and single test seam
  - Adapters: `Claude`, `Pi`, `Cursor` (no-op proof), `Fake` (test driver)
  - `Pricing` — derives `pi` cost from a price table; `nil` when unpriced (never defaulted to `0.0`)
- **Session runtime** (`lib/repo_builder/session/*`) — `erlexec`-backed GenServer per child, `Admission` concurrency gate, `Session.Supervisor` (`DynamicSupervisor`, `:temporary` children)
- **Zero-orphan ledger** — `lib/repo_builder/os_pid_ledger*` (durable OS-pid ledger) + `lib/repo_builder/orphan_reaper.ex` (boot-time reaper that verifies `/proc/<pid>/environ` before signalling)
- **Persistence** (`lib/repo_builder/*`) — `binary_id` PKs, JSONB, `Ecto.Enum`, an embedded `Usage` value object with a float→Decimal nil-vs-0 cost boundary; contexts (`Agents`, `Logs`, `Prompts`, `Chats`, `Workflows`, `OsPidLedger`) are the only `Repo` callers
- **Workflow engine** (`lib/repo_builder/workflow_engine*`) — `RepoBuilder.WorkflowEngine.Runner` deterministic state machine; `workflow_runs` is the source of truth, persisted before each transition; the seeded `plan -> build -> review -> fix` example ADW
- **Durable triggers** (`lib/repo_builder/workers/*`, `lib/repo_builder/webhooks.ex`) — Oban `StepWorker` (unique on `{workflow_run_id, step_name}`, chains the next step), `CronTrigger`, `WorkflowResume` reconciler, and the HMAC+timestamp-verified `Webhooks` module
- **Web / observability** (`lib/repo_builder_web/*`) — `ConsoleLive` (the full-bleed orchestration console at `/`), `AgentLive`, `DashboardLive` (swimlanes), `WorkflowLive` (`assign_async` cost/status), `SystemLogsLive`, typed `DashboardComponents`/`ConsoleComponents`, `WebhookController` + a raw-body `CacheBodyReader` plug, `Telemetry` + cost/error `Alerting`

## Prerequisites

The toolchain is **project-scoped** via [mise](https://mise.jdx.dev/): the `[tools]` are pinned in `mise.toml` at the repo root and are activated automatically when you enter the project directory. The pinned versions are:

| Tool | Version |
|------|---------|
| Erlang/OTP | `28.4` |
| Elixir | `1.20.1-otp-28` |
| PostgreSQL | `16.14` |

No Node.js version is pinned. PostgreSQL is provisioned as a user-space mise cluster (no `sudo`) via `scripts/pg.sh`, so the `postgres@16.14` tool above supplies the server binaries.

## Installation

PostgreSQL must be running **before** the database steps. The dev and test databases expect superuser `postgres` / password `postgres` on `localhost:5432` (trust auth via the project cluster).

1. **Install and activate the toolchain.** From the repo root, mise reads `mise.toml` and provisions the pinned Erlang, Elixir, and PostgreSQL:
   ```bash
   mise install
   ```

2. **Fetch dependencies:**
   ```bash
   mix deps.get
   ```

3. **Patch `type_check` (required before compiling).** `type_check 0.13.7` references a `Regex` struct field that does not exist on Elixir 1.20; this idempotent script removes the offending line so the project compiles under the pinned Elixir. It only edits the dependency's source — it does **not** compile anything — and must run **after** `mix deps.get` (or `mix deps.clean`) and **before** compilation:
   ```bash
   scripts/patch_deps.sh
   ```

4. **Compile** (recompile the patched `type_check` first, then the project):
   ```bash
   mix deps.compile type_check && mix compile
   ```

5. **Initialize and start the local PostgreSQL cluster** (one-time `init`, then `start`):
   ```bash
   scripts/pg.sh init
   scripts/pg.sh start
   ```

6. **Create, migrate, and seed the database.** The `ecto.setup` alias runs `ecto.create`, `ecto.migrate`, and `priv/repo/seeds.exs`:
   ```bash
   mix ecto.setup
   ```

The `setup` alias chains `deps.get`, `ecto.setup`, `assets.setup`, and `assets.build`:

```bash
mix setup
```

> Note: `mix setup` does **not** run `scripts/patch_deps.sh`. On a fresh checkout, run steps 2–4 first (`mix deps.get` → `scripts/patch_deps.sh` → `mix deps.compile type_check && mix compile`) so `type_check` compiles, then `mix setup` is safe.

Database management aliases:

- `mix ecto.reset` — drop and re-run `ecto.setup`.
- `mix test` — runs `ecto.create --quiet`, `ecto.migrate --quiet`, then `test` (uses a `repo_builder_test<PARTITION>` database; `MIX_TEST_PARTITION` enables partitioning).

## Running the app

### Start

1. Start PostgreSQL (once per session):
   ```bash
   scripts/pg.sh start
   ```
2. Start the Phoenix server:
   ```bash
   mix phx.server
   ```
   Or inside IEx (recommended for driving sessions/workflows from the console): `iex -S mix phx.server`.

The app listens on **http://localhost:4000** by default (override with the `PORT` env var). The root route `/` is the orchestration console.

### Restart

- **Phoenix server:** stop it with `Ctrl+C` twice (or `:init.stop()` / `System.halt()` inside IEx), then re-run `mix phx.server`. There is no daemon to manage — the server runs in the foreground.
- **PostgreSQL** (e.g. after changing cluster config, or if a stale lock blocks startup):
  ```bash
  scripts/pg.sh restart
  ```
  Other cluster commands: `scripts/pg.sh stop`, `scripts/pg.sh status`, and `scripts/pg.sh psql` (open a `psql` shell). The cluster survives between sessions, so a `restart` is only needed when it is actually misbehaving — a plain `start` is the normal per-session step.
- **Full reset of app state** (drop, recreate, migrate, re-seed the dev database; keeps the cluster):
  ```bash
  mix ecto.reset
  ```

### Nuke PostgreSQL and start fresh

Use this when the cluster itself is corrupt or you want a truly clean slate (it deletes **all** databases and cluster state, not just the app's data). `scripts/pg.sh init` is a no-op once a cluster exists, so a real rebuild must delete the data directory first.

**Find the data directory first — don't assume `.pgdata/`.** The script resolves it as `PGDATA="${PGDATA:-$PROJECT_DIR/.pgdata}"`, and the mise `postgres` tool **exports `PGDATA`** when the toolchain is active (typically `~/.local/share/mise/installs/postgres/16.14/data`). So in the normal mise-activated shell the live cluster is at `$PGDATA`, and the project-local `.pgdata/` fallback is used only if `PGDATA` is unset. Always confirm before deleting:

```bash
scripts/pg.sh stop            # stop the server (no-op if already down)
echo "$PGDATA"                # the real cluster location (mise sets this); if blank, it's ./.pgdata
rm -rf "$PGDATA"              # delete the entire cluster (irreversible) — quote it
scripts/pg.sh init            # re-initialize a fresh cluster (postgres / trust auth)
scripts/pg.sh start           # start it
mix ecto.setup                # recreate + migrate + seed the dev database
```

> If `$PGDATA` is unset in your shell, substitute `./.pgdata` for `"$PGDATA"` above. Deleting the wrong path silently does nothing and leaves the old cluster intact (`init` will then report "cluster already initialized").

The test database is created on demand by `mix test` (`ecto.create --quiet`), so it needs no extra step after a nuke.

Routes:

| Method | Path | Target | Notes |
|--------|------|--------|-------|
| LIVE | `/` | `ConsoleLive` | Multi-layered orchestration console (create agents, launch sessions/ADWs, live event stream + swimlanes) |
| LIVE | `/dashboard` | `DashboardLive` | Swimlane dashboard |
| LIVE | `/agents/:id` | `AgentLive` | Single-agent view |
| LIVE | `/workflows/:id` | `WorkflowLive` | Workflow run (async cost/status) |
| LIVE | `/system-logs` | `SystemLogsLive` | System log stream |
| LIVE | `/projects` | `ProjectsLive` | Target-repo registry + per-repo dashboard (agentic-layer adaptor) |
| LIVE | `/plan` | `PlanningLive` | Planning-Mode Wizard → previewed, costed, launched ADW run |
| LIVE | `/plans/:id` | `PlanningLive :show` | A durable, shareable Plan artifact |
| POST | `/webhooks/trigger` | `WebhookController :trigger` | Signed workflow trigger |
| LIVE | `/dev/dashboard` | Phoenix LiveDashboard | **Dev only** (telemetry/metrics) |
| FORWARD | `/dev/mailbox` | `Plug.Swoosh.MailboxPreview` | **Dev only** |

The `/dev/*` routes exist only when `:dev_routes` is enabled (development).

## Agentic layer adaptor

The platform can be pointed at **any** target repository, not just itself. A target repo
is promoted to a first-class **Project** (`RepoBuilder.Projects`) carrying its identity,
auto-detected stack + capability map, a pinned command pack, a budget cap, and an
isolation mode. Everything else scopes to a project via a **nullable** `project_id`
(`nil` = "the platform itself", the back-compatible default).

- **Register a target repo** at `/projects`: paste its absolute path; the `Profiler`
  detects git metadata, the stack (`mix.exs`/`package.json`/`pyproject.toml`/`Cargo.toml`/
  `go.mod`), discovered `.claude/commands`/`AGENTS.md`/ADWs, and a capability map, then
  primes an orchestrator context block.
- **Stack-aware commands**: `RepoBuilder.Commands.Resolver` resolves each `/command` for a
  project through a precedence chain — repo-local `.claude/commands` → pinned pack → stack
  pack → the `generic` base — filling capability tokens (`{{TEST_COMMAND}}` …) so one
  command body adapts to every stack. Versioned packs live in `priv/command_packs/`. See
  `ai_docs/agentic-layer-adaptor.md` for the command-pack authoring guide.
- **Worktree isolation** (opt-in per project, `isolation_mode: :worktree`): each run works
  in `git worktree add <scratch>/<run_id> -b adw/<run_id>` so parallel agents never collide
  and changes land on a reviewable branch. `:direct` (default) preserves today's behaviour.
- **Planning-Mode Wizard** at `/plan`: project → goal → workflow/harness/model/budget →
  stack-correct previewed steps + cost/context estimate → launch, persisting a durable
  Plan artifact (`/plans/:id`).

## Configuration

### Runtime environment variables (`config/runtime.exs`)

| Variable | Scope | Purpose |
|----------|-------|---------|
| `PORT` | all | HTTP port (default `4000`). |
| `PHX_SERVER` | release | Starts the endpoint when running a release. |
| `WEBHOOK_SECRET` | all | HMAC secret for webhook signature verification. When unset, signed triggers are rejected. |
| `ANTHROPIC_API_KEY` | all | Passed to the `claude` and `pi` harnesses. |
| `OPENAI_API_KEY` | all | Passed to the `pi` harness. |
| `FIRECRAWL_API_KEY` | all | One app-wide key for the firecrawl web-research MCP tool. Injected into the child env of workers the orchestrator grants `tools: ["firecrawl"]`; never persisted, never in argv. Requires `npx`/Node on PATH (`npx -y firecrawl-mcp`); the pi path also needs the operator's `pi-mcp-adapter` extension. |
| `DATABASE_URL` | prod | Production database URL (required; raises if missing). |
| `POOL_SIZE` | prod | DB connection pool size (default `10`). |
| `ECTO_IPV6` | prod | Use IPv6 for the DB socket when set to `true` or `1`. |
| `SECRET_KEY_BASE` | prod | Cookie/secret signing key (required; raises if missing). |
| `PHX_HOST` | prod | Endpoint host (default `example.com`). |
| `DNS_CLUSTER_QUERY` | prod | Optional DNS-based clustering query. |

### Harness registry (`config/config.exs`)

| Key | Adapter | Default model | Pricing |
|-----|---------|---------------|---------|
| `claude` | `RepoBuilder.Harness.Claude` | `claude-sonnet-4-6` | none (`%{}`) — cost reported in the stream |
| `pi` | `RepoBuilder.Harness.Pi` | `nil` | `%{"glm-4.6" => 0.6, "glm-4.5-air" => 0.2}` |
| `cursor` | `RepoBuilder.Harness.Cursor` | `nil` | none (`%{}`) — no-op extensibility proof |

### Session limits (`config/config.exs`)

`max_live_sessions: 100`, `max_children: 200`, `idle_ms: 300_000`, `max_line_bytes: 1_048_576`, `workspace_base: "priv/workspaces"`.

### Oban (`config/config.exs`)

- Queues: `default: 10`, `sessions: 20`, `workflows: 10`.
- Crontab: `{"*/5 * * * *", RepoBuilder.Workers.WorkflowResume}` (timezone `Etc/UTC`) — reconciles in-flight runs every 5 minutes.

### Alerting (`config/config.exs`)

- `cost_threshold_usd: 10.0`.

## Triggering a workflow

A workflow run can be started three ways:

1. **Interactively**, via the LiveView UI at `/dashboard` (and the per-workflow view at `/workflows/:id`).
2. **On a schedule**, via the Oban `CronTrigger` worker (the `*/5` crontab also drives `WorkflowResume`, which resumes in-flight runs from their `current_step` after a node restart).
3. **Via a signed webhook**, posted to `POST /webhooks/trigger`.

### Webhook signature scheme

The webhook is authenticated by a **hex-encoded HMAC-SHA256** over the string `"<timestamp>.<raw_body>"`, keyed by `WEBHOOK_SECRET`, plus a timestamp freshness window for replay protection. The signature is sent in the `x-signature` header and the Unix-seconds timestamp in `x-timestamp`. Verification is constant-time, and an invalid, unsigned, or expired request is rejected **before** any Oban job is enqueued (it never becomes a poison job). The raw request body bytes are signed, so the controller verifies against the cached raw body (via the `CacheBodyReader` plug). The JSON body selects the workflow by name with `workflow_name` (the workflow must already exist) and may carry `inputs`.

The signing reference (`RepoBuilder.Webhooks.sign/3`) is:

```elixir
:crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
|> Base.encode16(case: :lower)
```

Example client:

```bash
SECRET="$WEBHOOK_SECRET"
TS=$(date +%s)
BODY='{"workflow_name":"my-adw","inputs":{}}'
SIG=$(printf '%s.%s' "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

curl -X POST http://localhost:4000/webhooks/trigger \
  -H "content-type: application/json" \
  -H "x-timestamp: $TS" \
  -H "x-signature: $SIG" \
  --data "$BODY"
```

## Testing & the green gate

The project enforces a five-command "green gate". Run each verbatim:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test --warnings-as-errors
mix dialyzer
```

The suite has **146 tests** and is driven against the runtime through the `Fake`/Mock adapter via the registry seam, so it needs no external CLIs. Dialyzer runs with a small set of **justified TypeCheck skips** (`.dialyzer_ignore.exs`). The full gate also runs in CI (`.github/workflows/ci.yml`).

## Adding a harness

Extensibility is by design: a new harness is **one module + one config entry**, with no edits to the canonical `Event` types, the `Agent` schema, or the runtime. This works because the `Event.harness` identity is an open `atom()`.

1. Implement `RepoBuilder.Harness` (mandatory `command/1` + `normalize/2`; optional `CustomSpawn`).
2. Register it under `:harnesses` in `config/config.exs` with its adapter module, default model, and price table.

The included `RepoBuilder.Harness.Cursor` is the proof — a real `command/1` and a stub `normalize/2` (every frame `:skip`) — demonstrating that the platform accepts a new harness with no core change.

## Project layout

```
.
├── mise.toml                       # project-scoped toolchain pins (erlang/elixir/postgres)
├── mix.exs                         # :repo_builder app, deps, aliases
├── config/
│   ├── config.exs                  # harness registry, session limits, Oban, alerting
│   ├── dev.exs / test.exs          # local DB (postgres/postgres @ localhost:5432)
│   └── runtime.exs                 # env vars (PORT, WEBHOOK_SECRET, API keys, prod secrets)
├── scripts/
│   ├── pg.sh                       # user-space PostgreSQL cluster (init/start/stop/status/psql)
│   └── patch_deps.sh               # type_check 0.13.7 fix for Elixir 1.20 (run before compile)
├── lib/
│   ├── repo_builder/
│   │   ├── harness.ex, harness/    # contract, Event, Wire, Redact, Registry, adapters, Pricing
│   │   ├── session/                # erlexec GenServer runtime, Admission, Supervisor
│   │   ├── os_pid_ledger*, orphan_reaper.ex   # zero-orphan ledger + reaper
│   │   ├── workflow_engine*, workflows*       # deterministic state machine + context
│   │   ├── workers/, webhooks.ex   # Oban StepWorker/CronTrigger/WorkflowResume, HMAC verify
│   │   ├── agents*, logs*, prompts*, chats*   # Ecto contexts (only Repo callers)
│   │   └── telemetry/              # telemetry + cost/error alerting
│   └── repo_builder_web/
│       ├── router.ex, endpoint.ex
│       ├── live/                   # ConsoleLive (/), DashboardLive, AgentLive, WorkflowLive, SystemLogsLive
│       ├── controllers/            # PageController (unrouted), WebhookController
│       ├── components/             # typed DashboardComponents, ConsoleComponents
│       └── plugs/                  # CacheBodyReader (raw-body capture)
├── priv/                           # migrations, seeds, workspaces
└── test/
```

## Status / notes

- The automated suite (146 tests) and the green gate run entirely against the `Fake`/Mock adapter through the registry seam — **no external CLI is required** for CI or local development.
- The **only manual step** is live acceptance against the real `claude` and `pi` CLIs, since those tools are external and may not be installed in every environment.
- Remember `scripts/pg.sh start` once per session, and `scripts/patch_deps.sh` (followed by `mix deps.compile type_check && mix compile`) after any `mix deps.get`/`mix deps.clean`.
