# Feature: Close the orchestrator⇄ADW gap — shell out portable Python ADWs through a canonical-event harness adapter

## Metadata
issue_number: `the`
adw_id: `gap`
issue_json: `between`

## Feature Description
Give the Elixir orchestrator genuine awareness of, and agency to run, the **real**
AI Developer Workflows (ADWs) — keeping the ADWs as standalone, portable Python
scripts (so they can be driven by other harnesses/products, Elixir or not) while
still surfacing them in the Elixir console with full observability.

The orchestrator (Elixir) is the solid control plane; the ADWs are portable
execution units. Rather than re-implementing ADW logic inside the Elixir
`WorkflowEngine` (which would lock it to this product and can't express the
scout/parallel fan-out workflows), the orchestrator **shells out** to the Python
ADW scripts under `adws/adw_workflows/*.py` via the platform's existing harness
adapter contract: a thin **ADW harness adapter** builds the spawn command
(`command/1`) and maps the script's emitted events into canonical harness events
(`normalize/2`). The generic erlexec session runtime (BUILD_PROMPT.md §6) owns
spawning, interrupt, and termination — exactly as it does for the Claude/pi/cursor
adapters.

The linchpin that makes this both **portable** and **observable** is a neutral
**stdout-JSON event mode** added to the Python ADWs: instead of only pushing to a
hard-wired websocket backend + their own Postgres, the ADWs emit a versioned,
harness-neutral event line per step/tool/usage/done on stdout. Any consumer (this
Elixir app via `normalize/2`, or any other orchestrator/product) ingests the same
stream. The Elixir side then gets canonical events → unified console stream,
swimlane per-step progress, durable persistence, cost aggregation, and a rich
`check_adw` — with **no second system of record**.

The already-present-but-orphaned `RepoBuilder.Definitions.Adw` disk scanner
(`adws/adw_*.py`) becomes the discovery + validation source so the orchestrator
sees the real ADWs (including advanced scout/parallel ones) and can launch them.

## User Story
As an operator driving the orchestration console for a non-trivial project
I want the orchestrator to launch the real portable ADWs (plan→build→review→fix, full SDLC, and scout/parallel variants) and stream their per-step progress into my console, and to split a big project into several ADW runs it monitors
So that I get substantive automated workflows that also remain reusable outside this Elixir app — without giving up the canonical observability, cost tracking, and lifecycle control the platform provides.

## Problem Statement
1. **The orchestrator's ADWs are inert.** `start_adw` runs the in-app
   `WorkflowEngine.Catalog`, whose three types are generic English placeholders
   (`"Plan the work for: {{input}}"`) — they do not run the real
   `/plan`→`/build`→`/review`→`/fix` slash-command logic that lives in the Python
   ADWs.
2. **Re-implementing in Elixir would defeat portability.** The user wants the ADWs
   runnable by other harnesses/products that may not be Elixir. Porting the logic
   into `WorkflowEngine` locks it to this app and duplicates maintenance.
3. **The linear Elixir engine can't express the advanced workflows.** The
   scout/parallel-build ADWs (`orch_plan_w_scouts_build_review`, `build_in_parallel`)
   fan out — the deterministic linear `Runner` has no fan-out primitive. The Python
   versions already implement them.
4. **Naive shell-out loses everything that makes the platform valuable.** The
   Python ADWs today emit over **websockets to a specific backend** and to **their
   own Postgres** (`orch_database_models.py`: `agent_logs`/`system_logs` with
   `adw_id`/`adw_step`). Shelling them out as-is gives only an exit code + raw text
   — no canonical console stream, no cost, no `check_adw`, and a **second system of
   record** that diverges from the Elixir `agent_logs`.
5. **Discovery is wired to nothing.** `Definitions.Adw` scans `adws/adw_*.py` but is
   orphaned; `start_adw` validates only against the in-app `Catalog`.

## Solution Statement
Treat a Python ADW as **just another harness**, behind a neutral event contract:

1. **Neutral stdout-JSON event mode (portability + observability).** Add an
   `--emit json` (env-toggled) mode to the Python ADW entrypoints/shared logging so
   each lifecycle moment prints one versioned JSON event to stdout
   (`session_started`, `step_start`, `tool`, `text`, `usage`, `step_end`, `done`,
   `error`). Keep the existing websocket/DB emitters behind the default mode so the
   Python project is unaffected; the new mode is the harness-neutral transport any
   consumer can read.
2. **ADW harness adapter (Elixir).** A new `RepoBuilder.Harness.Adw` adapter:
   `command/1` returns the argv to spawn `uv run adws/adw_workflows/adw_<type>.py`
   (with prompt/working-dir/model/adw-id args and `--emit json`); `normalize/2`
   maps each stdout JSON event → a canonical `RepoBuilder.Harness.Event` struct.
   The generic §6 runtime owns spawn/stream/interrupt/terminate. Register it in the
   harness registry.
3. **Discovery + validation via `Definitions.Adw`.** Wire the disk scanner into
   `start_adw` (validate the requested `workflow_type` against discovered
   `adws/adw_*.py`, not just the in-app `Catalog`) and into the orchestrator's
   injected ADW-types block so it sees the real set, including advanced ones.
4. **Lifecycle + single system of record.** The Python parent is spawned/owned by
   the §6 runtime (recorded in `OsPidLedger`, reaped by `OrphanReaper`); ensure the
   Python ADW launches Claude subprocesses in its own process group so interrupting
   the parent reaps the children. Events flow only through `normalize/2` into the
   Elixir `agent_logs`/console — the Python's own DB/websocket emitters stay off in
   `--emit json` mode, so there is **one** record.
5. **Orchestrator awareness + agency.** Enrich the system prompt: pick an ADW by
   complexity (trivial→`plan_build`, standard→`plan_build_review_fix`,
   non-trivial→full SDLC, large/exploratory→scout/parallel), and **decompose** a
   complicated project into multiple `start_adw` runs tracked via `check_adw`.
6. **Advanced workflows folded in.** Because workflows are just discovered
   `adw_*.py`, the scout/parallel variants are added by copying their scripts +
   commands into `adws/` — no Elixir engine change. They appear in discovery and are
   launchable immediately.

Keep the existing in-app `WorkflowEngine.Catalog` as a lightweight, Fake-harness-
testable fallback (handy for tests and harness-agnostic demos), but the **real**
ADWs are the portable Python scripts driven through the adapter.

## Relevant Files
Use these files to implement the feature:

- `BUILD_PROMPT.md` — Harness event contract §4 (the canonical `Event` set
  `normalize/2` must produce), supervision tree §5, session runtime §6 (spawn/
  interrupt/terminate the ADW owns nothing of), persistence §8, dashboard §9,
  extensibility §10 (adding a harness adapter is the §10 path).
- `lib/repo_builder/harness.ex` — The mandatory behaviour: `command/1`
  (argv+env+`session_ctx`) and `normalize/2` (raw stdout map → canonical events).
  The ADW adapter implements exactly these.
- `lib/repo_builder/harness/custom_spawn.ex` — Optional spawn callbacks; only needed
  if the ADW adapter must drive the child itself. Default: rely on the §6 runtime via
  `command/1` (preferred — keep the adapter minimal).
- `lib/repo_builder/harness/event.ex` — Canonical `Event` structs
  (`SessionStarted`, `TextDelta`, `ToolCall`, `ToolResult`, `Usage`, `Done`,
  `Error`). `normalize/2` returns these; the ADW stdout schema maps onto them.
- `lib/repo_builder/harness/pi.ex` / `claude.ex` / `cursor.ex` — Reference adapters
  to mirror for `command/1`/`normalize/2` shape, env handling, and the streaming-JSON
  convention.
- `config/config.exs` (harness registry) + wherever `HarnessRegistry` is configured —
  register the new `adw` harness key, its providers/default model, and mark whether it
  is orchestrator-spawnable. Confirm `orchestrator_defaults/1` and provider/model
  option plumbing (already used by the console header/agent-models) accept it.
- `lib/repo_builder/definitions/adw.ex` — `Definitions.Adw.scan/2` (orphaned). Becomes
  the discovery + validation source for `start_adw` and the system-prompt block.
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw/2` (line ~321) +
  `resolve_workflow_type/1` (line ~344). Rework to: validate the type against
  discovered ADWs and launch via the ADW adapter + `Session.Supervisor.start_session`
  (mirroring `command_agent/2`'s spawn path, lines ~239-272) instead of the in-app
  `WorkflowEngine`. `check_adw/1` (line ~416) reads progress from the now-canonical
  persisted events.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `start_adw`/`check_adw` tool defs
  (lines ~100, ~174). Update descriptions for the real type set + complexity guidance.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `available_adw_types_block/0`
  (line ~181) sourced from `Definitions.Adw` (or a merge of Catalog + disk); ADW
  guidance prose (lines ~39-94) for selection-by-complexity + multi-ADW decomposition.
- `lib/repo_builder/session/server.ex` — Confirms the spawn/persist/broadcast path the
  ADW process flows through (`agent_db_id`/`orchestrator_db_id` gating, line ~419;
  global feed broadcast, line ~441) so ADW events land in the console + `agent_logs`
  like any worker. The ADW run is modeled as an agent/worker row.
- `lib/repo_builder/session/os_pid_ledger.ex` + `orphan_reaper.ex` — The lifecycle
  ledger/reaper the ADW parent must enroll in; verify process-group kill semantics for
  the Python child tree.
- `.claude/commands/conditional_docs.md` — Read for any docs to pull in.
- Reference (read-only; copy/adapt the Python, do NOT re-implement in Elixir):
  `/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/`
  — `adws/adw_workflows/{adw_plan_build,adw_plan_build_review,adw_plan_build_review_fix}.py`
  (the real step flow + review→fix branch), `adws/adw_modules/adw_logging.py` +
  `adw_websockets.py` (where to add the stdout-JSON emit mode),
  `adws/adw_triggers/{adw_manual_trigger.py,adw_scripts.py}` (how an ADW is launched —
  the argv contract for `command/1`), and
  `.claude/commands/{plan,build,review,fix,plan_w_scouters,orch_plan_w_scouts_build_review,build_in_parallel}.md`.

### New Files
- `lib/repo_builder/harness/adw.ex` — `RepoBuilder.Harness.Adw`: `command/1` +
  `normalize/2` (and only `CustomSpawn` callbacks if strictly needed). Fully `@spec`'d;
  precise `@type`s for the ADW stdout event schema; `{:ok,_}|{:error,_}` over raising.
- `lib/repo_builder/harness/adw/event_schema.ex` (or inline) — A typed decoder mapping
  the neutral stdout JSON events → `RepoBuilder.Harness.Event` structs, with a schema
  version guard. `@enforce_keys`/`typedstruct` for any intermediate structs.
- `adws/adw_workflows/*.py` (copied/adapted from the reference) — the real
  `adw_plan_build.py`, `adw_plan_build_review.py`, `adw_plan_build_review_fix.py`, plus
  advanced `adw_plan_w_scouts_build_review.py` / `adw_build_in_parallel.py`. Modified to
  support `--emit json` neutral stdout events.
- `adws/adw_modules/*.py` (copied/adapted) — shared logging/agent/summarizer modules,
  with the stdout-JSON emit mode added (default behavior unchanged).
- `.claude/commands/fix.md` (+ any missing `plan_w_scouters.md` etc.) — Elixir-idiom
  command(s) the ADW steps invoke, if the steps call repo-local slash commands.
- `test/repo_builder/harness/adw_normalize_test.exs` — Unit tests: each neutral
  stdout-JSON event line normalizes to the correct canonical `Event`; malformed/
  unknown/older-schema lines are handled (skipped or `Error`) without raising.
- `test/repo_builder/orchestrator/start_adw_discovery_test.exs` — `start_adw` validates
  against discovered `adws/adw_*.py`; unknown type lists discovered slugs; launch spawns
  via the ADW adapter (Session supervisor stubbed/Fake).
- `test/repo_builder_web/live/test_orchestrator_adw_shellout_test.exs` —
  `Phoenix.LiveViewTest`: a fake ADW script (or recorded stdout fixture) emitting neutral
  events drives the console; assert ordered per-step swimlane progress + cost + a
  `check_adw`-style status, proving the canonical-event bridge end-to-end.

## Implementation Plan
### Phase 1: Foundation — the neutral event contract
- Define the versioned, harness-neutral ADW stdout event schema (one JSON object per
  line: `type`, `adw_id`, `adw_step`, payload). This is the portability contract.
- Add `--emit json` mode to the Python ADWs (in shared logging) that prints these to
  stdout, leaving the existing websocket/DB emitters as the default mode.

### Phase 2: Core — the Elixir ADW harness adapter
- Implement `RepoBuilder.Harness.Adw` (`command/1` argv to `uv run adw_<type>.py … --emit json`;
  `normalize/2` stdout-event → canonical `Event`). Register the `adw` harness.
- Confirm the §6 runtime spawns/streams/interrupts it like any harness; the run is
  modeled as a worker/agent row so persistence + console + cost work unchanged.

### Phase 3: Integration — discovery, orchestrator agency, lifecycle, advanced workflows
- Wire `Definitions.Adw` into `start_adw` validation + the system-prompt ADW block.
- Rework `start_adw`/`check_adw` in `tools.ex` to launch via the adapter and read
  progress from canonical persisted events.
- Enrich the system prompt (selection-by-complexity + multi-ADW decomposition) and the
  tool descriptions.
- Verify process-group lifecycle (interrupt reaps the Python→Claude child tree;
  `OsPidLedger`/`OrphanReaper` cover it).
- Copy the advanced scout/parallel `adw_*.py` + commands into `adws/`; confirm they are
  discovered and launchable with no Elixir change.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Research + lock the event contract
- Read `BUILD_PROMPT.md` §4/§6/§10 and `.claude/commands/conditional_docs.md`. Use
  Tidewave `get_source_location` on `Harness` callbacks, `Harness.Event`, the pi/cursor
  adapters, `Session.Server`'s spawn+persist path, `Definitions.Adw`, and the
  `HarnessRegistry` config.
- Read the reference `adw_logging.py`/`adw_websockets.py` and a full workflow script
  (in chunks) and the trigger scripts to capture the exact argv + the event moments to
  emit. Define the neutral stdout JSON schema (with a `schema_version`) and document it
  in the adapter moduledoc.

### 2. Add neutral `--emit json` mode to the Python ADWs
- Copy the reference `adws/adw_workflows/*.py` + `adws/adw_modules/*.py` into this repo's
  `adws/` (adapt paths/env). In the shared logging module, add an emit mode that writes
  one JSON event per line to stdout for: session start, step start/end (with slug +
  status + cost/duration), tool use, assistant text, usage, done, error. Gate it on
  `--emit json` / `ADW_EMIT=json` so the default websocket/DB behavior is untouched.
- Ensure the script flushes stdout per line (unbuffered) so streaming works, and runs
  Claude children in their own process group (for clean interrupt/reap).

### 3. Implement the ADW harness adapter (Elixir)
- Create `RepoBuilder.Harness.Adw` implementing `command/1` (argv:
  `["uv","run","adws/adw_workflows/adw_#{type}.py","--prompt",…,"--working-dir",…,"--model",…,"--adw-id",…,"--emit","json"]`,
  plus env/secrets; return a typed `session_ctx` carrying `type`/`adw_id`) and
  `normalize/2` (decode each stdout JSON line via the typed schema decoder → the matching
  `Harness.Event`; map `step_start`/`step_end` to the closest canonical events — e.g.
  `ToolCall`/`TextDelta`/`Usage` — or a system event, and `done`/`error` to
  `Done`/`Error`). No raising; unknown/old-schema lines → skip or `Error`.
- Add `lib/repo_builder/harness/adw/event_schema.ex` with the typed decoder.
- Register `adw` in the harness registry (providers/default model = the Claude model the
  ADW uses; orchestrator-spawnable). Confirm provider/model option plumbing accepts it.

### 4. Adapter unit tests
- `test/repo_builder/harness/adw_normalize_test.exs`: feed representative neutral event
  lines; assert each maps to the right canonical `Event`; assert malformed/unknown/older
  `schema_version` is handled gracefully (mirror `pi_normalize_test.exs`).

### 5. Wire discovery + rework `start_adw`/`check_adw`
- In `tools.ex`, change `resolve_workflow_type/1` to validate against
  `Definitions.Adw.scan/2` (app root + optional working dir), listing discovered slugs on
  unknown; keep `Catalog` as a secondary/fallback if desired.
- Rework `start_adw/2` to spawn the ADW via the adapter +
  `Session.Supervisor.start_session` (model the worker/agent row + opts on
  `command_agent/2`, lines ~239-272), returning the run/agent id. `check_adw/1` reads
  per-step status/cost/artifacts from the canonical persisted events (`Logs`) keyed by
  that id.
- Update `tool_catalog.ex` `start_adw`/`check_adw` descriptions for the real type set +
  complexity guidance.

### 6. Orchestrator awareness + agency
- In `system_prompt.ex`, source `available_adw_types_block/0` from `Definitions.Adw`
  (merged with `Catalog` if kept), and expand the ADW guidance: choose by complexity
  (trivial→`plan_build`, standard→`plan_build_review_fix`, non-trivial→full SDLC,
  large/exploratory→`plan_w_scouts…`/`build_in_parallel`) and decompose complicated
  projects into multiple `start_adw` runs watched via `check_adw`, reporting in plain text.

### 7. Lifecycle verification
- Confirm the spawned `uv`/Python parent is recorded in `OsPidLedger` and reaped by
  `OrphanReaper`; verify interrupt (`Session.Supervisor.interrupt/1`) kills the Python
  parent AND its Claude children (process-group kill). Add/adjust a test or a Tidewave
  `project_eval` check if the existing session tests don't cover the child tree.

### 8. Fold in advanced workflows
- Copy/adapt `adw_plan_w_scouts_build_review.py` (+ `build_in_parallel.py`) and their
  `.claude/commands/*.md` into `adws/`/`.claude/commands/`, with `--emit json` support.
  Confirm `Definitions.Adw` discovers them and the orchestrator can `start_adw` them with
  zero Elixir engine changes (fan-out lives entirely in Python).

### 9. LiveView integration test (console end-to-end)
- `test/repo_builder_web/live/test_orchestrator_adw_shellout_test.exs`: use a small fake
  ADW script (or a recorded stdout fixture replayed through the adapter/Fake spawn) that
  emits the neutral events; mount the console, launch it, and assert ordered swimlane
  per-step progress (plan→build→review[→fix]) + cost + a `check_adw`-style status,
  proving the canonical-event bridge. Optionally capture a Tidewave Web/Playwright
  screenshot of `http://localhost:4000`.

### 10. Validate
- Run all **Validation Commands**; fix until green. Use Tidewave `project_eval` to
  `Definitions.Adw.scan/2` the repo and to push a sample neutral event line through
  `Harness.Adw.normalize/2`, and `get_logs` for any spawn/stacktrace issues.

## Testing Strategy
### Unit Tests
- `Harness.Adw.normalize/2`: every neutral event type → correct canonical `Event`;
  step_start/step_end ordering preserved; usage/cost mapped; `done`/`error` terminal;
  malformed/unknown/older-schema lines handled without raising.
- `Harness.Adw.command/1`: builds the expected argv/env for a given type/prompt/working
  dir/model, includes `--emit json`, and returns a typed `session_ctx`.
- `Definitions.Adw` discovery feeding `resolve_workflow_type/1`: known slug validates;
  unknown lists discovered slugs; empty `adws/` is handled.
- `start_adw/2`: launches via the adapter (Session supervisor faked) and returns an id;
  `check_adw/1` aggregates per-step status/cost from persisted canonical events.

### Edge Cases
- Python/uv missing or non-executable on PATH → `start_adw` returns a clear
  `{:error, _}` (not a crash), surfaced to the orchestrator.
- ADW emits a partial/garbled line or crashes mid-run → adapter yields `Error`; the run
  marks failed; no zombie Python/Claude children (interrupt + reaper verified).
- Two systems of record: assert that in `--emit json` mode the Python does NOT write its
  own DB/websocket (single record), so console/`check_adw` reflect Elixir persistence only.
- Schema drift: an event with a newer/older `schema_version` is tolerated per policy.
- Advanced fan-out ADW (scout/parallel) emitting interleaved multi-agent events → console
  attributes them coherently (agent/step keys preserved through `normalize/2`).
- Working-dir/space-in-path native-spawn gotcha (per project memory) does not break the
  `uv run` argv.

## Acceptance Criteria
- The orchestrator launches the real Python ADWs via `start_adw`, and their per-step
  progress, tool calls, usage/cost, and completion stream into the Elixir console
  (center stream + swimlanes) and persist to `agent_logs` as canonical events — with no
  second system of record.
- ADWs run in a neutral `--emit json` mode that is harness/product-agnostic (the same
  stream is consumable outside this Elixir app), proving portability.
- `Definitions.Adw` discovery drives `start_adw` validation and the orchestrator's
  injected ADW-types block; unknown types list the discovered slugs.
- `check_adw` reports real per-step status/cost from the canonical events.
- Advanced scout/parallel ADWs are discoverable and launchable with zero Elixir engine
  changes (workflow logic stays in Python).
- Interrupting an ADW reliably terminates the Python parent and its Claude child tree;
  `OsPidLedger`/`OrphanReaper` leave no orphans.
- The system prompt guides ADW selection by complexity and multi-ADW decomposition; tool
  descriptions match.
- The new ADW harness adapter is typed and registered; `mix compile --warnings-as-errors`,
  `mix test --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  and `mix dialyzer` are all green.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/harness/adw_normalize_test.exs` — neutral event →
  canonical `Event` mapping + malformed/schema handling.
- `mix test test/repo_builder/orchestrator/start_adw_discovery_test.exs` — discovery
  validation + adapter launch path.
- `mix test test/repo_builder_web/live/test_orchestrator_adw_shellout_test.exs` — console
  streams ordered ADW per-step progress + cost via the canonical bridge.
- `mix compile --warnings-as-errors` — clean compile; set-theoretic checker + warnings
  pass.
- `mix test --warnings-as-errors` — full suite green, zero regressions.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint incl. every-public-fn-`@spec`.
- `mix dialyzer` — no new contract warnings, no stale ignores.
- Tidewave sanity (live app): `project_eval` `RepoBuilder.Definitions.Adw.scan(File.cwd!(), :app)`
  lists the real ADW scripts; pushing a sample neutral event line through
  `RepoBuilder.Harness.Adw.normalize/2` returns the expected canonical `Event`.
- Manual (provisioned host): `uv run adws/adw_workflows/adw_plan_build.py --prompt "…"
  --working-dir "…" --emit json` prints one JSON event per line.

## Notes
- **Why shell-out over porting into the Elixir engine (the decision):** the ADWs are a
  portable asset the user wants reusable by other harnesses/products that may not be
  Elixir. Re-implementing them in `WorkflowEngine` would lock them in and can't express
  the scout/parallel fan-out. Shelling out keeps one portable source of truth; the
  platform's `command/1`+`normalize/2` harness contract is purpose-built to absorb an
  external CLI, so observability is preserved.
- **The condition that makes shell-out worth it:** the neutral stdout-JSON event mode.
  Without it you only get exit code + raw text, the Python's own websocket/DB become a
  second system of record, and `check_adw`/console/cost don't work. With it, the ADWs are
  *more* portable (not tied to the one hard-wired websocket backend) AND fully observable
  here. Do not ship the naive "stdout text only" variant.
- **Disadvantages accepted (documented for the developer):** (1) deploy coupling — hosts
  running the orchestrator need Python + uv + ADW deps + Claude Agent SDK + auth beside
  the BEAM; (2) the seam is stringly-typed at the process boundary — mitigated by a tight,
  versioned `normalize/2` decoder; (3) a deeper process tree — mitigated by process-group
  spawn + `OsPidLedger`/`OrphanReaper`; (4) testing needs a fake-ADW script/fixture rather
  than the Fake harness. These are bounded and outweighed by portability + reuse of the
  working Python logic (including advanced workflows for free).
- **In-app `WorkflowEngine.Catalog` is retained** as a lightweight, Fake-harness-testable
  fallback (useful for tests and harness-agnostic demos), but is no longer the path for
  the real ADWs. The earlier plan to add verdict-based branching to the Elixir `Runner` is
  obsolete here — the review→fix branch lives inside the Python ADW.
- **Reversibility:** the decision is reversible. The neutral event contract is the durable
  asset; if a future product wants a native engine, it can consume the same stdout-JSON
  stream or re-implement against the documented schema without touching the orchestrator.
- **Dependencies:** no Elixir `mix.exs` change expected (uses the existing erlexec runtime
  to spawn `uv`). The Python side pins its own deps via uv inline script metadata. Note the
  provisioning requirement (Python ≥3.11 + uv) in deploy docs.
