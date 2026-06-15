#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///

"""Hermetic tests for the harness adapter layer (adws/adw_modules/harness.py).

No real binary or model is ever called: argv is asserted as data, parsing runs
against captured fixtures, and ``check_installed`` is exercised via a PATH shim
(mirroring tests/pi_agent.bats' shim discipline). The default-preservation test
guards the cardinal constraint — no env ⇒ claude/anthropic ⇒ identical models.
"""

import os
import sys
import stat
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from adw_modules.harness import (
    ClaudeHarness,
    PiHarness,
    HARNESS_REGISTRY,
    harness_catalog,
    get_active_harness,
    get_active_provider,
    resolve_model,
)
from adw_modules.data_types import AgentPromptRequest


def _req(harness="claude", provider="anthropic", model="sonnet", **kw):
    return AgentPromptRequest(
        prompt="/feature build a thing",
        adw_id="abc12345",
        agent_name="planner",
        model=model,
        harness=harness,
        provider=provider,
        output_file="/tmp/out.jsonl",
        **kw,
    )


def test_claude_argv():
    print("Testing claude argv...")
    argv = ClaudeHarness().build_argv(
        _req(dangerously_skip_permissions=True)
    )
    ok = (
        argv[1:6] == ["-p", "/feature build a thing", "--model", "sonnet",
                      "--output-format"]
        and "stream-json" in argv
        and "--verbose" in argv
        and "--dangerously-skip-permissions" in argv
    )
    print(f"{'✅' if ok else '❌'} claude argv: {argv}")
    return ok


def test_pi_argv():
    print("\nTesting pi argv...")
    argv = PiHarness().build_argv(
        _req(harness="pi", provider="zai", model="glm-5.1")
    )
    ok = (
        "--mode" in argv and "json" in argv
        and "--provider" in argv and "zai" in argv
        and "--model" in argv and "glm-5.1" in argv
        and "--tools" in argv
        # pi gaps: no MCP, no permission-skip flag
        and "--mcp-config" not in argv
        and "--dangerously-skip-permissions" not in argv
    )
    print(f"{'✅' if ok else '❌'} pi argv: {argv}")
    return ok


def test_tier_resolution():
    print("\nTesting tier resolution per (harness, provider)...")
    cases = [
        ("fast", "claude", "anthropic", "haiku"),
        ("main", "claude", "anthropic", "sonnet"),
        ("heavy", "claude", "anthropic", "opus"),
        ("fast", "pi", "zai", "glm-4.5-air"),
        ("main", "pi", "zai", "glm-5.1"),
        ("heavy", "pi", "openai", "o3"),
        ("fast", "pi", "minimax", "MiniMax-M2.7"),
        ("main", "pi", "minimax", "MiniMax-M2.7"),
        ("heavy", "pi", "minimax", "MiniMax-M2.7"),
    ]
    ok = True
    for tier, h, p, expected in cases:
        got = resolve_model(tier, h, p)
        status = "✅" if got == expected else "❌"
        print(f"{status} {tier}@{h}/{p} → {got}")
        ok = ok and got == expected
    return ok


def test_tier_no_mapping_raises():
    print("\nTesting unmapped (harness, provider) raises loud...")
    try:
        resolve_model("main", "claude", "zai")  # claude has no zai
        print("❌ expected ValueError")
        return False
    except ValueError as e:
        print(f"✅ raised: {e}")
        return True


def test_pi_parse_fixture():
    print("\nTesting pi --mode json parse against fixture...")
    fixture = "\n".join([
        '{"type":"session","version":3,"id":"sess-123","cwd":"/x"}',
        '{"type":"agent_start"}',
        '{"type":"turn_start"}',
        '{"type":"message_start","message":{"role":"assistant","content":[]}}',
        '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Done editing files."}]}}',
        '{"type":"turn_end","message":{},"toolResults":[]}',
        '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"Done editing files."}]}]}',
    ])
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(fixture)
        path = f.name
    try:
        resp = PiHarness().parse_output(path, returncode=0, stderr="")
        ok = (
            resp.success
            and resp.session_id == "sess-123"
            and "Done editing files." in resp.output
        )
        print(f"{'✅' if ok else '❌'} parsed: success={resp.success}, "
              f"session={resp.session_id}, output={resp.output!r}")
        return ok
    finally:
        os.remove(path)


def test_pi_parse_failure_no_agent_end():
    print("\nTesting pi parse derives failure when agent_end missing...")
    fixture = "\n".join([
        '{"type":"session","id":"s1"}',
        '{"type":"agent_start"}',
        '{"type":"auto_retry_end","success":false,"finalError":"rate limited"}',
    ])
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(fixture)
        path = f.name
    try:
        resp = PiHarness().parse_output(path, returncode=0, stderr="")
        ok = (not resp.success) and "rate limited" in resp.output
        print(f"{'✅' if ok else '❌'} failure derived: {resp.output!r}")
        return ok
    finally:
        os.remove(path)


def test_check_installed_shim():
    print("\nTesting check_installed via PATH shim...")
    tmpdir = tempfile.mkdtemp()
    shim = os.path.join(tmpdir, "fake_pi")
    with open(shim, "w") as f:
        f.write("#!/bin/sh\necho 'pi 0.79.2'\n")
    os.chmod(shim, os.stat(shim).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    saved = os.environ.get("PI_CODING_AGENT_PATH")
    os.environ["PI_CODING_AGENT_PATH"] = shim
    try:
        err = PiHarness().check_installed()
        present = err is None
        # And a missing binary returns an error string
        os.environ["PI_CODING_AGENT_PATH"] = "/nonexistent/pi_xyz"
        err2 = PiHarness().check_installed()
        missing = err2 is not None and "pi" in err2.lower()
        ok = present and missing
        print(f"{'✅' if ok else '❌'} present→{err}, missing→{err2}")
        return ok
    finally:
        if saved is not None:
            os.environ["PI_CODING_AGENT_PATH"] = saved
        else:
            os.environ.pop("PI_CODING_AGENT_PATH", None)


def test_default_preservation():
    print("\nTesting default preservation (no env ⇒ claude/anthropic)...")
    saved = {k: os.environ.pop(k, None) for k in (
        "ADW_HARNESS", "ADW_PROVIDER", "ADW_MODEL_FAST", "ADW_MODEL_MAIN",
        "ADW_MODEL_HEAVY",
    )}
    try:
        ok = (
            get_active_harness() == "claude"
            and get_active_provider() == "anthropic"
            and resolve_model("main") == "sonnet"
            and resolve_model("heavy") == "opus"
            and resolve_model("fast") == "haiku"
        )
        # And the claude argv is identical to the historical command shape.
        argv = ClaudeHarness().build_argv(_req(model="sonnet"))
        ok = ok and argv[2] == "/feature build a thing" and "stream-json" in argv
        print(f"{'✅' if ok else '❌'} defaults preserved")
        return ok
    finally:
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v


def test_catalog_shape():
    print("\nTesting catalog shape + immutability...")
    cat = harness_catalog()
    cat["claude"]["anthropic"]["main"] = "MUTATED"
    fresh = harness_catalog()
    ok = (
        "claude" in fresh and "pi" in fresh
        and fresh["claude"]["anthropic"]["main"] == "sonnet"  # not mutated
        and set(HARNESS_REGISTRY) == {"claude", "pi"}
    )
    print(f"{'✅' if ok else '❌'} catalog is a defensive copy")
    return ok


def main():
    print("ADW Harness Adapter Tests")
    print("=" * 50)
    results = [
        test_claude_argv(),
        test_pi_argv(),
        test_tier_resolution(),
        test_tier_no_mapping_raises(),
        test_pi_parse_fixture(),
        test_pi_parse_failure_no_agent_end(),
        test_check_installed_shim(),
        test_default_preservation(),
        test_catalog_shape(),
    ]
    print("\n" + "=" * 50)
    if all(results):
        print("✅ All tests passed!")
        return 0
    print("❌ Some tests failed!")
    return 1


if __name__ == "__main__":
    sys.exit(main())
