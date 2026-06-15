#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic unit tests for the local guard in adw_modules/github.py.

Synthetic local issue numbers (>= local_ops.LOCAL_ISSUE_BASE = 9,000,000)
must short-circuit every issue op — no gh, no subprocess, no network — so
the five dependent workflows become dual-mode without per-call-site edits.
Real-looking numbers and non-numeric ids must keep their legacy paths.

subprocess.run is monkeypatched throughout: it FAILS the test if reached on
a synthetic path, and records the call on real paths.
"""

import os
import sys

import pytest

# adws/ on path so `adw_modules` imports cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules import github  # noqa: E402
from adw_modules.data_types import GitHubIssue  # noqa: E402
from adw_modules.local_ops import LOCAL_ISSUE_BASE  # noqa: E402

SYNTHETIC = "9344580"


class _Recorder:
    """Stands in for subprocess.run; records calls, returns a benign result."""

    def __init__(self):
        self.calls = []

    def __call__(self, cmd, *args, **kwargs):
        self.calls.append(cmd)

        class R:
            returncode = 0
            stdout = ""
            stderr = ""

        return R()


@pytest.fixture
def forbid_subprocess(monkeypatch):
    """Any subprocess.run on a synthetic path is a test failure."""

    def _boom(cmd, *args, **kwargs):
        pytest.fail(f"subprocess.run invoked on local path: {cmd}")

    monkeypatch.setattr(github.subprocess, "run", _boom)


@pytest.fixture
def record_subprocess(monkeypatch):
    rec = _Recorder()
    monkeypatch.setattr(github.subprocess, "run", rec)
    return rec


# --------------------------------------------------------------------------- #
# is_local_issue parsing
# --------------------------------------------------------------------------- #
def test_is_local_issue_boundaries():
    assert github.is_local_issue(str(LOCAL_ISSUE_BASE)) is True  # exactly base
    assert github.is_local_issue(SYNTHETIC) is True
    assert github.is_local_issue(f"#{SYNTHETIC}") is True  # leading '#'
    assert github.is_local_issue(int(SYNTHETIC)) is True  # int input
    assert github.is_local_issue(str(LOCAL_ISSUE_BASE - 1)) is False
    assert github.is_local_issue("123") is False


def test_is_local_issue_non_numeric_inert():
    assert github.is_local_issue("abc") is False
    assert github.is_local_issue("it") is False
    assert github.is_local_issue("") is False
    assert github.is_local_issue(None) is False


# --------------------------------------------------------------------------- #
# Synthetic numbers: every issue op short-circuits, gh never invoked
# --------------------------------------------------------------------------- #
def test_make_issue_comment_suppressed_for_synthetic(forbid_subprocess):
    assert github.make_issue_comment(SYNTHETIC, "✅ progress") is None


def test_make_issue_comment_suppressed_with_hash_prefix(forbid_subprocess):
    assert github.make_issue_comment(f"#{SYNTHETIC}", "✅ progress") is None


def test_fetch_issue_synthesizes_placeholder(forbid_subprocess):
    issue = github.fetch_issue(SYNTHETIC, "owner/repo")
    assert isinstance(issue, GitHubIssue)
    assert issue.number == int(SYNTHETIC)
    assert issue.author.login == "local-orchestrator"
    assert issue.state == "OPEN"
    assert issue.title == f"local task #{SYNTHETIC}"


def test_mark_issue_in_progress_noops_for_synthetic(forbid_subprocess):
    assert github.mark_issue_in_progress(SYNTHETIC) is None


# --------------------------------------------------------------------------- #
# Real numbers and non-numeric ids: legacy paths preserved
# --------------------------------------------------------------------------- #
def test_real_issue_comment_reaches_subprocess(record_subprocess, monkeypatch):
    monkeypatch.setattr(
        github, "get_repo_url", lambda: "https://github.com/owner/repo"
    )
    github.make_issue_comment("123", "hello")
    assert any("gh" in cmd for cmd in record_subprocess.calls)


def test_non_numeric_id_follows_legacy_path(record_subprocess, monkeypatch):
    monkeypatch.setattr(
        github, "get_repo_url", lambda: "https://github.com/owner/repo"
    )
    github.make_issue_comment("abc", "hello")
    assert len(record_subprocess.calls) == 1  # guard inert, gh path taken


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
