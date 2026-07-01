defmodule RepoBuilder.Harness.Event do
  @moduledoc """
  Canonical, harness-blind event sum type (BUILD_PROMPT.md §4.1).

  Every adapter's `normalize/2` maps a raw wire frame into zero-or-more of these
  variants; the orchestrator, persistence, and UI speak ONLY these events and are
  blind to which harness produced them.

  ## Open `harness` identity

  Every variant carries `harness: atom()` — the registry key, NOT a closed
  `:claude | :pi` union. This is the single deliberate type looseness (§3 rule 5,
  §10): a `:cursor` event must be representable with zero core-type edits. The
  trade-off is that Dialyzer cannot narrow on the harness value.

  ## `raw` redaction contract

  `raw` is the escape hatch retaining the full wire frame, which may include
  prompts, tool arguments, or provider responses containing secrets. The in-flight
  (PubSub) event keeps the FULL `raw` for the live UI. The PERSISTED copy
  (`agent_logs.payload`, §8) is passed through `RepoBuilder.Harness.Redact.scrub/1`
  first. Reviewers: the unredacted `raw` map here is by design, not a data leak.
  """

  @typedoc "Open harness identity (a registry key); NOT a closed union — adding a harness adds no core type edit (§10)."
  @type harness :: atom()

  @type t ::
          __MODULE__.SessionStarted.t()
          | __MODULE__.TextDelta.t()
          | __MODULE__.ToolCall.t()
          | __MODULE__.ToolResult.t()
          | __MODULE__.Usage.t()
          | __MODULE__.Status.t()
          | __MODULE__.Done.t()
          | __MODULE__.Error.t()

  defmodule SessionStarted do
    @moduledoc "Emitted exactly once at stream open."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :session_started, default: :session_started
      field :harness, atom()
      field :session_id, String.t()
      field :model, String.t(), enforce: false
      field :tools, [String.t()], enforce: false
      field :raw, map(), default: %{}
    end
  end

  defmodule TextDelta do
    @moduledoc """
    Incremental or finalized assistant text. `thinking?: true` routes to the
    reasoning pane.

    `partial?` is `true` for an incremental token delta and `false` for a
    finalized/whole block — consumers coalesce partials into one in-progress
    bubble and finalize on the non-partial block. Partials are broadcast for the
    live UI but NOT persisted, so `agent_logs` keeps one row per finalized turn.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :type, :text_delta, default: :text_delta
      field :harness, atom()
      field :text, String.t()
      field :thinking?, boolean(), default: false
      field :partial?, boolean(), default: false
      field :raw, map(), default: %{}
    end
  end

  defmodule ToolCall do
    @moduledoc "A tool invocation request from the assistant."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :tool_call, default: :tool_call
      field :harness, atom()
      field :id, String.t(), enforce: false
      field :name, String.t()
      field :input, map(), default: %{}
      field :raw, map(), default: %{}
    end
  end

  defmodule ToolResult do
    @moduledoc "The result of a tool invocation. Usually not rendered as its own UI card."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :tool_result, default: :tool_result
      field :harness, atom()
      field :id, String.t(), enforce: false
      field :is_error, boolean(), default: false
      field :content, term()
      field :raw, map(), default: %{}
    end
  end

  defmodule Usage do
    @moduledoc "Token usage and (optionally) cost. `cost_usd` is nil when unpriced, 0.0 when priced-at-zero."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :usage, default: :usage
      field :harness, atom()
      field :input_tokens, non_neg_integer()
      field :output_tokens, non_neg_integer()
      field :cache_read, non_neg_integer(), enforce: false
      field :cache_creation, non_neg_integer(), enforce: false
      field :cost_usd, float(), enforce: false
      # Token-derived live ESTIMATE (display-only); never accumulated into authoritative
      # cost; nil when the model is unpriced. Superseded by cost_usd when the harness
      # reports the real billed amount on the terminal event.
      field :estimated_cost_usd, float(), enforce: false
      field :raw, map(), default: %{}
    end
  end

  defmodule Status do
    @moduledoc """
    Non-terminal lifecycle signal (retry, rate limit, plugin install, init detail,
    missing provisioned-API secret).

    `kind: :missing_secret` (issue-provisioned-api-secret-missing-silent) is emitted at
    spawn when a worker is provisioned an external API whose `secret_name` did NOT resolve
    into the child env (fail-soft drop). `detail` carries `%{api: name, secret_name: name}`
    — the secret's NAME only, NEVER its value — so the operator sees a loud, queryable signal
    instead of decoding a downstream MCP `401`.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :type, :status, default: :status
      field :harness, atom()
      field :kind, :retry | :init_detail | :plugin_install | :rate_limit | :missing_secret
      field :attempt, integer(), enforce: false
      field :detail, map(), default: %{}
      field :raw, map(), default: %{}
    end
  end

  defmodule Done do
    @moduledoc """
    Terminal SUCCESS marker. `ok` reflects the harness's `is_error`, not merely the subtype.

    `reason: :held_pending_input` is a **clean, resumable stop** (issue
    holding-status-for-blocked-agents): a worker stopped because it is blocked on an
    external/human action (a browser login, a credential, a manual step). It stays
    `ok: true` (the stop is clean — no error, no degraded state), but it is NOT a
    completion: the worker is HELD and resumable, never reaped, and the orchestrator can
    `command_agent` it again once the blocking condition clears.
    """
    use TypedStruct

    typedstruct enforce: true do
      field :type, :done, default: :done
      field :harness, atom()
      field :ok, boolean()
      field :partial?, boolean(), default: false

      field :reason,
            :success
            | :clean_exit
            | :agent_end
            | :error_during_execution
            | :max_turns
            | :max_budget
            | :max_structured_output_retries
            | :idle_timeout
            | :sigterm_on_blocking_step
            | :held_pending_input

      field :duration_ms, integer(), enforce: false
      field :num_turns, integer(), enforce: false
      field :final_text, String.t(), enforce: false
      field :usage, map(), enforce: false
      field :cost_usd, float(), enforce: false
      field :raw, map(), default: %{}
    end
  end

  defmodule Error do
    @moduledoc "Terminal/fatal FAILURE marker."
    use TypedStruct

    typedstruct enforce: true do
      field :type, :error, default: :error
      field :harness, atom()
      field :message, String.t()

      field :reason,
            :provider_error
            | :auto_retry_exhausted
            | :idle_timeout
            | :spawn_failed
            | :no_model_selected
            | :unknown,
            default: :unknown

      field :retryable, boolean(), default: false
      field :status, integer(), enforce: false
      field :raw, map(), default: %{}
    end
  end
end
