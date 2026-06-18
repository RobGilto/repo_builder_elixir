# Feature: Cost Center price catalog — first-class CRUD

## Metadata
issue_number: `center`
adw_id: `needs`
issue_json: `to`

## Feature Description

The Cost Center settings tab (shipped in
`specs/issue-Center-adw-settings-sdlc_planner-cost-center-tab.md`) gives operators a
**price catalog** of per-model rates keyed by `(harness, provider, model)`. Today that
catalog is only *partially* CRUD:

- **Create** — the single `#price-form` inserts a new row (`upsert_price/1`).
- **Read** — `list_prices/0` renders the catalog table; `rollup/1` renders spend.
- **Update** — exists only *implicitly*: an operator must re-type the **exact**
  `(harness, provider, model)` key into the create form to land on the same row via
  `on_conflict`. There is no "edit this row" affordance, no pre-filled form, and the
  key fields are freely editable, so a typo silently creates a **second** row instead
  of editing the intended one.
- **Delete** — a per-row `✕` button deletes immediately, with **no confirmation**, so a
  misclick irreversibly drops a rate (and re-seed only restores `:seed` rows, never a
  deleted `:manual` one).

This feature makes the catalog a **complete, explicit CRUD surface**: a per-row **Edit**
action that loads the row into the form with its identity key **locked**, a clear
create-vs-edit mode with a **Cancel**, surfaced changeset validation errors, and a
**confirmed** delete. The rollup remains read-only by design (it aggregates immutable
historical `agent_logs`), so "CRUD" scopes to the editable `model_prices` catalog.

## User Story

As an **operator managing AI price rates from the Cost Center tab**
I want to **edit an existing catalog rate in place and delete with a confirmation**
So that **I can correct a rate without accidentally creating duplicate rows or losing a
rate to a misclick, and so the catalog behaves like a predictable CRUD table.**

## Problem Statement

The catalog's "update" path is a footgun: because the create form's key fields
(`harness`/`provider`/`model`) are editable and update is keyed on an exact 3-tuple
`on_conflict`, the *only* way to edit row X is to retype its key perfectly. Any deviation
(a different `provider`, a trailing space, a renamed `model`) creates a **new** row
rather than updating the intended one — the catalog accretes near-duplicate rates that
silently change which value `price_table_for/1` returns (`Map.put` last-writer-wins over
`model`, so a stray duplicate can shadow the real rate). Delete is equally unsafe: one
click on `#price-delete-<id>` removes a `:manual` rate permanently with no undo and no
re-seed recovery. There is no UI signal of *which* row (if any) is being edited, and
changeset errors from `upsert_price/1` are dropped into a generic re-render with no field
messages.

## Solution Statement

Add an explicit **edit mode** to the catalog driven entirely through the existing
`CostCenter` context (no new `Repo` callers, §8) and the existing `select_settings_tab`
/ assigns mechanism (§9):

1. **Context:** add `get_price/1` (fetch one row by id) so the LiveView can load a row to
   edit without touching `Repo`, and add a dedicated `update_price/2` (changeset update on
   a loaded row, key fields **not** cast) so an edit can never repoint the identity key.
   Keep `upsert_price/1` for create. Surface `ModelPrice.changeset/2` validation errors to
   the form.
2. **LiveView:** track an `:editing_price_id` assign. `edit_price` loads the row into
   `:price_form` and flips the form into edit mode; `cancel_edit` clears it back to a blank
   create form; `save_price` routes to `update_price/2` when editing or `upsert_price/1`
   when creating; `delete_price` gains a `data-confirm` so the browser confirms first.
3. **Component:** the form renders a header (`New price` vs `Editing <harness>/<model>`),
   locks the identity inputs while editing (readonly + a hidden id), shows a **Cancel**
   button in edit mode, renders `<.input>` field errors, and each catalog row gains an
   **Edit** button alongside the (now-confirmed) Delete.

This reuses the typed `ModelPrice` schema, the `cns-*` console styling, and the lazy
`load_cost_center/1` reload, so the change is additive and stays inside the established
patterns.

## Relevant Files

Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; §3 typed style (`@spec` on every public fn,
  precise types, `{:ok, t()} | {:error, reason()}`), §8 contexts-only-touch-`Repo`, §9
  LiveView/streams/reconnect, §13 testing. **Read before starting.**
- `AGENTS.md` — Phoenix v1.8 + LiveView conventions (`to_form/2` + `<.input>`, no
  `String.to_atom/1` on input, stable DOM ids, `data-confirm` for destructive actions).
- `.claude/commands/conditional_docs.md` — routing map; matched rows for this task: the
  **(always)** typed-standard row (`ai_docs/typed-elixir-standard.md`) and the LiveView
  row (`BUILD_PROMPT.md` §9). (No new migration/JSONB/Decimal-boundary work — the schema
  and table already exist — so the Ecto row is informational only.)
- `ai_docs/typed-elixir-standard.md` — enforced typed standard (rule 6 wire≠domain, rule
  10 float→Decimal); the edit form still casts string prices into the `:decimal` columns.
- `lib/repo_builder/cost_center.ex` — the catalog context. **Add `get_price/1` and
  `update_price/2`; keep `upsert_price/1` for create.** Sole `Repo` caller (§8).
- `lib/repo_builder/cost_center/model_price.ex` — `ModelPrice` schema + `changeset/2`
  (already validates required/inclusion/non-negative/unique, normalizes `provider`).
  **Reused as-is**; `update_price/2` calls the same changeset but the LiveView omits the
  locked key fields from the params.
- `lib/repo_builder_web/components/console_components.ex` — `price_catalog_table/1`
  (`~:1302`), `#price-form` (`~:1311`), per-row `#price-row-<id>` / `#price-delete-<id>`
  (`~:1352`, `~:1364`). **Add edit mode (header, locked inputs, Cancel, field errors) and
  a per-row Edit button; add `data-confirm` to Delete.** New attrs: `:editing_price_id`.
- `lib/repo_builder_web/live/console_live.ex` — Cost Center assigns/handlers:
  `:price_form` (`~:125`), `upsert_price`/`delete_price` (`~:875`/`~:885`),
  `load_cost_center/1` (`~:2167`), `reset_price_form/1` (`~:2175`),
  `<.settings_modal .../>` (`~:1992`). **Add `:editing_price_id` assign; add `edit_price`,
  `cancel_edit`, `save_price` handlers (rename/replace `upsert_price`); add `data-confirm`
  delete; pass `editing_price_id` into the modal.**
- `test/repo_builder/cost_center_test.exs` — existing context unit tests.
  **Add `get_price/1` and `update_price/2` cases** (happy, key-immutability, not-found,
  validation error).
- `test/repo_builder_web/live/test_cost_center_tab_test.exs` — existing LiveView test.
  **Extend with the edit-in-place + cancel + confirmed-delete flow** (or add the new file
  below if kept separate).
- `test/support/data_case.ex`, `test/support/conn_case.ex` — test cases used by the above.

### New Files

- `test/repo_builder_web/live/test_cost_center_crud_test.exs` — a focused
  `Phoenix.LiveViewTest` integration test for the new CRUD interactions (edit loads the
  row + locks the key, Cancel resets, save updates in place without creating a duplicate,
  delete carries `data-confirm`). Keeping it separate from the existing tab test isolates
  the CRUD behavior; alternatively fold these assertions into the existing file and skip
  this new file (note the choice in `Notes`).

## Implementation Plan

### Phase 1: Foundation
Extend the `CostCenter` context with the two read/update primitives the CRUD UI needs,
keeping all `Repo` access in the context (§8) and reusing the existing `ModelPrice`
changeset and its validations. No migration or schema change — the `model_prices` table
and schema already exist.

### Phase 2: Core Implementation
Add edit-mode state and handlers to `ConsoleLive` (`edit_price` / `cancel_edit` /
`save_price`), and render the create-vs-edit form, locked identity inputs, Cancel button,
inline field errors, per-row Edit button, and confirmed Delete in
`price_catalog_table/1`. Drive it all through the already-lazy `load_cost_center/1`
reload so a reconnect re-derives from the DB (§9).

### Phase 3: Integration
Wire the new assigns through `<.settings_modal .../>`, ensure the create and edit paths
both round-trip through the same `load_cost_center/1` + form-reset, and prove the flow end
to end with unit + LiveView tests plus the full green gate.

## Step by Step Tasks

IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative docs
- Read `BUILD_PROMPT.md` §3 (typed style), §8 (contexts-only-`Repo`), §9 (LiveView), §13
  (testing).
- Read `ai_docs/typed-elixir-standard.md` (rules 6 + 10) and confirm `AGENTS.md`
  conventions (`to_form/2` + `<.input>`, stable DOM ids, `data-confirm`, no
  `String.to_atom/1` on input).
- Skim the current Cost Center surface: `lib/repo_builder/cost_center.ex`,
  `lib/repo_builder/cost_center/model_price.ex`, the `price_catalog_table/1` component,
  and the `upsert_price`/`delete_price` handlers in `console_live.ex`.

### 2. Write the LiveView CRUD integration test first (red)
- Create `test/repo_builder_web/live/test_cost_center_crud_test.exs`
  (`use RepoBuilderWeb.ConnCase, async: false`; import `Phoenix.LiveViewTest`).
- Seed one `:manual` price via `CostCenter.upsert_price/1`, `live(conn, "/")`, switch to
  the Cost Center tab (`render_click(view, "select_settings_tab", %{"tab" => "cost_center"})`).
- Assert clicking `#price-edit-<id>` loads the row: the form shows an `Editing` header and
  the identity inputs are `readonly` (assert the markup), and a `#price-cancel` button is
  present.
- `render_submit` the form (changing only `output_price_per_mtok`) and assert the **same**
  row id updates (`CostCenter.get_price/1` reflects the new rate) and **no new row** is
  created (`CostCenter.list_prices/0` count unchanged).
- Assert `#price-cancel` returns the form to create mode (no `Editing` header).
- Assert `#price-delete-<id>` carries a `data-confirm` attribute.

### 3. Add `get_price/1` to the context
- In `lib/repo_builder/cost_center.ex`, add
  `@spec get_price(Ecto.UUID.t()) :: ModelPrice.t() | nil` and
  `def get_price(id), do: Repo.get(ModelPrice, id)`. (Distinct arity from the existing
  `get_price/3` key lookup.)

### 4. Add `update_price/2` to the context
- Add `@spec update_price(ModelPrice.t(), map()) :: {:ok, ModelPrice.t()} | {:error, Ecto.Changeset.t()}`.
- Implement as `price |> ModelPrice.changeset(params) |> Repo.update()`, marking
  `source: :manual` on the params (an edit is always a manual override).
- **Key immutability:** the LiveView will omit `harness`/`provider`/`model` from the
  update params (the inputs are locked), so the changeset only touches the rate columns +
  `source`. Document in the `@doc` that callers must not repoint the identity key via this
  function (use `delete_price/1` + `upsert_price/1` to move a row).

### 5. Context unit tests for the new functions
- In `test/repo_builder/cost_center_test.exs` add a `describe "get_price/1 + update_price/2"`:
  - `get_price/1` returns the row by id and `nil` for a random UUID.
  - `update_price/2` updates the rate in place (same id, new `output_price_per_mtok`),
    sets `source: :manual`, and does **not** change the count.
  - `update_price/2` with params that include a *different* `harness`/`model` still leaves
    the persisted key unchanged when those keys are omitted by the caller (assert the LiveView
    contract: passing only rate params preserves identity).
  - `update_price/2` returns `{:error, %Ecto.Changeset{}}` on a negative price.

### 6. Add edit-mode state + handlers to `ConsoleLive`
- Add `editing_price_id: nil` to the mount assigns alongside the existing Cost Center
  assigns (`~:123`).
- Replace the `"upsert_price"` handler with `"save_price"` that branches on
  `socket.assigns.editing_price_id`:
  - editing → `CostCenter.get_price/1` + `CostCenter.update_price/2`;
  - creating → `CostCenter.upsert_price/1`.
  - On success: `load_cost_center/1`, `reset_price_form/1`, and clear `:editing_price_id`.
  - On `{:error, changeset}`: re-assign `:price_form` from the changeset (keep edit mode).
- Add `handle_event("edit_price", %{"id" => id}, socket)`: load the row via
  `CostCenter.get_price/1`; if found, assign `:editing_price_id` and a `:price_form` built
  from its changeset; if `nil`, no-op (stale id after a concurrent delete).
- Add `handle_event("cancel_edit", _params, socket)`: clear `:editing_price_id` and reset
  the form.
- Keep `"delete_price"` but ensure after delete it also clears `:editing_price_id` if the
  deleted row was being edited.
- Extend `reset_price_form/1` (or add a helper) to also clear `:editing_price_id` so create
  mode is the default.
- Add `@spec`s for every new/changed private helper; update the `settings_tab` data flow
  only as needed.

### 7. Render edit mode in `price_catalog_table/1`
- In `lib/repo_builder_web/components/console_components.ex` add an
  `attr :editing_price_id, :any, default: nil` to `price_catalog_table/1` (and thread it
  from `settings_modal/1`).
- Form changes:
  - `phx-submit="save_price"` (was `upsert_price`).
  - A header: `New price` when `@editing_price_id == nil`, else
    `Editing <harness>/<model>` (read the values off `@form`).
  - When editing: render the `harness`/`provider`/`model` `<.input>`s as `readonly`
    (so the key can't drift) plus a hidden `<.input type="hidden" field={@form[:id]}>`,
    and show a `#price-cancel` button (`phx-click="cancel_edit"`).
  - Surface `<.input>` field errors (the component already renders `field.errors`).
  - Keep stable ids (`#price-form`, `#price-form-submit`, `#price-cancel`).
- Per-row changes in `#price-catalog-table`:
  - Add `<button id={"price-edit-#{p.id}"} phx-click="edit_price" phx-value-id={p.id}>`.
  - Add `data-confirm="Delete this price? Manual rates are not restored by re-seed."` to
    the existing `#price-delete-<id>` button.

### 8. Pass the new assign through the modal
- In `console_live.ex` `<.settings_modal .../>` (`~:1992`) pass
  `editing_price_id={@editing_price_id}`.
- In `console_components.ex` `settings_modal/1` add `attr :editing_price_id, :any,
  default: nil` and forward it to `<.price_catalog_table editing_price_id={@editing_price_id} ... />`.

### 9. Run the LiveView CRUD test (green)
- `mix test test/repo_builder_web/live/test_cost_center_crud_test.exs` — fix until green.

### 10. Run the full Validation Commands
- Run every command in **Validation Commands** and fix any failure until the full green
  gate passes with zero regressions. Optionally capture a Tidewave-vision/Playwright
  screenshot of `http://localhost:4000` with a row in edit mode as visual proof, and use
  Tidewave `project_eval` to sanity-check `RepoBuilder.CostCenter.update_price/2` against
  the live app.

## Testing Strategy

### Unit Tests
- `CostCenter.get_price/1`: returns the row by id; `nil` for an unknown UUID.
- `CostCenter.update_price/2`: updates rate columns in place (same id, count unchanged),
  forces `source: :manual`, returns `{:error, changeset}` on an invalid (negative) price,
  and preserves the identity key when the caller omits key fields.
- Regression: existing `upsert_price/1` create path, `delete_price/1`, `seed_prices/0`
  manual-preservation, and `rollup/1` all still pass unchanged.

### Edge Cases
- **Edit then Cancel** leaves the catalog and form untouched (create mode restored).
- **Concurrent delete** of the row currently being edited: `save_price`/`edit_price` on a
  now-missing id no-ops gracefully (no crash; `get_price/1` returns `nil`).
- **Key-immutability:** editing a row and submitting never creates a second row even if the
  (locked, readonly) key inputs were tampered with client-side — `update_price/2` operates
  on the loaded row and the omitted key params can't repoint it.
- **Validation error in edit mode** keeps the form in edit mode with the field error shown,
  not silently reset.
- **Delete confirmation:** the delete control carries `data-confirm`; a deleted `:manual`
  row stays gone after `seed_prices/0` (seed only restores `:seed` keys).
- **Reconnect** while editing: edit state is socket-local; after reconnect the tab
  re-derives from the DB in create mode (no reliance on lost state, §9).

## Acceptance Criteria

- Each catalog row exposes an **Edit** button that loads the row into the form with its
  `(harness, provider, model)` key **locked** (readonly) and an `Editing …` header.
- Submitting an edit updates the **same** row in place (no duplicate) and persists
  `source: :manual`; a **Cancel** button returns the form to create mode.
- The **Create** path (blank form) still inserts a new row via `upsert_price/1`.
- Changeset validation errors render inline on the form fields in both create and edit
  modes (no silent reset).
- The **Delete** control requires a `data-confirm` confirmation before removing a row.
- All catalog DB access remains in `RepoBuilder.CostCenter`; the LiveView/components never
  touch `Repo`/`Ecto.Query` (§8).
- The rollup table is unchanged (read-only).
- The full green gate passes with zero regressions.

## Validation Commands

Execute every command to validate the feature works correctly with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is running (once per session).
- `mix test test/repo_builder/cost_center_test.exs` — context unit tests (incl. new
  `get_price/1` + `update_price/2`).
- `mix test test/repo_builder_web/live/test_cost_center_crud_test.exs` — the new CRUD
  LiveView integration test.
- `mix test test/repo_builder_web/live/test_cost_center_tab_test.exs` — the existing tab
  test still passes (no regression).
- `mix compile --warnings-as-errors` — gradual set-theoretic types + `warnings_as_errors`.
- `mix test --warnings-as-errors` — full suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including `@spec`-on-every-public-function.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.
- (Optional, via Tidewave) `project_eval`:
  `p = RepoBuilder.CostCenter.upsert_price(%{harness: "pi", model: "crud-demo", output_price_per_mtok: "1.0"}); RepoBuilder.CostCenter.update_price(elem(p,1), %{"output_price_per_mtok" => "2.0"})`
  to confirm in-place update against the live app; capture a Playwright screenshot of
  `http://localhost:4000` with a catalog row in edit mode.

## Notes

- **No new dependency, migration, or schema change.** The `model_prices` table,
  `ModelPrice` schema, and its `changeset/2` validations already exist; this feature is
  purely context functions + LiveView/component wiring + tests.
- **Scope of "CRUD":** the editable `model_prices` catalog. The spend **rollup** is
  deliberately read-only — it aggregates immutable historical `agent_logs`, so there is
  nothing to create/update/delete there (clearing history is the separate `hidden`-flag
  CLEAR mechanism).
- **Key moves:** `update_price/2` intentionally cannot repoint a row's
  `(harness, provider, model)` identity. To "rename" a rate, delete the old row and create
  a new one — this keeps the unique key and the `price_table_for/1` lookup unambiguous.
- **Test-file choice:** the plan adds a dedicated
  `test_cost_center_crud_test.exs`; folding the assertions into the existing
  `test_cost_center_tab_test.exs` is an acceptable alternative — pick one and keep the
  Validation Commands list in sync.
- **Future considerations:** inline (per-row) editing without a shared form; optimistic
  concurrency (a `lock_version` to reject stale edits); bulk import/export (CSV) of the
  catalog; an audit trail of rate changes.
```
