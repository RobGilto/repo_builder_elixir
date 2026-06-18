# Feature: File-driven prompt palette (ADWs · slash commands · agents)

## Metadata
issue_number: `prompt`
adw_id: `palette`
issue_json: `surface`

## Feature Description
The ⌘K orchestration prompt UI currently shows availability as **static info pills**: a copyable harness list, plain-text agent names, and a single **hardcoded** example string `"plan → build → review"`. The ADW Builder palette is likewise a hardcoded literal `~w(plan patch build test review document ship)`, and workflow types live as three literal `%TypeDef{}` structs in `WorkflowEngine.Catalog`. Slash commands exist on disk as `.claude/commands/**/*.md` but are read **only** by the Python `adws/` harness — never by `lib/`. Nothing in the app watches the filesystem.

This feature makes the prompt UI surface **live, file-derived** lists of three definition categories as **clickable chips that append a token into the prompt textarea**:

- **Slash commands** — scanned from `.claude/commands/**/*.md` (frontmatter-parsed; subdirs namespaced with `:`).
- **Agents** — agent templates from the existing `Orchestrator.Templates` roots (`priv/orchestrator/agents` + `~/.repo_builder/agents`), plus the working dir's `.claude/agents/*.md`.
- **ADWs** — scanned from `adws/adw_*.py` (leading docstring → description).

Definitions are read from a **merged root**: the app repo is the base layer, and the operator-selected `working_dir`'s `.claude/` overlays/extends it (working-dir entries shadow app-repo entries of the same name). A `RepoBuilder.Definitions` GenServer scans the categories, **watches** the source directories via `FileSystem` (with a slow poll fallback), diffs an `(name, mtime)` signature, and **broadcasts over `Phoenix.PubSub`** so that adding, removing, or editing a definition file updates every connected console **with no restart and no panel re-open**.

## User Story
As an operator driving the orchestration console
I want the ⌘K prompt to show me the ADWs, slash commands, and agents that actually exist as files in my repo (and my selected working dir), refreshing automatically as I add or edit those files
So that I can discover and insert the correct token (`/feature`, `start_adw workflow_type=plan_build`, an agent name) without memorizing what's available or restarting the app when I author a new workflow/command/agent.

## Problem Statement
The prompt UI's notion of "what can I run" is stale and partly fictional: hardcoded example strings, a Builder palette divorced from the real catalog, and slash commands that the Elixir app never reads. An operator who drops a new `adw_*.py` or `.claude/commands/<name>.md` into the repo sees no change in the UI. There is no file watcher anywhere in app code, and the only disk-loaded category (agent templates) is not surfaced in the prompt UI at all. The result is a discovery gap and a correctness gap between the files on disk and what the UI advertises.

## Solution Statement
Introduce a single supervised `RepoBuilder.Definitions` GenServer that is the **runtime source of truth for "what can I reference in a prompt."** It:

1. Resolves a **merged** definition root (app repo base + working-dir overlay), per category.
2. Scans three categories into normalized, `@spec`'d typed structs.
3. Subscribes to the source directories with `FileSystem` (promoted to a direct dep — already present transitively in `mix.lock`), debounces events, re-scans the affected category, diffs an `(name, mtime)` signature, and broadcasts `{:definitions_changed, category, list}` on the `"definitions:changed"` PubSub topic. A 30s poll fallback covers environments where inotify events are missed.
4. Exposes a `@spec`'d read API (`all/1`, `list/2`, `subscribe/0`, `refresh/1`).

`ConsoleLive` subscribes on mount, seeds three assigns, re-seeds them when the `working_dir` changes, and updates a single assign per broadcast. The `global_command_input/1` component's static info-pill grid is replaced by **three collapsible chip rows** (Slash / Agents / ADWs), each chip dispatching a client-side `rb:insert-token` event handled by a tiny `CommandInsert` JS hook on the textarea (append at caret, refocus — no server round-trip). Empty-state hints tell the operator exactly which file to add. `WorkflowEngine.Catalog` remains the **validation** source of truth for the `start_adw` tool; the file-derived list is presentation only.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — authoritative spec; honor §3 typed style guide, §5 supervision tree placement, §8 persistence/context boundary, §9 LiveView dashboard, §10 extensibility, §13 testing.
- `README.md` — run instructions and project overview.
- `AGENTS.md` — repo contributor conventions.
- `mix.exs` — `deps/0` (pin `:file_system`), Dialyzer config, `mix` aliases. `:phoenix_live_reload` (`~> 1.2`, dev) is declared at line 71; `:file_system` is transitive via it + credo (`mix.lock:19`).
- `lib/repo_builder/application.ex` — supervision tree. New `RepoBuilder.Definitions` child goes **after `{Phoenix.PubSub, name: RepoBuilder.PubSub}`** (line ~19) and before `RepoBuilderWeb.Endpoint`.
- `lib/repo_builder/orchestrator/templates.ex` — existing disk-loaded agent-template loader. Public API: `list/0 :: [summary()]`, `builtin_root/0`, `writable_root/0`. Reuse for the Agents category (do not re-glob).
- `lib/repo_builder/orchestrator/template.ex` — frontmatter PARSE pair: `from_markdown/1 :: {:ok, map()} | {:error, reason()}` (splits `---` fences, `YamlElixir`, never raises). Reuse / mirror for slash-command frontmatter.
- `lib/repo_builder/workflow_engine/catalog.ex` — hardcoded typed ADW catalog (`types/0`, `fetch/1`, `default_type/0`, `TypeDef`). Stays as `start_adw` validation; the file list is additive/presentation.
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw` `workflow_type` resolution/validation (`resolve_workflow_type/1`, ~line 339). The ADW chip token must be a valid `start_adw` invocation; non-catalog `adw_*.py` are presentational only (chips render but the orchestrator validates on use).
- `lib/repo_builder/orchestrators.ex` — context that owns `working_dir` (`set_working_dir/2`). The merged-root resolution reads the orchestrator's `working_dir`.
- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. `mount/3` (line 72) seeds assigns and `subscribe_feeds/1` (line 319) subscribes PubSub feeds; `save_working_dir/2` / `clear_working_dir` change the working dir. Add `Definitions.subscribe()`, three assigns, a `{:definitions_changed, …}` `handle_info`, and re-seed on working-dir change.
- `lib/repo_builder_web/components/console_components.ex` — `global_command_input/1` (line 1986); static info-pill grid at lines 2104-2131 (the replacement site); `show_command/0`/`hide_command/0` (807-820); existing `cns-chip` class + `ClipboardCopy` hook usage to mirror.
- `assets/js/app.js` — JS hooks registry (line 102: `hooks: {...colocatedHooks, AutoScroll, ClipboardCopy, CommandPaste}`). Add a `CommandInsert` hook and register it.
- `config/config.exs` / `config/runtime.exs` / `config/test.exs` — optional `:repo_builder, RepoBuilder.Definitions` config (app_root override, poll interval, `watch_enabled?` flag for test/CI).
- `.claude/commands/` — the 10 existing slash-command `.md` files (`feature.md`, `implement.md`, `test.md`, `review.md`, `build.md`, `commit.md`, `bug.md`, `chore.md`, `prime.md`, `conditional_docs.md`) — fixtures for the scanner.
- `adws/` — the `adw_*.py` ADW scripts — fixtures for the ADW scanner.
- `priv/orchestrator/agents/code-scout/0001.md` — existing agent-template fixture.
- `.claude/commands/conditional_docs.md` — read during planning to check for required conditional docs (none matched for this feature: no payments, email, auth, or external-API integration; it is pure in-app discovery + LiveView).

### New Files
- `lib/repo_builder/definitions.ex` — the `RepoBuilder.Definitions` GenServer: merged-root resolution, scan orchestration, `FileSystem` watch + debounce + poll fallback, signature diff, PubSub broadcast, and the `@spec`'d read API.
- `lib/repo_builder/definitions/slash_command.ex` — `typedstruct` `%Definitions.SlashCommand{}` + `scan/1` (glob `.claude/commands/**/*.md`, `:`-namespacing, frontmatter parse).
- `lib/repo_builder/definitions/agent.ex` — `typedstruct` `%Definitions.Agent{}` + `scan/1` (delegate to `Orchestrator.Templates.list/0`, plus working-dir `.claude/agents/*.md`).
- `lib/repo_builder/definitions/adw.ex` — `typedstruct` `%Definitions.Adw{}` + `scan/1` (glob `adws/adw_*.py`, strip `adw_`, read leading `"""docstring"""`, fallback to filename).
- `test/repo_builder/definitions_test.exs` — scanning, namespacing, merge precedence, empty dirs, malformed-frontmatter tolerance.
- `test/repo_builder/definitions_watch_test.exs` — write a new file into a watched tmp dir → assert `{:definitions_changed, …}` broadcast (poll fallback path enabled so it is deterministic without inotify).
- `test/repo_builder_web/live/test_prompt_palette_test.exs` — `Phoenix.LiveViewTest`: chips render one per fixture, empty-state hint shows for an empty category, `rb:insert-token` dispatch is wired, and a `{:definitions_changed, …}` broadcast re-renders the chip row.

## Implementation Plan
### Phase 1: Foundation
Promote `:file_system` to a direct dependency and stand up the typed domain: the three category structs and their pure `scan/1` functions, plus the merged-root resolver. These are pure, `@spec`'d, side-effect-light (filesystem reads only) and independently unit-testable before any GenServer or UI exists. Reuse `Orchestrator.Template.from_markdown/1` for frontmatter and `Orchestrator.Templates` for agents to avoid reinventing parsing/globbing.

### Phase 2: Core Implementation
Build the `RepoBuilder.Definitions` GenServer: initial scan, `FileSystem` subscription per resolved directory, event debounce, `(name, mtime)` signature diff per category, PubSub broadcast of changed categories only, slow poll fallback, and the read API. Supervise it after PubSub in `application.ex`. Make watch enablement and poll interval configurable so tests are deterministic and CI without inotify still works via polling.

### Phase 3: Integration
Wire `ConsoleLive` (subscribe, seed, re-seed on working-dir change, per-broadcast assign update). Replace the static info-pill grid in `global_command_input/1` with three collapsible chip rows + empty-state hints + source badges. Add the `CommandInsert` JS hook for client-side caret-append. Add the LiveView integration test and run the full validation suite.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the authoritative spec and conventions
- Read `BUILD_PROMPT.md` (§3 typed style, §5 supervision, §8 context boundary, §9 LiveView, §10 extensibility, §13 testing) and `README.md` and `AGENTS.md`.
- Read `.claude/commands/conditional_docs.md` and confirm no additional docs are required (this feature is in-app discovery + LiveView only).
- Read `lib/repo_builder/orchestrator/templates.ex`, `lib/repo_builder/orchestrator/template.ex`, `lib/repo_builder/workflow_engine/catalog.ex`, and `lib/repo_builder/application.ex` to match existing patterns.

### 2. Promote `:file_system` to a direct dependency
- In `mix.exs` `deps/0`, add `{:file_system, "~> 1.1"}` (matches `mix.lock` 1.1.1; pin per BUILD_PROMPT §2).
- Run `mix deps.get` (no new download expected — already resolved transitively).
- Note the dependency in the `Notes` section.

### 3. Define the three category structs (`typedstruct`, `@enforce_keys`)
- Create `lib/repo_builder/definitions/slash_command.ex`, `.../agent.ex`, `.../adw.ex`.
- Each uses `typedstruct enforce: true` with a precise `field`-level type (no bare `map()`/`any()`): e.g. `SlashCommand{name: String.t(), namespace: [String.t()], path: String.t(), source: :app | :working_dir, description: String.t() | nil, argument_hint: String.t() | nil, mtime: integer()}`; `Agent{name, description, source, version, path, mtime}`; `Adw{name, path, source, description, mtime}`.
- Each module exposes `@spec scan(root :: String.t()) :: [t()]` returning `[]` on a missing dir (fail-silent, never raise).
  - `SlashCommand.scan/1`: `Path.wildcard(root <> "/.claude/commands/**/*.md")`, build `:`-joined name from the path relative to `commands/` (e.g. `experts/ws/q.md` → `experts:ws:q`), parse frontmatter via `Orchestrator.Template.from_markdown/1`, pull `description`/`argument-hint`; malformed frontmatter degrades to a struct with `description: nil`.
  - `Agent.scan/1`: map `Orchestrator.Templates.list/0` summaries to `%Agent{source: :app}`; additionally glob working-dir `.claude/agents/*.md` as `source: :working_dir`.
  - `Adw.scan/1`: `Path.wildcard(root <> "/adws/adw_*.py")`, `name = Path.basename(path, ".py") |> String.replace_prefix("adw_", "")`, read the leading `"""…"""` docstring for `description`, fallback to the humanized filename.

### 4. Implement the merged-root resolver
- In `lib/repo_builder/definitions.ex`, add `@spec resolve(working_dir :: String.t() | nil) :: %{slash_command: [...], agent: [...], adw: [...]}` that scans the app root and (when present) the working dir, then merges per category with **working-dir entries shadowing app-repo entries by `name`** (`Map.new(app, …) |> Map.merge(Map.new(working, …))` keyed by `name`, then values).
- `app_root/0` reads `Application.get_env(:repo_builder, RepoBuilder.Definitions)[:app_root]` if set, else `File.cwd!()`. Document the dev/prod resolution.

### 5. Implement the `RepoBuilder.Definitions` GenServer (scan + watch + broadcast)
- `use GenServer`; `@impl true` callbacks are exempt from the public-`@spec` rule but every *public* helper gets an `@spec`.
- State (`typedstruct`): cached lists per category, the `(name, mtime)` signature set per category, the resolved watched dirs, the `FileSystem` pid, and the working dir.
- `init/1`: do the initial `resolve/1`, start `FileSystem.start_link(dirs: watched_dirs)`, `FileSystem.subscribe(pid)`, and `Process.send_after(self(), :poll, poll_interval)` when polling is enabled.
- `handle_info({:file_event, _pid, {_path, _events}}, state)`: debounce by scheduling a single `:rescan` (cancel/replace a pending timer ~250ms) so save-storms coalesce.
- `handle_info(:rescan, state)` and `handle_info(:poll, state)`: re-`resolve/1`, compute per-category `(name, mtime)` signatures, and for each **changed** category `Phoenix.PubSub.broadcast(RepoBuilder.PubSub, "definitions:changed", {:definitions_changed, category, list})`; reschedule the poll.
- Public API with `@spec`:
  - `start_link/1`, `subscribe/0 :: :ok` (`Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "definitions:changed")`),
  - `all/1 :: %{slash_command: [...], agent: [...], adw: [...]}` (working_dir arg; reads cache, re-resolving the working-dir overlay on demand),
  - `list/2 :: [t()]`, `refresh/1 :: :ok` (force re-scan + broadcast; used by ConsoleLive when working_dir changes).
- Config: `watch_enabled?` (default true; false in `config/test.exs` so unit tests are deterministic), `poll_interval_ms` (default 30_000).

### 6. Supervise the GenServer
- In `lib/repo_builder/application.ex`, add `RepoBuilder.Definitions` to the `children` list **immediately after `{Phoenix.PubSub, name: RepoBuilder.PubSub}`** and before `RepoBuilderWeb.Endpoint` (it depends on PubSub; it must not depend on Repo).
- Confirm it starts cleanly under `mix test` (where `watch_enabled?` is false).

### 7. Unit tests for scanning + merge
- Create `test/repo_builder/definitions_test.exs`: build tmp fixture dirs (`.claude/commands/**`, `adws/adw_*.py`, agent template dir) and assert: one struct per file; `:`-namespacing of subdir commands; merge precedence (working-dir shadows app by name); empty dirs → `[]`; malformed frontmatter still yields a usable struct (no raise); ADW docstring → description, missing docstring → filename fallback.

### 8. Watch test (poll-fallback path)
- Create `test/repo_builder/definitions_watch_test.exs`: start a `Definitions` instance pointed at a tmp root with **polling enabled and a short interval**, `subscribe/0`, write a new `adw_x.py` (and a `cmd.md`), then `assert_receive {:definitions_changed, :adw, _}` (and `:slash_command`) within the poll window. This is deterministic without inotify.

### 9. LiveView integration test (write before the component change so it drives the UI)
- Create `test/repo_builder_web/live/test_prompt_palette_test.exs` using `Phoenix.LiveViewTest`:
  - `live(conn, "/")`, open the command modal, and assert one chip per fixture in each row (`element/2` / `render(...)` contains `/feature`, an agent name, and an ADW slug).
  - Assert the empty-state hint text renders when a category is empty (e.g. stub/empty working dir).
  - Assert a chip carries the `rb:insert-token` dispatch (rendered `phx-click` payload) so the client hook will receive it.
  - Broadcast `{:definitions_changed, :slash_command, new_list}` on `"definitions:changed"` and assert the chip row re-renders with the new entry (PubSub-driven live update).
  - Optionally capture a Playwright/Tidewave-vision screenshot of `http://localhost:4000` as visual proof.

### 10. ConsoleLive wiring
- In `mount/3` (or `subscribe_feeds/1`, line 319), call `RepoBuilder.Definitions.subscribe()` and seed `assign(socket, slash_commands: …, agents: …, adws: …)` from `Definitions.all(working_dir)`.
- Add `handle_info({:definitions_changed, category, list}, socket)` that updates the single matching assign (`:slash_command → :slash_commands`, `:agent → :agents`, `:adw → :adws`).
- In `save_working_dir/2` and `clear_working_dir`, call `Definitions.refresh(working_dir)` (or re-`all/1`) and re-seed the three assigns so the overlay updates immediately.
- Keep `mount/3`'s existing `agents: []` assign for live worker agents distinct from the new template `agents` assign — rename the template assign to avoid collision (e.g. `agent_defs`) if `agents` is already the live-worker list (it is — `subscribe_feeds/1` line 335 assigns live `agents`). Use `slash_commands`, `agent_defs`, `adws` to avoid clobbering.

### 11. Replace the static info-pill grid with collapsible chip rows
- In `console_components.ex` `global_command_input/1`, replace lines 2104-2131 with a private `palette_row/1` function component rendered three times (Slash / Agents / ADWs), each: a toggle button (default collapsed, `cns-chip--active` when open, count in the label), and a chip per item.
- Each chip: `<button type="button" class="cns-chip" phx-click={JS.dispatch("rb:insert-token", to: "#command-textarea", detail: %{token: token})} title={item.description}>{label}</button>` where token is `"/" <> name` (slash), the bare name (agent), or `"start_adw workflow_type=" <> name` (ADW).
- Render a small **source badge** (app vs working-dir) on each chip; render the **empty-state hint** per row when its list is empty ("none — add `.claude/commands/<name>.md>`", "none — add `adws/adw_*.py`", "none — add `priv/orchestrator/agents/<name>/NNNN.md`").
- Pass the three new assigns through from `console_live.ex` to the component (add `attr`s with `@spec`-friendly types).

### 12. Add the `CommandInsert` JS hook
- In `assets/js/app.js`, define `const CommandInsert = { mounted() { this.el.addEventListener("rb:insert-token", (e) => { /* insert e.detail.token at caret with space padding, refocus */ }) } }` and add it to the `hooks: {…}` map (line 102).
- Add `phx-hook="CommandInsert"` to the `#command-textarea` element in `global_command_input/1` (it already carries `CommandPaste`; combine both via a single wrapper hook or attach `CommandInsert` to the textarea — verify only one `phx-hook` per element, so fold the insert listener into the existing `CommandPaste` hook if needed).

### 13. Run the full validation suite
- Run every command in `Validation Commands` and fix until all are green with zero regressions.

## Testing Strategy
### Unit Tests
- `definitions_test.exs`: per-category `scan/1` against tmp fixtures — count, `:`-namespacing, frontmatter description extraction, ADW docstring vs filename fallback, agent summaries from `Orchestrator.Templates.list/0`.
- Merge precedence: same-named command in app root and working dir → working-dir struct wins and `source: :working_dir`.
- `definitions_watch_test.exs`: poll-fallback broadcast on file add; per-category signature diff means an unrelated category does **not** broadcast.
- LiveView test (`test_prompt_palette_test.exs`): chip rendering, empty-state hints, `rb:insert-token` wiring, and PubSub-driven live re-render.

### Edge Cases
- Missing `.claude/commands` / `adws` / agent dir → `[]`, no crash.
- Malformed YAML frontmatter in a command file → struct with `description: nil`, file still listed.
- ADW `.py` with no leading docstring → description falls back to humanized filename.
- Duplicate names across roots → working-dir shadows app-repo (exactly one chip).
- `working_dir` cleared (isolated workspace) → only app-root definitions show; re-seed fires.
- inotify unavailable (CI/container) → poll fallback still broadcasts within the interval.
- Save-storm (editor writes temp+rename) → debounce coalesces to a single re-scan.
- Live worker `agents` assign must not be clobbered by the template `agent_defs` assign.

## Acceptance Criteria
- `RepoBuilder.Definitions` is supervised after PubSub and scans all three categories from the merged (app + working-dir) root.
- Adding a `adws/adw_X.py`, a `.claude/commands/Y.md`, or an agent template file causes the corresponding chip to appear in an already-open console **without restart or panel re-open** (via PubSub broadcast; poll fallback guarantees it within the interval).
- Removing/editing a file updates/removes the chip; editing a description updates the chip's tooltip.
- Clicking a chip appends the correct token (`/feature`, agent name, `start_adw workflow_type=plan_build`) at the textarea caret with no server round-trip and refocuses the textarea.
- Working-dir `.claude/` definitions overlay and shadow app-repo ones by name, marked with a source badge.
- Empty categories show an actionable empty-state hint.
- `WorkflowEngine.Catalog` is unchanged as the `start_adw` validation source of truth; non-catalog ADW chips still render (presentation only).
- All five validation commands pass with zero regressions; every new public function carries an `@spec` and every new struct uses `typedstruct`/`@enforce_keys`.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix deps.get` — resolve the promoted `:file_system` direct dependency.
- `mix test test/repo_builder/definitions_test.exs` — scanning + merge unit tests pass.
- `mix test test/repo_builder/definitions_watch_test.exs` — watch/broadcast (poll-fallback) test passes.
- `mix test test/repo_builder_web/live/test_prompt_palette_test.exs` — LiveView chip rendering, empty-state, and PubSub live-update test passes.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic type checker + `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite green, zero failures.
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint clean, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — no new contract warnings, no stale ignore filters.
- Tidewave runtime check (optional, dev): `project_eval` `RepoBuilder.Definitions.all(nil)` against the running app to confirm the live scan returns the expected categories; `get_logs` to confirm no watcher errors on boot.

## Notes
- **New dependency:** `{:file_system, "~> 1.1"}` promoted from transitive (already `mix.lock:19` via `phoenix_live_reload` + credo) to a direct dep so it is available outside `:dev`. No new download.
- **Catalog vs files:** `WorkflowEngine.Catalog` stays the typed validation source for `start_adw`; the file-derived ADW list is presentation. A follow-up could fold the catalog into a manifest file so the two never drift.
- **Out of scope (follow-ups):** stateful enable/disable toggles (a real selection model), a file-driven ADW Builder step palette (currently hardcoded `~w(plan patch build test review document ship)` at `console_components.ex:2164`), and LLM autocomplete pills (both Vue reference apps have these; not requested here).
- **Reference apps:** `orchestrator_3_stream` (Vue+FastAPI) re-globs per request and refreshes on panel-open only; the earlier Python `repo_builder` adds a 1s polling watcher that pushes ADW changes over WebSocket but leaves slash/agents on refresh-on-open. This Elixir design pushes real updates for **all three** categories via `FileSystem` + PubSub, beating both — and adopts the Python app's engine-root-vs-working-dir decoupling as the "merged root."
- Design source of truth: `.planning/file-driven-prompt-palette.md`.
- The `#command-textarea` already carries the `CommandPaste` hook; an element takes one `phx-hook`, so fold the `rb:insert-token` listener into `CommandPaste` (or a combined hook) rather than adding a second `phx-hook` to the same element.
