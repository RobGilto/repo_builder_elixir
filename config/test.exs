import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :repo_builder, RepoBuilder.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "repo_builder_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :repo_builder, RepoBuilderWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "AfqOUq7O65Qq60G9/+lGDT7ZtYqjFEBBeSwYFVyJUCrnFBri0Tnuf5EKZSASsxXS",
  server: false

# In test we don't send emails
config :repo_builder, RepoBuilder.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Baseline harness registry for tests. Per-test setup overrides the entry for the
# harness under test (e.g. point "claude" at RepoBuilder.Harness.Mock) — the
# registry is the single injection seam (BUILD_PROMPT.md §13). "fake" lets
# session/workflow tests resolve a real canned-event adapter without a CLI.
# Never shell out to `pi --list-models` during tests — the model dropdown uses the
# static registry lists (RepoBuilder.Harness.Pi.Models is disabled here).
config :repo_builder, :pi_models_discovery, false

config :repo_builder, :harnesses, %{
  "claude" => %{
    module: RepoBuilder.Harness.Claude,
    exe: "claude",
    default_model: nil,
    price_table: %{},
    orchestrating: true,
    autonomous: true,
    orchestrator: %{
      default_provider: "anthropic",
      default_model: "opus",
      models: %{"anthropic" => ["opus", "sonnet", "haiku"]}
    }
  },
  "pi" => %{
    module: RepoBuilder.Harness.Pi,
    exe: "pi",
    default_model: "glm-4.6",
    price_table: %{"glm-4.6" => 0.6},
    orchestrating: true,
    autonomous: true,
    orchestrator: %{
      default_provider: nil,
      default_model: nil,
      providers: ["anthropic", "openai", "google", "zai", "groq", "openrouter"],
      models: %{
        "openai" => ["gpt-5", "gpt-5-mini"],
        "zai" => ["glm-4.6", "glm-4.5-air"]
      }
    }
  },
  "cursor" => %{
    module: RepoBuilder.Harness.Cursor,
    exe: "cursor-agent",
    default_model: nil,
    price_table: %{}
  },
  "fake" => %{
    module: RepoBuilder.Harness.Fake,
    exe: "printf",
    default_model: nil,
    price_table: %{},
    orchestrating: true
  },
  # ADW harness (issue-the-adw-gap): the shell-out workflow runner. In tests the
  # actual spawn is driven by a canned-event fixture script (config["adw_runner"] +
  # config["adw_script"]) so no `uv`/Python is required.
  "adw" => %{
    module: RepoBuilder.Harness.Adw,
    exe: "uv",
    default_model: "claude-sonnet-4-6",
    price_table: %{},
    autonomous: true
  }
}

# The default orchestrator runs on the keyless Fake harness in tests; the MCP base
# url points at the (server: false) test endpoint for controller/contract tests.
config :repo_builder, :orchestrator,
  default_harness: "fake",
  default_model: nil,
  mcp_base_url: "http://127.0.0.1:4002",
  # Deterministic queue defaults for tests; the holding-pattern test flips
  # auto_resume_on_worker_return to true via app-env for its own scope.
  auto_resume_on_worker_return: false,
  max_queue_depth: 50,
  # Per-run tmp root so template tests are hermetic and never touch the real
  # ~/.repo_builder/agents. Each test may further override this via app-env.
  agents_dir: Path.join(System.tmp_dir!(), "repo_builder_agents_test")

# Don't reap on boot in tests — the suite drives OrphanReaper.reap_node/1 explicitly
# so it doesn't race the Ecto sandbox.
config :repo_builder, :orphan_reaper, reap_on_boot: false

# File-driven prompt palette (issue-prompt-adw-palette): disable the inotify watcher
# and poll loop in the supervised instance so unit/LiveView tests are deterministic.
# Tests that exercise the watch path start their own Definitions instance with polling.
config :repo_builder, RepoBuilder.Definitions, watch_enabled?: false, poll_interval_ms: 30_000

# Oban in manual testing mode: jobs are inserted (assert_enqueued) but not run by
# queues/cron; execution tests use Oban.Testing helpers / perform_job.
config :repo_builder, Oban, testing: :manual

# Webhook secret for signing tests.
config :repo_builder, :webhooks, replay_window_seconds: 300, secret: "test-webhook-secret"

# Faster, more deterministic session runtime in tests.
config :repo_builder, :session,
  max_live_sessions: 100,
  max_children: 200,
  idle_ms: 300_000,
  max_line_bytes: 1_048_576,
  workspace_base: "priv/workspaces"
