#!/usr/bin/env -S uv run
# /// script
# dependencies = ["pytest"]
# ///

"""Hermetic unit tests for adw_modules/adw_runner.py (issue-workflow-adw-step).

No real SDK, network, or subprocess: a fake ``claude_agent_sdk`` module is injected
into ``sys.modules`` so ``_run_step`` drives canned messages, and the neutral event
stream is captured from an in-memory ``Emitter`` stream / pytest's ``capsys``.

Covers the three behaviors the fix guarantees:
  1. pre-flight command-availability fails fast with a neutral ``error`` event;
  2. ``_run_step`` reports ``failed`` on a non-execution marker (false-success guard);
  3. ``ClaudeAgentOptions`` is built with ``setting_sources`` including ``"project"``.
"""

import asyncio
import io
import json
import os
import sys
import types

import pytest

# adw_modules/ on path so `adw_runner` and its `from adw_emit import ...` resolve.
ADW_MODULES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "adw_modules"
)
sys.path.insert(0, ADW_MODULES)

import adw_runner  # noqa: E402
from adw_emit import Emitter  # noqa: E402


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _args(working_dir, emit_json=True):
    return adw_runner.Args(
        prompt="build a thing",
        working_dir=working_dir,
        model="claude-sonnet-4-6",
        adw_id="adw-test",
        emit_json=emit_json,
    )


def _parse_lines(text):
    """Parse a captured JSONL event stream into a list of dicts."""
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def install_fake_sdk(monkeypatch):
    """Inject a fake ``claude_agent_sdk`` and return ``(module, state)``.

    ``state["messages"]`` is the (mutable) list ``query`` yields; ``state["options"]``
    captures the kwargs of every ``ClaudeAgentOptions`` constructed.
    """
    mod = types.ModuleType("claude_agent_sdk")
    state = {"messages": [], "options": []}

    class TextBlock:
        def __init__(self, text):
            self.text = text

    class ThinkingBlock:
        def __init__(self, thinking):
            self.thinking = thinking

    class ToolUseBlock:
        def __init__(self, name, input):  # noqa: A002 — mirror the SDK's attr name
            self.name = name
            self.input = input

    class AssistantMessage:
        def __init__(self, content):
            self.content = content

    class ResultMessage:
        def __init__(self, usage=None, total_cost_usd=None, is_error=False):
            self.usage = usage or {}
            self.total_cost_usd = total_cost_usd
            self.is_error = is_error

    class ClaudeAgentOptions:
        def __init__(self, **kwargs):
            state["options"].append(kwargs)
            self.__dict__.update(kwargs)

    async def query(prompt, options):  # noqa: ARG001 — signature mirrors the SDK
        for message in state["messages"]:
            yield message

    for name, obj in {
        "TextBlock": TextBlock,
        "ThinkingBlock": ThinkingBlock,
        "ToolUseBlock": ToolUseBlock,
        "AssistantMessage": AssistantMessage,
        "ResultMessage": ResultMessage,
        "ClaudeAgentOptions": ClaudeAgentOptions,
        "query": query,
    }.items():
        setattr(mod, name, obj)

    monkeypatch.setitem(sys.modules, "claude_agent_sdk", mod)
    return mod, state


def _commands_dir(tmp_path, *names):
    """Create ``tmp_path/.claude/commands`` and seed ``<name>.md`` for each name."""
    cdir = tmp_path / ".claude" / "commands"
    cdir.mkdir(parents=True)
    for name in names:
        (cdir / f"{name}.md").write_text(f"# /{name}\n")
    return str(tmp_path)


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def test_command_name_strips_slash_and_args():
    assert adw_runner.command_name("/build slice-a") == "build"
    assert adw_runner.command_name("/plan") == "plan"
    assert adw_runner.command_name("  ") == ""


def test_missing_commands_lists_only_absent(tmp_path):
    wd = _commands_dir(tmp_path, "plan", "build")
    steps = [
        adw_runner.Step("plan", "/plan"),
        adw_runner.Step("build", "/build"),
        adw_runner.Step("review", "/review"),
    ]
    assert adw_runner.missing_commands(steps, wd) == ["review"]


def test_has_non_execution_marker_detects_each_marker():
    assert adw_runner.has_non_execution_marker("/plan isn't available in this environment")
    assert adw_runner.has_non_execution_marker("Unknown command: /build")
    assert adw_runner.has_non_execution_marker("bash: command not found")
    assert not adw_runner.has_non_execution_marker("Plan written to specs/foo.md")


# --------------------------------------------------------------------------- #
# (1) Pre-flight: missing command → error event, no step runs, non-zero exit
# --------------------------------------------------------------------------- #
def test_preflight_fails_fast_when_command_missing(tmp_path, capsys):
    # Empty `.claude/commands/` — every step command is unresolved.
    (tmp_path / ".claude" / "commands").mkdir(parents=True)
    steps = [adw_runner.Step("plan", "/plan"), adw_runner.Step("build", "/build")]

    code = asyncio.run(adw_runner.run(steps, _args(str(tmp_path))))

    assert code == 1
    events = _parse_lines(capsys.readouterr().out)
    errors = [e for e in events if e["type"] == "error"]
    assert errors, "expected a neutral error event for the missing commands"
    assert "/plan" in errors[0]["message"]
    assert "/build" in errors[0]["message"]
    assert errors[0]["reason"] == "spawn_failed"
    # Crucially: NO step ran and NOTHING reported success.
    assert not [e for e in events if e["type"] == "step_end"]
    assert not [e for e in events if e["type"] == "step_start"]


def test_preflight_passes_when_commands_present(tmp_path, monkeypatch, capsys):
    wd = _commands_dir(tmp_path, "plan")
    _mod, state = install_fake_sdk(monkeypatch)
    state["messages"] = []  # SDK yields nothing → step completes, succeeds

    code = asyncio.run(adw_runner.run([adw_runner.Step("plan", "/plan")], _args(wd)))

    assert code == 0
    events = _parse_lines(capsys.readouterr().out)
    assert not [e for e in events if e["type"] == "error"]
    [step_end] = [e for e in events if e["type"] == "step_end"]
    assert step_end["status"] == "succeeded"


# --------------------------------------------------------------------------- #
# (2) False-success guard: a non-execution marker → step_end "failed"
# --------------------------------------------------------------------------- #
def test_step_end_failed_on_non_execution_marker(monkeypatch):
    mod, state = install_fake_sdk(monkeypatch)
    state["messages"] = [
        mod.AssistantMessage(
            content=[mod.TextBlock("/plan isn't available in this environment")]
        ),
        mod.ResultMessage(
            usage={"input_tokens": 5, "output_tokens": 3},
            total_cost_usd=0.0,
            is_error=False,  # a "command not found" reply is NOT an SDK error
        ),
    ]

    stream = io.StringIO()
    emitter = Emitter("adw-test", enabled=True, stream=stream)
    step = adw_runner.Step("plan", "/plan")

    final_text, ok = asyncio.run(
        adw_runner._run_step(emitter, step, "build a thing", _args("/tmp"), 1, 1, {})
    )

    assert ok is False
    events = _parse_lines(stream.getvalue())
    [step_end] = [e for e in events if e["type"] == "step_end"]
    assert step_end["status"] == "failed"
    # An observability tool_result marks the non-dispatch.
    assert [e for e in events if e["type"] == "tool_result" and e["is_error"]]


def test_step_end_succeeded_on_real_output(monkeypatch):
    mod, state = install_fake_sdk(monkeypatch)
    state["messages"] = [
        mod.AssistantMessage(content=[mod.TextBlock("Plan written to specs/foo.md")]),
        mod.ResultMessage(usage={"input_tokens": 5, "output_tokens": 3}, total_cost_usd=0.01),
    ]

    stream = io.StringIO()
    emitter = Emitter("adw-test", enabled=True, stream=stream)

    _final_text, ok = asyncio.run(
        adw_runner._run_step(
            emitter, adw_runner.Step("plan", "/plan"), "x", _args("/tmp"), 1, 1, {}
        )
    )

    assert ok is True
    [step_end] = [e for e in _parse_lines(stream.getvalue()) if e["type"] == "step_end"]
    assert step_end["status"] == "succeeded"


# --------------------------------------------------------------------------- #
# (3) setting_sources includes "project"
# --------------------------------------------------------------------------- #
def test_options_built_with_project_setting_source(monkeypatch):
    _mod, state = install_fake_sdk(monkeypatch)
    state["messages"] = []

    stream = io.StringIO()
    emitter = Emitter("adw-test", enabled=True, stream=stream)

    asyncio.run(
        adw_runner._run_step(
            emitter, adw_runner.Step("plan", "/plan"), "x", _args("/tmp/project"), 1, 1, {}
        )
    )

    assert state["options"], "ClaudeAgentOptions was never constructed"
    opts = state["options"][0]
    assert "project" in opts.get("setting_sources", [])
    # cwd stays the target repo so commands resolve from there, not the runner's dir.
    assert opts["cwd"] == "/tmp/project"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
