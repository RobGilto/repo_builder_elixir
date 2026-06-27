# Chore: Provision portable ADW slash commands into foster repos so any repo can run RepoBuilder ADWs

## Metadata
issue_number: `adw-portable-commands`
adw_id: `na`
issue_json: `{"title":"Foster repos cannot run RepoBuilder ADWs — ADW fails instantly with 'missing slash command(s) in <repo>/.claude/commands: /plan, /build, /review'","body":"When the orchestrator launches an ADW against a target ('foster') repo that does not ship its own .claude/commands/ (fresh / non-git project, e.g. DroneCommander), the portable Python ADW harness fails its pre-flight and emits spawn_failed because it resolves /plan, /build, /review ONLY from <target_repo>/.claude/commands/. The platform already knows how to resolve these commands for ANY project via RepoBuilder.Commands.Resolver (repo-local -> plugin -> pinned -> stack -> generic pack, with capability tokens filled), but that knowledge is never made available to the ADW. Make foster repos able to use the powers of the RepoBuilder ADWs by seeding the resolved command set into the target repo at launch time."}`

## Chore Description

The orchestrator can launch a real, portable Python ADW (`adws/adw_*.py`) against any registered project via the `start_adw` tool and the `RepoBuilder.Harness.Adw` adapter. The ADW shells out through `uv run … --working-dir <cwd>` and the `claude-agent-sdk` is configured with `setting_sources=["project"]`, so **slash commands resolve exclusively from `<cwd>/.claude/commands/`**. A pre-flight in `adws/adw_modules/adw_runner.py` (`missing_commands/2` → `_emit_missing_commands/3`) hard-fails with:

```
missing slash command(s) in <repo>/.claude/commands: /plan, /build, /review
```

…when those files are absent. Fresh "foster" repos (e.g. DroneCommander — not even a git repo, no `.claude/`) have none, so every ADW dies before step 1. This is **infrastructure, not a task failure**.

The asymmetry is the root cause:

| Path | Command resolution |
|------|--------------------|
| Elixir orchestrator (direct `/build` dispatch) | `RepoBuilder.Commands.Resolver` — 4-layer fallback (repo-local → plugin → pinned → stack → **generic pack**) with capability-token fill. Works on **any** repo. This is why the operator's manual `/build` pivot succeeded. |
| Python ADW harness (`adw_runner.py` + SDK) | **Only** `<cwd>/.claude/commands/<name>.md`. No fallback, no token fill. Fails on any repo that doesn't ship its own commands. |

**The chore:** make the Elixir ADW launch path *provision* the resolved, token-filled command bodies into the target repo's `.claude/commands/` **before** spawning the Python ADW, so the Python pre-flight and the SDK both resolve them. Provisioning is idempotent and never overwrites a repo's own commands (repo still wins — mirrors the Resolver's existing precedence). The result: a foster repo gains the full plan→build→review→fix ADW cycle automatically, and becomes self-sufficient for subsequent runs.

Out of scope: changing the SDK's resolution model, rewriting the Python ADWs to call back into Elixir, or auto-`git init` of foster repos.

## Relevant Files

Use these files to resolve the chore:

- `lib/repo_builder/commands/resolver.ex` — **the resolution authority**. `resolve/2` returns a token-filled `%Resolved{}` for any command across the 4-layer chain; `resolve_all/1` enumerates everything available to a project. The provisioner is a thin writer on top of this — do **not** re-implement resolution.
- `lib/repo_builder/commands/resolved.ex` — the `%Resolved{}` struct (`name`, `body`, `layer`, `pack`, `version`, `provenance`). The `body` is the rendered command body (frontmatter already stripped by `Resolver.read_body/1`). Read to know what fields exist for the file we write.
- `lib/repo_builder/commands.ex` — the public `Commands` context facade. Add the provisioning entrypoint here (keep the new module private behind a context function, consistent with the codebase's context-module convention, `BUILD_PROMPT.md` §8).
- `lib/repo_builder/commands/pack.ex` — generic/stack pack discovery (`priv/command_packs/<id>/<ver>/commands/*.md`). Confirms the generic pack ships `plan/build/review/test/fix.md`; the fallback bodies come from here via the Resolver.
- `lib/repo_builder/orchestrator/tools.ex` — **the wiring seam**. `start_adw_via_adapter/4` (≈L473) resolves the target `cwd` (`adw_working_dir/2`, ≈L511) and the discovered script (`resolve_discovered_adw/3`), then calls `spawn_adw_session/4` (≈L531). Provisioning must run **after** `cwd`/`adw` are known and **before** `spawn_adw_session/4`.
- `lib/repo_builder/projects.ex` + `lib/repo_builder/projects/project.ex` — `Projects.get_by_root_path/1` already maps a `cwd` to a registered `%Project{}` (needed for capability-token fill). `adw_working_dir/2` proves the target is registered, so the `%Project{}` is recoverable.
- `lib/repo_builder/projects/capabilities.ex` — how `{{TEST_COMMAND}}`/`{{BUILD_COMMAND}}`/etc. tokens are derived; the Resolver already fills these, so provisioned bodies are correct for the foster repo's detected stack.
- `lib/repo_builder/harness/adw.ex` — the ADW harness adapter. Confirms `--working-dir <cwd>` and `setting_sources=["project"]` semantics (read-only; documents why files must land in `<cwd>/.claude/commands/`). No change required, but cross-reference its moduledoc.
- `lib/repo_builder/definitions/adw.ex` — `Definitions.Adw` structs carry the resolved script `path`. Used to determine **which** commands an ADW needs (parse the script's declared `slash_command=` steps; fall back to the standard set).
- `adws/adw_modules/adw_runner.py` — `commands_dir/1`, `command_name/1`, `missing_commands/2`, `_emit_missing_commands/3`, and `_run_step` (`setting_sources=["project"]`). The optional defensive Python step lives here. Read to keep the provisioned filenames byte-identical to what the pre-flight checks (`<name>.md`, leading-slash stripped).
- `priv/command_packs/generic/1.0.0/commands/` — the fallback bodies (`plan.md`, `build.md`, `review.md`, `test.md`, `fix.md`). Confirms the generic layer can always satisfy the standard ADW step set.
- `.claude/commands/{plan,build,review,test,fix}.md` — the platform's own command bodies (the highest-fidelity source; the generic pack mirrors them). Reference only.
- `test/repo_builder/commands/resolver_test.exs` (if present) — the test style to mirror for the new provisioner test.
- `test/repo_builder/orchestrator/tools_test.exs` (or the existing `start_adw` test) — extend to assert provisioning happens on launch.

### New Files
- `lib/repo_builder/commands/provisioner.ex` — `RepoBuilder.Commands.Provisioner`: resolves + writes the required command set into a target repo's `.claude/commands/`, idempotently, never overwriting repo-owned files. Pure-ish, fail-soft (a provisioning miss must NOT crash the launch — it degrades to the existing loud pre-flight error).
- `test/repo_builder/commands/provisioner_test.exs` — unit tests for the provisioner (writes missing, skips existing, fills tokens, tags provenance, returns the provisioned list, no-ops cleanly when nothing resolves).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the architecture and confirm the seam
- Read `BUILD_PROMPT.md` §3 (typed style), §8 (persistence/context modules), §10 (harness/ADW), and the moduledocs of `Commands.Resolver`, `Harness.Adw`, and `Definitions.Adw`.
- Re-read `tools.ex` `start_adw_via_adapter/4` → `adw_working_dir/2` → `spawn_adw_session/4` to confirm: by the time we reach `spawn_adw_session/4` we hold both the target `cwd` (a registered project's `root_path`) and the resolved `%Definitions.Adw{}` (with `.path`). This is the provisioning insertion point.
- Confirm in `adw_runner.py` the exact filename the pre-flight checks: `os.path.join(<cwd>/.claude/commands, f"{name}.md")` where `name = command_name(step.command)` (leading `/` stripped, arg suffix dropped). Provisioned files MUST match this exactly.

### 2. Determine the required command set for an ADW
- Add a helper (in the new `Provisioner` or a small private fn in `Definitions.Adw`) `required_commands(adw) :: [String.t()]` that:
  - Reads the ADW script at `adw.path` and extracts declared step commands via a regex over `slash_command="/<name>"` (the pattern every `adw_*.py` uses, e.g. `adw_plan_build_review_local_iso.py` → `["plan","build","review"]`).
  - Falls back to the standard set `~w(plan build review test fix)` when the script is unreadable or declares none (the generic pack guarantees these exist).
  - De-duplicates, preserves first-seen order, strips any leading `/`.
- This keeps provisioning **precise** (only what the chosen ADW needs) while remaining safe.

### 3. Implement `RepoBuilder.Commands.Provisioner`
- Create `lib/repo_builder/commands/provisioner.ex` with `@moduledoc` explaining: closes the ADW command-resolution gap by materializing `Commands.Resolver` output into `<root>/.claude/commands/`, idempotent, repo-owned files always win, fail-soft.
- Public API (every public fn gets an `@spec`, per `.credo.exs` gate):
  - `@spec provision(Project.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}`
    - Ensure `<project.root_path>/.claude/commands/` exists (`File.mkdir_p/1`).
    - For each name: if `<root>/.claude/commands/<name>.md` **already exists**, skip (repo wins — never clobber). Otherwise `Commands.Resolver.resolve(project, name)`:
      - `{:ok, %Resolved{} = r}` → write a valid command file: a minimal YAML frontmatter block carrying provenance (e.g. `# provisioned-by: repo_builder (layer: <r.layer>, pack: <r.pack>) — safe to edit or delete`) followed by `r.body`. Use the same frontmatter/body shape `Orchestrator.Template.from_markdown/1` round-trips, so re-reads stay clean.
      - `{:error, :not_found}` → record as unresolved (do not write); continue.
    - Return `{:ok, provisioned_names}` (only the names actually written). Reserve `{:error, _}` for hard IO failures (e.g. unwritable dir) so the caller can decide.
  - Optional convenience `@spec provision_for_adw(Project.t(), Definitions.Adw.t()) :: {:ok, [String.t()]} | {:error, term()}` that composes `required_commands/1` + `provision/2`.
- Tag each provisioned file with an unambiguous marker (the frontmatter comment above) so it is distinguishable from a hand-authored repo command and so a future cleanup/refresh can target only platform-seeded files.
- Must NEVER raise: wrap `File.write/2` / resolution in a `with`/rescue that degrades to `{:error, reason}`; a provisioning failure falls through to the existing Python pre-flight, which already emits a loud, neutral `spawn_failed` — i.e. no regression vs today.

### 4. Expose it via the `Commands` context
- In `lib/repo_builder/commands.ex` add a thin delegate `@spec provision_adw_commands(Project.t(), Definitions.Adw.t()) :: {:ok, [String.t()]} | {:error, term()}` → `Provisioner.provision_for_adw/2`, keeping `tools.ex` calling the context facade (not the implementation module), consistent with the codebase's access pattern.

### 5. Wire provisioning into the ADW launch
- In `lib/repo_builder/orchestrator/tools.ex`, inside `start_adw_via_adapter/4`, after `resolve_discovered_adw/3` succeeds and before `Agents.create_worker/2` → `spawn_adw_session/4`:
  - Recover the `%Project{}` for `cwd` via `Projects.get_by_root_path/1` (the same lookup `adw_working_dir/2` validated). When `cwd` came from the orchestrator's default binding, resolve the orchestrator's bound project instead.
  - If a `%Project{}` is found, call `Commands.provision_adw_commands(project, adw)`. Log/emit a concise note of what was provisioned (reuse the existing structured logging in this module; do NOT add a new console event type).
  - If no project is found (cwd not registered — should not happen given `adw_working_dir/2`'s guard, but be defensive) or provisioning returns `{:error, _}`, **proceed anyway** — do not block the launch. The Python pre-flight remains the backstop and emits the existing error.
- Keep the change minimal and within the existing `with` flow; do not alter `adw_working_dir/2`'s contract.

### 6. (Optional, defensive) Harden the Python pre-flight error
- In `adws/adw_modules/adw_runner.py`, `_emit_missing_commands/3`: extend the error message to hint that the platform can provision these (e.g. append `"— run via the RepoBuilder orchestrator's start_adw, which seeds these from the command resolver"`). This is a message-only change; it preserves the neutral `reason="spawn_failed"` contract and the JSON shape decoded by `Harness.Adw.EventSchema`. Do NOT add Python-side resolution logic (Elixir owns provisioning).
- Do NOT change `setting_sources` or the `commands_dir/1` path — provisioning makes the files exist where the SDK already looks.

### 7. Tests
- `test/repo_builder/commands/provisioner_test.exs`:
  - In a `tmp_dir` project root, `provision/2` writes `plan.md`/`build.md` when absent, with frontmatter provenance + resolved body; `File.exists?` is true and the body contains the resolved content (and filled tokens for a stack with capabilities).
  - A pre-existing `<root>/.claude/commands/build.md` is **not** overwritten (assert byte-identical before/after) and is **not** in the returned provisioned list.
  - An unresolvable name (e.g. a nonsense command) is skipped without error; return value excludes it.
  - `required_commands/1` parses a fixture ADW script's `slash_command="/…"` lines and falls back to the standard set for an empty/unreadable script.
  - Fail-soft: an unwritable target yields `{:error, _}`, never a raise.
- Extend the existing `start_adw` test (in `tools_test.exs` or the dedicated ADW test) so that launching an ADW against a registered project whose root lacks `.claude/commands/` results in those files existing afterward (use a `tmp_dir`-backed project + the `adw_runner: "bash"` / canned-event fixture path already used to avoid `uv`/Python). Assert the worker still starts.
- Run only the new/changed tests first to iterate quickly, then the full suite in the Validation step.

### 8. Validate (zero regressions)
- Run every command in **Validation Commands** below. All must pass clean. Fix any fallout (formatting, missing `@spec`, Dialyzer contract) before considering the chore done.

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures (includes the new provisioner + start_adw wiring tests).
- `mix test test/repo_builder/commands/provisioner_test.exs --warnings-as-errors` - Focused run of the new provisioner tests.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.
- `uv run adws/adw_modules/adw_runner.py --help` - (If the optional Step 6 message change is made) confirm the Python module still imports/parses cleanly after the edit.

## Notes

- **Why provision into the repo (not a temp dir):** both the Python pre-flight (`missing_commands/2`) and the SDK (`setting_sources=["project"]`) resolve from `<cwd>/.claude/commands/` — and `cwd` *is* the repo. Pointing the SDK elsewhere would require changing the working dir (it must be the repo) or an SDK feature for extra command roots that isn't available. Writing the files where they're already looked for is the minimal, correct fix, and it makes the foster repo self-sufficient for later runs (the orchestrator already offered exactly this scaffolding to the operator). An ephemeral-staging + cleanup variant was considered and rejected because it re-introduces the gap on every run and adds lifecycle complexity for no benefit; the provenance frontmatter marker leaves the door open to a future `--refresh`/cleanup command if desired.
- **Repo precedence is preserved:** provisioning only writes a file when the repo doesn't already have one, mirroring `Commands.Resolver`'s "repo-local wins" rule. A foster repo that later adds its own `.claude/commands/plan.md` overrides the seeded copy automatically.
- **No new dependencies.** Everything reuses `Commands.Resolver`, `Projects`, `Definitions.Adw`, and stdlib `File`. `mix.exs` is untouched.
- **No new canonical event type** — provisioning notes ride existing structured logging in `tools.ex`; the ADW's own per-step events still stream/persist via `Harness.Adw` + `agent_logs` unchanged.
- **Generic pack guarantees the floor:** `priv/command_packs/generic/1.0.0/commands/` ships `plan/build/review/test/fix.md`, so even a repo with an unknown/undetected stack always resolves the standard ADW step set; stack/pinned packs and capability tokens simply make the bodies more specific when available.
- **Doctrine fit:** this generalizes the platform's existing "the platform seeds the repo" stance (cf. `Session.Supervisor` injecting `.claude/commands/<name>.md` bodies on every interactive harness, and `Orchestrator.SystemPrompt`'s note that ADW commands resolve from the target repo). It closes the one path — the Python ADW — that didn't yet benefit from the resolver.
