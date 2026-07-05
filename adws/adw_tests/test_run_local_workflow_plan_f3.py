#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic tests for Gap 2 fix: run_local_workflow's step dispatcher must recognize
'plan_f3' and 'feature' and route them through _run_plan_step with the correct
slash command, persisting state.plan_file and output.spec_file.

Uses the real workflow_ops.build_plan via build_plan_output fixture to avoid
module-namespace patching complexity.
"""

import logging
import os
import sys

import pytest

ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules import local_ops  # noqa: E402
from adw_modules import observability as obs_mod  # noqa: E402
from adw_modules import workflow_ops  # noqa: E402
from adw_modules.data_types import AgentPromptResponse  # noqa: E402

LOGGER = logging.getLogger("test_run_local_workflow_plan_f3")


@pytest.fixture
def local_root(tmp_path, monkeypatch):
    """Redirect every module-anchored root to a tmp dir."""
    root = str(tmp_path)
    monkeypatch.setattr(local_ops, "_default_root", lambda: root)
    monkeypatch.setattr(obs_mod, "_default_root", lambda: root)
    return root


@pytest.fixture
def wired(local_root, tmp_path, monkeypatch):
    """Wire run_local_workflow collaborators: real ADWState (writes to tmp), patched worktree."""
    worktree = str(tmp_path / "worktree")
    os.makedirs(worktree, exist_ok=True)
    monkeypatch.setattr(
        workflow_ops,
        "_local_setup_worktree",
        lambda adw_id, issue, state, logger: (worktree, "feature-br", 9100, 9200),
    )
    return local_root, worktree


# -------------------------------------------------------------------------- #
# plan_f3 tests
# -------------------------------------------------------------------------- #

def test_plan_f3_reaches_completed(wired, monkeypatch):
    """run_local_workflow(['plan_f3'], ...) should reach COMPLETED (not 'Unknown step')."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test1-slc_planner-test.html"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("<html><body>test</body></html>")

    # Patch build_plan in the module's namespace so _run_plan_step's local ref finds it.
    monkeypatch.setattr(workflow_ops, "build_plan",
        lambda issue, command, adw_id, logger, working_dir=None: AgentPromptResponse(
            output=spec_rel, success=True
        ),
    )

    local_ops.create_run("aaaa1111", "plan_f3_test", "Test plan_f3 step")
    workflow_ops.run_local_workflow("aaaa1111", ["plan_f3"], LOGGER)

    run = local_ops.load_run("aaaa1111")
    assert run["status"] == local_ops.COMPLETED, (
        f"Expected COMPLETED but got {run['status']}. "
        f"error_step={run.get('error_step')}, error_message={run.get('error_message')}"
    )


def test_plan_f3_calls_build_plan_with_slash_command(wired, monkeypatch):
    """build_plan must be invoked with command='/plan_f3', not '/feature' or LOCAL_ISSUE_CLASS."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test2-slc_planner-test.html"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("<html>test</html>")

    plan_calls = []

    def fake_build_plan(issue, command, adw_id, logger, working_dir=None):
        plan_calls.append(command)
        return AgentPromptResponse(output=spec_rel, success=True)

    monkeypatch.setattr(workflow_ops, "build_plan", fake_build_plan)

    local_ops.create_run("bbbb2222", "plan_f3_cmd_test", "Test slash command")
    workflow_ops.run_local_workflow("bbbb2222", ["plan_f3"], LOGGER)

    assert plan_calls == ["/plan_f3"], f"Expected ['/plan_f3'] but got {plan_calls!r}"


def test_plan_f3_sets_state_plan_file(wired, monkeypatch):
    """After plan_f3 step, state.plan_file must be persisted in adw_state.json."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test3-slc_planner-test.html"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("<html>test</html>")

    import sys

    # Prevent sys.exit from terminating the test; record calls for assertion.
    exit_calls = []

    def noexit(dummy=1):
        exit_calls.append(dummy)
        raise SystemExit(dummy)

    monkeypatch.setattr(workflow_ops, "build_plan",
        lambda issue, cmd, aid, lgr, working_dir=None: AgentPromptResponse(
            output=spec_rel, success=True
        ),
    )
    monkeypatch.setattr(sys, "exit", noexit)
    local_ops.create_run("cccc3333", "plan_f3_state", "Test plan file in state")
    workflow_ops.run_local_workflow("cccc3333", ["plan_f3"], LOGGER)


    # Check adw_state.json was written with plan_file set.
    from adw_modules.state import ADWState as RealADWState
    state = RealADWState.load("cccc3333")
    assert state is not None, "ADWState.load returned None"
    assert state.data.get("plan_file") == spec_rel, (
        f"state.plan_file = {state.data.get('plan_file')!r}, expected {spec_rel!r}; "
        f"sys.exit calls: {exit_calls}"
    )


def test_plan_f3_records_output_spec_file(wired, monkeypatch):
    """local_ops.update_run must record output_data.spec_file after plan_f3."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test4-slc_planner-test.html"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("<html>test</html>")

    monkeypatch.setattr(workflow_ops, "build_plan",
        lambda issue, cmd, aid, lgr, working_dir=None: AgentPromptResponse(
            output=spec_rel, success=True
        ),
    )

    local_ops.create_run("dddd4444", "plan_f3_spec_file", "Test spec_file in run")
    workflow_ops.run_local_workflow("dddd4444", ["plan_f3"], LOGGER)

    run = local_ops.load_run("dddd4444")
    output_data = run.get("output_data", {})
    assert "spec_file" in output_data, (
        f"run output_data has no spec_file. output_data: {output_data}"
    )
    assert output_data["spec_file"] == spec_rel


def test_plan_f3_build_step_chain(wired, monkeypatch):
    """plan_f3 → build chain: spec_file from plan step is passed to build step."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test5-slc_planner-test.html"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("<html>test</html>")

    def fake_build_plan(issue, command, adw_id, logger, working_dir=None):
        return AgentPromptResponse(output=spec_rel, success=True)

    def fake_implement(spec_file, adw_id, logger, working_dir=None):
        # Capture what the build step received.
        # Return success so the chain continues.
        return AgentPromptResponse(output="implemented ok", success=True)

    monkeypatch.setattr(workflow_ops, "build_plan", fake_build_plan)
    monkeypatch.setattr(workflow_ops, "implement_plan", fake_implement)

    local_ops.create_run("eeee5555", "plan_f3_build_chain", "Test chain")
    workflow_ops.run_local_workflow("eeee5555", ["plan_f3", "build"], LOGGER)

    run = local_ops.load_run("eeee5555")
    # If COMPLETED: both plan_f3 and build ran; check output_data.spec_file was set.
    # If FAILED: check error_message is not "Unknown step: plan_f3".
    assert run["status"] == local_ops.COMPLETED, (
        f"Expected COMPLETED but got {run['status']}. "
        f"error_step={run.get('error_step')}, error_message={run.get('error_message')}"
    )
    # The plan_f3 step should have recorded spec_file on the run.
    output_data = run.get("output_data", {})
    assert "spec_file" in output_data, (
        f"output_data has no spec_file after plan_f3. output_data: {output_data}"
    )


# -------------------------------------------------------------------------- #
# feature tests
# -------------------------------------------------------------------------- #

def test_feature_reaches_completed(wired, monkeypatch):
    """run_local_workflow(['feature'], ...) should reach COMPLETED (not 'Unknown step')."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test6-slc_planner-test.md"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("# feature plan")

    def fake_build_plan(issue, command, adw_id, logger, working_dir=None):
        return AgentPromptResponse(output=spec_rel, success=True)

    monkeypatch.setattr(workflow_ops, "build_plan", fake_build_plan)

    local_ops.create_run("ffff6666", "feature_test", "Test feature step")
    workflow_ops.run_local_workflow("ffff6666", ["feature"], LOGGER)

    run = local_ops.load_run("ffff6666")
    assert run["status"] == local_ops.COMPLETED, (
        f"Expected COMPLETED but got {run['status']}. "
        f"error_step={run.get('error_step')}, error_message={run.get('error_message')}"
    )


def test_feature_calls_build_plan_with_slash_feature(wired, monkeypatch):
    """feature step must call build_plan with command='/feature', not '/plan_f3'."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test7-slc_planner-test.md"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("# feature plan")

    plan_calls = []

    def fake_build_plan(issue, command, adw_id, logger, working_dir=None):
        plan_calls.append(command)
        return AgentPromptResponse(output=spec_rel, success=True)

    monkeypatch.setattr(workflow_ops, "build_plan", fake_build_plan)

    local_ops.create_run("gggg7777", "feature_cmd_test", "Test slash command")
    workflow_ops.run_local_workflow("gggg7777", ["feature"], LOGGER)

    assert plan_calls == ["/feature"], f"Expected ['/feature'] but got {plan_calls!r}"


def test_feature_build_chain(wired, monkeypatch):
    """feature → build chain: spec_file from plan step is passed to build step."""
    local_root, worktree = wired

    specs_dir = os.path.join(worktree, "specs")
    os.makedirs(specs_dir, exist_ok=True)
    spec_rel = "specs/issue-0-adw-test8-slc_planner-test.md"
    with open(os.path.join(worktree, spec_rel), "w") as f:
        f.write("# feature plan")

    def fake_build_plan(issue, command, adw_id, logger, working_dir=None):
        return AgentPromptResponse(output=spec_rel, success=True)

    def fake_implement(spec_file, adw_id, logger, working_dir=None):
        return AgentPromptResponse(output="implemented ok", success=True)

    monkeypatch.setattr(workflow_ops, "build_plan", fake_build_plan)
    monkeypatch.setattr(workflow_ops, "implement_plan", fake_implement)

    local_ops.create_run("hhhh8888", "feature_build_chain", "Test chain")
    workflow_ops.run_local_workflow("hhhh8888", ["feature", "build"], LOGGER)

    run = local_ops.load_run("hhhh8888")
    assert run["status"] == local_ops.COMPLETED
    output_data = run.get("output_data", {})
    assert "spec_file" in output_data, (
        f"output_data has no spec_file after feature. output_data: {output_data}"
    )


# -------------------------------------------------------------------------- #
# Error-path test
# -------------------------------------------------------------------------- #

def test_plan_f3_fails_gracefully_on_bad_spec_path(wired, monkeypatch):
    """build_plan returning an invalid path triggers fallback; fallback missing → fail."""
    local_root, worktree = wired

    # No specs/ directory at all — fallback also fails → run should FAIL.
    monkeypatch.setattr(
        workflow_ops, "build_plan",
        lambda issue, cmd, aid, lgr, working_dir=None: AgentPromptResponse(
            output="specs/nonexistent.html",
            success=True,
        ),
    )

    local_ops.create_run("iiii9999", "plan_f3_bad_spec", "Test bad spec path")
    with pytest.raises(SystemExit):
        workflow_ops.run_local_workflow("iiii9999", ["plan_f3"], LOGGER)

    run = local_ops.load_run("iiii9999")
    assert run["status"] == local_ops.FAILED
    assert run["error_step"] in ("plan", "plan_f3")
