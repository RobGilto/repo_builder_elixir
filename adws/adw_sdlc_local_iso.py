#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW SDLC Local Iso - GitHub-optional full SDLC in an isolated worktree
(plan + build + test + review + document)

Usage:
  uv run adw_sdlc_local_iso.py <adw-id> [--skip-e2e] [--skip-resolution]

The single positional argument is the whole CLI contract: the launcher writes
agents/<adw_id>/run.json (adw.run/1, status pending) BEFORE spawning, and this
workflow pulls all task context from that record (local launch contract, see
adw_modules/local_ops.py). The default path makes ZERO GitHub or network
calls; a real input_data.issue_number turns on best-effort issue comments as
optional enrichment, never a prerequisite.

Local-mode simplifications (prompt-mode runs have no browser context and no
GitHub feedback channel): E2E tests are always skipped and test/review
resolution loops are disabled — test failures and review blockers are
narrated as warnings (non-fatal gate, mirroring adw_sdlc_iso's test phase).
The --skip-e2e / --skip-resolution flags are accepted for CLI compatibility.

Workflow:
1. Load + validate the run record; mark in_progress
2. Synthesize a local GitHubIssue from the prompt (numeric local id keeps the
   issue-{n}-adw-{id} spec/branch conventions intact)
3. Worktree + ports + branch (worktree_ops falls back to local main/master
   when origin/main is unavailable)
4. Plan step: /feature via build_plan (agent: sdlc_planner)
5. Build step: /implement via implement_plan (agent: sdlc_implementor); commit
6. Test step: /test single pass (agent: test_runner) — failures non-fatal
7. Review step: /review single pass (agent: reviewer) — blockers non-fatal
8. Document step: /document (agent: documenter); commit; mark completed

All progress narration is emitted as adw.event/1 lines (source: "workflow") —
the file-store equivalent of the GitHub twins' issue comments.
"""

import glob
import os
import subprocess
import sys
import time
from typing import List, Optional, Tuple

from dotenv import load_dotenv

from adw_modules import local_ops
from adw_modules.agent import execute_template
from adw_modules.data_types import (
    AgentTemplateRequest,
    GitHubIssue,
    ReviewResult,
    TestResult,
)
from adw_modules.git_ops import commit_changes
from adw_modules.observability import emit_event
from adw_modules.state import ADWState
from adw_modules.utils import check_env_vars, parse_json, setup_logger
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

WORKFLOW_NAME = "adw_sdlc_local_iso"
ISSUE_CLASS = "/feature"  # prompt-driven runs always plan through /feature
TOTAL_STEPS = 5

# Agent name constants (mirror the dependent-phase GitHub twins)
AGENT_TESTER = "test_runner"
AGENT_REVIEWER = "reviewer"
AGENT_DOCUMENTER = "documenter"


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


def find_spec_fallback(worktree_path: str, issue_number: int, adw_id: str) -> Optional[str]:
    """Newest specs/issue-{n}-adw-{id}*.md by mtime (Output Contract fallback)."""
    pattern = os.path.join(
        worktree_path, "specs", f"issue-{issue_number}-adw-{adw_id}*.md"
    )
    candidates = glob.glob(pattern)
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


def get_commit_sha(worktree_path: str) -> Optional[str]:
    """Current HEAD sha in the worktree, or None."""
    rev = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True, text=True, cwd=worktree_path,
    )
    return rev.stdout.strip() if rev.returncode == 0 else None


def commit_phase_artifacts(
    adw_id: str, phase: str, worktree_path: str, logger
) -> Optional[str]:
    """Commit a phase's artifacts with a deterministic message (no agent
    call, fully offline). No-op success when the worktree is clean.
    Returns the HEAD sha, or None on commit failure (logged, non-fatal)."""
    message = f"chore: {phase} artifacts via {WORKFLOW_NAME} (adw {adw_id})"
    success, error = commit_changes(message, cwd=worktree_path)
    if not success:
        logger.warning(f"Could not commit {phase} artifacts (non-fatal): {error}")
        return None
    return get_commit_sha(worktree_path)


def run_test_phase(
    adw_id: str, worktree_path: str, logger
) -> Tuple[List[TestResult], int, int]:
    """Single /test pass (no resolution loop, no E2E in local mode).
    Returns (results, passed_count, failed_count). Raises nothing; an
    agent-level failure is reported by the caller via response checks."""
    request = AgentTemplateRequest(
        agent_name=AGENT_TESTER,
        slash_command="/test",
        args=[],
        adw_id=adw_id,
        working_dir=worktree_path,
    )
    response = execute_template(request)
    if not response.success:
        return [], 0, -1  # sentinel: agent-level error (caller fails the step)
    try:
        results = parse_json(response.output, List[TestResult])
    except Exception as e:
        logger.warning(f"Could not parse test results (non-fatal): {e}")
        return [], 0, 0
    passed = sum(1 for t in results if t.passed)
    return results, passed, len(results) - passed


def run_review_phase(
    spec_file: str, adw_id: str, worktree_path: str, logger
) -> Optional[ReviewResult]:
    """Single /review pass (resolution loop disabled in local mode).
    Returns the parsed ReviewResult, or None on agent-level failure."""
    request = AgentTemplateRequest(
        agent_name=AGENT_REVIEWER,
        slash_command="/review",
        args=[adw_id, spec_file, AGENT_REVIEWER],
        adw_id=adw_id,
        working_dir=worktree_path,
    )
    response = execute_template(request)
    if not response.success:
        logger.error(f"Review failed: {response.output}")
        return None
    try:
        return parse_json(response.output, ReviewResult)
    except Exception as e:
        logger.warning(f"Could not parse review result (non-fatal): {e}")
        return ReviewResult(
            success=False,
            review_summary=f"Unparseable review output: {e}",
            review_issues=[],
            screenshots=[],
            screenshot_urls=[],
        )


def run_document_phase(
    spec_file: str, adw_id: str, worktree_path: str, logger
) -> Optional[str]:
    """/document pass. Returns the doc path, the sentinel
    "No documentation needed", or None on agent-level failure."""
    request = AgentTemplateRequest(
        agent_name=AGENT_DOCUMENTER,
        slash_command="/document",
        args=[spec_file],
        adw_id=adw_id,
        working_dir=worktree_path,
    )
    response = execute_template(request)
    if not response.success:
        logger.error(f"Documentation generation failed: {response.output}")
        return None
    return response.output.strip()


def main():
    """Main entry point."""
    load_dotenv()

    # Accepted for CLI compatibility with adw_sdlc_iso; in local mode E2E and
    # resolution loops are always skipped regardless of these flags.
    for flag in ("--skip-e2e", "--skip-resolution"):
        if flag in sys.argv:
            sys.argv.remove(flag)

    if len(sys.argv) < 2:
        print("Usage: uv run adw_sdlc_local_iso.py <adw-id> [--skip-e2e] [--skip-resolution]")
        print("\nError: the run record agents/<adw-id>/run.json is the task")
        print("context — create it first (local_ops.create_run or the")
        print("orchestrator app), then launch with its adw-id.")
        sys.exit(1)

    adw_id = sys.argv[1]
    logger = setup_logger(adw_id, WORKFLOW_NAME)
    logger.info(f"ADW SDLC Local Iso starting - ID: {adw_id}")

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
    narrate(adw_id, "✅ Starting local SDLC (GitHub-optional)")

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
        run, f"{adw_id}_ops: ✅ Local SDLC started in {worktree_path}", logger
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
                f"specs/issue-{issue.number}-adw-{adw_id}*.md exists",
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

    commit_sha = get_commit_sha(worktree_path)

    local_ops.update_run(
        adw_id,
        current_step="test",
        completed_steps=2,
        output={"commit": commit_sha},
    )
    local_ops.step_end(
        adw_id, "build", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"commit: {commit_sha or 'n/a'}",
    )

    # --- Test step (single pass; failures are a non-fatal gate, mirroring
    # adw_sdlc_iso; E2E always skipped in local mode) ---
    local_ops.step_start(adw_id, "test", summary="running /test (E2E skipped in local mode)")
    step_t0 = time.monotonic()

    results, passed_count, failed_count = run_test_phase(adw_id, worktree_path, logger)
    if failed_count < 0:
        local_ops.step_end(adw_id, "test", "failed")
        fail(adw_id, "test", "Error running tests (agent-level failure)", logger)

    if failed_count > 0:
        narrate(
            adw_id,
            f"⚠️ Tests: {passed_count} passed, {failed_count} failed "
            "(non-fatal in local mode — continuing)",
            agent_name=AGENT_TESTER,
        )
    else:
        narrate(
            adw_id,
            f"✅ Tests: {passed_count} passed, 0 failed",
            agent_name=AGENT_TESTER,
        )

    test_commit = commit_phase_artifacts(adw_id, "test", worktree_path, logger)
    local_ops.update_run(
        adw_id,
        current_step="review",
        completed_steps=3,
        output={"commit": test_commit or commit_sha},
    )
    local_ops.step_end(
        adw_id, "test", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"{passed_count} passed, {failed_count} failed",
    )

    # --- Review step (single pass; blockers narrated, resolution skipped) ---
    local_ops.step_start(adw_id, "review", summary=f"reviewing against {spec_file}")
    step_t0 = time.monotonic()

    review_result = run_review_phase(spec_file, adw_id, worktree_path, logger)
    if review_result is None:
        local_ops.step_end(adw_id, "review", "failed")
        fail(adw_id, "review", "Error running review (agent-level failure)", logger)

    blockers = [
        i for i in review_result.review_issues if i.issue_severity == "blocker"
    ]
    if blockers:
        narrate(
            adw_id,
            f"⚠️ Review found {len(blockers)} blocker(s) "
            "(resolution skipped in local mode): "
            + "; ".join(b.issue_description for b in blockers),
            agent_name=AGENT_REVIEWER,
        )
    else:
        narrate(
            adw_id,
            f"✅ Review passed: {review_result.review_summary}",
            agent_name=AGENT_REVIEWER,
        )

    review_commit = commit_phase_artifacts(adw_id, "review", worktree_path, logger)
    local_ops.update_run(
        adw_id,
        current_step="document",
        completed_steps=4,
        output={"commit": review_commit or test_commit or commit_sha},
    )
    local_ops.step_end(
        adw_id, "review", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=f"{len(blockers)} blocker(s)",
    )

    # --- Document step ---
    local_ops.step_start(adw_id, "document", summary=f"documenting {spec_file}")
    step_t0 = time.monotonic()

    doc_output = run_document_phase(spec_file, adw_id, worktree_path, logger)
    if doc_output is None:
        local_ops.step_end(adw_id, "document", "failed")
        fail(adw_id, "document", "Error generating documentation", logger)

    if doc_output and doc_output != "No documentation needed":
        narrate(adw_id, f"✅ Documentation created: {doc_output}", agent_name=AGENT_DOCUMENTER)
    else:
        narrate(adw_id, "ℹ️ No documentation changes were needed", agent_name=AGENT_DOCUMENTER)

    doc_commit = commit_phase_artifacts(adw_id, "document", worktree_path, logger)
    local_ops.step_end(
        adw_id, "document", "completed",
        duration_ms=int((time.monotonic() - step_t0) * 1000),
        summary=doc_output or "n/a",
    )

    local_ops.update_run(
        adw_id,
        status=local_ops.COMPLETED,
        completed_steps=TOTAL_STEPS,
        output={"commit": doc_commit or review_commit or test_commit or commit_sha},
    )
    state.save(WORKFLOW_NAME)
    narrate(adw_id, "✅ Local SDLC completed")
    maybe_comment_on_real_issue(
        run,
        f"{adw_id}_ops: ✅ Local SDLC completed — spec {spec_file}, "
        f"branch {branch_name}, tests {passed_count}p/{failed_count}f, "
        f"{len(blockers)} review blocker(s)",
        logger,
    )
    logger.info("Local SDLC completed successfully")


if __name__ == "__main__":
    main()
