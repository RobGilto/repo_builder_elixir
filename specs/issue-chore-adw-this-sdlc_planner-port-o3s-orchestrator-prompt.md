# Chore: Finish porting the o3s orchestrator system prompt (the "prompt drop-in")

## Metadata
issue_number: `chore`
adw_id: `this`
issue_json: `out` (interactive request — no GitHub issue)

## Chore Description
Carry over the remaining **prompt-level** elements of the reference
`orchestrator_3_stream` (o3s) orchestrator system prompt
(`backend/prompts/orchestrator_agent_system_prompt.md`) into our
`RepoBuilder.Orchestrator.SystemPrompt.build/1`. The tool surface, subagent-template
`{{SUBAGENT_MAP}}`, `report_cost`/context-window, and the context-management block are
**already ported**; what remains is the o3s prompt's *narrative + dynamic* bits that we
dropped or never carried:

1. **`{{AVAILABLE_ADW_TYPES}}` block** — o3s injects a live list of the available ADW
   workflows (it globs `adws/adw_workflows/adw_*.py`) so the brain knows which ADWs it
   can launch, and `start_adw` takes a `workflow_type`. **Our `start_adw` is hardcoded to
   one seeded `WorkflowEngine.create_example_workflow/2` with no `workflow_type` param and
   no listing** — so we have nothing to inject yet.
2. **`ultrathink` keyword guidance** — o3s recognizes `ultrathink` to raise thinking mode;
   maps onto our existing `reasoning_effort` (`:max`).
3. **Inline `/slash-command` placement guidance** — telling the brain it may put a custom
   `/slash-command` directly in the command field passed to `command_agent`.
4. **Narrative framing** — the "conductor of the multi-agent orchestra" voice, the
   agent-specialization examples, and the workflow-pattern section (prose only).
5. **(Optional) model-alias table** — o3s pins `opus/sonnet/haiku` → concrete model ids in
   prose. Ours resolves models via the registry + tier roster, so this is informational
   only; port only if it adds operator clarity (likely skip).

> **HARD DEPENDENCY — this chore is BLOCKED and must NOT start until the ADW feature lands.**
> Item (1), the `{{AVAILABLE_ADW_TYPES}}` block, depends on the separate **ADW workflow +
> ADW workflow-type discovery** feature: there must first be (a) more than one ADW workflow
> definition, (b) a way to *enumerate* the available workflows, and (c) a `workflow_type`
> parameter on `start_adw` (both bindings) for the injected list to mean anything. Until
> that feature exists, there is no list to inject and `start_adw` cannot honor a chosen type.
> The remaining prose items (2)–(5) are independent and *could* land earlier, but per the
> agreed sequencing the whole prompt drop-in is **parked behind** the ADW feature: do the
> ADW feature work first, then resolve this chore on top of it.

This is the LAST substantive gap from porting o3s into `repo_builder_elixir`.

## Relevant Files
Use these files to resolve the chore:

- `lib/repo_builder/orchestrator/system_prompt.ex` — the prompt builder. Add an
  `available_adw_types_block/0` (mirroring the existing `subagent_map_block/0` /
  `tools_block/0` / `context_management_block/0`) and reference it in `build/1`; add the
  `ultrathink` + inline-`/slash-command` + narrative prose to the operating-rules text.
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `start_adw` def: the `workflow_type`
  parameter must exist here (added by the ADW feature) before the prompt can describe it.
- `priv/orchestrator/pi_extension/orchestrator-tools.ts` — the pi mirror of `start_adw`
  (dual binding, §10); the `workflow_type` param must be mirrored here too.
- `lib/repo_builder/orchestrator/tools.ex` — `start_adw` handler; today calls
  `WorkflowEngine.create_example_workflow/2`. The ADW feature replaces this with a
  type-dispatched launch; this chore only needs the *enumeration* read-side to exist.
- `lib/repo_builder/workflow_engine.ex` (+ `lib/repo_builder/workflow_engine/`) — the ADW
  feature must expose a `@spec`'d "list available workflow definitions" function for the
  prompt block to read (the analog of o3s globbing `adws/adw_workflows/adw_*.py`). Confirm
  its shape before wiring the block.
- `adws/**` — the Python `uv` ADW scripts; reference for what "workflow types" should
  enumerate (the o3s analog). Decide in the ADW feature whether types come from the Elixir
  `WorkflowEngine` registry or the Python `adws/` set; this chore consumes whatever it lands.
- `test/repo_builder/orchestrator/system_prompt_test.exs` — extend with assertions that the
  `{{AVAILABLE_ADW_TYPES}}` block lists a seeded workflow type and renders an empty-state
  fallback when none, and that the `ultrathink` guidance is present.
- Reference (read-only, NOT in this repo):
  `/data/1.Projects/tactical-agentic-coding/tac-14/orchestrator-agent-with-adws/apps/orchestrator_3_stream/backend/prompts/orchestrator_agent_system_prompt.md`
  and `backend/modules/orchestrator_service.py` (`_load_system_prompt`, the `{{SUBAGENT_MAP}}`
  + `{{AVAILABLE_ADW_TYPES}}` substitution) — the source prompt + injection to mirror.
- `BUILD_PROMPT.md` §3 (typed style), §10 (dual tool binding), §11 (`priv/` layout).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Confirm the blocking ADW feature has landed (gate)
- Verify the prerequisite feature exists before doing anything else: there is a `@spec`'d
  way to enumerate available ADW workflow types, and `start_adw` accepts a `workflow_type`
  in BOTH `tool_catalog.ex` and `priv/orchestrator/pi_extension/orchestrator-tools.ts`.
- If that enumeration/param does NOT yet exist, STOP — this chore is blocked. Do the ADW
  workflow + workflow-type discovery feature first, then return here.

### 2. Add the `{{AVAILABLE_ADW_TYPES}}`-equivalent block to the system prompt
- In `system_prompt.ex`, add `available_adw_types_block/0` reading the workflow-type
  enumeration from the ADW feature (the `WorkflowEngine` list fn), rendering a markdown
  bullet list `- <type>: <one-line>` with an empty-state fallback (mirror
  `subagent_map_block/0`). Reference it in `build/1` near the tools/subagent blocks.

### 3. Port the o3s prompt prose niceties
- Add `ultrathink` guidance (raise reasoning effort to `:max`), inline-`/slash-command`
  placement guidance for `command_agent`, and the "conductor"/specialization/workflow-pattern
  narrative to the operating-rules text. Keep it concise and consistent with the existing
  voice. Skip the model-alias table unless it adds operator clarity.

### 4. Cover with SystemPrompt tests
- Extend `test/repo_builder/orchestrator/system_prompt_test.exs`: the ADW-types block lists a
  seeded workflow type and renders the empty-state fallback when none; the `ultrathink` and
  inline-slash-command guidance strings are present.

### 5. Run the validation commands
- Run every command in **Validation Commands** and fix any failure until all are green.

## Validation Commands
Execute every command to validate the chore is complete with zero regressions.

- `mix compile --warnings-as-errors` - Compile clean; the gradual set-theoretic type checker and `warnings_as_errors` must pass.
- `mix test test/repo_builder/orchestrator/system_prompt_test.exs` - The new prompt-block assertions pass.
- `mix test --warnings-as-errors` - Run the full ExUnit suite with zero failures.
- `mix format --check-formatted` - Ensure code is formatted.
- `mix credo --strict` - Lint, including the "every public function has an `@spec`" convention.
- `mix dialyzer` - `@spec`/contract checking with no new warnings.

## Notes
- **Sequencing (explicit):** STASHED/PARKED. This is the "prompt drop-in" half of the o3s
  port. It is intentionally deferred **behind** the ADW workflow + ADW workflow-type
  discovery feature — that feature is the real next focus; this chore lands on top of it.
- **No new dependencies.** Pure prompt-assembly + tests; reuses the existing `SystemPrompt`
  block pattern and whatever workflow-enumeration the ADW feature exposes.
- **Why blocked:** the `{{AVAILABLE_ADW_TYPES}}` block has nothing to list and `start_adw`
  has no `workflow_type` to honor until the ADW feature provides multiple workflows, an
  enumeration read-side, and the `workflow_type` param (both bindings, §10). Resolving this
  chore before that would inject an empty/misleading block.
- **Already ported (do NOT redo):** `{{SUBAGENT_MAP}}` (subagent templates), the tools
  block, `report_cost` + `ContextWindow`, and the context-management/compaction block are
  live in `SystemPrompt.build/1`. Confirm against the file before adding anything.
- **Reference prompt** to diff against lives outside this repo at the o3s path above; do not
  copy its Claude-only / model-alias / SDK-hook specifics — our platform is multi-harness and
  substitutes those (canonical event normalization instead of SDK hooks, registry/tier roster
  instead of pinned aliases).
- Optional runtime check via **Tidewave** once unblocked: `project_eval`
  `RepoBuilder.Orchestrators.get_or_create_default() |> elem(1) |> RepoBuilder.Orchestrator.SystemPrompt.build()`
  to eyeball the `{{AVAILABLE_ADW_TYPES}}` block.
