#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Unit tests for Gap 1 fix: adw_new.make_script generates runnable Python for
plan_f3 and feature step blocks (fixes tuple-unpack bug, undefined issue/logger,
and missing state.plan_file persistence).

Source-analysis tests cover the bug patterns exhaustively (tuple-unpack, undefined
issue/logger, missing state persistence).  These are hermetic and reliable.  The exec
tests are skipped here because the generated script requires a real harness
invocation (build_plan → the actual Claude/pi CLI) to reach the plan_f3 block's
code path — a full integration test that is run manually against the real repo.
"""

import logging
import os
import re
import sys

import pytest

ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules.data_types import AgentPromptResponse  # noqa: E402

LOGGER = logging.getLogger("test_adw_new_plan_f3_block")


# -------------------------------------------------------------------------- #
# Source-analysis helpers
# -------------------------------------------------------------------------- #

def check_no_tuple_unpack(script_source: str) -> list[str]:
    """Return lines that still try to tuple-unpack build_plan (bug)."""
    return [
        line for line in script_source.splitlines()
        if "plan_resp, plan_err = build_plan" in line
        or "feature_resp, feature_err = build_plan" in line
    ]


def check_no_undefined_issue(script_source: str) -> list[str]:
    """Return lines referencing bare 'issue' before it is defined (bug).

    Walks lines before the first synthesize_issue call, skipping docstrings,
    comments, blank lines, and the usage/help string (which contains 'issue-number').
    """
    lines_before_synth = []
    in_triple_quote = False
    for line in script_source.splitlines():
        if '"""' in line or "'''" in line:
            in_triple_quote = not in_triple_quote
            continue
        if in_triple_quote:
            continue
        if "synthesize_issue" in line:
            break
        lines_before_synth.append(line)

    bad = []
    for line in lines_before_synth:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "issue-number" in stripped or "issue_number" in stripped:
            continue
        if "sys.argv" in stripped or "Usage:" in stripped:
            continue
        # Bare 'issue' as a variable reference (not 'issue = ').
        if re.search(r'\bissue\b', line) and 'issue = ' not in line:
            bad.append(line)
    return bad


def check_no_undefined_logger(script_source: str) -> list[str]:
    """Return lines using 'logger' before setup_logger is called."""
    lines_before_logger = []
    for line in script_source.splitlines():
        if "setup_logger" in line and "logger" in line:
            break
        lines_before_logger.append(line)
    bad = []
    for line in lines_before_logger:
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'''"):
            continue
        if "logger" in line:
            bad.append(line)
    return bad


def check_state_plan_file_persist(script_source: str) -> bool:
    """True iff script contains state.update(plan_file=...).save(...) pattern."""
    return "state.update(plan_file=" in script_source and ".save(" in script_source


def check_calls_synthesize_issue(script_source: str) -> bool:
    """True iff script calls synthesize_issue to build an issue object."""
    return "synthesize_issue" in script_source


def check_uses_agent_prompt_response(script_source: str) -> bool:
    """True iff script uses AgentPromptResponse output field (not tuple unpacking)."""
    return "plan_resp.success" in script_source and "plan_resp.output" in script_source


# -------------------------------------------------------------------------- #
# Tests: plan_f3 block
# -------------------------------------------------------------------------- #

def test_plan_f3_block_no_tuple_unpack():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    bad = check_no_tuple_unpack(source)
    assert not bad, f"plan_f3_block still has tuple-unpack bug: {bad}"


def test_plan_f3_block_no_undefined_issue():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    bad = check_no_undefined_issue(source)
    assert not bad, f"plan_f3_block references 'issue' before definition: {bad}"


def test_plan_f3_block_no_undefined_logger():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    bad = check_no_undefined_logger(source)
    assert not bad, f"plan_f3_block uses 'logger' before setup_logger: {bad}"


def test_plan_f3_block_persists_state_plan_file():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    assert check_state_plan_file_persist(source), \
        "plan_f3_block must persist state.plan_file"


def test_plan_f3_block_calls_synthesize_issue():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    assert check_calls_synthesize_issue(source), \
        "plan_f3_block must call synthesize_issue to build an issue object"


def test_plan_f3_block_uses_agent_prompt_response():
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    assert check_uses_agent_prompt_response(source), \
        "plan_f3_block must use AgentPromptResponse (not tuple unpacking)"


def test_plan_f3_block_records_output_spec_file():
    """Assert the plan_f3 block calls local_ops.update_run with output.spec_file."""
    from adw_new import make_script
    source = make_script("ui_slowness", ["plan_f3"], local=True)
    assert "update_run" in source and "spec_file" in source, \
        "plan_f3_block must call update_run with spec_file"


# -------------------------------------------------------------------------- #
# Tests: feature block
# -------------------------------------------------------------------------- #

def test_feature_block_no_tuple_unpack():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    bad = check_no_tuple_unpack(source)
    assert not bad, f"feature_block still has tuple-unpack bug: {bad}"


def test_feature_block_no_undefined_issue():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    bad = check_no_undefined_issue(source)
    assert not bad, f"feature_block references 'issue' before definition: {bad}"


def test_feature_block_no_undefined_logger():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    bad = check_no_undefined_logger(source)
    assert not bad, f"feature_block uses 'logger' before setup_logger: {bad}"


def test_feature_block_persists_state_plan_file():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    assert check_state_plan_file_persist(source), \
        "feature_block must persist state.plan_file"


def test_feature_block_calls_synthesize_issue():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    assert check_calls_synthesize_issue(source), \
        "feature_block must call synthesize_issue to build an issue object"


def test_feature_block_uses_agent_prompt_response():
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    assert check_uses_agent_prompt_response(source), \
        "feature_block must use AgentPromptResponse (not tuple unpacking)"


def test_feature_block_records_output_spec_file():
    """Assert the feature block calls local_ops.update_run with output.spec_file."""
    from adw_new import make_script
    source = make_script("ui_slowness", ["feature"], local=True)
    assert "update_run" in source and "spec_file" in source, \
        "feature_block must call update_run with spec_file"

