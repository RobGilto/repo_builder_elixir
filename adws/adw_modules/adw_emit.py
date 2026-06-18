"""adw_emit — the NEUTRAL stdout-JSON event contract (issue-the-adw-gap).

This module is the portability linchpin: instead of pushing to a hard-wired
websocket backend and a private database, an ADW running in ``--emit json`` mode
prints exactly ONE versioned JSON object per line to stdout for each lifecycle
moment. Any consumer ingests the same stream — the Elixir orchestrator decodes it
via ``RepoBuilder.Harness.Adw.EventSchema`` into canonical events, but the contract
is harness/product neutral, so any other orchestrator can read it too.

Stdlib only — no third-party deps, so it imports cleanly regardless of the ADW's
own dependency set.

## The contract (schema_version 1)

One JSON object per line, flushed immediately (line-buffered), with a common
envelope plus a per-``type`` payload::

    {"schema_version": 1, "type": "...", "adw_id": "...", "adw_step": "...", ...}

Event types: ``session_started``, ``step_start``, ``step_end``, ``tool``,
``tool_result``, ``text``, ``usage``, ``done``, ``error``.

When the neutral mode is NOT selected (no ``--emit json`` / ``ADW_EMIT`` unset),
``Emitter`` is inert (``enabled=False``) so the script's default websocket/DB
behavior — if any — is untouched.
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

SCHEMA_VERSION = 1


def emit_mode_selected(argv: list[str] | None = None) -> bool:
    """True when the neutral stdout mode is selected via ``--emit json`` or ``ADW_EMIT=json``."""
    argv = sys.argv if argv is None else argv
    if os.environ.get("ADW_EMIT", "").lower() == "json":
        return True
    # Tolerate both "--emit json" and "--emit=json".
    for i, arg in enumerate(argv):
        if arg == "--emit" and i + 1 < len(argv) and argv[i + 1].lower() == "json":
            return True
        if arg.lower() == "--emit=json":
            return True
    return False


class Emitter:
    """Writes neutral event lines to stdout. Inert when ``enabled`` is False."""

    def __init__(self, adw_id: str, enabled: bool = True, stream: Any = None) -> None:
        self.adw_id = adw_id
        self.enabled = enabled
        self._stream = stream if stream is not None else sys.stdout

    # --- low-level ---

    def _write(self, type_: str, step: str | None, payload: dict[str, Any]) -> None:
        if not self.enabled:
            return
        line = {
            "schema_version": SCHEMA_VERSION,
            "type": type_,
            "adw_id": self.adw_id,
            "adw_step": step,
        }
        line.update(payload)
        self._stream.write(json.dumps(line, default=str) + "\n")
        self._stream.flush()  # one event per line, never buffered (streaming)

    # --- lifecycle events ---

    def session_started(self, model: str | None = None, session_id: str | None = None) -> None:
        self._write(
            "session_started",
            None,
            {"model": model, "session_id": session_id or self.adw_id},
        )

    def step_start(self, step: str, index: int, total: int) -> float:
        """Emit a step_start and return a start timestamp for ``step_end`` duration."""
        self._write("step_start", step, {"index": index, "total": total})
        return time.time()

    def step_end(
        self,
        step: str,
        status: str = "succeeded",
        cost_usd: float | None = None,
        started_at: float | None = None,
    ) -> None:
        duration_ms = None if started_at is None else int((time.time() - started_at) * 1000)
        self._write(
            "step_end",
            step,
            {"status": status, "cost_usd": cost_usd, "duration_ms": duration_ms},
        )

    def tool(self, step: str | None, name: str, input_: dict[str, Any] | None = None) -> None:
        self._write("tool", step, {"name": name, "input": input_ or {}})

    def tool_result(self, step: str | None, content: Any, is_error: bool = False) -> None:
        self._write("tool_result", step, {"content": content, "is_error": is_error})

    def text(self, step: str | None, text: str, thinking: bool = False) -> None:
        self._write("text", step, {"text": text, "thinking": thinking})

    def usage(
        self,
        step: str | None,
        input_tokens: int = 0,
        output_tokens: int = 0,
        cost_usd: float | None = None,
        cache_read: int | None = None,
        cache_creation: int | None = None,
    ) -> None:
        self._write(
            "usage",
            step,
            {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cost_usd": cost_usd,
                "cache_read": cache_read,
                "cache_creation": cache_creation,
            },
        )

    def done(self, ok: bool = True, reason: str = "success", final_text: str | None = None,
             cost_usd: float | None = None) -> None:
        self._write(
            "done",
            None,
            {"ok": ok, "reason": reason, "final_text": final_text, "cost_usd": cost_usd},
        )

    def error(self, message: str, reason: str = "unknown", retryable: bool = False) -> None:
        self._write("error", None, {"message": message, "reason": reason, "retryable": retryable})
