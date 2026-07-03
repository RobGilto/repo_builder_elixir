#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Plan Build Iso - Compositional workflow for isolated planning and building

Usage: uv run adw_plan_build_iso.py <issue-number> [adw-id]

This script runs:
1. adw_plan_iso.py - Planning phase (isolated)
2. adw_build_iso.py - Implementation phase (isolated)

The scripts are chained together via persistent state (adw_state.json).
"""

import logging
import subprocess
import sys
import os

# Add the parent directory to Python path to import modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adw_modules.workflow_ops import ensure_adw_id
from adw_modules.merge_ops import merge_branch_into_trunk
from adw_modules.state import ADWState


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: uv run adw_plan_build_iso.py <issue-number> [adw-id]")
        print("\nThis runs the isolated plan and build workflow:")
        print("  1. Plan (isolated)")
        print("  2. Build (isolated)")
        sys.exit(1)

    issue_number = sys.argv[1]
    adw_id = sys.argv[2] if len(sys.argv) > 2 else None

    # Ensure ADW ID exists with initialized state
    adw_id = ensure_adw_id(issue_number, adw_id)
    print(f"Using ADW ID: {adw_id}")

    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Run isolated plan with the ADW ID
    plan_cmd = [
        "uv",
        "run",
        os.path.join(script_dir, "adw_plan_iso.py"),
        issue_number,
        adw_id,
    ]
    print(f"\n=== ISOLATED PLAN PHASE ===")
    print(f"Running: {' '.join(plan_cmd)}")
    plan = subprocess.run(plan_cmd)
    if plan.returncode != 0:
        print("Isolated plan phase failed")
        sys.exit(1)

    # Run isolated build with the ADW ID
    build_cmd = [
        "uv",
        "run",
        os.path.join(script_dir, "adw_build_iso.py"),
        issue_number,
        adw_id,
    ]
    print(f"\n=== ISOLATED BUILD PHASE ===")
    print(f"Running: {' '.join(build_cmd)}")
    build = subprocess.run(build_cmd)
    if build.returncode != 0:
        print("Isolated build phase failed")
        sys.exit(1)

    # Ship: merge the feature branch into the repo's detected trunk (local git
    # merge, ZTE-chain parity). This point is reached only when every prior
    # phase exited 0 — the same tests/review-passing gating the ZTE chain uses.
    print(f"\n=== SHIP PHASE (MERGE TO TRUNK) ===")
    state = ADWState.load(adw_id, logging.getLogger(__name__))
    branch_name = state.get("branch_name") if state else None
    if not branch_name:
        print("Ship phase failed: no branch_name in state")
        sys.exit(1)
    repo_root = os.path.dirname(script_dir)
    success, merged_sha, error = merge_branch_into_trunk(branch_name, cwd=repo_root)
    if not success:
        print(f"Ship phase failed: {error}")
        sys.exit(1)
    print(f"Merged {branch_name} into trunk @ {merged_sha}")

    print(f"\n=== ISOLATED WORKFLOW COMPLETED ===")
    print(f"ADW ID: {adw_id}")
    print(f"All phases completed successfully!")


if __name__ == "__main__":
    main()