#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Regression tests proving adw_ship_iso.py no longer hardcodes the literal
branch name "main": its ship path goes through the shared trunk-aware helper
(adw_modules/merge_ops.py), so a repo whose trunk is `dev` gets `dev` checked
out, pulled, and pushed. Hermetic — subprocess.run is a scripted fake.
"""

import os
import subprocess
import sys

import pytest

# adws/ on path so `adw_modules` and adw_ship_iso import cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

import adw_ship_iso  # noqa: E402
from adw_modules import merge_ops  # noqa: E402
from adw_tests.test_merge_ops import FakeGit, _merge_fake  # noqa: E402

import logging  # noqa: E402

LOGGER = logging.getLogger("test_ship_iso_trunk_detection")


def test_ship_source_has_no_hardcoded_main_git_ops():
    """The old inline manual_merge_to_main (checkout/pull/push 'main') is gone."""
    assert not hasattr(adw_ship_iso, "manual_merge_to_main")
    source_path = os.path.join(ADWS_DIR, "adw_ship_iso.py")
    with open(source_path) as f:
        source = f.read()
    for hardcoded in (
        '"git", "checkout", "main"',
        '"git", "pull", "origin", "main"',
        '"git", "push", "origin", "main"',
    ):
        assert hardcoded not in source
    # Ship delegates to the shared trunk-aware helper.
    assert "merge_branch_into_trunk" in source


def test_merge_to_trunk_uses_detected_trunk_dev(monkeypatch):
    """With trunk detection returning 'dev', ship checks out/pulls/pushes dev."""
    monkeypatch.setattr(merge_ops, "get_trunk_branch", lambda cwd=None: "dev")
    fake = _merge_fake()
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)

    success, merged_sha, error = adw_ship_iso.merge_to_trunk("feature-br", LOGGER)

    assert (success, merged_sha, error) == (True, "abc123def", None)
    assert fake.ran("git", "checkout", "dev")
    assert fake.ran("git", "pull", "origin", "dev")
    assert fake.ran("git", "push", "origin", "dev")
    # And never the literal "main".
    assert not fake.ran("git", "checkout", "main")
    assert not fake.ran("git", "pull", "origin", "main")
    assert not fake.ran("git", "push", "origin", "main")


def test_merge_to_trunk_runs_in_main_repo_root(monkeypatch):
    """Merging happens in the repository root, never inside a worktree."""
    monkeypatch.setattr(merge_ops, "get_trunk_branch", lambda cwd=None: "dev")
    cwds = set()

    def fake(args, **kwargs):
        cwds.add(kwargs.get("cwd"))
        if list(args[:2]) == ["git", "remote"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        return subprocess.CompletedProcess(args, 0, "x\n", "")

    monkeypatch.setattr(merge_ops.subprocess, "run", fake)
    success, _sha, _error = adw_ship_iso.merge_to_trunk("feature-br", LOGGER)
    assert success is True
    assert cwds == {adw_ship_iso.get_main_repo_root()}


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
