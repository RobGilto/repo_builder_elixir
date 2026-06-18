#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.1.18"]
# ///
"""
ADW Plan-Build-Review — plan, build, then review the build (stops after review).

Runs /plan → /build → /review via the Claude Agent SDK, emitting the neutral
stdout-JSON event contract (adw_modules/adw_emit.py) under `--emit json`. No auto-fix:
the review's findings are reported but not acted on.

Usage:
    uv run adws/adw_workflows/adw_plan_build_review.py --prompt "<task>" \\
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
    Step("review", "/review"),
]

if __name__ == "__main__":
    raise SystemExit(main(STEPS))
