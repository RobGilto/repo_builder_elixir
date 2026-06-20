# Feature: Server-Side Slash-Command Expansion (harness-agnostic, control-owned)

## Metadata
issue_number: `think`
adw_id: `claude`
issue_json: `will`

## Feature Description
Today a `/slash-command` typed into the console (or emitted by the orchestrator into a
`command_agent` prompt) is delivered **verbatim** as argv to the harness CLI. Whether it
expands into the body of `.claude/commands/<name>.md` is left entirely to the underlying
harness: **Claude Code expands it natively** (`claude -p "/foo"`), but **pi does not** — pi
receives `/foo` as literal prompt text (`Harness.Pi.start/2` → `{"pi", args ++ [opts.prompt], …}`),
so the command never runs. This breaks the adapter pattern: the same operator prompt behaves
differently depending on which harness happens to back the orchestrator or worker.

This feature moves slash-command resolution **into the platform**, ahead of the harness
boundary. Before a prompt is handed to any live interactive session, the platform scans it for
known slash-command invocations, reads the matching `.claude/commands/**/*.md` file, and
**replaces the invocation token with the file's body** (substituting `$ARGUMENTS`/positional
args from the rest of the invocation line). If no matching command file exists, the text is left
**exactly as written** (graceful no-op — never mangle ordinary text, paths like `/usr/bin`, or
built-in harness commands like `/compact`). The result is uniform, control-owned templating that
works identically on Claude, pi, and cursor.

It applies to **both** prompt entry points the operator and the orchestrator use:
1. **Orchestrator turns** — operator → orchestrator messages and auto-resume turns.
2. **Spawned agents** — the orchestrator driving a worker via `command_agent` (and any other
   interactive worker session).

It explicitly does **not** touch the `adw` harness: the portable Python ADW engine performs its
own `/plan→/build→/review→/fix` slash-command dispatch in the target repo, and pre-expanding
those would break it.

Finally, the orchestrator agent is **empowered** to use slash commands deliberately: its system
prompt gains an `AVAILABLE SLASH COMMANDS` section (sourced from the live file-driven palette) and
guidance that it may place `/command` invocations in `command_agent` prompts, knowing the platform
expands them reliably on every harness.

## User Story
As an operator (and as the orchestrator agent acting on my behalf)
I want `/slash-command` invocations to expand into their `.claude/commands/*.md` body before they
reach any harness — Claude, pi, or cursor — and to fall back to the literal text when the command
file does not exist
So that prompt templating is consistent and controllable across harnesses (especially pi, which
has no native slash-command support), and the orchestrator can confidently reuse command templates
when dispatching work.

## Problem Statement
Slash-command expansion is delegated to the harness CLI and is therefore non-uniform:
- **pi** (`lib/repo_builder/harness/pi.ex:82`) passes the prompt as raw argv and never resolves
  `.claude/commands/`, so `/build the feature` runs as a literal string and the command is lost.
- **Claude** (`lib/repo_builder/harness/claude.ex`) expands natively, so the same prompt behaves
  differently — a leaky adapter abstraction.
- The orchestrator's system prompt already instructs it to forward operator slash commands into
  `command_agent` (`lib/repo_builder/orchestrator/system_prompt.ex:40`), but that instruction is
  only honored when the worker happens to run on Claude.
- The platform already **discovers** commands for the palette (`Definitions.SlashCommand.scan/2`,
  `Definitions.all/1`) but never **expands** them server-side.

## Solution Statement
Introduce a pure, fail-silent expander module, `RepoBuilder.Prompts.SlashExpander`, that takes a
prompt string plus a working directory and returns the prompt with every **known** leading
slash-command invocation replaced by its command file's body (args substituted). Unknown
invocations and built-in/reserved commands are passed through unchanged.

Invoke it at the single chokepoint every live session already passes through —
`RepoBuilder.Session.Supervisor.start_session/1` — rewriting `opts[:prompt]` against `opts[:cwd]`,
**gated to skip the `adw` harness**. Because orchestrator turns (`Orchestrator.Server`),
`command_agent` worker drives, and ADW worker sessions all funnel through `start_session/1`, this
one seam covers every interactive prompt path without scattering logic across call sites.

Then enrich `Orchestrator.SystemPrompt.build/1` with a live `AVAILABLE SLASH COMMANDS` listing and
updated guidance so the orchestrator agent uses slash commands intentionally.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/definitions/slash_command.ex` — existing typed discovery of
  `.claude/commands/**/*.md` (name, namespace, path, source, description, mtime). The expander
  reuses this to know **which** commands exist and **where** their files live. Relevant because
  membership in this set is exactly the "command found?" predicate that drives expand-vs-keep.
- `lib/repo_builder/definitions.ex` — the watcher/read API; `all/1` and `list/2` return the merged
  (app-root ∪ working-dir) `:slash_command` list. The expander calls `Definitions.list(:slash_command, working_dir)`
  to build its name→path index with the same merge/override semantics the palette uses.
- `lib/repo_builder/orchestrator/template.ex` — `from_markdown/1` splits frontmatter from body. The
  expander reuses it to extract the command **body** (the text that gets injected), matching the
  exact `---`-fence handling the rest of the platform relies on.
- `lib/repo_builder/session/supervisor.ex` — `start_session/1` is the **single chokepoint** for all
  live sessions (orchestrator turns, `command_agent`, ADW). This is where the prompt is rewritten
  before delegating to `Session.Server`. Relevant because centralizing here avoids touching three
  separate call sites.
- `lib/repo_builder/session/server.ex` — stores `opts[:prompt]` (`build_state/3`, line ~138) and
  delivers it via argv. Read-only reference to confirm the prompt flows unchanged after rewriting.
- `lib/repo_builder/orchestrator/server.ex` — builds orchestrator-turn opts with `prompt:` +
  `cwd: orchestrator.working_dir` and calls `Session.Supervisor.start_session/1`. Confirms the
  orchestrator path inherits expansion for free (no edit required beyond verifying `cwd` is passed).
- `lib/repo_builder/orchestrator/tools.ex` — `command_agent/2` (`prompt:` + `cwd: orchestrator_working_dir/1`,
  line ~258-292) and `spawn_adw_session/4` (line ~460, `adw` harness) both call `start_session/1`.
  Confirms worker drives inherit expansion and the ADW path is correctly skipped by harness gate.
- `lib/repo_builder/harness/pi.ex` — line 82 shows pi passes the raw prompt as argv (the bug this
  feature fixes); no edit needed, but documents the motivation.
- `lib/repo_builder/harness/claude.ex` — Claude expands natively; after this change Claude receives
  the already-expanded body (no `/foo` remains), so there is no double-expansion. Reference only.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `build/1` (line 17). Add an
  `AVAILABLE SLASH COMMANDS` section + refreshed guidance empowering the orchestrator to use slash
  commands, sourced from `Definitions`.
- `BUILD_PROMPT.md` — §3 typed style guide (every public fn `@spec`'d, precise types, no raising on
  expected paths), §6 session runtime, §10 extensibility. The new module must conform.

### New Files
- `lib/repo_builder/prompts/slash_expander.ex` — `RepoBuilder.Prompts.SlashExpander`: the pure,
  `@spec`'d, fail-silent expander (`expand/2`), its name-index builder, and `$ARGUMENTS`/positional
  substitution. No filesystem mutation; reads command files read-only.
- `test/repo_builder/prompts/slash_expander_test.exs` — unit tests for the expander (found/not-found,
  args substitution, namespaced commands, multi-line, reserved/built-in pass-through, malformed file).
- `test/repo_builder/session/slash_expansion_integration_test.exs` — verifies `start_session/1`
  rewrites `opts[:prompt]` for non-adw harnesses and leaves `adw` untouched, using a fake/observed
  session start so no real CLI spawns.
- `test/repo_builder_web/live/test_slash_command_expansion_test.exs` — `Phoenix.LiveViewTest`
  integration test: an operator submits `/<known-command> args` in the console; assert the
  orchestrator turn is started with the **expanded** prompt body (observed via the injected
  starter / a fake harness session), and that an unknown `/nope` is delivered verbatim.

## Implementation Plan
### Phase 1: Foundation
Build and unit-test the pure expander in isolation. It depends only on `Definitions` (discovery),
`Definitions.SlashCommand` (path), and `Template.from_markdown/1` (body) — all existing. Establish
the matching rules, argument substitution, and the reserved-name/built-in pass-through denylist so
the behavior is fully specified before wiring it into the runtime.

### Phase 2: Core Implementation
Wire the expander into `Session.Supervisor.start_session/1` as a prompt-rewrite step gated on
harness (skip `"adw"`). This single seam delivers expansion to orchestrator turns and all
interactive worker drives. Verify (no code change expected) that `Orchestrator.Server` and
`Tools.command_agent/2` pass `cwd` so commands resolve from the operator's working directory, and
that `spawn_adw_session/4` (harness `"adw"`) is correctly bypassed.

### Phase 3: Integration
Empower the orchestrator agent: extend `Orchestrator.SystemPrompt.build/1` with a live
`AVAILABLE SLASH COMMANDS` section and refreshed guidance. Add the LiveView integration test
proving the end-to-end console → orchestrator-turn expansion. Run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Step 1 — Define the expander contract and matching rules
- Read `lib/repo_builder/definitions/slash_command.ex`, `lib/repo_builder/definitions.ex`, and
  `lib/repo_builder/orchestrator/template.ex` to confirm exact function names/return shapes.
- Decide and document (in the new module's `@moduledoc`) the matching rules:
  - A slash invocation is recognized **only** when `/<name>` is the **first non-whitespace token of
    a line** (matches Claude semantics; avoids touching mid-sentence `/x` or paths).
  - `<name>` is matched liberally with `~r/\A\s*\/([A-Za-z0-9:_\-]+)/` and then confirmed by
    **exact membership** in the discovered command set — so "not found ⇒ keep text" is automatic
    and `/usr/bin`-style tokens are never expanded.
  - Built-in/reserved commands are never expanded even if a same-named file exists: maintain a
    `@reserved ~w(compact clear resume help model)` denylist (covers the internal `/compact` used by
    `Tools` at `tools.ex:849`). Document the list.
  - Argument handling: the remainder of the invocation line is `$ARGUMENTS`; whitespace-split tokens
    are `$1`, `$2`, …. Unfilled positionals collapse to empty; a body with no `$ARGUMENTS` but a
    non-empty arg string appends the args on a trailing line (so commands that don't template args
    still receive them) — match the documented behavior with tests.

### Step 2 — Implement `RepoBuilder.Prompts.SlashExpander`
- Create `lib/repo_builder/prompts/slash_expander.ex` with `defmodule RepoBuilder.Prompts.SlashExpander`.
- Public API (every public fn `@spec`'d per BUILD_PROMPT §3):
  - `@spec expand(prompt :: String.t(), working_dir :: String.t() | nil) :: String.t()` — the entry
    point. Builds the command index once, then maps over lines, expanding recognized leading
    invocations and leaving everything else byte-for-byte. Never raises (wrap file reads in `with`/
    `case`; a read or `from_markdown/1` error ⇒ keep the original line).
  - A private `@spec index(String.t() | nil) :: %{optional(String.t()) => String.t()}` building
    `name => path` from `Definitions.list(:slash_command, working_dir)`.
  - A private body reader: `@spec body(path :: String.t()) :: {:ok, String.t()} | {:error, term()}`
    using `File.read/1` + `Template.from_markdown/1` → `attrs["body"]`.
  - A private arg-substitution helper with a precise `@spec`.
- Use `@type`/`@typep` for any domain shapes; prefer precise types over `map()`/`any()`. No struct
  needed, but if one is introduced use `typedstruct` + `@enforce_keys`.
- Add `alias RepoBuilder.Definitions` and `alias RepoBuilder.Orchestrator.Template`.

### Step 3 — Unit-test the expander
- Create `test/repo_builder/prompts/slash_expander_test.exs` using a `tmp_dir`-based
  `.claude/commands/` fixture (write real `<name>.md` files with frontmatter + body) and pass that
  tmp dir as `working_dir`.
- Cover: known command expands to body; `$ARGUMENTS`/`$1`/`$2` substitution; namespaced command
  (`experts/ws/q.md` → `/experts:ws:q`); unknown `/nope` kept verbatim; reserved `/compact` kept
  verbatim even with a planted `compact.md`; multi-line prompt with two leading invocations both
  expand while surrounding prose is untouched; mid-line `/foo` not expanded; malformed/no-frontmatter
  command file ⇒ original line kept (no raise); `working_dir: nil` resolves app-root commands only.

### Step 4 — Wire expansion into the session chokepoint
- Edit `lib/repo_builder/session/supervisor.ex`:
  - In `start_session/1`, before `Budget.Guard.check/…`, rewrite the prompt:
    `opts = expand_prompt(opts)`.
  - Add `@spec expand_prompt(keyword()) :: keyword()` that:
    - returns `opts` unchanged when `to_string(opts[:harness]) == "adw"` (Python ADW owns its own
      dispatch) **or** when `opts[:prompt]` is blank/nil;
    - otherwise sets `Keyword.put(opts, :prompt, SlashExpander.expand(opts[:prompt], opts[:cwd]))`.
  - `alias RepoBuilder.Prompts.SlashExpander`.
- Confirm (read-only) that `Orchestrator.Server.handle_continue/2` passes `cwd: orchestrator.working_dir`
  and `Tools.command_agent/2` passes `cwd: orchestrator_working_dir/1`, so commands resolve from the
  operator's repo. No change expected; note it in the plan output if a gap is found.

### Step 5 — Integration test at the session seam
- Create `test/repo_builder/session/slash_expansion_integration_test.exs`.
- Drive `Session.Supervisor.start_session/1` with the `fake` harness and a planted tmp-dir command,
  asserting the started `Session.Server`'s stored prompt is the **expanded body** (read it back via
  the registry/`:sys.get_state` or a fake-harness observation seam), and that passing
  `harness: "adw"` leaves the prompt verbatim. Keep it hermetic — no real `claude`/`pi` spawn.
  Reuse existing `SessionCase`/fake-harness setup (see `erlexec-runtime-gotchas` memory / existing
  session tests for the established pattern).

### Step 6 — Empower the orchestrator via the system prompt
- Edit `lib/repo_builder/orchestrator/system_prompt.ex` `build/1`:
  - Inject an `AVAILABLE SLASH COMMANDS` section listing discovered commands (name + description)
    from `Definitions.list(:slash_command, orchestrator.working_dir)` — mirror the existing
    `{{TOOLS}}`/`{{HARNESSES}}` injection style. Empty list ⇒ a concise "none discovered" line.
  - Refresh the existing guidance (current lines ~40-42) to state that the **platform** expands any
    `/command` placed in a `command_agent` prompt (or operator turn) from the target repo's
    `.claude/commands/`, so it works on every harness (Claude, pi, cursor) — and that the
    orchestrator may use them deliberately to reuse templated workflows.
- Keep `@spec` coverage intact; the helper that renders the section must be `@spec`'d.

### Step 7 — LiveView integration test (console → orchestrator turn)
- Create `test/repo_builder_web/live/test_slash_command_expansion_test.exs` with `Phoenix.LiveViewTest`.
- Mount `ConsoleLive`, point the orchestrator at a working dir containing a planted
  `.claude/commands/greet.md`, submit `/greet world` through the command form, and assert the
  orchestrator turn is started with the **expanded** body (observe via the queue's injectable
  `starter` or a fake-harness session capturing `prompt`). Assert `/nope here` is delivered
  verbatim. Assert the right canonical event/broadcast occurs if the harness path emits one.
- Prefer the existing test seams already used by `test/repo_builder_web/live/*` (e.g. the queue
  `starter` injection in `Orchestrator.Queue`) so the test is deterministic and spawns no CLI.

### Step 8 — Validate
- Run every command in `Validation Commands` and fix any failure until the entire gate is green.

## Testing Strategy
### Unit Tests
- `SlashExpander.expand/2`:
  - found command → body injected; `working_dir` precedence over app-root (override semantics).
  - `$ARGUMENTS`, `$1`, `$2` substitution; no-args invocation; extra-args-with-no-placeholder
    append behavior.
  - namespaced command name resolution (`/a:b:c` ↔ `a/b/c.md`).
  - not-found `/unknown` → byte-identical pass-through.
  - reserved/built-in (`/compact`) → pass-through even with a planted file.
  - mid-line slash, code-fence content, and bare paths (`/usr/local`) → untouched.
  - malformed command file / missing frontmatter → original line kept, no exception.
  - `working_dir: nil` → app-root-only resolution.
- `Session.Supervisor.expand_prompt/1`: non-adw harness rewrites; `adw` skipped; blank/nil prompt
  skipped; `cwd: nil` tolerated.
- `Orchestrator.SystemPrompt.build/1`: section present with discovered commands; graceful "none"
  rendering when empty.

### Edge Cases
- Prompt that is only whitespace or empty → unchanged, no crash.
- A `.claude/commands/` directory that does not exist (nil/invalid `working_dir`) → no expansion,
  no raise.
- Command file present but unreadable / not valid UTF-8 / no `---` frontmatter → keep literal line.
- Two different commands on consecutive lines → both expand independently.
- Operator types a slash command Claude would have expanded natively → now expanded **once** by the
  platform (the body contains no `/name`, so Claude does not re-expand). No double expansion.
- `adw` worker session whose `prompt` contains `/plan` → delivered verbatim to the Python ADW.
- Internal `/compact` issued by `Tools` (`tools.ex:849`) → reserved, passes through to the harness's
  native compaction.

## Acceptance Criteria
- A pi-backed orchestrator (or worker) receiving `/<known-command> args` runs with the command
  **body** as its prompt (args substituted) — verified by an integration test observing the started
  session's prompt.
- A Claude-backed session receives the same expanded body (single expansion, no `/name` remaining).
- An unknown `/command` and any reserved built-in (`/compact`) are delivered **verbatim**.
- The `adw` harness path is **never** pre-expanded.
- Expansion is applied to **both** orchestrator turns and `command_agent` worker drives via the
  single `start_session/1` seam (no logic duplicated across call sites).
- The orchestrator system prompt lists available slash commands and documents that the platform
  expands them on every harness.
- All five validation commands pass with zero regressions; `mix dialyzer` and the gradual type
  checker stay green with no new warnings and no stale ignore filters.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/prompts/slash_expander_test.exs` — the expander unit suite.
- `mix test test/repo_builder/session/slash_expansion_integration_test.exs` — the session-seam
  rewrite/skip-adw integration test.
- `mix test test/repo_builder_web/live/test_slash_command_expansion_test.exs` — the console →
  orchestrator-turn LiveView expansion test.
- `mix compile --warnings-as-errors` — compile clean; gradual set-theoretic checker +
  `warnings_as_errors` pass.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed cases) with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including the "every public function has an `@spec`" gate.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

Optionally, validate the empowered system prompt against the live app with Tidewave:
`project_eval` →
`RepoBuilder.Orchestrator.SystemPrompt.build(RepoBuilder.Orchestrators.get_or_create_default() |> elem(1))`
and confirm the `AVAILABLE SLASH COMMANDS` section renders; use `project_eval` on
`RepoBuilder.Prompts.SlashExpander.expand("/feature do x", "<repo-with-commands>")` to confirm
expansion against the live `.claude/commands/`.

## Notes
- **Why the `start_session/1` chokepoint:** orchestrator turns (`Orchestrator.Server`),
  `command_agent` worker drives, and ADW sessions all already call
  `Session.Supervisor.start_session/1`. Centralizing the rewrite there satisfies "support in orch
  and spawned agents" with a single, harness-gated seam instead of editing each call site — and it
  automatically covers any future caller.
- **Adapter-pattern alignment:** by owning expansion ourselves we make every harness behave
  identically (the user's explicit goal). Claude's native expansion becomes a no-op because the
  injected body no longer contains `/name`.
- **ADW is deliberately excluded.** The `adw` harness is the portable Python engine whose entire job
  is to dispatch `/plan→/build→/review→/fix` in the target repo; pre-expanding would break it. The
  harness gate (`opts[:harness] == "adw"`) is the guard.
- **Reserved-name denylist** prevents shadowing built-in harness commands (notably the internal
  `/compact` at `tools.ex:849`). Keep it small and documented; revisit if harnesses add built-ins.
- **No new dependencies.** Everything reuses `Definitions` (discovery), `Definitions.SlashCommand`
  (paths), and `Template.from_markdown/1` (body extraction). No `mix.exs` change.
- **Future considerations:** (1) optionally surface the discovered-command index to the worker
  `spawn_agent` path for system-prompt-level command hints; (2) consider `argument-hint`-driven
  validation/warnings when an invocation omits required args; (3) consider a per-orchestrator toggle
  if any operator wants to defer to native harness expansion — out of scope here.
</content>
</invoke>
