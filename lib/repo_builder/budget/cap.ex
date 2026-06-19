defmodule RepoBuilder.Budget.Cap do
  @moduledoc """
  One durable spend CAP (issue-budget-guardrails), keyed by `(scope, scope_id, period)`.

    * `scope`/`scope_id` — what the cap limits (`:global` uses the `""` sentinel for
      `scope_id`; `:orchestrator`/`:workflow` carry the owning id).
    * `period` — the spend window the cap measures (`:total` all-time, `:daily`, `:monthly`).
    * `limit_usd` — the hard ceiling (`Decimal` — money never floats, §8).
    * `warn_ratio` — fraction of `limit_usd` at which the breaker broadcasts `:warning`.
    * `action` — what crossing the cap does: `:alert` (log/banner only, today's behaviour),
      `:pause` (refuse new spend in scope), `:hard_stop` (refuse + interrupt live sessions).
    * `enabled` — a disabled cap is ignored by the live breaker.
  """
  use RepoBuilder.Schema

  import Ecto.Changeset

  alias RepoBuilder.Budget.Scope

  @type scope :: Scope.scope()
  @type period :: :total | :daily | :monthly
  @type action :: :alert | :pause | :hard_stop

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          scope: scope() | nil,
          scope_id: String.t(),
          period: period() | nil,
          limit_usd: Decimal.t() | nil,
          warn_ratio: float(),
          action: action() | nil,
          enabled: boolean(),
          reset_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @scopes [:global, :orchestrator, :workflow]
  @periods [:total, :daily, :monthly]
  @actions [:alert, :pause, :hard_stop]
  @unique_index :budgets_scope_period_index

  schema "budgets" do
    field :scope, Ecto.Enum, values: @scopes
    field :scope_id, :string, default: ""
    field :period, Ecto.Enum, values: @periods, default: :total
    field :limit_usd, :decimal
    field :warn_ratio, :float, default: 0.8
    field :action, Ecto.Enum, values: @actions, default: :alert
    field :enabled, :boolean, default: true
    # Operator-set spend-window restart; the breaker counts from max(period_start,
    # reset_at). Set via Budget.reset_cap_window/1, not the user-facing changeset.
    field :reset_at, :utc_datetime_usec
    timestamps()
  end

  @fields [:scope, :scope_id, :period, :limit_usd, :warn_ratio, :action, :enabled]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cap, params) do
    cap
    |> cast(params, @fields)
    |> validate_required([:scope, :period, :limit_usd, :action])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:period, @periods)
    |> validate_inclusion(:action, @actions)
    |> validate_number(:limit_usd, greater_than: 0)
    |> validate_number(:warn_ratio, greater_than: 0, less_than_or_equal_to: 1)
    |> normalize_scope_id()
    |> unique_constraint([:scope, :scope_id, :period], name: @unique_index)
  end

  # The global scope forces `scope_id: ""` (the sentinel); a scoped cap requires a
  # non-blank `scope_id` so it actually targets an orchestrator/workflow.
  @spec normalize_scope_id(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp normalize_scope_id(changeset) do
    case get_field(changeset, :scope) do
      :global ->
        put_change(changeset, :scope_id, "")

      scope when scope in [:orchestrator, :workflow] ->
        case get_field(changeset, :scope_id) do
          id when is_binary(id) and id != "" -> changeset
          _ -> add_error(changeset, :scope_id, "is required for a #{scope} cap")
        end

      _ ->
        changeset
    end
  end

  @doc "The cap's `(scope, scope_id, period)` scope_ref (drops `period`)."
  @spec scope_ref(t()) :: Scope.scope_ref()
  def scope_ref(%__MODULE__{scope: scope, scope_id: scope_id}), do: {scope, scope_id || ""}
end
