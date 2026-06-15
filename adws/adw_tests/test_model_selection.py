#!/usr/bin/env -S uv run
# /// script
# dependencies = ["python-dotenv", "pydantic"]
# ///
"""Test tier-based model selection for ADW workflows.

The slash-command map now stores abstract *tiers* (fast/main/heavy); the active
(harness, provider) resolves a tier to a concrete model id. claude/anthropic is
the default and resolves main->sonnet, heavy->opus, preserving historical
behaviour.
"""

import sys
import os

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from adw_modules.agent import (
    get_model_for_slash_command,
    SLASH_COMMAND_MODEL_MAP,
)
from adw_modules.harness import resolve_model, HARNESS_CATALOG
from adw_modules.data_types import AgentTemplateRequest

VALID_TIERS = {"fast", "main", "heavy"}

# The real zai model vocabulary, captured from `pi -p --list-models` (2026-06-13).
# Every zai id in the catalog must be a member of this set — a catalog id that is
# not a real provider model is rejected by pi at runtime and surfaces as a
# BLOCKED agent (see issue: zai fast → glm-5.1-air). This guard turns that class
# of bug into a fast, obvious test failure.
REAL_ZAI_MODELS = {
    "glm-4.5-air", "glm-4.7", "glm-5", "glm-5-turbo", "glm-5.1", "glm-5v-turbo",
}

# The real MiniMax model vocabulary pi exposes under `--provider minimax`. Same
# guard as zai: every minimax catalog id must be a real provider model, or pi
# rejects it at runtime and the agent surfaces as BLOCKED.
REAL_MINIMAX_MODELS = {
    "MiniMax-M2.7",
}


def test_model_mapping_structure():
    """Every command maps base and heavy to a valid tier."""
    print("Testing tier mapping structure...")

    ok = True
    for command, config in SLASH_COMMAND_MODEL_MAP.items():
        if "base" not in config or "heavy" not in config:
            print(f"❌ {command} missing base/heavy")
            ok = False
        for key in ("base", "heavy"):
            if config.get(key) not in VALID_TIERS:
                print(f"❌ {command}.{key} = {config.get(key)} is not a tier")
                ok = False
    if ok:
        print("✅ All commands map base/heavy to valid tiers")
    return ok


def test_tier_lookups():
    """Tier lookups from the map match expectations."""
    print("\nTesting tier lookups...")
    test_cases = [
        ("/implement", "base", "main"),
        ("/implement", "heavy", "heavy"),
        ("/classify_issue", "base", "main"),
        ("/classify_issue", "heavy", "main"),
        ("/review", "base", "main"),
        ("/review", "heavy", "main"),
    ]
    all_passed = True
    for command, model_set, expected in test_cases:
        result = SLASH_COMMAND_MODEL_MAP.get(command, {}).get(model_set)
        status = "✅" if result == expected else "❌"
        print(f"{status} {command} [{model_set}] → {result} (expected {expected})")
        if result != expected:
            all_passed = False
    return all_passed


def test_tier_to_id_resolution():
    """Tier → concrete id resolution per (harness, provider)."""
    print("\nTesting tier → id resolution...")
    cases = [
        ("fast", "claude", "anthropic", "haiku"),
        ("main", "claude", "anthropic", "sonnet"),
        ("heavy", "claude", "anthropic", "opus"),
        ("fast", "pi", "zai", "glm-4.5-air"),
        ("main", "pi", "zai", "glm-5.1"),
        ("fast", "pi", "openai", "gpt-4o-mini"),
        ("fast", "pi", "minimax", "MiniMax-M2.7"),
        ("main", "pi", "minimax", "MiniMax-M2.7"),
        ("heavy", "pi", "minimax", "MiniMax-M2.7"),
    ]
    all_passed = True
    for tier, harness, provider, expected in cases:
        result = resolve_model(tier, harness, provider)
        status = "✅" if result == expected else "❌"
        print(f"{status} {tier} @ {harness}/{provider} → {result} (expected {expected})")
        if result != expected:
            all_passed = False
    return all_passed


def test_get_model_for_slash_command():
    """get_model_for_slash_command returns the right tier per state."""
    print("\nTesting get_model_for_slash_command...")
    from adw_modules.state import ADWState

    test_adw_id = "test1234"
    state = ADWState(test_adw_id)
    state.update(model_set="base")
    state.save("test")

    request = AgentTemplateRequest(
        agent_name="test", slash_command="/implement", args=["plan.md"],
        adw_id=test_adw_id,
    )
    tier = get_model_for_slash_command(request)
    ok = tier == "main"
    print(f"{'✅' if ok else '❌'} base /implement → {tier} (expected main)")

    state.update(model_set="heavy")
    state.save("test")
    tier = get_model_for_slash_command(request)
    ok = ok and tier == "heavy"
    print(f"{'✅' if tier == 'heavy' else '❌'} heavy /implement → {tier} (expected heavy)")

    request_no_state = AgentTemplateRequest(
        agent_name="test", slash_command="/review", args=["spec.md"],
        adw_id="nonexistent",
    )
    tier = get_model_for_slash_command(request_no_state)
    ok = ok and tier == "main"
    print(f"{'✅' if tier == 'main' else '❌'} no-state /review → {tier} (default main)")

    # Cleanup
    state_file = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "agents", test_adw_id, "adw_state.json",
    )
    if os.path.exists(state_file):
        os.remove(state_file)
        try:
            os.rmdir(os.path.dirname(state_file))
            os.rmdir(os.path.dirname(os.path.dirname(state_file)))
        except Exception:
            pass
    return ok


def test_zai_catalog_ids_are_real_models():
    """Every zai id in the catalog must be a real zai model.

    Guards against a hand-edited catalog drifting from pi's provider vocabulary
    (e.g. zai fast → glm-5.1-air, a hallucinated id that pi rejects at runtime).
    """
    print("\nTesting zai catalog ids are real models...")
    all_passed = True
    for harness, providers in HARNESS_CATALOG.items():
        zai = providers.get("zai")
        if not zai:
            continue
        for tier, model in zai.items():
            ok = model in REAL_ZAI_MODELS
            status = "✅" if ok else "❌"
            print(f"{status} {harness}/zai/{tier} → {model} (real zai model: {ok})")
            if not ok:
                all_passed = False
    return all_passed


def test_minimax_catalog_ids_are_real_models():
    """Every minimax id in the catalog must be a real minimax model.

    Same guard as the zai one: a catalog id that is not a real provider model is
    rejected by pi at runtime and surfaces as a BLOCKED agent.
    """
    print("\nTesting minimax catalog ids are real models...")
    all_passed = True
    for harness, providers in HARNESS_CATALOG.items():
        minimax = providers.get("minimax")
        if not minimax:
            continue
        for tier, model in minimax.items():
            ok = model in REAL_MINIMAX_MODELS
            status = "✅" if ok else "❌"
            print(f"{status} {harness}/minimax/{tier} → {model} (real minimax model: {ok})")
            if not ok:
                all_passed = False
    # The user-specified id must be a member of the vocabulary set.
    member = "MiniMax-M2.7" in REAL_MINIMAX_MODELS
    print(f"{'✅' if member else '❌'} MiniMax-M2.7 ∈ REAL_MINIMAX_MODELS")
    return all_passed and member


def test_default_preservation():
    """No-env default resolves to the same concrete models as before."""
    print("\nTesting default preservation (claude/anthropic)...")
    saved = {k: os.environ.pop(k, None) for k in (
        "ADW_HARNESS", "ADW_PROVIDER", "ADW_MODEL_FAST", "ADW_MODEL_MAIN",
        "ADW_MODEL_HEAVY",
    )}
    try:
        ok = (
            resolve_model("main") == "sonnet"
            and resolve_model("heavy") == "opus"
            and resolve_model("fast") == "haiku"
        )
        print(f"{'✅' if ok else '❌'} main→sonnet, heavy→opus, fast→haiku")
    finally:
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
    return ok


def main():
    print("ADW Model Selection Tests")
    print("=" * 50)
    results = [
        test_model_mapping_structure(),
        test_tier_lookups(),
        test_tier_to_id_resolution(),
        test_zai_catalog_ids_are_real_models(),
        test_minimax_catalog_ids_are_real_models(),
        test_get_model_for_slash_command(),
        test_default_preservation(),
    ]
    print("\n" + "=" * 50)
    if all(results):
        print("✅ All tests passed!")
        return 0
    print("❌ Some tests failed!")
    return 1


if __name__ == "__main__":
    sys.exit(main())
