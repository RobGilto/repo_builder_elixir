# Feature: Timezone setting with local-time rendering of log timestamps

## Metadata
issue_number: `a`
adw_id: `timezone`
issue_json: `in`

## Feature Description
Add a **Timezone** setting to the console so every timestamp in the dashboard renders
in the operator's chosen local timezone instead of UTC. Today the center log stream
renders the persisted UTC `inserted_at` as a bare wall-clock `HH:MM:SS` string
(`Calendar.strftime(at, "%H:%M:%S")`), and live (non-backfill) rows stamp
`Time.utc_now()` at render time — so there is no date, no timezone, and the live/backfill
paths disagree. This feature:

1. **Persists** a chosen IANA timezone (e.g. `Australia/Sydney`, `America/New_York`,
   `UTC`) on the singleton default orchestrator, surviving reconnect.
2. **Supports full UTC `DateTime`** end-to-end (not "just time") so timestamps can be
   correctly shifted — the live path stops stamping a bare `Time` and carries a real
   `DateTime` (UTC) like the backfill path does.
3. **Renders in the configured local timezone** at every display point (center log
   rows, live-appended rows, the chat entry timestamp), as `YYYY-MM-DD HH:MM:SS` in
   the chosen zone.
4. Keeps the **center ("middle") log stream ordered by datetime ascending** (oldest at
   top, newest at the bottom where new rows append) — verified and locked with a test.

## User Story
As an operator running orchestrators and ADWs from the console
I want log timestamps shown in my own timezone (with the date), persisted across sessions
So that I can correlate events with my wall clock and external systems without doing UTC math in my head

## Problem Statement
- The center log stream formats only **time** in **UTC** (`log_time/1` →
  `Calendar.strftime(at, "%H:%M:%S")` at `lib/repo_builder_web/live/console_live.ex`),
  with no date and no timezone — ambiguous across midnight boundaries and wrong for any
  non-UTC operator.
- Live (non-backfill) rows stamp `Time.utc_now()` (`now_hms/0`, `now_hm/0`) at render
  time, which is a `Time` (not the canonical persisted `DateTime`) and also UTC — so the
  live path and the backfill path use different sources and neither honors a timezone.
- There is **no persisted display preference** for timezone. Most General-tab toggles
  (`auto_follow?`, `show_thinking?`, `show_hidden?`) live only in `socket.assigns` and are
  lost on reconnect; only DB-backed settings (`reasoning_effort`, `system_prompt`) persist.
- Elixir's `DateTime.shift_zone/2` requires a configured **time zone database**, and the
  project currently has **none** (no `tz`/`tzdata` dep, no `config :elixir,
  :time_zone_database`), so arbitrary IANA conversions are impossible today.

## Solution Statement
- Add a pure-Elixir time zone database dependency (**`tz`**, compiles IANA data at build
  time, no runtime data fetch) and wire it as Elixir's default `:time_zone_database`, so
  `DateTime.shift_zone/2` works for any IANA zone.
- Introduce a small, `@spec`'d display helper module `RepoBuilder.Timezones` that owns the
  curated zone list, the default (`"UTC"`), validation, and the **single** UTC→local
  conversion + formatting functions. LiveView/components call only this module — no
  ad-hoc `Calendar.strftime`/`DateTime` math scattered around.
- Persist the chosen timezone on the singleton default orchestrator's `metadata`
  (`metadata["timezone"]`), mirroring the existing `recent_models`/`agent_models` JSONB
  precedent — **no migration**. Add `Orchestrators.timezone/1` (default `"UTC"`) and
  `Orchestrators.set_timezone/2` (validated against the curated list, atomic
  read-merge-write like `set_agent_model/3`), and broadcast the orchestrator update so an
  open console re-renders.
- Read the timezone on `mount` into a `:timezone` assign; thread it into the row builder
  and components. Make the live path carry a real UTC `DateTime` and format it through
  `Timezones`. On change, reassign `:timezone` and rebuild the center stream (reset) so
  already-rendered rows re-format in the new zone — reusing the existing backfill path
  that `toggle_show_hidden` already uses.
- The center stream is **already** ascending by `(inserted_at, id)` (DB `desc` + `Enum.reverse`
  in `Logs.list_recent_global/2`/`list_recent/2`); lock this with an explicit context test.
  Display-zone conversion does not change DB ordering (UTC `inserted_at` is the sort key).

## Relevant Files
Use these files to implement the feature:

- `mix.exs` — add the `{:tz, "~> 0.28"}` dependency (pin per `BUILD_PROMPT.md` §2) to
  `deps/0`. No other dep touched.
- `config/config.exs` — add `config :elixir, :time_zone_database, Tz.TimeZoneDatabase` so
  `DateTime.shift_zone/2` resolves IANA zones app-wide (dev/test/prod).
- `lib/repo_builder/orchestrator.ex` — the `Orchestrators` context (sole `Repo` caller for
  orchestrators). Add `timezone/1` accessor (reads `metadata["timezone"]`, default `"UTC"`)
  and `set_timezone/2` (validated; atomic read-merge-write into `metadata` using the same
  `Repo.transaction` + `FOR UPDATE` + `merge_*!` pattern as `set_agent_model/3`/
  `merge_agent_model!/3`, then `broadcast_orchestrator_updated`). Mirrors `recent_models`.
- `lib/repo_builder/orchestrator/orchestrator.ex` — Ecto schema; `metadata` JSONB already
  exists (`field :metadata, :map, default: %{}`). No schema change; confirm the changeset
  casts `:metadata` (it does for `agent_models`/`recent_models`).
- `lib/repo_builder_web/live/console_live.ex` — the console LiveView.
  - `mount/3` (`@assigns` block ~`console_live.ex:60-101`) — add `timezone: "UTC"` default;
    `assign_orchestrator_selection/2` (~`:128-141`) — read `Orchestrators.timezone(orchestrator)`
    into the `:timezone` assign (this is the persistence read-back, like `reasoning_effort`).
  - `log_time/1` (~`:2019-2021`) — replace bare-UTC `%H:%M:%S` with a zone-aware datetime
    format via `RepoBuilder.Timezones`. Rename/repurpose to carry the configured zone.
  - `log_to_row/3` (~`:2003`) and the row stream — thread the timezone in so each row's
    `time` field is formatted in the local zone.
  - `now_hms/0` (~`:2107`) and `now_hm/0` (~`:2110`) — stop using `Time.utc_now()`; build
    from `DateTime.utc_now()` and format through `Timezones` with the configured zone.
  - Add a `handle_event("set_timezone", %{"timezone" => tz}, socket)` that persists via
    `Orchestrators.set_timezone/2`, reassigns `:timezone`, and rebuilds the center stream
    (reuse the backfill helper `toggle_show_hidden` uses so rendered rows re-format).
  - The `{:orchestrator_updated, orchestrator}` handler — pick up the new `timezone` so a
    change from another tab/session reflects live (mirror how it reflects other fields).
- `lib/repo_builder_web/components/console_components.ex` — render the new control.
  - `settings_modal/1` General tab (~`:847-910`) — add a **Timezone** `<select>`
    (`id="settings-timezone"`, `phx-change="set_timezone"`, options from
    `RepoBuilder.Timezones.list/0`, current = `@timezone`), following the existing
    `settings_field`/`set_chat_width`/reasoning-effort control patterns. Add `attr :timezone`.
  - `format_relative_time/1` (~`:1327`) is relative and timezone-agnostic — leave as-is.
- `lib/repo_builder/logs.ex` — `list_recent_global/2` (~`:88-95`) and `list_recent/2`
  (~`:70-77`) already yield ascending `(inserted_at, id)` via `order_by desc + Enum.reverse`.
  Read-only confirmation; the ascending-order regression test targets these.
- `lib/repo_builder/logs/agent_log.ex` — schema; `inserted_at` (`DateTime`, UTC) is the
  canonical timestamp (`timestamps()`), no custom time field. Read-only confirmation.
- `BUILD_PROMPT.md` §3 (typed standard), §8 (persistence/contexts/JSONB), §9 (LiveView
  dashboard/reconnect) — authoritative constraints.
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions for the LiveView test and components.
- `.claude/commands/conditional_docs.md` routing — matched rows for this task:
  - *(always)* → `ai_docs/typed-elixir-standard.md` (typed coding standard).
  - *Ecto schemas, migrations, contexts, JSONB…* → `BUILD_PROMPT.md` §8;
    `ai_docs/typed-elixir-standard.md` (rule 10).
  - *The LiveView dashboard, streams, reconnect handling…* → `BUILD_PROMPT.md` §9; `AGENTS.md`.
  - *Tests, Mox, the FakeHarness…* → `BUILD_PROMPT.md` §13.

### New Files
- `lib/repo_builder/timezones.ex` — the display-zone helper module: curated IANA zone
  list, `default/0` (`"UTC"`), `valid?/1`, and the single conversion/format functions
  (`to_local/2`, `format_datetime/2`, `format_time/2`). Fully `@spec`'d; no `Repo` access.
- `test/repo_builder/timezones_test.exs` — unit tests for conversion, formatting, default,
  validation, and DST/edge handling.
- `test/repo_builder/orchestrators_timezone_test.exs` — context tests for `timezone/1`
  (default + round-trip), `set_timezone/2` (valid persists + broadcasts; invalid rejected;
  atomic with no clobber of sibling `metadata` keys).
- `test/repo_builder_web/live/test_timezone_setting_test.exs` — `Phoenix.LiveViewTest`
  integration test: mount, change the timezone select, assert it persists to the DB,
  assert a seeded log row renders its timestamp in the chosen zone (offset applied), and
  assert it survives a remount (reconnect) by reading the persisted value back.
- (Test-only addition; no new file) extend the logs context test with an explicit
  ascending-by-datetime ordering assertion for `list_recent_global/2`.

## Implementation Plan
### Phase 1: Foundation
Add the time zone database so conversions are even possible, and build the single
display-helper module that owns all zone logic. Persist the setting in the context.

### Phase 2: Core Implementation
Wire the timezone into the LiveView: read it on mount, render every timestamp through the
helper, make the live path carry a UTC `DateTime`, and add the settings control + event.

### Phase 3: Integration
Re-render existing rows on change, reflect cross-session updates via PubSub, lock the
ascending-datetime ordering, and validate end-to-end with tests + Tidewave.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative context
- Read `BUILD_PROMPT.md` §3 (typed standard), §8 (persistence/contexts/JSONB), §9 (LiveView
  dashboard & reconnect), §13 (testing).
- Read `ai_docs/typed-elixir-standard.md` (rules 1, 5, 10).
- Re-read `lib/repo_builder/orchestrator.ex` (`metadata`, `agent_models/1`,
  `set_agent_model/3`, `merge_agent_model!/3`, `recent_models/2`, `update_fields/2`,
  `broadcast_orchestrator_updated`), `lib/repo_builder_web/live/console_live.ex`
  (`mount/3`, `assign_orchestrator_selection/2`, `log_time/1`, `log_to_row/3`, `now_hms/0`,
  `now_hm/0`, the `{:orchestrator_updated, _}` handler, the `toggle_show_hidden` backfill
  path), and `lib/repo_builder/logs.ex` (`list_recent_global/2`, `list_recent/2`).

### 2. Add the time zone database dependency and config
- In `mix.exs` `deps/0`, add `{:tz, "~> 0.28"}` (pin per §2). Run `mix deps.get` and
  `mix deps.compile tz`.
- In `config/config.exs`, add `config :elixir, :time_zone_database, Tz.TimeZoneDatabase`
  (app-wide; covers dev/test/prod). Verify `DateTime.shift_zone(DateTime.utc_now(),
  "Australia/Sydney")` returns `{:ok, _}` (Tidewave `project_eval`).
- Report the new dependency in the `Notes` section.

### 3. Create `RepoBuilder.Timezones` (the single display-zone helper)
- New file `lib/repo_builder/timezones.ex`. No `Repo`/`Ecto` access (display-only).
- Define a curated `@timezones` list of common IANA names with `"UTC"` first, e.g.
  `["UTC", "America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Berlin",
  "Asia/Kolkata", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland"]`
  (curated, not the full tz set, to keep the dropdown usable — note this in `Notes`).
- Public, `@spec`'d functions:
  - `list() :: [String.t()]` — the curated zones (dropdown source).
  - `default() :: String.t()` — `"UTC"`.
  - `valid?(String.t()) :: boolean()` — membership in `list/0`.
  - `to_local(DateTime.t(), String.t()) :: DateTime.t()` — `DateTime.shift_zone/2`;
    on `{:error, _}` (unknown/invalid zone) fall back to the original UTC datetime
    (defensive — never raise in a render path).
  - `format_datetime(DateTime.t(), String.t()) :: String.t()` — `to_local/2` then
    `Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")`.
  - `format_time(DateTime.t(), String.t()) :: String.t()` — `to_local/2` then
    `Calendar.strftime(local, "%H:%M:%S")` (used where a compact time is preferred).
- Add `@moduledoc`, `@type`/precise specs; no `any()`/`map()`.

### 4. Add timezone persistence to the `Orchestrators` context
- In `lib/repo_builder/orchestrator.ex`:
  - `@spec timezone(Orchestrator.t()) :: String.t()` — return
    `Map.get(metadata, "timezone")` if it is a valid `RepoBuilder.Timezones.valid?/1`
    value, else `RepoBuilder.Timezones.default()`.
  - `@spec set_timezone(Ecto.UUID.t(), String.t()) :: {:ok, Orchestrator.t()} | {:error,
    :not_found | :invalid_timezone}` — reject non-`valid?` input with `:invalid_timezone`;
    otherwise atomically merge `metadata["timezone"]` using the **same** transactional
    `FOR UPDATE` read-merge-write pattern as `set_agent_model/3` (extract a
    `merge_metadata!/3` helper or reuse the established shape), then
    `RepoBuilder.Dashboard.broadcast_orchestrator_updated/1` on success (outside the
    transaction). Do not clobber sibling `metadata` keys (`agent_models`/`recent_models`).
  - Keep all other public functions and specs unchanged.

### 5. Context tests for the timezone setting (Fix the contract early)
- New `test/repo_builder/orchestrators_timezone_test.exs`:
  - `timezone/1` returns `"UTC"` for a fresh orchestrator and the stored value after set.
  - `set_timezone/2` with a valid zone persists `metadata["timezone"]`, returns `{:ok, _}`,
    and broadcasts `{:orchestrator_updated, _}` on `"console:events"`.
  - `set_timezone/2` with an invalid zone returns `{:error, :invalid_timezone}` and does
    not mutate `metadata`.
  - `set_timezone/2` preserves a pre-existing `metadata["agent_models"]`/`recent_models`
    entry (no clobber) — guards the atomic merge.
  - unknown id → `{:error, :not_found}`.
- New `test/repo_builder/timezones_test.exs`:
  - `to_local/2` shifts a known UTC instant into a known offset (e.g. a fixed
    `~U[2026-06-18 00:00:00Z]` into `Australia/Sydney` and `America/New_York`), asserting
    the resulting wall-clock hour.
  - `format_datetime/2` / `format_time/2` produce the expected strings for those instants.
  - `default/0` is `"UTC"`; `valid?/1` true for a listed zone, false for `"Mars/Olympus"`;
    `to_local/2` with an invalid zone returns the original datetime (no raise).

### 6. LiveView: read + thread the timezone, render in local zone
- In `lib/repo_builder_web/live/console_live.ex`:
  - Add `timezone: RepoBuilder.Timezones.default()` to the `mount/3` assigns block.
  - In `assign_orchestrator_selection/2`, add `timezone: Orchestrators.timezone(orchestrator)`
    so the persisted value is read on mount (this is the persistence read-back).
  - Replace `log_time/1` UTC formatting with a zone-aware datetime: format the row's
    `inserted_at` via `RepoBuilder.Timezones.format_datetime(at, timezone)`; thread the
    `timezone` from assigns through `log_to_row/3` into each row's `time` field.
  - Change `now_hms/0` and `now_hm/0` to build from `DateTime.utc_now()` and format through
    `RepoBuilder.Timezones` with the configured zone (carry the real UTC `DateTime`, not a
    bare `Time`) — and pass the assign-held timezone in. Update their callers (live row at
    ~`:1365`, chat entry at ~`:1405`).
  - Keep all `@spec`s precise; the row map shape is otherwise unchanged.

### 7. LiveView: the `set_timezone` event + cross-session reflection
- Add `handle_event("set_timezone", %{"timezone" => tz}, socket)`:
  - Persist via `Orchestrators.set_timezone(socket.assigns.orchestrator_id, tz)`.
  - On `{:ok, _}`: `assign(socket, :timezone, tz)` and **rebuild the center stream** so
    already-rendered rows re-format in the new zone — reuse the same backfill/restream
    helper `toggle_show_hidden` uses (stream `:events` reset with the rebuilt rows).
  - On `{:error, _}`: no-op (`{:noreply, socket}`); the select snaps back to `@timezone`.
- In the `{:orchestrator_updated, orchestrator}` handler, also pick up the (possibly
  changed) `timezone` and re-format the stream, so a change made in another tab/session is
  reflected live (mirror how the handler already reflects other orchestrator fields).

### 8. Render the Timezone control in the settings modal
- In `lib/repo_builder_web/components/console_components.ex` `settings_modal/1` General tab,
  add a `.settings_field label="Timezone"` containing a `<select id="settings-timezone"
  name="timezone" phx-change="set_timezone">` whose options come from
  `RepoBuilder.Timezones.list/0`, with `selected={@timezone == tz}`. Add `attr :timezone,
  :string, default: "UTC"` to the component and pass `timezone={@timezone}` from the
  LiveView render (alongside the existing `reasoning_effort`/`chat_width` passes).
- Add a short helper caption (like the reasoning-effort one) explaining timestamps render
  in this zone and the setting persists.

### 9. LiveView integration test (drives the UI, asserts persistence + local rendering)
- New `test/repo_builder_web/live/test_timezone_setting_test.exs` (`use
  RepoBuilderWeb.ConnCase`, `import Phoenix.LiveViewTest`):
  - Mount `~p"/"`; obtain `orchestrator_id` from the live socket assigns (as existing tests
    do via `:sys.get_state/1`).
  - Seed a log via the `Logs` context (or insert) with a **known** `inserted_at`
    (e.g. `~U[2026-06-18 00:30:00Z]`) so the rendered local time is deterministic.
  - Change the timezone: `view |> element("#settings-timezone") |> render_change(%{"timezone"
    => "Australia/Sydney"})` (or push the `set_timezone` event).
  - Assert the DB persisted: `Orchestrators.timezone(reload) == "Australia/Sydney"`.
  - Assert the rendered center stream shows the seeded row's timestamp in the chosen zone
    (e.g. the Sydney-local `2026-06-18 10:30:00`, offset applied — not the UTC `00:30:00`).
  - Assert a **negative**: the bare UTC `00:30:00` is not what renders for that row.
  - Remount the LiveView (fresh `live/2`) and assert `:timezone` assign / rendered control
    reflects the persisted `"Australia/Sydney"` (reconnect persistence).
- Optionally capture a Playwright screenshot of `http://localhost:4000` with the settings
  modal open showing the Timezone control as visual proof.

### 10. Lock the ascending-by-datetime ordering of the center log stream
- In the existing logs context test (e.g. `test/repo_builder/logs_*` — locate the file
  covering `list_recent_global/2`/`list_recent/2`; add if absent), insert ≥3 logs with
  out-of-order `inserted_at` and assert `Logs.list_recent_global/2` returns them ascending
  by `(inserted_at, id)` (oldest first). This locks the "middle logs ordered by datetime
  ascending" requirement against future regressions; no production change expected (the
  `desc + Enum.reverse` already yields this).

### 11. Run the full validation suite
- Run every command in **Validation Commands** and fix any failure until all are green.
- Confirm the new context, unit, and LiveView tests pass and there are zero regressions.
- Tidewave runtime checks (optional but preferred): `project_eval` to confirm
  `DateTime.shift_zone/2` works and `Orchestrators.set_timezone/2` round-trips;
  `execute_sql_query` (`select metadata->'timezone' from orchestrators`) to inspect the
  persisted value; `get_logs` if any stacktrace appears.

## Testing Strategy
### Unit Tests
- `RepoBuilder.Timezones`: `to_local/2` offset correctness for multiple zones (incl. a
  Southern-Hemisphere zone and UTC), `format_datetime/2`/`format_time/2` string output,
  `default/0`, `valid?/1`, and the invalid-zone fallback (returns original, no raise).
- `Orchestrators.timezone/1`/`set_timezone/2`: default, valid round-trip + broadcast,
  invalid rejection, atomic no-clobber of sibling `metadata` keys, unknown-id `:not_found`.
- `Logs`: `list_recent_global/2` ascending-by-`(inserted_at, id)` ordering.

### Edge Cases
- Invalid/unknown timezone string submitted from the UI → context rejects
  (`:invalid_timezone`), LiveView no-ops, select snaps back to current; render path never
  raises (helper falls back to UTC).
- DST boundary: converting a UTC instant during a DST transition for a zone that observes
  DST yields the correct local wall clock (tz handles this — assert one DST and one
  non-DST instant for the same zone).
- Reconnect: after a full LiveView remount, the persisted timezone is re-read on mount (not
  reset to UTC) — distinguishes this from the ephemeral assigns-only toggles.
- Live vs backfill parity: a live-appended row and a backfilled row for the same instant
  render the same local timestamp (both now flow from a UTC `DateTime` through `Timezones`).
- Cross-session: changing the timezone in one browser tab reflects in another open console
  via the `{:orchestrator_updated, _}` broadcast.

## Acceptance Criteria
- A **Timezone** `<select>` appears in the settings modal General tab, listing the curated
  zones, defaulting to `UTC`, with the current value selected.
- Selecting a timezone **persists** it (`metadata["timezone"]` on the default orchestrator)
  and it **survives reconnect** (re-read on mount; not lost like the assigns-only toggles).
- Every console timestamp (center backfilled rows, live-appended rows, chat entry) renders
  as `YYYY-MM-DD HH:MM:SS` in the **configured local timezone**, derived from the canonical
  UTC `DateTime` (the live path no longer stamps a bare UTC `Time`).
- The center ("middle") log stream is ordered by **datetime ascending** (`(inserted_at,
  id)`), verified by a context test.
- `DateTime.shift_zone/2` works app-wide (time zone database configured); the render path
  never raises on a bad zone (defensive fallback to UTC).
- All Validation Commands pass with zero regressions; `mix dialyzer` shows no new warnings
  and the `set_timezone/2` contract is `{:ok, Orchestrator.t()} | {:error, :not_found |
  :invalid_timezone}`.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix deps.get` — fetch the new `tz` dependency.
- `mix test test/repo_builder/timezones_test.exs` — timezone helper unit tests.
- `mix test test/repo_builder/orchestrators_timezone_test.exs` — context persistence tests
  (default, round-trip, invalid, atomic no-clobber, broadcast).
- `mix test test/repo_builder_web/live/test_timezone_setting_test.exs` — LiveView
  integration test (UI change → persist → local-time render → reconnect persistence).
- `mix test` (the logs ordering test included) — full suite for the ascending-order lock.
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker +
  `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" rule.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

## Notes
- **New dependency:** `{:tz, "~> 0.28"}` (pure-Elixir IANA time zone database, compiled at
  build time — no runtime data fetch, unlike `tzdata`). Configured as Elixir's default time
  zone database via `config :elixir, :time_zone_database, Tz.TimeZoneDatabase` in
  `config/config.exs`. If a newer minor is current at implementation time, pin the latest
  `~> 0.x` and note it. Verify with Tidewave `get_docs`/`project_eval` against the live app.
- **Why `metadata["timezone"]`, not a new column:** mirrors the existing `recent_models`/
  `agent_models` JSONB precedent on the singleton orchestrator — no migration, and
  `set_timezone/2` reuses the proven atomic `FOR UPDATE` read-merge-write from
  `set_agent_model/3` (which itself fixed a lost-update race for `metadata` writes). If a
  future feature wants a first-class typed column, the setter/accessor seam makes that a
  contained change.
- **Why a curated zone list, not the full IANA set:** the full set is ~600 zones — unusable
  in a dropdown. The curated `Timezones.list/0` covers common operator zones; extending it
  is a one-line edit. (If a full searchable picker is later desired, that is a separate
  feature, e.g. a typeahead backed by `tz`'s zone list.)
- **Ordering is display-agnostic:** the center stream already orders ascending by the UTC
  `inserted_at` (`desc` query + `Enum.reverse` in `Logs.list_recent_global/2`); changing the
  *display* zone does not change the sort. The new test simply locks that invariant.
- **`format_relative_time/1`** in `console_components.ex` (the agent-models "last changed"
  label) is relative ("5m ago") and timezone-agnostic — intentionally left unchanged.
- **Scope discipline:** other UTC display points outside the console log stream are out of
  scope; the `Timezones` helper is the seam to extend if they need localizing later.
```

