#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic", "pytest"]
# ///
"""Dual-format (.md/.html) spec discovery + ADW_PLAN_COMMAND resolution.

planf3 plans are HTML files in specs/; the discovery paths (state, git-diff filter,
glob fallback) must see them alongside the historical markdown specs, and the
plan-step command override must validate its value and fail open to the classified
issue class.
"""

import logging
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from adw_modules.workflow_ops import (
    PLAN_CAPABLE_COMMANDS,
    _extract_spec_path,
    _local_find_spec_fallback,
    resolve_plan_command,
)

logger = logging.getLogger(__name__)


def _with_env(key, value, fn):
    prior = os.environ.get(key)
    try:
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
        return fn()
    finally:
        if prior is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = prior


def test_resolve_plan_command_default_is_issue_class():
    assert _with_env(
        "ADW_PLAN_COMMAND", None, lambda: resolve_plan_command("/feature")
    ) == "/feature"


def test_resolve_plan_command_override_planf3():
    assert _with_env(
        "ADW_PLAN_COMMAND", "/plan_f3", lambda: resolve_plan_command("/feature")
    ) == "/plan_f3"


def test_resolve_plan_command_unknown_falls_back():
    """A typo'd override must warn and fall back, never crash a run."""
    assert _with_env(
        "ADW_PLAN_COMMAND", "/nonsense", lambda: resolve_plan_command("/bug")
    ) == "/bug"


def test_plan_capable_commands_include_planf3_and_classes():
    assert "/plan_f3" in PLAN_CAPABLE_COMMANDS
    for cls in ("/feature", "/bug", "/chore"):
        assert cls in PLAN_CAPABLE_COMMANDS


def test_local_fallback_finds_html_spec():
    with tempfile.TemporaryDirectory() as root:
        specs = os.path.join(root, "specs")
        os.makedirs(specs)
        html = os.path.join(specs, "issue-7-adw-abc123-sdlc_planner-thing.html")
        with open(html, "w") as f:
            f.write("<html></html>")
        assert _local_find_spec_fallback(root, 7, "abc123") == html


def test_local_fallback_still_finds_md_spec():
    with tempfile.TemporaryDirectory() as root:
        specs = os.path.join(root, "specs")
        os.makedirs(specs)
        md = os.path.join(specs, "issue-7-adw-abc123-sdlc_planner-thing.md")
        with open(md, "w") as f:
            f.write("# plan")
        assert _local_find_spec_fallback(root, 7, "abc123") == md


def test_local_fallback_newest_wins_across_formats():
    with tempfile.TemporaryDirectory() as root:
        specs = os.path.join(root, "specs")
        os.makedirs(specs)
        md = os.path.join(specs, "issue-7-adw-abc123-sdlc_planner-old.md")
        html = os.path.join(specs, "issue-7-adw-abc123-sdlc_planner-new.html")
        with open(md, "w") as f:
            f.write("# plan")
        with open(html, "w") as f:
            f.write("<html></html>")
        os.utime(md, (1_000_000_000, 1_000_000_000))
        os.utime(html, (2_000_000_000, 2_000_000_000))
        assert _local_find_spec_fallback(root, 7, "abc123") == html


def test_local_fallback_ignores_sibling_image_dirs():
    """A plan's images directory (same stem, no extension) must not match."""
    with tempfile.TemporaryDirectory() as root:
        specs = os.path.join(root, "specs")
        os.makedirs(os.path.join(specs, "issue-7-adw-abc123-sdlc_planner-thing"))
        assert _local_find_spec_fallback(root, 7, "abc123") is None


def test_find_spec_file_diff_filter_accepts_both_formats():
    """The git-diff filter logic: specs/ prefix + .md/.html suffix."""
    files = [
        "specs/issue-1-adw-x-sdlc_planner-a.md",
        "specs/issue-1-adw-x-sdlc_planner-b.html",
        "specs/issue-1-adw-x-sdlc_planner-b/hero.png",
        "lib/foo.ex",
    ]
    kept = [
        f for f in files if f.startswith("specs/") and f.endswith((".md", ".html"))
    ]
    assert kept == [
        "specs/issue-1-adw-x-sdlc_planner-a.md",
        "specs/issue-1-adw-x-sdlc_planner-b.html",
    ]


def test_extract_spec_path_salvages_chatty_reply():
    """Regression: run 0d9c026a — planner replied 'Plan saved to `specs/...html`.' plus
    a long summary; the strict parse and glob fallback both missed the plan."""
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "specs"))
        with open(os.path.join(root, "specs", "pg-sh-version-flag.html"), "w") as f:
            f.write("<html></html>")
        chatty = "Plan saved to `specs/pg-sh-version-flag.html`.\n\n## Summary\nblah"
        assert _extract_spec_path(chatty, root) == "specs/pg-sh-version-flag.html"


def test_extract_spec_path_leaves_clean_reply_alone():
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "specs"))
        with open(os.path.join(root, "specs", "a.html"), "w") as f:
            f.write("x")
        assert _extract_spec_path("specs/a.html", root) is None


def test_extract_spec_path_ignores_nonexistent_mentions():
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "specs"))
        assert _extract_spec_path("see specs/ghost.html maybe", root) is None


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"✅ {name}")
            except AssertionError as exc:
                print(f"❌ {name}: {exc}")
                failures += 1
    sys.exit(1 if failures else 0)
