# Bug: Project palette (SLASH/AGENTS/ADWS) does not refresh when switching projects — newly-created `.claude/commands` never appear

## Metadata
issue_number: `palette-project-refresh`
adw_id: `n/a`
issue_json: `{"title":"New slash command in a project repo's .claude/commands is not shown in the Project palette tab","body":"Created /data/1.Projects/Firebird/.claude/commands/phoenix.md but it does not appear under the Project tab of the ⌘K prompt palette."}`

## Bug Description
A new slash command created in a project repo's `.claude/commands/` (concretely `/data/1.Projects/Firebird/.claude/commands/phoenix.md`) does not appear under the **Project** tab of the ⌘K prompt palette (`#palette-toggle-slash-project`).

- **Expected:** when the active brain is the Firebird project (orchestrator `working_dir = /data/1.Projects/Firebird`), the Project tab lists `phoenix` alongside the project's other `.claude/commands`. Creating or editing a file in the active project's `.claude/` is reflected without a full page reload.
- **Actual:** the Project tab is empty (or stale). The command never surfaces — neither on project switch nor live after creation.

The underlying scan is correct: `RepoBuilder.Definitions.all("/data/1.Projects/Firebird").slash_command` returns `{"phoenix", :working_dir}`. The defect is purely in *when/how the console refreshes the palette* relative to the active project's working directory.

## Problem Statement
The file-derived palette assigns (`@slash_commands`, `@agent_defs`, `@adws`) are seeded **once at mount** for the then-active orchestrator's `working_dir`, and re-seeded **only** by the 📁 CWD dir-picker path (`save_working_dir/2`). The primary way the working directory changes — selecting a project in the global switcher (`select_project` → `switch_orchestrator/2`) — updates `orchestrator_working_dir` for display but **never re-scans the palette nor refreshes the `Definitions` watcher**. As a result the palette reflects the wrong (often the default/base) working dir, and the active project's `.claude/` artifacts are missing.

## Solution Statement
In `switch_orchestrator/2` (the project-switch success path), after `assign_orchestrator_selection/2` sets the new `orchestrator_working_dir`, perform the same two steps `save_working_dir/2` already performs:

1. `Definitions.refresh(working_dir)` — point the single global `Definitions` watcher at the newly-active project's dir (updates its tracked `working_dir` + `watched_dirs`, and broadcasts a fresh listing to every connected console).
2. `seed_definitions/1` — immediately re-scan the merged (base + new working_dir) root and re-assign the three palette lists so this console's chips update without waiting on the broadcast.

This is the minimal, surgical change and reuses the exact, already-proven mechanism from `save_working_dir/2`. It fixes both the on-switch staleness and (via `refresh/1` repointing the watcher) the live-update path for subsequent edits in the active project.

## Steps to Reproduce
1. Have a project (e.g. Firebird) whose orchestrator `working_dir` is `/data/1.Projects/Firebird`.
2. In the console, select that project via the project switcher (`select_project`).
3. Create `/data/1.Projects/Firebird/.claude/commands/phoenix.md` (or have it created by an agent).
4. Open ⌘K → **Project** tab → SLASH. Observe `phoenix` is absent.
5. Even waiting >30s (the poll interval) does not surface it.

Verified via Tidewave at runtime:
- `RepoBuilder.Definitions.all("/data/1.Projects/Firebird").slash_command` ⇒ includes `{"phoenix", :working_dir}` (the scan is correct).
- `:sys.get_state(RepoBuilder.Definitions)` ⇒ `working_dir: nil`, `watched_dirs: [".../repo_builder_elixir/.claude", ".../repo_builder_elixir/adws"]`, `fs_pid: nil` (watcher is **not** tracking the project and the FileSystem watcher is not running).
- `which inotifywait` ⇒ not installed (so `file_system` falls back to the 30s poll — and that poll scans only the watcher's tracked dir, which is base-only).

## Root Cause Analysis
There are two layers; the **code defect** is layer 1.

**Layer 1 — the project-switch path never refreshes the palette (the bug).**
- `handle_event("select_project", …)` (`lib/repo_builder_web/live/console_live.ex:898`) calls `switch_orchestrator/2`.
- `switch_orchestrator/2` (`console_live.ex:294-303`) rebuilds orchestrator-scoped state — `assign_orchestrator_selection` (which sets `orchestrator_working_dir`), queue resubscribe, cost seeds, backfill — but does **not** call `seed_definitions/1` or `Definitions.refresh/1`.
- The only place that re-seeds + refreshes is `save_working_dir/2` (`console_live.ex:1981-1995`), reached solely through the 📁 CWD dir-picker. So changing the working dir *by selecting a project* leaves the palette assigns at their mount-time values (the default brain's base-repo scan), and leaves the watcher's tracked dir stale.
- `seed_definitions/1` (`console_live.ex:535`) itself is correct — it scans `Definitions.all(nilify_blank(orchestrator_working_dir))`. It simply is never invoked on project switch.

**Layer 2 — live file events don't fire in this environment (mitigated by design, not the bug).**
- The `Definitions` GenServer's FileSystem watcher requires `inotify-tools` on Linux; it is not installed here, so `fs_pid: nil` and the watcher relies on the 30s poll (`handle_info(:poll, …)` → `rescan_and_broadcast/1`).
- `rescan_and_broadcast/1` scans `resolve(state.app_root, state.working_dir)`. Because `state.working_dir` is `nil` (never refreshed for the project), the poll scans only the base repo and can never observe Firebird's new file. Once Layer 1 is fixed (switch calls `refresh/1`), the watcher's `working_dir` becomes the project dir and the poll covers it; an installed `inotify-tools` would additionally give sub-second updates. Layer 2 is therefore an environment/ops note, not a code change.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder_web/live/console_live.ex` — **primary fix site.**
  - `switch_orchestrator/2` (294-303): add the `Definitions.refresh/1` + `seed_definitions/1` steps on the success branch.
  - `save_working_dir/2` (1981-1995): the existing, correct precedent to mirror exactly.
  - `seed_definitions/1` (535): the re-scan helper (reused, unchanged).
  - `select_project` handler (898) and mount chain (258-265): context for how `active_project_id` / `orchestrator_working_dir` flow.
- `lib/repo_builder/definitions.ex` — `refresh/1` (updates the watcher's tracked dir + broadcasts), `all/1`/`resolve/2` (the merged base+overlay scan; `overlay_dir/2` normalizes overlay==app_root → nil). No change expected; relied upon.
- `BUILD_PROMPT.md` §9 (LiveView reconnect/seed discipline) — keep the "seed from source on state change" contract; this fix extends it to the project-switch transition.

### New Files
- `test/repo_builder_web/live/test_project_palette_refresh_test.exs` — `Phoenix.LiveViewTest` integration test: selecting a project re-seeds the Project tab with that project's `.claude/commands` (fails before the fix, passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Re-seed definitions + refresh the watcher on project switch
- In `lib/repo_builder_web/live/console_live.ex`, in `switch_orchestrator/2`'s `{:ok, orchestrator}` branch, after `assign_orchestrator_selection/2` (so `orchestrator_working_dir` is set) add the two steps `save_working_dir/2` already uses:
  - `:ok = Definitions.refresh(nilify_blank(orchestrator.working_dir))` (or pass `orchestrator.working_dir`; `refresh/1` accepts `String.t() | nil`).
  - Pipe through `seed_definitions/1` so this console's chips update immediately.
- Keep the pipeline shape; e.g. insert `|> tap_refresh_definitions(orchestrator)` or inline the `Definitions.refresh/1` call before the `|> seed_definitions()` pipe step. Match the surrounding style; if you add a tiny private helper give it an `@spec`.
- Do NOT add this to the `{:error, _reason}` branch (leave the current brain + palette in place on a resolve failure).
- Rationale: `refresh/1` repoints the single global watcher at the now-active project dir (fixing the poll/live path) and broadcasts to all consoles; `seed_definitions/1` gives the acting console an instant, correct re-scan.

### 2. (No change) Confirm the dir-picker path stays correct
- Verify `save_working_dir/2` still does `Definitions.refresh/1` + `seed_definitions/1`; the new switch path mirrors it. No duplication beyond the shared helper, if you extract one.

### 3. Add the LiveView regression test
- Create `test/repo_builder_web/live/test_project_palette_refresh_test.exs` (`use RepoBuilderWeb.ConnCase, async: false` so the sandbox reaches the LiveView).
- Setup: create a temp project root with `<<tmp>>/.claude/commands/<name>.md` (e.g. `projonly.md`); insert a `Project` with `root_path` = that dir and an orchestrator bound to it with `working_dir` = that dir (use the existing `Orchestrators`/`Projects` contexts/fixtures).
- Drive it:
  - `{:ok, view, _} = live(conn, ~p"/")` (default brain).
  - Assert the Project tab does NOT contain `/projonly` yet (default brain ⇒ project tab empty): switch to project tab via `view |> element("#palette-tab-project") |> render_click()` and `refute` the token.
  - `render_click` the project switcher for the new project (the `select_project` event with `project_id`), then `view |> element("#palette-tab-project") |> render_click()` and **assert** `render(view) =~ "/projonly"`.
- This fails before Step 1 (switch doesn't re-seed) and passes after.
- Optional supplementary (only if cheap): a Tidewave `browser_eval` confirming the Project tab count increments after switching to a project with a command. The LiveView test is the authoritative gate.

### 4. Run the validation commands
- Execute every command in **Validation Commands**; all must be green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder_web/live/test_project_palette_refresh_test.exs` — the new regression test (fails before, passes after).
- `mix test test/repo_builder_web/live/test_prompt_palette_test.exs test/repo_builder/definitions_test.exs test/repo_builder/definitions_watch_test.exs` — palette + definitions suites (no regression to the BASE/PROJECT tabs or the watcher).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, incl. the `@spec` gate.
- `mix dialyzer` — contract checking, no new warnings, no stale ignore filters.

Optional runtime confirmation (Tidewave, live dev server): `select_project` for Firebird, then `RepoBuilder.Definitions` `:sys.get_state` should show `working_dir: "/data/1.Projects/Firebird"`, and the Project tab SLASH row should include `phoenix`.

## Notes
- **Scope is the switch transition.** The on-demand scan (`Definitions.all/1`) and the BASE/PROJECT source split are already correct (verified at runtime). The only defect is that `switch_orchestrator/2` skips the re-seed/refresh that `save_working_dir/2` performs.
- **Environment note (not a code fix): install `inotify-tools`.** On this host `inotifywait` is absent, so `file_system` can't deliver real-time events and falls back to the 30s poll. After this fix the poll (and broadcasts) track the right dir, so a created file appears within the poll interval; installing `inotify-tools` restores sub-second live updates. Consider documenting this in the dev setup/README.
- **Pre-existing single-watcher limitation (out of scope).** `RepoBuilder.Definitions` is one global GenServer tracking ONE `working_dir`; with multiple consoles/projects open, the last `refresh/1` wins for the *watcher's* live broadcasts. Each console still re-seeds its own palette correctly on switch (Step 1), so the reported single-user bug is fully fixed; a per-console/multi-dir watcher is a larger follow-up if simultaneous multi-project live-watching is ever required.
- **Tidewave was used to root-cause** (per the build prompt): `project_eval` (`Definitions.all/1` + `:sys.get_state`) and a shell check of `inotifywait` pinpointed that the scan is correct but the watcher's tracked dir is stale and the switch path never re-seeds.
