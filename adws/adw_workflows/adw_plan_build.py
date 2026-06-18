#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.1.18"]
# ///
"""
ADW Plan-Build — plan the work, then build it. The leanest real ADW (no review).

Runs /plan then /build via the Claude Agent SDK, emitting the neutral stdout-JSON
event contract (see adw_modules/adw_emit.py) when launched with `--emit json` /
`ADW_EMIT=json`. Portable: the Elixir orchestrator consumes this stream through the
ADW harness adapter, but any product can read the same events.

Usage:
    uv run adws/adw_workflows/adw_plan_build.py --prompt "<task>" \\
        --working-dir <dir> --model <model> --adw-id <id> --emit json
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "adw_modules"))

from adw_runner import Step, main  # noqa: E402

STEPS = [
    Step("plan", "/plan"),
    Step("build", "/build"),
]

if __name__ == "__main__":
    raise SystemExit(main(STEPS))
