#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic unit tests for adw_modules/local_ops.py — the local launch contract
(adw.run/1 records, status/timing semantics, step events, issue synthesis).

No network, no subprocess, no gh. All path resolution is redirected to tmp
dirs (the resolution is module-anchored, mirroring observability — see the
patched_root fixture in test_observability.py this copies).
"""

import json
import os
import sys

import pytest

# adws/ on path so `adw_modules` imports cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

from adw_modules import local_ops  # noqa: E402
from adw_modules import observability as obs_mod  # noqa: E402
from adw_modules.data_types import GitHubIssue  # noqa: E402

RUN_FIELDS = {
    "schema", "adw_id", "workflow_type", "status", "current_step",
    "total_steps", "completed_steps", "created_at", "started_at",
    "completed_at", "duration_seconds", "input_data", "output_data",
    "error_message", "error_step",
}


@pytest.fixture(autouse=True)
def _clean_kill_switch(monkeypatch):
    monkeypatch.delenv("ADW_EVENTS_DISABLED", raising=False)


@pytest.fixture
def wd(tmp_path):
    """Explicit tmp root passed as working_dir — never the real repo."""
    return str(tmp_path)


# --------------------------------------------------------------------------- #
# (a) run record round-trip + schema + atomic save
# --------------------------------------------------------------------------- #
def test_create_run_writes_full_schema(wd):
    run = local_ops.create_run(
        "aaaa1111", "plan_build_local", "Build a hello endpoint",
        model="sonnet", working_dir=wd,
    )
    assert set(run.keys()) == RUN_FIELDS
    assert run["schema"] == "adw.run/1"
    assert run["status"] == "pending"
    assert run["total_steps"] == 2 and run["completed_steps"] == 0
    assert run["started_at"] is None and run["completed_at"] is None
    assert run["input_data"]["prompt"] == "Build a hello endpoint"
    assert run["input_data"]["model"] == "sonnet"
    assert run["input_data"]["issue_number"] is None

    path = local_ops.run_path("aaaa1111", working_dir=wd)
    assert path == os.path.join(wd, "agents", "aaaa1111", "run.json")
    with open(path) as f:
        on_disk = json.load(f)
    assert on_disk == run
    assert local_ops.load_run("aaaa1111", working_dir=wd) == run


def test_load_run_absent_and_corrupt_return_none(wd):
    assert local_ops.load_run("missing0", working_dir=wd) is None
    path = local_ops.run_path("badbad00", working_dir=wd)
    os.makedirs(os.path.dirname(path))
    with open(path, "w") as f:
        f.write("{not json")
    assert local_ops.load_run("badbad00", working_dir=wd) is None


def test_save_run_is_atomic_no_tmp_residue(wd):
    local_ops.create_run("aaaa1111", "plan_build_local", "p", working_dir=wd)
    run_dir = os.path.join(wd, "agents", "aaaa1111")
    # Atomic save leaves exactly the final file — no .run-*.tmp residue.
    assert sorted(os.listdir(run_dir)) == ["events.jsonl", "run.json"] or \
        sorted(os.listdir(run_dir)) == ["run.json"]


def test_save_run_failure_returns_false_never_raises(tmp_path):
    blocker = tmp_path / "blocker"
    blocker.write_text("not a directory")
    ok = local_ops.save_run(
        {"adw_id": "x"}, working_dir=str(blocker)
    )
    assert ok is False


# --------------------------------------------------------------------------- #
# (b) update_run: tac-14 status/timing semantics
# --------------------------------------------------------------------------- #
def test_in_progress_sets_started_at_exactly_once(wd):
    local_ops.create_run("bbbb2222", "plan_build_local", "p", working_dir=wd)
    run = local_ops.update_run("bbbb2222", status="in_progress", working_dir=wd)
    first_started = run["started_at"]
    assert first_started is not None
    run = local_ops.update_run("bbbb2222", status="in_progress", working_dir=wd)
    assert run["started_at"] == first_started  # set once, never overwritten


def test_terminal_status_sets_completed_at_and_duration(wd):
    local_ops.create_run("bbbb2222", "plan_build_local", "p", working_dir=wd)
    local_ops.update_run("bbbb2222", status="in_progress", working_dir=wd)
    run = local_ops.update_run("bbbb2222", status="completed", working_dir=wd)
    assert run["completed_at"] is not None
    assert isinstance(run["duration_seconds"], float)
    assert run["duration_seconds"] >= 0


def test_failed_records_error_fields(wd):
    local_ops.create_run("cccc3333", "plan_build_local", "p", working_dir=wd)
    run = local_ops.update_run(
        "cccc3333", status="failed",
        error_message="boom", error_step="plan", working_dir=wd,
    )
    assert run["status"] == "failed"
    assert run["error_message"] == "boom" and run["error_step"] == "plan"
    assert run["completed_at"] is not None


def test_update_run_invalid_status_raises(wd):
    local_ops.create_run("cccc3333", "plan_build_local", "p", working_dir=wd)
    with pytest.raises(ValueError):
        local_ops.update_run("cccc3333", status="exploded", working_dir=wd)


def test_update_run_missing_record_returns_none(wd):
    assert local_ops.update_run("nope0000", status="failed", working_dir=wd) is None


def test_update_run_merges_output_data(wd):
    local_ops.create_run("dddd4444", "plan_build_local", "p", working_dir=wd)
    local_ops.update_run(
        "dddd4444", output={"spec_file": "specs/x.md"}, working_dir=wd
    )
    run = local_ops.update_run(
        "dddd4444", output={"branch": "feat-x"}, working_dir=wd
    )
    assert run["output_data"]["spec_file"] == "specs/x.md"
    assert run["output_data"]["branch"] == "feat-x"


def test_update_run_emits_run_updated_event_with_changed_fields(wd):
    local_ops.create_run("eeee5555", "plan_build_local", "p", working_dir=wd)
    local_ops.update_run(
        "eeee5555", status="in_progress", current_step="plan", working_dir=wd
    )
    events = obs_mod.read_events("eeee5555", working_dir=wd)
    updated = [e for e in events if e["event_type"] == "run_updated"]
    assert len(updated) == 1
    assert updated[0]["source"] == "workflow"
    assert updated[0]["payload"]["status"] == "in_progress"
    assert updated[0]["payload"]["current_step"] == "plan"
    assert "started_at" in updated[0]["payload"]


# --------------------------------------------------------------------------- #
# (c) step events land in events.jsonl (swimlane grouping markers)
# --------------------------------------------------------------------------- #
def test_step_start_end_events(wd):
    local_ops.step_start("ffff6666", "plan", working_dir=wd)
    local_ops.step_end("ffff6666", "plan", "completed", duration_ms=1234, working_dir=wd)
    events = obs_mod.read_events("ffff6666", working_dir=wd)
    assert [e["event_type"] for e in events] == ["step_start", "step_end"]
    start, end = events
    assert start["source"] == "workflow"
    assert start["payload"]["step"] == "plan"
    assert end["payload"] == {"step": "plan", "status": "completed", "duration_ms": 1234}
    assert all(e["schema"] == "adw.event/1" for e in events)


# --------------------------------------------------------------------------- #
# (d) synthesize_issue: valid GitHubIssue, minimal serialization, stability
# --------------------------------------------------------------------------- #
def _run_dict(adw_id="a1b2c3d4", prompt="Add a /health endpoint\nwith JSON body",
              issue_number=None):
    return {
        "adw_id": adw_id,
        "input_data": {"prompt": prompt, "issue_number": issue_number},
    }


def test_synthesized_issue_validates_and_serializes_minimal_payload():
    issue = local_ops.synthesize_issue(_run_dict())
    assert isinstance(issue, GitHubIssue)
    assert issue.state == "OPEN"
    assert issue.title == "Add a /health endpoint"
    assert issue.body == "Add a /health endpoint\nwith JSON body"
    # The only serialization downstream ops perform:
    minimal = json.loads(
        issue.model_dump_json(by_alias=True, include={"number", "title", "body"})
    )
    assert set(minimal.keys()) == {"number", "title", "body"}
    assert isinstance(minimal["number"], int)


def test_local_issue_number_is_numeric_and_stable():
    n1 = local_ops.local_issue_number("a1b2c3d4")
    n2 = local_ops.local_issue_number("a1b2c3d4")
    assert n1 == n2  # stable across calls
    assert n1 >= local_ops.LOCAL_ISSUE_BASE  # never collides with real issues
    assert local_ops.local_issue_number("ffffffff") != n1


def test_real_issue_number_passes_through():
    issue = local_ops.synthesize_issue(_run_dict(issue_number=42))
    assert issue.number == 42


def test_title_sanitizes_quotes_newlines_and_caps_length():
    prompt = '  "Build the \'thing\'"  \nrest of body'
    issue = local_ops.synthesize_issue(_run_dict(prompt=prompt))
    assert "\n" not in issue.title
    assert not issue.title.startswith('"') and not issue.title.endswith('"')
    long_prompt = "x" * 300
    issue = local_ops.synthesize_issue(_run_dict(prompt=long_prompt))
    assert len(issue.title) == 80 and issue.title.endswith("...")
    assert issue.body == long_prompt  # body always verbatim


def test_empty_prompt_gets_placeholder_title():
    issue = local_ops.synthesize_issue(_run_dict(prompt="   \n  "))
    assert issue.title == "local task a1b2c3d4"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
