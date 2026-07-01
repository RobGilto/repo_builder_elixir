# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :repo_builder,
  ecto_repos: [RepoBuilder.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Time zone database for DateTime.shift_zone/2 (local-time rendering of log
# timestamps, issue-a timezone). `tz` compiles the IANA data at build time.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :repo_builder, RepoBuilderWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RepoBuilderWeb.ErrorHTML, json: RepoBuilderWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RepoBuilder.PubSub,
  live_view: [signing_salt: "7NuWV4Ju"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Register Elixir source extensions so allow_upload accepts them
config :mime, :types, %{
  "text/x-elixir" => ["ex", "exs"]
}

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :repo_builder, RepoBuilder.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  repo_builder: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  repo_builder: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Harness registry (BUILD_PROMPT.md §10) — the SINGLE source of truth for which
# harnesses exist. Adding a harness is one adapter module + one entry here, with
# zero edits to the canonical Event types, the Agent schema, or the runtime.
# Read ONLY through RepoBuilder.Harness.Registry; injected/overridden in tests.
harnesses = %{
  "claude" => %{
    module: RepoBuilder.Harness.Claude,
    exe: "claude",
    default_model: "claude-sonnet-4-6",
    # Claude reports total_cost_usd in its stream — no price table needed.
    price_table: %{},
    # Orchestrator-capable (§10): binds tools via native MCP over .mcp.json.
    orchestrating: true,
    # Programmatic autonomy (issue-d): an autonomous Claude session appends
    # `--dangerously-skip-permissions` (== `--permission-mode bypassPermissions`) so
    # unattended turns never block on a tool-permission prompt. DELIBERATE and gated:
    # it only applies on this sandboxed orchestration server and can be turned off here.
    autonomous: true,
    # Per-harness orchestrator defaults — switching to Claude sets Opus automatically.
    # `models` drives the header model dropdown (latest first). The `claude` CLI
    # accepts BOTH the family aliases `opus`/`sonnet`/`haiku` (each resolves to the
    # latest of its family) AND concrete pinned model ids. We offer both so an
    # operator can pin a specific model instead of only the generic tier alias —
    # the dropdown still accepts any custom string the operator types. Edit here to
    # track new releases (one config edit, §10).
    orchestrator: %{
      default_provider: "anthropic",
      default_model: "opus",
      models: %{
        "anthropic" => [
          "opus",
          "sonnet",
          "haiku",
          "claude-opus-4-8",
          "claude-sonnet-4-6",
          "claude-haiku-4-5",
          "claude-opus-4-5",
          "claude-sonnet-4-5"
        ]
      }
    }
  },
  "pi" => %{
    module: RepoBuilder.Harness.Pi,
    exe: "pi",
    default_model: nil,
    # pi reports no USD — cost is derived (USD per million tokens). Unpriced ⇒ nil.
    price_table: %{"glm-4.6" => 0.6, "glm-4.5-air" => 0.2},
    # Orchestrator-capable (§10): binds tools via a TypeScript extension (-e).
    orchestrating: true,
    # pi has NO permission popups by design — its "autonomy" is `--approve` (trust
    # project-local resources non-interactively), NOT a skip-permissions flag.
    autonomous: true,
    # pi's provider/model are operator-chosen (no forced defaults); the providers
    # list drives the console dropdown without constraining the open `provider` column.
    # `models` is a per-provider curated list (latest first) that drives the model
    # dropdown; pi still accepts any model string, so this is guidance, not a
    # constraint. Edit here to track new releases (one config edit, §10).
    # `providers` are pi's `--provider` keys (its auth.json keys, per pi's
    # providers.md). `models` is a per-provider curated list (latest first) that
    # drives the model dropdown; pi accepts any model string, so this is guidance,
    # not a constraint — edit here to track new releases (one config edit, §10).
    orchestrator: %{
      default_provider: nil,
      default_model: nil,
      providers: [
        "anthropic",
        "openai",
        "google",
        "xai",
        "deepseek",
        "mistral",
        "groq",
        "cerebras",
        "fireworks",
        "together",
        "openrouter",
        "zai",
        "minimax",
        "kimi-coding",
        "nvidia",
        "huggingface"
      ],
      models: %{
        "anthropic" => ["claude-opus-4-1", "claude-sonnet-4-5", "claude-3-5-haiku-latest"],
        "openai" => ["gpt-5", "gpt-5-mini", "o4-mini", "gpt-4.1"],
        "google" => ["gemini-2.5-pro", "gemini-2.5-flash"],
        "xai" => ["grok-4", "grok-4-fast", "grok-code-fast-1"],
        "deepseek" => ["deepseek-chat", "deepseek-reasoner"],
        "mistral" => [
          "mistral-large-latest",
          "magistral-medium-latest",
          "codestral-latest",
          "devstral-medium-latest"
        ],
        "groq" => ["moonshotai/kimi-k2-instruct", "llama-3.3-70b-versatile", "qwen/qwen3-32b"],
        "cerebras" => ["qwen-3-coder-480b", "llama-3.3-70b", "gpt-oss-120b"],
        "fireworks" => [
          "accounts/fireworks/models/kimi-k2-instruct",
          "accounts/fireworks/models/deepseek-v3p1",
          "accounts/fireworks/models/qwen3-coder-480b-a35b-instruct"
        ],
        "together" => [
          "moonshotai/Kimi-K2-Instruct",
          "deepseek-ai/DeepSeek-V3.1",
          "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8"
        ],
        "openrouter" => [
          "anthropic/claude-sonnet-4.5",
          "openai/gpt-5",
          "google/gemini-2.5-pro",
          "x-ai/grok-4",
          "deepseek/deepseek-chat-v3.1"
        ],
        "zai" => ["glm-4.6", "glm-4.5-air"],
        "minimax" => ["MiniMax-M2", "MiniMax-M1", "MiniMax-Text-01"],
        "kimi-coding" => ["kimi-k2-0905-preview", "kimi-k2-turbo-preview"],
        "nvidia" => [
          "moonshotai/kimi-k2-instruct",
          "deepseek-ai/deepseek-r1",
          "qwen/qwen3-coder-480b-a35b-instruct"
        ],
        "huggingface" => [
          "deepseek-ai/DeepSeek-V3.1",
          "moonshotai/Kimi-K2-Instruct",
          "Qwen/Qwen3-Coder-480B-A35B-Instruct"
        ]
      }
    }
  },
  # Extensibility proof (§10): a third harness = this one module + this one entry,
  # with ZERO edits to Event/Agent/runtime.
  "cursor" => %{
    module: RepoBuilder.Harness.Cursor,
    exe: "cursor-agent",
    default_model: nil,
    price_table: %{}
  },
  # ADW harness (issue-the-adw-gap): shells out to a portable Python AI Developer
  # Workflow via `uv run`, mapping its neutral stdout-JSON events onto canonical
  # events. NOT an orchestrator brain (`orchestrating` omitted) — it is a workflow
  # RUNNER the orchestrator launches via `start_adw` (harness "adw"). `autonomous`
  # so the underlying Claude SDK runs unattended. The ADW reports Claude's USD cost
  # directly in its `usage` events, so no price table is needed.
  "adw" => %{
    module: RepoBuilder.Harness.Adw,
    exe: "uv",
    default_model: "claude-sonnet-4-6",
    price_table: %{},
    autonomous: true
  }
}

# Keyless local-demo harness (BUILD_PROMPT.md §13). The Fake adapter emits a canned
# canonical event sequence via `printf`, so the dashboard can be exercised end-to-end
# without a real CLI or any API key. Registered in :dev ONLY — never in prod (tests
# inject it through the registry override seam, §13).
harnesses =
  if config_env() == :dev do
    Map.put(harnesses, "fake", %{
      module: RepoBuilder.Harness.Fake,
      exe: "printf",
      default_model: "fake-model-1",
      price_table: %{},
      # Fake is orchestrator-capable WITHOUT an external binding: it has no
      # `orchestrator_spawn/2`, so Orchestrator.Server dispatches its tool calls
      # in-process (the keyless CI loop), §13.
      orchestrating: true
    })
  else
    harnesses
  end

config :repo_builder, :harnesses, harnesses

# Oban — durable jobs / cron / webhook triggers (BUILD_PROMPT.md §7). The Cron
# plugin periodically runs the WorkflowResume reconciler so in-flight runs resume
# after a node restart (durable/live split). bigint job ids (§8).
config :repo_builder, Oban,
  repo: RepoBuilder.Repo,
  queues: [default: 10, sessions: 20, workflows: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [{"*/5 * * * *", RepoBuilder.Workers.WorkflowResume}], timezone: "Etc/UTC"}
  ]

# Webhook trigger security (BUILD_PROMPT.md §7). The secret is resolved at runtime
# (config/runtime.exs); the replay window bounds the signed-timestamp age.
config :repo_builder, :webhooks, replay_window_seconds: 300

# Cost/error alerting thresholds (BUILD_PROMPT.md §13).
config :repo_builder, :alerting, cost_threshold_usd: 10.0

# Budget guardrails (issue-budget-guardrails). `refresh_ms` is the slow-path reconcile
# interval for Budget.Guard; `reconcile_on_boot?` seeds the default :alert cap from
# `:alerting` and reconciles spent-so-far from CostCenter on start (runtime-overridable).
config :repo_builder, :budget, refresh_ms: 60_000, reconcile_on_boot?: true

# Global default worker-model roster (issue per-project-agent-models). Compile-time
# fallback for `RepoBuilder.Settings.default_agent_models/0` when no `app_settings` row
# exists yet (first boot). Empty by default — the operator sets it in Settings → Default
# Models. Shape: `%{category => %{"harness" => h, "provider" => p | nil, "model" => m}}`.
config :repo_builder, :default_agent_models, %{}

# Context-window sizes (tokens) for orchestrator/worker usage-% reporting. This map is
# the operator OVERRIDE layer only — `RepoBuilder.Orchestrator.ContextWindow` resolves a
# `{harness, model}` window as: this config override → derived/live source (pi's
# `--list-models` `context` column via RepoBuilder.Harness.Pi.Models, else the built-in
# `@known_windows` catalog for Claude/known models) → `:default`. Entries here win over
# the built-in catalog and the live source; harness-blind at the call site.
config :repo_builder, :context_windows, %{
  :default => 200_000,
  {"claude", "claude-opus-4-8"} => 1_000_000,
  {"claude", "claude-sonnet-4-6"} => 1_000_000
}

# Orchestrator brain defaults (issue-c). `default_harness` is the harness the
# default orchestrator runs on; `mcp_base_url` is the localhost-bound base the
# generated `.mcp.json` / pi extension point at. Overridden per env + runtime.
config :repo_builder, :orchestrator,
  default_harness: "claude",
  default_model: nil,
  mcp_base_url: "http://127.0.0.1:4000",
  # FIFO turn queue (issue message-queue). `auto_resume_on_worker_return` enables the
  # holding pattern (an idle orchestrator is re-engaged when a dispatched worker
  # returns) — defaults ON (issue holding-pattern-followup) so the orchestrator always
  # follows up on returned work; set false to opt out. `max_queue_depth` bounds the
  # pending operator-message backlog.
  auto_resume_on_worker_return: true,
  max_queue_depth: 50,
  # Worker context-window HANDOVER threshold (issue graceful-agent-handover). A worker
  # whose latest-turn occupancy (`ContextWindow.usage_fraction/3`) reaches this fraction
  # is wound down gracefully: the platform issues a one-shot `[WIND DOWN]` directive, the
  # worker writes `ai_docs/<name>-handover.md` + emits a `:handover <path>` signal, and is
  # then retired. `RepoBuilder.Agents.Handover.threshold/0` reads this value and the
  # `report_cost` high-usage warning shares it (via `Handover.over_threshold?/1`) so the
  # two cannot drift. Default 0.8 (80%).
  handover_threshold: 0.8,
  # Idle watchdog for orchestrator turns. An orchestrator turn is interactive, so it
  # gets a SHORTER byte-idle window than the worker-grade `:session` `idle_ms` (5 min):
  # a worker doing a long build can legitimately be byte-silent for minutes, but an
  # interactive orchestrator turn byte-silent beyond this is treated as stalled and is
  # surfaced/recovered via the existing idle-timeout → Event.Error path. The timer
  # resets on every streamed frame, so a genuinely-working turn never trips it.
  turn_idle_ms: 120_000,
  # Writable root for operator/orchestrator-authored subagent templates (the
  # read-only built-ins ship at priv/orchestrator/agents). Markdown-with-frontmatter
  # files, versioned on the filesystem. Overridden to a tmp dir in test.exs.
  agents_dir: Path.expand("~/.repo_builder/agents"),
  # Autonomous drive loop (self-healing Phase 4). `Orchestrator.Driver` ticks every
  # `drive_interval_ms` (and once on boot when `drive_on_boot`) and drives every orchestrator
  # with an active goal one inner-loop step. The stall ladder: `max_stall` no-progress turns →
  # a replan turn; `escalate_after_stall` → escalate to the away human. `turn_deadline_ms` is
  # the HARD per-turn ceiling (catches a turn that stays byte-active but never finishes). The
  # circuit breaker trips a harness/model path after `breaker_max_failures` failures and
  # half-opens after `breaker_cooldown_ms`.
  #
  # The drive loop is a BACKSTOP, not the engine (deterministic-worker-fleet-gate): the
  # event-driven holding pattern (`auto_resume_on_worker_return`) is the primary re-engagement
  # path, and `RepoBuilder.Orchestrator.WorkerFleet` stops the loop from spending an LLM turn
  # to poll an orchestrator that has live, progressing workers (a worker is "progressing" when
  # its session process is alive and it is `:holding` or heartbeating within
  # `worker_progress_grace_ms`). `min_drive_interval_ms` is a hard per-orchestrator cooldown
  # that floors the drive cadence regardless of fleet edge cases — bounding worst-case spend.
  drive_interval_ms: 120_000,
  min_drive_interval_ms: 120_000,
  worker_progress_grace_ms: 90_000,
  drive_on_boot: true,
  max_stall: 2,
  escalate_after_stall: 3,
  # Focus discipline (orchestrator focus). When true (default), a budget-spending worker tool
  # (`command_agent`/`create_agent`/`start_adw`) is BLOCKED until the scope it targets has a
  # focus: a workstream-tagged call needs that workstream focused, an untagged call needs the
  # orchestrator's own focus. The Driver also nudges an unfocused active-goal orchestrator to
  # `set_focus` before spending budget. Set false to disable the gate (full back-compat).
  focus_gate: true,
  turn_deadline_ms: 180_000,
  breaker_max_failures: 3,
  breaker_cooldown_ms: 60_000,
  # Writable root for self-improving domain mental models (self-healing Phase 5): versioned
  # `.md` files shadowing the read-only `priv/orchestrator/experts` seed root (same dual-root
  # mechanism as agent templates). Overridden to a tmp dir in test.exs.
  experts_dir: Path.expand("~/.repo_builder/experts"),
  # Iterative UI/UX polish phase (iterative-ui-ux). `ui_iteration_cap` bounds a `:ui_ux`
  # phase's review→fix loop before it auto-completes at MVP (no infinite polishing);
  # `ui_ux_enabled` is the global off-switch so pure-backend/library builds skip surface
  # detection entirely. Both default-on/3; raise the cap per project to hold a higher bar.
  ui_iteration_cap: 3,
  ui_ux_enabled: true

# Editor integration: open files in the operator's editor from the file-diff event cards.
# Disabled by default in config/test.exs; overridable at runtime via RB_EDITOR_CMD /
# RB_EDITOR_ENABLED (config/runtime.exs).
config :repo_builder, :editor,
  enabled: true,
  command: ["code"]

# Live-session runtime defaults (BUILD_PROMPT.md §5/§6). Overridable per env.
config :repo_builder, :session,
  max_live_sessions: 100,
  max_children: 200,
  idle_ms: 300_000,
  # Soft quiescence demotion (self-healing Phase 1). A live worker quiet on MEANINGFUL
  # events past this window is demoted `:running → :idle` while staying alive/resumable —
  # the honest "waiting" state. Load-bearing ordering: `quiescence_ms` (soft, 90 s)
  # < `turn_idle_ms` (120 s) ≈ `min_stale_ms` (120 s reaper) < `idle_ms` (300 s hard-kill).
  quiescence_ms: 90_000,
  # Hostile-stream OOM backstop (BUILD_PROMPT.md §6 rule 6): a single un-newline-terminated
  # line larger than this is treated as a runaway flood and kills the child. Sized at 16 MiB
  # so legitimate large single-line stream-json frames (big Read/diff/Firecrawl tool results)
  # pass through; tune per deploy via REPO_BUILDER_MAX_LINE_BYTES (config/runtime.exs).
  max_line_bytes: 16_777_216,
  workspace_base: "priv/workspaces"

# Phantom-worker liveness sweep (issue worker-terminal Part B). `RepoBuilder.Session.LivenessReaper`
# reconciles non-archived agents wedged `:running`/`:holding` whose session process is dead
# (a hard kill / brutal shutdown / node restart that bypassed `terminate/2`) and re-engages
# the owning orchestrator. `min_stale_ms` is a load-bearing grace (≥ 2× the interval): it
# avoids reaping a worker in the sub-second window between `command_agent`'s optimistic
# `:running` write and the `Session.Server` registering in `SessionRegistry`.
config :repo_builder, :session_liveness_reaper,
  sweep_on_boot: true,
  interval_ms: 60_000,
  min_stale_ms: 120_000,
  # Pass 3 (self-healing Phase 1): demote live-but-stale `:running` workers to `:idle`
  # (alive), the catch-all if a per-session quiescence timer was missed. Toggle off to
  # disable just that pass; the phantom passes are unaffected.
  idle_demotion: true

# Agentic plugin system (the agentic plugin system foundation). The SINGLE reader is
# `RepoBuilder.Plugins.Registry`. `install_dir` is the live install target (a sibling
# of `lib/`); `library_dir` is the local authoring/source folder; `sources` is the
# pluggable "store" seam (a fully-working local library + an HTTP remote store);
# `trust` gates checksum/code/signature on install.
config :repo_builder, :plugins,
  install_dir: "agentic_plugins",
  library_dir: "plugin_library",
  sources: %{
    "library" => %{module: RepoBuilder.Plugins.Source.LocalLibrary},
    "store" => %{module: RepoBuilder.Plugins.Source.RemoteStore, base_url: nil}
  },
  trust: [require_checksum: false, allow_code: true, require_signature: false]

# The Forge (forge-meta-artifact-generation). The meta-artifact generators are vendored
# in-tree; `RepoBuilder.Forge` renders one, drives a real harness session to write the
# artifact into an isolated scratch workspace, validates + packages it, and hands the
# result to the existing Plugins install→activate lifecycle. `generators_dir` is the
# vendored template root; `generation_harness` is the harness the generate step runs on
# (operator-overridable per project); `scratch_base` isolates generation from the target
# repo; `default_source` is the install source the Packager writes for. `max_retries`
# bounds the validate→generate retry edge.
config :repo_builder, :forge,
  generators_dir: "priv/forge/generators",
  generation_harness: "claude",
  scratch_base: "priv/forge_scratch",
  default_source: "library",
  max_retries: 1

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
