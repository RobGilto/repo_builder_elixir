#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic tests for run_local_workflow's `ship` step: it must perform a REAL
merge into the detected trunk via merge_ops.merge_branch_into_trunk (mocked
here) and record the outcome (merge_status / merged_sha / merge_error) onto
the adw.run/1 record — no more commit-only no-op.

Mocking conventions follow test_local_ops.py: module-anchored path resolution
is redirected to tmp dirs; no real git/subprocess/worktree.
"""

import logging
import os
import sys

import pytest

# adws/ on path so `adw_modules` imports cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules import local_ops  # noqa: E402
from adw_modules import merge_ops  # noqa: E402
from adw_modules import observability as obs_mod  # noqa: E402
from adw_modules import workflow_ops  # noqa: E402

LOGGER = logging.getLogger("test_workflow_ops_ship")


class FakeState:
    """Minimal ADWState stand-in — never touches the real agents/ dir."""

    def __init__(self, adw_id, *args, **kwargs):
        self.data = {"adw_id": adw_id}

    @classmethod
    def load(cls, adw_id, logger=None):
        return None

    def update(self, **kwargs):
        self.data.update(kwargs)

    def get(self, key, default=None):
        return self.data.get(key, default)

    def append_adw_id(self, adw_id):
        pass

    def save(self, *args, **kwargs):
        pass


@pytest.fixture
def local_root(tmp_path, monkeypatch):
    """Redirect every module-anchored root to a tmp dir (never the repo)."""
    root = str(tmp_path)
    monkeypatch.setattr(local_ops, "_default_root", lambda: root)
    monkeypatch.setattr(obs_mod, "_default_root", lambda: root)
    return root


@pytest.fixture
def wired(local_root, tmp_path, monkeypatch):
    """Wire run_local_workflow's collaborators to hermetic fakes."""
    worktree = str(tmp_path / "worktree")
    os.makedirs(worktree, exist_ok=True)
    monkeypatch.setattr(workflow_ops, "ADWState", FakeState)
    monkeypatch.setattr(
        workflow_ops,
        "_local_setup_worktree",
        lambda adw_id, issue, state, logger: (worktree, "feature-br", 9100, 9200),
    )
    return local_root


def test_ship_step_merges_and_records_result(wired, monkeypatch):
    calls = []

    def fake_merge(branch_name, cwd=None, logger=None):
        calls.append({"branch_name": branch_name, "cwd": cwd})
        return True, "abc123def", None

    monkeypatch.setattr(merge_ops, "merge_branch_into_trunk", fake_merge)

    local_ops.create_run("aaaa1111", "ship_local", "Ship the work")
    workflow_ops.run_local_workflow("aaaa1111", ["ship"], LOGGER)

    # The merge really ran, against the worktree's branch, in the repo root.
    assert len(calls) == 1
    assert calls[0]["branch_name"] == "feature-br"
    assert calls[0]["cwd"] == os.path.dirname(ADWS_DIR)

    # ...and its outcome is recorded on the run record.
    run = local_ops.load_run("aaaa1111")
    assert run["status"] == local_ops.COMPLETED
    assert run["merge_status"] == local_ops.MERGE_MERGED
    assert run["merged_sha"] == "abc123def"
    assert run["merge_error"] is None


def test_ship_step_merge_failure_fails_the_run(wired, monkeypatch):
    monkeypatch.setattr(
        merge_ops,
        "merge_branch_into_trunk",
        lambda branch_name, cwd=None, logger=None: (False, None, "merge conflict"),
    )

    local_ops.create_run("bbbb2222", "ship_local", "Ship the work")
    with pytest.raises(SystemExit):
        workflow_ops.run_local_workflow("bbbb2222", ["ship"], LOGGER)

    run = local_ops.load_run("bbbb2222")
    assert run["status"] == local_ops.FAILED
    assert run["merge_status"] == local_ops.MERGE_FAILED
    assert run["merged_sha"] is None
    assert "merge conflict" in run["merge_error"]
    assert run["error_step"] == "ship"


def test_non_ship_runs_never_touch_merge(wired, monkeypatch):
    def boom(*args, **kwargs):
        raise AssertionError("merge must not run without a ship step")

    monkeypatch.setattr(merge_ops, "merge_branch_into_trunk", boom)
    monkeypatch.setattr(
        workflow_ops,
        "build_plan",
        lambda *a, **k: type("R", (), {"success": False, "output": "stop here"})(),
    )

    local_ops.create_run("cccc3333", "plan_local", "Plan only")
    with pytest.raises(SystemExit):
        workflow_ops.run_local_workflow("cccc3333", ["plan"], LOGGER)

    run = local_ops.load_run("cccc3333")
    assert run["merge_status"] == local_ops.MERGE_UNMERGED


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
