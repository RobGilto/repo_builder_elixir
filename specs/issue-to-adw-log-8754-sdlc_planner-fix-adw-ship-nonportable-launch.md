# Bug: `start_adw` silently launches non-portable `*_iso` ADWs (e.g. `ship_iso`) that crash with `exit_status 256`

## Metadata
issue_number: `to`
adw_id: `log-8754`
issue_json: `a`

> Note on metadata: this bug was filed from the console via `/bug` with the freeform
> request *"log-8734 to log-8754 — a worktree ship to codebase is erroring out, can you
> investigate"*. The command's variable parser mis-split the request, yielding
> `issue_number=to`, `adw_id=log-8754`, `issue_json=a`. The values above are preserved
> verbatim per the command contract, but the **real** subject is orchestrator log-stream
> entries **log-8734 … log-8754**, which record a `ship_iso` ADW (a "worktree ship to the
> codebase") failing twice in a row. Those logs are the authoritative bug report and were
> used to root-cause this plan.

## Bug Description
When the orchestrator runs `start_adw` with the `adw` harness and `workflow_type: "ship_iso"`
(to merge an isolated worktree's branch back into the main codebase), the run dies
immediately at launch instead of shipping. The console log stream (log-8734 → log-8754,
session `f031dfee-9262-453b-b737-0a2a71428dc4`) shows two consecutive failures of the same
ship:

- **Run `47649cad`** — crashed with `Errno 36: File name too long`. The orchestrator
  (correctly) observed that "the `ship_iso` workflow uses the input string to name its run
  directory" (log-8735).
- **Run `06c61daf`** — relaunched with a short single-line `input`; still failed, this time
  with a bare `provider exited: {:exit_status, 256}` and **no traceback** (log-8740 /
  log-8750). The orchestrator noted it was "different from the first failure … I need more
  detail before retrying blindly" (log-8753) and was left guessing.

**Expected:** Either the ship workflow runs and merges the branch, OR `start_adw` rejects the
request up front with a clear, actionable error ("`ship_iso` is not an adapter-launchable
workflow; available: …").

**Actual:** `start_adw` reports `{"status":"started", …}`, spawns a doomed Python process,
and the run terminates with an opaque `exit_status 256` (or a path-length crash on long
input). The orchestrator burns real money/turns and cannot tell *why* it failed.

## Problem Statement
The `adw`-harness launch path admits workflow slugs it physically cannot run. The
`Harness.Adw` adapter speaks a single CLI contract:

```
uv run <script.py> --prompt <input> --working-dir <cwd> --adw-id <id> [--model <m>] --emit json
```

Only the **portable** workflows under `adws/adw_workflows/` (which delegate to
`adws/adw_modules/adw_runner.py`, an `argparse` front-end that accepts exactly
`--prompt/--working-dir/--model/--adw-id/--emit`) honour that contract. There are 5 of them:
`build_in_parallel`, `plan_build`, `plan_build_review`, `plan_build_review_fix`,
`plan_w_scouts_build_review`.

The **top-level** `adws/adw_*_iso.py` scripts (24 of them, including `ship_iso`, `sdlc_iso`,
`plan_build_iso`, …) use a completely different CLI — **positional** `<issue-number>
<adw-id>` args — and emit to GitHub/websocket, not stdout JSON. `adw_ship_iso.py` in
particular *requires pre-existing `ADWState`* (worktree path, branch name, plan file, ports)
produced by a prior full SDLC run; it cannot be launched fresh from a `--prompt` string at
all.

`Orchestrator.Tools.resolve_discovered_adw/3` validates the requested `workflow_type` against
**every** discovered script (both globs), so a non-portable slug like `ship_iso` passes
validation, gets `config["adw_script"]` pointed at the positional-arg script, and is handed
to the adapter, which builds flag-style argv the script ignores.

## Solution Statement
Gate the `adw`-harness launch path so it only accepts **portable** workflows (the ones under
`adws/adw_workflows/` that actually implement the `--prompt/--emit json` contract). A
non-portable slug returns a clear `{:error, reason}` from `start_adw` — listing the slugs that
*can* be launched — instead of silently spawning a process that crashes with `exit_status
256`. This fixes the reported `ship_iso` failure and prevents the identical silent-crash class
for all 24 top-level `*_iso` slugs.

Concretely:
1. Add a typed `portable?` boolean to `RepoBuilder.Definitions.Adw` (true iff the script lives
   under an `adw_workflows/` directory — i.e. it is launched via `adw_runner.py`).
2. In `Orchestrator.Tools`, restrict `resolve_discovered_adw/3` (and the slug list in its error
   messages) to portable workflows, with a distinct, actionable message when a *known but
   non-portable* slug is requested.

This is surgical: discovery/presentation (the ADWS palette) is untouched; only the launch
**validation** is tightened.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start`, then `mix phx.server`) and open the console at
   `http://localhost:4000`.
2. As the orchestrator (on the `adw` harness), call `start_adw` with
   `%{"input" => "merge the fix to main", "harness" => "adw", "workflow_type" => "ship_iso",
   "working_dir" => "/data/1.Projects/repo_builder_elixir"}`.
3. Observe `{"status":"started", …}` returned, then within ~1s a terminal
   `error` event `provider exited: {:exit_status, 256}` (this is `adw_ship_iso.py` exiting `1`
   because `ADWState.load("merge the fix to main")` finds no state). With a long multi-line
   `input`, the failure is instead `Errno 36: File name too long` (the input becomes a path).
4. Runtime reproduction (no GitHub/`uv` needed) — confirm the argv mismatch directly:
   ```elixir
   # Tidewave project_eval
   opts = %{prompt: "merge the fix to main", cwd: File.cwd!(), model: nil,
            config: %{"adw_type" => "ship_iso",
                      "adw_script" => Path.join(File.cwd!(), "adws/adw_ship_iso.py"),
                      "adw_id" => "adw-x"}}
   {_exe, args, _env, _ctx} = RepoBuilder.Harness.Adw.command(opts)
   # => the script then reads sys.argv[1] == "--prompt", sys.argv[2] == "merge the fix to main"
   ```

## Root Cause Analysis
Two layers of the `adw` harness disagree about the workflow CLI contract, and nothing enforces
the agreement at the launch boundary:

- **`RepoBuilder.Harness.Adw.command/1`** (`lib/repo_builder/harness/adw.ex:51`) builds
  *flag-style* argv (`--prompt/--working-dir/--adw-id/--emit json`). Its own moduledoc and
  `default_script/2` fallback (`adws/adw_workflows/adw_<type>.py`) show it was designed for the
  **portable** workflows only.
- **`RepoBuilder.Definitions.Adw.scan/2`** (`lib/repo_builder/definitions/adw.ex:38`) globs
  **both** `adws/adw_*.py` (the positional-arg `*_iso` scripts) **and**
  `adws/adw_workflows/adw_*.py` (the portable ones), tagging both with the same `source`.
- **`Orchestrator.Tools.resolve_discovered_adw/3`** (`lib/repo_builder/orchestrator/tools.ex:513`)
  accepts a `workflow_type` if it matches *any* discovered script, then threads that script's
  path into `config["adw_script"]`.

So `ship_iso` → `adws/adw_ship_iso.py` (a positional-arg, GitHub-emitting, state-dependent
script) is launched with flag argv it ignores. Verified at runtime: the adapter's argv makes
`sys.argv[1] == "--prompt"` and `sys.argv[2] == <input>`, so `adw_ship_iso.py` treats the
literal string `"--prompt"` as the issue number and the `input` as the ADW id:

- Long `input` → `ADWState`/log path built from the id overflows the 255-byte filename limit →
  `Errno 36: File name too long` (run `47649cad`).
- Short `input` → `ADWState.load(<input>)` returns `None` → `sys.exit(1)` → erlexec surfaces it
  as `{:exit_status, 256}` (`256 == 1 << 8`) with no traceback (run `06c61daf`).

The deeper truth is that **shipping is not expressible through the portable `--prompt` contract
at all** — `adw_ship_iso.py` consumes the *state of a prior SDLC run* (its worktree + branch),
not a free-text prompt. Therefore the correct fix is to stop advertising it (and its 23
positional-arg siblings) as adapter-launchable and fail fast with guidance, rather than to
mangle the input into argv.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/definitions/adw.ex` — discovery of `adws/adw_*.py` into `Definitions.Adw`
  structs. Needs a typed `portable?` field distinguishing `adw_workflows/` scripts (launchable)
  from top-level `*_iso` scripts (presentation-only). `scan/2` and `from_file/2` live here.
- `lib/repo_builder/orchestrator/tools.ex` — the `start_adw` tool. `resolve_discovered_adw/3`
  (the launch validation gate) and `discovered_adws/2` / `slugs/1` (error-message helpers) must
  restrict to portable workflows and emit a distinct message for known-but-non-portable slugs.
- `lib/repo_builder/harness/adw.ex` — the adapter that builds the `--prompt/--emit json` argv;
  read-only reference for *which* contract the portable scripts must satisfy (no change needed).
- `adws/adw_ship_iso.py`, `adws/adw_modules/adw_runner.py`, `adws/adw_workflows/*.py` — the two
  Python CLI contracts; read-only reference confirming positional vs. flag argv (no change).
- `test/repo_builder/orchestrator/start_adw_discovery_test.exs` — existing `start_adw`
  discovery tests; its fixtures already live under `adws/adw_workflows/`, so they stay green and
  this is the right place to extend for the non-portable-rejection case.
- `test/repo_builder/definitions_test.exs` — existing `Definitions.Adw` unit tests; extend with
  `portable?` assertions.

### New Files
- `test/repo_builder/orchestrator/start_adw_ship_nonportable_test.exs` — focused regression test
  proving `start_adw` with `workflow_type: "ship_iso"` (and any top-level `*_iso` slug) returns a
  clear `{:error, reason}` and does **not** create a worker/session.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Mark portable workflows in `Definitions.Adw`
- In `lib/repo_builder/definitions/adw.ex`, add a `field :portable?, boolean()` to the
  `typedstruct` (keep `enforce: true`; populate it everywhere a struct is built).
- In `from_file/2`, compute `portable?` as "this script lives under an `adw_workflows/`
  directory" — e.g. `"adw_workflows" in Path.split(Path.dirname(path))`. Add a private
  `@spec`'d helper `portable?/1` for clarity.
- Update the moduledoc to state that only `portable?` scripts implement the adapter's
  `--prompt/--emit json` contract and are launchable via the `adw` harness; the rest are
  presentation-only.
- Keep `scan/2` returning **all** discovered scripts (presentation/palette behaviour is
  unchanged); only the new field is added.

### 2. Gate the `start_adw` adapter path to portable workflows
- In `lib/repo_builder/orchestrator/tools.ex`, change `resolve_discovered_adw/3` so it matches
  the requested `workflow_type` only against `Enum.filter(discovered, & &1.portable?)`.
- Distinguish three outcomes with precise messages (no crash, always `{:error, reason()}`):
  - **portable match** → `{:ok, adw}` (unchanged behaviour for `plan_build`, etc.).
  - **missing `workflow_type`** → keep the existing "workflow_type is required for the adw
    harness; available: <portable slugs>" message, but list **portable** slugs only.
  - **known but non-portable** (the requested slug exists in `discovered` but is not
    `portable?`, e.g. `ship_iso`) → a dedicated message, e.g.
    `"workflow_type #{type} is not an adapter-launchable ADW (it uses the legacy positional/GitHub CLI, not the portable --prompt/--emit json contract); launchable via the adw harness: <portable slugs>"`.
  - **unknown slug** → keep "unknown workflow_type <type>; available: <portable slugs>".
- Point `slugs/1` (or a new `portable_slugs/1` helper) at the portable subset for these
  messages so operators only see slugs they can actually run. Preserve `@spec`s on every
  touched private function; keep return types as `{:ok, …} | {:error, reason()}`.
- Do **not** change `discovered_adws/2`'s scan breadth (the palette still lists everything);
  only the validation/slug-listing for launch is narrowed.

### 3. Unit-test the `portable?` discriminator
- In `test/repo_builder/definitions_test.exs`, add assertions that a scanned
  `adws/adw_workflows/adw_<x>.py` fixture has `portable? == true` and a top-level
  `adws/adw_<x>_iso.py` fixture has `portable? == false`. Reuse the existing tmp-dir fixture
  helper pattern in that file.

### 4. Regression test: non-portable slugs are rejected, not launched
- Create `test/repo_builder/orchestrator/start_adw_ship_nonportable_test.exs`
  (`use RepoBuilder.SessionCase, async: false`, mirroring `start_adw_discovery_test.exs`).
- Build a tmp working dir that contains BOTH a portable fixture
  (`adws/adw_workflows/adw_plan_build.py`) and a non-portable one (`adws/adw_ship_iso.py`), set
  it as the orchestrator's working dir.
- Assert that `Tools.call("start_adw", orch.id, %{"input" => "merge to main", "harness" =>
  "adw", "workflow_type" => "ship_iso"})` returns `{:error, reason}` where `reason` mentions it
  is not adapter-launchable AND lists `plan_build` (the portable slug).
- Assert **no worker was created** for that orchestrator as a side effect (e.g. the
  orchestrator's agent/worker count is unchanged before/after the rejected call), proving we
  fail *before* spawning a doomed session — this is the core regression guard against
  `exit_status 256`.
- Add a positive control in the same file: `workflow_type: "plan_build"` (portable) still
  returns `{:ok, %{"status" => "started", …}}` via the `"adw_runner" => "bash"` fixture path,
  proving the gate didn't break legitimate launches.

### 5. Confirm existing discovery tests still pass unchanged
- Run `test/repo_builder/orchestrator/start_adw_discovery_test.exs` — its fixtures live under
  `adws/adw_workflows/` (already portable), so the "unknown/missing workflow_type" and
  "launch via the adapter" cases must stay green with the portable-only slug listing.

### 6. Run the full validation gate
- Execute every command in **Validation Commands** and ensure all are green with zero new
  warnings (compiler + Dialyzer) and zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- Reproduce BEFORE the fix (expect a doomed launch): with the gate not yet applied, the
  runtime snippet in *Steps to Reproduce §4* shows `sys.argv[1] == "--prompt"`, and a live
  `start_adw` with `workflow_type: "ship_iso"` returns `{:ok, "started"}` then errors with
  `exit_status 256`.
- Reproduce AFTER the fix (expect a clean rejection):
  `mix test test/repo_builder/orchestrator/start_adw_ship_nonportable_test.exs` — proves
  `ship_iso` is rejected with an actionable error and no worker is spawned, while `plan_build`
  still launches.
- `mix test test/repo_builder/definitions_test.exs` — `portable?` discriminator is correct.
- `mix test test/repo_builder/orchestrator/start_adw_discovery_test.exs` — existing adapter
  launch/validation tests stay green.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (spawns Postgres-backed cases) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Why not "make the input into argv" / sanitize the path?** That only masks the first
  failure mode (path-too-long). `adw_ship_iso.py` fundamentally consumes *prior-run state*
  (worktree + branch), not a `--prompt`; feeding it any free-text input is wrong. Failing fast
  with guidance is the correct, minimal fix.
- **Scope boundary (follow-up, not this bug):** if orchestrator-driven shipping is desired, it
  needs a *new portable* workflow under `adws/adw_workflows/` (e.g. `adw_ship.py` wired through
  `adw_runner.py`) whose input is the **prior run's `adw_id`** (so it can load that run's
  worktree/branch and merge it), plus a `start_adw` parameter to pass that id. That is a feature
  addition, deliberately out of scope here. This plan only stops the silent crash.
- **No DB/UI change.** The bug lives entirely in the `adw`-harness launch validation
  (`Orchestrator.Tools` + `Definitions.Adw`); the LiveView dashboard and `agent_logs` schema are
  untouched, so no migration and no `Phoenix.LiveViewTest` is required. The regression is best
  proven at the tool boundary (`Tools.call/3`), which the new test targets.
- **Tidewave used while root-causing:** `get_logs`/`logs_by_numbers` read the actual log-8734…
  8754 stream and the two `exit_status 256` errors; `project_eval` ran `Definitions.Adw.scan/2`
  and `Harness.Adw.command/1` to prove the portable-vs-`*_iso` split and the exact
  `sys.argv[1]=="--prompt"` mismatch. Reuse these to verify the fix.
- `exit_status 256` is erlexec's encoding of POSIX exit code `1` (`1 <<< 8`); any `sys.exit(1)`
  in the launched script surfaces this way — useful to recognise in future ADW triage.
