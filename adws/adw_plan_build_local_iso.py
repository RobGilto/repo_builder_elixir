#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Plan Build Local Iso - GitHub-optional plan + build in an isolated worktree

Usage:
  uv run adw_plan_build_local_iso.py <adw-id>

The single positional argument is the whole CLI contract: the launcher writes
agents/<adw_id>/run.json (adw.run/1, status pending) BEFORE spawning, and this
workflow pulls all task context from that record (local launch contract, see
adw_modules/local_ops.py). The default path makes ZERO GitHub or network
calls; a real input_data.issue_number turns on best-effort issue comments as
optional enrichment, never a prerequisite.

Workflow:
1. Load + validate the run record; mark in_progress
2. Synthesize a local GitHubIssue from the prompt (numeric local id keeps the
   issue-{n}-adw-{id} spec/branch conventions intact)
3. Worktree + ports + branch (worktree_ops falls back to local main/master
   when origin/main is unavailable)
4. Plan step: /feature via build_plan (agent: sdlc_planner)
5. Build step: /implement via implement_plan (agent: sdlc_implementor)
6. Commit in the worktree (no push); mark completed

All progress narration is emitted as adw.event/1 lines (source: "workflow") —
the file-store equivalent of the GitHub twins' issue comments.
"""

import glob
import os
import subprocess
import sys
import time
from typing import Optional

from dotenv import load_dotenv

from adw_modules import local_ops
from adw_modules.data_types import GitHubIssue
from adw_modules.git_ops import commit_changes
from adw_modules.observability import emit_event
from adw_modules.state import ADWState
from adw_modules.utils import check_env_vars, setup_logger
from adw_modules.workflow_ops import (
    AGENT_IMPLEMENTOR,
    AGENT_PLANNER,
    build_plan,
    create_commit,
    implement_plan,
)
from adw_modules.worktree_ops import (
    create_worktree,
    find_next_available_ports,
    get_ports_for_adw,
    is_port_available,
    setup_worktree_environment,
    validate_worktree,
)

WORKFLOW_NAME = "adw_plan_build_local_iso"
ISSUE_CLASS = "/feature"  # prompt-driven runs always plan through /feature


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
    slug = "".join(
        c if c.isalnum() else "-" for c in issue.title.lower()
    ).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return f"feature-issue-{issue.number}-adw-{adw_id}-{slug[:40].rstrip('-')}"


def find_spec_fallback(worktree_path: str, issue_number: int, adw_id: str) -> Optional[str]:
    """Newest specs/issue-{n}-adw-{id}*.md by mtime (Output Contract fallback)."""
    base = os.path.join(
        worktree_path, "specs", f"issue-{issue_number}-adw-{adw_id}*"
    )
    candidates = glob.glob(base + ".md") + glob.glob(base + ".html")
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


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
        print("Usage: uv run adw_plan_build_local_iso.py <adw-id>")
        print("\nError: the run record agents/<adw-id>/run.json is the task")
        print("context — create it first (local_ops.create_run or the")
        print("orchestrator app), then launch with its adw-id.")
        sys.exit(1)

    adw_id = sys.argv[1]
    logger = setup_logger(adw_id, WORKFLOW_NAME)
    logger.info(f"ADW Plan Build Local Iso starting - ID: {adw_id}")

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

    local_ops.update_run(adw_id, status=local_ops.IN_PROGRESS, current_step="plan")
    narrate(adw_id, "✅ Starting local plan+build (GitHub-optional)")

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
        run, f"{adw_id}_ops: ✅ Local plan+build started in {worktree_path}", logger
    )

    # --- Plan step ---
    local_ops.step_start(adw_id, "plan", summary="planning via /feature")
    step_t0 = time.monotonic()

    plan_response = build_plan(
        issue, ISSUE_CLASS, adw_id, logger, working_dir=worktree_path
    )
    if not plan_response.success:
        local_ops.step_end(adw_id, "plan", "failed")
        fail(adw_id, "plan", f"Error building plan: {plan_response.output}", logger)

    # Output Contract: the response is the spec path; fallback = newest
    # specs/issue-{n}-adw-{id}*.md in the worktree by mtime.
    spec_file = plan_response.output.strip().strip("`")
    spec_abs = (
        spec_file if os.path.isabs(spec_file)
        else os.path.join(worktree_path, spec_file)
    )
    if not spec_file or not os.path.exists(spec_abs):
        fallback = find_spec_fallback(worktree_path, issue.number, adw_id)
        if not fallback:
            local_ops.step_end(adw_id, "plan", "failed")
            fail(
                adw_id,
                "plan",
                f"Planner returned no usable spec path ({spec_file!r}) and no "
                f"specs/issue-{issue.number}-adw-{adw_id}*.{{md,html}} exists",
                logger,
            )
        spec_abs = fallback
        spec_file = os.path.relpath(fallback, worktree_path)
        logger.info(f"Using fallback spec file: {spec_file}")

    state.update(plan_file=spec_file)
    state.save(WORKFLOW_NAME)
    local_ops.update_run(
        adw_id,
        current_step="build",
        completed_steps=1,
        output={"spec_file": spec_file},
    )
    local_ops.step_end(
        adw_id, "plan", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"spec: {spec_file}",
    )
    narrate(adw_id, f"✅ Plan created: {spec_file}", agent_name=AGENT_PLANNER)

    # --- Build step ---
    local_ops.step_start(adw_id, "build", summary=f"implementing {spec_file}")
    step_t0 = time.monotonic()

    build_response = implement_plan(
        spec_file, adw_id, logger, working_dir=worktree_path
    )
    if not build_response.success:
        local_ops.step_end(adw_id, "build", "failed")
        fail(adw_id, "build", f"Error implementing plan: {build_response.output}", logger)

    narrate(adw_id, "✅ Implementation complete", agent_name=AGENT_IMPLEMENTOR)

    # Commit in the worktree (no push — GitHub stays optional)
    commit_msg, error = create_commit(
        AGENT_IMPLEMENTOR, issue, ISSUE_CLASS, adw_id, logger, worktree_path
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
        completed_steps=2,
        output={"commit": commit_sha},
    )
    state.save(WORKFLOW_NAME)
    narrate(adw_id, "✅ Local plan+build completed")
    maybe_comment_on_real_issue(
        run,
        f"{adw_id}_ops: ✅ Local plan+build completed — spec {spec_file}, "
        f"branch {branch_name}, commit {commit_sha or 'n/a'}",
        logger,
    )
    logger.info("Local plan+build completed successfully")


if __name__ == "__main__":
    main()
