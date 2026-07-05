# Orchestrator System Prompt — Dedupe Ledger

> Review artifact for the refactor planned in
> `specs/orchestrator-system-prompt-refactor.html`. Every deletion in the
> `system_prompt.ex` diff must pair with a row here — a reviewer can walk
> old-render → this ledger → new-render and account for every dropped line.

## Byte counts (`SystemPrompt.build/1`, `fake` harness, dev DB)

| Variant | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| no-repo (`working_dir: nil`, no project) | 33,983 | 20,781 | −38.9% |
| with-repo (`working_dir: platform root`, resolves registered project) | 39,412 | 30,748 | −22.0% |

(Plan targets were −40% / −25%; actuals fell just short because the with-repo
render carries irreducible per-project content — primer, stack contract,
expertise, reflections — and no policy was trimmed to hit a number.)

## A — Concept → single-home mapping

Anchors reference `lib/repo_builder/orchestrator/system_prompt.ex` (SP) at the
pre-refactor revision and `lib/repo_builder/orchestrator/tool_catalog.ex` (TC)
by tool name.

| # | Concept | Occurrences (before) | Single home (after) | Other mentions reduced to |
|---|---------|----------------------|---------------------|---------------------------|
| 1 | ADW selection ladder + decompose-into-runs + cross-repo `working_dir` rules | SP operating rules :68-85; TC `start_adw` (full ladder restated) | §5 Dispatch reference → "ADWs" prose | `start_adw` summary: launch + run id + pointer to the ADW section |
| 2 | `compact_self` safety / rehydrate-on-resume / durable workstreams | SP context mgmt :487-491; SP external_memory_block :654-668; TC `compact_self` | §1 Durable memory (promoted `external_memory_block`) | context-mgmt: one cross-ref line; `compact_self` summary terse |
| 3 | One step per turn / don't poll / re-engaged on return | SP drive loop :551-553; SP message-queue :134-148; SP working-rhythm :150-154 | §2 Core loop → turn discipline | working-rhythm section deleted (ADW "observe, don't interfere" line moved to §5 ADWs); queue block merged in |
| 4 | VERIFY against the real tree, never trust a self-report | SP drive loop :548-550; SP phased delivery :584-585; TC `report_complete`; TC `record_stage`; TC `inspect_repo` | §2 Core loop → canonical VERIFY rule | phase machine: "verify first (see Core loop)"; tool summaries drop the restatement |
| 5 | Subagent template roster (printed twice per render) | SP `subagent_map_block` :100-101; SP `worker_roles_block` :126-127; TC `list_agent_templates` | §5 Dispatch reference → one "Worker templates & roles" block | `worker_roles_block/0` deleted; its empty-state role names folded into the kept block; tool summary points at the block |
| 6 | `clear_context` vs `compact_agent` + ≈80% proactive rule | SP context mgmt :480-491; TC `clear_context`; TC `compact_agent` | §4 Context management | tool summaries name the counterpart tool in one line |
| 7 | Quality-gate two-call protocol + fix loop | SP phased-delivery test bullet :590-594; SP quality_gate_block :636-639; TC `run_quality_gate` | §3 Quality gate block | test-stage bullet: one line + cross-ref; tool summary: two-mode hint + cross-ref |
| 8 | Focus discipline (`set_focus` before spend) | SP drive loop :554-559; TC `set_focus`; TC `clear_focus` | §2 Core loop | tool summaries terse |
| 9 | Worker tier semantics (fast/main/heavy/leader) | SP operating rules :44-46; TC `create_agent`; tiers listing :97-98 | §5 Dispatch reference, above the rendered tier roster | `create_agent` summary keeps only "prefer `category`" |
| 10 | Goal/progress ledger (durable goal, record every turn, stall/replan) | SP drive loop :541-547, :560-562; TC `set_goal` / `record_progress` / `get_ledger` | §2 Core loop | tool summaries terse |
| 11 | Workstream stage-machine record/advance semantics | SP phased delivery :583-597; TC `record_stage` / `plan_phases` / `create_workstream` / `get_workstream` / `list_workstreams` | §3 Phase machine (+§1 for the start-of-turn index habit) | tool summaries terse |

## B — Dedupe rows (what each deleted passage became)

1. Operating-rules tier bullet (:44-46) + tier self-unblock bullet (:86-89) +
   `set_orchestrator_config` bullet (:90) → merged into ONE "WORKER TIERS"
   bullet under `Dispatching workers` (all constraints kept: tier semantics,
   unassigned-cannot-spawn, `get_config`→`configure_tier` self-unblock,
   don't-ask-unless-no-model).
2. Operating-rules "read a worker's findings via `final_message`" bullet
   (:49-51) → folded into the core loop's canonical VERIFY bullet.
3. Operating-rules `start_adw` mega-bullet (:68-85) → the `ADWs` section
   (single home for the selection ladder / decompose-into-runs); the
   cross-repo `working_dir` rules paragraph is now repo-gated.
4. "Message queue & holding pattern" section (:134-148) → merged into the core
   loop's "ONE STEP per turn, then END YOUR TURN" bullet (kept: queued-in-order
   delivery, no mid-turn interruption, report-what-you-kicked-off, no polling,
   woken once per return, operator-message precedence).
5. "Working rhythm" closing paragraph (:150-154) → deleted as a restatement of
   the core loop; its one unique rule ("once an ADW is launched, observe rather
   than interfere") moved to the `ADWs` section.
6. `worker_roles_block/0` (:519-531) → deleted — it printed the identical
   `Templates.list()` roster `subagent_map_block/0` already prints. The merged
   header is "Available subagent templates & worker roles"; the empty state
   keeps the conventional role names (builder/reviewer/tester/documenter/
   debugger).
7. Context-management `report_cost` bullet (:475-476) and the "≈80% …
   `compact_self` … rehydrate-on-resume" clause (:486-491) → the promoted
   `Durable memory (workstreams) & self-compaction` block (§1); context
   management keeps the worker levers plus a one-line cross-reference.
8. `external_memory_block` "(your durable swap)" (:654-668) → promoted to §1
   and expanded into the single `compact_self`/rehydrate home (absorbing 7).
9. Phased-delivery "VERIFY with `inspect_repo` first — never trust a
   self-report" (:584-585) → "verify each stage first — the core loop's VERIFY
   rule".
10. Phased-delivery test-stage quality-gate walkthrough (:590-594) → one line +
    "see the Quality gate section" (the two-call protocol and fix loop live in
    `quality_gate_block/0`, unchanged, and remain verbatim in the
    `run_quality_gate` MCP description).
11. Prompt tools block: full `description` per tool → terse `summary` per tool
    (§C); the full descriptions still reach the model as tool schemas on the
    MCP `tools/list` / pi-manifest channel (unchanged, pinned by
    `tool_manifest_snapshot_test.exs` — fixture regenerated for the additive
    `summary` keys only).

## C — Tool description → summary reductions

`description` stays the MCP `tools/list` / pi-manifest source of truth
(unchanged); `summary` is what the prompt renders (`ToolCatalog.prompt_line/1`).
Policy sentences dropped from the prompt line live in the named prose section
(and remain, verbatim, in the MCP description).

29 tools carry a `summary` pointing at their policy home ("see Core loop",
"see Durable memory", "see Phased delivery", "see Quality gate", "see Context
management", "see the ADWs section", "see Registered APIs"). 8 tools whose
descriptions were already terse render via the fallback: `command_agent`,
`list_agents`, `interrupt_agent`, `delete_agent`, `read_system_logs`,
`set_orchestrator_config`, `get_agent_template`, `close_workstream`.

## D — Conditional inclusion (Phase 4)

`repo_bound?/1` = project resolved OR non-empty `working_dir`. When false the
render omits: quality-gate block, phase-machine dispatch detail + UI/UX
polish, cross-repo ADW paragraph — replaced by a two-line inactive-protocols
notice merged into the no-dir working-directory copy.
