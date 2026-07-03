"""Local launch contract for GitHub-optional ADW workflows.

The orchestration app (or any local caller) writes the task context to
`agents/<adw_id>/run.json` BEFORE spawning a workflow; the workflow pulls
everything from that record by adw_id — the CLI carries only the id. This is
tac-14's context inversion on this engine's file store: `run.json` plays the
role of tac-14's `ai_developer_workflows` row.

`run.json` is a SIBLING of `adw_state.json`, never a replacement: it carries
launch context + lifecycle; `ADWState` keeps its whitelist and consumers.

Run record schema (`adw.run/1`) — one JSON object per file:

    {
        "schema": "adw.run/1",
        "adw_id": str,
        "workflow_type": str,            # e.g. "plan_build_local"
        "status": "pending" | "in_progress" | "completed" | "failed"
                  | "cancelled",
        "current_step": str | null,
        "total_steps": int,
        "completed_steps": int,
        "created_at": "<ISO-8601 UTC>",
        "started_at": "<ISO-8601 UTC>" | null,
        "completed_at": "<ISO-8601 UTC>" | null,
        "duration_seconds": float | null,
        "input_data": {
            "prompt": str,
            "model": str | null,
            "working_dir": str | null,
            "issue_number": int | null   # real GitHub issue = optional enrichment
        },
        "output_data": {
            "spec_file": str | null,
            "branch": str | null,
            "worktree": str | null,
            "commit": str | null
        },
        "error_message": str | null,
        "error_step": str | null,
        "merge_status": "unmerged" | "merged" | "failed",
        "merged_sha": str | null,
        "merge_error": str | null
    }

Status/timing semantics (tac-14 `update_adw_status` parity): transitioning to
`in_progress` sets `started_at` exactly once; any terminal status sets
`completed_at` and `duration_seconds`. Every `update_run` also emits a
`run_updated` adw.event/1 line (fail-silent) carrying the changed fields.

Design constraints:
- Stdlib + existing adw_modules only. Saves are atomic (tmp file + os.replace).
- Path resolution is module-anchored, mirroring `observability.events_path`:
  the root is the checkout containing `adws/`; cwd is never consulted. Pass
  `working_dir` to override the root explicitly (test seam).
"""

import json
import os
import re
import tempfile
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from adw_modules.data_types import GitHubIssue, GitHubUser
from adw_modules.observability import emit_event

RUN_SCHEMA = "adw.run/1"
RUN_FILENAME = "run.json"

PENDING = "pending"
IN_PROGRESS = "in_progress"
COMPLETED = "completed"
FAILED = "failed"
CANCELLED = "cancelled"
TERMINAL_STATUSES = {COMPLETED, FAILED, CANCELLED}
VALID_STATUSES = {PENDING, IN_PROGRESS} | TERMINAL_STATUSES

# Merge outcome of the ship step (trunk-aware merge, see merge_ops.py)
MERGE_UNMERGED = "unmerged"
MERGE_MERGED = "merged"
MERGE_FAILED = "failed"
VALID_MERGE_STATUSES = {MERGE_UNMERGED, MERGE_MERGED, MERGE_FAILED}

# Synthesized local issue numbers live far above any plausible real issue so
# the two namespaces can never collide in spec filenames or branch globs.
LOCAL_ISSUE_BASE = 9_000_000
_LOCAL_ISSUE_MOD = 999_983  # prime, keeps the hash well-distributed


def _default_root() -> str:
    """Checkout root containing adws/ — mirrors observability._default_root."""
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def run_path(adw_id: str, working_dir: Optional[str] = None) -> str:
    """Path to the run record: <root>/agents/<adw_id>/run.json."""
    root = working_dir if working_dir else _default_root()
    return os.path.join(root, "agents", adw_id, RUN_FILENAME)


def create_run(
    adw_id: str,
    workflow_type: str,
    prompt: str,
    model: Optional[str] = None,
    issue_number: Optional[int] = None,
    input_working_dir: Optional[str] = None,
    total_steps: int = 2,
    working_dir: Optional[str] = None,
) -> Dict[str, Any]:
    """Create and persist a pending adw.run/1 record. Returns the dict."""
    run = {
        "schema": RUN_SCHEMA,
        "adw_id": adw_id,
        "workflow_type": workflow_type,
        "status": PENDING,
        "current_step": None,
        "total_steps": total_steps,
        "completed_steps": 0,
        "created_at": _now_iso(),
        "started_at": None,
        "completed_at": None,
        "duration_seconds": None,
        "input_data": {
            "prompt": prompt,
            "model": model,
            "working_dir": input_working_dir,
            "issue_number": issue_number,
        },
        "output_data": {
            "spec_file": None,
            "branch": None,
            "worktree": None,
            "commit": None,
        },
        "error_message": None,
        "error_step": None,
        "merge_status": MERGE_UNMERGED,
        "merged_sha": None,
        "merge_error": None,
    }
    save_run(run, working_dir=working_dir)
    return run


def load_run(
    adw_id: str, working_dir: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """Load a run record, or None when absent/corrupt (caller decides)."""
    path = run_path(adw_id, working_dir=working_dir)
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def save_run(run: Dict[str, Any], working_dir: Optional[str] = None) -> bool:
    """Persist a run record atomically (tmp file + os.replace).

    A reader polling run.json never observes a partial write. Returns True on
    success, False on any I/O failure (never raises).
    """
    try:
        path = run_path(run["adw_id"], working_dir=working_dir)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=os.path.dirname(path), prefix=".run-", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(run, f, indent=2)
            os.replace(tmp_path, path)
        finally:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        return True
    except Exception:
        return False


def update_run(
    adw_id: str,
    status: Optional[str] = None,
    current_step: Optional[str] = None,
    completed_steps: Optional[int] = None,
    error_message: Optional[str] = None,
    error_step: Optional[str] = None,
    output: Optional[Dict[str, Any]] = None,
    total_steps: Optional[int] = None,
    working_dir: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """Apply field updates with tac-14 status/timing semantics, then persist.

    Returns the updated run dict, or None when the record can't be loaded.
    Emits a `run_updated` event (fail-silent) with the changed fields.
    """
    run = load_run(adw_id, working_dir=working_dir)
    if run is None:
        return None

    changed: Dict[str, Any] = {}
    if status is not None:
        if status not in VALID_STATUSES:
            raise ValueError(f"Invalid run status: {status!r}")
        run["status"] = status
        changed["status"] = status
        if status == IN_PROGRESS and not run.get("started_at"):
            run["started_at"] = _now_iso()
            changed["started_at"] = run["started_at"]
        if status in TERMINAL_STATUSES:
            run["completed_at"] = _now_iso()
            changed["completed_at"] = run["completed_at"]
            anchor = run.get("started_at") or run.get("created_at")
            if anchor:
                try:
                    delta = datetime.fromisoformat(
                        run["completed_at"]
                    ) - datetime.fromisoformat(anchor)
                    run["duration_seconds"] = round(delta.total_seconds(), 3)
                    changed["duration_seconds"] = run["duration_seconds"]
                except ValueError:
                    pass
    if current_step is not None:
        run["current_step"] = current_step
        changed["current_step"] = current_step
    if total_steps is not None:
        # Workflows correct the launcher's default (a launcher writes the
        # record before knowing each workflow's phase count).
        run["total_steps"] = total_steps
        changed["total_steps"] = total_steps
    if completed_steps is not None:
        run["completed_steps"] = completed_steps
        changed["completed_steps"] = completed_steps
    if error_message is not None:
        run["error_message"] = error_message
        changed["error_message"] = error_message
    if error_step is not None:
        run["error_step"] = error_step
        changed["error_step"] = error_step
    if output:
        run.setdefault("output_data", {}).update(output)
        changed["output_data"] = output

    save_run(run, working_dir=working_dir)
    emit_event(
        adw_id,
        "workflow",
        "run_updated",
        payload=changed,
        working_dir=working_dir,
    )
    return run


def update_merge_result(
    adw_id: str,
    merge_status: str,
    merged_sha: Optional[str] = None,
    merge_error: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """Record the ship step's merge outcome onto the run record, then persist.

    Returns the updated run dict, or None when the record can't be loaded.
    Emits a `run_updated` event (fail-silent) with the changed fields.
    """
    if merge_status not in VALID_MERGE_STATUSES:
        raise ValueError(f"Invalid merge status: {merge_status!r}")

    run = load_run(adw_id, working_dir=working_dir)
    if run is None:
        return None

    changed: Dict[str, Any] = {"merge_status": merge_status}
    run["merge_status"] = merge_status
    if merged_sha is not None:
        run["merged_sha"] = merged_sha
        changed["merged_sha"] = merged_sha
    if merge_error is not None:
        run["merge_error"] = merge_error
        changed["merge_error"] = merge_error

    save_run(run, working_dir=working_dir)
    emit_event(
        adw_id,
        "workflow",
        "run_updated",
        payload=changed,
        working_dir=working_dir,
    )
    return run


def step_start(
    adw_id: str,
    step: str,
    summary: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> None:
    """Emit the swimlane grouping marker for a step opening."""
    emit_event(
        adw_id,
        "workflow",
        "step_start",
        payload={"step": step},
        summary=summary or f"step {step} started",
        working_dir=working_dir,
    )


def step_end(
    adw_id: str,
    step: str,
    status: str,
    duration_ms: Optional[int] = None,
    summary: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> None:
    """Emit the swimlane grouping marker for a step closing."""
    emit_event(
        adw_id,
        "workflow",
        "step_end",
        payload={"step": step, "status": status, "duration_ms": duration_ms},
        summary=summary or f"step {step} {status}",
        working_dir=working_dir,
    )


def local_issue_number(adw_id: str) -> int:
    """Stable numeric local id derived from the adw_id.

    Numeric so every downstream `issue-{n}-adw-{id}` spec-filename and
    branch-glob convention keeps working without GitHub.
    """
    hex_chars = "".join(c for c in adw_id if c in "0123456789abcdefABCDEF")[:6]
    try:
        digest = int(hex_chars, 16) if hex_chars else 0
    except ValueError:
        digest = 0
    return LOCAL_ISSUE_BASE + digest % _LOCAL_ISSUE_MOD


def synthesize_issue(run: Dict[str, Any]) -> GitHubIssue:
    """Build a placeholder-complete GitHubIssue from a run record.

    Downstream ops (build_plan, generate_branch_name, create_commit) only
    serialize {number, title, body}; everything else is a valid placeholder.
    Title = first non-empty line of the prompt, sanitized and capped at 80
    chars; body = the prompt verbatim.
    """
    input_data = run.get("input_data", {})
    prompt = input_data.get("prompt") or ""

    number = input_data.get("issue_number")
    if not isinstance(number, int):
        number = local_issue_number(run["adw_id"])

    title = ""
    for line in prompt.splitlines():
        if line.strip():
            # Collapse whitespace and drop quotes/backticks that would leak
            # into shell-adjacent surfaces (branch slugs, commit subjects).
            title = re.sub(r"\s+", " ", line).strip().strip("\"'`")
            break
    if not title:
        title = f"local task {run['adw_id']}"
    if len(title) > 80:
        title = title[:77].rstrip() + "..."

    now = datetime.now(timezone.utc)
    return GitHubIssue(
        number=number,
        title=title,
        body=prompt,
        state="OPEN",
        author=GitHubUser(login="local-orchestrator"),
        createdAt=now,
        updatedAt=now,
        url="",
    )
