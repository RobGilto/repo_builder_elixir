# Feature: Subagent Templates (`{{SUBAGENT_MAP}}`) — File-Based, Dual-Authored, Versioned

## Metadata
issue_number: `spec`
adw_id: `this`
issue_json: `out` (interactive request — no GitHub issue)

## Feature Description
Give the orchestrator a library of reusable **subagent templates** — named, pre-configured
worker recipes (description + system prompt + optional model/category/harness) that
`create_agent` can apply by name instead of the operator/brain hand-writing a system prompt
every time. The available templates are injected into the orchestrator's own system prompt
as a `{{SUBAGENT_MAP}}` block so the brain knows what specialists it can spawn.

Templates are stored as **markdown files with YAML frontmatter** — the portable,
human-editable, git-diffable format used by Claude Code's `.claude/agents/*.md` convention
(the "lean A" decision). They are authored by **BOTH** the operator (a new console Settings
tab) and the orchestrator itself (new runtime tools), and every save is **versioned**
(append-only history with restore), so a template can evolve without losing prior revisions.

This ports the reference `orchestrator_3_stream` subagent-template system
(`backend/modules/subagent_loader.py` + `subagent_models.py` + `{{SUBAGENT_MAP}}` injection
in `orchestrator_service.py`) onto our typed Elixir/OTP platform, adapting three things to
our architecture:

1. **Storage format vs. consumption.** In the reference, templates are read from the
   orchestrator's working dir. In our platform the worker is a *separate CLI session* spawned
   with the template body as its system prompt — templates are OUR concept, not fed to a
   harness's native subagent loader. We keep the `.claude/agents` *file format* (portability,
   hand-editability) but the files live at a STABLE configured root, not the ephemeral
   per-session cwd.
2. **Dual authorship.** The reference templates are operator-authored files only. We add an
   orchestrator-facing tool surface (`save_agent_template`/`list_agent_templates`) so the
   brain can mint and refine its own specialists, plus an operator console tab.
3. **Versioning.** The reference has none. We make every save append a new version and
   support non-destructive restore, all on the filesystem (no DB), faithful to "A".

The `tools` frontmatter field from the reference is intentionally **dropped** (our workers
inherit harness-default tools; per-worker tool allowlisting does not exist and is a separate,
larger feature — noted under Future Considerations).

## User Story
As an **operator (and as the orchestrator brain) driving the console**
I want to **define reusable, versioned worker templates as markdown files and apply them by
name when creating agents**
So that **I can spin up consistent specialists ("code-scout", "test-writer", "reviewer")
without rewriting prompts, evolve them safely over time, and let the orchestrator see and
reuse the available specialists via `{{SUBAGENT_MAP}}`.**

## Problem Statement
Today `create_agent` only takes an ad-hoc `system_prompt` (free text) plus a tier/harness/
model. There is no way to (a) save a worker recipe for reuse, (b) let the orchestrator
discover what specialist recipes exist, or (c) evolve a recipe without copy-pasting prompts.
The reference orchestrator solves this with `.claude/agents/*.md` templates and a
`{{SUBAGENT_MAP}}` prompt block, but our platform has neither the storage, the parsing, the
tool surface, nor the prompt injection — and the reference lacks versioning and
orchestrator-side authoring entirely.

## Solution Statement
1. Define a **markdown-with-YAML-frontmatter** template format (`name`, `description`,
   optional `model`/`category`/`harness`; body = worker system prompt) and add a YAML parser
   dependency (`yaml_elixir`) for robust frontmatter reading.
2. Add a single `@spec`'d **`RepoBuilder.Orchestrator.Templates` context** that owns ALL
   filesystem I/O for templates behind tagged-tuple functions (the "no scattered I/O" analog
   to "no `Repo` outside contexts", §8). It manages a stable configured templates root,
   parses/serializes files, and implements append-only **versioning** + restore.
3. Add a `Template` `typedstruct` (`@enforce_keys`) domain type and a `Frontmatter`
   parse/validate helper.
4. Surface templates to BOTH authoring paths:
   - **Operator:** a new "Agent Templates" console Settings tab (list, edit, save-as-new-
     version, version history + restore, delete).
   - **Orchestrator:** new tools `list_agent_templates` / `save_agent_template` /
     `get_agent_template` added to `ToolCatalog` (Claude MCP) AND the pi extension TS defs,
     dispatched through `Tools.call`.
5. Teach `create_agent` to accept `subagent_template`: apply the current version's body
   (system prompt) + model/category, recording the template name+version on the worker.
6. Inject a `{{SUBAGENT_MAP}}`-equivalent block into `SystemPrompt.build/1` (a markdown list
   of `name: description` from `Templates.list/0`, with an empty-state fallback), exactly like
   the existing `{{TOOLS}}`/tiers blocks.
7. Cover with context unit tests (save/version/restore/validate/not_found), `Tools` tests
   (new tools + create_agent-with-template), a `SystemPrompt` injection test, and a
   `Phoenix.LiveViewTest` for the new tab.

### Storage & versioning design (locked)
- **Root:** configurable via `config :repo_builder, :orchestrator, agents_dir: <path>`,
  defaulting to a writable data dir (e.g. `Path.expand("~/.repo_builder/agents")`), plus a
  read-only built-in root at `priv/orchestrator/agents/` for shipped templates. The context
  merges both (writable shadows built-in by name).
- **Layout (per template):** `<<root>>/<name>/<NNNN>.md` where `NNNN` is a zero-padded,
  monotonically increasing version number; the highest N is "current". Each file is a complete
  markdown doc (frontmatter carries `version`, `author`, `updated_at`).
- **Version numbering is per logical template name across BOTH roots.** `next = max(version
  across builtin + writable roots) + 1`, always written to the writable root. So editing a
  built-in (`priv/.../code-scout/0001.md`) produces `<agents_dir>/code-scout/0002.md`, keeping
  one coherent, monotonic history even though built-in and writable live in different dirs.
- **Save is append-only via an ATOMIC exclusive create (collision-safe, no lock, no DB).**
  `save/1` computes `next` from a fresh listing, then opens `<NNNN>.md` with
  `File.open(path, [:write, :exclusive])` (O_EXCL). On `:eexist` (a concurrent writer — operator
  UI racing the orchestrator tool — took that N), it re-lists and retries with the new `next`,
  up to 5 attempts; if still colliding it returns `{:error, :version_conflict}`. No version is
  ever silently overwritten, so concurrent saves both persist as distinct versions.
- **Restore(name, k):** writes a NEW current version (via the same atomic create) whose content
  copies version `k` (history stays linear and non-destructive; "restore" = "promote old to new").
- **Author provenance:** `author: operator` or `author: orchestrator` in frontmatter.
- **No DB.** Faithful to "A" — the filesystem is the source of truth; the context is the only
  reader/writer.

## Relevant Files
Use these files to implement the feature:

### New Files
- `lib/repo_builder/orchestrator/templates.ex` — the `RepoBuilder.Orchestrator.Templates`
  context: the ONLY module that touches the templates filesystem. `@spec`'d `list/0`,
  `fetch/1`, `fetch_version/2`, `versions/1`, `save/1`, `restore/2`, `delete/1`, all returning
  tagged tuples; owns root resolution, parsing, validation, and version numbering.
- `lib/repo_builder/orchestrator/template.ex` — the `Template` `typedstruct` (`@enforce_keys`):
  `name`, `description`, `body`, `model`, `category`, `harness`, `version`, `author`,
  `updated_at`; plus a `Frontmatter` parse (`from_markdown/1` via `YamlElixir`) and serialize
  (`to_markdown/1`, hand-built flat YAML) pair. Validates name (kebab-case, non-empty),
  description/body non-empty, optional model/category(∈ tiers)/harness.
- `priv/orchestrator/agents/code-scout/0001.md` — one shipped built-in template as a seed +
  fixture (read-only root), so `{{SUBAGENT_MAP}}` and the UI are non-empty out of the box.
- `test/repo_builder/orchestrator/templates_test.exs` — context unit tests (uses a tmp root
  via app-env override; save → version bump → restore → fetch → validation → not_found).
- `test/repo_builder/orchestrator/template_test.exs` — frontmatter parse/serialize round-trip
  + validation edge cases (missing name, non-kebab, empty body, bad category).
- `test/repo_builder_web/live/test_agent_templates_tab_test.exs` — `Phoenix.LiveViewTest` for
  the new Settings tab (list, save-new-version, restore, delete) against a tmp root.

### Existing Files
- `lib/repo_builder/orchestrator/tool_catalog.ex` — the SINGLE source of truth for tool defs
  feeding Claude's MCP `tools/list`. Add `subagent_template` to `create_agent`'s schema; add
  `list_agent_templates`, `save_agent_template`, `get_agent_template` defs.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — pi's tool binding HARDCODES tool
  defs (it does not fetch `tools/list`). Mirror the three new tools + the `subagent_template`
  param here so pi orchestrators get them too (logic still lives once in Elixir `Tools`).
- `lib/repo_builder/orchestrator/tools.ex` — `Tools.call`/`dispatch`. Add dispatch clauses +
  `@spec`'d handlers for the three new tools (delegating to `Templates`), and extend
  `create_agent` to apply a `subagent_template` (fetch current version → body/model/category;
  record `template_name`/`template_version` in the worker `config`). Reuses `result()` type.
- `lib/repo_builder/orchestrator/system_prompt.ex` — add a `subagent_map_block/0` (markdown
  list from `Templates.list/0`, empty fallback) and reference it in `build/1`, mirroring the
  existing `tools_block/0`/`categories_block/1`.
- `lib/repo_builder_web/live/console_live.ex` — add a `:templates` settings tab (extend
  `settings_tab/1` union + mapping), assigns (`template_rows`, `selected_template`,
  `template_versions`), and handlers (`select_settings_tab` already exists;
  `save_agent_template`, `select_template`, `restore_template`, `delete_template`,
  `new_template`). Reuse `update`/flash patterns; never `String.to_atom/1` on input.
- `lib/repo_builder_web/components/console_components.ex` — add `:templates` to the
  `settings_tab` `values:`, a `<.settings_tab_button tab={:templates} ...>`, and a templates
  panel (list rail + markdown `<textarea>` editor + frontmatter fields + Save/Delete + a
  version-history list with Restore). Reuse `<.settings_field>`. Unique element ids.
- `lib/repo_builder/agents/agent.ex` — confirm the worker `config`/`metadata` map can carry
  `template_name`/`template_version` (it already holds open config); no schema change expected.
- `mix.exs` — add `{:yaml_elixir, "~> 2.11"}` to `deps/0` (frontmatter parsing). Run
  `mix deps.get`. Report in Notes.
- `config/config.exs` / `config/test.exs` — add `config :repo_builder, :orchestrator,
  agents_dir: ...`; in `test.exs` point it at a per-run tmp dir so tests are hermetic.
- `lib/repo_builder_web/controllers/orchestrator_mcp_controller.ex` — referenced only: it
  auto-derives `tools/list` from `ToolCatalog`, so new tools propagate to Claude with no
  controller change (confirm).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (the **(always)** row):
  `@spec` everywhere, `typedstruct`/`@enforce_keys`, precise types, tagged tuples.
- `BUILD_PROMPT.md` §3 (typed style), §8 (contexts own I/O boundaries), §9 (LiveView/
  components), §10 (extensibility / dual tool binding), §11 (directory layout for `priv/`).

## Implementation Plan
### Phase 1: Foundation
Add the dependency, the template domain type + frontmatter parser, and the `Templates` context
that owns the filesystem root, parsing, validation, and append-only versioning. Seed one
built-in template. Lock it with context + parser unit tests. This is the substrate every
later phase depends on.

### Phase 2: Core Implementation
Wire templates into the orchestrator: the `{{SUBAGENT_MAP}}` injection in `SystemPrompt`, the
`subagent_template` parameter on `create_agent`, and the three new orchestrator tools in both
bindings (`ToolCatalog` + pi extension TS) dispatched through `Tools`. Cover with `Tools` and
`SystemPrompt` tests.

### Phase 3: Integration
Build the operator "Agent Templates" console tab (list/edit/save-version/restore/delete) and
its LiveView wiring; verify the full loop (operator OR orchestrator authors → versioned file →
`{{SUBAGENT_MAP}}` shows it → `create_agent(subagent_template:)` applies it). Lock with the
LiveView test and the green gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the YAML dependency
- Add `{:yaml_elixir, "~> 2.11"}` to `mix.exs` `deps/0`; run `mix deps.get` and
  `mix deps.compile yaml_elixir`. (Reading frontmatter robustly; writing is hand-built flat
  YAML so no serializer is needed.)

### 2. Define the template domain type + frontmatter parser
- Create `lib/repo_builder/orchestrator/template.ex`:
  - `Template` `typedstruct enforce: true`: `name`, `description`, `body`, `model` (nil ok),
    `category` (nil ok), `harness` (nil ok), `version` (pos_integer), `author` (`:operator |
    :orchestrator`), `updated_at` (DateTime).
  - `@spec from_markdown(String.t()) :: {:ok, attrs :: map()} | {:error, reason()}` — split on
    the `---` fences, `YamlElixir.read_from_string/1` the frontmatter, body = remainder.
  - `@spec to_markdown(Template.t()) :: String.t()` — emit `---\n<flat frontmatter>\n---\n\n<body>`.
  - `@spec validate(map()) :: :ok | {:error, reason()}` — name kebab-case + non-empty,
    description/body non-empty, `category ∈ Orchestrators.agent_categories()` when present.

### 3. Write the parser/round-trip unit test
- `test/repo_builder/orchestrator/template_test.exs`: round-trip `to_markdown |> from_markdown`;
  reject missing name, non-kebab name, empty body, unknown category; tolerate absent optional
  fields.

### 4. Implement the `Templates` context (filesystem + versioning)
- Create `lib/repo_builder/orchestrator/templates.ex`:
  - Root resolution: writable `agents_dir` (app env) + read-only `priv/orchestrator/agents`;
    writable shadows built-in by name.
  - `@spec list() :: [map()]` — one summary per template (name, description, current version,
    author, updated_at), sorted by name.
  - `@spec fetch(String.t()) :: {:ok, Template.t()} | {:error, :not_found}` — current version.
  - `@spec fetch_version(String.t(), pos_integer()) :: {:ok, Template.t()} | {:error, :not_found}`.
  - `@spec versions(String.t()) :: [map()]` — version metadata, newest first.
  - `@spec save(map()) :: {:ok, Template.t()} | {:error, reason()}` — validate, compute next
    version as `max(version across both roots) + 1`, then write `<agents_dir>/<name>/<NNNN>.md`
    via an ATOMIC exclusive create (`File.open(path, [:write, :exclusive])`); on `:eexist`,
    re-list and retry (≤5 attempts) → `{:error, :version_conflict}` if it can't get a free slot.
    `author` defaults `:operator`. Never overwrites an existing version file.
  - `@spec restore(String.t(), pos_integer()) :: {:ok, Template.t()} | {:error, reason()}` —
    copy version `k`'s content into a NEW current version (non-destructive).
  - `@spec delete(String.t()) :: :ok | {:error, :not_found}` — remove the writable template dir
    (built-ins are not deletable; return `{:error, :builtin}`).
  - All filesystem errors map to tagged tuples; the context NEVER raises on expected paths.

### 5. Seed a built-in template + write the context test
- Create `priv/orchestrator/agents/code-scout/0001.md` (frontmatter + a read-only scout prompt).
- `test/repo_builder/orchestrator/templates_test.exs` (`async: false`, app-env tmp root):
  save creates v1; a second save bumps to v2; `versions/1` lists both newest-first; `restore/2`
  to v1 creates v3 mirroring v1; `fetch/1` returns current; `{:error, :not_found}` for unknown;
  validation rejects a bad payload; the built-in `code-scout` is listed and not deletable;
  editing the built-in writes `0002.md` to the writable root (cross-root numbering); two saves
  computed off the same starting version both persist as distinct files (atomic-create collision
  safety), neither overwritten.

### 6. Inject `{{SUBAGENT_MAP}}` into the orchestrator system prompt
- In `lib/repo_builder/orchestrator/system_prompt.ex`, add `subagent_map_block/0` (markdown
  bullets `- name: description` from `Templates.list/0`; fallback "No subagent templates yet —
  author one in Settings → Agent Templates or via save_agent_template.") and reference it in
  `build/1` near the tools block.
- Extend the SystemPrompt test (or add one) asserting the block lists a seeded template and the
  empty-state fallback renders when none.

### 7. Teach `create_agent` to apply a template
- In `lib/repo_builder/orchestrator/tool_catalog.ex`, add `subagent_template` (string) to
  `create_agent`'s `input_schema` properties with a clear description (mutually informative with
  `category`/`system_prompt`).
- In `lib/repo_builder/orchestrator/tools.ex` `create_agent`: when `subagent_template` is set,
  `Templates.fetch/1`; on `{:error, :not_found}` return a helpful error listing available names;
  on success apply body→`system_prompt`, frontmatter `model`/`category` (category resolves via
  the existing tier roster path), and record `template_name`/`template_version` in the worker
  `config`. An explicit `system_prompt`/`model` arg still overrides the template.

### 8. Add the orchestrator template tools (both bindings)
- In `tool_catalog.ex`, add defs for:
  - `list_agent_templates` (no args) → name+description list (the SUBAGENT_MAP, on demand).
  - `get_agent_template` (`name`) → current body + frontmatter.
  - `save_agent_template` (`name`, `description`, `system_prompt`/body, optional `model`,
    `category`) → writes a new version with `author: orchestrator`.
- In `tools.ex`, add dispatch clauses + `@spec`'d handlers delegating to `Templates` (author
  `:orchestrator`), returning the `result()` shape.
- In `priv/orchestrator/pi_extension/orchestrator-tools.ts`, add the THREE new tool definitions
  + the `subagent_template` param on `create_agent` (defs only — logic stays in Elixir).

### 9. Write the Tools unit tests
- Add to the orchestrator tools test suite: `save_agent_template` persists a version readable
  by `Templates.fetch/1`; `list_agent_templates` returns it; `create_agent(subagent_template:)`
  applies the body+model and records `template_name`/`template_version`; unknown template name
  returns a helpful error; an explicit `system_prompt` overrides the template body.

### 10. Add the operator "Agent Templates" settings tab (LiveView test first)
- Create `test/repo_builder_web/live/test_agent_templates_tab_test.exs` (`async: false`, tmp
  root): open the tab (`button[phx-value-tab=templates]`); save a template via the form; assert
  it appears in the list and `Templates.fetch/1` returns it; edit + save again and assert the
  version count increments and history shows v1+v2; click Restore on v1 and assert a new current
  version mirrors v1; delete and assert it's gone.
- Implement the tab:
  - `console_components.ex`: add `:templates` to `settings_tab` `values:`, a tab button, and the
    panel (list rail with select; an editor form `#agent-template-form` with name/description/
    model/category fields + a markdown `<textarea>`; Save + Delete; a version list with Restore
    buttons). Reuse `<.settings_field>`; unique ids.
  - `console_live.ex`: assigns (`template_rows`, `selected_template`, `template_versions`) seeded
    in mount + refreshed after writes; handlers `new_template`, `select_template`,
    `save_agent_template`, `restore_template`, `delete_template` (all `{:noreply, ...}`, flash on
    error, re-read via `Templates`); extend `settings_tab/1` to map `"templates" -> :templates`
    and widen its `@spec` union; pass the assigns into `<.settings_modal>`.

### 11. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green.

## Testing Strategy
### Unit Tests
- **Template parser**: frontmatter round-trip; validation (name kebab/non-empty, body
  non-empty, category ∈ tiers); optional fields absent.
- **Templates context**: save creates v1; re-save bumps version; `versions/1` newest-first;
  `restore/2` is non-destructive (new current mirrors old); `fetch`/`fetch_version`/`not_found`;
  built-in is listed and non-deletable; cross-root numbering (built-in edit → writable `0002`);
  atomic-create collision safety (two same-N saves both persist); hermetic via a tmp `agents_dir`.
- **Tools**: `save_agent_template`/`list_agent_templates`/`get_agent_template` happy + error
  paths; `create_agent(subagent_template:)` applies body/model + records provenance; unknown
  template → helpful error; explicit args override the template.
- **SystemPrompt**: `{{SUBAGENT_MAP}}` block lists seeded templates and renders the empty-state
  fallback when none.

### Edge Cases
- Unknown template name in `create_agent` → `{:error, ...}` listing available names (never a crash).
- Empty templates root → `{{SUBAGENT_MAP}}` fallback + empty UI list (no crash).
- Concurrent saves to the same name (operator UI racing the orchestrator tool) → the atomic
  exclusive create guarantees no version is silently lost: the loser hits `:eexist`, retries
  with the next free N, and persists as its own distinct version. Test this explicitly by
  issuing two `save/1` calls computed off the same starting version and asserting BOTH land as
  separate version files (N and N+1), neither overwritten.
- Restore of a non-existent version → `{:error, :not_found}`.
- Built-in template: not deletable (`{:error, :builtin}`); a writable override of the same name
  shadows it.
- Malformed frontmatter / non-UTF-8 file → `{:error, reason}`, skipped from `list/0` with a log.
- Disconnected mount render must not crash — assigns default to empty before the connected read.
- Worker created from a template that is later edited keeps the version it was created from
  (provenance recorded as `template_version`).

## Acceptance Criteria
- A markdown-with-frontmatter template format is parsed/validated/serialized by a typed
  `Template` module; the `Templates` context is the only filesystem reader/writer.
- Templates are versioned: each save appends a new version; history is listable; restore is
  non-destructive; built-ins are read-only.
- The orchestrator's system prompt contains a `{{SUBAGENT_MAP}}` block listing available
  templates (with an empty-state fallback).
- `create_agent(subagent_template: "<name>")` spawns a worker using the template's body+model
  and records the template name+version on the worker; explicit args override.
- Both authoring paths work: the operator via a new "Agent Templates" Settings tab, and the
  orchestrator via `save_agent_template` (Claude MCP + pi extension), both writing versioned
  files through the same context.
- All five green-gate commands pass, plus the new context, parser, Tools, SystemPrompt, and
  LiveView tests.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix deps.get` — resolves the new `yaml_elixir` dependency.
- `mix test test/repo_builder/orchestrator/template_test.exs` — parser/validation.
- `mix test test/repo_builder/orchestrator/templates_test.exs` — context + versioning.
- `mix test test/repo_builder_web/live/test_agent_templates_tab_test.exs` — the new tab.
- `mix compile --warnings-as-errors` — clean compile under the gradual type checker.
- `mix test --warnings-as-errors` — full suite green.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint clean (every new public function has an `@spec`).
- `mix dialyzer` — no new contract warnings, no stale ignore filters.

Optional runtime validation via **Tidewave** (`http://localhost:4000/tidewave/mcp`):
- `project_eval`: `RepoBuilder.Orchestrator.Templates.save(%{name: "x", description: "d", body: "be terse", author: :operator})` then `RepoBuilder.Orchestrator.Templates.versions("x")`.
- `project_eval`: `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |> RepoBuilder.Orchestrator.SystemPrompt.build()` to eyeball the `{{SUBAGENT_MAP}}` block.
- Screenshot `http://localhost:4000` (Settings → Agent Templates) via the Playwright MCP tools.

## Notes
- **New dependency:** `{:yaml_elixir, "~> 2.11"}` (frontmatter parsing). Writing frontmatter is
  hand-built flat YAML, so no serializer dep is needed. This is the only `mix.exs` change.
- **"Lean A" interpretation:** we adopt the `.claude/agents/*.md` *file format and filesystem
  storage* (portable, hand-editable, git-diffable), NOT the harness's native subagent loader —
  our workers are separate CLI sessions that receive the template body as their system prompt,
  so templates are entirely our concept. The format choice is what buys portability + operator
  hand-editing.
- **Dual tool binding (§10):** every new tool is added in TWO places — `ToolCatalog` (Elixir,
  feeds Claude's MCP `tools/list` automatically) and the pi extension TS defs (hardcoded). The
  LOGIC lives once in `Tools`/`Templates`.
- **Versioning model:** append-only version files + non-destructive restore keep history linear
  and auditable with zero DB footprint. If templates later need cross-orchestrator querying or
  tagging, migrating to a DB table is a clean follow-up (the context API stays the same).
- **Dropped `tools` frontmatter:** our workers inherit harness-default tools; per-worker tool
  allowlisting requires session-runtime changes and is out of scope (Future Consideration).
- **Companion spec:** pairs with `issue-spec-adw-this-sdlc_planner-orchestrator-cost-and-
  compaction.md` (report_cost + context-window awareness + `/compact` guidance). This template
  spec is independent and can land first.
- **Future considerations:** per-worker tool allowlists; per-orchestrator (vs. global) template
  scoping; `color`/tagging metadata; git-backed history instead of numbered files; a
  `delete`-as-archive (tombstone) instead of hard remove.
```
