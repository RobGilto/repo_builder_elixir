#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Document Iso - AI Developer Workflow for documentation generation in isolated worktrees

Usage:
  uv run adw_document_iso.py <issue-number> <adw-id>

Workflow:
1. Load state and validate worktree exists
2. Find spec file from worktree
3. Analyze git changes in worktree
4. Generate feature documentation
5. Update conditional docs
6. Commit documentation in worktree

This workflow REQUIRES that adw_plan_iso.py or adw_patch_iso.py has been run first
to create the worktree. It cannot create worktrees itself.
"""

import sys
import os
import logging
import json
import subprocess
from typing import Optional
from datetime import datetime
from dotenv import load_dotenv

from adw_modules.state import ADWState
from adw_modules.git_ops import commit_changes, finalize_git_operations
from adw_modules.github import (
    fetch_issue,
    make_issue_comment,
    get_repo_url,
    extract_repo_path,
)
from adw_modules.workflow_ops import (
    create_commit,
    format_issue_message,
    find_spec_file,
)
from adw_modules.utils import setup_logger, check_env_vars
from adw_modules.data_types import (
    GitHubIssue,
    GitHubUser,
    AgentTemplateRequest,
    DocumentationResult,
    IssueClassSlashCommand,
)
from adw_modules.agent import execute_template
from adw_modules.worktree_ops import validate_worktree

# Agent name constant
AGENT_DOCUMENTER = "documenter"

DOCS_PATH = "app_docs/"


def check_for_changes(logger: logging.Logger, cwd: Optional[str] = None) -> bool:
    """Check if there are any changes between current branch and origin/main.

    Args:
        logger: Logger instance
        cwd: Working directory to run git commands in

    Returns:
        bool: True if changes exist, False if no changes
    """
    try:
        # Check for changes against origin/main
        result = subprocess.run(
            ["git", "diff", "origin/main", "--stat"],
            capture_output=True,
            text=True,
            check=True,
            cwd=cwd,
        )

        # If output is empty or only whitespace, no changes
        has_changes = bool(result.stdout.strip())

        if not has_changes:
            logger.info("No changes detected between current branch and origin/main")
        else:
            logger.info(f"Found changes:\n{result.stdout}")

        return has_changes

    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to check for changes: {e}")
        # If we can't check, assume there are changes and let the agent handle it
        return True


def generate_documentation(
    issue_number: str,
    adw_id: str,
    logger: logging.Logger,
    spec_file: str,
    working_dir: Optional[str] = None,
) -> Optional[DocumentationResult]:
    """Generate documentation using the /document command.

    Args:
        issue_number: GitHub issue number
        adw_id: ADW workflow ID
        logger: Logger instance
        spec_file: Path to the spec file
        working_dir: Working directory for the agent

    Returns:
        DocumentationResult if successful, None if failed
    """
    request = AgentTemplateRequest(
        agent_name=AGENT_DOCUMENTER,
        slash_command="/document",
        args=[spec_file],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"documentation_request: {request.model_dump_json(indent=2, by_alias=True)}"
    )

    response = execute_template(request)

    logger.debug(
        f"documentation_response: {response.model_dump_json(indent=2, by_alias=True)}"
    )

    if not response.success:
        logger.error(f"Documentation generation failed: {response.output}")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                AGENT_DOCUMENTER,
                f"❌ Documentation generation failed: {response.output}",
            ),
        )
        return None

    # Parse the agent response - it should return the path to the documentation file created
    doc_file_path = response.output.strip()

    # Check if the agent actually created documentation
    if doc_file_path and doc_file_path != "No documentation needed":
        # Agent created documentation - validate the path exists
        import os

        full_path = os.path.join(working_dir or ".", doc_file_path)
        if os.path.exists(full_path):
            logger.info(f"Documentation created at: {doc_file_path}")
            return DocumentationResult(
                success=True,
                documentation_created=True,
                documentation_path=doc_file_path,
                error_message=None,
            )
        else:
            logger.warning(
                f"Agent reported doc file {doc_file_path} but file not found"
            )
            return DocumentationResult(
                success=True,
                documentation_created=False,
                documentation_path=None,
                error_message=f"Reported file {doc_file_path} not found",
            )
    else:
        # Agent determined no documentation was needed
        logger.info("Agent determined no documentation changes were needed")
        return DocumentationResult(
            success=True,
            documentation_created=False,
            documentation_path=None,
            error_message=None,
        )


def track_agentic_kpis(
    issue_number: str,
    adw_id: str,
    state: ADWState,
    logger: logging.Logger,
    worktree_path: str,
) -> None:
    """Track agentic KPIs - never fails the main workflow.

    Args:
        issue_number: GitHub issue number
        adw_id: ADW workflow ID
        state: ADW state object
        logger: Logger instance
        worktree_path: Path to the worktree
    """
    try:
        logger.info("Tracking agentic KPIs...")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, "ops", "📊 Updating agentic KPIs"),
        )

        # Execute the track_agentic_kpis prompt
        kpi_request = AgentTemplateRequest(
            agent_name="kpi_tracker",
            slash_command="/track_agentic_kpis",
            args=[json.dumps(state.data, indent=2)],
            adw_id=adw_id,
            working_dir=worktree_path,
        )

        try:
            kpi_response = execute_template(kpi_request)

            if kpi_response.success:
                logger.info("Successfully updated agentic KPIs")

                # Commit the KPI changes
                try:
                    commit_msg, error = create_commit(
                        "kpi_tracker",
                        GitHubIssue(
                            number=int(issue_number),
                            title="Update agentic KPIs",
                            body="Tracking ADW performance metrics",
                            state="open",
                            author=GitHubUser(login="system"),
                            created_at=datetime.now(),
                            updated_at=datetime.now(),
                            url="",
                        ),
                        "/chore",
                        adw_id,
                        logger,
                        worktree_path,
                    )
                    if commit_msg and not error:
                        logger.info(f"Committed KPI update: {commit_msg}")
                        make_issue_comment(
                            issue_number,
                            format_issue_message(
                                adw_id, "kpi_tracker", "✅ Agentic KPIs updated"
                            ),
                        )
                    elif error:
                        logger.warning(f"Failed to create KPI commit: {error}")
                except Exception as e:
                    logger.warning(f"Failed to commit KPI update: {e}")
            else:
                logger.warning("Failed to update agentic KPIs - continuing anyway")
                make_issue_comment(
                    issue_number,
                    format_issue_message(
                        adw_id,
                        "kpi_tracker",
                        "⚠️ Failed to update agentic KPIs - continuing anyway",
                    ),
                )
        except Exception as e:
            logger.warning(f"Error executing KPI template: {e}")
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    "kpi_tracker",
                    "⚠️ Error tracking agentic KPIs - continuing anyway",
                ),
            )
    except Exception as e:
        # Catch-all to ensure we never fail the main workflow
        logger.error(f"Unexpected error in track_agentic_kpis: {e}")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "kpi_tracker",
                "⚠️ Top level error tracking agentic KPIs - continuing anyway",
            ),
        )


def main():
    """Main entry point."""
    # Load environment variables
    load_dotenv()

    # Parse command line args
    # INTENTIONAL: adw-id is REQUIRED - we need it to find the worktree
    if len(sys.argv) < 3:
        print("Usage: uv run adw_document_iso.py <issue-number> <adw-id>")
        print("\nError: adw-id is required to locate the worktree")
        print("Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree")
        sys.exit(1)

    issue_number = sys.argv[1]
    adw_id = sys.argv[2]

    # Try to load existing state
    temp_logger = setup_logger(adw_id, "adw_document_iso")
    state = ADWState.load(adw_id, temp_logger)
    if state:
        # Found existing state - use the issue number from state if available
        issue_number = state.get("issue_number", issue_number)
        make_issue_comment(
            issue_number,
            f"{adw_id}_ops: 🔍 Found existing state - starting isolated documentation\n```json\n{json.dumps(state.data, indent=2)}\n```",
        )
    else:
        # No existing state found
        logger = setup_logger(adw_id, "adw_document_iso")
        logger.error(f"No state found for ADW ID: {adw_id}")
        logger.error(
            "Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree and state"
        )
        print(f"\nError: No state found for ADW ID: {adw_id}")
        print(
            "Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree and state"
        )
        sys.exit(1)

    # Track that this ADW workflow has run
    state.append_adw_id("adw_document_iso")

    # Set up logger with ADW ID from command line
    logger = setup_logger(adw_id, "adw_document_iso")
    logger.info(f"ADW Document Iso starting - ID: {adw_id}, Issue: {issue_number}")

    # Validate environment
    check_env_vars(logger)

    # Validate worktree exists
    valid, error = validate_worktree(adw_id, state)
    if not valid:
        logger.error(f"Worktree validation failed: {error}")
        logger.error("Run adw_plan_iso.py or adw_patch_iso.py first")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                f"❌ Worktree validation failed: {error}\n"
                "Run adw_plan_iso.py or adw_patch_iso.py first",
            ),
        )
        sys.exit(1)

    # Get worktree path for explicit context
    worktree_path = state.get("worktree_path")
    logger.info(f"Using worktree at: {worktree_path}")

    # Get port information for display
    backend_port = state.get("backend_port", "9100")
    frontend_port = state.get("frontend_port", "9200")

    make_issue_comment(
        issue_number,
        format_issue_message(
            adw_id,
            "ops",
            f"✅ Starting isolated documentation phase\n"
            f"🏠 Worktree: {worktree_path}\n"
            f"🔌 Ports - Backend: {backend_port}, Frontend: {frontend_port}",
        ),
    )

    # Check if there are any changes to document (in worktree)
    if not check_for_changes(logger, cwd=worktree_path):
        logger.info("No changes to document - skipping documentation generation")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                "ℹ️ No changes detected between current branch and origin/main - skipping documentation",
            ),
        )
        return

    # Find spec file from current branch (in worktree)
    logger.info("Looking for spec file in worktree")
    spec_file = find_spec_file(state, logger)

    if not spec_file:
        error_msg = "Could not find spec file for documentation"
        logger.error(error_msg)
        make_issue_comment(
            issue_number, format_issue_message(adw_id, "ops", f"❌ {error_msg}")
        )
        sys.exit(1)

    logger.info(f"Found spec file: {spec_file}")
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, "ops", f"📋 Found spec file: {spec_file}"),
    )

    # Generate documentation (executing in worktree)
    logger.info("Generating documentation")
    make_issue_comment(
        issue_number,
        format_issue_message(
            adw_id,
            AGENT_DOCUMENTER,
            "📝 Generating documentation in isolated environment...",
        ),
    )

    doc_result = generate_documentation(
        issue_number, adw_id, logger, spec_file, working_dir=worktree_path
    )

    if not doc_result:
        # Error already logged and posted to issue
        sys.exit(1)

    if doc_result.documentation_created:
        logger.info(f"Documentation created at: {doc_result.documentation_path}")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                AGENT_DOCUMENTER,
                f"✅ Documentation generated successfully\n📁 Location: {doc_result.documentation_path}",
            ),
        )
    else:
        logger.info("No documentation changes were needed")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id, AGENT_DOCUMENTER, "ℹ️ No documentation changes were needed"
            ),
        )

    # Get repo information
    try:
        github_repo_url = get_repo_url()
        repo_path = extract_repo_path(github_repo_url)
    except ValueError as e:
        logger.error(f"Error getting repository URL: {e}")
        sys.exit(1)

    # Fetch issue data for commit message generation
    logger.info("Fetching issue data for commit message")
    issue = fetch_issue(issue_number, repo_path)

    # Get issue classification from state
    issue_command = state.get("issue_class", "/feature")

    # Create commit message
    logger.info("Creating documentation commit")
    commit_msg, error = create_commit(
        AGENT_DOCUMENTER, issue, issue_command, adw_id, logger, worktree_path
    )

    if error:
        logger.error(f"Error creating commit message: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id, AGENT_DOCUMENTER, f"❌ Error creating commit message: {error}"
            ),
        )
        sys.exit(1)

    # Commit the documentation (in worktree)
    success, error = commit_changes(commit_msg, cwd=worktree_path)

    if not success:
        logger.error(f"Error committing documentation: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                AGENT_DOCUMENTER,
                f"❌ Error committing documentation: {error}",
            ),
        )
        sys.exit(1)

    logger.info(f"Committed documentation: {commit_msg}")
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, AGENT_DOCUMENTER, "✅ Documentation committed"),
    )

    # Track Agentic KPIs before finalizing - this never fails the workflow
    track_agentic_kpis(issue_number, adw_id, state, logger, worktree_path)

    # Finalize git operations (push and PR)
    # Note: This will work from the worktree context
    finalize_git_operations(state, logger, cwd=worktree_path)

    logger.info("Isolated documentation phase completed successfully")
    make_issue_comment(
        issue_number,
        format_issue_message(
            adw_id, "ops", "✅ Isolated documentation phase completed"
        ),
    )

    # Save final state
    state.save("adw_document_iso")

    # Post final state summary to issue
    make_issue_comment(
        issue_number,
        f"{adw_id}_ops: 📋 Final documentation state:\n```json\n{json.dumps(state.data, indent=2)}\n```",
    )


if __name__ == "__main__":
    main()
