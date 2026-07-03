"""Shared AI Developer Workflow (ADW) operations."""

import glob
import json
import logging
import os
import subprocess
import re
from typing import Tuple, Optional
from adw_modules.data_types import (
    AgentTemplateRequest,
    GitHubIssue,
    AgentPromptResponse,
    IssueClassSlashCommand,
    ADWExtractionResult,
)
from adw_modules.agent import execute_template
from adw_modules.github import get_repo_url, extract_repo_path, ADW_BOT_IDENTIFIER
from adw_modules.state import ADWState
from adw_modules.utils import parse_json


# Agent name constants
AGENT_PLANNER = "sdlc_planner"
AGENT_IMPLEMENTOR = "sdlc_implementor"
AGENT_CLASSIFIER = "issue_classifier"
AGENT_BRANCH_GENERATOR = "branch_generator"
AGENT_PR_CREATOR = "pr_creator"

# Available ADW workflows for runtime validation
AVAILABLE_ADW_WORKFLOWS = [
    # Isolated workflows (all workflows are now iso-based)
    "adw_plan_iso",
    "adw_patch_iso",
    "adw_build_iso",
    "adw_test_iso",
    "adw_review_iso",
    "adw_document_iso",
    "adw_ship_iso",
    "adw_sdlc_ZTE_iso",  # Zero Touch Execution workflow
    "adw_plan_build_iso",
    "adw_plan_build_local_iso",  # GitHub-optional: context from agents/<id>/run.json
    "adw_plan_local_iso",  # GitHub-optional: plan only
    "adw_patch_local_iso",  # GitHub-optional: patch (prompt IS the patch spec)
    "adw_plan_build_review_local_iso",  # GitHub-optional: plan + build + review
    "adw_plan_build_test_local_iso",  # GitHub-optional: plan + build + test
    "adw_plan_build_test_review_local_iso",  # GitHub-optional: plan + build + test + review
    "adw_plan_build_document_local_iso",  # GitHub-optional: plan + build + document
    "adw_sdlc_local_iso",  # GitHub-optional: full SDLC
    "adw_plan_build_test_iso",
    "adw_plan_build_test_review_iso",
    "adw_plan_build_document_iso",
    "adw_plan_build_review_iso",
    "adw_sdlc_iso",
]


def format_issue_message(
    adw_id: str, agent_name: str, message: str, session_id: Optional[str] = None
) -> str:
    """Format a message for issue comments with ADW tracking and bot identifier."""
    # Always include ADW_BOT_IDENTIFIER to prevent webhook loops
    if session_id:
        return f"{ADW_BOT_IDENTIFIER} {adw_id}_{agent_name}_{session_id}: {message}"
    return f"{ADW_BOT_IDENTIFIER} {adw_id}_{agent_name}: {message}"


def extract_adw_info(text: str, temp_adw_id: str) -> ADWExtractionResult:
    """Extract ADW workflow, ID, and model_set from text using classify_adw agent.
    Returns ADWExtractionResult with workflow_command, adw_id, and model_set."""

    # Use classify_adw to extract structured info
    request = AgentTemplateRequest(
        agent_name="adw_classifier",
        slash_command="/classify_adw",
        args=[text],
        adw_id=temp_adw_id,
    )

    try:
        response = execute_template(request)  # No logger available in this function

        if not response.success:
            print(f"Failed to classify ADW: {response.output}")
            return ADWExtractionResult()  # Empty result

        # Parse JSON response using utility that handles markdown
        try:
            data = parse_json(response.output, dict)
            adw_command = data.get("adw_slash_command", "").replace(
                "/", ""
            )  # Remove slash
            adw_id = data.get("adw_id")
            model_set = data.get("model_set", "base")  # Default to "base"

            # Validate command
            if adw_command and adw_command in AVAILABLE_ADW_WORKFLOWS:
                return ADWExtractionResult(
                    workflow_command=adw_command,
                    adw_id=adw_id,
                    model_set=model_set
                )

            return ADWExtractionResult()  # Empty result

        except ValueError as e:
            print(f"Failed to parse classify_adw response: {e}")
            return ADWExtractionResult()  # Empty result

    except Exception as e:
        print(f"Error calling classify_adw: {e}")
        return ADWExtractionResult()  # Empty result


def classify_issue(
    issue: GitHubIssue, adw_id: str, logger: logging.Logger
) -> Tuple[Optional[IssueClassSlashCommand], Optional[str]]:
    """Classify GitHub issue and return appropriate slash command.
    Returns (command, error_message) tuple."""

    # Use the classify_issue slash command template with minimal payload
    # Only include the essential fields: number, title, body
    minimal_issue_json = issue.model_dump_json(
        by_alias=True, include={"number", "title", "body"}
    )

    request = AgentTemplateRequest(
        agent_name=AGENT_CLASSIFIER,
        slash_command="/classify_issue",
        args=[minimal_issue_json],
        adw_id=adw_id,
    )

    logger.debug(f"Classifying issue: {issue.title}")

    response = execute_template(request)

    logger.debug(
        f"Classification response: {response.model_dump_json(indent=2, by_alias=True)}"
    )

    if not response.success:
        return None, response.output

    # Extract the classification from the response
    output = response.output.strip()

    # Look for the classification pattern in the output
    # Claude might add explanation, so we need to extract just the command
    classification_match = re.search(r"(/chore|/bug|/feature|0)", output)

    if classification_match:
        issue_command = classification_match.group(1)
    else:
        issue_command = output

    if issue_command == "0":
        return None, f"No command selected: {response.output}"

    if issue_command not in ["/chore", "/bug", "/feature"]:
        return None, f"Invalid command selected: {response.output}"

    return issue_command, None  # type: ignore


def build_plan(
    issue: GitHubIssue,
    command: str,
    adw_id: str,
    logger: logging.Logger,
    working_dir: Optional[str] = None,
) -> AgentPromptResponse:
    """Build implementation plan for the issue using the specified command."""
    # Use minimal payload like classify_issue does
    minimal_issue_json = issue.model_dump_json(
        by_alias=True, include={"number", "title", "body"}
    )

    issue_plan_template_request = AgentTemplateRequest(
        agent_name=AGENT_PLANNER,
        slash_command=command,
        args=[str(issue.number), adw_id, minimal_issue_json],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"issue_plan_template_request: {issue_plan_template_request.model_dump_json(indent=2, by_alias=True)}"
    )

    issue_plan_response = execute_template(issue_plan_template_request)

    logger.debug(
        f"issue_plan_response: {issue_plan_response.model_dump_json(indent=2, by_alias=True)}"
    )

    return issue_plan_response


def implement_plan(
    plan_file: str,
    adw_id: str,
    logger: logging.Logger,
    agent_name: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> AgentPromptResponse:
    """Implement the plan using the /implement command."""
    # Use provided agent_name or default to AGENT_IMPLEMENTOR
    implementor_name = agent_name or AGENT_IMPLEMENTOR

    implement_template_request = AgentTemplateRequest(
        agent_name=implementor_name,
        slash_command="/implement",
        args=[plan_file],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"implement_template_request: {implement_template_request.model_dump_json(indent=2, by_alias=True)}"
    )

    implement_response = execute_template(implement_template_request)

    logger.debug(
        f"implement_response: {implement_response.model_dump_json(indent=2, by_alias=True)}"
    )

    return implement_response


def generate_branch_name(
    issue: GitHubIssue,
    issue_class: IssueClassSlashCommand,
    adw_id: str,
    logger: logging.Logger,
) -> Tuple[Optional[str], Optional[str]]:
    """Generate a git branch name for the issue.
    Returns (branch_name, error_message) tuple."""
    # Remove the leading slash from issue_class for the branch name
    issue_type = issue_class.replace("/", "")

    # Use minimal payload like classify_issue does
    minimal_issue_json = issue.model_dump_json(
        by_alias=True, include={"number", "title", "body"}
    )

    request = AgentTemplateRequest(
        agent_name=AGENT_BRANCH_GENERATOR,
        slash_command="/generate_branch_name",
        args=[issue_type, adw_id, minimal_issue_json],
        adw_id=adw_id,
    )

    response = execute_template(request)

    if not response.success:
        return None, response.output

    branch_name = response.output.strip().strip("`")
    logger.info(f"Generated branch name: {branch_name}")
    return branch_name, None


def create_commit(
    agent_name: str,
    issue: GitHubIssue,
    issue_class: IssueClassSlashCommand,
    adw_id: str,
    logger: logging.Logger,
    working_dir: str,
) -> Tuple[Optional[str], Optional[str]]:
    """Create a git commit with a properly formatted message.
    Returns (commit_message, error_message) tuple."""
    # Remove the leading slash from issue_class
    issue_type = issue_class.replace("/", "")

    # Create unique committer agent name by suffixing '_committer'
    unique_agent_name = f"{agent_name}_committer"

    # Use minimal payload like classify_issue does
    minimal_issue_json = issue.model_dump_json(
        by_alias=True, include={"number", "title", "body"}
    )

    request = AgentTemplateRequest(
        agent_name=unique_agent_name,
        slash_command="/commit",
        args=[agent_name, issue_type, minimal_issue_json],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    response = execute_template(request)

    if not response.success:
        return None, response.output

    commit_message = response.output.strip()
    logger.info(f"Created commit message: {commit_message}")
    return commit_message, None


def create_pull_request(
    branch_name: str,
    issue: Optional[GitHubIssue],
    state: ADWState,
    logger: logging.Logger,
    working_dir: str,
) -> Tuple[Optional[str], Optional[str]]:
    """Create a pull request for the implemented changes.
    Returns (pr_url, error_message) tuple."""

    # Get plan file from state (may be None for test runs)
    plan_file = state.get("plan_file") or "No plan file (test run)"
    adw_id = state.get("adw_id")

    # If we don't have issue data, try to construct minimal data
    if not issue:
        issue_data = state.get("issue", {})
        issue_json = json.dumps(issue_data) if issue_data else "{}"
    elif isinstance(issue, dict):
        # Try to reconstruct as GitHubIssue model which handles datetime serialization
        from adw_modules.data_types import GitHubIssue

        try:
            issue_model = GitHubIssue(**issue)
            # Use minimal payload like classify_issue does
            issue_json = issue_model.model_dump_json(
                by_alias=True, include={"number", "title", "body"}
            )
        except Exception:
            # Fallback: use json.dumps with default str converter for datetime
            issue_json = json.dumps(issue, default=str)
    else:
        # Use minimal payload like classify_issue does
        issue_json = issue.model_dump_json(
            by_alias=True, include={"number", "title", "body"}
        )

    request = AgentTemplateRequest(
        agent_name=AGENT_PR_CREATOR,
        slash_command="/pull_request",
        args=[branch_name, issue_json, plan_file, adw_id],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    response = execute_template(request)

    if not response.success:
        return None, response.output

    pr_url = response.output.strip()
    logger.info(f"Created pull request: {pr_url}")
    return pr_url, None


def ensure_plan_exists(state: ADWState, issue_number: str) -> str:
    """Find or error if no plan exists for issue.
    Used by isolated build workflows in standalone mode."""
    # Check if plan file is in state
    if state.get("plan_file"):
        return state.get("plan_file")

    # Check current branch
    from adw_modules.git_ops import get_current_branch

    branch = get_current_branch()

    # Look for plan in branch name
    if f"-{issue_number}-" in branch:
        # Look for plan file
        plans = glob.glob(f"specs/*{issue_number}*.md")
        if plans:
            return plans[0]

    # No plan found
    raise ValueError(
        f"No plan found for issue {issue_number}. Run adw_plan_iso.py first."
    )


def ensure_adw_id(
    issue_number: str,
    adw_id: Optional[str] = None,
    logger: Optional[logging.Logger] = None,
) -> str:
    """Get ADW ID or create a new one and initialize state.

    Args:
        issue_number: The issue number to find/create ADW ID for
        adw_id: Optional existing ADW ID to use
        logger: Optional logger instance

    Returns:
        The ADW ID (existing or newly created)
    """
    # If ADW ID provided, check if state exists
    if adw_id:
        state = ADWState.load(adw_id, logger)
        if state:
            if logger:
                logger.info(f"Found existing ADW state for ID: {adw_id}")
            else:
                print(f"Found existing ADW state for ID: {adw_id}")
            return adw_id
        # ADW ID provided but no state exists, create state
        state = ADWState(adw_id)
        state.update(adw_id=adw_id, issue_number=issue_number)
        state.save("ensure_adw_id")
        if logger:
            logger.info(f"Created new ADW state for provided ID: {adw_id}")
        else:
            print(f"Created new ADW state for provided ID: {adw_id}")
        return adw_id

    # No ADW ID provided, create new one with state
    from adw_modules.utils import make_adw_id

    new_adw_id = make_adw_id()
    state = ADWState(new_adw_id)
    state.update(adw_id=new_adw_id, issue_number=issue_number)
    state.save("ensure_adw_id")
    if logger:
        logger.info(f"Created new ADW ID and state: {new_adw_id}")
    else:
        print(f"Created new ADW ID and state: {new_adw_id}")
    return new_adw_id


def find_existing_branch_for_issue(
    issue_number: str, adw_id: Optional[str] = None, cwd: Optional[str] = None
) -> Optional[str]:
    """Find an existing branch for the given issue number.
    Returns branch name if found, None otherwise."""
    # List all branches
    result = subprocess.run(
        ["git", "branch", "-a"], capture_output=True, text=True, cwd=cwd
    )

    if result.returncode != 0:
        return None

    branches = result.stdout.strip().split("\n")

    # Look for branch with standardized pattern: *-issue-{issue_number}-adw-{adw_id}-*
    for branch in branches:
        branch = branch.strip().replace("* ", "").replace("remotes/origin/", "")
        # Check for the standardized pattern
        if f"-issue-{issue_number}-" in branch:
            if adw_id and f"-adw-{adw_id}-" in branch:
                return branch
            elif not adw_id:
                # Return first match if no adw_id specified
                return branch

    return None


def find_plan_for_issue(
    issue_number: str, adw_id: Optional[str] = None
) -> Optional[str]:
    """Find plan file for the given issue number and optional adw_id.
    Returns path to plan file if found, None otherwise."""
    import os

    # Get project root
    project_root = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    agents_dir = os.path.join(project_root, "agents")

    if not os.path.exists(agents_dir):
        return None

    # If adw_id is provided, check specific directory first
    if adw_id:
        plan_path = os.path.join(agents_dir, adw_id, AGENT_PLANNER, "plan.md")
        if os.path.exists(plan_path):
            return plan_path

    # Otherwise, search all agent directories
    for agent_id in os.listdir(agents_dir):
        agent_path = os.path.join(agents_dir, agent_id)
        if os.path.isdir(agent_path):
            plan_path = os.path.join(agent_path, AGENT_PLANNER, "plan.md")
            if os.path.exists(plan_path):
                # Check if this plan is for our issue by reading branch info or checking commits
                # For now, return the first plan found (can be improved)
                return plan_path

    return None


def create_or_find_branch(
    issue_number: str,
    issue: GitHubIssue,
    state: ADWState,
    logger: logging.Logger,
    cwd: Optional[str] = None,
) -> Tuple[str, Optional[str]]:
    """Create or find a branch for the given issue.

    1. First checks state for existing branch name
    2. Then looks for existing branches matching the issue
    3. If none found, classifies the issue and creates a new branch

    Returns (branch_name, error_message) tuple.
    """
    # 1. Check state for branch name
    branch_name = state.get("branch_name") or state.get("branch", {}).get("name")
    if branch_name:
        logger.info(f"Found branch in state: {branch_name}")
        # Check if we need to checkout
        from adw_modules.git_ops import get_current_branch

        current = get_current_branch(cwd=cwd)
        if current != branch_name:
            result = subprocess.run(
                ["git", "checkout", branch_name],
                capture_output=True,
                text=True,
                cwd=cwd,
            )
            if result.returncode != 0:
                # Branch might not exist locally, try to create from remote
                result = subprocess.run(
                    ["git", "checkout", "-b", branch_name, f"origin/{branch_name}"],
                    capture_output=True,
                    text=True,
                    cwd=cwd,
                )
                if result.returncode != 0:
                    return "", f"Failed to checkout branch: {result.stderr}"
        return branch_name, None

    # 2. Look for existing branch
    adw_id = state.get("adw_id")
    existing_branch = find_existing_branch_for_issue(issue_number, adw_id, cwd=cwd)
    if existing_branch:
        logger.info(f"Found existing branch: {existing_branch}")
        # Checkout the branch
        result = subprocess.run(
            ["git", "checkout", existing_branch],
            capture_output=True,
            text=True,
            cwd=cwd,
        )
        if result.returncode != 0:
            return "", f"Failed to checkout branch: {result.stderr}"
        state.update(branch_name=existing_branch)
        return existing_branch, None

    # 3. Create new branch - classify issue first
    logger.info("No existing branch found, creating new one")

    # Classify the issue
    issue_command, error = classify_issue(issue, adw_id, logger)
    if error:
        return "", f"Failed to classify issue: {error}"

    state.update(issue_class=issue_command)

    # Generate branch name
    branch_name, error = generate_branch_name(issue, issue_command, adw_id, logger)
    if error:
        return "", f"Failed to generate branch name: {error}"

    # Create the branch
    from adw_modules.git_ops import create_branch

    success, error = create_branch(branch_name, cwd=cwd)
    if not success:
        return "", f"Failed to create branch: {error}"

    state.update(branch_name=branch_name)
    logger.info(f"Created and checked out new branch: {branch_name}")

    return branch_name, None


def find_spec_file(state: ADWState, logger: logging.Logger) -> Optional[str]:
    """Find the spec file from state or by examining git diff.

    For isolated workflows, automatically uses worktree_path from state.
    """
    # Get worktree path if in isolated workflow
    worktree_path = state.get("worktree_path")

    # Check if spec file is already in state (from plan phase)
    spec_file = state.get("plan_file")
    if spec_file:
        # If worktree_path exists and spec_file is relative, make it absolute
        if worktree_path and not os.path.isabs(spec_file):
            spec_file = os.path.join(worktree_path, spec_file)

        if os.path.exists(spec_file):
            logger.info(f"Using spec file from state: {spec_file}")
            return spec_file

    # Otherwise, try to find it from git diff (against the detected trunk)
    logger.info("Looking for spec file in git diff")
    from adw_modules.git_ops import get_trunk_branch

    trunk = get_trunk_branch(cwd=worktree_path)
    result = subprocess.run(
        ["git", "diff", f"origin/{trunk}", "--name-only"],
        capture_output=True,
        text=True,
        cwd=worktree_path,
    )

    if result.returncode == 0:
        files = result.stdout.strip().split("\n")
        spec_files = [f for f in files if f.startswith("specs/") and f.endswith(".md")]

        if spec_files:
            # Use the first spec file found
            spec_file = spec_files[0]
            if worktree_path:
                spec_file = os.path.join(worktree_path, spec_file)
            logger.info(f"Found spec file: {spec_file}")
            return spec_file

    # If still not found, try to derive from branch name
    branch_name = state.get("branch_name")
    if branch_name:
        # Extract issue number from branch name
        import re

        match = re.search(r"issue-(\d+)", branch_name)
        if match:
            issue_num = match.group(1)
            adw_id = state.get("adw_id")

            # Look for spec files matching the pattern
            import glob

            # Use worktree_path if provided, otherwise current directory
            search_dir = worktree_path if worktree_path else os.getcwd()
            pattern = os.path.join(
                search_dir, f"specs/issue-{issue_num}-adw-{adw_id}*.md"
            )
            spec_files = glob.glob(pattern)

            if spec_files:
                spec_file = spec_files[0]
                logger.info(f"Found spec file by pattern: {spec_file}")
                return spec_file

    logger.warning("No spec file found")
    return None


def create_and_implement_patch(
    adw_id: str,
    review_change_request: str,
    logger: logging.Logger,
    agent_name_planner: str,
    agent_name_implementor: str,
    spec_path: Optional[str] = None,
    issue_screenshots: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> Tuple[Optional[str], AgentPromptResponse]:
    """Create a patch plan and implement it.
    Returns (patch_file_path, implement_response) tuple."""

    # Create patch plan using /patch command
    args = [adw_id, review_change_request]

    # Add optional arguments in the correct order
    if spec_path:
        args.append(spec_path)
    else:
        args.append("")  # Empty string for optional spec_path

    args.append(agent_name_planner)

    if issue_screenshots:
        args.append(issue_screenshots)

    request = AgentTemplateRequest(
        agent_name=agent_name_planner,
        slash_command="/patch",
        args=args,
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"Patch plan request: {request.model_dump_json(indent=2, by_alias=True)}"
    )

    response = execute_template(request)

    logger.debug(
        f"Patch plan response: {response.model_dump_json(indent=2, by_alias=True)}"
    )

    if not response.success:
        logger.error(f"Error creating patch plan: {response.output}")
        # Return None and a failed response
        return None, AgentPromptResponse(
            output=f"Failed to create patch plan: {response.output}", success=False
        )

    # Extract the patch plan file path from the response
    patch_file_path = response.output.strip()

    # Validate that it looks like a file path
    if "specs/patch/" not in patch_file_path or not patch_file_path.endswith(".md"):
        logger.error(f"Invalid patch plan path returned: {patch_file_path}")
        return None, AgentPromptResponse(
            output=f"Invalid patch plan path: {patch_file_path}", success=False
        )

    logger.info(f"Created patch plan: {patch_file_path}")

    # Now implement the patch plan using the provided implementor agent name
    implement_response = implement_plan(
        patch_file_path, adw_id, logger, agent_name_implementor, working_dir=working_dir
    )

    return patch_file_path, implement_response


# ---------------------------------------------------------------------------
# Generalized local-workflow runner (RepoBuilder.Adw.Scaffold `_local_iso` twin)
# ---------------------------------------------------------------------------
#
# Every generated `_local_iso` combo (see RepoBuilder.Adw.Scaffold) is a thin
# monolith that reads a single `<adw-id>` from argv and delegates the actual
# step-threading here. This helper generalizes the body of
# `adws/adw_plan_build_local_iso.py` to an ARBITRARY, ordered step list so those
# generated scripts run correctly against the single-`<adw-id>` + `run.json`
# local launch contract (one worktree, prompt from the run record, no chaining
# of positional issue numbers). Behavior for the plan+build recipe is unchanged.

LOCAL_ISSUE_CLASS = "/feature"  # prompt-driven local runs always plan through /feature


def _local_narrate(adw_id: str, message: str, agent_name: str = "ops") -> None:
    """Workflow narration to the event stream (the issue-comment twin)."""
    from adw_modules.observability import emit_event

    emit_event(
        adw_id,
        "workflow",
        "progress",
        payload={"message": message},
        agent_name=agent_name,
        summary=message,
    )


def _local_fail(adw_id: str, step: Optional[str], message: str, logger) -> None:
    """Record failure on the run + events, then exit 1."""
    from adw_modules import local_ops

    if logger:
        logger.error(message)
    _local_narrate(adw_id, f"❌ {message}")
    local_ops.update_run(
        adw_id, status=local_ops.FAILED, error_message=message, error_step=step
    )
    import sys

    sys.exit(1)


def _local_branch_name(issue: GitHubIssue, adw_id: str) -> str:
    """Deterministic branch name in the canonical structure — no agent call."""
    slug = "".join(c if c.isalnum() else "-" for c in issue.title.lower()).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return f"feature-issue-{issue.number}-adw-{adw_id}-{slug[:40].rstrip('-')}"


def _local_find_spec_fallback(
    worktree_path: str, issue_number: int, adw_id: str
) -> Optional[str]:
    """Newest specs/issue-{n}-adw-{id}*.md by mtime (Output Contract fallback)."""
    pattern = os.path.join(
        worktree_path, "specs", f"issue-{issue_number}-adw-{adw_id}*.md"
    )
    candidates = glob.glob(pattern)
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def _local_setup_worktree(adw_id, issue, state, logger):
    """Create (or reuse) the worktree + ports + branch ONCE. Returns
    (worktree_path, branch_name, backend_port, frontend_port)."""
    from adw_modules.worktree_ops import (
        create_worktree,
        find_next_available_ports,
        get_ports_for_adw,
        is_port_available,
        setup_worktree_environment,
        validate_worktree,
    )

    valid, _ = validate_worktree(adw_id, state)
    if valid:
        return (
            state.get("worktree_path"),
            state.get("branch_name"),
            state.get("backend_port"),
            state.get("frontend_port"),
        )

    backend_port, frontend_port = get_ports_for_adw(adw_id)
    if not (is_port_available(backend_port) and is_port_available(frontend_port)):
        backend_port, frontend_port = find_next_available_ports(adw_id)
    state.update(backend_port=backend_port, frontend_port=frontend_port)

    branch_name = _local_branch_name(issue, adw_id)
    state.update(branch_name=branch_name)
    state.save(state.get("adw_id") or adw_id)

    worktree_path, error = create_worktree(adw_id, branch_name, logger)
    if error:
        _local_fail(adw_id, "plan", f"Error creating worktree: {error}", logger)

    state.update(worktree_path=worktree_path)
    state.save(state.get("adw_id") or adw_id)
    setup_worktree_environment(worktree_path, backend_port, frontend_port, logger)
    return worktree_path, branch_name, backend_port, frontend_port


def run_local_workflow(adw_id: str, steps: list, logger) -> None:
    """Run an ordered `steps` list against the single-`<adw-id>` + run.json local
    contract, in ONE isolated worktree, narrating progress via emit_event.

    Generalized from `adw_plan_build_local_iso.py`: it loads + validates the run
    record, synthesizes a local issue, sets up the worktree/branch/ports once,
    then iterates the steps running the correct inline op per step:

        plan     -> build_plan (/feature)      test     -> run_tests (/test)
        build    -> implement_plan (/implement) review   -> run_review (/review)
        patch    -> create_and_implement_patch  document -> generate_documentation
        ship     -> commit + merge into the detected trunk (merge_ops)

    The worktree is committed once after the implementing steps (mirroring the
    shipped plan+build composite). Faithful to the existing local composites so
    already-shipping recipes behave identically.
    """
    import time
    from adw_modules import local_ops
    from adw_modules.git_ops import commit_changes

    run = local_ops.load_run(adw_id)
    if run is None:
        _local_narrate(adw_id, f"❌ No run record at agents/{adw_id}/run.json")
        logger.error(f"Missing or corrupt run record for {adw_id}")
        import sys

        sys.exit(1)

    prompt = run.get("input_data", {}).get("prompt")
    if not prompt or not str(prompt).strip():
        _local_fail(adw_id, None, "Run record has no input_data.prompt", logger)

    normalized = [str(s).strip().lower() for s in steps if str(s).strip()]
    first_step = normalized[0] if normalized else None

    local_ops.update_run(
        adw_id, status=local_ops.IN_PROGRESS, current_step=first_step
    )
    _local_narrate(adw_id, f"✅ Starting local workflow ({' + '.join(normalized)})")

    # Synthesize the local issue (numeric id keeps spec/branch conventions intact).
    issue = local_ops.synthesize_issue(run)
    logger.info(f"Synthesized local issue #{issue.number}: {issue.title}")

    state = ADWState.load(adw_id, logger) or ADWState(adw_id)
    state.update(
        adw_id=adw_id, issue_number=str(issue.number), issue_class=LOCAL_ISSUE_CLASS
    )
    model = run.get("input_data", {}).get("model")
    state.update(model_set="heavy" if model in ("heavy", "opus") else "base")
    state.append_adw_id(adw_id)
    state.save(adw_id)

    worktree_path, branch_name, backend_port, frontend_port = _local_setup_worktree(
        adw_id, issue, state, logger
    )
    local_ops.update_run(
        adw_id, output={"branch": branch_name, "worktree": worktree_path}
    )
    _local_narrate(
        adw_id,
        f"✅ Worktree ready: {worktree_path} (branch {branch_name}, "
        f"ports {backend_port}/{frontend_port})",
    )

    spec_file = None
    completed = 0
    did_change = False
    commit_sha = None

    def _commit_pending() -> None:
        """Commit worktree changes once. Ship needs this BEFORE merging so the
        merge captures every implementing step's output; otherwise it runs
        after the loop (mirroring the shipped plan+build composite)."""
        nonlocal did_change, commit_sha
        if not did_change:
            return

        commit_msg, error = create_commit(
            AGENT_IMPLEMENTOR, issue, LOCAL_ISSUE_CLASS, adw_id, logger, worktree_path
        )
        if error:
            _local_fail(
                adw_id, "ship", f"Error creating commit message: {error}", logger
            )

        success, error = commit_changes(commit_msg, cwd=worktree_path)
        if not success:
            _local_fail(adw_id, "ship", f"Error committing changes: {error}", logger)

        rev = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            cwd=worktree_path,
        )
        if rev.returncode == 0:
            commit_sha = rev.stdout.strip()
        did_change = False

    for step in normalized:
        local_ops.step_start(adw_id, step, summary=f"running {step}")
        step_t0 = time.monotonic()

        if step == "plan":
            resp = build_plan(
                issue, LOCAL_ISSUE_CLASS, adw_id, logger, working_dir=worktree_path
            )
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, f"Error building plan: {resp.output}", logger)

            spec_file = resp.output.strip().strip("`")
            spec_abs = (
                spec_file
                if os.path.isabs(spec_file)
                else os.path.join(worktree_path, spec_file)
            )
            if not spec_file or not os.path.exists(spec_abs):
                fallback = _local_find_spec_fallback(
                    worktree_path, issue.number, adw_id
                )
                if not fallback:
                    local_ops.step_end(adw_id, step, "failed")
                    _local_fail(
                        adw_id,
                        step,
                        f"Planner returned no usable spec path ({spec_file!r})",
                        logger,
                    )
                spec_file = os.path.relpath(fallback, worktree_path)

            state.update(plan_file=spec_file)
            state.save(adw_id)
            local_ops.update_run(adw_id, output={"spec_file": spec_file})
            _local_narrate(adw_id, f"✅ Plan created: {spec_file}", AGENT_PLANNER)

        elif step == "build":
            if not spec_file:
                spec_file = _local_find_spec_fallback(
                    worktree_path, issue.number, adw_id
                )
            if not spec_file:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, "No spec file to implement", logger)

            resp = implement_plan(spec_file, adw_id, logger, working_dir=worktree_path)
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(
                    adw_id, step, f"Error implementing plan: {resp.output}", logger
                )
            did_change = True
            _local_narrate(adw_id, "✅ Implementation complete", AGENT_IMPLEMENTOR)

        elif step == "patch":
            _patch_file, resp = create_and_implement_patch(
                adw_id,
                prompt,
                logger,
                AGENT_PLANNER,
                AGENT_IMPLEMENTOR,
                spec_path=spec_file,
                working_dir=worktree_path,
            )
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, f"Error patching: {resp.output}", logger)
            did_change = True
            _local_narrate(adw_id, "✅ Patch applied", AGENT_IMPLEMENTOR)

        elif step == "test":
            from adw_test_iso import run_tests

            resp = run_tests(adw_id, logger, working_dir=worktree_path)
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, f"Tests failed: {resp.output}", logger)
            _local_narrate(adw_id, "✅ Tests complete")

        elif step == "review":
            from adw_review_iso import run_review

            resp = run_review(adw_id, logger, working_dir=worktree_path)
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, f"Review failed: {resp.output}", logger)
            _local_narrate(adw_id, "✅ Review complete")

        elif step == "document":
            from adw_document_iso import generate_documentation

            resp = generate_documentation(adw_id, logger, working_dir=worktree_path)
            if not resp.success:
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(adw_id, step, f"Docs failed: {resp.output}", logger)
            did_change = True
            _local_narrate(adw_id, "✅ Documentation complete")

        elif step == "ship":
            # Real ship: commit whatever is pending, then merge the worktree
            # branch into the repo's detected trunk (local merge; push only
            # when an origin remote exists — see adw_modules/merge_ops.py).
            from adw_modules import merge_ops

            _commit_pending()
            repo_root = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            ok, merged_sha, merge_error = merge_ops.merge_branch_into_trunk(
                branch_name, cwd=repo_root, logger=logger
            )
            if not ok:
                local_ops.update_merge_result(
                    adw_id, local_ops.MERGE_FAILED, merge_error=merge_error
                )
                local_ops.step_end(adw_id, step, "failed")
                _local_fail(
                    adw_id, step, f"Merge to trunk failed: {merge_error}", logger
                )
            local_ops.update_merge_result(
                adw_id, local_ops.MERGE_MERGED, merged_sha=merged_sha
            )
            _local_narrate(
                adw_id, f"✅ Ship: merged {branch_name} into trunk @ {merged_sha}"
            )

        else:
            local_ops.step_end(adw_id, step, "failed")
            _local_fail(adw_id, step, f"Unknown step: {step}", logger)

        completed += 1
        local_ops.step_end(
            adw_id,
            step,
            "completed",
            duration_ms=int((time.monotonic() - step_t0) * 1000),
        )
        local_ops.update_run(adw_id, completed_steps=completed)

    # Commit once in the worktree if any step changed files (no push — offline).
    # A ship step already committed via _commit_pending(); this is a no-op then.
    _commit_pending()

    state.save(adw_id)
    local_ops.update_run(
        adw_id,
        status=local_ops.COMPLETED,
        completed_steps=completed,
        output={"commit": commit_sha},
    )
    _local_narrate(adw_id, "✅ Local workflow completed")
    logger.info("Local workflow completed successfully")
