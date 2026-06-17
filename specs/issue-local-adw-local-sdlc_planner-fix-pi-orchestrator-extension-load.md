# Bug: pi orchestrator never runs inference — its tool extension fails to load (`pi is not defined`)

## Metadata
issue_number: `local` (invoked via `/bug this`; no GitHub issue)
adw_id: `local`
issue_json: `{}` (no issue JSON; bug sourced from the live debugging session — pi orchestrator turn dies before inference)

## Bug Description
With the console header configured for a **pi** orchestrator (`harness: pi`, `provider: zai`, `model: glm-5.1`), submitting a prompt via ⌘K produces **no inference and no visible output**. The orchestrator row gets stuck at `status: :running` with `session_id: nil`, and the console feed shows (at most) a bare error row with no detail.

- **Expected:** the orchestrator turn spawns the pi CLI, streams `SessionStarted → TextDelta/ToolCall … → Done`, the row advances to `:idle`, and the orchestrator can create/dispatch workers via its bound tools.
- **Actual:** the spawned pi process exits with code 1 roughly 200 ms after launch, before any model call. The session runtime synthesizes a generic `provider exited` error, but pi's real diagnostic is discarded, so the failure is invisible in the UI and the DB.

This affects the **pi** orchestrator path only. The Claude orchestrator binds tools over native MCP (`--mcp-config`), not this extension, so it is not impacted by this root cause.

## Problem Statement
The pi orchestrator attaches its agent-management tools by loading a TypeScript extension with `pi -e <priv/orchestrator/pi_extension>` (`RepoBuilder.Harness.Pi.orchestrator_spawn/2`). That extension, `priv/orchestrator/pi_extension/orchestrator-tools.ts`, is written against an **obsolete pi extension API** and crashes pi at load time with `Failed to load extension: pi is not defined`. Because the extension fails, the whole pi process exits non-zero before the model is ever invoked — so the orchestrator "does nothing" despite correct harness/provider/model settings.

Two observability gaps made this undiagnosable from the app:
1. `RepoBuilder.Session.Server` **discards the child process's stderr** (`handle_info({:stderr, …}, state) -> {:noreply, state}`), so pi's `Failed to load extension …` line is thrown away.
2. Synthesized `Event.Error` records are persisted with `payload: scrubbed.raw`, which is `nil` for runtime-synthesized errors, so the `message`/`reason` are lost — `agent_logs` error rows land with an empty `payload: %{}`.

## Solution Statement
1. **Primary fix (makes inference work):** Rewrite `priv/orchestrator/pi_extension/orchestrator-tools.ts` to the current pi extension API used by pi 0.79.6 — a **default-exported function that receives the `pi` host object as its argument** and registers tools via `pi.registerTool({ name, label, description, parameters, execute })`, returning `{ content: [{ type: "text", text }] }`. Keep the exact same six tools and the same `fetch`-to-MCP-over-HTTP binding logic (env `PI_ORCH_BASE_URL` / `PI_ORCH_TOKEN`). This is modeled directly on the installed, working `pi-mcp-adapter` extension, which performs the identical "bridge MCP tools into pi" job.
2. **Regression-prevention fix (makes such failures visible):** In `Session.Server`, capture a bounded tail of child **stderr** and include it in the synthesized error message on a non-zero exit. In `Logs`, persist the diagnostic fields of an `Event.Error` (`message`, `reason`, `retryable`) into `payload` when the event carries no `raw`, so the cause is never silently dropped again.

Both fixes are surgical: one TS file rewrite, two small Elixir edits, plus targeted tests.

## Steps to Reproduce
1. Start the app (`scripts/pg.sh start` then `mix phx.server`) and open `http://localhost:4000`.
2. In the header, set orchestrator **harness = pi**, **provider = zai**, **model = glm-5.1**.
3. Open the ⌘K command modal and submit any prompt (e.g. `testing`).
4. Observe: no assistant output streams; the orchestrator row stays `:running` (`session_id: nil`); the feed shows no useful error.
5. Confirm the underlying cause directly (the exact orchestrator invocation):
   ```bash
   cd /tmp
   PI_SKIP_VERSION_CHECK=1 PI_ORCH_BASE_URL=http://127.0.0.1:4000/x PI_ORCH_TOKEN=t \
     pi -e /data/1.Projects/repo_builder_elixir/priv/orchestrator/pi_extension \
     --append-system-prompt "orchestrator" --mode json --provider zai --model glm-5.1 --approve "testing"
   # => Error: Failed to load extension ".../pi_extension": Failed to load extension: pi is not defined  (exit 1)
   ```
   The same command **without** `-e <extension>` streams a full GLM-5.1 response and exits 0 — proving auth/provider/model are fine and the extension load is the sole blocker.

## Root Cause Analysis
`orchestrator-tools.ts` was authored against an older pi extension contract:

```ts
declare const pi: { registerTool: (def: { …; handler: (args) => Promise<string> }) => void };
// …
for (const tool of tools) { pi.registerTool({ name, description, parameters: <raw JSON schema>, handler }); }
```

It assumes `pi` is a **global** and calls `registerTool` at module top-level. pi 0.79.6 instead injects the host API as the **argument to the module's default export** and uses an `execute` callback. Because no global `pi` exists, evaluating the module throws `ReferenceError: pi is not defined`, which pi reports as `Failed to load extension: pi is not defined` and then exits non-zero. The session runtime sees only `{:exit_status, 256}` → `maybe_synthesize_terminal/2` → `error_event(state, "provider exited: …", :provider_error)`. Inference never starts.

The correct, proven shape (from the installed `pi-mcp-adapter`, which bridges MCP tools into pi exactly like this extension must):

```ts
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"; // type-only; erased at runtime
export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name, label, description,
    parameters: <schema>,                 // raw JSON-schema object (see decision note below)
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      const text = await callTool(name, params as Record<string, unknown>);
      return { content: [{ type: "text", text }] };
    },
  });
}
```

Secondary contributors (why it was invisible, not why it broke):
- `Session.Server` drops stderr (`server.ex` `handle_info({:stderr, _os_pid, _chunk}, state)`), discarding pi's diagnostic line.
- `Logs.persist_event/2` and `Logs.persist_orchestrator_event/2` set `payload: scrubbed.raw`; a synthesized `Event.Error` has `raw == nil`, so `message`/`reason` are dropped and the row stores `payload: %{}`.

## Relevant Files
Use these files to fix the bug:

- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — **the broken extension**; rewrite to the current pi extension API (default-export function + `execute`). This is the primary fix.
- `priv/orchestrator/pi_extension/package.json` — declares `main` and the (stale) peer dependency name; verify/adjust the peer-dependency package name to the one pi 0.79.6 actually uses (`@mariozechner/pi-coding-agent`) so type tooling and docs are accurate. Runtime is unaffected because the import is type-only.
- `lib/repo_builder/harness/pi.ex` — `orchestrator_spawn/2` builds the `-e <extension>` argv + `PI_ORCH_BASE_URL`/`PI_ORCH_TOKEN` env. No behavior change expected; read to confirm the extension path and env contract the rewritten TS must honor (and to confirm whether `--print`/`-p` is needed — see Notes).
- `lib/repo_builder/harness/orchestrating.ex` — the `orchestrator_spawn/2` behaviour + `tool_ctx` type; confirms the binding contract (token in env, never argv).
- `lib/repo_builder/orchestrator/server.ex` — orchestrator turn runner; shows how `Event.Done`/`Event.Error` drive status and why a non-zero pi exit lands as a generic error. No change required, but it is the consumer of the surfaced error.
- `lib/repo_builder/session/server.ex` — **drops stderr** at `handle_info({:stderr, …})` and synthesizes the terminal error in `maybe_synthesize_terminal/2` / `error_event/3`. Edit to capture a bounded stderr tail and fold it into the error message.
- `lib/repo_builder/logs.ex` — `persist_event/2` and `persist_orchestrator_event/2` persist `payload: scrubbed.raw`; edit so an `Event.Error` with no `raw` persists its `message`/`reason`/`retryable`.
- `lib/repo_builder/harness/event.ex` — the canonical `Event.Error` struct (`message`, `reason`, `retryable`, `raw`); read to keep the payload mapping precise and typed.
- `BUILD_PROMPT.md` §4 (event contract) + §4.1 (redaction) + §6 (session runtime/secrets) + §10 (extensibility: add-a-harness contract) — authoritative spec for the harness adapter, the canonical event flow, redaction, and the pi-extension tool-binding mechanism.
- `ai_docs/typed-elixir-standard.md` — enforced typed style (`@spec` on every public function, precise types, `{:ok, t()} | {:error, reason()}`); the always-applies row of `conditional_docs.md`.

### New Files
- `test/repo_builder/logs_orchestrator_error_test.exs` — unit test proving an `Event.Error` (with `raw == nil`) persists its `message`/`reason` into `payload` (fails before the `Logs` fix, passes after).
- `test/repo_builder/session/stderr_surfacing_test.exs` — `SessionCase` test that spawns a tiny script which writes a known line to **stderr** and exits non-zero, asserting the dispatched/persisted `Event.Error` message contains that stderr tail (fails before the `Session.Server` fix, passes after).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Reproduce and lock in the failure (research)
- Read `BUILD_PROMPT.md` §4, §4.1, §6, §10 and `ai_docs/typed-elixir-standard.md`.
- Run the reproduce command from **Steps to Reproduce §5** and confirm `Failed to load extension: pi is not defined` (exit 1). Run the same command without `-e` and confirm a clean GLM-5.1 stream (exit 0). This pins the failure to the extension, not auth/provider/model.
- Inspect a working analog for the exact current API: `pi-mcp-adapter/index.ts` (installed at `…/node_modules/pi-mcp-adapter/index.ts`) — note `export default function mcpAdapter(pi: ExtensionAPI)`, `pi.registerTool({ name, label, description, parameters, execute })`, and the `{ content: [{ type: "text", text }] }` return shape. Also confirm the package name `@mariozechner/pi-coding-agent`.

### 2. Decide the `parameters` representation (small spike)
- Determine whether `pi.registerTool` accepts a **plain JSON-schema object** for `parameters` at runtime, or whether it requires a TypeBox schema (the adapter wraps with `Type.Unsafe(schema)` from `@sinclair/typebox`).
- Verification: after writing the rewrite (next step), the Step-7 `pi -e … -p` command must register the tools without error. Prefer the plain JSON-schema object first (zero new runtime dependency, most minimal). Only if pi rejects it, fall back to `Type.Unsafe(...)` and ensure `@sinclair/typebox` resolves for the `-e`-loaded extension (vendor it via the extension's `package.json` + `npm install` in that dir). Record the outcome in **Notes**.

### 3. Rewrite the pi extension (primary fix)
- Rewrite `priv/orchestrator/pi_extension/orchestrator-tools.ts` to:
  - `import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";` (type-only).
  - `export default function (pi: ExtensionAPI) { … }` and register each of the six tools **inside** that function via `pi.registerTool`.
  - Replace `handler: (args) => Promise<string>` with `async execute(_toolCallId, params, _signal, _onUpdate, _ctx)` that calls the existing `callTool(name, params as Record<string, unknown>)` and returns `{ content: [{ type: "text", text }] }`.
  - Keep `BASE_URL`/`TOKEN` from `process.env.PI_ORCH_BASE_URL`/`PI_ORCH_TOKEN`, the JSON-RPC 2.0 `tools/call` body, the bearer header, and all six tool definitions (`create_agent`, `command_agent`, `list_agents`, `check_agent_status`, `interrupt_agent`, `start_adw`) byte-for-byte identical in name/description/parameters.
  - Remove the obsolete `declare const pi` global and the top-level registration loop.
- Update `priv/orchestrator/pi_extension/package.json` `peerDependencies` key to `@mariozechner/pi-coding-agent` (the package the installed extensions resolve), keeping `"main": "orchestrator-tools.ts"`.
- Do **not** change `RepoBuilder.Harness.Pi.orchestrator_spawn/2` unless Step 7 shows the process hangs on open stdin (see Notes re `--print`).

### 4. Surface child stderr on failure (regression prevention)
- In `lib/repo_builder/session/server.ex`:
  - Add a bounded `stderr_tail` (e.g. last ~2 KB / last N lines) to the session `State` struct (`typedstruct`, with a precise `@type` and an `@enforce`/default consistent with the existing fields).
  - In `handle_info({:stderr, os_pid, chunk}, %State{os_pid: os_pid} = state)`, append `chunk` to `stderr_tail` (truncating to the cap) instead of discarding it. Keep stderr **out** of stdout line framing.
  - In `maybe_synthesize_terminal/2` (non-clean path) and/or `error_event/3`, include the trimmed `stderr_tail` in the `Event.Error.message` (e.g. `"provider exited: {:exit_status, 256}\nstderr: …"`). Preserve all `@spec`s and the redaction boundary (stderr is process diagnostics, not secrets, but keep the existing `Redact` flow intact).

### 5. Persist error diagnostics into payload (regression prevention)
- In `lib/repo_builder/logs.ex`, in both `persist_event/2` and `persist_orchestrator_event/2`, compute `payload` so that for an `%Event.Error{}` whose `raw` is `nil`/empty, the persisted payload carries `%{"message" => …, "reason" => to_string(reason), "retryable" => …}` (redacted). For all other events, keep `payload: scrubbed.raw` unchanged. Add a small private `@spec`'d helper (e.g. `error_payload/1`) rather than inlining, to keep both call sites identical. Keep harness mapping (`to_string(event.harness)`) as-is.

### 6. Add regression tests (Elixir layer)
- `test/repo_builder/logs_orchestrator_error_test.exs`: build `%Event.Error{harness: :pi, message: "boom", reason: :provider_error, retryable: false, raw: nil}`, call `Logs.persist_orchestrator_event/2`, reload the row, assert `event_type == :error`, `harness == "pi"`, and `payload["message"]`/`payload["reason"]` are present and correct. Assert the same for `persist_event/2`.
- `test/repo_builder/session/stderr_surfacing_test.exs` (use `RepoBuilder.SessionCase`): spawn a throwaway script (write a temp file like `#!/bin/sh\n echo "EXT_LOAD_FAILED: pi is not defined" 1>&2; exit 1`) as the session executable, and assert the resulting `Event.Error` (broadcast and/or persisted) `message` contains `EXT_LOAD_FAILED`. This is the direct regression guard for the "invisible failure" class.

### 7. Verify the extension actually loads and inference runs
- Run the extension-load check (must exit 0 and **not** print `Failed to load extension`):
  ```bash
  PI_SKIP_VERSION_CHECK=1 PI_ORCH_BASE_URL=http://127.0.0.1:4000/x PI_ORCH_TOKEN=t \
    pi -e priv/orchestrator/pi_extension --append-system-prompt "orchestrator" \
    --mode json --provider zai --model glm-5.1 --approve --no-session -p "list your tools" \
    | tail -5
  ```
- Then verify end-to-end in the live app: with orchestrator harness=pi/provider=zai/model=glm-5.1, submit a prompt at `http://localhost:4000` and confirm via Tidewave `project_eval`/`execute_sql_query` that the orchestrator row reaches `:idle` (or `:error` with a now-informative `agent_logs` payload), and that `SessionStarted`/`Done` events are persisted. Optionally capture a Tidewave Web screenshot of the console as visual proof.

### 8. Run the full validation suite
- Run every command in **Validation Commands** and ensure all are green with zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- **Reproduce BEFORE the fix (must fail with the API error):**
  ```bash
  PI_SKIP_VERSION_CHECK=1 PI_ORCH_BASE_URL=http://127.0.0.1:4000/x PI_ORCH_TOKEN=t \
    pi -e priv/orchestrator/pi_extension --append-system-prompt o --mode json \
    --provider zai --model glm-5.1 --approve --no-session -p "hi"; echo "exit=$?"
  # before: prints "Failed to load extension: pi is not defined", exit=1
  ```
- **Reproduce AFTER the fix (must load and stream, exit 0):**
  ```bash
  PI_SKIP_VERSION_CHECK=1 PI_ORCH_BASE_URL=http://127.0.0.1:4000/x PI_ORCH_TOKEN=t \
    pi -e priv/orchestrator/pi_extension --append-system-prompt o --mode json \
    --provider zai --model glm-5.1 --approve --no-session -p "hi"; echo "exit=$?"
  # after: no "Failed to load extension" line, exit=0
  ```
- `mix test test/repo_builder/logs_orchestrator_error_test.exs` — error diagnostics land in `payload`.
- `mix test test/repo_builder/session/stderr_surfacing_test.exs` — stderr tail is surfaced in the error message.
- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite (Postgres-backed) with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings and no stale ignore filters.

## Notes
- **Why no LiveView test file:** the console already surfaces orchestrator failures via `put_flash(socket, :error, …)` in `ConsoleLive.run_orchestrator/2`, and the fix touches the harness extension, the session runtime, and the logs context — not LiveView rendering. Forcing a `Phoenix.LiveViewTest` here would test pre-existing flash behavior, not the fix. The orchestrator turn spawns a **real** external CLI, which is not exercisable in `LiveViewTest`; the meaningful regression guards live at the harness/logs layer (Step 6) plus the `pi -e … -p` extension-load check (Step 7). A Tidewave/Playwright screenshot of `http://localhost:4000` is an optional manual proof.
- **`--print`/`-p` watch-item:** the orchestrator command (`Pi.command/1` + `orchestrator_spawn/2`) does **not** pass `--print`/`-p`. With `--mode json` and a prompt arg pi processed and exited 0 in manual runs, but the app keeps the child's stdin open via erlexec. After the extension loads, confirm the orchestrator session reaches a terminal `Done` and does not hang waiting on stdin. If it hangs, the minimal follow-up is to append `--print`/`-p` in `RepoBuilder.Harness.Pi.command/1` (or `orchestrator_spawn/2`) — but only make that change if Step 7 demonstrates a hang; do not pre-emptively add it.
- **Package name:** working extensions on this machine import `@mariozechner/pi-coding-agent`; the repo's `package.json` referenced `@earendil-works/pi-coding-agent`. The TS `import type` is erased at runtime so this does not affect loading, but align the `peerDependencies` name for correct typing/docs.
- **No new mix dependency** is expected. The only possible new dependency is the npm `@sinclair/typebox` for the TS extension, and only if Step 2 shows pi rejects a plain JSON-schema `parameters` object; if needed, vendor it under the extension dir (not in `mix.exs`) and record it here.
- **Tidewave during fix:** use `get_logs` to read the synthesized error, `project_eval`/`execute_sql_query` to inspect the orchestrator row + `agent_logs` payloads, and `get_source_location`/`get_docs` for exact-version Elixir/Ecto behavior — per `conditional_docs.md`.
- **Claude orchestrator** path is unaffected (binds tools via `--mcp-config`/`.mcp.json`, not `-e`); switching the header harness to `claude` is a working interim path while this fix lands.
