"""Structured observability events for ADW workflows.

Emits versioned `adw.event/1` JSON lines to `agents/<adw_id>/events.jsonl`,
the stable, zero-dependency contract an orchestration app tails or polls
(via `read_events`). Wired at two engine chokepoints:
`agent.prompt_claude_code_with_retry()` and `ADWState.save()`.

Event schema (`adw.event/1`) — one JSON object per line:

    {
        "schema": "adw.event/1",
        "ts": "<ISO-8601 UTC>",
        "adw_id": str,
        "source": "agent" | "state" | "workflow",
        "event_type": str,
        "agent_name": str | null,
        "payload": dict,
        "summary": str | null
    }

Design constraints:
- Stdlib only (json, os, datetime). No new dependencies, no decorators.
- Fail-silent: `emit_event` never raises; any failure returns False. A
  non-JSON-serializable payload falls back to `str(payload)` and still emits.
- Kill switch: `ADW_EVENTS_DISABLED=1` disables all writes (returns False).
- Path resolution is module-anchored, mirroring `ADWState.get_state_path()`
  (state.py): the root is the checkout containing `adws/`, derived from
  `os.path.abspath(__file__)` — cwd is never consulted. Events therefore land
  beside `adw_state.json` under `agents/<adw_id>/`, never under `adws/agents/`.
  Pass `working_dir` to override the root explicitly.
"""

import json
import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

EVENT_SCHEMA = "adw.event/1"
EVENTS_FILENAME = "events.jsonl"


def _default_root() -> str:
    """Checkout root containing adws/ — mirrors ADWState.get_state_path().

    __file__ is adws/adw_modules/observability.py, so three dirnames up is
    the project root. Never cwd-based.
    """
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )


def events_path(adw_id: str, working_dir: Optional[str] = None) -> str:
    """Path to the events file: <root>/agents/<adw_id>/events.jsonl.

    Root is `working_dir` when given, else the module-anchored checkout root.
    """
    root = working_dir if working_dir else _default_root()
    return os.path.join(root, "agents", adw_id, EVENTS_FILENAME)


def emit_event(
    adw_id: str,
    source: str,
    event_type: str,
    payload: Optional[Dict[str, Any]] = None,
    agent_name: Optional[str] = None,
    summary: Optional[str] = None,
    working_dir: Optional[str] = None,
) -> bool:
    """Append one adw.event/1 JSON line. Fail-silent: never raises.

    Returns True if the line was written, False otherwise (including when
    ADW_EVENTS_DISABLED=1 is set, in which case nothing is written).
    """
    if os.environ.get("ADW_EVENTS_DISABLED") == "1":
        return False

    try:
        event = {
            "schema": EVENT_SCHEMA,
            "ts": datetime.now(timezone.utc).isoformat(),
            "adw_id": adw_id,
            "source": source,
            "event_type": event_type,
            "agent_name": agent_name,
            "payload": payload if payload is not None else {},
            "summary": summary,
        }
        try:
            line = json.dumps(event)
        except (TypeError, ValueError):
            # Non-serializable payload: degrade to its string form, still emit.
            event["payload"] = str(payload)
            line = json.dumps(event)

        path = events_path(adw_id, working_dir=working_dir)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(line + "\n")
        return True
    except Exception:
        # Observability must never break a workflow.
        return False


def read_events(adw_id: str, working_dir: Optional[str] = None) -> List[dict]:
    """Read all events for an adw_id, skipping malformed lines silently.

    Returns [] if the events file does not exist. This is the seam a
    T1/T2 orchestration app polls.
    """
    path = events_path(adw_id, working_dir=working_dir)
    if not os.path.exists(path):
        return []

    events: List[dict] = []
    try:
        with open(path, "r") as f:
            for raw_line in f:
                stripped = raw_line.strip()
                if not stripped:
                    continue
                try:
                    parsed = json.loads(stripped)
                except json.JSONDecodeError:
                    continue
                if isinstance(parsed, dict):
                    events.append(parsed)
    except Exception:
        # Return whatever parsed successfully; never raise.
        return events
    return events
