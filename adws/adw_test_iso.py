#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Test Iso - AI Developer Workflow for agentic testing in isolated worktrees

Usage:
  uv run adw_test_iso.py <issue-number> <adw-id> [--skip-e2e]

Workflow:
1. Load state and validate worktree exists
2. Run application test suite in worktree
3. Report results to issue
4. Create commit with test results in worktree
5. Push and update PR

This workflow REQUIRES that adw_plan_iso.py or adw_patch_iso.py has been run first
to create the worktree. It cannot create worktrees itself.
"""

import json
import subprocess
import sys
import os
import logging
from typing import Tuple, Optional, List
from dotenv import load_dotenv
from adw_modules.data_types import (
    AgentTemplateRequest,
    GitHubIssue,
    AgentPromptResponse,
    TestResult,
    E2ETestResult,
    IssueClassSlashCommand,
)
from adw_modules.agent import execute_template
from adw_modules.github import (
    extract_repo_path,
    fetch_issue,
    make_issue_comment,
    get_repo_url,
)
from adw_modules.utils import make_adw_id, setup_logger, parse_json, check_env_vars
from adw_modules.state import ADWState
from adw_modules.git_ops import commit_changes, finalize_git_operations
from adw_modules.workflow_ops import (
    format_issue_message,
    create_commit,
    ensure_adw_id,
    classify_issue,
)
from adw_modules.worktree_ops import validate_worktree

# Agent name constants
AGENT_TESTER = "test_runner"
AGENT_E2E_TESTER = "e2e_test_runner"
AGENT_BRANCH_GENERATOR = "branch_generator"

# Maximum number of test retry attempts after resolution
MAX_TEST_RETRY_ATTEMPTS = 4
MAX_E2E_TEST_RETRY_ATTEMPTS = 2  # E2E ui tests




def run_tests(adw_id: str, logger: logging.Logger, working_dir: Optional[str] = None) -> AgentPromptResponse:
    """Run the test suite using the /test command."""
    test_template_request = AgentTemplateRequest(
        agent_name=AGENT_TESTER,
        slash_command="/test",
        args=[],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"test_template_request: {test_template_request.model_dump_json(indent=2, by_alias=True)}"
    )

    test_response = execute_template(test_template_request)

    logger.debug(
        f"test_response: {test_response.model_dump_json(indent=2, by_alias=True)}"
    )

    return test_response


def parse_test_results(
    output: str, logger: logging.Logger
) -> Tuple[List[TestResult], int, int]:
    """Parse test results JSON and return (results, passed_count, failed_count)."""
    try:
        # Use parse_json to handle markdown-wrapped JSON
        results = parse_json(output, List[TestResult])

        passed_count = sum(1 for test in results if test.passed)
        failed_count = len(results) - passed_count

        return results, passed_count, failed_count
    except Exception as e:
        logger.error(f"Error parsing test results: {e}")
        return [], 0, 0


def format_test_results_comment(
    results: List[TestResult], passed_count: int, failed_count: int
) -> str:
    """Format test results for GitHub issue comment with JSON blocks."""
    if not results:
        return "❌ No test results found"

    # Separate failed and passed tests
    failed_tests = [test for test in results if not test.passed]
    passed_tests = [test for test in results if test.passed]

    # Build comment
    comment_parts = []

    # Failed tests header
    if failed_tests:
        comment_parts.append("")
        comment_parts.append("## ❌ Failed Tests")
        comment_parts.append("")

        # Loop over each failed test
        for test in failed_tests:
            comment_parts.append(f"### {test.test_name}")
            comment_parts.append("")
            comment_parts.append("```json")
            comment_parts.append(json.dumps(test.model_dump(), indent=2))
            comment_parts.append("```")
            comment_parts.append("")

    # Passed tests header
    if passed_tests:
        comment_parts.append("## ✅ Passed Tests")
        comment_parts.append("")

        # Loop over each passed test
        for test in passed_tests:
            comment_parts.append(f"### {test.test_name}")
            comment_parts.append("")
            comment_parts.append("```json")
            comment_parts.append(json.dumps(test.model_dump(), indent=2))
            comment_parts.append("```")
            comment_parts.append("")

    # Summary
    comment_parts.append("## Summary")
    comment_parts.append(f"- **Passed**: {passed_count}")
    comment_parts.append(f"- **Failed**: {failed_count}")
    comment_parts.append(f"- **Total**: {len(results)}")

    return "\n".join(comment_parts)


def parse_e2e_test_results(
    output: str, logger: logging.Logger
) -> Tuple[List[E2ETestResult], int, int]:
    """Parse E2E test results JSON and return (results, passed_count, failed_count)."""
    try:
        # Use parse_json to handle markdown-wrapped JSON
        results = parse_json(output, List[E2ETestResult])

        passed_count = sum(1 for test in results if test.passed)
        failed_count = len(results) - passed_count

        return results, passed_count, failed_count
    except Exception as e:
        logger.error(f"Error parsing E2E test results: {e}")
        return [], 0, 0


def post_comprehensive_test_summary(
    issue_number: str,
    adw_id: str,
    results: List[TestResult],
    e2e_results: List[E2ETestResult],
    logger: logging.Logger,
):
    """Post a comprehensive test summary including both unit and E2E tests."""
    summary = "# 🧪 Comprehensive Test Results\n\n"

    # Unit test section
    if results:
        passed_count = sum(1 for test in results if test.passed)
        failed_count = len(results) - passed_count

        summary += "## Unit Tests\n\n"
        summary += f"- **Total**: {len(results)}\n"
        summary += f"- **Passed**: {passed_count} ✅\n"
        summary += f"- **Failed**: {failed_count} ❌\n\n"

        # List failures first
        failed_tests = [test for test in results if not test.passed]
        if failed_tests:
            summary += "### Failed Unit Tests:\n"
            for test in failed_tests:
                summary += f"- ❌ {test.test_name}\n"
            summary += "\n"

    # E2E test section
    if e2e_results:
        e2e_passed_count = sum(1 for test in e2e_results if test.passed)
        e2e_failed_count = len(e2e_results) - e2e_passed_count

        summary += "## E2E Tests\n\n"
        summary += f"- **Total**: {len(e2e_results)}\n"
        summary += f"- **Passed**: {e2e_passed_count} ✅\n"
        summary += f"- **Failed**: {e2e_failed_count} ❌\n\n"

        # List E2E failures
        e2e_failed_tests = [test for test in e2e_results if not test.passed]
        if e2e_failed_tests:
            summary += "### Failed E2E Tests:\n"
            for result in e2e_failed_tests:
                summary += f"- ❌ {result.test_name}\n"
                if result.screenshots:
                    summary += f"  - Screenshots: {', '.join(result.screenshots)}\n"

    # Overall status
    total_failures = (
        (failed_count if results else 0) + 
        (e2e_failed_count if e2e_results else 0)
    )
    if total_failures > 0:
        summary += f"\n### ❌ Overall Status: FAILED\n"
        summary += f"Total failures: {total_failures}\n"
    else:
        total_tests = len(results) + len(e2e_results)
        summary += f"\n### ✅ Overall Status: PASSED\n"
        summary += f"All {total_tests} tests passed successfully!\n"

    # Post the summary to the issue
    make_issue_comment(
        issue_number, format_issue_message(adw_id, "test_summary", summary)
    )

    logger.info(f"Posted comprehensive test results summary to issue #{issue_number}")


def run_e2e_tests(adw_id: str, logger: logging.Logger, working_dir: Optional[str] = None) -> AgentPromptResponse:
    """Run the E2E test suite using the /test_e2e command.
    
    Note: The test_e2e command will automatically detect and use ports from .ports.env
    in the working directory if it exists.
    """
    test_template_request = AgentTemplateRequest(
        agent_name=AGENT_E2E_TESTER,
        slash_command="/test_e2e",
        args=[],
        adw_id=adw_id,
        working_dir=working_dir,
    )

    logger.debug(
        f"e2e_test_template_request: {test_template_request.model_dump_json(indent=2, by_alias=True)}"
    )

    test_response = execute_template(test_template_request)

    logger.debug(
        f"e2e_test_response: {test_response.model_dump_json(indent=2, by_alias=True)}"
    )

    return test_response


def resolve_failed_tests(
    failed_tests: List[TestResult],
    adw_id: str,
    issue_number: str,
    logger: logging.Logger,
    worktree_path: str,
    iteration: int = 1,
) -> Tuple[int, int]:
    """
    Attempt to resolve failed tests using the resolve_failed_test command.
    Returns (resolved_count, unresolved_count).
    """
    resolved_count = 0
    unresolved_count = 0

    for idx, test in enumerate(failed_tests):
        logger.info(
            f"\n=== Resolving failed test {idx + 1}/{len(failed_tests)}: {test.test_name} ==="
        )

        # Create payload for the resolve command
        test_payload = test.model_dump_json(indent=2)

        # Create agent name with iteration
        agent_name = f"test_resolver_iter{iteration}_{idx}"

        # Create template request with worktree_path
        resolve_request = AgentTemplateRequest(
            agent_name=agent_name,
            slash_command="/resolve_failed_test",
            args=[test_payload],
            adw_id=adw_id,
            working_dir=worktree_path,
        )

        # Post to issue
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                agent_name,
                f"🔧 Attempting to resolve: {test.test_name}\n```json\n{test_payload}\n```",
            ),
        )

        # Execute resolution
        response = execute_template(resolve_request)

        if response.success:
            resolved_count += 1
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    agent_name,
                    f"✅ Successfully resolved: {test.test_name}",
                ),
            )
            logger.info(f"Successfully resolved: {test.test_name}")
        else:
            unresolved_count += 1
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    agent_name,
                    f"❌ Failed to resolve: {test.test_name}",
                ),
            )
            logger.error(f"Failed to resolve: {test.test_name}")

    return resolved_count, unresolved_count


def run_tests_with_resolution(
    adw_id: str,
    issue_number: str,
    logger: logging.Logger,
    worktree_path: str,
    max_attempts: int = MAX_TEST_RETRY_ATTEMPTS,
) -> Tuple[List[TestResult], int, int, AgentPromptResponse]:
    """
    Run tests with automatic resolution and retry logic.
    Returns (results, passed_count, failed_count, last_test_response).
    """
    attempt = 0
    results = []
    passed_count = 0
    failed_count = 0
    test_response = None

    while attempt < max_attempts:
        attempt += 1
        logger.info(f"\n=== Test Run Attempt {attempt}/{max_attempts} ===")

        # Run tests in worktree
        test_response = run_tests(adw_id, logger, worktree_path)

        # If there was a high level - non-test related error, stop and report it
        if not test_response.success:
            logger.error(f"Error running tests: {test_response.output}")
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    AGENT_TESTER,
                    f"❌ Error running tests: {test_response.output}",
                ),
            )
            break

        # Parse test results
        results, passed_count, failed_count = parse_test_results(
            test_response.output, logger
        )

        # If no failures or this is the last attempt, we're done
        if failed_count == 0:
            logger.info("All tests passed, stopping retry attempts")
            break
        if attempt == max_attempts:
            logger.info(f"Reached maximum retry attempts ({max_attempts}), stopping")
            break

        # If we have failed tests and this isn't the last attempt, try to resolve
        logger.info("\n=== Attempting to resolve failed tests ===")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                f"🔧 Found {failed_count} failed tests. Attempting resolution...",
            ),
        )

        # Get list of failed tests
        failed_tests = [test for test in results if not test.passed]

        # Attempt resolution
        resolved, unresolved = resolve_failed_tests(
            failed_tests, adw_id, issue_number, logger, worktree_path, iteration=attempt
        )

        # Report resolution results
        if resolved > 0:
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id, "ops", f"✅ Resolved {resolved}/{failed_count} failed tests"
                ),
            )

            # Continue to next attempt if we resolved something
            logger.info(f"\n=== Re-running tests after resolving {resolved} tests ===")
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    AGENT_TESTER,
                    f"🔄 Re-running tests (attempt {attempt + 1}/{max_attempts})...",
                ),
            )
        else:
            # No tests were resolved, no point in retrying
            logger.info("No tests were resolved, stopping retry attempts")
            break

    # Log final attempt status
    if attempt == max_attempts and failed_count > 0:
        logger.warning(
            f"Reached maximum retry attempts ({max_attempts}) with {failed_count} failures remaining"
        )
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                f"⚠️ Reached maximum retry attempts ({max_attempts}) with {failed_count} failures",
            ),
        )

    return results, passed_count, failed_count, test_response


def resolve_failed_e2e_tests(
    failed_tests: List[E2ETestResult],
    adw_id: str,
    issue_number: str,
    logger: logging.Logger,
    worktree_path: str,
    iteration: int = 1,
) -> Tuple[int, int]:
    """
    Attempt to resolve failed E2E tests using the resolve_failed_e2e_test command.
    Returns (resolved_count, unresolved_count).
    """
    resolved_count = 0
    unresolved_count = 0

    for idx, test in enumerate(failed_tests):
        logger.info(
            f"\n=== Resolving failed E2E test {idx + 1}/{len(failed_tests)}: {test.test_name} ==="
        )

        # Create payload for the resolve command
        test_payload = test.model_dump_json(indent=2)

        # Create agent name with iteration
        agent_name = f"e2e_test_resolver_iter{iteration}_{idx}"

        # Create template request with worktree_path
        resolve_request = AgentTemplateRequest(
            agent_name=agent_name,
            slash_command="/resolve_failed_e2e_test",
            args=[test_payload],
            adw_id=adw_id,
            working_dir=worktree_path,
        )

        # Post to issue
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                agent_name,
                f"🔧 Attempting to resolve E2E test: {test.test_name}\n```json\n{test_payload}\n```",
            ),
        )

        # Execute resolution
        response = execute_template(resolve_request)

        if response.success:
            resolved_count += 1
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    agent_name,
                    f"✅ Successfully resolved E2E test: {test.test_name}",
                ),
            )
            logger.info(f"Successfully resolved E2E test: {test.test_name}")
        else:
            unresolved_count += 1
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    agent_name,
                    f"❌ Failed to resolve E2E test: {test.test_name}",
                ),
            )
            logger.error(f"Failed to resolve E2E test: {test.test_name}")

    return resolved_count, unresolved_count


def run_e2e_tests_with_resolution(
    adw_id: str,
    issue_number: str,
    logger: logging.Logger,
    worktree_path: str,
    max_attempts: int = MAX_E2E_TEST_RETRY_ATTEMPTS,
) -> Tuple[List[E2ETestResult], int, int]:
    """
    Run E2E tests with automatic resolution and retry logic.
    Returns (results, passed_count, failed_count).
    """
    attempt = 0
    results = []
    passed_count = 0
    failed_count = 0

    while attempt < max_attempts:
        attempt += 1
        logger.info(f"\n=== E2E Test Run Attempt {attempt}/{max_attempts} ===")

        # Run E2E tests (will auto-detect ports from .ports.env in worktree)
        e2e_response = run_e2e_tests(adw_id, logger, worktree_path)

        if not e2e_response.success:
            logger.error(f"Error running E2E tests: {e2e_response.output}")
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    AGENT_E2E_TESTER,
                    f"❌ Error running E2E tests: {e2e_response.output}",
                ),
            )
            break

        # Parse E2E results
        results, passed_count, failed_count = parse_e2e_test_results(
            e2e_response.output, logger
        )

        if not results:
            logger.warning("No E2E test results to process")
            break

        # If no failures or this is the last attempt, we're done
        if failed_count == 0:
            logger.info("All E2E tests passed, stopping retry attempts")
            break
        if attempt == max_attempts:
            logger.info(
                f"Reached maximum E2E retry attempts ({max_attempts}), stopping"
            )
            break

        # If we have failed tests and this isn't the last attempt, try to resolve
        logger.info("\n=== Attempting to resolve failed E2E tests ===")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                f"🔧 Found {failed_count} failed E2E tests. Attempting resolution...",
            ),
        )

        # Get list of failed tests
        failed_tests = [test for test in results if not test.passed]

        # Attempt resolution
        resolved, unresolved = resolve_failed_e2e_tests(
            failed_tests, adw_id, issue_number, logger, worktree_path, iteration=attempt
        )

        # Report resolution results
        if resolved > 0:
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    "ops",
                    f"✅ Resolved {resolved}/{failed_count} failed E2E tests",
                ),
            )

            # Continue to next attempt if we resolved something
            logger.info(
                f"\n=== Re-running E2E tests after resolving {resolved} tests ==="
            )
            make_issue_comment(
                issue_number,
                format_issue_message(
                    adw_id,
                    AGENT_E2E_TESTER,
                    f"🔄 Re-running E2E tests (attempt {attempt + 1}/{max_attempts})...",
                ),
            )
        else:
            # No tests were resolved, no point in retrying
            logger.info("No E2E tests were resolved, stopping retry attempts")
            break

    # Log final attempt status
    if attempt == max_attempts and failed_count > 0:
        logger.warning(
            f"Reached maximum E2E retry attempts ({max_attempts}) with {failed_count} failures remaining"
        )
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id,
                "ops",
                f"⚠️ Reached maximum E2E retry attempts ({max_attempts}) with {failed_count} failures",
            ),
        )

    return results, passed_count, failed_count


def main():
    """Main entry point."""
    # Load environment variables
    load_dotenv()
    
    # Check for --skip-e2e flag in args
    skip_e2e = "--skip-e2e" in sys.argv
    # Remove flag from args if present
    if skip_e2e:
        sys.argv.remove("--skip-e2e")
    
    # Parse command line args
    # INTENTIONAL: adw-id is REQUIRED - we need it to find the worktree
    if len(sys.argv) < 3:
        print("Usage: uv run adw_test_iso.py <issue-number> <adw-id> [--skip-e2e]")
        print("\nError: adw-id is required to locate the worktree")
        print("Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree")
        sys.exit(1)
    
    issue_number = sys.argv[1]
    adw_id = sys.argv[2]
    
    # Try to load existing state
    temp_logger = setup_logger(adw_id, "adw_test_iso")
    state = ADWState.load(adw_id, temp_logger)
    if state:
        # Found existing state - use the issue number from state if available
        issue_number = state.get("issue_number", issue_number)
        make_issue_comment(
            issue_number,
            f"{adw_id}_ops: 🔍 Found existing state - starting isolated testing\n```json\n{json.dumps(state.data, indent=2)}\n```"
        )
    else:
        # No existing state found
        logger = setup_logger(adw_id, "adw_test_iso")
        logger.error(f"No state found for ADW ID: {adw_id}")
        logger.error("Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree and state")
        print(f"\nError: No state found for ADW ID: {adw_id}")
        print("Run adw_plan_iso.py or adw_patch_iso.py first to create the worktree and state")
        sys.exit(1)
    
    # Track that this ADW workflow has run
    state.append_adw_id("adw_test_iso")
    
    # Set up logger with ADW ID from command line
    logger = setup_logger(adw_id, "adw_test_iso")
    logger.info(f"ADW Test Iso starting - ID: {adw_id}, Issue: {issue_number}, Skip E2E: {skip_e2e}")
    
    # Validate environment
    check_env_vars(logger)
    
    # Validate worktree exists
    valid, error = validate_worktree(adw_id, state)
    if not valid:
        logger.error(f"Worktree validation failed: {error}")
        logger.error("Run adw_plan_iso.py or adw_patch_iso.py first")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, "ops", f"❌ Worktree validation failed: {error}\n"
                               "Run adw_plan_iso.py or adw_patch_iso.py first")
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
        format_issue_message(adw_id, "ops", f"✅ Starting isolated testing phase\n"
                           f"🏠 Worktree: {worktree_path}\n"
                           f"🔌 Ports - Backend: {backend_port}, Frontend: {frontend_port}\n"
                           f"🧪 E2E Tests: {'Skipped' if skip_e2e else 'Enabled'}")
    )
    
    # Track results for resolution attempts
    test_results = []
    e2e_results = []
    
    # Run unit tests (executing in worktree)
    logger.info("Running unit tests in worktree with automatic resolution")
    make_issue_comment(
        issue_number,
        format_issue_message(adw_id, AGENT_TESTER, "🧪 Running unit tests in isolated environment...")
    )
    
    # Run tests with resolution and retry logic
    results, passed_count, failed_count, test_response = run_tests_with_resolution(
        adw_id, issue_number, logger, worktree_path
    )
    
    # Track results
    test_results = results
    
    if results:
        comment = format_test_results_comment(results, passed_count, failed_count)
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_TESTER, comment)
        )
        logger.info(f"Test results: {passed_count} passed, {failed_count} failed")
    else:
        logger.warning("No test results found in output")
        make_issue_comment(
            issue_number,
            format_issue_message(
                adw_id, AGENT_TESTER, "⚠️ No test results found in output"
            ),
        )
    
    # Run E2E tests if not skipped (executing in worktree)
    e2e_passed = 0
    e2e_failed = 0
    if not skip_e2e:
        logger.info("Running E2E tests in worktree with automatic resolution")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_E2E_TESTER, "🌐 Running E2E tests in isolated environment...")
        )
        
        # Run E2E tests with resolution and retry logic
        e2e_results, e2e_passed, e2e_failed = run_e2e_tests_with_resolution(
            adw_id, issue_number, logger, worktree_path
        )
        
        if e2e_results:
            logger.info(f"E2E test results: {e2e_passed} passed, {e2e_failed} failed")
    
    # Post comprehensive summary
    post_comprehensive_test_summary(
        issue_number, adw_id, test_results, e2e_results, logger
    )
    
    # Check if we should exit due to test failures
    total_failures = failed_count + (e2e_failed if not skip_e2e and e2e_results else 0)
    if total_failures > 0:
        logger.warning(f"Tests completed with {total_failures} failures - continuing to commit results")
        # Note: We don't exit here anymore, we commit the results regardless
        # This is different from the old workflow which would exit(1) on failures
    
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
    
    # Get issue classification from state or classify if needed
    issue_command = state.get("issue_class")
    if not issue_command:
        logger.info("No issue classification in state, running classify_issue")
        issue_command, error = classify_issue(issue, adw_id, logger)
        if error:
            logger.error(f"Error classifying issue: {error}")
            # Default to feature if classification fails
            issue_command = "/feature"
            logger.warning("Defaulting to /feature after classification error")
        else:
            # Save the classification for future use
            state.update(issue_class=issue_command)
            state.save("adw_test_iso")
    
    # Create commit message
    logger.info("Creating test commit")
    commit_msg, error = create_commit(AGENT_TESTER, issue, issue_command, adw_id, logger, worktree_path)
    
    if error:
        logger.error(f"Error creating commit message: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_TESTER, f"❌ Error creating commit message: {error}")
        )
        sys.exit(1)
    
    # Commit the test results (in worktree)
    success, error = commit_changes(commit_msg, cwd=worktree_path)
    
    if not success:
        logger.error(f"Error committing test results: {error}")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, AGENT_TESTER, f"❌ Error committing test results: {error}")
        )
        sys.exit(1)
    
    logger.info(f"Committed test results: {commit_msg}")
    make_issue_comment(
        issue_number, format_issue_message(adw_id, AGENT_TESTER, "✅ Test results committed")
    )
    
    # Finalize git operations (push and PR)
    # Note: This will work from the worktree context
    finalize_git_operations(state, logger, cwd=worktree_path)
    
    logger.info("Isolated testing phase completed successfully")
    make_issue_comment(
        issue_number, format_issue_message(adw_id, "ops", "✅ Isolated testing phase completed")
    )
    
    # Save final state
    state.save("adw_test_iso")
    
    # Post final state summary to issue
    make_issue_comment(
        issue_number,
        f"{adw_id}_ops: 📋 Final test state:\n```json\n{json.dumps(state.data, indent=2)}\n```"
    )
    
    # Exit with appropriate code based on test results
    if total_failures > 0:
        logger.error(f"Test workflow completed with {total_failures} failures")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, "ops", f"❌ Test workflow completed with {total_failures} failures")
        )
        sys.exit(1)
    else:
        logger.info("All tests passed successfully")
        make_issue_comment(
            issue_number,
            format_issue_message(adw_id, "ops", "✅ All tests passed successfully!")
        )


if __name__ == "__main__":
    main()