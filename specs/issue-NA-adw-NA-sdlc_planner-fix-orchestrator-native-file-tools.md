# Bug: Orchestrator can use the harness's native file/shell tools and writes files itself instead of delegating

## Metadata
issue_number: `NA`
adw_id: `NA`
issue_json: `{}` (interactive `/bug` invocation — see Bug Description for the verbatim report)

## Bug Description
The orchestrator is a **delegation-only meta-agent**: per its system prompt it "does NOT
write code or run shell commands yourself … decide which worker agents to create and
what tasks to dispatch." In practice it **wrote a real file itself** instead of dispatching
to a worker.

Observed (operator session, harness `pi` / provider `zai` / model `glm-5.1`):

- Console chat showed: `Simple task — I'll create it directly.` → `Successfully wrote 38
  bytes to /data/1.Projects/repo_builder_elixir/zephyr-notes-7f3a.md` → `Done. Created
  zephyr-notes-7f3a.md in the working directory…`.
- The file `zephyr-notes-7f3a.md` was **actually written to the project root** (operator
  confirmed it existed and deleted it manually).
- The orchestrator system log also recorded `orchestrator tool write: :unknown_tool` at
  the same time — the model also tried the orchestrator's *bound* tool channel for `write`
  (which only exposes meta-tools), got rejected, and the actual write went through the
  **harness's own native file tool**.

**Expected:** the orchestrator can only call its meta-tools (`create_agent`,
`command_agent`, `start_adw`, …). Any file/shell work is impossible for it — it must
`create_agent` + `command_agent` a worker. It should be **structurally incapable** of
touching the filesystem, not merely told not to.

**Actual:** the orchestrator session runs the underlying coding-agent CLI (pi / Claude
Code) with its **full native toolset** (write/edit/read/bash) available and
auto-approved, restrained only by a soft system-prompt instruction. A model that drifts
from that instruction (see the contributing context-loss factor below) writes directly.

A contributing factor reported alongside this: the long-lived orchestrator session had
accumulated ~817k tokens / $22.86, and its working context was **auto-compacted to ~357
tokens** (0.2% usage), after which the model lost the prior conversation and its role
discipline — and, lacking any hard tool guardrail, acted on that drift.

This is made materially worse by the new **working-directory** feature: the operator can
point the orchestrator's cwd at the **project root**, so a stray native write lands
inside the live repository.

## Problem Statement
The orchestrator session is bound to its meta-tools (via Claude MCP / pi extension) but is
**never restricted from the harness's built-in tools**. The "no file writes" rule lives
only in the system prompt — a soft constraint. There is no hard guarantee that the
orchestrator cannot read/write/edit files or run shell commands, so a drifting or
context-compacted model bypasses delegation and mutates the filesystem directly.

## Solution Statement
Make delegation the **only** capability the orchestrator session has: when spawning the
orchestrator, pass the harness's tool-restriction flags so **only the bound orchestrator
tools are available** and all native file/edit/read/shell tools are disabled — for BOTH
orchestrator-capable harnesses.

- **Claude** (`claude.ex` `orchestrator_spawn/2`): add an allowlist that permits only the
  generated MCP server and denies built-ins — e.g. `--allowedTools "mcp__repo_builder"`
  (allow the whole bound server) and/or `--disallowedTools "Write Edit Bash Read ..."`.
  Verify exact semantics against the installed CLI (`claude --help`) before committing.
- **pi** (`pi.ex` `orchestrator_spawn/2`): pass pi's "no built-in tools" / tool-restriction
  flag so the orchestrator runs with ONLY the loaded `-e` extension's tools. Confirm the
  exact flag from pi's `--help` / README (pi ships built-in file/bash tools by default).

This is a hard, structural guardrail that holds regardless of context state, model
strength, or prompt drift. The system-prompt instruction stays as documentation, but is
no longer the only thing standing between the orchestrator and the filesystem.

**Critical scope guarantee — workers MUST keep write/edit/bash.** Worker agents do the
actual coding and need the full native toolset. The fix does not touch them: orchestrator
and worker sessions share the same base `command/1`, and the restriction is added ONLY
inside `orchestrator_spawn/2`, which is reached ONLY for the orchestrator. The branch is
`Session.Server.maybe_orchestrator_spawn/4` (`lib/repo_builder/session/server.ex:219-232`):
a worker is started with `orchestrator_ctx: nil` and returns the base args UNCHANGED
(full native tools); the orchestrator is started with an `orchestrator_ctx`
(`Orchestrator.Server.handle_continue/2`, `server.ex:169`) and is the only session that
merges the binding (and now restriction) args. The orchestrator also never *legitimately*
needs write tools: "create an agent" is the meta-tool `create_agent` (then `command_agent`
dispatches the task to that worker, who writes the code), so blocking its native tools
costs zero capability. (The orchestrator's `.mcp.json` is written by the Elixir runtime,
not a model tool, so the restriction does not affect it.)

Secondary hardening (optional, smaller): surface the orchestrator's own context-usage and
nudge/auto-compact the orchestrator session at a high-token threshold (it already exposes
`report_cost`/usage and has a worker-facing `compact_agent`, but nothing guards its OWN
session) — this addresses the contributing context-loss factor but is NOT required to
close the security/correctness hole, which the tool restriction fixes on its own.

## Steps to Reproduce
1. Configure an orchestrator on an orchestrator-capable harness (`pi` with a real
   provider/model, or `claude`) and set a working directory (e.g. the project root) via
   the prompt-modal directory picker.
2. Give the orchestrator a trivial "create a file" task (e.g. "create a small notes file
   in the working directory").
3. Observe: the orchestrator writes the file itself (a real file appears in the cwd) and
   reports success in chat, instead of `create_agent` + `command_agent` to a worker.
4. Check the orchestrator system logs: a `orchestrator tool <write/bash/edit>:
   :unknown_tool` entry appears for the meta-tool channel, while the native harness tool
   performed the actual write.

Deterministic (no live model) reproduction for the regression test: assert that
`Harness.Claude.orchestrator_spawn/2` and `Harness.Pi.orchestrator_spawn/2` emit the
tool-restriction flags (today they do not). See Step by Step Tasks.

## Root Cause Analysis
The orchestrator session is spawned by each adapter's `orchestrator_spawn/2`:

- `lib/repo_builder/harness/claude.ex:19-40` returns
  `["--mcp-config", path, "--strict-mcp-config"] ++ [system_prompt_flag, system_prompt] ++
  resume_args`. It binds the MCP meta-tools and (via `command/1`,
  `claude.ex:106-111`) adds `--dangerously-skip-permissions` for the orchestrator. It
  **never** passes `--allowedTools`/`--disallowedTools`, so Claude's native
  Write/Edit/Bash/Read remain available AND are auto-approved by the skip-permissions
  flag.
- `lib/repo_builder/harness/pi.ex:30-44` returns `["-e", @pi_extension,
  system_prompt_flag, system_prompt] ++ resume_args` plus the tool-endpoint env. It loads
  the orchestrator extension but **does not disable pi's built-in file/bash tools**, so
  the orchestrator model can write files directly (confirmed: the file was really
  created).

The orchestrator's *bound* tool set (`lib/repo_builder/orchestrator/tools.ex:46-79`) is
meta-only: `create_agent`, `command_agent`, `list_agents`, `check_agent_status`,
`interrupt_agent`, `start_adw`, `update_agent`, `delete_agent`, `read_system_logs`,
`check_adw`, `get_config`, `configure_tier`, `set_orchestrator_config`, `report_cost`,
`compact_agent`, `*_agent_template`. A `write` call falls through to `{:error,
:unknown_tool}` (`tools.ex:79`) — which is why the meta channel logged `:unknown_tool`.
But that allowlist governs ONLY the bound channel; it does nothing about the harness's
own native tools, which are a separate, unrestricted surface.

So the orchestrator is "delegation-only" by **convention** (system prompt) but
"full-coding-agent" by **capability** (native harness tools). The single missing control
is a per-harness tool restriction on the orchestrator spawn. The context-compaction event
(~817k tokens → ~357 tokens working context) is the trigger that made the model exercise
the latent capability, but the capability should never have existed.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/harness/claude.ex` — `orchestrator_spawn/2` (lines 19-40) and
  `command/1`/`permission_args/1` (66-111). Add the Claude tool-restriction flags here so
  the orchestrator session is limited to the bound MCP server (no native file/shell
  tools). Primary fix site for Claude.
- `lib/repo_builder/harness/pi.ex` — `orchestrator_spawn/2` (lines 30-53). Add pi's
  built-in-tool-disable / restriction flag so the orchestrator runs with only the `-e`
  extension tools. Primary fix site for pi.
- `lib/repo_builder/harness/orchestrating.ex` — the `tool_ctx` typedoc/type (26-48) and
  the `orchestrator_spawn/2` callback contract. If the restriction needs to be driven by
  the canonical orchestrator tool names (rather than hardcoded per adapter), add an
  `:allowed_tool_names` (or `:restrict_tools`) field here and thread it from the server.
- `lib/repo_builder/orchestrator/tools.ex` — `dispatch/3` (46-79) is the SOURCE OF TRUTH
  for the orchestrator's meta-tool names; reference it (or expose a `tool_names/0`) if the
  allowlist is data-driven rather than a per-adapter constant.
- `lib/repo_builder/orchestrator/server.ex` — builds `tool_ctx` (≈220-230) and runs the
  turn; the place to thread any new `tool_ctx` field and (for the optional secondary
  hardening) to guard the orchestrator's own context usage.
- `config/config.exs` — the harness registry (`:harnesses`) documents each adapter's
  autonomy/orchestrating flags; note any new behavior here if relevant.
- `BUILD_PROMPT.md` — §4.3 (harness adapters / permission model), §10 (extensibility: the
  orchestrator-tool-binding seam). The fix must keep the "one adapter + one registry
  entry" extensibility property and the typed-style guarantees.
- `.claude/commands/conditional_docs.md` — read to check whether any conditional docs
  apply (e.g. an orchestrator/harness security doc) and include matches here.

### New Files
- `test/repo_builder/harness/orchestrator_tool_restriction_test.exs` — a unit test
  asserting that `Harness.Claude.orchestrator_spawn/2` and `Harness.Pi.orchestrator_spawn/2`
  emit the tool-restriction flags (and, for Claude, that the orchestrator `command/1`
  output combined with the spawn args restricts native tools). Fails before the fix,
  passes after. Pure argv assertions — no live CLI.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the root cause at runtime (Tidewave)
- Read `BUILD_PROMPT.md` §4.3 and §10, `AGENTS.md`, and `.claude/commands/conditional_docs.md`.
- Use Tidewave `get_logs` / `execute_sql_query` to confirm an `orchestrator tool write:
  :unknown_tool` entry exists for the meta channel while a real file was created in the
  cwd (the capability came from the harness's native tools, not the bound channel).
- Inspect `orchestrator_spawn/2` for both adapters and confirm neither emits a tool
  allowlist/denylist today.

### 2. Pin down the exact CLI flags (verify, don't assume)
- For Claude: run `claude --help` (and/or the claude-api/CLI docs via `get_docs`) to
  confirm the precise `--allowedTools` / `--disallowedTools` syntax and whether, under
  `--dangerously-skip-permissions`, an allowlist still removes built-in tool
  *availability* (not just permission). Capture the canonical MCP tool-name pattern
  (`mcp__repo_builder__*`) the bound server exposes.
- For pi: run `pi --help` (and consult the pi README in `ai_docs`/memory) to find the flag
  that disables built-in tools or restricts the session to extension-provided tools only.
- Record the verified flags in the plan's Notes / code comments.

### 3. Restrict the Claude orchestrator session to bound tools only
- In `claude.ex` `orchestrator_spawn/2`, append the verified restriction (e.g.
  `--allowedTools "mcp__repo_builder"` and/or `--disallowedTools "Write Edit MultiEdit
  NotebookEdit Bash Read Glob Grep WebFetch ..."`) so the orchestrator cannot invoke any
  native file/shell tool. Keep the `@spec`s and the existing `{args, env}` shape; the
  build is `--warnings-as-errors`.
- Add a comment pointing at `Orchestrator.Tools.dispatch/3` as the source of truth for the
  meta-tool surface.

### 4. Restrict the pi orchestrator session to extension tools only
- In `pi.ex` `orchestrator_spawn/2`, append pi's verified built-in-tool-disable flag so
  only the `-e` extension's orchestrator tools are callable. Preserve the env-only token
  rule and the `{args, env}` shape.

### 5. (If data-driven) thread the allowlist through the behaviour
- Only if step 3/4 need the canonical tool names rather than a per-adapter constant: add
  `:allowed_tool_names` to `Orchestrating.tool_ctx` (and its typedoc), expose
  `Orchestrator.Tools.tool_names/0`, and populate it in `Server.tool_ctx/2`. Otherwise keep
  the restriction as a per-adapter constant (more surgical) and skip this step.

### 6. Regression test (fails before, passes after)
- Create `test/repo_builder/harness/orchestrator_tool_restriction_test.exs`:
  - Build a representative `tool_ctx` and call `Harness.Claude.orchestrator_spawn/2`;
    assert the returned args include the Claude tool restriction (allow MCP server / deny
    native file+shell tools).
  - Call `Harness.Pi.orchestrator_spawn/2`; assert the returned args include pi's
    built-in-tool-disable flag.
  - **Worker-unaffected guarantee (MUST):** assert the plain WORKER spawn keeps full
    tools — call `adapter.command/1` for a worker (no `:orchestrator_ctx`) and assert the
    base argv does NOT contain the restriction flags; and/or unit-test
    `Session.Server.maybe_orchestrator_spawn/4` with `orchestrator_ctx: nil` returns the
    base args unchanged (workers retain Write/Edit/Bash). This locks in that the fix is
    scoped to the orchestrator only.
  - (Optional) assert the meta-tool channel still rejects `write` via
    `Orchestrator.Tools` (`:unknown_tool`) so the two layers are consistent.

### 7. (Optional) secondary hardening — orchestrator self-context guardrail
- If in scope: in `Orchestrator.Server`, track the orchestrator session's context/token
  usage (already surfaced via usage events) and either warn the operator or trigger a
  self-compaction when it crosses a high threshold, so the model is less likely to drift
  after auto-compaction. Keep this additive and behind the same canonical event flow; it
  does NOT replace the tool restriction.

### 8. Run the Validation Commands
- Run every command below; all green with zero regressions. Manually re-run the repro from
  "Steps to Reproduce" against a live orchestrator and confirm it now `create_agent` +
  `command_agent`s a worker (and that a direct native write is no longer possible).
- Note the two known-unrelated failures: the pre-existing `test_orchestration_console_test.exs`
  `spawn failed: env - invalid env argument #234` (erlexec env gotcha). Confirm they are
  unchanged.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `mix test test/repo_builder/harness/orchestrator_tool_restriction_test.exs` — the new
  restriction regression test passes (and failed before the fix).
- `mix test test/repo_builder/orchestrator/server_test.exs test/repo_builder/harness` —
  orchestrator/harness suites stay green.
- `mix compile --warnings-as-errors` — clean compile; gradual type checker + warnings gate pass.
- `mix test --warnings-as-errors` — full suite; no new failures (only the known erlexec
  `env - invalid env argument` spawn cases may remain, unchanged).
- `mix format --check-formatted` — formatting clean.
- `mix credo --strict` — lint passes, including the `@spec`-on-every-public-function gate.
- `mix dialyzer` — no new contract warnings; no stale ignore filters.

## Notes
- **Scope:** the surgical fix is the per-harness tool restriction (steps 3–4 + test). The
  context-loss item is a *contributing factor*, not the defect — the structural fix closes
  the hole regardless of context state. Keep the optional self-context guardrail (step 7)
  out unless explicitly requested, to stay minimal.
- **Why this is also a safety issue:** with the new working-directory picker, the
  orchestrator cwd can be the live repo, so an unrestricted native write mutates project
  files. The restriction also protects against accidental `bash`/`edit` on the repo.
- **Extensibility invariant (§10):** any third orchestrator-capable harness must likewise
  restrict its native tools in its own `orchestrator_spawn/2`; add a one-line note to the
  `Orchestrating` behaviour doc so future adapters don't reintroduce the hole.
- **Verify, don't assume, the CLI flags** — `--allowedTools`/`--disallowedTools` (Claude)
  and pi's built-in-tool flag must be confirmed against the installed CLIs; their exact
  spelling/semantics drive the fix. The platform never `String.to_atom`s untrusted input,
  so any tool-name list stays as strings in argv.
- **Separate, unrelated crash seen in the same session (do NOT fold in here):** a LiveView
  `KeyError key :timezone not found` was observed on `open_dir_picker`. It is a distinct
  bug in `RepoBuilderWeb.ConsoleLive` (a render/handler path that reads `@timezone` /
  `socket.assigns.timezone` without that assign being present on that path — see
  `console_live.ex:110,230,436`). Track it as its own issue.
```
