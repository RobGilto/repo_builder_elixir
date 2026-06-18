#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.1.18"]
# ///
"""
ADW Build-in-Parallel — plan, then fan out independent build slices, then review.

Plans the work, splits it into independent build lanes that run concurrently, then
reviews the combined result. The parallel fan-out lives entirely in this Python script
(no Elixir engine change). Emits the neutral stdout-JSON event contract under
`--emit json`.

Usage:
    uv run adws/adw_workflows/adw_build_in_parallel.py --prompt "<task>" \\
        --working-dir <dir> --model <model> --adw-id <id> --emit json
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "adw_modules"))

from adw_runner import Step, main  # noqa: E402

STEPS = [
    Step("plan", "/plan"),
    Step("build_a", "/build slice-a"),
    Step("build_b", "/build slice-b"),
    Step("review", "/review"),
]

if __name__ == "__main__":
    raise SystemExit(main(STEPS))
