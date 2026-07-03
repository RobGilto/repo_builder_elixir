"""Git operations for ADW composable architecture.

Provides centralized git operations that build on top of github.py module.
"""

import subprocess
import json
import logging
from typing import Optional, Tuple

# Import GitHub functions from existing module
from adw_modules.github import get_repo_url, extract_repo_path, make_issue_comment


def get_trunk_branch(cwd: Optional[str] = None) -> str:
    """Detect the repository's trunk branch dynamically.

    Fallback precedence:
    1. `git symbolic-ref refs/remotes/origin/HEAD` (strip refs/remotes/origin/)
    2. `git remote show origin` — the "HEAD branch:" line
    3. `git branch --show-current` (no usable origin remote — offline/local repos)
    4. "main" — deliberate degrade-to-historical-default, never a silent failure
       (this literal is the only allowed hardcoded branch-name fallback).
    """
    # 1. symbolic-ref: cheap, offline, present when origin/HEAD is set locally
    result = subprocess.run(
        ["git", "symbolic-ref", "refs/remotes/origin/HEAD"],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    if result.returncode == 0:
        ref = result.stdout.strip()
        prefix = "refs/remotes/origin/"
        if ref.startswith(prefix) and ref[len(prefix):]:
            return ref[len(prefix):]

    # 2. remote show origin: queries the remote for its HEAD branch
    result = subprocess.run(
        ["git", "remote", "show", "origin"],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("HEAD branch:"):
                branch = line.split(":", 1)[1].strip()
                if branch and branch != "(unknown)":
                    return branch

    # 3. no usable origin remote: the currently checked-out branch
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()

    # 4. last resort: historical default
    return "main"


def get_current_branch(cwd: Optional[str] = None) -> str:
    """Get current git branch name."""
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    return result.stdout.strip()


def push_branch(
    branch_name: str, cwd: Optional[str] = None
) -> Tuple[bool, Optional[str]]:
    """Push current branch to remote. Returns (success, error_message)."""
    result = subprocess.run(
        ["git", "push", "-u", "origin", branch_name],
        capture_output=True,
        text=True,
        cwd=cwd,
    )
    if result.returncode != 0:
        return False, result.stderr
    return True, None


def check_pr_exists(branch_name: str) -> Optional[str]:
    """Check if PR exists for branch. Returns PR URL if exists."""
    # Use github.py functions to get repo info
    try:
        repo_url = get_repo_url()
        repo_path = extract_repo_path(repo_url)
    except Exception as e:
        return None

    result = subprocess.run(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            repo_path,
            "--head",
            branch_name,
            "--json",
            "url",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        prs = json.loads(result.stdout)
        if prs:
            return prs[0]["url"]
    return None


def create_branch(
    branch_name: str, cwd: Optional[str] = None
) -> Tuple[bool, Optional[str]]:
    """Create and checkout a new branch. Returns (success, error_message)."""
    # Create branch
    result = subprocess.run(
        ["git", "checkout", "-b", branch_name], capture_output=True, text=True, cwd=cwd
    )
    if result.returncode != 0:
        # Check if error is because branch already exists
        if "already exists" in result.stderr:
            # Try to checkout existing branch
            result = subprocess.run(
                ["git", "checkout", branch_name],
                capture_output=True,
                text=True,
                cwd=cwd,
            )
            if result.returncode != 0:
                return False, result.stderr
            return True, None
        return False, result.stderr
    return True, None


def commit_changes(
    message: str, cwd: Optional[str] = None
) -> Tuple[bool, Optional[str]]:
    """Stage all changes and commit. Returns (success, error_message)."""
    # Check if there are changes to commit
    result = subprocess.run(
        ["git", "status", "--porcelain"], capture_output=True, text=True, cwd=cwd
    )
    if not result.stdout.strip():
        return True, None  # No changes to commit

    # Stage all changes
    result = subprocess.run(
        ["git", "add", "-A"], capture_output=True, text=True, cwd=cwd
    )
    if result.returncode != 0:
        return False, result.stderr

    # Commit
    result = subprocess.run(
        ["git", "commit", "-m", message], capture_output=True, text=True, cwd=cwd
    )
    if result.returncode != 0:
        return False, result.stderr
    return True, None


def get_pr_number(branch_name: str) -> Optional[str]:
    """Get PR number for a branch. Returns PR number if exists."""
    # Use github.py functions to get repo info
    try:
        repo_url = get_repo_url()
        repo_path = extract_repo_path(repo_url)
    except Exception as e:
        return None

    result = subprocess.run(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            repo_path,
            "--head",
            branch_name,
            "--json",
            "number",
            "--limit",
            "1",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        prs = json.loads(result.stdout)
        if prs:
            return str(prs[0]["number"])
    return None


def approve_pr(pr_number: str, logger: logging.Logger) -> Tuple[bool, Optional[str]]:
    """Approve a PR. Returns (success, error_message)."""
    try:
        repo_url = get_repo_url()
        repo_path = extract_repo_path(repo_url)
    except Exception as e:
        return False, f"Failed to get repo info: {e}"

    result = subprocess.run(
        [
            "gh",
            "pr",
            "review",
            pr_number,
            "--repo",
            repo_path,
            "--approve",
            "--body",
            "ADW Ship workflow approved this PR after validating all state fields.",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False, result.stderr

    logger.info(f"Approved PR #{pr_number}")
    return True, None


def merge_pr(
    pr_number: str, logger: logging.Logger, merge_method: str = "squash"
) -> Tuple[bool, Optional[str]]:
    """Merge a PR. Returns (success, error_message).

    Args:
        pr_number: The PR number to merge
        logger: Logger instance
        merge_method: One of 'merge', 'squash', 'rebase' (default: 'squash')
    """
    try:
        repo_url = get_repo_url()
        repo_path = extract_repo_path(repo_url)
    except Exception as e:
        return False, f"Failed to get repo info: {e}"

    # First check if PR is mergeable
    result = subprocess.run(
        [
            "gh",
            "pr",
            "view",
            pr_number,
            "--repo",
            repo_path,
            "--json",
            "mergeable,mergeStateStatus",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False, f"Failed to check PR status: {result.stderr}"

    pr_status = json.loads(result.stdout)
    if pr_status.get("mergeable") != "MERGEABLE":
        return (
            False,
            f"PR is not mergeable. Status: {pr_status.get('mergeStateStatus', 'unknown')}",
        )

    # Merge the PR
    merge_cmd = [
        "gh",
        "pr",
        "merge",
        pr_number,
        "--repo",
        repo_path,
        f"--{merge_method}",
    ]

    # Add auto-merge body
    merge_cmd.extend(
        ["--body", "Merged by ADW Ship workflow after successful validation."]
    )

    result = subprocess.run(merge_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return False, result.stderr

    logger.info(f"Merged PR #{pr_number} using {merge_method} method")
    return True, None


def finalize_git_operations(
    state: "ADWState", logger: logging.Logger, cwd: Optional[str] = None
) -> None:
    """Standard git finalization: push branch and create/update PR."""
    branch_name = state.get("branch_name")
    if not branch_name:
        # Fallback: use current git branch if it is not the trunk
        current_branch = get_current_branch(cwd=cwd)
        trunk_branch = get_trunk_branch(cwd=cwd)
        if current_branch and current_branch != trunk_branch:
            logger.warning(
                f"No branch name in state, using current branch: {current_branch}"
            )
            branch_name = current_branch
        else:
            logger.error(
                f"No branch name in state and current branch is the trunk "
                f"({trunk_branch}), skipping git operations"
            )
            return

    # Always push
    success, error = push_branch(branch_name, cwd=cwd)
    if not success:
        logger.error(f"Failed to push branch: {error}")
        return

    logger.info(f"Pushed branch: {branch_name}")

    # Handle PR
    pr_url = check_pr_exists(branch_name)
    issue_number = state.get("issue_number")
    adw_id = state.get("adw_id")

    if pr_url:
        logger.info(f"Found existing PR: {pr_url}")
        # Post PR link for easy reference
        if issue_number and adw_id:
            make_issue_comment(issue_number, f"{adw_id}_ops: ✅ Pull request: {pr_url}")
    else:
        # Create new PR - fetch issue data first
        if issue_number:
            try:
                repo_url = get_repo_url()
                repo_path = extract_repo_path(repo_url)
                from adw_modules.github import fetch_issue

                issue = fetch_issue(issue_number, repo_path)

                from adw_modules.workflow_ops import create_pull_request

                pr_url, error = create_pull_request(branch_name, issue, state, logger, cwd)
            except Exception as e:
                logger.error(f"Failed to fetch issue for PR creation: {e}")
                pr_url, error = None, str(e)
        else:
            pr_url, error = None, "No issue number in state"

        if pr_url:
            logger.info(f"Created PR: {pr_url}")
            # Post new PR link
            if issue_number and adw_id:
                make_issue_comment(
                    issue_number, f"{adw_id}_ops: ✅ Pull request created: {pr_url}"
                )
        else:
            logger.error(f"Failed to create PR: {error}")
