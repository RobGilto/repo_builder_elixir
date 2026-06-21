defmodule RepoBuilder.Orchestrators do
  @moduledoc """
  Context for durable orchestrators (BUILD_PROMPT.md §8). The ONLY `Repo` caller
  for `orchestrators`. Every public function is `@spec`'d and returns tagged
  tuples; nothing raises on the happy/expected-error paths.

  Owns the per-orchestrator bearer token used to scope the MCP tool surface: the
  PLAINTEXT token is returned exactly once by `mint_token/1` and never persisted;
  only its SHA-256 hash is stored, and `verify_token/2` compares in constant time.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Harness.Registry
  alias RepoBuilder.Orchestrator.{Orchestrator, SystemPrompt}
  alias RepoBuilder.Repo

  @default_name "default"

  # The worker "model roster" categories the orchestrator picks from when spawning
  # agents (issue-d follow-up). Each maps to a {harness, provider, model} the
  # operator assigns via the console; an unassigned model means "no model selected".
  @agent_categories ~w(fast main heavy leader)

  @doc "The fixed worker-model categories the orchestrator can spawn into."
  @spec agent_categories() :: [String.t()]
  def agent_categories, do: @agent_categories

  @doc "The configured default orchestrator settings (harness/model)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:repo_builder, :orchestrator, [])

  @doc """
  Whether the holding pattern is enabled: when a dispatched worker returns, the `Queue`
  re-engages the orchestrator with a low-priority auto-resume turn (started when idle, or
  recorded and run once the queue drains). Defaults to `true` (issue
  holding-pattern-followup); the test env opts out for determinism.
  """
  @spec auto_resume?() :: boolean()
  def auto_resume?, do: config()[:auto_resume_on_worker_return] == true

  @doc "The maximum number of queued operator turns before `enqueue` is rejected."
  @spec max_queue_depth() :: pos_integer()
  def max_queue_depth, do: config()[:max_queue_depth] || 50

  @spec default_harness() :: String.t()
  def default_harness do
    config()[:default_harness] || List.first(RepoBuilder.Harness.Registry.known()) || "fake"
  end

  @spec list() :: [Orchestrator.t()]
  def list, do: Repo.all(from(o in Orchestrator, order_by: [asc: o.name]))

  @doc "Fetch an orchestrator by id."
  @spec fetch(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  def fetch(id) do
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      orchestrator -> {:ok, orchestrator}
    end
  end

  @doc """
  Idempotently fetch-or-create the singleton "default" orchestrator. On first call
  it is created with `harness` (defaulting to the configured orchestrator harness)
  and the configured default model; subsequent calls return the existing row
  unchanged (its harness/model are NOT overwritten).
  """
  @spec get_or_create_default(String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_default(harness \\ nil) do
    case Repo.get_by(Orchestrator, name: @default_name) do
      %Orchestrator{} = orchestrator ->
        {:ok, orchestrator}

      nil ->
        harness = harness || default_harness()

        %Orchestrator{}
        |> Orchestrator.changeset(
          apply_harness_defaults(%{name: @default_name, harness: harness}, harness)
        )
        |> Repo.insert()
        |> handle_default_race()
    end
  end

  @doc """
  Merge the per-harness orchestrator defaults (provider/model from the registry)
  into `params`/an orchestrator's attrs for `harness`. Switching to Claude yields
  provider `anthropic`/model `opus`; switching to pi clears both (operator-chosen).
  The registry default falls back to the configured global `:default_model`.
  """
  @spec apply_harness_defaults(Orchestrator.t() | map(), String.t()) :: map()
  def apply_harness_defaults(base, harness) do
    defaults = Registry.orchestrator_defaults(harness)

    base
    |> to_attrs()
    |> Map.merge(%{
      harness: harness,
      provider: Map.get(defaults, :default_provider),
      # No model is auto-assigned: the operator must pick one explicitly, and
      # running inference with none surfaces a clear "no model selected" error.
      model: nil,
      # A resumable CLI session id is harness-specific (a Fake/pi session can't be
      # resumed by Claude). Clear it on switch so the next turn starts fresh — not
      # `--resume <stale-id>`, which the new harness rejects.
      session_id: nil
    })
  end

  @spec to_attrs(Orchestrator.t() | map()) :: map()
  defp to_attrs(%Orchestrator{} = orchestrator), do: Map.from_struct(orchestrator)
  defp to_attrs(map) when is_map(map), do: map

  # Two concurrent first-calls can race on the unique :name; the loser hits the
  # constraint and we read the winner's row instead of surfacing an error.
  @spec handle_default_race({:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  defp handle_default_race({:ok, _} = ok), do: ok

  defp handle_default_race({:error, _changeset} = error) do
    case Repo.get_by(Orchestrator, name: @default_name) do
      %Orchestrator{} = orchestrator -> {:ok, orchestrator}
      nil -> error
    end
  end

  @spec create(map()) :: {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  def create(params) do
    %Orchestrator{}
    |> Orchestrator.changeset(params)
    |> Repo.insert()
  end

  @doc "Persist the resumable CLI session id captured from the last turn."
  @spec set_session(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_session(id, session_id), do: update_fields(id, %{session_id: session_id})

  @spec set_status(Ecto.UUID.t(), Orchestrator.status()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_status(id, status), do: update_fields(id, %{status: status})

  @doc """
  Switch the orchestrator's harness (validated against the registry by the
  changeset) AND apply that harness's orchestrator defaults to provider/model:
  flipping to Claude restores Opus, flipping to pi clears the Claude-only model.
  """
  @spec set_harness(Ecto.UUID.t(), String.t()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_harness(id, harness), do: update_fields(id, apply_harness_defaults(%{}, harness))

  @doc """
  Set the orchestrator's provider (open identity; nil clears it). Clears the model
  (no auto-default — the operator picks one, and inference with none errors) and the
  resumable session (a CLI session is provider-specific).
  """
  @spec set_provider(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_provider(id, provider),
    do: update_fields(id, %{provider: provider, model: nil, session_id: nil})

  @doc """
  Set the working directory the orchestrator AND the workers it commands run in
  (their session `cwd`). A blank value clears it (`nil`), restoring the default of
  an isolated per-session scratch workspace. Clears the resumable session id: a CLI
  session store is keyed to its project cwd (pi keys sessions by cwd), so moving to
  a new directory must start the next turn fresh rather than resume in the old tree.
  """
  @spec set_working_dir(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_working_dir(id, working_dir),
    do: update_fields(id, %{working_dir: blank_to_nil(working_dir), session_id: nil})

  @doc """
  Set the orchestrator's custom system prompt (`nil`/blank falls back to the
  generated default at spawn) and its append/replace `mode`. Both are persisted
  together so the next turn spawns with the chosen text under the chosen flag.
  """
  @spec set_system_prompt(Ecto.UUID.t(), String.t() | nil, Orchestrator.mode()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_system_prompt(id, prompt, mode) when mode in [:append, :replace],
    do: update_fields(id, %{system_prompt: blank_to_nil(prompt), system_prompt_mode: mode})

  @doc """
  Reset the system prompt to its generated default: clears the custom override and
  restores `:append` mode (today's behavior). Idempotent.
  """
  @spec reset_system_prompt(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  def reset_system_prompt(id),
    do: update_fields(id, %{system_prompt: nil, system_prompt_mode: :append})

  @doc """
  The generated default system prompt for `orchestrator` (delegates to
  `SystemPrompt.build/1`) — used by the console to render a read-only preview of
  what the orchestrator runs with when no custom override is set.
  """
  @spec default_system_prompt(Orchestrator.t()) :: String.t()
  def default_system_prompt(%Orchestrator{} = orchestrator), do: SystemPrompt.build(orchestrator)

  @doc """
  Set the orchestrator's harness-blind reasoning effort. Each adapter maps it to its
  own CLI flag at spawn (`:default` ⇒ omit the flag). Persisted on the row so the
  next turn picks it up; preserved across harness switches (orchestrator-level state).
  """
  @spec set_reasoning_effort(Ecto.UUID.t(), Orchestrator.effort()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_reasoning_effort(id, effort)
      when effort in [:default, :off, :low, :medium, :high, :max],
      do: update_fields(id, %{reasoning_effort: effort})

  @doc "The ordered reasoning-effort levels for the settings control (`:default` first)."
  @spec reasoning_efforts() :: [Orchestrator.effort(), ...]
  def reasoning_efforts, do: Orchestrator.efforts()

  @doc "The worker model roster: `%{category => entry}` where each entry has harness/provider/model."
  @spec agent_models(Orchestrator.t()) :: %{optional(String.t()) => map()}
  def agent_models(%Orchestrator{metadata: metadata}), do: Map.get(metadata, "agent_models", %{})

  @doc """
  The operator's chosen display timezone (IANA name) for rendering log timestamps.
  Stored in `metadata["timezone"]`; falls back to the default (`"UTC"`) when unset or
  no longer a curated/valid zone.
  """
  @spec timezone(Orchestrator.t()) :: String.t()
  def timezone(%Orchestrator{metadata: metadata}) do
    case Map.get(metadata, "timezone") do
      zone when is_binary(zone) ->
        if RepoBuilder.Timezones.valid?(zone), do: zone, else: default_tz()

      _ ->
        default_tz()
    end
  end

  @doc """
  Set the operator's display timezone (validated against `RepoBuilder.Timezones`).
  Persists to `metadata["timezone"]` via the same atomic `FOR UPDATE` read-merge-write
  as `set_agent_model/3` so a concurrent metadata write can't clobber sibling keys, then
  broadcasts the orchestrator update so open consoles re-render in the new zone.
  """
  @spec set_timezone(Ecto.UUID.t(), String.t()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found | :invalid_timezone}
  def set_timezone(id, zone) do
    if RepoBuilder.Timezones.valid?(zone) do
      put_metadata_locked(id, "timezone", zone)
    else
      {:error, :invalid_timezone}
    end
  end

  # Atomically put a single top-level `key => value` into the orchestrator's metadata
  # under a `FOR UPDATE` row lock (so concurrent metadata writes can't clobber sibling
  # keys), then broadcast the update outside the transaction. Shared by metadata setters.
  @spec put_metadata_locked(Ecto.UUID.t(), String.t(), term()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  defp put_metadata_locked(id, key, value) do
    result =
      Repo.transaction(fn ->
        case Repo.one(from(o in Orchestrator, where: o.id == ^id, lock: "FOR UPDATE")) do
          nil -> Repo.rollback(:not_found)
          %Orchestrator{} = orchestrator -> merge_metadata!(orchestrator, key, value)
        end
      end)

    case result do
      {:ok, updated} ->
        :ok = RepoBuilder.Dashboard.broadcast_orchestrator_updated(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec default_tz() :: String.t()
  defp default_tz, do: RepoBuilder.Timezones.default()

  @doc """
  Assign the {harness, provider, model} a worker `category` (`fast`/`main`/`heavy`/
  `leader`) uses. A blank model means "unassigned" — the orchestrator can't spawn
  into that category until a model is chosen.
  """
  @spec set_agent_model(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found | :invalid_category}
  def set_agent_model(id, category, attrs) when category in @agent_categories do
    # The four `configure_tier` tool calls arrive as concurrent HTTP requests, each
    # an independent process. A plain read-merge-write would lose updates (the last
    # writer clobbers the others' categories). Serialize writers on the same row with
    # a `FOR UPDATE` lock inside one transaction so each merge sees the prior committed
    # roster and the entries accumulate.
    entry = %{
      "harness" => attr(attrs, "harness"),
      "provider" => attr(attrs, "provider"),
      "model" => attr(attrs, "model"),
      "_updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    result =
      Repo.transaction(fn ->
        case Repo.one(from(o in Orchestrator, where: o.id == ^id, lock: "FOR UPDATE")) do
          nil -> Repo.rollback(:not_found)
          %Orchestrator{} = orchestrator -> merge_agent_model!(orchestrator, category, entry)
        end
      end)

    # Broadcast outside the transaction so PubSub never holds the row lock.
    case result do
      {:ok, updated} ->
        :ok = RepoBuilder.Dashboard.broadcast_orchestrator_updated(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_agent_model(_id, _category, _attrs), do: {:error, :invalid_category}

  # Merge `entry` into the locked orchestrator's `agent_models` roster and persist.
  # Runs inside the `set_agent_model/3` transaction; rolls back on a write error so
  # the caller's contract stays `{:error, :not_found}`. Returns the updated row.
  # Inference-only spec — Dialyzer narrows the returned struct below `Orchestrator.t()`.
  defp merge_agent_model!(%Orchestrator{metadata: metadata} = orchestrator, category, entry) do
    roster = Map.put(Map.get(metadata, "agent_models", %{}), category, entry)

    case update_record(orchestrator, %{metadata: Map.put(metadata, "agent_models", roster)}) do
      {:ok, updated} -> updated
      {:error, _} -> Repo.rollback(:not_found)
    end
  end

  # Put a single top-level `key => value` into the locked orchestrator's `metadata`
  # and persist, preserving all sibling keys. Runs inside the `set_timezone/2`
  # transaction; rolls back on a write error. Returns the updated row.
  # Inference-only spec — Dialyzer narrows the returned struct below `Orchestrator.t()`.
  defp merge_metadata!(%Orchestrator{metadata: metadata} = orchestrator, key, value) do
    case update_record(orchestrator, %{metadata: Map.put(metadata, key, value)}) do
      {:ok, updated} -> updated
      {:error, _} -> Repo.rollback(:not_found)
    end
  end

  @doc """
  Set the orchestrator's model (nil clears it) and remember it in the per-provider
  "recently selected" list (orchestrator `metadata`, most-recent first). Clears the
  resumable session id: a CLI session is model-specific, so switching models must
  start the next turn fresh (and zero the console context-window bar) rather than
  resume the prior model's conversation.
  """
  @spec set_model(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_model(id, model) do
    case fetch(id) do
      {:ok, orchestrator} ->
        update_fields(id, %{
          model: model,
          session_id: nil,
          metadata: record_recent_model(orchestrator.metadata, orchestrator.provider, model)
        })

      error ->
        error
    end
  end

  @doc "The recently-selected models for `provider` (most-recent first), from `metadata`."
  @spec recent_models(Orchestrator.t(), String.t() | nil) :: [String.t()]
  def recent_models(%Orchestrator{metadata: metadata}, provider) do
    metadata
    |> Map.get("recent_models", %{})
    |> Map.get(recent_key(provider), [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Add `amount` USD to the running total (float→Decimal boundary, §8 rule 10). A
  `nil` amount is a no-op (unpriced harnesses contribute nothing).
  """
  @spec add_cost(Ecto.UUID.t(), float() | Decimal.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def add_cost(id, nil) do
    # No-op for unpriced turns: return the (unchanged) row so callers never branch.
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      %Orchestrator{} = orchestrator -> {:ok, orchestrator}
    end
  end

  def add_cost(id, amount) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{total_cost_usd: current} = orchestrator ->
        # Emit the live cost telemetry AND get the Decimal delta back in one call.
        delta = emit_cost_recorded(id, amount)
        total = Decimal.add(current, delta)
        update_record(orchestrator, %{total_cost_usd: total})
    end
  end

  @doc """
  Fire the shared cost telemetry (`[:repo_builder, :cost, :recorded]`) for one
  increment WITHOUT touching the DB, returning the Decimal delta so the caller can
  accumulate it. This is the per-event budget-enforcement seam (issue hot-path-writes
  Part B): `Orchestrator.Server` coalesces the `orchestrators` row write to one flush
  per turn, but must still emit this telemetry per `Usage` so `Budget.Guard`
  (issue-budget-guardrails) enforces live caps on every increment.

  A `nil` amount is a no-op: it emits nothing (parity with `add_cost/2`'s nil clause)
  and returns `Decimal.new(0)`.
  """
  @spec emit_cost_recorded(Ecto.UUID.t(), float() | Decimal.t() | nil) :: Decimal.t()
  def emit_cost_recorded(_id, nil), do: Decimal.new(0)

  def emit_cost_recorded(id, amount) do
    delta = to_decimal(amount)

    # Emit on the shared cost event so Budget.Guard (issue-budget-guardrails) can
    # attribute orchestrator spend to the {:global} and {:orchestrator, id} scopes.
    :telemetry.execute(
      [:repo_builder, :cost, :recorded],
      %{amount: Decimal.to_float(delta)},
      %{orchestrator_id: id, run_id: nil}
    )

    delta
  end

  @doc """
  Flush an ENTIRE orchestrator turn's accumulated cost/usage in ONE `Repo.update`
  (issue hot-path-writes Part B), replacing the per-`Usage` write storm of three
  separate `add_cost`/`add_usage`/`set_estimated_cost` round-trips.

  `acc` carries the in-memory turn accumulation:

    * `:cost` (Decimal) — summed billed cost this turn, ADDED to `total_cost_usd`;
    * `:input`/`:output` (non_neg integers) — summed tokens, ADDED to the lifetime
      cumulative counters;
    * `:context` (integer | nil) — the LAST frame's `input + output` occupancy, which
      OVERWRITES `context_tokens` (nil ⇒ no usage seen ⇒ left untouched);
    * `:estimate` (float | Decimal | nil) — the LAST frame's token-derived estimate,
      which OVERWRITES `estimated_cost_usd` (nil ⇒ untouched, float→Decimal here, §8);
    * `:status` (`:idle | :error | nil`) — final status (nil ⇒ untouched, e.g. a
      best-effort crash flush leaves the running status as-is).
  """
  @spec flush_turn(Ecto.UUID.t(), map()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  def flush_turn(id, acc) when is_map(acc) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{} = orchestrator ->
        update_record(orchestrator, flush_params(orchestrator, acc))
    end
  end

  @doc """
  Record the live token-derived cost ESTIMATE (display-only). OVERWRITES the latest
  snapshot — it is NOT additive and is strictly separate from the authoritative
  `total_cost_usd`. A `nil` amount is a no-op (unpriced turn leaves the prior estimate
  in place). The estimate is superseded by `add_cost/2` when the harness reports the
  real billed amount on the terminal event.
  """
  @spec set_estimated_cost(Ecto.UUID.t(), float() | Decimal.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_estimated_cost(id, nil) do
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      %Orchestrator{} = orchestrator -> {:ok, orchestrator}
    end
  end

  def set_estimated_cost(id, amount) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{} = orchestrator ->
        update_record(orchestrator, %{estimated_cost_usd: to_decimal(amount)})
    end
  end

  @doc """
  Record a turn's token usage. ACCUMULATES `input`/`output` into the cumulative
  lifetime counters (cost report) AND OVERWRITES `context_tokens` with this turn's
  `input + output` (the context-window OCCUPANCY signal — latest turn, not a sum).
  `nil` token args are treated as 0 (no-op-safe for unpriced/absent usage fields).
  """
  @spec add_usage(Ecto.UUID.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def add_usage(id, input, output) do
    input = non_neg(input)
    output = non_neg(output)

    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{input_tokens: in_total, output_tokens: out_total} = orchestrator ->
        update_record(orchestrator, %{
          input_tokens: in_total + input,
          output_tokens: out_total + output,
          context_tokens: input + output
        })
    end
  end

  @doc """
  Token snapshot for the cost report/UI: cumulative `input`/`output`/`total`
  throughput plus the latest-turn `context` occupancy.
  """
  @spec token_totals(Orchestrator.t()) :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          total: non_neg_integer(),
          context: non_neg_integer()
        }
  def token_totals(%Orchestrator{} = orchestrator) do
    input = orchestrator.input_tokens || 0
    output = orchestrator.output_tokens || 0

    %{
      input: input,
      output: output,
      total: input + output,
      context: orchestrator.context_tokens || 0
    }
  end

  @doc """
  Mint a fresh per-orchestrator bearer token: returns the PLAINTEXT (caller passes
  it to the harness via env) and stores only its hash. Re-minting rotates the token.
  """
  @spec mint_token(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, :not_found}
  def mint_token(id) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{} = orchestrator ->
        token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        case update_record(orchestrator, %{token_hash: hash(token)}) do
          {:ok, _orchestrator} -> {:ok, token}
          {:error, _changeset} -> {:error, :not_found}
        end
    end
  end

  @doc "Verify a plaintext bearer token against the stored hash (constant-time)."
  @spec verify_token(Ecto.UUID.t(), String.t()) ::
          {:ok, Orchestrator.t()} | {:error, :unauthorized}
  def verify_token(id, token) when is_binary(token) do
    with %Orchestrator{token_hash: stored} when is_binary(stored) <- Repo.get(Orchestrator, id),
         true <- Plug.Crypto.secure_compare(stored, hash(token)) do
      {:ok, Repo.get(Orchestrator, id)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_token(_id, _token), do: {:error, :unauthorized}

  # --- private ---

  @spec update_fields(Ecto.UUID.t(), map()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  defp update_fields(id, params) do
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      %Orchestrator{} = orchestrator -> update_record(orchestrator, params)
    end
  end

  # Build the single coalesced flush params from the pre-turn row + the turn accumulator
  # (see flush_turn/2): cost + tokens ACCUMULATE onto the row; context/estimate/status
  # are replace-latest and are only written when present (nil ⇒ leave the column as-is).
  @spec flush_params(Orchestrator.t(), map()) :: map()
  defp flush_params(%Orchestrator{} = o, acc) do
    %{
      total_cost_usd: Decimal.add(o.total_cost_usd, Map.get(acc, :cost) || Decimal.new(0)),
      input_tokens: (o.input_tokens || 0) + non_neg(Map.get(acc, :input)),
      output_tokens: (o.output_tokens || 0) + non_neg(Map.get(acc, :output))
    }
    |> maybe_put(:context_tokens, Map.get(acc, :context))
    |> maybe_put(:estimated_cost_usd, decimal_or_nil(Map.get(acc, :estimate)))
    |> maybe_put(:status, Map.get(acc, :status))
  end

  # Inference-only (no @spec): a generic "put unless nil" map-builder — a hand-written
  # contract would only be a supertype of dialyzer's success typing.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec decimal_or_nil(float() | Decimal.t() | nil) :: Decimal.t() | nil
  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(amount), do: to_decimal(amount)

  @spec update_record(Orchestrator.t(), map()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  defp update_record(orchestrator, params) do
    orchestrator
    |> Orchestrator.changeset(params)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :not_found}
    end
  end

  # Trim a system-prompt string, treating blank/whitespace-only as nil (so spawn
  # falls back to the generated default). A nil input passes through unchanged.
  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Read a roster attribute from a string-keyed map, treating blank as nil.
  @spec attr(map(), String.t()) :: String.t() | nil
  defp attr(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _ -> nil
    end
  end

  @recent_limit 6

  @spec record_recent_model(map(), String.t() | nil, String.t() | nil) :: map()
  defp record_recent_model(metadata, _provider, model) when model in [nil, ""], do: metadata

  defp record_recent_model(metadata, provider, model) do
    key = recent_key(provider)
    all = Map.get(metadata, "recent_models", %{})
    list = [model | Map.get(all, key, [])] |> Enum.uniq() |> Enum.take(@recent_limit)
    Map.put(metadata, "recent_models", Map.put(all, key, list))
  end

  @spec recent_key(String.t() | nil) :: String.t()
  defp recent_key(nil), do: "_"
  defp recent_key(provider), do: to_string(provider)

  @spec to_decimal(float() | Decimal.t()) :: Decimal.t()
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)

  @spec hash(String.t()) :: String.t()
  defp hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  # Coerce a token field to a non-negative integer; nil/negative/non-integer ⇒ 0.
  @spec non_neg(term()) :: non_neg_integer()
  defp non_neg(value) when is_integer(value) and value > 0, do: value
  defp non_neg(_value), do: 0
end
