#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
GitHub Operations Module - AI Developer Workflow (ADW)

This module contains all GitHub-related operations including:
- Issue fetching and manipulation
- Comment posting
- Repository path extraction
- Issue status management
"""

import subprocess
import sys
import os
import json
from typing import Dict, List, Optional
from .data_types import GitHubIssue, GitHubIssueListItem, GitHubComment

# Bot identifier to prevent webhook loops and filter bot comments
ADW_BOT_IDENTIFIER = "[ADW-AGENTS]"


def is_local_issue(issue_id) -> bool:
    """True iff issue_id parses as a synthetic local issue number.

    Local runs (adw.run/1 contract, see adw_modules/local_ops.py) mint issue
    numbers >= LOCAL_ISSUE_BASE; those never exist on GitHub, so issue ops
    short-circuit instead of calling gh. Non-numeric ids return False and
    keep their legacy behavior untouched.
    """
    # Lazy import: cycle-free today (local_ops imports only data_types +
    # observability) but cheap insurance against future import cycles.
    from .local_ops import LOCAL_ISSUE_BASE

    try:
        return int(str(issue_id).lstrip("#")) >= LOCAL_ISSUE_BASE
    except (TypeError, ValueError):
        return False


def get_github_env() -> Optional[dict]:
    """Get environment with GitHub token set up. Returns None if no GITHUB_PAT.
    
    Subprocess env behavior:
    - env=None → Inherits parent's environment (default)
    - env={} → Empty environment (no variables)
    - env=custom_dict → Only uses specified variables
    
    So this will work with gh authentication:
    # These are equivalent:
    result = subprocess.run(cmd, capture_output=True, text=True)
    result = subprocess.run(cmd, capture_output=True, text=True, env=None)
    
    But this will NOT work (no PATH, no auth):
    result = subprocess.run(cmd, capture_output=True, text=True, env={})
    """
    github_pat = os.getenv("GITHUB_PAT")
    if not github_pat:
        return None
    
    # Only create minimal env with GitHub token
    env = {
        "GH_TOKEN": github_pat,
        "PATH": os.environ.get("PATH", ""),
    }
    return env


def get_repo_url() -> str:
    """Get GitHub repository URL from git remote."""
    try:
        result = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        raise ValueError(
            "No git remote 'origin' found. Please ensure you're in a git repository with a remote."
        )
    except FileNotFoundError:
        raise ValueError("git command not found. Please ensure git is installed.")


def extract_repo_path(github_url: str) -> str:
    """Extract owner/repo from GitHub URL."""
    # Handle both https://github.com/owner/repo and https://github.com/owner/repo.git
    return github_url.replace("https://github.com/", "").replace(".git", "")


def fetch_issue(issue_number: str, repo_path: str) -> GitHubIssue:
    """Fetch GitHub issue using gh CLI and return typed model.

    Synthetic local issue numbers (>= local_ops.LOCAL_ISSUE_BASE) never exist
    on GitHub: return a placeholder-complete GitHubIssue instead of calling
    gh. Dependents use the fetched issue for comments/context only (their
    plan file already exists in the worktree), so the placeholder suffices.
    """
    if is_local_issue(issue_number):
        from datetime import datetime, timezone

        from .data_types import GitHubUser

        n = int(str(issue_number).lstrip("#"))
        print(f"[local] issue fetch synthesized for #{n} (no gh call)")
        now = datetime.now(timezone.utc)
        return GitHubIssue(
            number=n,
            title=f"local task #{n}",
            body="",
            state="OPEN",
            author=GitHubUser(login="local-orchestrator"),
            createdAt=now,
            updatedAt=now,
            url="",
        )

    # Use JSON output for structured data
    cmd = [
        "gh",
        "issue",
        "view",
        issue_number,
        "-R",
        repo_path,
        "--json",
        "number,title,body,state,author,assignees,labels,milestone,comments,createdAt,updatedAt,closedAt,url",
    ]

    # Set up environment with GitHub token if available
    env = get_github_env()

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)

        if result.returncode == 0:
            # Parse JSON response into Pydantic model
            issue_data = json.loads(result.stdout)
            issue = GitHubIssue(**issue_data)

            return issue
        else:
            print(result.stderr, file=sys.stderr)
            sys.exit(result.returncode)
    except FileNotFoundError:
        print("Error: GitHub CLI (gh) is not installed.", file=sys.stderr)
        print("\nTo install gh:", file=sys.stderr)
        print("  - macOS: brew install gh", file=sys.stderr)
        print(
            "  - Linux: See https://github.com/cli/cli#installation",
            file=sys.stderr,
        )
        print(
            "  - Windows: See https://github.com/cli/cli#installation", file=sys.stderr
        )
        print("\nAfter installation, authenticate with: gh auth login", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error parsing issue data: {e}", file=sys.stderr)
        sys.exit(1)


def make_issue_comment(issue_id: str, comment: str) -> None:
    """Post a comment to a GitHub issue using gh CLI.

    Synthetic local issue numbers self-suppress: log-only, never touch gh.
    This makes every workflow's unguarded comment calls local-safe.
    """
    if is_local_issue(issue_id):
        n = str(issue_id).lstrip("#")
        print(f"[local] github op suppressed for #{n} (issue comment)")
        return

    # Get repo information from git remote
    github_repo_url = get_repo_url()
    repo_path = extract_repo_path(github_repo_url)

    # Ensure comment has ADW_BOT_IDENTIFIER to prevent webhook loops
    if not comment.startswith(ADW_BOT_IDENTIFIER):
        comment = f"{ADW_BOT_IDENTIFIER} {comment}"

    # Build command
    cmd = [
        "gh",
        "issue",
        "comment",
        issue_id,
        "-R",
        repo_path,
        "--body",
        comment,
    ]

    # Set up environment with GitHub token if available
    env = get_github_env()

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)

        if result.returncode == 0:
            print(f"Successfully posted comment to issue #{issue_id}")
        else:
            print(f"Error posting comment: {result.stderr}", file=sys.stderr)
            raise RuntimeError(f"Failed to post comment: {result.stderr}")
    except Exception as e:
        print(f"Error posting comment: {e}", file=sys.stderr)
        raise


def mark_issue_in_progress(issue_id: str) -> None:
    """Mark issue as in progress by adding label and comment.

    Synthetic local issue numbers self-suppress: log-only, never touch gh.
    """
    if is_local_issue(issue_id):
        n = str(issue_id).lstrip("#")
        print(f"[local] github op suppressed for #{n} (mark in progress)")
        return

    # Get repo information from git remote
    github_repo_url = get_repo_url()
    repo_path = extract_repo_path(github_repo_url)

    # Add "in_progress" label
    cmd = [
        "gh",
        "issue",
        "edit",
        issue_id,
        "-R",
        repo_path,
        "--add-label",
        "in_progress",
    ]

    # Set up environment with GitHub token if available
    env = get_github_env()

    # Try to add label (may fail if label doesn't exist)
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        print(f"Note: Could not add 'in_progress' label: {result.stderr}")

    # Post comment indicating work has started
    # make_issue_comment(issue_id, "🚧 ADW is working on this issue...")

    # Assign to self (optional)
    cmd = [
        "gh",
        "issue",
        "edit",
        issue_id,
        "-R",
        repo_path,
        "--add-assignee",
        "@me",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode == 0:
        print(f"Assigned issue #{issue_id} to self")


def fetch_open_issues(repo_path: str) -> List[GitHubIssueListItem]:
    """Fetch all open issues from the GitHub repository."""
    try:
        cmd = [
            "gh",
            "issue",
            "list",
            "--repo",
            repo_path,
            "--state",
            "open",
            "--json",
            "number,title,body,labels,createdAt,updatedAt",
            "--limit",
            "1000",
        ]

        # Set up environment with GitHub token if available
        env = get_github_env()

        # DEBUG level - not printing command
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, env=env
        )

        issues_data = json.loads(result.stdout)
        issues = [GitHubIssueListItem(**issue_data) for issue_data in issues_data]
        print(f"Fetched {len(issues)} open issues")
        return issues

    except subprocess.CalledProcessError as e:
        print(f"ERROR: Failed to fetch issues: {e.stderr}", file=sys.stderr)
        return []
    except json.JSONDecodeError as e:
        print(f"ERROR: Failed to parse issues JSON: {e}", file=sys.stderr)
        return []


def fetch_issue_comments(repo_path: str, issue_number: int) -> List[Dict]:
    """Fetch all comments for a specific issue."""
    try:
        cmd = [
            "gh",
            "issue",
            "view",
            str(issue_number),
            "--repo",
            repo_path,
            "--json",
            "comments",
        ]

        # Set up environment with GitHub token if available
        env = get_github_env()

        result = subprocess.run(
            cmd, capture_output=True, text=True, check=True, env=env
        )
        data = json.loads(result.stdout)
        comments = data.get("comments", [])

        # Sort comments by creation time
        comments.sort(key=lambda c: c.get("createdAt", ""))

        # DEBUG level - not printing
        return comments

    except subprocess.CalledProcessError as e:
        print(
            f"ERROR: Failed to fetch comments for issue #{issue_number}: {e.stderr}",
            file=sys.stderr,
        )
        return []
    except json.JSONDecodeError as e:
        print(
            f"ERROR: Failed to parse comments JSON for issue #{issue_number}: {e}",
            file=sys.stderr,
        )
        return []


def find_keyword_from_comment(keyword: str, issue: GitHubIssue) -> Optional[GitHubComment]:
    """Find the latest comment containing a specific keyword.
    
    Args:
        keyword: The keyword to search for in comments
        issue: The GitHub issue containing comments
        
    Returns:
        The latest GitHubComment containing the keyword, or None if not found
    """
    # Sort comments by created_at date (newest first)
    sorted_comments = sorted(issue.comments, key=lambda c: c.created_at, reverse=True)
    
    # Search through sorted comments (newest first)
    for comment in sorted_comments:
        # Skip ADW bot comments to prevent loops
        if ADW_BOT_IDENTIFIER in comment.body:
            continue
            
        if keyword in comment.body:
            return comment
    
    return None
