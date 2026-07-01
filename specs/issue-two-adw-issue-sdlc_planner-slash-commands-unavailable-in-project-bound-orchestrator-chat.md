# Bug: Platform slash commands (`/bug`, `/chore`, `/feature`, …) are unavailable in a project-bound orchestrator chat

## Metadata
issue_number: `two`
adw_id: `issue`
issue_json: `log-36404`

## Bug Description
An operator typed `/bug ADW is running but not showing the ADWS screen…` **into the
orchestrator chat** while the orchestrator was bound to a foster/target repo
(`cwd = /data/1.Projects/worldWorkBench`). The orchestrator (a Claude harness session)
replied **"/bug isn't available in this environment."**

Evidence in the log feed:
- `log-36404` / `log-36422` — the operator's `/bug …` input (`role: operator`).
- `log-36405` / `log-36425` — a Claude orchestrator session starts with
  `cwd: /data/1.Projects/worldWorkBench`.
- `log-36406` / `log-36426` — the model's reply: *"/bug isn't available in this
  environment."*

**Expected:** typing a platform slash command the app ships (`/bug`, `/chore`,
`/feature`, `/implement`, `/commit`, `/prime`, `/troubleshooting`) into the orchestrator
chat expands to that command's body (arguments substituted) and runs — the same uniform,
harness-agnostic behavior `RepoBuilder.Prompts.SlashExpander` already provides for the
non-project (path-based) case.

**Actual:** when the orchestrator is bound to a **registered Project**, only the commands
that Project resolves through the stack-aware command packs are recognized
(`/plan`, `/build`, `/fix`, `/review`, `/test` — the `generic` pack). Every
**platform-only** command that lives solely in the app's own `.claude/commands/`
(`bug`, `chore`, `feature`, `implement`, `commit`, `prime`, `conditional_docs`,
`troubleshooting`) passes through **unexpanded**; the raw `/bug …` text reaches the Claude
session, which reports the command as unavailable.

## Problem Statement
`RepoBuilder.Prompts.SlashExpander.expand/3` (the project-aware branch) resolves leading
slash commands **only** through `RepoBuilder.Commands.resolve_all/1` — the per-project
precedence chain (repo-local `.claude/commands` → active plugins → pinned pack → stack
pack → `generic` base). That chain does **not** include the platform's own
`.claude/commands/` directory. So for a project-bound orchestrator, any platform command
not mirrored into a command pack is invisible and is emitted to the harness verbatim.
The non-project (`working_dir`-based) branch does **not** have this gap — it merges the
app root (`Definitions.list/2`) — but a bound orchestrator always takes the project-aware
branch.

## Solution Statement
Make the project-aware expansion **layer the platform's own command bodies underneath the
project's resolved commands** (project wins on conflict). Concretely: in
`SlashExpander.expand/3`, build the resolution index as the app-root ∪ working-dir
path-based bodies (the existing `index/1` + `body/1` reads) **overlaid** by the project's
`Commands.resolve_all/1` bodies. Then a command the Project resolves (repo-local / pinned
/ stack / generic) still wins, while a platform-only command (`/bug`, `/chore`, …) resolves
from the app's `.claude/commands/` instead of leaking through raw.

This is:
- **Server-side and side-effect-free** — it reuses `SlashExpander`'s existing pure,
  fail-silent expansion; it writes nothing into the foster repo (unlike the ADW
  provisioning path, which materializes files into `<repo>/.claude/commands/`).
- **Minimal** — one module's resolution index changes; no new deps, no schema, no new
  public API.
- **Consistent** — it restores the "platform commands are available everywhere"
  invariant the path-based `expand/2` already embodies (which merges the app root), and
  keeps stack-aware overrides winning.

## Steps to Reproduce
1. Register a target repo at `/projects` that ships **no** `.claude/commands/bug.md`
   (e.g. `worldWorkBench`) and bind an orchestrator to it.
2. In the console orchestrator chat (or the ⌘K command bar routed to the orchestrator),
   send `/bug something`.
3. **Observe:** the orchestrator replies that `/bug` isn't available; the raw `/bug …`
   text was sent to the harness unexpanded. `/chore`, `/feature`, `/implement`, `/commit`
   behave the same.
4. Control: send `/plan something` (present in the `generic` pack) — it expands and runs,
   proving expansion works for pack-resolved commands but not platform-only ones.
5. (Runtime confirmation via Tidewave `project_eval`) — with a registered project `p`:
   ```elixir
   RepoBuilder.Prompts.SlashExpander.expand("/bug x", p.root_path, p)   # => "/bug x" (unchanged) — BUG
   RepoBuilder.Prompts.SlashExpander.expand("/plan x", p.root_path, p)  # => expanded body   — OK
   RepoBuilder.Prompts.SlashExpander.expand("/bug x", p.root_path)      # => expanded body (path-based merges app root)
   ```
   The divergence between the 2-arity (works) and 3-arity+project (fails) calls is the bug.

## Root Cause Analysis
**The expansion seam.** Every live session's prompt passes through
`RepoBuilder.Session.Supervisor.expand_prompt/1`
(`lib/repo_builder/session/supervisor.ex:50`), which calls
`SlashExpander.expand(prompt, opts[:cwd], project_for(opts[:cwd]))` (`:56`).
`project_for/1` (`:63`) maps the cwd to a registered `%Project{}` via
`Projects.get_by_root_path/1`. The orchestrator's session opts set
`cwd: orchestrator.working_dir` and `project_id: orchestrator.project_id`
(`lib/repo_builder/orchestrator/server.ex` launch opts), so a **bound** orchestrator
always yields a non-nil `%Project{}` and takes the **project-aware** branch.

**The project-aware branch drops the platform layer.**
`SlashExpander.expand/3` (`lib/repo_builder/prompts/slash_expander.ex:76`) builds its index
via `body_index/1` (`:117`) = `Commands.resolve_all(project)` keyed `name => resolved.body`.
`Commands.resolve_all/1` → `Resolver.resolve_all/1`
(`lib/repo_builder/commands/resolver.ex:56`) walks only the per-project precedence chain
(repo-local → plugins → pinned pack → stack pack → `generic`). It never consults the app's
own `.claude/commands/`. Crucially, `expand/3` only falls back to the path-based
`expand/2` (which *does* merge the app root) when `body_index` is **empty** (`:78`–`:79`).
For a real project it is **not** empty (the `generic` pack resolves `plan/build/fix/
review/test`), so it takes the `index ->` branch (`:81`) and `expand_line_with_bodies/2`
(`:106`) returns the literal line for any name absent from the project index (`:109`–
`:113`). `/bug` is absent ⇒ raw pass-through.

**Inventory confirms the gap.**
- App-only commands (`.claude/commands/`): `bug, build, chore, commit, conditional_docs,
  feature, fix, implement, plan, prime, review, test, troubleshooting`.
- `generic` pack (`priv/command_packs/generic/1.0.0/commands/`): `build, fix, plan,
  review, test` **only**.
- ⇒ `bug, chore, commit, conditional_docs, feature, implement, prime, troubleshooting`
  are resolvable for the platform-as-project but **not** for any foster project — so a
  project-bound orchestrator can never expand them. `/bug` is one of eight affected
  commands, not a one-off.

**Why the harness reports "not available."** With expansion a no-op, the literal
`/bug …` reaches the Claude CLI, whose native resolver looks in the foster repo's
`.claude/commands/` (cwd), finds no `bug.md`, and reports it unavailable — exactly the
`log-36406` / `log-36426` reply.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/prompts/slash_expander.ex` — **primary edit.** `expand/3` (`:76`) and
  `body_index/1` (`:117`): overlay the project's resolved bodies **on top of** the
  app-root ∪ working-dir path-based bodies so platform-only commands resolve. `index/1`
  (`:127`, path discovery) and `body/1` (`:135`, frontmatter-stripped body read) are the
  existing helpers to reuse for the platform layer; `expand_line_with_bodies/2` (`:106`)
  consumes the merged index unchanged. Keep it pure and fail-silent (§ module doc).
- `lib/repo_builder/session/supervisor.ex` — **reference, no edit.** `expand_prompt/1`
  (`:50`) + `project_for/1` (`:63`) show that a bound orchestrator always hits the
  project-aware branch; confirms the fix belongs in `SlashExpander`, not here.
- `lib/repo_builder/commands.ex` / `lib/repo_builder/commands/resolver.ex` —
  `resolve_all/1` (`commands.ex:19` → `resolver.ex:56`): the per-project chain that omits
  the platform command dir; confirms the precedence the overlay must preserve
  (project resolution still wins).
- `lib/repo_builder/definitions.ex` — `Definitions.list(:slash_command, working_dir)`
  (used by `index/1`): the merged app-root ∪ working-dir discovery that supplies the
  platform layer bodies.
- `.claude/commands/` + `priv/command_packs/generic/1.0.0/commands/` — the two inventories
  above; the source of the resolvable-set divergence. (Reference only.)
- `lib/repo_builder/orchestrator/server.ex` — the orchestrator session launch opts
  (`cwd: orchestrator.working_dir`, `project_id`) that select the project-aware branch.
  (Reference only.)
- `lib/repo_builder/commands/provisioner.ex` — `provision_for_adw/2` / `provision/2`: the
  ADW precedent that materializes commands into the foster repo. Documents the alternative
  we deliberately do **not** take for chat (it writes into the user's repo). (Reference
  only.)

Conditional docs (per `.claude/commands/conditional_docs.md`):
- `README.md` (Agentic layer adaptor → "Stack-aware commands"; the Resolver precedence
  chain) and `ai_docs/agentic-layer-adaptor.md` — the command-resolution model.
- `BUILD_PROMPT.md` §10 (open-identity/closed-contract; extensibility) — the doctrine the
  command system generalizes.
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-on).

### New Files
- `test/repo_builder/prompts/test_slash_expander_platform_fallback_test.exs` — a unit test
  proving a project-bound expansion resolves platform-only commands (`/bug`) while keeping
  project/pack overrides winning. (Pure function; no Postgres needed if a `%Project{}`
  struct is constructed in-memory / via a lightweight fixture.)

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and capture the baseline
- Start Postgres (`scripts/pg.sh start`) if needed and open `iex -S mix phx.server`.
- Via Tidewave `project_eval`, run the three `SlashExpander.expand/2` vs `/3` calls from
  **Steps to Reproduce** against a registered foster project and confirm the 3-arity
  project call leaves `/bug x` unchanged while the 2-arity path call expands it. Record
  this in the PR as the failing baseline.

### 2. Overlay the platform command layer in the project-aware expansion
- In `lib/repo_builder/prompts/slash_expander.ex`, change the project-aware `expand/3`
  (`:76`) so its index is the **merge** of:
  1. the path-based platform layer — the app-root ∪ working-dir bodies (reuse `index/1` to
     get `name => path`, then `body/1` to read each frontmatter-stripped body; skip
     unreadable files, staying fail-silent), and
  2. the project layer — `Commands.resolve_all(project)` `name => resolved.body`,
  with the **project layer overlaid on top** (`Map.merge(platform, project)`), so repo-
  local / pinned / stack / generic still win on conflict and platform-only commands fill
  the gaps.
- Keep the empty-index fallback intact (if BOTH layers are empty, defer to `expand/2`).
- Preserve reserved-command protection (`@reserved`) and the `$ARGUMENTS`/`$N`
  substitution — they already run inside `expand_line_with_bodies/2`, which is unchanged.
- Maintain purity and the "never raises / unreadable ⇒ keep literal" contract. Update/keep
  every `@spec`; the new/merged index helper needs an `@spec` returning the `index()` type.
- Do **not** write anything to the filesystem (no foster-repo provisioning) — this is the
  key distinction from the ADW path.

### 3. Add the regression test
- Create `test/repo_builder/prompts/test_slash_expander_platform_fallback_test.exs`.
- Build a `%Project{}` whose `root_path` is a temp dir with NO `.claude/commands/` (so its
  resolver yields only pack commands), mirroring a foster repo.
- Assert:
  - `expand("/bug hello", project.root_path, project)` now expands to the platform
    `bug.md` body with `hello` substituted (no longer a literal `/bug hello`).
  - A project/repo-local or pack command still **overrides** the platform default: seed a
    repo-local `.claude/commands/plan.md` (or rely on the `generic` pack `plan`) and assert
    the resolved body is the project's, not the app's — proving precedence is preserved.
  - An unknown command (`/definitely-not-a-command x`) is still passed through verbatim.
- Prefer asserting on a stable, unique substring of the resolved body over the whole file.
- Keep the test `async: true` if it shares no global state.

### 4. Optional: guard the orchestrator-chat integration
- If a lightweight seam exists, add a focused test that a project-bound orchestrator's
  outgoing prompt is expanded for a platform command (e.g. assert `Session.Supervisor`'s
  `expand_prompt/1` result for opts with a bound-project cwd expands `/bug`). Include only
  if it stays small; the `SlashExpander` unit test is the required one.

### 5. Run the full validation suite
- Execute every command in **Validation Commands**; ensure all green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `scripts/pg.sh start` — ensure the local Postgres cluster is up (once per session).
- `mix test test/repo_builder/prompts/test_slash_expander_platform_fallback_test.exs` — the
  new test: **fails before** the `slash_expander.ex` change (platform `/bug` stays literal
  under a project) and **passes after** (it expands, with project/pack overrides still
  winning).
- `mix compile --warnings-as-errors` — clean compile; gradual set-theoretic checker +
  `warnings_as_errors` pass.
- `mix format --check-formatted` — formatting is canonical.
- `mix credo --strict` — lint incl. `@spec` on every public function.
- `mix test --warnings-as-errors` — full ExUnit suite green (incl. existing
  `SlashExpander` tests — the path-based `expand/2` behavior must be unchanged).
- `mix dialyzer` — `@spec`/contract checking with no new warnings and no stale ignore
  filters.
- Manual/live re-check (optional, Tidewave): bind an orchestrator to a foster repo, send
  `/bug test` in the chat, and confirm it now expands and runs instead of replying
  "not available."

## Notes
- **Companion to** `specs/issue-two-adw-issue-sdlc_planner-portable-adw-missing-from-adws-screen.md`.
  Both surfaced in the same `log-363xx…364xx` window but have **independent** root causes
  and fixes: that plan makes a running portable ADW *appear on the ADWs screen*; **this**
  plan makes platform slash commands *usable in a project-bound orchestrator chat*. Ship
  them separately.
- **No new dependencies, migrations, or schema changes.** The change is confined to
  `SlashExpander`'s resolution index and is harness-agnostic.
- **Why overlay in `SlashExpander` rather than provision into the foster repo (ADW-style).**
  `Commands.Provisioner` writes command files into `<repo>/.claude/commands/`, which is
  appropriate for an ADW's Python harness (it needs the files on disk) but is an
  unwanted side effect for interactive chat (it litters the user's repo and can shadow
  their own commands). Server-side overlay keeps expansion pure and reversible.
- **Why not just add the missing commands to the `generic` pack.** That would (a) duplicate
  platform meta-commands into a versioned pack that also feeds ADW command provisioning,
  changing ADW behavior, and (b) require re-versioning the pack for every platform command
  added later. The overlay keeps a single source of truth (the app's `.claude/commands/`)
  and auto-covers future platform commands.
- **Precedence must be preserved:** project resolution (repo-local → plugins → pinned →
  stack → generic) overrides the platform layer, so a foster repo that ships its own
  `/plan`, `/build`, etc. still wins. The step-3 override assertion locks this in.
- **Scope of the bug is broader than `/bug`:** the same gap hides `/chore`, `/feature`,
  `/implement`, `/commit`, `/prime`, `/troubleshooting`, `/conditional_docs` in any
  project-bound orchestrator chat; the single overlay fix resolves all of them.
- **Tidewave was used during root-causing:** `project_eval` demonstrated the 2-arity vs
  3-arity-with-project divergence in `SlashExpander.expand`, and source inspection
  confirmed `Commands.resolve_all/1` omits the app-root command dir.
