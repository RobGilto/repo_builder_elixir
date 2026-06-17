# Feature: Manage the Orchestrator System Prompt from a Settings Tab

## Metadata
issue_number: `sysprompt`
adw_id: `f3a1c7e2`
issue_json: `{}` (interactive request — no GitHub issue)

## Feature Description
Add a dedicated **"System Prompt"** tab to the console Settings modal that lets the
operator view, override, and reset the orchestrator's system prompt, and choose how
that prompt is applied to the underlying harness CLI (**append** to the harness
default vs **replace** it entirely).

Today the platform already persists a per-orchestrator `system_prompt` column and the
`Orchestrator.Server` already threads `orchestrator.system_prompt || SystemPrompt.build/1`
into the harness tool-binding context. What is missing is (a) any UI to edit it and
(b) operator control over the **append-vs-replace** semantics — both adapters currently
hardcode `--append-system-prompt`. Web research against the authoritative CLI docs
confirms both harnesses support both modes programmatically:

- **Claude Code CLI** (`code.claude.com/docs/en/cli-reference`): `--system-prompt` /
  `--system-prompt-file` replace the entire default prompt; `--append-system-prompt` /
  `--append-system-prompt-file` append to it. Replace + append may be combined; the two
  replace flags are mutually exclusive.
- **pi CLI** (`github.com/earendil-works/pi` README → "Other Options"): `--system-prompt <text>`
  replaces the default prompt (context files & skills are still appended) and
  `--append-system-prompt <text>` appends. (File equivalents exist as `.pi/SYSTEM.md` /
  `APPEND_SYSTEM.md` but the flags are the programmatic path we already use.)

This feature makes the orchestrator's "brain prompt" a first-class, operator-editable
setting with correct, harness-blind append/replace semantics.

## User Story
As an **operator driving the orchestration console**
I want to **edit the orchestrator's system prompt and choose whether it appends to or
replaces the harness default, from a Settings tab**
So that **I can tune the meta-agent's behavior (tone, policies, extra rules, or a fully
custom identity) without editing code or restarting, and see exactly what prompt the
orchestrator will run with.**

## Problem Statement
The orchestrator's system prompt is generated in code (`Orchestrator.SystemPrompt.build/1`)
and, although a `system_prompt` override column exists, there is no way for an operator to
inspect or change it from the running app. Worse, the append-vs-replace decision is
hardcoded to `--append-system-prompt` in both the Claude and pi adapters, so an operator
who wants a fully custom orchestrator identity (replacing the harness's default
coding-agent prompt) cannot get it. The capability exists at the CLI layer but is not
surfaced or controllable.

## Solution Statement
1. Persist an append/replace **mode** alongside the existing `system_prompt` text on the
   `orchestrators` row (a typed `Ecto.Enum` column, default `:append` — preserving today's
   behavior).
2. Extend the harness orchestrator tool-binding contract (`Harness.Orchestrating.tool_ctx`)
   with `:system_prompt_mode`, and update the **Claude** and **pi** adapters to select the
   correct flag (`--append-system-prompt` vs `--system-prompt`) from that mode. This is the
   single harness-blind seam; no other adapter changes are needed (Fake dispatches
   in-process and ignores the prompt).
3. Add `@spec`'d context functions on `RepoBuilder.Orchestrators` to set the prompt + mode
   and to reset to the generated default, returning tagged tuples.
4. Add a **"System Prompt"** tab to the console Settings modal: a textarea bound to the
   custom override, an append/replace mode toggle, a read-only preview of the live
   generated default (so the operator sees what `build/1` produces), a **Save** action, and
   a **Reset to default** action. Wire the corresponding LiveView events/assigns.
5. Cover the change with a `Phoenix.LiveViewTest` integration test plus unit tests for the
   context functions and the two adapters' argv selection.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/orchestrator/orchestrator.ex` — the durable orchestrator schema/changeset.
  Already has `system_prompt :string`; add the new `system_prompt_mode` `Ecto.Enum` field to
  the schema, `@type t`, and `cast/3` list.
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators` context) — the ONLY `Repo`
  caller for orchestrators. Add `set_system_prompt/3`, `reset_system_prompt/1`, and a
  `default_system_prompt/1` helper (delegating to `SystemPrompt.build/1`). Mirrors the
  existing `set_provider/2`/`set_model/2` tagged-tuple pattern.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `build/1` generates the default prompt
  (tools/harnesses injected). Used unchanged as the "default/preview" source.
- `lib/repo_builder/orchestrator/server.ex` — `tool_ctx/2` resolves the effective prompt
  (`orchestrator.system_prompt || SystemPrompt.build/1`). Extend the returned map with
  `system_prompt_mode: orchestrator.system_prompt_mode`.
- `lib/repo_builder/harness/orchestrating.ex` — the optional behaviour + `tool_ctx` type.
  Add `required(:system_prompt_mode) => :append | :replace` to the `@type tool_ctx` and the
  callback doc.
- `lib/repo_builder/harness/claude.ex` — `orchestrator_spawn/2` currently emits
  `["--append-system-prompt", ctx.system_prompt]`. Switch to a mode-driven flag
  (`--append-system-prompt` vs `--system-prompt`).
- `lib/repo_builder/harness/pi.ex` — `orchestrator_spawn/2`, same change (pi supports both
  flags per the README).
- `lib/repo_builder_web/live/console_live.ex` — add the prompt assigns to
  `assign_orchestrator_selection/2`, the `save_system_prompt` / `set_system_prompt_mode` /
  `reset_system_prompt` handlers, extend `settings_tab/1` to accept `:prompt`, and pass the
  new assigns into `<.settings_modal>`.
- `lib/repo_builder_web/components/console_components.ex` — extend `settings_modal/1` attrs +
  the tab rail (`<.settings_tab_button tab={:prompt} ...>`), the `values:` list on the
  `settings_tab` attr, and add a System-Prompt tab panel (textarea form + mode toggle +
  preview + reset). Reuse `settings_field/1`.
- `test/repo_builder_web/live/test_orchestrator_thinking_toggle_test.exs` — the closest
  existing Settings-tab integration test; mirror its structure (`async: false`, `live/2`,
  `fake` harness from `config/test.exs`).
- `test/repo_builder_web/live/test_orchestrator_harness_provider_test.exs` — existing
  orchestrator-config LiveView test; reference for how header/orchestrator selection updates
  are asserted.
- `test/repo_builder/orchestrators_provider_test.exs` — existing context test for
  `Orchestrators`; mirror for the new `set_system_prompt/3` / `reset_system_prompt/1` specs.
- `config/test.exs` — registers the `fake` harness used by the LiveView tests (no change
  expected; referenced for context).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec`, `@enforce_keys`,
  precise types, tagged tuples) — the **(always)** conditional-docs row.
- `BUILD_PROMPT.md` §4.2/§4.3 (harness contract + per-harness flag mapping), §8 (persistence
  & migrations), §9 (LiveView/streams), §10 (extensibility seam).

### New Files
- `priv/repo/migrations/<timestamp>_add_system_prompt_mode_to_orchestrators.exs` — adds the
  `system_prompt_mode :string NOT NULL DEFAULT 'append'` column (Enum-as-string per §8).
  Generate with `mix ecto.gen.migration add_system_prompt_mode_to_orchestrators`.
- `test/repo_builder_web/live/test_orchestrator_system_prompt_test.exs` — `Phoenix.LiveViewTest`
  integration test for the new Settings tab.
- `test/repo_builder/harness/orchestrator_system_prompt_flag_test.exs` — unit test asserting
  the Claude and pi `orchestrator_spawn/2` argv select the correct flag per mode.

## Implementation Plan
### Phase 1: Foundation
Persist the append/replace mode and expose it through the typed context and the harness
tool-binding contract. This is the shared substrate every later phase depends on:
the schema column + migration, the `Orchestrators` context functions, the `tool_ctx` type
extension, and the `Server.tool_ctx/2` wiring.

### Phase 2: Core Implementation
Teach the two orchestrator-capable adapters (Claude, pi) to honor the mode by choosing the
right CLI flag, then build the Settings UI: a new "System Prompt" tab with a textarea form,
mode toggle, generated-default preview, Save, and Reset, plus the LiveView events/assigns.

### Phase 3: Integration
Wire the tab into the existing settings modal and `settings_tab/1` router; ensure the header
orchestrator selection reload paths also surface the prompt assigns; verify the full path
(edit → save → next `run_turn` spawns with the chosen flag) and lock it down with tests and
the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `system_prompt_mode` column (migration)
- Run `mix ecto.gen.migration add_system_prompt_mode_to_orchestrators`.
- In the migration `change/0`: `alter table(:orchestrators) do add :system_prompt_mode, :string, null: false, default: "append" end`. (Enum stored as `:string` per §8; no DB enum type.)
- Do NOT backfill — the default covers all existing rows.

### 2. Extend the orchestrator schema + changeset
- In `lib/repo_builder/orchestrator/orchestrator.ex`:
  - Add `@type mode :: :append | :replace`.
  - Add `system_prompt_mode: mode()` to `@type t`.
  - Add `field :system_prompt_mode, Ecto.Enum, values: [:append, :replace], default: :append`.
  - Add `:system_prompt_mode` to the `cast/3` field list.
  - Add `validate_inclusion(:system_prompt_mode, [:append, :replace])` (defensive; Enum already constrains).
  - Optionally `validate_length(:system_prompt, max: 100_000)` to bound textarea input.

### 3. Add context functions on `RepoBuilder.Orchestrators`
- `@spec set_system_prompt(Ecto.UUID.t(), String.t() | nil, Orchestrator.mode()) :: {:ok, Orchestrator.t()} | {:error, :not_found}` — trims the prompt, treats blank as `nil` (falls back to generated default at spawn), persists both fields via the existing `update_fields/2`.
- `@spec reset_system_prompt(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, :not_found}` — sets `system_prompt: nil, system_prompt_mode: :append` (back to today's behavior).
- `@spec default_system_prompt(Orchestrator.t()) :: String.t()` — delegates to `RepoBuilder.Orchestrator.SystemPrompt.build/1` so the LiveView can render the generated preview without reaching into another module. (Add the `alias` for `SystemPrompt`.)

### 4. Write the context unit test
- Create/extend `test/repo_builder/orchestrators_provider_test.exs` (or a new `orchestrators_system_prompt_test.exs`): assert `set_system_prompt/3` persists text + mode; blank text persists as `nil`; `reset_system_prompt/1` clears both; `{:error, :not_found}` for a bogus id; `default_system_prompt/1` returns a non-empty string mentioning a known tool/harness.

### 5. Extend the `Orchestrating.tool_ctx` contract
- In `lib/repo_builder/harness/orchestrating.ex`: add `required(:system_prompt_mode) => :append | :replace` to `@type tool_ctx`, and document it in the `@typedoc`/callback doc (which flag each adapter maps it to).

### 6. Thread the mode through `Orchestrator.Server.tool_ctx/2`
- In `lib/repo_builder/orchestrator/server.ex`, add `system_prompt_mode: orchestrator.system_prompt_mode` to the `tool_ctx/2` map (keep the existing `system_prompt: orchestrator.system_prompt || SystemPrompt.build(orchestrator)` resolution).

### 7. Update the Claude adapter
- In `lib/repo_builder/harness/claude.ex` `orchestrator_spawn/2`, replace the hardcoded
  `["--append-system-prompt", ctx.system_prompt]` with a `system_prompt_flag(ctx.system_prompt_mode)` helper returning `"--append-system-prompt"` for `:append` and `"--system-prompt"` for `:replace`. Add an `@spec`'d private helper. (Confirmed flags: both exist for Claude.)

### 8. Update the pi adapter
- In `lib/repo_builder/harness/pi.ex` `orchestrator_spawn/2`, same change: choose
  `--append-system-prompt` vs `--system-prompt` from `ctx.system_prompt_mode`. (Confirmed:
  pi supports both per its README "Other Options".) Factor the flag choice into a shared
  private helper in each adapter (do NOT cross-module share — keep each adapter self-contained
  per §10).

### 9. Write the adapter argv unit test
- Create `test/repo_builder/harness/orchestrator_system_prompt_flag_test.exs`: build a
  `tool_ctx` map (with `system_prompt: "CUSTOM"` and each mode) and call
  `Claude.orchestrator_spawn/2` and `Pi.orchestrator_spawn/2`; assert the returned args
  contain `--append-system-prompt` for `:append` and `--system-prompt` for `:replace`, each
  immediately followed by `"CUSTOM"`, and that the other flag is absent. (For Claude, write
  to a tmp `cwd` so the `.mcp.json` side effect has a real directory; use
  `System.tmp_dir!()` + a unique subdir.)

### 10. Add the LiveView integration test (early UI lock-in)
- Create `test/repo_builder_web/live/test_orchestrator_system_prompt_test.exs` (`async: false`,
  mirror the thinking-toggle test):
  - `live(conn, ~p"/")`, then `element("button[phx-value-tab=prompt]") |> render_click()` to
    open the System Prompt tab; assert the tab panel + textarea (`#settings-system-prompt`)
    render and the generated-default preview (`#settings-system-prompt-default`) is present.
  - `form("#settings-system-prompt-form", ...) |> render_submit(%{"system_prompt" => "Be terse.", "mode" => "replace"})`; then fetch the default orchestrator via
    `Orchestrators.get_or_create_default()` and assert `system_prompt == "Be terse."` and
    `system_prompt_mode == :replace`.
  - Click `#settings-system-prompt-reset`; assert the row is back to `system_prompt == nil`,
    `system_prompt_mode == :append`, and the textarea renders empty.
  - Assert the mode toggle reflects the active mode in the DOM.

### 11. Extend the `settings_modal` component
- In `lib/repo_builder_web/components/console_components.ex`:
  - Add `:prompt` to the `values:` of the `settings_tab` attr.
  - Add new attrs: `system_prompt` (`:string`, default `""`), `system_prompt_mode` (`:atom`,
    default `:append`, `values: [:append, :replace]`), `default_system_prompt` (`:string`,
    default `""`).
  - Add `<.settings_tab_button tab={:prompt} active={@settings_tab} label="System Prompt" />`
    to the tab rail.
  - Add a `:if={@settings_tab == :prompt}` panel: a `<.form id="settings-system-prompt-form"
    phx-submit="save_system_prompt">` containing a `<textarea id="settings-system-prompt"
    name="system_prompt">` (value = `@system_prompt`), a hidden/segmented mode control
    (append/replace) using `phx-click="set_system_prompt_mode"` styled like the existing
    `cns-toggle`, a **Save** submit button, a **Reset to default** button
    (`id="settings-system-prompt-reset"` `phx-click="reset_system_prompt"`), and a read-only
    `<pre id="settings-system-prompt-default" phx-no-curly-interpolation>` preview of
    `@default_system_prompt`. Use `<.settings_field>` for labels. Keep all element ids unique
    (no clash with header controls).

### 12. Wire LiveView assigns + handlers in `console_live.ex`
- In `assign_orchestrator_selection/2`, add:
  `orchestrator_system_prompt: orchestrator.system_prompt || "",`
  `orchestrator_system_prompt_mode: orchestrator.system_prompt_mode,`
  `orchestrator_default_prompt: Orchestrators.default_system_prompt(orchestrator)`.
- Add these keys to the initial `assign(...)` in `mount/3` (defaults: `""`, `:append`, `""`)
  so the disconnected render is safe.
- Add handlers (all returning `{:noreply, ...}`, reusing `update_orchestrator/3` where it fits):
  - `handle_event("save_system_prompt", %{"system_prompt" => text} = params, socket)` — read
    `mode` from params (default the current assign), call
    `Orchestrators.set_system_prompt(id, nilify_blank(text), mode)`, re-reflect via
    `assign_orchestrator_selection/2`, flash on error.
  - `handle_event("set_system_prompt_mode", %{"mode" => mode}, socket)` — persist the mode
    immediately (call `set_system_prompt/3` with the current stored text) OR keep it as a
    transient assign until Save; choose persist-immediately for consistency with the other
    settings, and re-reflect.
  - `handle_event("reset_system_prompt", _params, socket)` — call
    `Orchestrators.reset_system_prompt(id)`, re-reflect.
- Extend `settings_tab/1` to map `"prompt" -> :prompt` and update its `@spec` return union to
  `:general | :appearance | :about | :prompt`.
- Pass the three new assigns into `<.settings_modal ...>` in `render/1`.
- Add a `@spec`'d `system_prompt_mode/1` string→atom guard (`"replace" -> :replace`, `_ -> :append`)
  mirroring `to_chat_width/1`, and use it in the handlers (never `String.to_atom/1` on input).

### 13. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green.

## Testing Strategy
### Unit Tests
- **Context (`Orchestrators`)**: `set_system_prompt/3` persists text+mode; blank → `nil`;
  `reset_system_prompt/1` restores `nil`/`:append`; `{:error, :not_found}` for unknown id;
  `default_system_prompt/1` returns a non-empty generated prompt.
- **Adapters (`Claude`, `Pi`)**: `orchestrator_spawn/2` emits `--append-system-prompt` for
  `:append` and `--system-prompt` for `:replace`, each followed by the prompt text; the
  unused flag never appears; existing args (`--mcp-config`/`--strict-mcp-config` for Claude,
  `-e <ext>` for pi, resume args) are preserved.
- **Schema/changeset**: a changeset with an invalid `system_prompt_mode` is rejected
  (Ecto.Enum/`validate_inclusion`); default is `:append`.

### Edge Cases
- Blank/whitespace-only custom prompt → stored as `nil`; spawn falls back to the generated
  default (today's behavior) under the chosen mode.
- `:replace` mode with no custom prompt → the **generated orchestrator prompt** replaces the
  harness default (drops Claude's/pi's default coding-agent base, including their tool/safety
  guidance). This is an intentional operator choice; document it in the panel help text.
- Harness switch (Claude ⇄ pi) preserves `system_prompt`/`system_prompt_mode` (they are
  orchestrator-level, not harness-level) — `apply_harness_defaults/2` must NOT clear them
  (verify it doesn't; it only touches harness/provider/model/session_id).
- Disconnected mount render (mount runs twice) must not crash — the initial `assign/2`
  provides safe defaults before `assign_orchestrator/1` runs on the connected socket.
- Very long prompt — bounded by the optional `validate_length(:system_prompt, max: 100_000)`.
- Reset is idempotent (resetting an already-default orchestrator returns `{:ok, _}`).

## Acceptance Criteria
- A "System Prompt" tab appears in the console Settings modal with a textarea, an
  append/replace mode toggle, a Save button, a Reset-to-default button, and a read-only
  preview of the generated default prompt.
- Saving a custom prompt + mode persists to the `orchestrators` row (verifiable via
  `Orchestrators.fetch/1`), and the next `OrchestratorServer.run_turn/2` spawns the harness
  with the correct flag: `--append-system-prompt <text>` (append) or `--system-prompt <text>`
  (replace) for both Claude and pi.
- Reset clears the override (`system_prompt: nil`, `system_prompt_mode: :append`) and the UI
  reflects the empty textarea.
- The default mode is `:append`, so existing orchestrators behave exactly as before the
  change (no regression in `tool_ctx`/spawn argv when nothing is customized).
- All five green-gate commands pass, plus the new LiveView and unit tests.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the new `system_prompt_mode` migration cleanly (and confirm
  `mix ecto.rollback` then `mix ecto.migrate` round-trips).
- `mix test test/repo_builder_web/live/test_orchestrator_system_prompt_test.exs` — the new
  LiveView integration test passes.
- `mix test test/repo_builder/harness/orchestrator_system_prompt_flag_test.exs` — the adapter
  argv unit test passes.
- `mix test test/repo_builder/orchestrators_provider_test.exs` — context tests pass (including
  the new prompt functions).
- `mix compile --warnings-as-errors` — clean compile under the gradual type checker.
- `mix test --warnings-as-errors` — full suite green.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean (every new public function has an `@spec`).
- `mix dialyzer` — no new contract warnings, no stale ignore filters (the `tool_ctx` map type
  change must keep Claude/pi `orchestrator_spawn/2` consistent with the behaviour).

Optional runtime validation via **Tidewave** (`http://localhost:4000/tidewave/mcp`):
- `project_eval`: `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |> RepoBuilder.Orchestrators.default_system_prompt()` to eyeball the generated default.
- `execute_sql_query`: `select system_prompt, system_prompt_mode from orchestrators;` to
  confirm a saved override persisted with the chosen mode.
- Optionally screenshot `http://localhost:4000` (open Settings → System Prompt) via Tidewave
  Web vision mode or the Playwright MCP tools as visual proof.

## Notes
- **No new dependencies.** Everything uses existing libs (Ecto, Phoenix LiveView, typedstruct
  contract). No `mix.exs` change.
- **Research provenance (firecrawl, 2026-06-17):** Claude flags from
  `https://code.claude.com/docs/en/cli-reference` ("System prompt flags" — four flags,
  replace/append, mutually-exclusive replacements); pi flags from the
  `github.com/earendil-works/pi` coding-agent README "Other Options"
  (`--system-prompt` replace, `--append-system-prompt` append) and "System Prompt" section
  (`.pi/SYSTEM.md` / `APPEND_SYSTEM.md` file equivalents). Both harnesses support both modes,
  so the append/replace toggle maps cleanly and harness-blind.
- **Existing groundwork reused:** the `orchestrators.system_prompt` column and
  `Server.tool_ctx/2` resolution already exist — this feature adds the *mode*, the *context
  API*, the *adapter flag selection*, and the *UI*. The effective-prompt fallback
  (`custom || build/1`) is unchanged.
- **Extensibility:** because the mode flows through the `Orchestrating.tool_ctx` seam, a
  future orchestrator-capable harness only needs to map `system_prompt_mode` to its own
  replace/append flags in its `orchestrator_spawn/2` — consistent with the §10 "one module"
  promise. Document the mapping in `Orchestrating`'s callback doc.
- **Future consideration:** a per-worker (non-orchestrator) system-prompt override could
  reuse the same mode column pattern on `agents`, but that is out of scope here.
