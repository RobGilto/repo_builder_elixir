#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.1.18"]
# ///
"""
ADW Plan-with-Scouts → Build → Review — scout fan-out before planning.

Dispatches parallel /scout passes that explore the codebase from different angles,
folds their findings into /plan, then /build → /review. The fan-out lives entirely in
this Python script (the Elixir engine needs ZERO changes — it just runs the discovered
script). Emits the neutral stdout-JSON event contract under `--emit json`.

Usage:
    uv run adws/adw_workflows/adw_plan_w_scouts_build_review.py --prompt "<task>" \\
        --working-dir <dir> --model <model> --adw-id <id> --emit json
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "adw_modules"))

from adw_runner import Step, main  # noqa: E402

# Each scout is its own step lane; the Elixir console attributes them by step slug.
STEPS = [
    Step("scout_architecture", "/scout architecture"),
    Step("scout_tests", "/scout tests"),
    Step("plan", "/plan"),
    Step("build", "/build"),
    Step("review", "/review"),
]

if __name__ == "__main__":
    raise SystemExit(main(STEPS))
