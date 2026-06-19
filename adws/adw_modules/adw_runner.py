"""adw_runner — a portable, self-contained ADW step runner (issue-the-adw-gap).

Drives an ordered list of slash-command steps (``/plan``, ``/build``, ``/review``,
``/fix``) through the Claude Agent SDK and reports each lifecycle moment via the
neutral :mod:`adw_emit` contract. The review→fix branch lives here in Python, NOT in
the Elixir engine — keeping the workflow logic portable.

This is deliberately decoupled from the repo's existing ``adw_modules`` (its
DB/websocket harness): the ONLY transport is neutral stdout JSON, so the same script
is consumable by the Elixir orchestrator or any other product.

Runnable on a provisioned host with ``uv`` (Python ≥3.11 + claude-agent-sdk + auth).
If the SDK is unavailable, the runner emits a neutral ``error`` event and exits
non-zero — honoring the contract even on a misconfigured host.
"""

from __future__ import annotations

import argparse
import asyncio
import os
from dataclasses import dataclass
from typing import Any, Callable

from adw_emit import Emitter, emit_mode_selected

# Substrings that mark a slash command the agent could NOT dispatch — it echoed the
# token back as plain text instead of running the project command. Seeing any of these
# in a step's output means the step did NOT execute, so it must report `failed`, never
# `succeeded` (issue-workflow-adw-step). Matched case-insensitively.
NON_EXECUTION_MARKERS = (
    "isn't available in this environment",
    "unknown command",
    "command not found",
)


@dataclass
class Step:
    """One workflow step: a slug plus the slash command to run for it."""

    slug: str
    command: str  # e.g. "/plan", "/build", "/review", "/fix"


@dataclass
class Args:
    prompt: str
    working_dir: str | None
    model: str | None
    adw_id: str
    emit_json: bool


def parse_args(argv: list[str] | None = None) -> Args:
    """Parse the argv contract the Elixir ``Harness.Adw.command/1`` builds."""
    parser = argparse.ArgumentParser(description="Portable ADW workflow runner")
    parser.add_argument("--prompt", required=True, help="The work item / task description.")
    parser.add_argument("--working-dir", dest="working_dir", default=None)
    parser.add_argument("--model", default=None)
    parser.add_argument("--adw-id", dest="adw_id", default="")
    parser.add_argument("--emit", default=None, help="'json' selects the neutral stdout mode.")
    ns, _unknown = parser.parse_known_args(argv)
    return Args(
        prompt=ns.prompt,
        working_dir=ns.working_dir,
        model=ns.model,
        adw_id=ns.adw_id or "adw-local",
        emit_json=emit_mode_selected(argv),
    )


def render(command: str, prompt: str, prior: dict[str, str]) -> str:
    """Build a step's input: the slash command + the task, threading prior step output."""
    parts = [command, prompt]
    if command == "/build" and prior.get("plan"):
        parts.append(f"\n\nPlan:\n{prior['plan']}")
    if command == "/fix" and prior.get("review"):
        parts.append(f"\n\nReview findings to fix:\n{prior['review']}")
    return " ".join(parts)


def command_name(command: str) -> str:
    """The bare command name: strip the leading slash + any arg suffix ('/build x' → 'build')."""
    stripped = command.strip().lstrip("/").split()
    return stripped[0] if stripped else ""


def commands_dir(working_dir: str | None) -> str:
    """The project slash-command directory the SDK resolves commands from."""
    return os.path.join(working_dir or ".", ".claude", "commands")


def missing_commands(steps: list[Step], working_dir: str | None) -> list[str]:
    """Bare names of step commands with no ``<working_dir>/.claude/commands/<name>.md``.

    First-seen order, de-duplicated. This is the pre-flight that converts the silent
    "workflow references a command the runtime doesn't have" failure into a loud one.
    """
    base = commands_dir(working_dir)
    missing: list[str] = []
    seen: set[str] = set()
    for step in steps:
        name = command_name(step.command)
        if not name or name in seen:
            continue
        seen.add(name)
        if not os.path.isfile(os.path.join(base, f"{name}.md")):
            missing.append(name)
    return missing


def _emit_missing_commands(emitter: Emitter, missing: list[str], working_dir: str | None) -> None:
    """Emit the neutral ``error`` event naming the unresolved slash commands."""
    names = ", ".join(f"/{name}" for name in missing)
    emitter.error(
        f"missing slash command(s) in {commands_dir(working_dir)}: {names}",
        reason="spawn_failed",
    )


def has_non_execution_marker(text: str) -> bool:
    """True when ``text`` shows the agent failed to dispatch a slash command."""
    lowered = text.lower()
    return any(marker in lowered for marker in NON_EXECUTION_MARKERS)


async def _run_step(emitter: Emitter, step: Step, prompt: str, args: Args,
                    index: int, total: int, prior: dict[str, str]) -> tuple[str, bool]:
    """Run one step via the SDK, emitting neutral events. Returns (final_text, ok)."""
    started = emitter.step_start(step.slug, index, total)
    final_text = ""
    ok = True

    try:
        # Imported lazily so the contract still works (error event) without the SDK.
        from claude_agent_sdk import (  # type: ignore
            query,
            ClaudeAgentOptions,
            AssistantMessage,
            ResultMessage,
            TextBlock,
            ThinkingBlock,
            ToolUseBlock,
        )

        options = ClaudeAgentOptions(
            cwd=args.working_dir,
            model=args.model,
            permission_mode="bypassPermissions",
            # Load the project's filesystem settings — crucially `.claude/commands/` from
            # the run's cwd — so the custom slash commands (/plan, /build, /review, /fix)
            # resolve. claude-agent-sdk ≥0.1.0 loads NOTHING from disk without this, so
            # without it every slash command is treated as plain text (issue-workflow-adw-step).
            setting_sources=["project"],
        )

        step_cost: float | None = None
        async for message in query(prompt=render(step.command, prompt, prior), options=options):
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        emitter.text(step.slug, block.text)
                        final_text += block.text
                    elif isinstance(block, ThinkingBlock):
                        emitter.text(step.slug, block.thinking, thinking=True)
                    elif isinstance(block, ToolUseBlock):
                        emitter.tool(step.slug, block.name, dict(block.input or {}))
            elif isinstance(message, ResultMessage):
                usage = getattr(message, "usage", {}) or {}
                step_cost = getattr(message, "total_cost_usd", None)
                emitter.usage(
                    step.slug,
                    input_tokens=int(usage.get("input_tokens", 0) or 0),
                    output_tokens=int(usage.get("output_tokens", 0) or 0),
                    cost_usd=step_cost,
                    cache_read=usage.get("cache_read_input_tokens"),
                    cache_creation=usage.get("cache_creation_input_tokens"),
                )
                if getattr(message, "is_error", False):
                    ok = False

        # Defensive backstop: a "command not recognized" reply is a SUCCESSFUL SDK run
        # (the agent produced text), so `is_error` stays False — yet the step did no
        # work. Treat the well-known non-execution markers as a step failure so
        # `step_end` reports `failed`, never a false `succeeded` (issue-workflow-adw-step).
        if has_non_execution_marker(final_text):
            ok = False
            emitter.tool_result(
                step.slug,
                f"step {step.slug}: slash command {step.command} did not dispatch "
                "(non-execution marker in agent output)",
                is_error=True,
            )

        emitter.step_end(step.slug, "succeeded" if ok else "failed",
                         cost_usd=step_cost, started_at=started)
    except Exception as exc:  # noqa: BLE001 — surface any failure as a neutral event
        ok = False
        emitter.tool_result(step.slug, str(exc), is_error=True)
        emitter.step_end(step.slug, "failed", started_at=started)

    return final_text, ok


async def run(
    steps: list[Step],
    args: Args,
    branch: Callable[[str, dict[str, str]], list[Step]] | None = None,
) -> int:
    """Run ``steps`` in order, emitting neutral events. ``branch`` may append steps
    (e.g. review→fix) based on a completed step's output. Returns a process exit code.
    """
    emitter = Emitter(args.adw_id, enabled=args.emit_json)
    emitter.session_started(model=args.model)

    # Pre-flight: every static step's slash command must resolve to a project command
    # file under the TARGET repo's `.claude/commands/`. If any is missing, fail loud and
    # fast with a neutral `error` event — NEVER run steps that would silently "succeed"
    # while doing nothing (issue-workflow-adw-step).
    static_missing = missing_commands(steps, args.working_dir)
    if static_missing:
        _emit_missing_commands(emitter, static_missing, args.working_dir)
        return 1

    prior: dict[str, str] = {}
    queue = list(steps)
    index, ok_all = 0, True

    while index < len(queue):
        step = queue[index]
        total = len(queue)
        final_text, ok = await _run_step(emitter, step, args.prompt, args, index + 1, total, prior)
        prior[step.slug] = final_text
        ok_all = ok_all and ok

        if branch is not None:
            appended = branch(step.slug, prior)
            # Validate branch-appended commands (e.g. review→/fix) before running them,
            # closing the same silent-failure gap on the dynamic path.
            appended_missing = missing_commands(appended, args.working_dir)
            if appended_missing:
                _emit_missing_commands(emitter, appended_missing, args.working_dir)
                return 1
            queue.extend(appended)

        index += 1

    emitter.done(ok=ok_all, reason="success" if ok_all else "error_during_execution",
                 final_text=prior.get(queue[-1].slug) if queue else None)
    return 0 if ok_all else 1


def main(steps: list[Step], branch: Callable[[str, dict[str, str]], list[Step]] | None = None) -> int:
    args = parse_args()
    return asyncio.run(run(steps, args, branch))
