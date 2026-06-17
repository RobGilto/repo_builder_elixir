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
    # resolves the aliases `opus`/`sonnet`/`haiku` to the latest of each family.
    orchestrator: %{
      default_provider: "anthropic",
      default_model: "opus",
      models: %{"anthropic" => ["opus", "sonnet", "haiku"]}
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

# Context-window sizes (tokens) for orchestrator/worker usage-% reporting. A
# `{harness, model}` tuple overrides the `:default`; harness-blind at the call site
# (RepoBuilder.Orchestrator.ContextWindow). Operator-tunable; pi's live model catalog
# could later supply real per-model sizes (Future Consideration).
config :repo_builder, :context_windows, %{
  :default => 200_000,
  {"claude", "claude-opus-4-8"} => 200_000,
  {"claude", "claude-sonnet-4-6"} => 1_000_000
}

# Orchestrator brain defaults (issue-c). `default_harness` is the harness the
# default orchestrator runs on; `mcp_base_url` is the localhost-bound base the
# generated `.mcp.json` / pi extension point at. Overridden per env + runtime.
config :repo_builder, :orchestrator,
  default_harness: "claude",
  default_model: nil,
  mcp_base_url: "http://127.0.0.1:4000",
  # Writable root for operator/orchestrator-authored subagent templates (the
  # read-only built-ins ship at priv/orchestrator/agents). Markdown-with-frontmatter
  # files, versioned on the filesystem. Overridden to a tmp dir in test.exs.
  agents_dir: Path.expand("~/.repo_builder/agents")

# Live-session runtime defaults (BUILD_PROMPT.md §5/§6). Overridable per env.
config :repo_builder, :session,
  max_live_sessions: 100,
  max_children: 200,
  idle_ms: 300_000,
  max_line_bytes: 1_048_576,
  workspace_base: "priv/workspaces"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
