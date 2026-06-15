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
    price_table: %{}
  },
  "pi" => %{
    module: RepoBuilder.Harness.Pi,
    exe: "pi",
    default_model: nil,
    # pi reports no USD — cost is derived (USD per million tokens). Unpriced ⇒ nil.
    price_table: %{"glm-4.6" => 0.6, "glm-4.5-air" => 0.2}
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
      price_table: %{}
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
