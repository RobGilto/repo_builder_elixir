import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/repo_builder start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :repo_builder, RepoBuilderWeb.Endpoint, server: true
end

config :repo_builder, RepoBuilderWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Webhook HMAC secret (BUILD_PROMPT.md §7) — resolved from the OS env at runtime,
# never persisted. Guarded so it does not clobber the dev/test config secret.
if webhook_secret = System.get_env("WEBHOOK_SECRET") do
  config :repo_builder, :webhooks, secret: webhook_secret
end

# Per-harness credentials (BUILD_PROMPT.md §6) — sourced from the OS env at runtime,
# referenced by env-var name and NEVER persisted to the DB. The session runtime
# resolves these into the child's env (never argv) and drops unset (nil) values.
config :repo_builder, :harness_secrets, %{
  "pi" => %{
    "OPENAI_API_KEY" => System.get_env("OPENAI_API_KEY"),
    "ANTHROPIC_API_KEY" => System.get_env("ANTHROPIC_API_KEY")
  }
}

# Per-TOOL credentials (issue firecrawl-grant) — the single app-wide key for each
# grantable worker research tool, sourced from the OS env at runtime, referenced by
# name and NEVER persisted to the DB. `Session.Server.resolve_secrets/2` folds these
# into the child env ONLY for the tools a worker actually has enabled, and drops unset
# (nil) values. Mirrors `:harness_secrets` above.
config :repo_builder, :tool_secrets, %{
  "firecrawl" => %{"FIRECRAWL_API_KEY" => System.get_env("FIRECRAWL_API_KEY")}
}

# Orchestrator MCP base URL (issue-c) — the localhost-bound base the generated
# `.mcp.json` / pi extension point at. Overridable per host; defaults to the local
# endpoint. The orchestrator reuses the same per-harness `:harness_secrets` above.
if base = System.get_env("ORCHESTRATOR_MCP_BASE_URL") do
  config :repo_builder, :orchestrator, mcp_base_url: base
end

# Operator-tunable stdout backpressure ceiling (BUILD_PROMPT.md §6 rule 6): raise/lower the
# per-line OOM backstop without a redeploy. Only applied when the env var is a valid positive
# integer; otherwise the config/config.exs default (16 MiB) stands.
case System.get_env("REPO_BUILDER_MAX_LINE_BYTES") do
  nil ->
    :ok

  raw ->
    case Integer.parse(raw) do
      {bytes, ""} when bytes > 0 ->
        session_cfg = Application.get_env(:repo_builder, :session, [])
        config :repo_builder, :session, Keyword.put(session_cfg, :max_line_bytes, bytes)

      _invalid ->
        :ok
    end
end

# Editor integration (issue file-diff-event-cards) — runtime overrides.
# RB_EDITOR_CMD: space-delimited command (e.g. "code" or "cursor --wait").
# RB_EDITOR_ENABLED: "true" to enable, "false" to disable.
if cmd = System.get_env("RB_EDITOR_CMD") do
  parts = String.split(cmd, " ", trim: true)
  editor_cfg = Application.get_env(:repo_builder, :editor, [])
  config :repo_builder, :editor, Keyword.put(editor_cfg, :command, parts)
end

if raw_enabled = System.get_env("RB_EDITOR_ENABLED") do
  editor_cfg = Application.get_env(:repo_builder, :editor, [])
  config :repo_builder, :editor, Keyword.put(editor_cfg, :enabled, raw_enabled == "true")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :repo_builder, RepoBuilder.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :repo_builder, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :repo_builder, RepoBuilderWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :repo_builder, RepoBuilderWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :repo_builder, RepoBuilderWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :repo_builder, RepoBuilder.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
