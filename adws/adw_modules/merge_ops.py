"""Shared trunk-aware merge operations for ADW workflows.

Generalizes the merge logic that previously lived inline in
`adw_ship_iso.py::manual_merge_to_main` (which hardcoded the literal branch
name "main"): the target branch is always detected dynamically via
`git_ops.get_trunk_branch`, and repos with no `origin` remote (fully
local/offline) are merged locally without fetch/pull/push.

Used by `adw_ship_iso.py`, `workflow_ops.run_local_workflow`'s ship step, and
the standalone GitHub `*_iso.py` composites' final ship-on-success call.
"""

import logging
import subprocess
from typing import Optional, Tuple

from adw_modules.git_ops import get_trunk_branch

# (success, merged_sha, error_message)
MergeResult = Tuple[bool, Optional[str], Optional[str]]


def has_origin_remote(cwd: Optional[str] = None) -> bool:
    """True iff the repo has an `origin` remote configured."""
    result = subprocess.run(
        ["git", "remote"], capture_output=True, text=True, cwd=cwd
    )
    return result.returncode == 0 and "origin" in result.stdout.split()


def get_head_sha(cwd: Optional[str] = None) -> Optional[str]:
    """The current HEAD commit sha, or None when it can't be resolved."""
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=cwd
    )
    if result.returncode != 0:
        return None
    sha = result.stdout.strip()
    return sha or None


def merge_branch_into_trunk(
    branch_name: str,
    cwd: Optional[str] = None,
    logger: Optional[logging.Logger] = None,
) -> MergeResult:
    """Merge `branch_name` into the repo's detected trunk branch.

    Sequence (remote-aware):
    1. Detect the trunk via `get_trunk_branch` (never a hardcoded "main").
    2. `git fetch origin` (skipped when no `origin` remote exists).
    3. Checkout the trunk; `git pull origin <trunk>` (skipped when offline).
    4. `git merge --no-ff <branch_name>`.
    5. `git push origin <trunk>` (skipped when offline).
    6. Restore the originally checked-out branch.

    Returns (success, merged_sha, error_message):
    - success: (True, "<merge commit sha>", None)
    - failure: (False, None, "<error>") with the original branch restored.
    """
    log = logger or logging.getLogger(__name__)
    original_branch: Optional[str] = None

    def restore() -> None:
        if original_branch:
            subprocess.run(
                ["git", "checkout", original_branch],
                capture_output=True,
                text=True,
                cwd=cwd,
            )

    try:
        trunk_branch = get_trunk_branch(cwd=cwd)
        remote = has_origin_remote(cwd=cwd)
        log.info(
            f"Merging {branch_name} into trunk '{trunk_branch}' "
            f"({'remote-aware' if remote else 'local-only, no origin remote'})"
        )

        # Save current branch to restore later
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            cwd=cwd,
        )
        original_branch = result.stdout.strip() or None
        log.debug(f"Original branch: {original_branch}")

        # Step 1: Fetch latest from origin (remote repos only)
        if remote:
            log.info("Fetching latest from origin...")
            result = subprocess.run(
                ["git", "fetch", "origin"], capture_output=True, text=True, cwd=cwd
            )
            if result.returncode != 0:
                return False, None, f"Failed to fetch from origin: {result.stderr}"

        # Step 2: Checkout the trunk
        log.info(f"Checking out trunk branch '{trunk_branch}'...")
        result = subprocess.run(
            ["git", "checkout", trunk_branch],
            capture_output=True,
            text=True,
            cwd=cwd,
        )
        if result.returncode != 0:
            return False, None, f"Failed to checkout {trunk_branch}: {result.stderr}"

        # Step 3: Pull latest trunk (remote repos only)
        if remote:
            log.info(f"Pulling latest {trunk_branch}...")
            result = subprocess.run(
                ["git", "pull", "origin", trunk_branch],
                capture_output=True,
                text=True,
                cwd=cwd,
            )
            if result.returncode != 0:
                restore()
                return (
                    False,
                    None,
                    f"Failed to pull latest {trunk_branch}: {result.stderr}",
                )

        # Step 4: Merge the feature branch (no-ff to preserve all commits)
        log.info(f"Merging branch {branch_name} (no-ff to preserve all commits)...")
        result = subprocess.run(
            [
                "git",
                "merge",
                branch_name,
                "--no-ff",
                "-m",
                f"Merge branch '{branch_name}' via ADW ship workflow",
            ],
            capture_output=True,
            text=True,
            cwd=cwd,
        )
        if result.returncode != 0:
            # Abort a half-applied merge (conflicts) before restoring
            subprocess.run(
                ["git", "merge", "--abort"], capture_output=True, text=True, cwd=cwd
            )
            restore()
            return False, None, f"Failed to merge {branch_name}: {result.stderr}"

        merged_sha = get_head_sha(cwd=cwd)

        # Step 5: Push to origin/<trunk> (remote repos only)
        if remote:
            log.info(f"Pushing to origin/{trunk_branch}...")
            result = subprocess.run(
                ["git", "push", "origin", trunk_branch],
                capture_output=True,
                text=True,
                cwd=cwd,
            )
            if result.returncode != 0:
                restore()
                return (
                    False,
                    None,
                    f"Failed to push to origin/{trunk_branch}: {result.stderr}",
                )

        # Step 6: Restore original branch
        log.info(f"Restoring original branch: {original_branch}")
        restore()

        log.info(f"Successfully merged {branch_name} into {trunk_branch}!")
        return True, merged_sha, None

    except Exception as e:
        log.error(f"Unexpected error during merge: {e}")
        restore()
        return False, None, str(e)
