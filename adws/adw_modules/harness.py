"""Pluggable coding-agent harness adapter layer.

The ADW engine historically welded itself to a single harness (Claude Code) and
to Anthropic's concrete model names. This module introduces a thin, flat
abstraction seam so the engine can run a step through **Claude Code** *or* the
**pi coding agent** (``@earendil-works/pi-coding-agent``), against any provider
either supports, addressing models by an abstract tier (``fast``/``main``/
``heavy``) instead of a hardcoded id.

Design notes:
- No ABC ceremony, no decorators. Each adapter is a plain class registered in
  ``HARNESS_REGISTRY``, mirroring how the rest of the engine keeps things flat.
- ``harness_catalog()`` is the single source of truth for the
  ``{harness -> {provider -> {tier -> model_id}}}`` table. The orchestrator
  backend reads it read-only.
- Backward compatibility is the cardinal constraint: with no env configured the
  active harness is ``claude``, the active provider is ``anthropic``, and tiers
  resolve to the exact same concrete models as before (fast->haiku,
  main->sonnet, heavy->opus).

See ``app_docs/pi-harness-sdk.md`` for the pi CLI/flag/event-stream reference
this adapter is built from.
"""

import json
import os
import subprocess
from typing import Any, Dict, List, Optional

from .data_types import (
    AgentPromptRequest,
    AgentPromptResponse,
    Harness,
    ModelTier,
    Provider,
    RetryCode,
)


# --------------------------------------------------------------------------- #
# Catalog: the single source of truth for tier -> concrete model resolution.
#
# Concrete ids are deployment config, not engine constants — pi's provider model
# vocabularies evolve. Keep them here (one editable table) rather than scattered
# as literals across the engine. ``ADW_MODEL_{FAST,MAIN,HEAVY}`` env overrides
# win over any entry below (see resolve_model).
# --------------------------------------------------------------------------- #
HARNESS_CATALOG: Dict[str, Dict[str, Dict[str, str]]] = {
    "claude": {
        # Claude Code is implicitly Anthropic-only.
        "anthropic": {"fast": "haiku", "main": "sonnet", "heavy": "opus"},
    },
    "pi": {
        "anthropic": {"fast": "haiku", "main": "sonnet", "heavy": "opus"},
        "zai": {"fast": "glm-4.5-air", "main": "glm-5.1", "heavy": "glm-5.1"},
        "openai": {"fast": "gpt-4o-mini", "main": "gpt-4o", "heavy": "o3"},
        # MiniMax exposes a single coding model; all three tiers map to it.
        "minimax": {"fast": "MiniMax-M2.7", "main": "MiniMax-M2.7", "heavy": "MiniMax-M2.7"},
    },
}

# Default selection — preserves historical behaviour when nothing is configured.
DEFAULT_HARNESS: Harness = "claude"
DEFAULT_PROVIDER: Provider = "anthropic"
DEFAULT_TIER: ModelTier = "main"

# Env override knobs (per tier). When set, they win over the catalog id.
_TIER_ENV_OVERRIDE: Dict[ModelTier, str] = {
    "fast": "ADW_MODEL_FAST",
    "main": "ADW_MODEL_MAIN",
    "heavy": "ADW_MODEL_HEAVY",
}


def harness_catalog() -> Dict[str, Dict[str, Dict[str, str]]]:
    """Return the full ``{harness -> {provider -> {tier -> model_id}}}`` table.

    Returned as a deep copy so callers (e.g. the orchestrator backend surfacing
    it over HTTP) cannot mutate the engine's source of truth.
    """
    return json.loads(json.dumps(HARNESS_CATALOG))


# --------------------------------------------------------------------------- #
# Adapters.
# --------------------------------------------------------------------------- #
class ClaudeHarness:
    """Adapter for the Claude Code CLI (``claude``).

    Mirrors the exact argv + JSONL result parse the engine used before the
    abstraction, so the no-env default path is byte-for-byte unchanged.
    """

    name: Harness = "claude"

    @property
    def binary(self) -> str:
        return os.getenv("CLAUDE_CODE_PATH", "claude")

    def resolve_model(self, tier: ModelTier, provider: Provider) -> str:
        return _resolve_from_catalog(self.name, provider, tier)

    def check_installed(self) -> Optional[str]:
        path = self.binary
        try:
            result = subprocess.run(
                [path, "--version"], capture_output=True, text=True
            )
            if result.returncode != 0:
                return f"Error: Claude Code CLI is not installed. Expected at: {path}"
        except FileNotFoundError:
            return f"Error: Claude Code CLI is not installed. Expected at: {path}"
        return None

    def build_argv(self, request: AgentPromptRequest) -> List[str]:
        cmd = [self.binary, "-p", request.prompt]
        cmd.extend(["--model", request.model])
        cmd.extend(["--output-format", "stream-json"])
        cmd.append("--verbose")

        # MCP is a Claude-only capability; pass the project .mcp.json if present.
        if request.working_dir:
            mcp_config_path = os.path.join(request.working_dir, ".mcp.json")
            if os.path.exists(mcp_config_path):
                cmd.extend(["--mcp-config", mcp_config_path])

        if request.dangerously_skip_permissions:
            cmd.append("--dangerously-skip-permissions")

        return cmd

    def parse_output(
        self, output_file: str, returncode: int, stderr: str
    ) -> AgentPromptResponse:
        """Parse Claude Code's stream-json output into the engine result."""
        from .agent import (
            convert_jsonl_to_json,
            parse_jsonl_output,
            truncate_output,
        )

        if returncode == 0:
            messages, result_message = parse_jsonl_output(output_file)
            convert_jsonl_to_json(output_file)

            if result_message:
                session_id = result_message.get("session_id")
                is_error = result_message.get("is_error", False)
                subtype = result_message.get("subtype", "")

                if subtype == "error_during_execution":
                    return AgentPromptResponse(
                        output=(
                            "Error during execution: Agent encountered an error "
                            "and did not return a result"
                        ),
                        success=False,
                        session_id=session_id,
                        retry_code=RetryCode.ERROR_DURING_EXECUTION,
                    )

                result_text = result_message.get("result", "")
                if is_error and len(result_text) > 1000:
                    result_text = truncate_output(result_text, max_length=800)

                return AgentPromptResponse(
                    output=result_text,
                    success=not is_error,
                    session_id=session_id,
                    retry_code=RetryCode.NONE,
                )

            # No result message — try to surface a meaningful error.
            error_msg = "No result message found in Claude Code output"
            try:
                with open(output_file, "r") as f:
                    lines = f.readlines()
                if lines:
                    last_lines = lines[-5:] if len(lines) > 5 else lines
                    for line in reversed(last_lines):
                        try:
                            data = json.loads(line.strip())
                            if data.get("type") == "assistant" and data.get(
                                "message"
                            ):
                                content = data["message"].get("content", [])
                                if isinstance(content, list) and content:
                                    text = content[0].get("text", "")
                                    if text:
                                        error_msg = f"Claude Code output: {text[:500]}"
                                        break
                        except Exception:
                            pass
            except Exception:
                pass

            return AgentPromptResponse(
                output=truncate_output(error_msg, max_length=800),
                success=False,
                session_id=None,
                retry_code=RetryCode.NONE,
            )

        # Non-zero exit — derive an error message from stderr + the output file.
        stderr_msg = stderr.strip() if stderr else ""
        stdout_msg = ""
        error_from_jsonl = None
        try:
            if os.path.exists(output_file):
                messages, result_message = parse_jsonl_output(output_file)
                if result_message and result_message.get("is_error"):
                    error_from_jsonl = result_message.get("result", "Unknown error")
                elif messages:
                    for msg in reversed(messages[-5:]):
                        if msg.get("type") == "assistant" and msg.get(
                            "message", {}
                        ).get("content"):
                            content = msg["message"]["content"]
                            if isinstance(content, list) and content:
                                text = content[0].get("text", "")
                                if text and (
                                    "error" in text.lower()
                                    or "failed" in text.lower()
                                ):
                                    error_from_jsonl = text[:500]
                                    break
                if not error_from_jsonl:
                    with open(output_file, "r") as f:
                        lines = f.readlines()
                    if lines:
                        stdout_msg = lines[-1].strip()[:200]
        except Exception:
            pass

        if error_from_jsonl:
            error_msg = f"Claude Code error: {error_from_jsonl}"
        elif stdout_msg and not stderr_msg:
            error_msg = f"Claude Code error: {stdout_msg}"
        elif stderr_msg and not stdout_msg:
            error_msg = f"Claude Code error: {stderr_msg}"
        elif stdout_msg and stderr_msg:
            error_msg = f"Claude Code error: {stderr_msg}\nStdout: {stdout_msg}"
        else:
            error_msg = (
                f"Claude Code error: Command failed with exit code {returncode}"
            )

        return AgentPromptResponse(
            output=truncate_output(error_msg, max_length=800),
            success=False,
            session_id=None,
            retry_code=RetryCode.CLAUDE_CODE_ERROR,
        )


class PiHarness:
    """Adapter for the pi coding agent CLI (``pi``).

    pi is provider-agnostic; the engine drives it with ``--mode json`` and
    derives success from reaching ``agent_end`` (pi has no single ``is_error``
    result line like Claude Code). MCP and permission-skip flags have no pi
    equivalent and are intentionally omitted (see the SDK doc's gaps list).
    """

    name: Harness = "pi"

    @property
    def binary(self) -> str:
        return os.getenv("PI_CODING_AGENT_PATH", os.getenv("PI_BIN", "pi"))

    def resolve_model(self, tier: ModelTier, provider: Provider) -> str:
        return _resolve_from_catalog(self.name, provider, tier)

    def check_installed(self) -> Optional[str]:
        path = self.binary
        try:
            result = subprocess.run(
                [path, "--version"], capture_output=True, text=True
            )
            if result.returncode != 0:
                return f"Error: pi coding agent is not installed. Expected at: {path}"
        except FileNotFoundError:
            return f"Error: pi coding agent is not installed. Expected at: {path}"
        return None

    def build_argv(self, request: AgentPromptRequest) -> List[str]:
        cmd = [self.binary, "--mode", "json"]
        cmd.extend(["--provider", request.provider])
        cmd.extend(["--model", request.model])
        cmd.extend(["--tools", "read,write,edit,bash"])
        # Ephemeral session keeps hermetic/CI runs clean (mirrors the engine's
        # constrained subprocess env discipline).
        cmd.append("--no-session")
        # NOTE: no --mcp-config (pi has no native MCP) and no
        # --dangerously-skip-permissions (pi non-interactive never prompts).
        cmd.append(request.prompt)
        return cmd

    def parse_output(
        self, output_file: str, returncode: int, stderr: str
    ) -> AgentPromptResponse:
        """Parse pi's ``--mode json`` event stream into the engine result.

        - session_id  <- first ``{"type":"session", "id": ...}`` header line
        - output      <- last assistant ``message_end`` text content
        - success     <- reaching ``agent_end`` cleanly (returncode 0); a
          ``tool_execution_end.isError`` or failed ``auto_retry_end`` flips it.
        """
        from .agent import truncate_output

        events: List[Dict[str, Any]] = []
        try:
            with open(output_file, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        except Exception as e:
            return AgentPromptResponse(
                output=f"pi error: could not read output ({e})",
                success=False,
                session_id=None,
                retry_code=RetryCode.EXECUTION_ERROR,
            )

        session_id = None
        for ev in events:
            if ev.get("type") == "session":
                session_id = ev.get("id")
                break

        if returncode != 0:
            err = stderr.strip() if stderr else ""
            if not err and events:
                err = json.dumps(events[-1])[:200]
            return AgentPromptResponse(
                output=truncate_output(
                    f"pi error: Command failed with exit code {returncode}"
                    + (f": {err}" if err else ""),
                    max_length=800,
                ),
                success=False,
                session_id=session_id,
                retry_code=RetryCode.CLAUDE_CODE_ERROR,
            )

        reached_end = any(ev.get("type") == "agent_end" for ev in events)

        # Heuristic failure signals (pi self-retries; a final failed retry or a
        # tool error means the run did not complete cleanly).
        for ev in events:
            if ev.get("type") == "auto_retry_end" and ev.get("success") is False:
                return AgentPromptResponse(
                    output=truncate_output(
                        f"pi error: {ev.get('finalError', 'auto-retry exhausted')}",
                        max_length=800,
                    ),
                    success=False,
                    session_id=session_id,
                    retry_code=RetryCode.CLAUDE_CODE_ERROR,
                )

        output_text = _extract_pi_text(events)

        if not reached_end:
            return AgentPromptResponse(
                output=truncate_output(
                    output_text or "pi error: stream ended before agent_end",
                    max_length=800,
                ),
                success=False,
                session_id=session_id,
                retry_code=RetryCode.ERROR_DURING_EXECUTION,
            )

        return AgentPromptResponse(
            output=output_text,
            success=True,
            session_id=session_id,
            retry_code=RetryCode.NONE,
        )


def _extract_pi_text(events: List[Dict[str, Any]]) -> str:
    """Pull the final assistant text out of a pi event list."""

    def text_of(message: Dict[str, Any]) -> str:
        content = message.get("content", [])
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") in (
                    "text",
                    None,
                ):
                    parts.append(block.get("text", ""))
                elif isinstance(block, str):
                    parts.append(block)
            return "".join(parts)
        return ""

    # Prefer agent_end.messages[-1], then the last message_end.
    for ev in reversed(events):
        if ev.get("type") == "agent_end":
            msgs = ev.get("messages") or []
            for m in reversed(msgs):
                if isinstance(m, dict) and m.get("role") == "assistant":
                    t = text_of(m)
                    if t:
                        return t
    for ev in reversed(events):
        if ev.get("type") == "message_end":
            t = text_of(ev.get("message", {}))
            if t:
                return t
    return ""


# --------------------------------------------------------------------------- #
# Registry + resolution.
# --------------------------------------------------------------------------- #
HARNESS_REGISTRY: Dict[Harness, Any] = {
    "claude": ClaudeHarness(),
    "pi": PiHarness(),
}


def get_active_harness() -> Harness:
    """Active harness from ``ADW_HARNESS`` (default ``claude``)."""
    value = os.getenv("ADW_HARNESS", DEFAULT_HARNESS).strip().lower()
    if value not in HARNESS_REGISTRY:
        return DEFAULT_HARNESS
    return value  # type: ignore[return-value]


def get_active_provider() -> Provider:
    """Active provider from ``ADW_PROVIDER`` (default ``anthropic``)."""
    value = os.getenv("ADW_PROVIDER", DEFAULT_PROVIDER).strip().lower()
    return value  # type: ignore[return-value]


def get_harness_adapter(harness: Optional[Harness] = None) -> Any:
    """Return the adapter for ``harness`` (or the active one)."""
    return HARNESS_REGISTRY[harness or get_active_harness()]


def _resolve_from_catalog(
    harness: Harness, provider: Provider, tier: ModelTier
) -> str:
    """Resolve a tier to a concrete id, honouring env overrides first.

    Raises a loud, explicit error if no mapping exists — never silently picks a
    wrong model.
    """
    override_var = _TIER_ENV_OVERRIDE.get(tier)
    if override_var:
        override = os.getenv(override_var)
        if override:
            return override

    providers = HARNESS_CATALOG.get(harness)
    if not providers:
        raise ValueError(f"Unknown harness '{harness}' (no catalog entry)")
    tiers = providers.get(provider)
    if not tiers:
        raise ValueError(
            f"Harness '{harness}' has no provider '{provider}' in the catalog. "
            f"Available: {sorted(providers)}"
        )
    model_id = tiers.get(tier)
    if not model_id:
        raise ValueError(
            f"No model mapped for tier '{tier}' under {harness}/{provider}. "
            f"Available tiers: {sorted(tiers)}"
        )
    return model_id


def resolve_model(
    tier: ModelTier,
    harness: Optional[Harness] = None,
    provider: Optional[Provider] = None,
) -> str:
    """Resolve ``(tier, harness, provider)`` to a concrete model id.

    ``harness``/``provider`` default to the active env-driven selection.
    """
    harness = harness or get_active_harness()
    provider = provider or get_active_provider()
    return _resolve_from_catalog(harness, provider, tier)
