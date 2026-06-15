#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Patch Local Iso - GitHub-optional patch workflow in an isolated worktree

Usage:
  uv run adw_patch_local_iso.py <adw-id>

The single positional argument is the whole CLI contract: the launcher writes
agents/<adw_id>/run.json (adw.run/1, status pending) BEFORE spawning, and this
workflow pulls all task context from that record (local launch contract, see
adw_modules/local_ops.py). The default path makes ZERO GitHub or network
calls; a real input_data.issue_number turns on best-effort issue comments as
optional enrichment, never a prerequisite.

In local mode the user's freeform prompt IS the patch description: the
'adw_patch' keyword extraction (find_keyword_from_comment) of the GitHub twin
is skipped entirely — input_data.prompt is used directly as patch content.

Workflow:
1. Load + validate the run record; mark in_progress
2. Synthesize a local GitHubIssue from the prompt (numeric local id keeps the
   issue-{n}-adw-{id} spec/branch conventions intact)
3. Worktree + ports + branch (worktree_ops falls back to local main/master
   when origin/main is unavailable)
4. Plan step: patch plan via /patch (agent: patch_planner)
5. Build step: /implement via implement_plan (agent: patch_implementor)
6. Commit in the worktree (no push); mark completed

All progress narration is emitted as adw.event/1 lines (source: "workflow") —
the file-store equivalent of the GitHub twins' issue comments.
"""

import os
import subprocess
import sys
import time
from typing import Optional

from dotenv import load_dotenv

from adw_modules import local_ops
from adw_modules.agent import execute_template
from adw_modules.data_types import AgentTemplateRequest, GitHubIssue
from adw_modules.git_ops import commit_changes
from adw_modules.observability import emit_event
from adw_modules.state import ADWState
from adw_modules.utils import check_env_vars, setup_logger
from adw_modules.workflow_ops import create_commit, implement_plan
from adw_modules.worktree_ops import (
    create_worktree,
    find_next_available_ports,
    get_ports_for_adw,
    is_port_available,
    setup_worktree_environment,
    validate_worktree,
)

WORKFLOW_NAME = "adw_patch_local_iso"
ISSUE_CLASS = "/bug"  # patch-mode convention
TOTAL_STEPS = 2

# Agent name constants (mirror adw_patch_iso)
AGENT_PATCH_PLANNER = "patch_planner"
AGENT_PATCH_IMPLEMENTOR = "patch_implementor"


def narrate(adw_id: str, message: str, agent_name: str = "ops") -> None:
    """Workflow narration to the event stream (the issue-comment twin)."""
    emit_event(
        adw_id,
        "workflow",
        "progress",
        payload={"message": message},
        agent_name=agent_name,
        summary=message,
    )


def fail(adw_id: str, step: Optional[str], message: str, logger=None) -> None:
    """Record failure on the run + events, then exit 1."""
    if logger:
        logger.error(message)
    narrate(adw_id, f"❌ {message}")
    local_ops.update_run(
        adw_id, status=local_ops.FAILED, error_message=message, error_step=step
    )
    sys.exit(1)


def synthesize_branch_name(issue: GitHubIssue, adw_id: str) -> str:
    """Deterministic branch name in the canonical structure
    <issue_class>-issue-<n>-adw-<id>-<slug> — no agent call, fully offline."""
    prefix = ISSUE_CLASS.replace("/", "")
    slug = "".join(
        c if c.isalnum() else "-" for c in issue.title.lower()
    ).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return f"{prefix}-issue-{issue.number}-adw-{adw_id}-{slug[:40].rstrip('-')}"


def maybe_comment_on_real_issue(run: dict, message: str, logger) -> None:
    """Optional GitHub enrichment: best-effort, never load-bearing."""
    issue_number = run.get("input_data", {}).get("issue_number")
    if not isinstance(issue_number, int) or issue_number >= local_ops.LOCAL_ISSUE_BASE:
        return
    try:
        from adw_modules.github import make_issue_comment

        make_issue_comment(str(issue_number), message)
    except Exception as e:
        logger.warning(f"GitHub enrichment skipped (non-fatal): {e}")


def main():
    """Main entry point."""
    load_dotenv()

    if len(sys.argv) < 2:
        print("Usage: uv run adw_patch_local_iso.py <adw-id>")
        print("\nError: the run record agents/<adw-id>/run.json is the task")
        print("context — create it first (local_ops.create_run or the")
        print("orchestrator app), then launch with its adw-id.")
        sys.exit(1)

    adw_id = sys.argv[1]
    logger = setup_logger(adw_id, WORKFLOW_NAME)
    logger.info(f"ADW Patch Local Iso starting - ID: {adw_id}")

    # Validate environment (CLAUDE_CODE_PATH is the only hard requirement)
    check_env_vars(logger)

    # Load and validate the run record — it IS the launch context
    run = local_ops.load_run(adw_id)
    if run is None:
        # No run record: emit what we can, exit without update_run (no record).
        narrate(adw_id, f"❌ No run record at agents/{adw_id}/run.json")
        logger.error(f"Missing or corrupt run record for {adw_id}")
        sys.exit(1)

    prompt = run.get("input_data", {}).get("prompt")
    if not prompt or not str(prompt).strip():
        fail(adw_id, None, "Run record has no input_data.prompt", logger)

    local_ops.update_run(
        adw_id,
        status=local_ops.IN_PROGRESS,
        current_step="plan",
        total_steps=TOTAL_STEPS,
    )
    narrate(adw_id, "✅ Starting local patch (GitHub-optional)")

    # Synthesize the issue: numeric local id keeps every downstream
    # spec-filename/branch-glob convention working without GitHub.
    issue = local_ops.synthesize_issue(run)
    logger.info(f"Synthesized local issue #{issue.number}: {issue.title}")

    # State: sibling of run.json, same whitelist + consumers as the GitHub twins
    state = ADWState.load(adw_id, logger) or ADWState(adw_id)
    state.update(adw_id=adw_id, issue_number=str(issue.number), issue_class=ISSUE_CLASS)
    model = run.get("input_data", {}).get("model")
    # Accept both the legacy concrete name ("opus") and the heavy tier so
    # existing run.json records and tier-based callers both pick the heavy profile.
    state.update(model_set="heavy" if model in ("heavy", "opus") else "base")
    state.append_adw_id(WORKFLOW_NAME)
    state.save(WORKFLOW_NAME)

    # Worktree + ports (reuse existing worktree when resuming)
    valid, _ = validate_worktree(adw_id, state)
    if valid:
        worktree_path = state.get("worktree_path")
        backend_port = state.get("backend_port")
        frontend_port = state.get("frontend_port")
        branch_name = state.get("branch_name")
        logger.info(f"Reusing existing worktree at {worktree_path}")
    else:
        backend_port, frontend_port = get_ports_for_adw(adw_id)
        if not (is_port_available(backend_port) and is_port_available(frontend_port)):
            backend_port, frontend_port = find_next_available_ports(adw_id)
        state.update(backend_port=backend_port, frontend_port=frontend_port)

        branch_name = synthesize_branch_name(issue, adw_id)
        state.update(branch_name=branch_name)
        state.save(WORKFLOW_NAME)

        worktree_path, error = create_worktree(adw_id, branch_name, logger)
        if error:
            fail(adw_id, "plan", f"Error creating worktree: {error}", logger)

        state.update(worktree_path=worktree_path)
        state.save(WORKFLOW_NAME)
        setup_worktree_environment(worktree_path, backend_port, frontend_port, logger)

    local_ops.update_run(
        adw_id, output={"branch": branch_name, "worktree": worktree_path}
    )
    narrate(
        adw_id,
        f"✅ Worktree ready: {worktree_path} (branch {branch_name}, "
        f"ports {backend_port}/{frontend_port})",
    )
    maybe_comment_on_real_issue(
        run, f"{adw_id}_ops: ✅ Local patch started in {worktree_path}", logger
    )

    # --- Patch plan step (the prompt IS the patch spec) ---
    local_ops.step_start(adw_id, "plan", summary="patch planning via /patch")
    step_t0 = time.monotonic()

    patch_request = AgentTemplateRequest(
        agent_name=AGENT_PATCH_PLANNER,
        slash_command="/patch",
        args=[adw_id, str(prompt), "", AGENT_PATCH_PLANNER],
        adw_id=adw_id,
        working_dir=worktree_path,
    )
    patch_response = execute_template(patch_request)
    if not patch_response.success:
        local_ops.step_end(adw_id, "plan", "failed")
        fail(
            adw_id, "plan",
            f"Error creating patch plan: {patch_response.output}", logger,
        )

    # Output Contract: a specs/patch/*.md path and nothing else
    patch_file = patch_response.output.strip().strip("`")
    if "specs/patch/" not in patch_file or not patch_file.endswith(".md"):
        local_ops.step_end(adw_id, "plan", "failed")
        fail(adw_id, "plan", f"Invalid patch plan path: {patch_file!r}", logger)

    state.update(plan_file=patch_file)
    state.save(WORKFLOW_NAME)
    local_ops.update_run(
        adw_id,
        current_step="build",
        completed_steps=1,
        output={"spec_file": patch_file},
    )
    local_ops.step_end(
        adw_id, "plan", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"patch plan: {patch_file}",
    )
    narrate(adw_id, f"✅ Patch plan created: {patch_file}", agent_name=AGENT_PATCH_PLANNER)

    # --- Patch implement step ---
    local_ops.step_start(adw_id, "build", summary=f"implementing {patch_file}")
    step_t0 = time.monotonic()

    build_response = implement_plan(
        patch_file, adw_id, logger,
        agent_name=AGENT_PATCH_IMPLEMENTOR, working_dir=worktree_path,
    )
    if not build_response.success:
        local_ops.step_end(adw_id, "build", "failed")
        fail(adw_id, "build", f"Error implementing patch: {build_response.output}", logger)

    narrate(adw_id, "✅ Patch implemented", agent_name=AGENT_PATCH_IMPLEMENTOR)

    # Commit in the worktree (no push — GitHub stays optional)
    commit_msg, error = create_commit(
        AGENT_PATCH_IMPLEMENTOR, issue, ISSUE_CLASS, adw_id, logger, worktree_path
    )
    if error:
        local_ops.step_end(adw_id, "build", "failed")
        fail(adw_id, "build", f"Error creating commit message: {error}", logger)

    success, error = commit_changes(commit_msg, cwd=worktree_path)
    if not success:
        local_ops.step_end(adw_id, "build", "failed")
        fail(adw_id, "build", f"Error committing changes: {error}", logger)

    commit_sha = None
    rev = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True, text=True, cwd=worktree_path,
    )
    if rev.returncode == 0:
        commit_sha = rev.stdout.strip()

    local_ops.step_end(
        adw_id, "build", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"commit: {commit_sha or 'n/a'}",
    )

    local_ops.update_run(
        adw_id,
        status=local_ops.COMPLETED,
        completed_steps=TOTAL_STEPS,
        output={"commit": commit_sha},
    )
    state.save(WORKFLOW_NAME)
    narrate(adw_id, "✅ Local patch completed")
    maybe_comment_on_real_issue(
        run,
        f"{adw_id}_ops: ✅ Local patch completed — patch {patch_file}, "
        f"branch {branch_name}, commit {commit_sha or 'n/a'}",
        logger,
    )
    logger.info("Local patch completed successfully")


if __name__ == "__main__":
    main()
