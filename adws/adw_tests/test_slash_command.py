#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///

"""
Hermetic unit tests for adw_slash_command.py.

Covers the pure helpers (normalize/compose/new_adw_id/build_result), the
--dry-run result shape (asserting the Claude engine is NEVER called), and the
real + error execution paths via a monkeypatched
`prompt_claude_code_with_retry`. No network, no subprocess.
"""

import json
import os
import sys

import pytest

# adws/ on path so `adw_modules` and the runner import cleanly.
ADWS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADWS_DIR)

import adw_slash_command as runner  # noqa: E402
from adw_modules import agent as agent_mod  # noqa: E402
from adw_modules.data_types import AgentPromptResponse, RetryCode  # noqa: E402


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def test_normalize_command_adds_leading_slash():
    assert runner.normalize_command("feature") == "/feature"


def test_normalize_command_keeps_leading_slash():
    assert runner.normalize_command("/feature") == "/feature"


def test_normalize_command_strips_whitespace():
    assert runner.normalize_command("  build  ") == "/build"


def test_normalize_command_empty_raises():
    with pytest.raises(ValueError):
        runner.normalize_command("")
    with pytest.raises(ValueError):
        runner.normalize_command("   ")


def test_compose_prompt_joins_args():
    assert runner.compose_prompt("/feature", ["a", "b"]) == "/feature a b"


def test_compose_prompt_bare_command():
    assert runner.compose_prompt("/prime", []) == "/prime"


def test_new_adw_id_is_8_char_hex_and_distinct():
    a = runner.new_adw_id()
    b = runner.new_adw_id()
    assert len(a) == 8
    assert all(c in "0123456789abcdef" for c in a)
    assert a != b


def test_build_result_shape():
    r = runner.build_result(
        command="/feature",
        args=["x"],
        prompt="/feature x",
        model="sonnet",
        agent_name="ops",
        adw_id="abcd1234",
        working_dir="/repo",
        output_file="/repo/agents/abcd1234/ops/raw_output.jsonl",
        dry_run=True,
    )
    assert r["schema"] == "adw.slash_command.result/1"
    assert r["status"] == "success"
    assert r["dry_run"] is True
    assert r["command"] == "/feature"


# --------------------------------------------------------------------------- #
# Dry-run path: never calls the engine
# --------------------------------------------------------------------------- #
def test_dry_run_result_shape_and_no_engine_call(monkeypatch):
    called = {"n": 0}

    def _boom(*a, **k):
        called["n"] += 1
        raise AssertionError("engine must not be called on --dry-run")

    monkeypatch.setattr(agent_mod, "prompt_claude_code_with_retry", _boom)

    result, code = runner.execute(["/feature", "specs/x.md", "--dry-run", "--json"])

    assert code == 0
    assert called["n"] == 0
    assert result["dry_run"] is True
    assert result["status"] == "success"
    assert result["prompt"] == "/feature specs/x.md"
    assert result["command"] == "/feature"
    assert result["args"] == ["specs/x.md"]
    assert result["session_id"] is None
    assert result["output"] is None


def test_dry_run_normalizes_command():
    result, code = runner.execute(["prime", "--dry-run"])
    assert code == 0
    assert result["command"] == "/prime"
    assert result["prompt"] == "/prime"


def test_dry_run_passthrough_flags_via_remainder():
    result, code = runner.execute(["/build", "--foo", "specs/x.md", "--dry-run"])
    assert code == 0
    # --foo + path pass through as command args; --dry-run is consumed by us.
    assert "--foo" in result["args"]
    assert "specs/x.md" in result["args"]
    assert result["prompt"].startswith("/build")


def test_empty_command_is_usage_error():
    result, code = runner.execute(["", "--dry-run"])
    assert code == 2
    assert result == {}


def test_main_dry_run_json_stdout_purity(capsys):
    code = runner.main(["/feature", "specs/x.md", "--dry-run", "--json"])
    assert code == 0
    captured = capsys.readouterr()
    # stdout is exactly one valid JSON object.
    obj = json.loads(captured.out)
    assert obj["dry_run"] is True
    assert obj["prompt"] == "/feature specs/x.md"
    # No stray non-JSON lines on stdout.
    assert captured.out.strip().count("\n") == 0


# --------------------------------------------------------------------------- #
# Real execution path (engine mocked)
# --------------------------------------------------------------------------- #
def test_real_path_success(monkeypatch):
    monkeypatch.setattr(agent_mod, "check_claude_installed", lambda: None)

    canned = AgentPromptResponse(
        output="done",
        success=True,
        session_id="sess-123",
        retry_code=RetryCode.NONE,
    )
    monkeypatch.setattr(
        agent_mod, "prompt_claude_code_with_retry", lambda req: canned
    )

    result, code = runner.execute(["/feature", "specs/x.md", "--json"])

    assert code == 0
    assert result["status"] == "success"
    assert result["dry_run"] is False
    assert result["session_id"] == "sess-123"
    assert result["retry_code"] == "none"
    assert result["output"] == "done"
    assert result["output_file"].endswith("/ops/raw_output.jsonl")
    # Output lands under the repo-root agents/ (matches agent.execute_template),
    # NOT a stray adws/agents/ tree (issue-i regression guard).
    assert "/agents/" in result["output_file"]
    assert "/adws/agents/" not in result["output_file"]


def test_real_path_error_surfaces_retry_code(monkeypatch):
    monkeypatch.setattr(agent_mod, "check_claude_installed", lambda: None)

    canned = AgentPromptResponse(
        output="boom",
        success=False,
        session_id=None,
        retry_code=RetryCode.CLAUDE_CODE_ERROR,
    )
    monkeypatch.setattr(
        agent_mod, "prompt_claude_code_with_retry", lambda req: canned
    )

    result, code = runner.execute(["/feature", "specs/x.md"])

    assert code == 1
    assert result["status"] == "error"
    assert result["retry_code"] == "claude_code_error"
    assert result["error"]["message"] == "boom"


def test_real_path_honors_explicit_model(monkeypatch):
    monkeypatch.setattr(agent_mod, "check_claude_installed", lambda: None)
    seen = {}

    def _capture(req):
        seen["model"] = req.model
        return AgentPromptResponse(output="ok", success=True, session_id="s")

    monkeypatch.setattr(agent_mod, "prompt_claude_code_with_retry", _capture)

    result, code = runner.execute(["/review", "--model", "opus"])
    assert code == 0
    assert seen["model"] == "opus"
    assert result["model"] == "opus"


def test_real_path_missing_claude_is_error(monkeypatch):
    monkeypatch.setattr(
        agent_mod, "check_claude_installed", lambda: "Error: not installed"
    )
    # Engine must not be reached when install check fails.
    monkeypatch.setattr(
        agent_mod,
        "prompt_claude_code_with_retry",
        lambda req: (_ for _ in ()).throw(AssertionError("should not run")),
    )

    result, code = runner.execute(["/feature", "x"])
    assert code == 1
    assert result["status"] == "error"
    assert "not installed" in result["error"]["message"]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
