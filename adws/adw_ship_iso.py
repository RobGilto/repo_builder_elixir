#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Ship Iso - AI Developer Workflow for shipping (merging) to the trunk branch

Usage:
  uv run adw_ship_iso.py <issue-number> <adw-id>

Workflow:
1. Load state and validate worktree exists
2. Validate ALL state fields are populated (not None)
3. Perform git merge in the main repository via the shared
   adw_modules.merge_ops helper (trunk detected dynamically — main, dev, ...):
   - Fetch latest from origin (skipped when no origin remote exists)
   - Checkout the detected trunk branch
   - Merge feature branch (--no-ff)
   - Push to origin/<trunk> (skipped when no origin remote exists)
4. Post success message to issue

This workflow REQUIRES that all previous workflows have been run and that
every field in ADWState has a value. This is our final approval step.

Note: Merge operations happen in the main repository root, not in the worktree,
to preserve the worktree's state.
"""

import sys
import os
import logging
import json
import subprocess
from typing import Optional, Dict, Any, Tuple
from dotenv import load_dotenv

from adw_modules.state import ADWState
from adw_modules.github import (
    make_issue_comment,
    get_repo_url,
    extract_repo_path,
)
from adw_modules.workflow_ops import format_issue_message
from adw_modules.utils import setup_logger, check_env_vars
from adw_modules.worktree_ops import validate_worktree
from adw_modules.data_types import ADWStateData
from adw_modules.git_ops import get_trunk_branch
from adw_modules.merge_ops import merge_branch_into_trunk

# Agent name constant
AGENT_SHIPPER = "shipper"


def get_main_repo_root() -> str:
    """Get the main repository root directory (parent of adws)."""
    # This script is in adws/, so go up one level to get repo root
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def merge_to_trunk(branch_name: str, logger: logging.Logger) -> Tuple[bool, Optional[str], Optional[str]]:
    """Merge a branch into the detected trunk via the shared merge helper.

    This runs in the main repository root, not in a worktree. The trunk branch
    is detected dynamically (main, dev, ...) — never hardcoded.

    Args:
        branch_name: The feature branch to merge
        logger: Logger instance

    Returns:
        Tuple of (success, merged_sha, error_message)
    """
    repo_root = get_main_repo_root()
    logger.info(f"Performing merge in main repository: {repo_root}")
    return merge_branch_into_trunk(branch_name, cwd=repo_root, logger=logger)


def validate_state_completeness(state: ADWState, logger: logging.Logger) -> tuple[bool, list[str]]:
    """Validate that all fields in ADWState have values (not None).
    
    Returns:
        tuple of (is_valid, missing_fields)
    """
    # Get the expected fields from ADWStateData model
    expected_fields = {
        "adw_id",
        "issue_number",
        "branch_name",
        "plan_file",
        "issue_class",
        "worktree_path",
        "backend_port",
        "frontend_port",
    }
    
    missing_fields = []
    
    for field in expected_fields:
        value = state.get(field)
        if value is None:
            missing_fields.append(field)
            logger.warning(f"Missing required field: {field}")
        else:
            logger.debug(f"✓ {field}: {value}")
    
    return len(missing_fields) == 0, missing_fields


def main():
    """Main entry point."""
    # Load environment variables
    load_dotenv()
    
    # Parse command line args
    # INTENTIONAL: adw-id is REQUIRED - we need it to find the worktree and state
    if len(sys.argv) < 3:
        print("Usage: uv run adw_ship_iso.py <issue-number> <adw-id>")
        print("\nError: Both issue-number and adw-id are required")
        print("Run the complete SDLC workflow before shipping")
        sys.exit(1)
    
    issue_number = sys.argv[1]
    adw_id = sys.argv[2]
    
    # Try to load existing state
    temp_logger = setup_logger(adw_id, "adw_ship_iso")
    state = ADWState.load(adw_id, temp_logger)
    if not state:
        # No existing state found
        logger = setup_logger(adw_id, "adw_ship_iso")
        logger.error(f"No state found for ADW ID: {adw_id}")
        logger.error("Run the complete SDLC workflow before shipping")
        print(f"\nError: No state found for ADW ID: {adw_id}")
        print("Run the complete SDLC workflow before shipping")
        sys.exit(1)
    
    # Update issue number from state if available
    issue_number = state.get("issue_number", issue_number)
    
    # Track that this ADW workflow has run
    state.append_adw_id("adw_ship_iso")
    
    # Set up logger with ADW ID
    logger = setup_logger(adw_id, "adw_ship_iso")
    logger.info(f"ADW Ship Iso starting - ID: {adw_id}, Issue: {issue_number}")
    
    # Validate environment
    check_env_vars(logger)
    
    # Post initial status
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, "ops", f"🚢 Starting ship workflow\n"
                           f"📋 Validating state completeness...")
    )
    
    # Step 1: Validate state completeness
    logger.info("Validating state completeness...")
    is_valid, missing_fields = validate_state_completeness(state, logger)
    
    if not is_valid:
        error_msg = f"State validation failed. Missing fields: {', '.join(missing_fields)}"
        logger.error(error_msg)
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_SHIPPER, f"❌ {error_msg}\n\n"
                               "Please ensure all workflows have been run:\n"
                               "- adw_plan_iso.py (creates plan_file, branch_name, issue_class)\n"
                               "- adw_build_iso.py (implements the plan)\n" 
                               "- adw_test_iso.py (runs tests)\n"
                               "- adw_review_iso.py (reviews implementation)\n"
                               "- adw_document_iso.py (generates docs)")
        )
        sys.exit(1)
    
    logger.info("✅ State validation passed - all fields have values")
    
    # Step 2: Validate worktree exists
    valid, error = validate_worktree(adw_id, state)
    if not valid:
        logger.error(f"Worktree validation failed: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_SHIPPER, f"❌ Worktree validation failed: {error}")
        )
        sys.exit(1)
    
    worktree_path = state.get("worktree_path")
    logger.info(f"✅ Worktree validated at: {worktree_path}")
    
    # Step 3: Get branch name
    branch_name = state.get("branch_name")
    logger.info(f"Preparing to merge branch: {branch_name}")
    
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, AGENT_SHIPPER, f"📋 State validation complete\n"
                           f"🔍 Preparing to merge branch: {branch_name}")
    )
    
    # Step 4: Perform merge into the detected trunk
    trunk_branch = get_trunk_branch(cwd=get_main_repo_root())
    logger.info(f"Starting merge of {branch_name} to {trunk_branch}...")
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, AGENT_SHIPPER, f"🔀 Merging {branch_name} to {trunk_branch}...\n"
                           "Using git operations in main repository")
    )

    success, merged_sha, error = merge_to_trunk(branch_name, logger)

    if not success:
        logger.error(f"Failed to merge: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_SHIPPER, f"❌ Failed to merge: {error}")
        )
        sys.exit(1)

    logger.info(f"✅ Successfully merged {branch_name} to {trunk_branch} @ {merged_sha}")

    # Step 5: Post success message
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, AGENT_SHIPPER,
                           f"🎉 **Successfully shipped!**\n\n"
                           f"✅ Validated all state fields\n"
                           f"✅ Merged branch `{branch_name}` to {trunk_branch} @ `{merged_sha}`\n"
                           f"✅ Pushed to origin/{trunk_branch} (when a remote exists)\n\n"
                           f"🚢 Code has been deployed to production!")
    )
    
    # Save final state
    state.save("adw_ship_iso")
    
    # Post final state summary
    make_issue_comment(
        issue_number,
        f"{adw_id}_ops: 📋 Final ship state:\n```json\n{json.dumps(state.data, indent=2)}\n```"
    )
    
    logger.info("Ship workflow completed successfully")


if __name__ == "__main__":
    main()