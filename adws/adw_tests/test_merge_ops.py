#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic unit tests for the trunk-aware merge helpers:

- adw_modules/git_ops.py::get_trunk_branch — dynamic trunk detection with the
  documented fallback precedence (symbolic-ref → remote show origin →
  branch --show-current → literal "main" last resort).
- adw_modules/merge_ops.py::merge_branch_into_trunk — trunk merge (success,
  conflict with original-branch restoration, no-origin local-only path).

No real git, no network: subprocess.run is replaced by a scripted fake
(mirrors the mocking conventions of test_local_ops.py — everything hermetic).
"""

import os
import subprocess
import sys

import pytest

# adws/ on path so `adw_modules` imports cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules import git_ops, merge_ops  # noqa: E402


class FakeGit:
    """Scripted subprocess.run stand-in: first matching arg-prefix wins."""

    def __init__(self, spec):
        # spec: list of (prefix_tuple, returncode, stdout, stderr)
        self.spec = spec
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append(list(args))
        for prefix, rc, out, err in self.spec:
            if list(args[: len(prefix)]) == list(prefix):
                return subprocess.CompletedProcess(args, rc, out, err)
        return subprocess.CompletedProcess(args, 0, "", "")

    def ran(self, *prefix):
        return any(c[: len(prefix)] == list(prefix) for c in self.calls)


# --------------------------------------------------------------------------- #
# (a) get_trunk_branch fallback precedence
# --------------------------------------------------------------------------- #
def test_trunk_from_symbolic_ref(monkeypatch):
    fake = FakeGit(
        [(("git", "symbolic-ref"), 0, "refs/remotes/origin/dev\n", "")]
    )
    monkeypatch.setattr(git_ops.subprocess, "run", fake)
    assert git_ops.get_trunk_branch() == "dev"
    # First hit wins — no further probing needed.
    assert not fake.ran("git", "remote", "show")


def test_trunk_falls_back_to_remote_show_origin(monkeypatch):
    remote_show = (
        "* remote origin\n"
        "  Fetch URL: git@example.com:acme/repo.git\n"
        "  HEAD branch: dev\n"
    )
    fake = FakeGit(
        [
            (("git", "symbolic-ref"), 1, "", "fatal: ref refs/remotes/origin/HEAD is not a symbolic ref"),
            (("git", "remote", "show", "origin"), 0, remote_show, ""),
        ]
    )
    monkeypatch.setattr(git_ops.subprocess, "run", fake)
    assert git_ops.get_trunk_branch() == "dev"


def test_trunk_falls_back_to_current_branch_when_no_origin(monkeypatch):
    fake = FakeGit(
        [
            (("git", "symbolic-ref"), 1, "", "fatal: not a symbolic ref"),
            (("git", "remote", "show", "origin"), 1, "", "error: No such remote 'origin'"),
            (("git", "branch", "--show-current"), 0, "dev\n", ""),
        ]
    )
    monkeypatch.setattr(git_ops.subprocess, "run", fake)
    assert git_ops.get_trunk_branch() == "dev"


def test_trunk_last_resort_is_main(monkeypatch):
    fake = FakeGit(
        [
            (("git", "symbolic-ref"), 1, "", "boom"),
            (("git", "remote", "show", "origin"), 1, "", "boom"),
            (("git", "branch", "--show-current"), 0, "", ""),  # detached HEAD
        ]
    )
    monkeypatch.setattr(git_ops.subprocess, "run", fake)
    assert git_ops.get_trunk_branch() == "main"


def test_trunk_passes_cwd_through(monkeypatch):
    seen = []

    def fake(args, **kwargs):
        seen.append(kwargs.get("cwd"))
        return subprocess.CompletedProcess(args, 0, "refs/remotes/origin/dev\n", "")

    monkeypatch.setattr(git_ops.subprocess, "run", fake)
    assert git_ops.get_trunk_branch(cwd="/some/repo") == "dev"
    assert seen == ["/some/repo"]


# --------------------------------------------------------------------------- #
# (b) merge_branch_into_trunk
# --------------------------------------------------------------------------- #
def _merge_fake(remote=True, merge_rc=0, push_rc=0):
    """A FakeGit scripted for the merge sequence against trunk 'dev'."""
    return FakeGit(
        [
            (("git", "remote",), 0, "origin\n" if remote else "", ""),
            (("git", "rev-parse", "--abbrev-ref", "HEAD"), 0, "feature-br\n", ""),
            (("git", "fetch", "origin"), 0, "", ""),
            (("git", "checkout",), 0, "", ""),
            (("git", "pull", "origin"), 0, "", ""),
            (("git", "merge", "--abort"), 0, "", ""),
            (("git", "merge",), merge_rc, "", "CONFLICT (content)" if merge_rc else ""),
            (("git", "rev-parse", "HEAD"), 0, "abc123def\n", ""),
            (("git", "push", "origin"), push_rc, "", "rejected" if push_rc else ""),
        ]
    )


@pytest.fixture
def trunk_dev(monkeypatch):
    monkeypatch.setattr(merge_ops, "get_trunk_branch", lambda cwd=None: "dev")


def test_merge_success_with_remote(trunk_dev, monkeypatch):
    fake = _merge_fake()
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)

    success, merged_sha, error = merge_ops.merge_branch_into_trunk("feature-br")

    assert (success, merged_sha, error) == (True, "abc123def", None)
    assert fake.ran("git", "fetch", "origin")
    assert fake.ran("git", "checkout", "dev")
    assert fake.ran("git", "pull", "origin", "dev")
    assert fake.ran("git", "merge", "feature-br", "--no-ff")
    assert fake.ran("git", "push", "origin", "dev")
    # Original branch restored at the end.
    assert fake.calls[-1][:3] == ["git", "checkout", "feature-br"]


def test_merge_conflict_returns_error_and_restores_branch(trunk_dev, monkeypatch):
    fake = _merge_fake(merge_rc=1)
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)

    success, merged_sha, error = merge_ops.merge_branch_into_trunk("feature-br")

    assert success is False
    assert merged_sha is None
    assert "Failed to merge feature-br" in error
    # Half-applied merge aborted, then original branch restored.
    assert fake.ran("git", "merge", "--abort")
    assert fake.calls[-1][:3] == ["git", "checkout", "feature-br"]
    # Nothing was pushed.
    assert not fake.ran("git", "push")


def test_merge_no_origin_skips_fetch_pull_push(trunk_dev, monkeypatch):
    fake = _merge_fake(remote=False)
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)

    success, merged_sha, error = merge_ops.merge_branch_into_trunk("feature-br")

    assert (success, merged_sha, error) == (True, "abc123def", None)
    assert not fake.ran("git", "fetch")
    assert not fake.ran("git", "pull")
    assert not fake.ran("git", "push")
    assert fake.ran("git", "checkout", "dev")
    assert fake.ran("git", "merge", "feature-br", "--no-ff")


def test_merge_push_failure_restores_branch(trunk_dev, monkeypatch):
    fake = _merge_fake(push_rc=1)
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)

    success, merged_sha, error = merge_ops.merge_branch_into_trunk("feature-br")

    assert success is False
    assert merged_sha is None
    assert "Failed to push to origin/dev" in error
    assert fake.calls[-1][:3] == ["git", "checkout", "feature-br"]


def test_get_head_sha(monkeypatch):
    fake = FakeGit([(("git", "rev-parse", "HEAD"), 0, "abc123\n", "")])
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)
    assert merge_ops.get_head_sha() == "abc123"

    fake = FakeGit([(("git", "rev-parse", "HEAD"), 128, "", "fatal")])
    monkeypatch.setattr(merge_ops.subprocess, "run", fake)
    assert merge_ops.get_head_sha() is None


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
