#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""
ADW Slash Command - friendly one-shot slash-command runner

Fire a SINGLE slash command (with arguments) through Claude Code's headless
(programmable) mode. No GitHub issue, no git worktree, no ADW state - the
lowest-ceremony path in adws/. It reuses the existing execution engine
(`prompt_claude_code_with_retry`) so retry, JSONL parsing, prompt logging, and
`--dangerously-skip-permissions` all come for free.

Usage:
  uv run adws/adw_slash_command.py <command> [args...] \\
    [--model sonnet|opus] [--agent-name NAME] [--adw-id ID] \\
    [--working-dir PATH] [--json] [--dry-run]

  <command>   slash command to run, e.g. /feature or feature (a leading
              '/' is added if missing).
  [args...]   trailing arguments joined with spaces as the command argument
              string (e.g. specs/issue-g-….md). Flags/paths meant for the
              command pass through verbatim.

Flags:
  --model        sonnet (default) or opus. The explicit value always wins.
  --agent-name   output/log agent name (default: ops).
  --adw-id       8-char id for the output/log dir (default: fresh uuid hex).
  --working-dir  working directory for the run (default: repo root).
  --json         emit the structured result as the only thing on stdout
                 (logs go to stderr) so `… --json | jq` is clean.
  --dry-run      compose the prompt + request and print the would-be result;
                 NEVER invokes Claude (hermetic, offline). Exits 0.

Examples:
  uv run adws/adw_slash_command.py /feature "specs/x.md"
  uv run adws/adw_slash_command.py /build specs/issue-g-….md --json
  uv run adws/adw_slash_command.py prime --dry-run --json
"""

import argparse
import json
import logging
import os
import sys
import uuid
from typing import List, Optional, Tuple

from dotenv import load_dotenv

load_dotenv()

# __file__ lives in adws/, so ADWS_DIR is that dir and REPO_ROOT is its parent.
# Run output goes under the repo-root agents/ tree (agents/<adw_id>/<agent>/...),
# matching the convention in agent.execute_template (which resolves project_root
# to the repo root, not adws/).
ADWS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(ADWS_DIR)

RESULT_SCHEMA = "adw.slash_command.result/1"

# Logs go to stderr so stdout stays pure for --json piping.
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("adw_slash_command")


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def normalize_command(command: str) -> str:
    """Normalize a slash command: strip, prepend '/' if missing, reject empty."""
    cmd = (command or "").strip()
    if not cmd:
        raise ValueError("command must not be empty")
    if not cmd.startswith("/"):
        cmd = "/" + cmd
    return cmd


def compose_prompt(command: str, args: List[str]) -> str:
    """Compose the prompt from a (normalized) command and its argument list."""
    parts = [command, *[a for a in args if a != ""]]
    return " ".join(parts).strip()


def new_adw_id() -> str:
    """Generate a fresh 8-char hex ADW id (matches the ADW id format)."""
    return uuid.uuid4().hex[:8]


def output_file_for(adw_id: str, agent_name: str, project_root: str) -> str:
    """Build the raw_output.jsonl path (agents/<adw_id>/<agent>/...)."""
    return os.path.join(
        project_root, "agents", adw_id, agent_name, "raw_output.jsonl"
    )


def is_known_command(command: str) -> bool:
    """Best-effort check: is this command in the ADW SlashCommand registry?

    Returns False if the registry can't be imported - this runner is general
    and never gates on registry membership.
    """
    try:
        from typing import get_args

        from adw_modules.data_types import SlashCommand

        return command in get_args(SlashCommand)
    except Exception:
        return False


def build_result(
    *,
    command: str,
    args: List[str],
    prompt: str,
    model: str,
    agent_name: str,
    adw_id: str,
    working_dir: str,
    output_file: str,
    dry_run: bool,
    status: str = "success",
    session_id: Optional[str] = None,
    retry_code: str = "none",
    output: Optional[str] = None,
    error: Optional[dict] = None,
) -> dict:
    """Assemble the structured result object (adw.slash_command.result/1)."""
    return {
        "schema": RESULT_SCHEMA,
        "status": status,
        "command": command,
        "args": list(args),
        "prompt": prompt,
        "model": model,
        "agent_name": agent_name,
        "adw_id": adw_id,
        "working_dir": working_dir,
        "dry_run": dry_run,
        "output_file": output_file,
        "session_id": session_id,
        "retry_code": retry_code,
        "output": output,
        "error": error,
    }


# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="adw_slash_command.py",
        description="Run a single slash command through Claude Code headless mode.",
        add_help=True,
    )
    parser.add_argument("command", help="slash command, e.g. /feature or feature")
    parser.add_argument(
        "--model",
        choices=["sonnet", "opus"],
        default="sonnet",
        help="model to use (default: sonnet)",
    )
    parser.add_argument(
        "--agent-name", default="ops", help="output/log agent name (default: ops)"
    )
    parser.add_argument(
        "--adw-id", default=None, help="8-char id for the output dir (default: fresh)"
    )
    parser.add_argument(
        "--working-dir", default=None, help="working directory (default: repo root)"
    )
    parser.add_argument(
        "--json",
        dest="as_json",
        action="store_true",
        help="emit the structured result as JSON on stdout (logs to stderr)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="compose only; never invoke Claude (offline, exit 0)",
    )
    return parser


def parse_args(argv: List[str]) -> Tuple[argparse.Namespace, List[str]]:
    """Parse our flags; trailing/unknown tokens become the command args.

    `parse_known_args` lets our flags appear AFTER the command + its args
    (e.g. `/feature specs/x.md --dry-run --json`) while still passing through
    arbitrary flags/paths intended for the command itself (e.g. `--foo`).
    """
    parser = build_parser()
    ns, extra = parser.parse_known_args(argv)
    return ns, extra


# --------------------------------------------------------------------------- #
# Core
# --------------------------------------------------------------------------- #
def execute(argv: List[str]) -> Tuple[dict, int]:
    """Run the CLI logic. Returns (result, exit_code). Does not print."""
    ns, extra = parse_args(argv)

    # Normalize the command (empty -> usage error, exit 2).
    try:
        command = normalize_command(ns.command)
    except ValueError as e:
        logger.error("Error: %s", e)
        return {}, 2

    args: List[str] = list(extra)
    prompt = compose_prompt(command, args)
    model = ns.model
    agent_name = ns.agent_name
    adw_id = ns.adw_id or new_adw_id()
    working_dir = os.path.abspath(ns.working_dir) if ns.working_dir else REPO_ROOT
    output_file = output_file_for(adw_id, agent_name, REPO_ROOT)

    if not is_known_command(command):
        logger.info(
            "Note: %s is not in the ADW SlashCommand registry; running anyway.",
            command,
        )

    # --- dry-run: compose only, never touch the engine -------------------- #
    if ns.dry_run:
        logger.info("[dry-run] would run: %s (model=%s)", prompt, model)
        result = build_result(
            command=command,
            args=args,
            prompt=prompt,
            model=model,
            agent_name=agent_name,
            adw_id=adw_id,
            working_dir=working_dir,
            output_file=output_file,
            dry_run=True,
            status="success",
            session_id=None,
            retry_code="none",
            output=None,
            error=None,
        )
        return result, 0

    # --- real execution path ---------------------------------------------- #
    from adw_modules.agent import (
        check_claude_installed,
        prompt_claude_code_with_retry,
    )
    from adw_modules.data_types import AgentPromptRequest

    install_error = check_claude_installed()
    if install_error:
        logger.error(install_error)
        result = build_result(
            command=command,
            args=args,
            prompt=prompt,
            model=model,
            agent_name=agent_name,
            adw_id=adw_id,
            working_dir=working_dir,
            output_file=output_file,
            dry_run=False,
            status="error",
            session_id=None,
            retry_code="none",
            output=None,
            error={"message": install_error},
        )
        return result, 1

    logger.info("Running %s (model=%s, adw_id=%s)", prompt, model, adw_id)

    request = AgentPromptRequest(
        prompt=prompt,
        adw_id=adw_id,
        agent_name=agent_name,
        model=model,
        dangerously_skip_permissions=True,
        output_file=output_file,
        working_dir=working_dir,
    )

    response = prompt_claude_code_with_retry(request)
    retry_code = (
        response.retry_code.value
        if hasattr(response.retry_code, "value")
        else str(response.retry_code)
    )

    if response.success:
        result = build_result(
            command=command,
            args=args,
            prompt=prompt,
            model=model,
            agent_name=agent_name,
            adw_id=adw_id,
            working_dir=working_dir,
            output_file=output_file,
            dry_run=False,
            status="success",
            session_id=response.session_id,
            retry_code=retry_code,
            output=response.output,
            error=None,
        )
        return result, 0

    logger.error("Run failed (retry_code=%s): %s", retry_code, response.output)
    result = build_result(
        command=command,
        args=args,
        prompt=prompt,
        model=model,
        agent_name=agent_name,
        adw_id=adw_id,
        working_dir=working_dir,
        output_file=output_file,
        dry_run=False,
        status="error",
        session_id=response.session_id,
        retry_code=retry_code,
        output=response.output,
        error={"message": response.output},
    )
    return result, 1


def main(argv: Optional[List[str]] = None) -> int:
    """Entry point: run, then print the result (JSON to stdout or human to stderr)."""
    if argv is None:
        argv = sys.argv[1:]

    result, exit_code = execute(argv)

    # Usage error (empty command) leaves result empty; argparse-style exit 2.
    if exit_code == 2 and not result:
        return 2

    ns, _ = parse_args(argv) if argv else (None, [])
    as_json = bool(getattr(ns, "as_json", False))

    if as_json:
        # stdout discipline: the JSON object is the ONLY thing on stdout.
        print(json.dumps(result))
    else:
        # Human summary -> stderr (keeps stdout free for piping).
        if result.get("dry_run"):
            logger.info("[dry-run] prompt: %s", result.get("prompt"))
            logger.info("[dry-run] output_file: %s", result.get("output_file"))
        elif result.get("status") == "success":
            logger.info("Success. Output written to %s", result.get("output_file"))
            if result.get("output"):
                logger.info("%s", result["output"])
        else:
            err = (result.get("error") or {}).get("message", "unknown error")
            logger.error("Error: %s", err)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
