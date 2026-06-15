# ADW Primitives — Inventory & Composition Doctrine

What `/build-adw-prompt`, `/build-adw-primitive`, and `/build-adw-workflow` read
before generating anything. This is the written form of the ADW engine's unwritten
skeleton: the primitive inventory, the canonical stitching pattern, and every
registration surface a new artifact must touch.

> **Anchor invariant (same rule as `commands/tac/experts/adw/expertise.yaml`):**
> every `file:line` anchor in this doc MUST be re-verified against the code on
> read. Code is the source of truth; this doc is mutable memory validated
> *against* it — never the reverse (see `ai_docs/agent-experts.md`). Line numbers
> drift faster than symbol names: if an anchor misses, grep the symbol and use the
> real line. Paths are relative to the repo root.

---

## 1. Layering

The engine is a five-rung ladder. Each rung is extended independently, and each
rung's artifact is consumed by the rung above it:

```
commands/tac/*.md              STEP PROMPTS — one agentic step each (/feature, /implement,
        │                      /review, …); deployed to .claude/commands/ via sync_commands.sh
        │  driven by execute_template() — adws/adw_modules/agent.py:511
        ▼
adws/adw_modules/*.py          PRIMITIVES — typed, importable operations (classify_issue,
        │                      create_worktree, make_issue_comment, ADWState, …)
        │  stitched by
        ▼
adws/adw_<phase>_iso.py        PHASE SCRIPTS — uv single-file scripts, one SDLC phase each
        │                      (adw_plan_iso, adw_build_iso, adw_test_iso, adw_review_iso,
        │                      adw_document_iso, adw_ship_iso, adw_patch_iso)
        │  chained by subprocess.run([...]) gated on returncode
        ▼
adws/adw_<a>_<b>…_iso.py       ORCHESTRATORS — deterministic chains of phase scripts
        │                      (adw_plan_build_iso, adw_sdlc_iso, adw_sdlc_zte_iso, …)
        │  launched by
        ▼
adws/adw_triggers/*.py         TRIGGERS — trigger_webhook.py (GitHub events, FastAPI),
                               trigger_cron.py (polling), or the operator's shell
```

The load-bearing doctrine: **the workflow STRUCTURE is deterministic Python; only
the per-step agent EXECUTION is non-deterministic** (Claude Code headless, invoked
through a slash command). A phase script never "asks an agent what to do next" —
it calls `execute_template()` (`adws/adw_modules/agent.py:511`), which composes
`"{slash_command} {args}"` into a prompt, picks the model from
`SLASH_COMMAND_MODEL_MAP` (`agent.py:30`), and runs `claude -p … --output-format
stream-json` via `prompt_claude_code_with_retry()` (`agent.py:250`). The step
prompts in `commands/tac/*.md` are therefore the engine's instruction set; the
Python is the CPU.

Side door: `adws/adw_slash_command.py` fires a single slash command through the
same engine (`prompt_claude_code_with_retry`) with no issue, worktree, or state —
the lowest-ceremony rung-1→2 path.

## 2. Primitive inventory

### `adws/adw_modules/agent.py` — Claude Code headless engine

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `SLASH_COMMAND_MODEL_MAP` | `:30` | `Dict[SlashCommand, Dict[ModelSet, str]]` — base/heavy model per command. Registration surface. |
| `get_model_for_slash_command` | `:52` | `(request: AgentTemplateRequest, default="sonnet") -> str` — reads `model_set` from saved state. |
| `truncate_output` | `:86` | `(output, max_length=500, suffix=…) -> str` — JSONL-aware truncation for comments/errors. |
| `check_claude_installed` | `:147` | `() -> Optional[str]` — error message or None. |
| `parse_jsonl_output` | `:162` | `(output_file) -> Tuple[List[dict], Optional[dict]]` — all messages + the `type=="result"` message. |
| `convert_jsonl_to_json` | `:187` | `(jsonl_file) -> str` — writes the `.json` array mirror, returns its path. |
| `save_prompt` | `:225` | `(prompt, adw_id, agent_name="ops") -> None` — logs prompt to `agents/<adw_id>/<agent>/prompts/<cmd>.txt`. |
| `prompt_claude_code_with_retry` | `:250` | `(request: AgentPromptRequest, max_retries=3, retry_delays=None) -> AgentPromptResponse` — **the single chokepoint every engine agent call passes through** (covers `execute_template` and `adw_slash_command.py`). Retries on `RetryCode.{CLAUDE_CODE_ERROR, TIMEOUT_ERROR, EXECUTION_ERROR, ERROR_DURING_EXECUTION}`. Observability wiring point (§8). |
| `prompt_claude_code` | `:304` | `(request: AgentPromptRequest) -> AgentPromptResponse` — one `claude -p` subprocess, streams JSONL to `request.output_file`. Never raises; failures come back as `success=False` + `retry_code`. |
| `execute_template` | `:511` | `(request: AgentTemplateRequest) -> AgentPromptResponse` — slash command + args → prompt; model-mapped; output to `agents/<adw_id>/<agent_name>/raw_output.jsonl` (project-root anchored, `:538-547`). **Use this for every agent call in a primitive or phase script.** |

### `adws/adw_modules/workflow_ops.py` — phase-level operations

| Primitive | Anchor | Signature / contract |
|---|---|---|
| Agent-name constants | `:24-28` | `AGENT_PLANNER="sdlc_planner"`, `AGENT_IMPLEMENTOR`, `AGENT_CLASSIFIER`, `AGENT_BRANCH_GENERATOR`, `AGENT_PR_CREATOR`. |
| `AVAILABLE_ADW_WORKFLOWS` | `:31-47` | runtime list of the 14 workflow names. Registration surface. |
| `format_issue_message` | `:50` | `(adw_id, agent_name, message, session_id=None) -> str` — prefixes `ADW_BOT_IDENTIFIER` to prevent webhook loops. Every ❌/✅ comment goes through this. |
| `extract_adw_info` | `:60` | `(text, temp_adw_id) -> ADWExtractionResult` — `/classify_adw` agent call, validated against `AVAILABLE_ADW_WORKFLOWS` (`:89`). |
| `classify_issue` | `:107` | `(issue, adw_id, logger) -> Tuple[Optional[IssueClassSlashCommand], Optional[str]]` — `/classify_issue`; regex-extracts `/chore\|/bug\|/feature\|0` (`:142`). |
| `build_plan` | `:158` | `(issue, command, adw_id, logger, working_dir=None) -> AgentPromptResponse` — runs `/chore`/`/bug`/`/feature`; output is the plan path (§5). |
| `implement_plan` | `:192` | `(plan_file, adw_id, logger, agent_name=None, working_dir=None) -> AgentPromptResponse` — `/implement`. |
| `generate_branch_name` | `:224` | `(issue, issue_class, adw_id, logger) -> Tuple[Optional[str], Optional[str]]` — `/generate_branch_name`; strips backticks (`:252`). |
| `create_commit` | `:257` | `(agent_name, issue, issue_class, adw_id, logger, working_dir) -> Tuple[Optional[str], Optional[str]]` — `/commit`; suffixes agent `_committer` (`:271`). |
| `create_pull_request` | `:296` | `(branch_name, issue, state, logger, working_dir) -> Tuple[Optional[str], Optional[str]]` — `/pull_request`. |
| `ensure_plan_exists` | `:351` | `(state, issue_number) -> str` — raises `ValueError` if no plan. |
| `ensure_adw_id` | `:376` | `(issue_number, adw_id=None, logger=None) -> str` — mint/load id + init state. **First call in every orchestrator.** |
| `find_existing_branch_for_issue` | `:424` | `(issue_number, adw_id=None, cwd=None) -> Optional[str]` — matches `-issue-{n}-` / `-adw-{id}-` pattern. |
| `find_plan_for_issue` | `:453` | `(issue_number, adw_id=None) -> Optional[str]` — `agents/*/sdlc_planner/plan.md` lookup. |
| `create_or_find_branch` | `:488` | `(issue_number, issue, state, logger, cwd=None) -> Tuple[str, Optional[str]]` — state → existing branch → classify+generate+create. |
| `find_spec_file` | `:575` | `(state, logger) -> Optional[str]` — state → git diff → branch-pattern glob fallback (`:615-639`). Key Output-Contract evidence (§5). |
| `create_and_implement_patch` | `:645` | `(adw_id, review_change_request, logger, agent_name_planner, agent_name_implementor, spec_path=None, issue_screenshots=None, working_dir=None) -> Tuple[Optional[str], AgentPromptResponse]` — `/patch` then `/implement`; validates the returned path (`:701`). |

### `adws/adw_modules/state.py` — persistent workflow state

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `ADWState` | `:15` | container; `adw_id` required (`:26-27`). |
| `update` | `:34` | `(**kwargs)` — silently drops keys outside the 10-field whitelist at `:37` (§6). |
| `get` | `:42` | `(key, default=None)`. |
| `append_adw_id` | `:46` | `(adw_id)` — appends workflow name to `all_adws` provenance list. |
| `get_working_directory` | `:53` | `() -> str` — `worktree_path` if set, else repo root. |
| `get_state_path` | `:68-73` | `() -> str` — `<repo-root>/agents/<adw_id>/adw_state.json`. **Module-anchored** (3× `dirname` of `os.path.abspath(__file__)`), never cwd-based. `observability.py` mirrors this resolution. |
| `save` | `:75` | `(workflow_step: Optional[str] = None) -> None` — validates through `ADWStateData`, writes JSON. **Second observability chokepoint** (§8). |
| `load` | `:102` | classmethod `(adw_id, logger=None) -> Optional[ADWState]` — None if absent/invalid. |
| `from_stdin` / `to_stdout` | `:136` / `:158` | piped-state passing between scripts; `to_stdout` prints the core fields only. |

### `adws/adw_modules/git_ops.py` — git/PR operations

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `get_current_branch` | `:15` | `(cwd=None) -> str`. |
| `push_branch` | `:26` | `(branch_name, cwd=None) -> Tuple[bool, Optional[str]]`. |
| `check_pr_exists` | `:41` | `(branch_name) -> Optional[str]` — PR URL via `gh pr list`. |
| `create_branch` | `:72` | `(branch_name, cwd=None) -> Tuple[bool, Optional[str]]` — falls back to checkout if it exists. |
| `commit_changes` | `:97` | `(message, cwd=None) -> Tuple[bool, Optional[str]]` — `git add -A` + commit; no-op success when clean. |
| `get_pr_number` | `:124` | `(branch_name) -> Optional[str]`. |
| `approve_pr` / `merge_pr` | `:157` / `:187` | `(pr_number, logger[, merge_method="squash"]) -> Tuple[bool, Optional[str]]` — ship-phase only. |
| `finalize_git_operations` | `:252` | `(state, logger, cwd=None) -> None` — push + create/update PR + comment. **Standard last step of every phase script.** |

### `adws/adw_modules/github.py` — gh CLI wrappers

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `ADW_BOT_IDENTIFIER` | `:24` | `"[ADW-AGENTS]"` — loop-prevention marker on every bot comment. |
| `get_github_env` | `:27` | `() -> Optional[dict]` — minimal env with `GH_TOKEN` from `GITHUB_PAT`. |
| `get_repo_url` / `extract_repo_path` | `:55` / `:73` | origin URL → `owner/repo`. |
| `fetch_issue` | `:79` | `(issue_number, repo_path) -> GitHubIssue` — ⚠ calls `sys.exit` on failure (`:107`, `:120`, `:123`) — known pitfall, do not copy (§10). |
| `make_issue_comment` | `:126` | `(issue_id, comment) -> None` — auto-prefixes `ADW_BOT_IDENTIFIER`; raises on failure. The ❌/✅ progress channel. |
| `mark_issue_in_progress` | `:164` | `(issue_id) -> None` — label + self-assign, best-effort. |
| `fetch_open_issues` | `:209` | `(repo_path) -> List[GitHubIssueListItem]` — returns `[]` on error. |
| `fetch_issue_comments` | `:247` | `(repo_path, issue_number) -> List[Dict]` — sorted by `createdAt`. |
| `find_keyword_from_comment` | `:290` | `(keyword, issue) -> Optional[GitHubComment]` — newest first, skips bot comments. |

### `adws/adw_modules/worktree_ops.py` — isolation & ports

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `create_worktree` | `:15` | `(adw_id, branch_name, logger) -> Tuple[str, Optional[str]]` — `trees/<adw_id>/` off `origin/main`, branch created with `-b`. |
| `validate_worktree` | `:75` | `(adw_id, state) -> Tuple[bool, Optional[str]]` — three-way check: state, filesystem, `git worktree list`. **First gate of every dependent phase.** |
| `get_worktree_path` | `:107` | `(adw_id) -> str` — `<repo-root>/trees/<adw_id>`. |
| `remove_worktree` | `:122` | `(adw_id, logger) -> Tuple[bool, Optional[str]]` — ⚠ `shutil` used un-imported on the fallback path (`:142`) — known pitfall (§10). |
| `setup_worktree_environment` | `:151` | `(worktree_path, backend_port, frontend_port, logger) -> None` — writes `.ports.env`. |
| `get_ports_for_adw` | `:176` | `(adw_id) -> Tuple[int, int]` — deterministic base-36 hash → index `% 15` (`:190`): backend `9100-9114`, frontend `9200-9214`. **Hard cap: 15 concurrent instances.** |
| `is_port_available` | `:201` | `(port) -> bool`. |
| `find_next_available_ports` | `:219` | `(adw_id, max_attempts=15) -> Tuple[int, int]` — raises `RuntimeError` when exhausted. |

### `adws/adw_modules/utils.py` — ids, logging, parsing, env

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `make_adw_id` | `:15` | `() -> str` — 8-char uuid4 prefix. |
| `setup_logger` | `:20` | `(adw_id, trigger_type="adw_plan_build") -> logging.Logger` — file `agents/<adw_id>/<trigger_type>/execution.log` (DEBUG) + console (INFO). Module-anchored path (`:32`). |
| `get_logger` | `:76` | `(adw_id) -> logging.Logger` — fetch by name `adw_<id>`. |
| `parse_json` | `:88` | `(text, target_type=None) -> Any` — tolerates ```json fences and surrounding prose; optional Pydantic validation incl. `List[Model]`. **The standard way to parse an agent's JSON output.** |
| `check_env_vars` | `:161` | `(logger=None) -> None` — requires `CLAUDE_CODE_PATH`; `sys.exit(1)` if missing (acceptable: it is a startup gate, called only from phase-script `main()`). |
| `get_safe_subprocess_env` | `:188` | `() -> Dict[str, str]` — allowlisted env for subprocesses; never pass `os.environ` wholesale. |

### `adws/adw_modules/data_types.py` — Pydantic models & Literals

| Type | Anchor | Role |
|---|---|---|
| `RetryCode` | `:10` | retryable-error enum used by the agent engine. |
| `IssueClassSlashCommand` | `:22` | `Literal["/chore", "/bug", "/feature"]`. |
| `ModelSet` | `:25` | `Literal["base", "heavy"]`. |
| `ADWWorkflow` | `:28` | Literal of the 14 workflow names. Registration surface (§7). |
| `SlashCommand` | `:47` | Literal of every engine-driven slash command. Registration surface (§7). |
| `GitHubIssue` (+ user/label/comment models) | `:126` | typed `gh` JSON. |
| `AgentPromptRequest` | `:147` | raw engine request (`prompt`, `adw_id`, `agent_name`, `model`, `output_file`, `working_dir`). |
| `AgentPromptResponse` | `:159` | `output`, `success`, `session_id`, `retry_code`. |
| `AgentTemplateRequest` | `:168` | slash-command request (`agent_name`, `slash_command`, `args`, `adw_id`, `working_dir`). |
| `TestResult` / `E2ETestResult` | `:193` / `:203` | parsed `/test` / `/test_e2e` output. |
| `ADWStateData` | `:218` | the persisted state schema (10 fields). Registration surface for new state fields (§6). |
| `ReviewIssue` / `ReviewResult` | `:237` / `:250` | parsed `/review` output (§5). |
| `DocumentationResult` | `:266` | `/document` outcome. |
| `ADWExtractionResult` | `:275` | `/classify_adw` outcome. |

### `adws/adw_modules/r2_uploader.py` — screenshot uploads (optional tier)

| Primitive | Anchor | Signature / contract |
|---|---|---|
| `R2Uploader` | `:12` | `(logger)` — self-disables (`enabled=False`) when `CLOUDFLARE_*` env vars are missing; never blocks a workflow. |
| `upload_file` | `:54` | `(file_path, object_key=None) -> Optional[str]` — public URL or None. |
| `upload_screenshots` | `:99` | `(screenshots, adw_id) -> Dict[str, str]` — local path → URL (or original path on failure). The graceful-degradation pattern to copy for optional integrations. |

### `adws/adw_modules/observability.py` — structured event stream

*(New in ADW 1.2.0 — anchored by symbol only; verify against the module on read.)*
Stdlib-only (`json`, `os`, `datetime`), no decorators, fail-silent.

| Primitive | Signature / contract |
|---|---|
| `events_path` | `(adw_id, working_dir=None) -> str` — `agents/<adw_id>/events.jsonl`. Default root mirrors `ADWState.get_state_path()` (`adws/adw_modules/state.py:68-73`): module-anchored to the checkout containing `adws/`, cwd never consulted. Explicit `working_dir` overrides: `<working_dir>/agents/<adw_id>/events.jsonl`. |
| `emit_event` | `(adw_id, source, event_type, payload=None, agent_name=None, summary=None, working_dir=None) -> bool` — appends one `adw.event/1` JSON line (§8). Returns `False` and **never raises** on any failure; non-serializable payload falls back to `str()`; creates the parent dir; no-op `False` when `ADW_EVENTS_DISABLED=1`. |
| `read_events` | `(adw_id, working_dir=None) -> List[dict]` — parses the file, silently skipping malformed lines; `[]` if absent. The seam an orchestration app polls. |

### `adws/adw_modules/local_ops.py` — the local launch contract

*(New in ADW 1.3.0.)* Stdlib + existing modules only. Manages
`agents/<adw_id>/run.json` (schema `adw.run/1` — tac-14's
`ai_developer_workflows` row on the file store): an orchestrator writes the
record BEFORE spawning; the workflow pulls all task context from it by id.
Consumed by `adws/adw_plan_build_local_iso.py` (CLI: single `<adw-id>`
positional — the run record is the context).

| Primitive | Signature / contract |
|---|---|
| `run_path` | `(adw_id, working_dir=None) -> str` — `agents/<adw_id>/run.json`, module-anchored root mirroring `observability.events_path`. |
| `create_run` | `(adw_id, workflow_type, prompt, model=None, issue_number=None, input_working_dir=None, total_steps=2, working_dir=None) -> dict` — writes a full `pending` record. |
| `load_run` / `save_run` | load returns `None` on absent/corrupt; save is **atomic** (tmp + `os.replace`), returns bool, never raises. |
| `update_run` | `(adw_id, status=None, current_step=None, completed_steps=None, error_message=None, error_step=None, output=None, working_dir=None) -> Optional[dict]` — tac-14 `update_adw_status` parity: `in_progress` sets `started_at` once; terminal sets `completed_at`+`duration_seconds`; `output` merges into `output_data`; emits a `run_updated` event with the changed fields. |
| `step_start` / `step_end` | emit the `step_start`/`step_end` adw.event/1 lines — the swimlane grouping markers. |
| `synthesize_issue` | `(run) -> GitHubIssue` — placeholder-complete construction; `number` = real `input_data.issue_number` or `local_issue_number(adw_id)` (stable numeric ≥ 9,000,000 so `issue-{n}-adw-{id}` spec/branch conventions hold); title = sanitized first prompt line (≤80), body = prompt verbatim. Downstream ops serialize only `{number,title,body}`. |

## 3. The canonical phase-script skeleton

Every `adws/adw_*_iso.py` opens with the astral-uv single-file header — stdlib +
the two house deps (add others, e.g. `boto3`, only when actually imported, as
`adws/adw_review_iso.py:1-4` does):

```python
#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///
```

Then a docstring with `Usage:` and a numbered `Workflow:` list (see
`adws/adw_plan_iso.py:6-25`), imports from `adw_modules`, and a `main()` guarded
by `if __name__ == "__main__":`.

`main()` opens with the standard preamble — `load_dotenv()`, positional-arg
parsing (§6 CLI contract), state load/create, `state.append_adw_id("<script>")`
(`adw_plan_iso.py:91`), `setup_logger(adw_id, "<script>")`, `check_env_vars(logger)`
— and then stitches primitives with the **stitching triple** between every step.

On failure: `logger.error` + ❌ `make_issue_comment` + `sys.exit(1)`. On success:
`state.update(...)` + `state.save("<script>")` + ✅ comment. Verbatim shape (from
`adws/adw_plan_iso.py:142-158`):

```python
    issue_command, error = classify_issue(issue, adw_id, logger)

    if error:
        logger.error(f"Error classifying issue: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, "ops", f"❌ Error classifying issue: {error}"),
        )
        sys.exit(1)

    state.update(issue_class=issue_command)
    state.save("adw_plan_iso")
    logger.info(f"Issue classified as: {issue_command}")
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, "ops", f"✅ Issue classified as: {issue_command}"),
    )
```

The same triple wraps agent calls (`build_plan` → check `response.success`,
`adw_plan_iso.py:233-243`) and git ops (`commit_changes` → check the
`(success, error)` tuple, `adw_plan_iso.py:301-311`). Phase scripts end with
`finalize_git_operations(state, logger, cwd=worktree_path)` (`git_ops.py:252`),
a final `state.save("<script>")`, and a 📋 final-state comment
(`adw_plan_iso.py:318-334`).

Dependent phases (build/test/review/document/ship) additionally hard-require the
adw-id argument and refuse to run without prior state + a valid worktree
(`adw_build_iso.py:53-58`, `:73-80`, `validate_worktree` gate at `:93-102`).

## 4. The orchestrator skeleton

Orchestrators contain **no agent calls and no business logic** — only
`ensure_adw_id` then a gated `subprocess.run` chain. Canonical form
(`adws/adw_plan_build_iso.py:27-78`, identical pattern in `adws/adw_sdlc_iso.py`):

```python
def main():
    if len(sys.argv) < 2:
        print("Usage: uv run adw_plan_build_iso.py <issue-number> [adw-id]")
        sys.exit(1)

    issue_number = sys.argv[1]
    adw_id = sys.argv[2] if len(sys.argv) > 2 else None

    adw_id = ensure_adw_id(issue_number, adw_id)   # workflow_ops.py:376
    script_dir = os.path.dirname(os.path.abspath(__file__))

    plan = subprocess.run(
        ["uv", "run", os.path.join(script_dir, "adw_plan_iso.py"), issue_number, adw_id]
    )
    if plan.returncode != 0:
        print("Isolated plan phase failed")
        sys.exit(1)
    # …repeat per phase, passing the SAME adw_id…
```

Phases communicate **only** through `agents/<adw_id>/adw_state.json` — never via
stdout parsing or shared globals. A phase failure exits 1 and stops the chain;
the one sanctioned exception is a deliberately non-fatal gate (test phase in
`adw_sdlc_iso.py:106-109` warns and continues). Flags are stripped from
`sys.argv` before positional parsing (`adw_sdlc_iso.py:34-41`).

## 5. Output Contracts

A step prompt is only composable if the glue code can consume its result
**deterministically**. Every step prompt must therefore end in an **Output
Contract**: a known artifact location + filename pattern, and a machine-parseable
final message. This is not aspiration — the existing engine already depends on it
everywhere:

- **Plan-path echo** — `/feature`/`/bug`/`/chore` return only the spec path;
  `adw_plan_iso.py:253` does ``plan_response.output.strip().strip("`")`` and then
  hard-fails unless the file exists in the worktree (`:266-274`).
- **Patch-path echo** — `create_and_implement_patch`
  (`adws/adw_modules/workflow_ops.py:698-705`) strips the output and rejects it
  unless it contains `specs/patch/` and ends with `.md`.
- **Branch name** — `commands/tac/generate_branch_name.md:39` says "Return ONLY
  the generated branch name (no other text)"; the glue strips backticks and uses
  it raw (`workflow_ops.py:252`).
- **Classification token** — `classify_issue` regex-extracts
  `(/chore|/bug|/feature|0)` from the output (`workflow_ops.py:142`); `0` is the
  contractual "no match" sentinel.
- **Review verdict** — `/review` returns a `ReviewResult` JSON object; parsed via
  `parse_json(response.output, ReviewResult)` (`adws/adw_review_iso.py:105`),
  fence-tolerant thanks to `utils.parse_json` (`adws/adw_modules/utils.py:88`).
- **Test results** — `/test` and `/test_e2e` return JSON arrays parsed as
  `List[TestResult]` / `List[E2ETestResult]` (`adws/adw_test_iso.py:97`, `:166`).
- **Documentation path or sentinel** — `/document` returns a path or the literal
  `"No documentation needed"` (`adws/adw_document_iso.py:149-152`).

The cost of a weak contract is visible in `find_spec_file`
(`adws/adw_modules/workflow_ops.py:575`): when state/plan-path discipline breaks
down, the glue degrades through a git-diff scan and finally a brittle branch-name
glob `specs/issue-{n}-adw-{id}*.md` (`:615-639`). Recovery glue like this is what
Output Contracts exist to avoid — a generator must make contracts explicit, not
replicate fallbacks.

**The contract template `/build-adw-prompt` embeds** (a mandatory section in
every generated step prompt):

```markdown
## Output Contract

- **Artifact**: <directory>/<filename pattern>
  (e.g. `specs/issue-{issue_number}-adw-{adw_id}-{slug}.md`)
- **Final message**: <exactly what to print and nothing else>
  (e.g. the artifact path alone · a single JSON object matching <Model> ·
   `## Verdict: PASS|FAIL` · a fixed sentinel like "No documentation needed")
- **On failure**: <the parseable failure shape — never free prose>
```

Rules of thumb: one artifact per step; the final line *is* the API; prefer a bare
path or a single JSON object (parsed with `parse_json`, so fences are tolerated
but never required); pick sentinels that cannot occur in normal prose.

## 6. Conventions checklist

A generated primitive or workflow script MUST satisfy all of these:

- **Naming** — workflow scripts are `adw_<phases>_iso.py`; the registered
  workflow name is the filename minus `.py` (sole casing oddity:
  `adw_sdlc_ZTE_iso`, `data_types.py:36`). Agent names are UPPER_SNAKE constants
  (`AGENT_PLANNER = "sdlc_planner"`, `workflow_ops.py:24-28`; per-script ones like
  `AGENT_REVIEWER` at `adw_review_iso.py:61-63`); the value becomes the
  `agents/<adw_id>/<agent_name>/` directory name.
- **CLI contract** — positional `<issue-number> [adw-id]` for entry points and
  orchestrators; `<issue-number> <adw-id>` (adw-id REQUIRED) for dependent phases
  (`adw_build_iso.py:53-58`). Optional flags (`--skip-e2e`, `--skip-resolution`)
  are removed from `sys.argv` before positional parsing (`adw_sdlc_iso.py:34-41`).
  Print a usage line and `sys.exit(1)` on bad args.
- **Logging** — `setup_logger(adw_id, "<script_name>")` →
  `agents/<adw_id>/<script_name>/execution.log` (`adws/adw_modules/utils.py:20-37`);
  file gets DEBUG, console INFO.
- **State whitelist** — `ADWState.update` silently drops anything outside the 10
  core fields at `adws/adw_modules/state.py:37`: `adw_id`, `issue_number`,
  `branch_name`, `plan_file`, `issue_class`, `worktree_path`, `backend_port`,
  `frontend_port`, `model_set`, `all_adws`. **Adding a state field touches four+
  places**: `ADWStateData` (`data_types.py:218-234`), the whitelist
  (`state.py:37`), `save()`'s explicit kwargs (`state.py:81-92`), `to_stdout`
  (`state.py:158-172` — note it currently omits `model_set`), and ship's
  `validate_state_completeness` (`adws/adw_ship_iso.py:150-178`).
- **Env** — `load_dotenv()` first thing in `main()` (`adw_plan_iso.py:69`);
  `check_env_vars(logger)` as the startup gate (`utils.py:161`); subprocess env
  always via `get_safe_subprocess_env()` (`utils.py:188`), never raw `os.environ`.
- **Ports** — derived from the adw_id hash (`worktree_ops.py:176`), backend
  `9100-9114` / frontend `9200-9214`; 15-instance ceiling (`:190`).
- **Issue comments** — every ❌/✅ goes through
  `format_issue_message(adw_id, agent_name, msg)` (`workflow_ops.py:50`) so the
  `[ADW-AGENTS]` identifier (`github.py:24`) prevents webhook loops.
- **Branch naming** — fixed structure, agent-chosen slug:
  `<issue_class>-issue-<issue_number>-adw-<adw_id>-<concise_name>`
  (`commands/tac/generate_branch_name.md:18`); discovery glue depends on the
  `-issue-{n}-` / `-adw-{id}-` segments (`workflow_ops.py:439-448`).
- **Exit codes** — `0` success; `1` any failed step (via the stitching triple) or
  failed child phase; `2` is reserved for usage errors in the slash runner
  (`adws/adw_slash_command.py`). Orchestrators propagate child failure as their
  own `sys.exit(1)`.
- **Failure semantics in modules** — primitives return
  `Tuple[result, Optional[error]]` or a typed response object; they never
  `sys.exit` (that is a `main()`-only privilege; see §10).
- **Version** — any `adws/**` change bumps `adws/VERSION` (gated by
  `scripts/check_versions.sh`).

## 7. Registration surfaces

### New engine-driven slash command

A step prompt invoked via `execute_template()` must be registered in three
places; miss one and the Pydantic Literal rejects the request at runtime:

1. `commands/tac/<cmd>.md` — the prompt source, dual frontmatter
   (`command:`/`version:`); deployed by `scripts/sync_commands.sh`, never hand-copied.
2. `SlashCommand` Literal — `adws/adw_modules/data_types.py:47`.
3. `SLASH_COMMAND_MODEL_MAP` — `adws/adw_modules/agent.py:30` (base + heavy model).

Operator-only commands (run via `adw_slash_command.py` or interactively) skip 2-3:
the runner treats registry membership as advisory (`adws/adw_slash_command.py:103`,
`is_known_command`).

### New workflow script — the 9-item checklist

From the toolchain spec's Problem Statement, reproduced verbatim:

> **Registration knowledge is scattered and hand-synced.** Adding one workflow
> script touches up to 9 files (`ADWWorkflow` Literal at
> `adws/adw_modules/data_types.py:28`, `AVAILABLE_ADW_WORKFLOWS` at
> `adws/adw_modules/workflow_ops.py:31`, `commands/tac/classify_adw.md`,
> `DEPENDENT_WORKFLOWS` at `adws/adw_triggers/trigger_webhook.py:44`,
> `adws/adw_tests/test_webhook_simplified.py`, `adws/README.md`, `adws/VERSION`,
> `CHANGELOG.md`, plus slash-command surfaces). Nothing automates or even
> documents this checklist in one place.

This doc is now that one place. As an executable checklist (all anchors verified
against the current tree):

| # | Surface | Anchor | What to do |
|---|---|---|---|
| 1 | `ADWWorkflow` Literal | `adws/adw_modules/data_types.py:28-43` | add the workflow name. |
| 2 | `AVAILABLE_ADW_WORKFLOWS` | `adws/adw_modules/workflow_ops.py:31-47` | add the name (runtime validation for `/classify_adw` extraction, `:89`). |
| 3 | `commands/tac/classify_adw.md` | "Valid ADW Commands" list (`:23-38`) | add `/adw_<name>` + description; bump the file's `version:`. |
| 4 | `DEPENDENT_WORKFLOWS` | `adws/adw_triggers/trigger_webhook.py:44-50` | add ONLY if the workflow requires an existing worktree/adw-id. |
| 5 | `adws/adw_tests/test_webhook_simplified.py` | mirror lists `:13-16` (dependent) and `:24-41` (entry points) | keep the mirrors in sync. |
| 6 | `adws/README.md` | workflow taxonomy sections (Entry Point / Dependent / Orchestrator, around `:150-290`) | document usage + steps. |
| 7 | `adws/VERSION` | — | bump (minor for a new workflow). |
| 8 | `CHANGELOG.md` | repo root | ADW release entry. |
| 9 | Slash-command surfaces | §7 above | only if the workflow introduces new step prompts (each new prompt = the 3-item registration). |

Items 1-2 and 4-5 are duplicated data today (registry-as-data is tracked future
work); a generator must update all copies, not pick one.

Local-launch workflows (`adw_plan_build_local_iso`-style, driven by
`agents/<adw_id>/run.json` instead of an issue) register the script basename
in items 1-3 like any workflow, but SKIP items 4-5: they are entry points,
never `DEPENDENT_WORKFLOWS`, and the webhook never launches them (webhook
triggers are issue-driven by definition — a local run has no issue to carry
the trigger comment).

## 8. Observability artifacts

Everything a run produces lives under `agents/<adw_id>/` at the checkout root
(inside a worktree, the worktree's own `adws/` modules resolve to the worktree
root — consistent module-anchored resolution, `state.py:68-73`, `agent.py:238-240`,
`utils.py:32`):

```
agents/<adw_id>/
├── adw_state.json               # ADWState — the inter-phase contract (state.py:75)
├── events.jsonl                 # adw.event/1 stream — observability.py (ADW >= 1.2.0)
├── <script_name>/
│   └── execution.log            # per-phase logger output (utils.py:20)
└── <agent_name>/                # one dir per agent call site (e.g. sdlc_planner, ops)
    ├── raw_output.jsonl         # Claude Code stream-json transcript (agent.py:547)
    ├── raw_output.json          # JSON-array mirror (agent.py:187)
    └── prompts/<command>.txt    # the exact prompt sent (agent.py:225)
```

### The `adw.event/1` schema

One JSON object per line in `events.jsonl`:

```json
{
  "schema": "adw.event/1",
  "ts": "<ISO-8601 UTC>",
  "adw_id": "abc12345",
  "source": "agent" | "state" | "workflow",
  "event_type": "agent_call_start",
  "agent_name": "sdlc_planner",
  "payload": {},
  "summary": null
}
```

`agent_name` and `summary` are nullable; `payload` is a dict (non-serializable
values degrade to `str()`). Kill switch: `ADW_EVENTS_DISABLED=1` makes every emit
a no-op returning `False`. Emission is fail-silent by contract — an events bug
can never break a workflow.

### Engine chokepoints (the only two wiring sites)

| Source | Chokepoint | Events emitted |
|---|---|---|
| `agent` | `prompt_claude_code_with_retry()` — `adws/adw_modules/agent.py:250` | `agent_call_start` (payload: `model`, `agent_name`, best-effort `command`, `output_file`) before the attempt loop; `agent_call_retry` (payload: `attempt`, `retry_code`, `delay`) per retry; `agent_call_end` (payload: `success`, `retry_code`, `duration_ms`) after. |
| `state` | `ADWState.save()` — `adws/adw_modules/state.py:75` | `state_saved` (payload: `{"workflow_step": <arg>, "state": <data>}`) after a successful write. |

Because every engine agent call funnels through `prompt_claude_code_with_retry`
and every phase boundary funnels through `state.save`, the 14 workflow scripts
needed no edits. The `source: "workflow"` value is reserved for workflow-level
emits from generated scripts that opt in. Orchestration apps consume the stream
via `read_events()` or by tailing the file — this is the zero-dependency contract
`ai_docs/adw-orchestration.md` builds its tiers on.

## 9. Testing conventions

Engine tests are **hermetic**: no network, no subprocess, no Claude. The pattern
to copy is `adws/adw_tests/test_slash_command.py`:

- uv single-file runnable with pytest in the deps block (`:1-4`) and a
  `pytest.main([__file__, "-v"])` entry (`:230-231`) — run with
  `uv run adws/adw_tests/test_slash_command.py`.
- `sys.path.insert(0, <adws dir>)` so `adw_modules` imports cleanly (`:22-23`).
- Monkeypatch the engine seam, not internals:
  `monkeypatch.setattr(agent_mod, "prompt_claude_code_with_retry", lambda req: canned)`
  with a canned `AgentPromptResponse` (`:148-160`), plus
  `check_claude_installed → None` (`:149`).
- Assert the negative too: dry-run paths must NEVER reach the engine — patch it
  with a function that raises (`:89-96`).
- Path regression guards assert on returned path strings: outputs land under the
  repo-root `agents/`, never a stray `adws/agents/` (`:170-173`).
- When the code under test touches module-anchored paths (state, events — they
  resolve relative to the module file, NOT cwd), monkeypatch the path seam
  (`ADWState.get_state_path`, `observability.events_path`'s root, or pass
  `working_dir`) at a pytest tmp dir, or the real checkout's `agents/` gets
  polluted. `adws/adw_tests/test_observability.py` is the worked example.

Structural/factory-level checks (file existence, frontmatter, command-set
resolution) live in `tests/*.bats`, not here.

## 10. Known pitfalls a generator must NOT copy

These exist in the current code. They are documented limitations, kept for
stability — generated artifacts must not replicate the patterns:

1. **`remove_worktree`'s un-imported `shutil`** —
   `adws/adw_modules/worktree_ops.py:142` calls `shutil.rmtree(...)` on the
   manual-cleanup fallback path, but `shutil` is never imported (`:6-12`): the
   fallback raises `NameError` instead of cleaning up. Lesson: generated modules
   must import everything they reference — including rarely-hit error paths —
   and a hermetic test should drive those paths.
2. **`fetch_issue`'s `sys.exit` inside a library** —
   `adws/adw_modules/github.py:107` (also `:120`, `:123`) kills the entire
   process from inside a module. House failure style is
   `Tuple[result, Optional[error]]` or a typed response with `success=False`;
   `sys.exit` belongs only in a script's `main()` (the §3 stitching triple).
3. **Hard-pinned model literals** — model names are frozen as
   `Literal["sonnet", "opus"]` on `AgentPromptRequest`/`AgentTemplateRequest`
   (`adws/adw_modules/data_types.py:153`, `:175`) and as string literals across
   `SLASH_COMMAND_MODEL_MAP` (`adws/adw_modules/agent.py:30-49`). Generated code
   must never hardcode a model name at a call site: route selection through
   `SLASH_COMMAND_MODEL_MAP` + `get_model_for_slash_command` (`agent.py:52`) so
   the base/heavy `model_set` mechanism keeps working.

Secondary (be aware, do not imitate): `find_plan_for_issue` returns the first
plan found regardless of issue when no adw_id is given
(`adws/adw_modules/workflow_ops.py:476-483` — its own comment admits it); bare
`except:` clauses swallow diagnostics in `agent.py`'s JSONL salvage paths
(`:121`, `:420-423`, `:471-472`) — prefer narrow exceptions with logging.
