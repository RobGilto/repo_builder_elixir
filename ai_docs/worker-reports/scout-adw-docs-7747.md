# Worker report: scout-adw-docs (idle)

Both worker reports were **truncated when originally generated** — each ends mid-sentence with a `[truncated]` marker followed by a single placeholder line `(see attached image)`. I cannot view images, and per your instruction I did not re-explore the codebase. So I can faithfully extract everything that *exists* in these two files, but a large portion of what you requested simply **isn't in the reports**. I'll flag the truncation losses explicitly at the top and in-line so an orchestrator doesn't proceed on a false premise of completeness.

Below is the consolidated brief.

---

# Consolidated Scout Brief: ADW Design Docs vs. Current Setup

> ⚠️ **TRUNCATION REALITY (read first):**
> - **File #1 (`scout-adw-docs-7653.md`)** only contains the summary of **`adw-primitives.md`**. The **entire `adw-orchestration.md` summary you asked for was never written** — the report was truncated before the scout got to "FILE 2." So thesis/concepts/mechanisms/contracts/integration points/quotes/"what's new" for adw-orchestration.md are **NOT AVAILABLE** in this report.
> - **File #2 (`scout-current-setup-7695.md`)** contains Section A.1, A.2 (complete), and A.3 (partial). **Section B (the prompt-builder map), the `ai_docs/` inventory, and the gaps/TODOs/hacks list were never written** — truncated away.
> - Only one minor gap/TODO survived in the truncated text (the duplicated step-map wart in `Catalog`).
>
> An orchestrator doing "how do the two design docs improve the existing setup" **cannot** synthesize the adw-orchestration side or the prompt-builder side from these two reports alone. Those would need the source docs (`ai_docs/adw-orchestration.md`) and a re-scan of the prompt-builder modules.

---

## PART 1 — `ai_docs/adw-primitives.md`: "ADW Primitives — Inventory & Composition Doctrine" *(from file #1, complete)*

### Core thesis / purpose
The **written-form doctrine the three generator commands read before producing anything**: `/build-adw-prompt`, `/build-adw-primitive`, `/build-adw-workflow`. Documents "the ADW engine's unwritten skeleton" — primitive inventory, canonical stitching pattern, every registration surface a new artifact must touch.

> "every `file:line` anchor in this doc MUST be re-verified against the code on read. Code is the source of truth; this doc is mutable memory validated *against* it — never the reverse."

### Key abstractions: the five-rung layering ladder (each rung consumed by the one above)
1. **STEP PROMPTS** — `commands/tac/*.md`, one agentic step each; driven by `execute_template()` (`adws/adw_modules/agent.py:511`)
2. **PRIMITIVES** — `adws/adw_modules/*.py` (typed, importable operations)
3. **PHASE SCRIPTS** — `adws/adw_<phase>_iso.py` (uv single-file scripts; one SDLC phase each)
4. **ORCHESTRATORS** — `adws/adw_<a>_<b>…_iso.py` (deterministic chains of phase scripts)
5. **TRIGGERS** — `adws/adw_triggers/*.py` (`trigger_webhook.py`, `trigger_cron.py`, or shell)

**Load-bearing doctrine (verbatim):**
> "the workflow STRUCTURE is deterministic Python; only the per-step agent EXECUTION is non-deterministic (Claude Code headless, invoked through a slash command). … The step prompts in `commands/tac/*.md` are therefore the engine's instruction set; the Python is the CPU."

**Side door:** `adws/adw_slash_command.py` — fires a single slash command via `prompt_claude_code_with_retry` with no issue/worktree/state (the "lowest-ceremony rung-1→2 path").

### Primitive inventory (concrete modules, functions, line anchors)

**`adws/adw_modules/agent.py` — Claude Code headless engine**
- `SLASH_COMMAND_MODEL_MAP` (`:30`) — `Dict[SlashCommand, Dict[ModelSet, str]]` (base/heavy model per command)
- `get_model_for_slash_command` (`:52`) — `(request: AgentTemplateRequest, default="sonnet") -> str`
- `truncate_output` (`:86`), `check_claude_installed` (`:147`), `parse_jsonl_output` (`:162`), `convert_jsonl_to_json` (`:187`), `save_prompt` (`:225`)
- **`prompt_claude_code_with_retry`** (`:250`) — *"the single chokepoint every engine agent call passes through"*; retries on `RetryCode.{CLAUDE_CODE_ERROR, TIMEOUT_ERROR, EXECUTION_ERROR, ERROR_DURING_EXECUTION}`; observability wiring point
- `prompt_claude_code` (`:304`) — one `claude -p` subprocess; streams JSONL; "Never raises; failures come back as `success=False` + `retry_code`."
- **`execute_template`** (`:511`) — slash command + args → prompt; model-mapped; output to `agents/<adw_id>/<agent_name>/raw_output.jsonl` (project-root anchored `:538-547`). *"Use this for every agent call in a primitive or phase script."*

**`adws/adw_modules/workflow_ops.py` — phase-level operations**
- Agent-name constants (`:24-28`): `AGENT_PLANNER="sdlc_planner"`, plus `AGENT_IMPLEMENTOR`, `AGENT_CLASSIFIER`, `AGENT_BRANCH_GENERATOR`, `AGENT_PR_CREATOR`
- `AVAILABLE_ADW_WORKFLOWS` (`:31-47`) — runtime list of the 14 workflow names
- `format_issue_message` (`:50`) — prefixes `ADW_BOT_IDENTIFIER`
- `extract_adw_info` (`:60`), `classify_issue` (`:107` — regex-extracts `(/chore|/bug|/feature|0)` at `:142`)
- `build_plan` (`:158`), `implement_plan` (`:192`), `generate_branch_name` (`:224` — strips backticks), `create_commit` (`:257` — suffixes `_committer`), `create_pull_request` (`:296`)
- `ensure_plan_exists` (`:351`)
- **`ensure_adw_id`** (`:376`) — mint/load id + init state. *"First call in every orchestrator."*
- `find_existing_branch_for_issue` (`:424`), `find_plan_for_issue` (`:453`), `create_or_find_branch` (`:488`), `find_spec_file` (`:575`), `create_and_implement_patch` (`:645` — `/patch` then `/implement`, validates path contains `specs/patch/` and ends `.md` at `:701`)

**`adws/adw_modules/state.py` — persistent workflow state**
- `ADWState` (`:15`); `update` (`:34`) silently drops keys outside the 10-field whitelist (`:37`); `get`, `append_adw_id`, `get_working_directory`
- `get_state_path` (`:68-73`) — `<repo-root>/agents/<adw_id>/adw_state.json`; **module-anchored** (3× `dirname` of the module file, "never cwd-based")
- `save` (`:75`) — **"Second observability chokepoint"**
- `load` (`:102`); `from_stdin` (`:136`) / `to_stdout` (`:158`)

**`adws/adw_modules/git_ops.py`**
`get_current_branch` (`:15`), `push_branch` (`:26`), `check_pr_exists` (`:41`), `create_branch` (`:72`), `commit_changes` (`:97`), `get_pr_number` (`:124`), `approve_pr`/`merge_pr` (`:157`/`:187` — ship-phase only), **`finalize_git_operations`** (`:252`) — *"Standard last step of every phase script."*

**`adws/adw_modules/github.py`**
`ADW_BOT_IDENTIFIER` (`:24`) = `"[ADW-AGENTS]"`; `get_github_env` (`:27`), `get_repo_url`/`extract_repo_path` (`:55`/`:73`), `fetch_issue` (`:79`), `make_issue_comment` (`:126`), `mark_issue_in_progress` (`:164`), `fetch_open_issues` (`:209`), `fetch_issue_comments` (`:247`), `find_keyword_from_comment` (`:290`)

**`adws/adw_modules/worktree_ops.py`**
`create_worktree` (`:15` — `trees/<adw_id>/` off `origin/main`), **`validate_worktree`** (`:75` — three-way check: state, filesystem, `git worktree list`; *"First gate of every dependent phase"*), `get_worktree_path` (`:107`), `remove_worktree` (`:122`), `setup_worktree_environment` (`:151`), **`get_ports_for_adw`** (`:176` — base-36 hash → index `% 15`: backend `9100-9114`, frontend `9200-9214`; *"Hard cap: 15 concurrent instances"*), `is_port_available` (`:201`), `find_next_available_ports` (`:219`)

**`adws/adw_modules/utils.py`**
`make_adw_id` (`:15` — 8-char uuid4 prefix), `setup_logger` (`:20` — module-anchored path `:32`), `get_logger` (`:76`), **`parse_json`** (`:88` — tolerates ```json fences; *"The standard way to parse an agent's JSON output"*), `check_env_vars` (`:161` — requires `CLAUDE_CODE_PATH`), `get_safe_subprocess_env` (`:188` — allowlisted env; "never pass `os.environ` wholesale")

**`adws/adw_modules/data_types.py`**
`RetryCode` (`:10`), `IssueClassSlashCommand` (`:22` = `Literal["/chore","/bug","/feature"]`), `ModelSet` (`:25` = `Literal["base","heavy"]`), `ADWWorkflow` (`:28` — 14 names), `SlashCommand` (`:47`), `GitHubIssue` (`:126`), `AgentPromptRequest` (`:147`), `AgentPromptResponse` (`:159`), `AgentTemplateRequest` (`:168`), `TestResult`/`E2ETestResult` (`:193`/`:203`), **`ADWStateData`** (`:218` — persisted state schema, 10 fields), `ReviewIssue`/`ReviewResult` (`:237`/`:250`), `DocumentationResult` (`:266`), `ADWExtractionResult` (`:275`)

**`adws/adw_modules/r2_uploader.py`**
`R2Uploader` (`:12` — self-disables when `CLOUDFLARE_*` env missing), `upload_file` (`:54`), `upload_screenshots` (`:99` — *"The graceful-degradation pattern to copy for optional integrations"*)

### What's NEW / additive in primitives (vs. describing existing behavior)
- **`adws/adw_modules/observability.py`** — *"New in ADW 1.2.0"*. Stdlib-only (`json`, `os`, `datetime`), no decorators, fail-silent:
  - `events_path(adw_id, working_dir=None) -> str` → `agents/<adw_id>/events.jsonl`
  - `emit_event(adw_id, source, event_type, payload=None, agent_name=None, summary=None, working_dir=None) -> bool` — "Returns `False` and **never raises**"; kill switch `ADW_EVENTS_DISABLED=1`
  - `read_events(adw_id, working_dir=None) -> List[dict]` — *"The seam an orchestration app polls."*
- **`adws/adw_modules/local_ops.py`** — *"New in ADW 1.3.0"*. Manages `agents/<adw_id>/run.json` (schema `adw.run/1`). Primitives: `run_path`, `create_run`, `load_run`/`save_run` (atomic), `update_run` (tac-14 `update_adw_status` parity; emits `run_updated` event), `step_start`/`step_end`, **`synthesize_issue(run) -> GitHubIssue`** — `local_issue_number(adw_id)` returns "stable numeric ≥ 9,000,000 so `issue-{n}-adw-{id}` spec/branch conventions hold". Consumed by `adws/adw_plan_build_local_iso.py`.

### Conventions / contracts / schemas defined

**§3 Canonical phase-script skeleton**
- uv single-file header:
  ```python
  #!/usr/bin/env -S uv run
  # /// script
  # dependencies = ["python-dotenv", "pydantic"]
  # ///
  ```
- `mai...[truncated]
