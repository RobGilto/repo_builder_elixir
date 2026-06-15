#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv"]
# ///

"""
Test script to verify simplified webhook workflow support.
"""

import os

# Mirror the constants from trigger_webhook.py
DEPENDENT_WORKFLOWS = [
    "adw_build", "adw_test", "adw_review", "adw_document",
    "adw_build_iso", "adw_test_iso", "adw_review_iso", "adw_document_iso"
]

def test_workflow_support():
    """Test the simplified workflow support."""
    print("=== Simplified Webhook Workflow Support ===")
    print()
    
    print("Entry Point Workflows (can be triggered via webhook):")
    entry_points = [
        "adw_plan",
        "adw_patch", 
        "adw_plan_build",
        "adw_plan_build_test",
        "adw_plan_build_test_review",
        "adw_plan_build_document",
        "adw_plan_build_review",
        "adw_sdlc",
        "adw_plan_iso",
        "adw_patch_iso",
        "adw_plan_build_iso",
        "adw_plan_build_test_iso",
        "adw_plan_build_test_review_iso",
        "adw_plan_build_document_iso",
        "adw_plan_build_review_iso",
        "adw_sdlc_iso",
    ]
    
    for workflow in entry_points:
        emoji = "🏗️" if workflow.endswith("_iso") else "🔧"
        print(f"  {workflow:35} {emoji}")
    
    print()
    print("Dependent Workflows (require ADW ID):")
    for workflow in DEPENDENT_WORKFLOWS:
        emoji = "🏗️" if workflow.endswith("_iso") else "🔧"
        print(f"  {workflow:35} {emoji}")
    
    print()
    print("Testing workflow validation logic:")
    
    test_cases = [
        ("adw_plan", None, True),
        ("adw_plan_iso", None, True),
        ("adw_build", None, False),  # Dependent, no ID
        ("adw_build", "test-123", True),  # Dependent with ID
        ("adw_build_iso", None, False),  # Dependent, no ID
        ("adw_build_iso", "test-123", True),  # Dependent with ID
        ("adw_plan_build", None, True),
        ("adw_plan_build_iso", None, True),
        ("adw_test_iso", None, False),  # Dependent, no ID
        ("adw_sdlc_iso", None, True),
    ]
    
    for workflow, adw_id, should_work in test_cases:
        if workflow in DEPENDENT_WORKFLOWS and not adw_id:
            status = "❌ BLOCKED (requires ADW ID)"
        else:
            status = "✅ Can trigger"
        
        id_info = f" (with ID: {adw_id})" if adw_id else ""
        print(f"  {workflow:20}{id_info:20} {status}")


if __name__ == "__main__":
    test_workflow_support()