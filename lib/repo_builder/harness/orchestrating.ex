defmodule RepoBuilder.Harness.Orchestrating do
  @moduledoc """
  OPTIONAL harness behaviour (issue-c) — implement ONLY for a harness that can run
  as the conversational ORCHESTRATOR, binding the agent-management tools through
  its native mechanism. Mirrors `RepoBuilder.Harness.CustomSpawn`: a single
  `@optional_callbacks` entry so a workers-only adapter (mandatory behaviour only)
  still compiles under `--warnings-as-errors`.

  The harness-blind tool LOGIC lives once in `RepoBuilder.Orchestrator.Tools` and
  is served over one MCP-over-HTTP endpoint; this callback returns only the EXTRA
  argv + env needed to attach those tools and resume the orchestrator's session,
  writing any per-session config file (e.g. `.mcp.json`) as a side effect.

    * Claude — writes `<cwd>/.mcp.json` (http transport + bearer header) and returns
      `--mcp-config <path>`, the system prompt, and `--resume <id>` when resuming.
    * pi — returns `-e <extension>`, the system prompt, session-resume args, and the
      tool-endpoint env (`PI_ORCH_BASE_URL` / `PI_ORCH_TOKEN`), since pi ships no MCP.

  A harness that does NOT implement this callback is workers-only: the
  `Orchestrator.Server` then dispatches its tool calls in-process (the keyless Fake
  loop). Either way the canonical `Event` flow and the worker `Session` runtime are
  untouched — adding an orchestrator-capable harness is one module + one registry
  `orchestrating: true` entry (§10).

  SECURITY INVARIANT: the orchestrator is delegation-only — it must call ONLY its bound
  meta-tools, never the harness's native file/shell tools. Every `orchestrator_spawn/2`
  MUST restrict the session's native toolset accordingly (Claude `--disallowedTools …`,
  pi `--no-builtin-tools`), otherwise a drifting model writes files itself instead of
  dispatching to a worker. Workers reach the harness WITHOUT this callback, so they keep
  the full native toolset.
  """

  @typedoc """
  Per-orchestrator tool-binding context handed to `orchestrator_spawn/2`:

    * `:orchestrator_id` — the orchestrator whose tool surface this session binds;
    * `:mcp_base_url`   — base URL of the MCP-over-HTTP endpoint (scoped per id);
    * `:token`         — the per-orchestrator bearer token (env only, never argv);
    * `:resume_session_id` — prior CLI session id to resume, or `nil` on first turn;
    * `:system_prompt` — the orchestrator system prompt to inject;
    * `:system_prompt_mode` — `:append` ⇒ map to the harness's append-prompt flag
      (Claude/pi `--append-system-prompt`); `:replace` ⇒ map to the harness's
      replace-prompt flag (Claude/pi `--system-prompt`), swapping out the harness
      default entirely;
    * `:cwd`           — the session working directory (where to write config files).
  """
  @type tool_ctx :: %{
          required(:orchestrator_id) => Ecto.UUID.t(),
          required(:mcp_base_url) => String.t(),
          required(:token) => String.t(),
          required(:resume_session_id) => String.t() | nil,
          required(:system_prompt) => String.t(),
          required(:system_prompt_mode) => :append | :replace,
          required(:cwd) => Path.t()
        }

  @doc """
  Return the EXTRA `{args, env}` to merge onto the base `command/1` output so this
  harness runs as the orchestrator with its tools bound and session resumed. Args
  are appended after the base argv; env is appended to the base env. Secrets
  (`:token`) go in env, NEVER argv. May write a per-session config file under `:cwd`.
  """
  @callback orchestrator_spawn(RepoBuilder.Harness.start_opts(), tool_ctx()) ::
              {args :: [String.t()], env :: [{String.t(), String.t()}]}

  @optional_callbacks orchestrator_spawn: 2
end
