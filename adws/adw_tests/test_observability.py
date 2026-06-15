#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic unit tests for adw_modules/observability.py and its two engine
chokepoint wirings (agent.prompt_claude_code_with_retry, ADWState.save).

Covers the adw.event/1 schema, append-only round-trips, malformed-line
tolerance, fail-silent writes, the ADW_EVENTS_DISABLED kill switch, the
monkeypatched chokepoint wiring, and the repo-root agents/ path guard.
No network, no subprocess.
"""

import json
import os
import sys

import pytest

# adws/ on path so `adw_modules` imports cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

REPO_ROOT = os.path.dirname(ADWS_DIR)

from adw_modules import observability as obs_mod  # noqa: E402
from adw_modules import agent as agent_mod  # noqa: E402
from adw_modules.data_types import (  # noqa: E402
    AgentPromptRequest,
    AgentPromptResponse,
    RetryCode,
)
from adw_modules.state import ADWState  # noqa: E402

EVENT_FIELDS = {
    "schema",
    "ts",
    "adw_id",
    "source",
    "event_type",
    "agent_name",
    "payload",
    "summary",
}


@pytest.fixture(autouse=True)
def _clean_kill_switch(monkeypatch):
    """Ensure the kill switch from the ambient env never leaks into tests."""
    monkeypatch.delenv("ADW_EVENTS_DISABLED", raising=False)


@pytest.fixture
def patched_root(tmp_path, monkeypatch):
    """Redirect ALL default path resolution to a tmp dir.

    Path resolution is module-anchored (state.py get_state_path /
    observability._default_root) — NOT cwd-based — so without this patch the
    wiring tests would pollute the real repo's agents/ directory.
    """
    root = str(tmp_path)
    monkeypatch.setattr(obs_mod, "_default_root", lambda: root)
    monkeypatch.setattr(
        ADWState,
        "get_state_path",
        lambda self: os.path.join(
            root, "agents", self.adw_id, ADWState.STATE_FILENAME
        ),
    )
    return root


# --------------------------------------------------------------------------- #
# (a) emit_event writes exactly one valid adw.event/1 JSON line
# --------------------------------------------------------------------------- #
def test_emit_event_writes_one_valid_schema_line(tmp_path):
    wd = str(tmp_path)
    ok = obs_mod.emit_event(
        "aaaa1111",
        "workflow",
        "phase_started",
        payload={"phase": "plan"},
        agent_name="planner",
        summary="plan phase started",
        working_dir=wd,
    )
    assert ok is True

    path = obs_mod.events_path("aaaa1111", working_dir=wd)
    assert path == os.path.join(wd, "agents", "aaaa1111", "events.jsonl")
    with open(path) as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]
    assert len(lines) == 1

    event = json.loads(lines[0])
    assert set(event.keys()) == EVENT_FIELDS
    assert event["schema"] == "adw.event/1"
    assert event["adw_id"] == "aaaa1111"
    assert event["source"] == "workflow"
    assert event["event_type"] == "phase_started"
    assert event["agent_name"] == "planner"
    assert event["payload"] == {"phase": "plan"}
    assert event["summary"] == "plan phase started"
    # ISO-8601 UTC timestamp
    assert "T" in event["ts"]
    assert event["ts"].endswith("+00:00") or event["ts"].endswith("Z")


def test_emit_event_defaults_payload_and_nullables(tmp_path):
    wd = str(tmp_path)
    assert obs_mod.emit_event("aaaa1111", "agent", "ping", working_dir=wd) is True
    events = obs_mod.read_events("aaaa1111", working_dir=wd)
    assert len(events) == 1
    assert events[0]["payload"] == {}
    assert events[0]["agent_name"] is None
    assert events[0]["summary"] is None


def test_emit_event_nonserializable_payload_falls_back_to_str(tmp_path):
    wd = str(tmp_path)
    payload = {"bad": object()}
    ok = obs_mod.emit_event(
        "aaaa1111", "agent", "weird", payload=payload, working_dir=wd
    )
    assert ok is True
    events = obs_mod.read_events("aaaa1111", working_dir=wd)
    assert len(events) == 1
    # Fallback degrades the payload to its string form; line stays valid JSON.
    assert events[0]["payload"] == str(payload)


def test_emit_event_creates_missing_parent_dir(tmp_path):
    wd = str(tmp_path / "deeper" / "fresh")
    assert not os.path.exists(wd)
    assert obs_mod.emit_event("bbbb2222", "state", "state_saved", working_dir=wd)
    assert os.path.isfile(os.path.join(wd, "agents", "bbbb2222", "events.jsonl"))


# --------------------------------------------------------------------------- #
# (b) read_events round-trips and skips malformed lines
# --------------------------------------------------------------------------- #
def test_read_events_round_trip_appends_in_order(tmp_path):
    wd = str(tmp_path)
    obs_mod.emit_event("cccc3333", "agent", "first", payload={"n": 1}, working_dir=wd)
    obs_mod.emit_event("cccc3333", "agent", "second", payload={"n": 2}, working_dir=wd)
    events = obs_mod.read_events("cccc3333", working_dir=wd)
    assert [e["event_type"] for e in events] == ["first", "second"]
    assert [e["payload"]["n"] for e in events] == [1, 2]


def test_read_events_skips_malformed_lines(tmp_path):
    wd = str(tmp_path)
    obs_mod.emit_event("cccc3333", "agent", "good_one", working_dir=wd)
    path = obs_mod.events_path("cccc3333", working_dir=wd)
    with open(path, "a") as f:
        f.write("{this is not json\n")
        f.write("\n")
    obs_mod.emit_event("cccc3333", "agent", "good_two", working_dir=wd)

    events = obs_mod.read_events("cccc3333", working_dir=wd)
    assert [e["event_type"] for e in events] == ["good_one", "good_two"]


def test_read_events_missing_file_returns_empty_list(tmp_path):
    assert obs_mod.read_events("nope0000", working_dir=str(tmp_path)) == []


# --------------------------------------------------------------------------- #
# (c) fail-silent: unwritable destination returns False, never raises
# --------------------------------------------------------------------------- #
def test_emit_event_path_blocked_by_file_returns_false(tmp_path):
    # A regular file where the root dir should be: makedirs must fail for any
    # user (including root), exercising the fail-silent contract.
    blocker = tmp_path / "blocker"
    blocker.write_text("not a directory")
    ok = obs_mod.emit_event(
        "dddd4444", "agent", "boom", working_dir=str(blocker)
    )
    assert ok is False


@pytest.mark.skipif(
    hasattr(os, "geteuid") and os.geteuid() == 0,
    reason="permission bits do not block root",
)
def test_emit_event_unwritable_dir_returns_false(tmp_path):
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o500)  # r-x: no write
    try:
        ok = obs_mod.emit_event(
            "dddd4444", "agent", "boom", working_dir=str(locked)
        )
        assert ok is False
    finally:
        locked.chmod(0o700)


# --------------------------------------------------------------------------- #
# (d) ADW_EVENTS_DISABLED=1 kill switch
# --------------------------------------------------------------------------- #
def test_kill_switch_suppresses_write_and_returns_false(tmp_path, monkeypatch):
    wd = str(tmp_path)
    monkeypatch.setenv("ADW_EVENTS_DISABLED", "1")
    ok = obs_mod.emit_event("eeee5555", "agent", "nope", working_dir=wd)
    assert ok is False
    assert not os.path.exists(obs_mod.events_path("eeee5555", working_dir=wd))


def test_kill_switch_only_triggers_on_exact_value(tmp_path, monkeypatch):
    wd = str(tmp_path)
    monkeypatch.setenv("ADW_EVENTS_DISABLED", "0")
    assert obs_mod.emit_event("eeee5555", "agent", "yep", working_dir=wd) is True
    assert len(obs_mod.read_events("eeee5555", working_dir=wd)) == 1


# --------------------------------------------------------------------------- #
# (e) chokepoint wiring (engine monkeypatched, paths redirected to tmp)
# --------------------------------------------------------------------------- #
def _make_request(tmp_root: str, adw_id: str) -> AgentPromptRequest:
    return AgentPromptRequest(
        prompt="/test some args",
        adw_id=adw_id,
        agent_name="tester",
        model="sonnet",
        output_file=os.path.join(tmp_root, "raw_output.jsonl"),
    )


def test_wiring_agent_call_start_and_end_events(patched_root, monkeypatch):
    canned = AgentPromptResponse(
        output="done", success=True, session_id="s1", retry_code=RetryCode.NONE
    )
    monkeypatch.setattr(agent_mod, "prompt_claude_code", lambda req: canned)

    request = _make_request(patched_root, "ffff6666")
    response = agent_mod.prompt_claude_code_with_retry(request)
    assert response.success is True

    events = obs_mod.read_events("ffff6666")
    types = [e["event_type"] for e in events]
    assert types == ["agent_call_start", "agent_call_end"]

    start, end = events
    assert start["source"] == "agent"
    assert start["agent_name"] == "tester"
    assert start["payload"]["model"] == "sonnet"
    assert start["payload"]["agent_name"] == "tester"
    assert start["payload"]["command"] == "/test"
    assert start["payload"]["output_file"] == request.output_file

    assert end["source"] == "agent"
    assert end["payload"]["success"] is True
    assert end["payload"]["retry_code"] == "none"
    assert isinstance(end["payload"]["duration_ms"], int)
    assert end["payload"]["duration_ms"] >= 0

    # Events land in the patched tmp root, not the real repo.
    assert obs_mod.events_path("ffff6666").startswith(patched_root)


def test_wiring_agent_call_retry_event(patched_root, monkeypatch):
    monkeypatch.setattr(agent_mod.time, "sleep", lambda s: None)
    responses = [
        AgentPromptResponse(
            output="boom",
            success=False,
            session_id=None,
            retry_code=RetryCode.CLAUDE_CODE_ERROR,
        ),
        AgentPromptResponse(
            output="done", success=True, session_id="s2", retry_code=RetryCode.NONE
        ),
    ]
    monkeypatch.setattr(
        agent_mod, "prompt_claude_code", lambda req: responses.pop(0)
    )

    response = agent_mod.prompt_claude_code_with_retry(
        _make_request(patched_root, "gggg7777")
    )
    assert response.success is True

    events = obs_mod.read_events("gggg7777")
    types = [e["event_type"] for e in events]
    assert types == ["agent_call_start", "agent_call_retry", "agent_call_end"]

    retry = events[1]
    assert retry["payload"]["attempt"] == 1
    assert retry["payload"]["retry_code"] == "claude_code_error"
    assert retry["payload"]["delay"] == 1


def test_wiring_non_command_prompt_has_null_command(patched_root, monkeypatch):
    canned = AgentPromptResponse(
        output="ok", success=True, session_id="s3", retry_code=RetryCode.NONE
    )
    monkeypatch.setattr(agent_mod, "prompt_claude_code", lambda req: canned)

    request = AgentPromptRequest(
        prompt="plain prose prompt",
        adw_id="hhhh8888",
        agent_name="ops",
        output_file=os.path.join(patched_root, "raw_output.jsonl"),
    )
    agent_mod.prompt_claude_code_with_retry(request)

    events = obs_mod.read_events("hhhh8888")
    assert events[0]["payload"]["command"] is None


def test_wiring_state_save_emits_state_saved(patched_root):
    state = ADWState("iiii9999")
    state.update(issue_number="42", branch_name="feat-x")
    state.save("test_step")

    # State file landed in the patched tmp root (proves the patch took).
    assert os.path.isfile(
        os.path.join(patched_root, "agents", "iiii9999", "adw_state.json")
    )

    events = obs_mod.read_events("iiii9999")
    saved = [e for e in events if e["event_type"] == "state_saved"]
    assert len(saved) == 1
    assert saved[0]["source"] == "state"
    assert saved[0]["payload"]["workflow_step"] == "test_step"
    assert saved[0]["payload"]["state"]["adw_id"] == "iiii9999"
    assert saved[0]["payload"]["state"]["issue_number"] == "42"
    assert saved[0]["payload"]["state"]["branch_name"] == "feat-x"


def test_wiring_state_save_survives_emit_failure(patched_root, monkeypatch):
    # emit_event returning False must not break save().
    monkeypatch.setenv("ADW_EVENTS_DISABLED", "1")
    state = ADWState("jjjj0000")
    state.save("test_step")
    assert os.path.isfile(
        os.path.join(patched_root, "agents", "jjjj0000", "adw_state.json")
    )
    assert obs_mod.read_events("jjjj0000") == []


# --------------------------------------------------------------------------- #
# (f) regression guard: default path is repo-root agents/, never adws/agents/
# --------------------------------------------------------------------------- #
def test_default_events_path_resolves_under_repo_root_agents():
    # Path resolution is module-anchored (state.py get_state_path), NOT
    # cwd-based: events land under the checkout root's agents/, matching
    # adw_state.json — never a stray adws/agents/ tree.
    path = obs_mod.events_path("regress1")
    assert path == os.path.join(REPO_ROOT, "agents", "regress1", "events.jsonl")
    assert "/agents/" in path
    assert "/adws/agents/" not in path
    # Mirrors ADWState's resolution exactly: same agents/<adw_id>/ directory.
    assert os.path.dirname(path) == os.path.dirname(
        ADWState("regress1").get_state_path()
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
