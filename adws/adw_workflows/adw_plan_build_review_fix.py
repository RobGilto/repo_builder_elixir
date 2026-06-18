#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.1.18"]
# ///
"""
ADW Plan-Build-Review-Fix — the full default cycle with a review→fix branch.

Runs /plan → /build → /review, and on a FAILED review branches to /fix (the branch
lives here in Python, not the Elixir engine). Emits the neutral stdout-JSON event
contract (adw_modules/adw_emit.py) under `--emit json`.

Usage:
    uv run adws/adw_workflows/adw_plan_build_review_fix.py --prompt "<task>" \\
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


def branch(slug: str, prior: dict[str, str]) -> list[Step]:
    """After review, append /fix when the review surfaced problems."""
    if slug == "review":
        review = (prior.get("review") or "").lower()
        if any(marker in review for marker in ("fail", "issue", "bug", "error", "must fix")):
            return [Step("fix", "/fix")]
    return []


if __name__ == "__main__":
    raise SystemExit(main(STEPS, branch))
