# Feature: Budget Guardrails & Kill Switch — enforced spend caps for autonomous agents

## Metadata
issue_number: `budget-guardrails`
adw_id: `feature`
issue_json: `{"title":"Budget Guardrails & Kill Switch — enforce spend caps, not just alert","body":"Today the platform tracks AI spend (CostCenter rollups, period_spend, live token counting) and emits a [:repo_builder, :cost, :recorded] telemetry event, but the only consumer (Telemetry.Alerting) just logs a WARNING when cost_threshold_usd is crossed. Nothing actually STOPS spend. An autonomous orchestrator or a runaway ADW (a cheap-model retry loop, a stuck pi session, a fan-out that spawns dozens of workers) can burn a month of budget overnight before anyone reads the log. Add enforced budget guardrails: durable spend CAPS per scope (global / per-orchestrator / per-workflow), a live circuit breaker that trips when a cap is crossed, three enforcement actions (alert, pause new work, hard-stop + interrupt in-flight), a manual global KILL SWITCH, and a LiveView surface (budgets panel + tripped banner + kill-switch button) so the operator sees and controls spend in real time."}`

## Feature Description

Add **enforced budget guardrails** to the orchestration platform: a durable set of
spend **caps** (per `(scope, period)`), a live **circuit breaker** (`Budget.Guard`) that
accumulates actual spend and **trips** when a cap is crossed, and **enforcement** at the
three points where new spend originates — starting a live session, advancing a workflow
step, and an orchestrator spawning/driving a worker. Each cap carries an **action**:

- `:alert` — log + banner only (today's behaviour, preserved as the default).
- `:pause` — reject **new** spend in scope (`{:error, :budget_exceeded}`); let in-flight
  sessions finish on their own.
- `:hard_stop` — reject new spend **and** interrupt every live session in scope
  (SIGTERM→SIGKILL via the existing `Session` interrupt path), i.e. a scoped kill switch.

A **manual global kill switch** lets the operator trip the global breaker instantly
(panic button) and release it. The whole thing is surfaced in the LiveView console: a
**budgets panel** (CRUD caps + live spend-vs-cap progress bars), a **tripped banner**, a
**budget badge**, and a **kill-switch button**, all updating live over a `"budget:events"`
PubSub topic.

The breaker is **durable across restarts**: caps live in Postgres, and on boot `Budget.Guard`
reconciles its in-memory accumulators from `CostCenter.period_spend/1` (real money already
spent in the current window) so a node restart cannot silently reset a budget to zero. This
mirrors the durable/live split the platform already uses (BUILD_PROMPT.md §7) and the
admission-gate pattern (`Session.Admission`, BUILD_PROMPT.md §5).

This is the natural completion of the cost story: the platform already *measures* spend
end-to-end; this feature makes it *enforceable*.

## User Story

As a **platform operator running autonomous AI agents and ADWs**
I want to **set hard spend caps (global, per-orchestrator, per-workflow) that automatically pause or kill agent work when crossed, plus a one-click kill switch**
So that **a runaway loop, a stuck session, or an over-eager orchestrator can't burn my budget overnight — spend stops at a limit I chose, and I can hit the brakes instantly when something looks wrong.**

## Problem Statement

The platform drives **non-deterministic** AI agents that spend real money per token, and it
is explicitly designed for **autonomous** operation (cron triggers, webhooks, orchestrators
that spawn workers, ADWs that fan out). Spend is **measured** everywhere
(`agent_logs.usage`, `workflow_runs.total_cost_usd`, `orchestrators.estimated_cost_usd`,
`CostCenter.rollup/1`, `CostCenter.period_spend/1`, the `[:repo_builder, :cost, :recorded]`
telemetry event) — but it is **never enforced**. The only reaction to crossing
`config :repo_builder, :alerting, cost_threshold_usd: 10.0` is
`RepoBuilder.Telemetry.Alerting` emitting a `Logger.warning/1`. By the time a human reads
that line, the money is already gone. There is:

- no per-orchestrator or per-workflow cap (a single bad orchestrator can spend without bound);
- no automatic back-pressure (nothing rejects new sessions/steps/workers on overspend);
- no kill switch (no way to stop everything at once);
- no operator-facing budget state (the console shows spend, never a limit or a breach).

For a product whose defining risk is "deterministic orchestration of **non-deterministic**,
**paid** agents," the absence of spend enforcement is the highest-leverage gap.

## Solution Statement

Introduce a `RepoBuilder.Budget` bounded context with two durable concerns and one live
process, then enforce at the three spend-origination seams and surface it in LiveView:

1. **Durable caps** — a new `budgets` table (`Budget.Cap` schema) holding
   `{scope, scope_id, period, limit_usd, action, enabled}` with a unique key on
   `(scope, scope_id, period)`. Context: `RepoBuilder.Budget` (the only `Repo` caller),
   all functions `@spec`'d, returning `{:ok, t()} | {:error, Ecto.Changeset.t()}`.
2. **Live circuit breaker** — `RepoBuilder.Budget.Guard`, a supervised GenServer modeled on
   `Session.Admission`. It owns the authoritative, in-memory answer to "is spend allowed in
   scope X right now?" It (a) loads caps + reconciles spent-so-far from
   `CostCenter.period_spend/1` on init, (b) attaches a telemetry handler to
   `[:repo_builder, :cost, :recorded]` to accumulate live spend, (c) exposes
   `check(scopes) :: :ok | {:error, {:budget_exceeded, Cap.t()}}`, (d) **trips** a cap when
   crossed: marks it tripped, broadcasts on `"budget:events"`, and for `:hard_stop`
   enumerates `SessionRegistry` and interrupts every live session in scope, (e) supports a
   **manual global kill switch** (`engage_kill_switch/0` / `release_all/0`).
3. **Enforcement seams** —
   - `Session.Supervisor.start_session/1` calls `Budget.Guard.check/1` (with the session's
     scopes) before acquiring an admission slot; returns `{:error, {:budget_exceeded, cap}}`.
   - `WorkflowEngine.Runner` checks the breaker before each `:run_step`; on block it records
     the step `:failed`/`:cancelled` and follows the step's `on_failure` edge (isolated, never
     crashes the run).
   - `Orchestrator.Server` checks the breaker before spawning a worker / sending a turn;
     on block it returns a typed `budget_exceeded` tool result to the orchestrator instead of
     spending.
4. **LiveView surface** — a budgets panel + tripped banner + kill-switch button + budget
   badge in the console, plus a focused `Phoenix.LiveViewTest` integration test.

Reuse the existing telemetry event, the `CostCenter` actuals, the `Session.Admission`
GenServer pattern, the `Session` interrupt path, and the console's PubSub/stream idioms — no
new infrastructure, no new dependency.

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec. §5 (supervision tree + admission-gate pattern the
  Guard mirrors), §6 (session interrupt/`Session` API used by hard-stop), §7 (durable/live
  split + workflow runner step state machine), §8 (Ecto schema/migration shape, cost
  float→Decimal boundary), §9 (LiveView streams/`assign_async`/reconnect), §13 (Oban + Mox +
  crash-isolation testing).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every public
  fn, `@type`/`@enforce_keys`/`typedstruct`, precise unions, `{:ok,_}|{:error,_}` over
  raising, wire-vs-domain). Every new module must conform; the Credo `@spec` gate + Dialyzer
  are hard CI gates.
- `AGENTS.md` — Phoenix 1.8 + LiveView conventions for the new panel/components.
- `ai_docs/adw-orchestration.md` — workflow engine + Oban context for the runner-seam change.
- `lib/repo_builder/cost_center.ex` — **source of spent-so-far actuals.** `period_spend/1`
  (today/week/month, hidden INCLUDED — real money) and `rollup/1` feed the Guard's
  reconciliation on init/restart and the panel's "spent" figures. Study `derive_costs/5` and
  the nil-vs-0 (`NULL` = unpriced) convention — the Guard must respect it (an unpriced run
  contributes its *estimated* spend to the cap, flagged `estimated?`).
- `lib/repo_builder/session/admission.ex` — **the structural template** for `Budget.Guard`:
  a small `{used, max}` GenServer with `acquire/release/count`, typed `State`,
  `config`-sourced bound. The Guard is the same shape with richer state.
- `lib/repo_builder/session/supervisor.ex` — `start_session/1`: the first enforcement seam
  (add a `Budget.Guard.check/1` call before `Admission.acquire/0`). (Read to confirm the
  exact arity/return contract before editing.)
- `lib/repo_builder/session/server.ex` — the live session GenServer; confirm the
  interrupt/stop API the hard-stop path calls (e.g. `Session.interrupt/1` /
  `Session.Server` stop), and the scope metadata a session carries (`agent_id`,
  `orchestrator_id`, `workflow_run_id`).
- `lib/repo_builder/session.ex` — the `Session` facade (interrupt/lookup helpers the
  hard-stop path uses); confirm public API.
- `lib/repo_builder/workflow_engine/runner.ex` — `handle_continue(:run_step, ...)`: the
  second enforcement seam (check breaker before starting the step's session; on block,
  `record_step` `:cancelled` + `advance(state, step.on_failure)`).
- `lib/repo_builder/orchestrator/server.ex` — the orchestrator GenServer; the third
  enforcement seam (before spawning a worker / sending a turn). Read around line 225
  (`set_estimated_cost`) to find where orchestrator spend is accrued and where to gate.
- `lib/repo_builder/orchestrator/tools.ex` + `lib/repo_builder/orchestrator/tool_catalog.ex`
  — where worker-spawn / ADW-launch tools live; the budget block returns a typed
  `budget_exceeded` tool result here.
- `lib/repo_builder/workflows.ex` — `add_run_cost/2` (line ~67) **emits**
  `[:repo_builder, :cost, :recorded]` with `%{amount}` + `%{run_id}` metadata. The Guard
  subscribes to this; **extend the metadata** to also carry `orchestrator_id` and the
  scope keys so the Guard can attribute spend per scope (today it only has `run_id`).
- `lib/repo_builder/telemetry/alerting.ex` — the existing **alert-only** consumer of the
  same event. Keep it (the `:alert` action subsumes it) but the Guard becomes the
  *enforcing* consumer. Confirm the two handlers coexist (distinct handler ids).
- `lib/repo_builder/telemetry.ex` (`lib/repo_builder_web/telemetry.ex`) — add a
  `last_value`/`counter` metric for budget state (tripped count, % of cap) and confirm
  handler-attach ordering (Telemetry starts first, §5).
- `lib/repo_builder/application.ex` — supervision tree; add `Budget.Guard` after `Repo`
  (it reads caps + actuals on init) and before `Endpoint` (§5 ordering).
- `lib/repo_builder/orchestrator/orchestrator.ex` & `lib/repo_builder/workflows/workflow_run.ex`
  — confirm the id fields the Guard keys scopes on (`orchestrator_id`, `workflow_id`,
  `workflow_run_id`).
- `lib/repo_builder_web/live/console_live.ex` — primary UI; mount-subscribe to
  `"budget:events"`, seed budget assigns, render the panel/banner/badge, handle
  budget events + form/kill-switch UI events. Follow its existing PubSub + assign idioms.
- `lib/repo_builder_web/components/console_components.ex` — add the typed
  `budget_panel/1`, `budget_banner/1`, `budget_badge/1`, `kill_switch/1` function components
  (`attr/3` + `slot/3`, `values:` for the enum constraints).
- `config/config.exs` — existing `:alerting, cost_threshold_usd: 10.0` (the seed for a
  default global `:alert` cap) and `:session` block (Guard config lives alongside, runtime-
  overridable like `max_live_sessions`).
- `priv/repo/migrations/**` — pattern for the new `budgets` migration (binary_id PK, Enum-as-
  string, `:decimal` limit, unique index on `(scope, scope_id, period)`).
- `test/support/` (e.g. `session_case.ex`, `data_case.ex`, Mox setup) — reuse for the new tests.

### New Files

- `lib/repo_builder/budget.ex` — the bounded-context module (the **only** `Repo` caller for
  `budgets`): `list_caps/0`, `list_active_caps/0`, `get_cap/1`, `upsert_cap/1`,
  `update_cap/2`, `delete_cap/1`, `caps_for_scopes/1`, plus `seed_default_cap/0`. All
  `@spec`'d; `{:ok, Cap.t()} | {:error, Ecto.Changeset.t()}`.
- `lib/repo_builder/budget/cap.ex` — the `Budget.Cap` Ecto schema (`use RepoBuilder.Schema`):
  `scope Ecto.Enum[:global,:orchestrator,:workflow]`, `scope_id :string|nil`,
  `period Ecto.Enum[:total,:daily,:monthly]`, `limit_usd :decimal`,
  `warn_ratio :float` (default 0.8), `action Ecto.Enum[:alert,:pause,:hard_stop]`,
  `enabled :boolean`, hand-written `@type t`, `@spec`'d `changeset/2` with
  `validate_inclusion`/`validate_number`/`unique_constraint(:scope_scope_id_period)`.
- `lib/repo_builder/budget/guard.ex` — `RepoBuilder.Budget.Guard` GenServer (the live circuit
  breaker). Typed `%State{}` (`@enforce_keys` via `typedstruct`) holding the loaded caps,
  per-`(scope,scope_id,period)` spent-Decimal accumulators, per-cap breaker state
  (`:ok | :warning | :tripped`), and the manual `kill_switch?` flag. Public API:
  `check/1`, `note_spend/1` (or telemetry-driven), `engage_kill_switch/0`, `release_all/0`,
  `reset_cap/1`, `snapshot/0`. `@impl` callbacks unspecced per §3 rule 1; all other public
  fns `@spec`'d.
- `lib/repo_builder/budget/scope.ex` — a tiny typed helper:
  `@type scope_ref :: {:global, nil} | {:orchestrator, String.t()} | {:workflow, String.t()}`
  and `scopes_for/1` deriving the list of scope_refs a given session/step/worker belongs to
  (so one live session is checked against global + its orchestrator + its workflow caps at
  once). Keeps scope logic out of the runner/server/supervisor.
- `priv/repo/migrations/<ts>_create_budgets.exs` — the `budgets` table migration (binary_id
  PK, Enum-as-string columns, `:decimal` `limit_usd`, `:float` `warn_ratio`, `:boolean`
  `enabled`, unique index on `[:scope, :scope_id, :period]`).
- `test/repo_builder/budget_test.exs` — context CRUD + changeset validation + unique-key +
  nil-vs-0 cost handling unit tests.
- `test/repo_builder/budget/guard_test.exs` — Guard unit tests: accumulation from the
  telemetry event, warn→trip transitions, `check/1` allow/deny, `:pause` vs `:hard_stop`
  (hard-stop interrupts a live session — assert via a Fake/mock session), kill switch
  engage/release, restart reconciliation from `CostCenter.period_spend/1`, crash isolation.
- `test/repo_builder_web/live/test_budget_guardrails_test.exs` — the required
  `Phoenix.LiveViewTest` integration test (see Step by Step Tasks).

## Implementation Plan

### Phase 1: Foundation — durable caps + scope model + telemetry metadata

Stand up the data model and the scope vocabulary first, because every later phase depends on
them. Create the `budgets` table + `Budget.Cap` schema + `RepoBuilder.Budget` context
(the typed `Repo` seam), the `Budget.Scope` helper, and **extend the
`[:repo_builder, :cost, :recorded]` telemetry metadata** in `Workflows.add_run_cost/2` (and
add an equivalent emission for orchestrator spend if one does not already exist) so the event
carries enough to attribute spend to `{:global}`, `{:orchestrator, id}`, and
`{:workflow, run_id}` scopes. Seed a default global `:alert` cap from the existing
`cost_threshold_usd` so behaviour is unchanged until an operator opts into enforcement.

### Phase 2: Core Implementation — the circuit breaker

Build `Budget.Guard` modeled on `Session.Admission`: typed state, config-sourced refresh
interval, telemetry-handler attach in `init` (idempotent, like `Telemetry.Alerting.attach/0`),
spent-so-far reconciliation from `CostCenter.period_spend/1` on init, the `check/1`
allow/deny decision, the warn/trip state machine, the `"budget:events"` broadcasts, the
`:hard_stop` session-interrupt sweep over `SessionRegistry`, and the manual kill switch.
Supervise it in `application.ex` after `Repo`. Unit-test it in isolation (FakeHarness /
mock session for the hard-stop path) before wiring any enforcement.

### Phase 3: Integration — enforcement seams + LiveView surface

Wire `Budget.Guard.check/1` into the three spend-origination seams (session supervisor,
workflow runner, orchestrator server), each degrading gracefully and *isolated* (a budget
block is a typed `{:error, {:budget_exceeded, cap}}`, never a crash, and a workflow follows
`on_failure`). Then build the console surface: budget panel (CRUD + live spend-vs-cap bars),
tripped banner, badge, kill-switch button, all driven by `"budget:events"` and the existing
console PubSub idioms. Finish with the LiveView integration test and the full validation gate.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the routed docs and confirm seams
- Read `ai_docs/typed-elixir-standard.md` (always row) and BUILD_PROMPT.md §5, §6, §7, §8,
  §9, §13; skim `AGENTS.md` and `ai_docs/adw-orchestration.md`.
- Confirm via the code (not assumption): the exact `Session.Supervisor.start_session/1`
  return contract; the `Session` interrupt API and how a live session exposes its
  `orchestrator_id`/`workflow_run_id`; the `Orchestrator.Server` worker-spawn call site;
  the precise `[:repo_builder, :cost, :recorded]` emission in `Workflows.add_run_cost/2`.
- Optionally use Tidewave `get_source_location`/`project_eval` to verify the live arities.

### 2. Create the `budgets` migration
- `mix ecto.gen.migration create_budgets`. binary_id PK; columns: `scope :string` (not null),
  `scope_id :string` (nullable), `period :string` (not null, default `"total"`),
  `limit_usd :decimal` (not null, precision/scale e.g. `15,6`), `warn_ratio :float`
  (default `0.8`), `action :string` (not null, default `"alert"`), `enabled :boolean`
  (not null, default `true`), `timestamps(type: :utc_datetime_usec)`.
- `create unique_index(:budgets, [:scope, :scope_id, :period], name: :budgets_scope_period_index)`
  — note `scope_id` NULL for global; ensure the partial/expression handles NULL (use a
  coalesced expression index or store global `scope_id` as `""` to keep the unique key total —
  pick the `""`-sentinel approach to mirror `CostCenter`'s `normalize_provider/1` `""` convention).

### 3. Implement `Budget.Cap` schema (`lib/repo_builder/budget/cap.ex`)
- `use RepoBuilder.Schema`; hand-written `@type t :: %__MODULE__{...}` with the Enum literal
  unions (`scope: :global | :orchestrator | :workflow`, etc.) per §8.
- `@spec changeset(t(), map()) :: Ecto.Changeset.t()`: cast + `validate_required`
  `[:scope, :period, :limit_usd, :action]`; `validate_number(:limit_usd, greater_than: 0)`;
  `validate_number(:warn_ratio, greater_than: 0, less_than_or_equal_to: 1)`;
  `validate_inclusion` on the enums; require `scope_id` when `scope != :global` (and force
  `""` when `:global`); `unique_constraint([:scope, :scope_id, :period], name: :budgets_scope_period_index)`.
- `mix dialyzer`-friendly precise types; no `any()`/`map()` where a shape is known.

### 4. Implement the `RepoBuilder.Budget` context (`lib/repo_builder/budget.ex`)
- The **only** `Repo` caller for `budgets`. `@spec` every public fn:
  `list_caps/0`, `list_active_caps/0` (enabled), `get_cap/1`, `caps_for_scopes/1`
  (given `[scope_ref]`, return matching enabled caps), `upsert_cap/1`, `update_cap/2`,
  `delete_cap/1`, `seed_default_cap/0` (idempotent: insert a global `:total` `:alert` cap at
  `config :repo_builder, :alerting, :cost_threshold_usd` if none exists).
- Returns `{:ok, Cap.t()} | {:error, Ecto.Changeset.t()}` (or `[Cap.t()]`/`Cap.t() | nil`).

### 5. Implement `Budget.Scope` (`lib/repo_builder/budget/scope.ex`)
- `@type scope_ref :: {:global, String.t()} | {:orchestrator, String.t()} | {:workflow, String.t()}`
  (global uses the `""` sentinel for `scope_id`).
- `@spec scopes_for(map()) :: [scope_ref()]` — from a context map
  (`%{orchestrator_id, workflow_run_id}` etc.) build the list of scope_refs that apply (always
  includes `{:global, ""}`). Pure, unit-testable.

### 6. Extend cost telemetry metadata (Phase 1 seam)
- In `Workflows.add_run_cost/2`, extend the `[:repo_builder, :cost, :recorded]` metadata from
  `%{run_id: ...}` to also include `%{workflow_run_id:, workflow_id:, orchestrator_id: nil}`
  (whatever the run carries) so the Guard can attribute spend.
- Ensure orchestrator-session spend is **also** emitted on the same event (find where
  `Orchestrators.set_estimated_cost/2` is called in `orchestrator/server.ex` near line 225 and
  emit `[:repo_builder, :cost, :recorded]` with `%{orchestrator_id: ...}` metadata if it is not
  already). Keep amounts as `float()` (the event's existing shape); the Guard converts to
  `Decimal` at its boundary (§8 cost float→Decimal rule).
- Update `Telemetry.Alerting` only if the metadata-shape change affects its `run_id` read
  (it should keep working unchanged — verify with its test).

### 7. Implement `Budget.Guard` (`lib/repo_builder/budget/guard.ex`) — the circuit breaker
- GenServer modeled on `Session.Admission`. Typed `%State{}` (`typedstruct`, `@enforce_keys`):
  `caps :: %{scope_ref => Cap.t()}`, `spent :: %{scope_ref => Decimal.t()}`,
  `breaker :: %{scope_ref => :ok | :warning | :tripped}`, `kill_switch? :: boolean()`.
- `init/1`: load `Budget.list_active_caps/0`; reconcile `spent` from
  `CostCenter.period_spend/1` / `rollup/1` for each cap's window (so a restart does not zero a
  budget); attach the telemetry handler to `[:repo_builder, :cost, :recorded]` (idempotent;
  the handler `cast`s spend into the Guard — keep handler work tiny per §13, just forward).
- `@spec check([Scope.scope_ref()]) :: :ok | {:error, {:budget_exceeded, Cap.t()}}` — deny if
  `kill_switch?` or any matching cap is `:tripped` (and its action is `:pause`/`:hard_stop`;
  an `:alert` cap never denies).
- Spend handler: add the float→Decimal amount to every matching scope accumulator; recompute
  breaker state; on crossing `warn_ratio` broadcast `:warning`; on crossing `limit_usd`
  **trip**: set `:tripped`, broadcast `{:budget_tripped, cap, spent}` on `"budget:events"`,
  and for `action: :hard_stop` enumerate `Registry.select(SessionRegistry, ...)`, filter to
  sessions in scope, and `Session.interrupt/1` each (SIGTERM→SIGKILL via §6). `:alert` action
  only broadcasts + lets `Telemetry.Alerting` log (no deny, no interrupt).
- `engage_kill_switch/0` / `release_all/0` (manual global trip/reset; hard-stop semantics);
  `reset_cap/1` (operator clears a tripped cap after raising the limit); `snapshot/0` (caps +
  spent + breaker state for the LiveView, like `Admission.count/0`).
- Idempotent, clamp-safe, never crashes on a bad event (`:skip`-style tolerance).
- Supervise in `application.ex` **after `Repo`** (needs caps + actuals), before `Endpoint`.

### 8. Write the `Budget.Guard` unit tests (`test/repo_builder/budget/guard_test.exs`)
- Start a Guard with seeded caps (Mox/Fake session for the hard-stop path); drive
  `[:repo_builder, :cost, :recorded]` events (or `note_spend/1`) and assert: accumulation,
  `warn_ratio` → `:warning` broadcast, `limit_usd` → `:tripped` + `"budget:events"` broadcast,
  `check/1` allow before / deny after, `:pause` does **not** interrupt a live session while
  `:hard_stop` **does**, kill-switch engage denies everything + release restores, restart
  reconciliation seeds `spent` from `CostCenter.period_spend/1`, and crash isolation (kill the
  Guard, assert sessions keep running — enforcement fails *open* or the supervisor restarts it;
  decide and assert the chosen policy explicitly).

### 9. Enforcement seam 1 — `Session.Supervisor.start_session/1`
- Before `Admission.acquire/0`, build the session's scope_refs (from its
  `orchestrator_id`/`workflow_run_id` opts) via `Scope.scopes_for/1` and call
  `Budget.Guard.check/1`. On `{:error, {:budget_exceeded, cap}}` return that to the caller
  (do not acquire a slot); on `:ok` proceed unchanged.
- Add a test asserting a session is refused when a `:pause`/`:hard_stop` cap is tripped, and
  allowed otherwise.

### 10. Enforcement seam 2 — `WorkflowEngine.Runner`
- In `handle_continue(:run_step, ...)`, before `Session.Supervisor.start_session/...`, call
  `Budget.Guard.check(Scope.scopes_for(%{workflow_run_id: run.id, ...}))`. On block: record the
  step `:cancelled` (or `:failed`) via the existing `record_step/4` + `advance(state, step.on_failure)`
  — the run is **isolated**, never crashed, and persists the transition to `workflow_runs`
  (source of truth, §7). On `:ok` proceed unchanged.
- Add a runner test: a tripped budget makes the in-flight step follow `on_failure` and does not
  affect a second concurrent workflow run (crash-isolation parity, §13).

### 11. Enforcement seam 3 — `Orchestrator.Server`
- Before spawning a worker / sending a worker turn (find the call site near the worker-launch /
  `start_adw` tool path in `orchestrator/server.ex` + `tools.ex`), call `Budget.Guard.check/1`
  with the orchestrator's scope_refs. On block, return a typed `budget_exceeded` **tool result**
  to the orchestrator (so the agent sees "budget exceeded, cannot spawn worker" rather than the
  platform silently spending), and broadcast nothing new (the trip broadcast already fired).
- Add a test asserting the orchestrator gets a `budget_exceeded` tool result and no worker
  session is started when a relevant cap is tripped.

### 12. Typed function components (`console_components.ex`)
- `budget_badge/1` (compact spend/cap with a state color via `values:`), `budget_banner/1`
  (rendered only when a cap is tripped or the kill switch is engaged — red, with the cap label
  + a "reset" affordance), `budget_panel/1` (list of caps with live spend-vs-cap progress bars
  + an add/edit form), `kill_switch/1` (the engage/release button). All typed with `attr/3` +
  `slot/3`; enums constrained with `values:`.

### 13. Console integration (`console_live.ex`)
- On `connected?(socket)` mount: `Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "budget:events")`;
  seed `:budgets`/`:budget_state` assigns from `Budget.Guard.snapshot/0` and
  `Budget.list_caps/0`; consider `assign_async` for the initial spend rollup (§9) with a
  loading placeholder.
- `handle_info/2` clauses for `{:budget_tripped, cap, spent}`, `{:budget_warning, ...}`,
  `{:budget_reset, ...}`, `{:kill_switch, :engaged|:released}` → update assigns + (optionally)
  `stream_insert` a system-log-style line.
- `handle_event/3` for the panel form (`save_budget` → `Budget.upsert_cap/1`,
  `delete_budget`), `reset_budget` (→ `Budget.Guard.reset_cap/1`), and
  `toggle_kill_switch` (→ `engage_kill_switch/0` / `release_all/0`). Re-render reflects the new
  state live. Respect reconnect: re-seed from `snapshot/0` in mount (§9 reconnect rule).

### 14. Telemetry metric + config
- Add a `last_value`/`counter` metric in `lib/repo_builder_web/telemetry.ex` for budget state
  (e.g. tripped-cap count, max %-of-cap) so it shows in LiveDashboard (§9/§13).
- Add `config :repo_builder, :budget, refresh_ms: <n>, enforce?: true` (runtime-overridable
  like `:session`), and call `Budget.seed_default_cap/0` at boot (e.g. in the Guard `init` or a
  release task) so the existing `cost_threshold_usd` becomes a real (default `:alert`) cap.

### 15. LiveView integration test (`test/repo_builder_web/live/test_budget_guardrails_test.exs`)
- Use `Phoenix.LiveViewTest`: `live(conn, "/")` (console). Drive the panel form to create a
  small global `:pause` cap (`render_submit(form, ...)`), assert it renders in the panel.
- Broadcast a `{:budget_tripped, cap, spent}` on `"budget:events"` (or push spend through the
  Guard) and assert (`assert_push`/`render`) the **tripped banner** appears and the badge shows
  the tripped state. Click the kill-switch button (`element(...) |> render_click()`) and assert
  the engaged state renders; release and assert it clears.
- Assert the right canonical/PubSub event drove the re-render (PubSub assertion per the §9
  guidance). Optionally capture a Playwright screenshot of `http://localhost:4000` as visual
  proof (do not assert on CSS).

### 16. Run the full validation gate
- Execute every command in **Validation Commands** below and fix any failure until the entire
  gate is green with zero regressions. Optionally verify live behaviour with Tidewave
  (`project_eval` to trip a cap, `execute_sql_query` to confirm the `budgets` row, `get_logs`
  to confirm the trip + interrupt path).

## Testing Strategy

### Unit Tests
- **`Budget` context** — changeset validation (limit > 0, warn_ratio in (0,1], scope_id
  required unless global), unique key on `(scope, scope_id, period)` returns
  `{:error, changeset}` (proves the index exists, §13), `caps_for_scopes/1` filtering,
  `seed_default_cap/0` idempotency, enum/decimal round-trip.
- **`Budget.Scope`** — `scopes_for/1` derives the correct scope_ref list for global-only,
  orchestrator, and workflow contexts (always includes global).
- **`Budget.Guard`** — accumulation from the telemetry event (float→Decimal), warn/trip
  transitions and broadcasts, `check/1` allow/deny per action, `:pause` vs `:hard_stop`
  (interrupt sweep), kill switch, restart reconciliation from `CostCenter.period_spend/1`,
  unpriced (nil-cost) runs contributing *estimated* spend without breaking the nil-vs-0 rule.
- **Enforcement seams** — session refused on trip, workflow step follows `on_failure` on trip
  (isolated; second run unaffected), orchestrator gets a `budget_exceeded` tool result.
- **LiveView** — the integration test above (mount, create cap, trip, banner, kill switch).

### Edge Cases
- **Unpriced harness (pi) before its price catalog entry exists** — `cost_usd` is `nil`; the
  Guard must use the *estimated* cost (`CostCenter.derive_costs`) so an unpriced runaway is
  still capped; never treat `nil` as `0` (BUILD_PROMPT.md §8 nil-vs-0).
- **Concurrent spend racing the trip** — two sessions spending simultaneously past the cap;
  the Guard serializes on its GenServer mailbox, so the breaker trips deterministically and
  both subsequent `check/1`s deny. Assert no double-spend slips an *already-tripped* cap.
- **Restart with spend already over cap** — boot reconciliation must trip immediately (not
  start at zero) so a restart cannot launder an exceeded budget.
- **Cap raised after a trip** — `update_cap/2` then `reset_cap/1` re-allows spend; a raise
  without reset stays tripped (explicit operator action required).
- **Hard-stop with no live sessions in scope** — interrupt sweep is a no-op; no crash.
- **`:alert` cap** — never denies and never interrupts; only logs/broadcasts (back-compat with
  today's `Telemetry.Alerting`).
- **Guard crash** — the supervisor restarts it; decide and test the during-restart policy
  (fail-open: new spend allowed for the restart window, then re-reconciled — document it).
- **Kill switch engaged while a workflow is mid-step** — new steps blocked; in-flight session
  interrupted (hard-stop semantics); the run follows `on_failure`, the run row stays consistent.

## Acceptance Criteria
- A durable `budgets` cap (global / per-orchestrator / per-workflow; total/daily/monthly;
  action alert/pause/hard_stop) can be created, edited, and deleted through the
  `@spec`'d `RepoBuilder.Budget` context and the console panel; the web layer never touches
  `Repo` directly (§8).
- With a `:pause` cap, once actual spend in scope crosses `limit_usd`, **new** live sessions,
  workflow steps, and orchestrator worker spawns in that scope are refused with
  `{:error, {:budget_exceeded, cap}}` (or a `budget_exceeded` tool result); in-flight sessions
  finish.
- With a `:hard_stop` cap, crossing `limit_usd` additionally **interrupts every live session in
  scope** (verified: the child is SIGTERM→SIGKILLed, no orphan, via the existing §6 path).
- The **manual kill switch** trips the global breaker instantly (engage) and restores spend
  (release); both reflect live in the console.
- The breaker is **durable across a node restart**: after restart, `Budget.Guard` reconciles
  spent-so-far from `CostCenter.period_spend/1`, so a budget already over its cap stays tripped
  (does not silently reset to zero).
- A budget block is **isolated**: a tripped cap never crashes a workflow run or another run; the
  affected step follows its `on_failure` edge and the transition persists to `workflow_runs`.
- The console renders, live over `"budget:events"`: a budget panel (spend-vs-cap progress
  bars), a tripped banner, a budget badge, and the kill-switch button — all updating without a
  page reload and surviving reconnect (re-seeded from `snapshot/0`, §9).
- Back-compat: the existing `cost_threshold_usd` becomes a default global `:alert` cap; with no
  enforcing cap configured, platform behaviour is unchanged (alert-only).
- The full validation gate is green with zero regressions; every new public function has an
  `@spec`, every new struct is `@enforce_keys`-typed, Dialyzer is clean, and untrusted/external
  numbers cross the float→Decimal boundary at persistence/Guard ingest (§8).

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the `create_budgets` migration cleanly (and `mix ecto.rollback`
  then `mix ecto.migrate` once to prove the migration round-trips).
- `mix test test/repo_builder/budget_test.exs` — context CRUD + changeset + unique-key tests.
- `mix test test/repo_builder/budget/guard_test.exs` — circuit-breaker unit tests
  (accumulate/warn/trip, pause vs hard-stop, kill switch, restart reconciliation, isolation).
- `mix test test/repo_builder_web/live/test_budget_guardrails_test.exs` — the LiveView
  integration test (panel, trip banner, kill switch).
- `mix compile --warnings-as-errors` — compile clean; the gradual set-theoretic type checker
  and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — run the full ExUnit suite (Postgres-backed) with zero
  failures and zero regressions across the existing ~540+ tests.
- `mix format --check-formatted` — ensure code is formatted.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **No new dependency.** The feature is built entirely on existing machinery: the
  `[:repo_builder, :cost, :recorded]` telemetry event, `CostCenter` actuals, the
  `Session.Admission` GenServer pattern, the `Session` interrupt path, the `WorkflowEngine.Runner`
  step machine, the orchestrator tool-result protocol, and the console's PubSub/stream idioms.
  `mix.exs` `deps/0` is unchanged.
- **Single source of truth for "may we spend?"** — like `Session.Admission` for concurrency,
  `Budget.Guard` is the *only* place enforcement decisions live; the three seams just call
  `check/1`. This keeps the policy testable in isolation and the seams thin.
- **Fail-open vs fail-closed on Guard crash** is a deliberate decision: recommended **fail-open**
  for the brief restart window (don't wedge the whole platform if the breaker process dies),
  immediately re-reconciled from `CostCenter` on restart. Document and test whichever is chosen.
- **Why the telemetry event, not polling the DB** — the event already fires on every cost roll;
  the Guard reacts in-process with no DB round-trip on the hot path (the periodic
  `CostCenter.period_spend/1` reconcile is the slow-path correctness backstop, e.g. every
  `refresh_ms`). This mirrors the live/durable split (§7).
- **Industry grounding** (firecrawl, 2026-06-19): per-run caps, per-workflow budgets, kill
  switches, and runtime circuit breakers / safe-mode execution are the standard pattern for
  agentic-AI cost governance (AWS "Taming Runaway AI Agent Costs"; Oracle "Runtime Budget
  Guardrails for Agentic AI"; Finout "Agentic AI Cost Governance"). This feature implements the
  enforcement half of that pattern on top of the platform's existing observability half.
- **Future considerations** (out of scope here, natural follow-ups): per-harness caps; budget
  *forecasting* using `estimated_cost_usd` to refuse a step whose *projected* cost would breach
  the cap (pre-flight, not just post-hoc); email/Slack/webhook alerts on trip via the existing
  webhook machinery; per-cap schedules (Oban cron) to auto-reset daily/monthly windows; a
  budgets-only `/budgets` LiveView for a dedicated finance view.
```
