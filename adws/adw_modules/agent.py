"""Claude Code agent module for executing prompts programmatically."""

import subprocess
import sys
import os
import json
import re
import logging
import time
from typing import Optional, List, Dict, Any, Tuple, Final
from dotenv import load_dotenv
from .data_types import (
    AgentPromptRequest,
    AgentPromptResponse,
    AgentTemplateRequest,
    ClaudeCodeResultMessage,
    SlashCommand,
    ModelSet,
    ModelTier,
    RetryCode,
)
from .observability import emit_event

# Load environment variables
load_dotenv()

# Get Claude Code CLI path from environment
# (kept for backward compatibility; the claude adapter reads CLAUDE_CODE_PATH).
CLAUDE_PATH = os.getenv("CLAUDE_CODE_PATH", "claude")

# Model selection mapping for slash commands.
# Values are abstract *tiers* (fast/main/heavy), not concrete model ids. The
# active (harness, provider) resolves a tier to a concrete id inside
# execute_template. The base/heavy keys are the run-profile (ModelSet); they pick
# which tier a command uses. claude+anthropic resolves main->sonnet, heavy->opus,
# so the default path is identical to the historical sonnet/opus behaviour.
SLASH_COMMAND_MODEL_MAP: Final[Dict[SlashCommand, Dict[ModelSet, ModelTier]]] = {
    "/classify_issue": {"base": "main", "heavy": "main"},
    "/classify_adw": {"base": "main", "heavy": "main"},
    "/generate_branch_name": {"base": "main", "heavy": "main"},
    "/implement": {"base": "main", "heavy": "heavy"},
    "/test": {"base": "main", "heavy": "main"},
    "/resolve_failed_test": {"base": "main", "heavy": "heavy"},
    "/test_e2e": {"base": "main", "heavy": "main"},
    "/resolve_failed_e2e_test": {"base": "main", "heavy": "heavy"},
    "/review": {"base": "main", "heavy": "main"},
    "/document": {"base": "main", "heavy": "heavy"},
    "/commit": {"base": "main", "heavy": "main"},
    "/pull_request": {"base": "main", "heavy": "main"},
    "/chore": {"base": "main", "heavy": "heavy"},
    "/bug": {"base": "main", "heavy": "heavy"},
    "/feature": {"base": "main", "heavy": "heavy"},
    "/planf3": {"base": "main", "heavy": "heavy"},
    "/patch": {"base": "main", "heavy": "heavy"},
    "/install_worktree": {"base": "main", "heavy": "main"},
    "/track_agentic_kpis": {"base": "main", "heavy": "main"},
}


def get_model_for_slash_command(
    request: AgentTemplateRequest, default: ModelTier = "main"
) -> ModelTier:
    """Get the appropriate model *tier* for a template request.

    Loads the ADW state to determine the model set (base or heavy) and returns
    the abstract tier (fast/main/heavy) for the slash command. The tier is later
    resolved to a concrete model id by the active harness/provider.

    Args:
        request: The template request containing the slash command and adw_id
        default: Default tier if the command is not in the mapping

    Returns:
        Abstract model tier ("fast", "main", or "heavy")
    """
    # Import here to avoid circular imports
    from .state import ADWState

    # Load state to get model_set
    model_set: ModelSet = "base"  # Default model set
    state = ADWState.load(request.adw_id)
    if state:
        model_set = state.get("model_set", "base")

    # Get the tier configuration for the command
    command_config = SLASH_COMMAND_MODEL_MAP.get(request.slash_command)

    if command_config:
        # Get the tier for the specified model set, defaulting to base if not found
        return command_config.get(model_set, command_config.get("base", default))

    return default


def truncate_output(
    output: str, max_length: int = 500, suffix: str = "... (truncated)"
) -> str:
    """Truncate output to a reasonable length for display.

    Special handling for JSONL data - if the output appears to be JSONL,
    try to extract just the meaningful part.

    Args:
        output: The output string to truncate
        max_length: Maximum length before truncation (default: 500)
        suffix: Suffix to add when truncated (default: "... (truncated)")

    Returns:
        Truncated string if needed, original if shorter than max_length
    """
    # Check if this looks like JSONL data
    if output.startswith('{"type":') and '\n{"type":' in output:
        # This is likely JSONL output - try to extract the last meaningful message
        lines = output.strip().split("\n")
        for line in reversed(lines):
            try:
                data = json.loads(line)
                # Look for result message
                if data.get("type") == "result":
                    result = data.get("result", "")
                    if result:
                        return truncate_output(result, max_length, suffix)
                # Look for assistant message
                elif data.get("type") == "assistant" and data.get("message"):
                    content = data["message"].get("content", [])
                    if isinstance(content, list) and content:
                        text = content[0].get("text", "")
                        if text:
                            return truncate_output(text, max_length, suffix)
            except:
                pass
        # If we couldn't extract anything meaningful, just show that it's JSONL
        return f"[JSONL output with {len(lines)} messages]{suffix}"

    # Regular truncation logic
    if len(output) <= max_length:
        return output

    # Try to find a good break point (newline or space)
    truncate_at = max_length - len(suffix)

    # Look for newline near the truncation point
    newline_pos = output.rfind("\n", truncate_at - 50, truncate_at)
    if newline_pos > 0:
        return output[:newline_pos] + suffix

    # Look for space near the truncation point
    space_pos = output.rfind(" ", truncate_at - 20, truncate_at)
    if space_pos > 0:
        return output[:space_pos] + suffix

    # Just truncate at the limit
    return output[:truncate_at] + suffix


def check_claude_installed() -> Optional[str]:
    """Check if Claude Code CLI is installed. Return error message if not."""
    try:
        result = subprocess.run(
            [CLAUDE_PATH, "--version"], capture_output=True, text=True
        )
        if result.returncode != 0:
            return (
                f"Error: Claude Code CLI is not installed. Expected at: {CLAUDE_PATH}"
            )
    except FileNotFoundError:
        return f"Error: Claude Code CLI is not installed. Expected at: {CLAUDE_PATH}"
    return None


def parse_jsonl_output(
    output_file: str,
) -> Tuple[List[Dict[str, Any]], Optional[Dict[str, Any]]]:
    """Parse JSONL output file and return all messages and the result message.

    Returns:
        Tuple of (all_messages, result_message) where result_message is None if not found
    """
    try:
        with open(output_file, "r") as f:
            # Read all lines and parse each as JSON
            messages = [json.loads(line) for line in f if line.strip()]

            # Find the result message (should be the last one)
            result_message = None
            for message in reversed(messages):
                if message.get("type") == "result":
                    result_message = message
                    break

            return messages, result_message
    except Exception as e:
        return [], None


def convert_jsonl_to_json(jsonl_file: str) -> str:
    """Convert JSONL file to JSON array file.

    Creates a .json file with the same name as the .jsonl file,
    containing all messages as a JSON array.

    Returns:
        Path to the created JSON file
    """
    # Create JSON filename by replacing .jsonl with .json
    json_file = jsonl_file.replace(".jsonl", ".json")

    # Parse the JSONL file
    messages, _ = parse_jsonl_output(jsonl_file)

    # Write as JSON array
    with open(json_file, "w") as f:
        json.dump(messages, f, indent=2)

    return json_file


def get_claude_env() -> Dict[str, str]:
    """Get only the required environment variables for Claude Code execution.

    This is a wrapper around get_safe_subprocess_env() from utils.py for
    backward compatibility. New code should use get_safe_subprocess_env() directly.

    Returns a dictionary containing only the necessary environment variables
    based on .env.sample configuration.
    """
    # Import here to avoid circular imports
    from .utils import get_safe_subprocess_env

    # Use the shared function
    return get_safe_subprocess_env()


def save_prompt(prompt: str, adw_id: str, agent_name: str = "ops") -> None:
    """Save a prompt to the appropriate logging directory."""
    # Extract slash command from prompt
    match = re.match(r"^(/\w+)", prompt)
    if not match:
        return

    slash_command = match.group(1)
    # Remove leading slash for filename
    command_name = slash_command[1:]

    # Create directory structure at project root (parent of adws)
    # __file__ is in adws/adw_modules/, so we need to go up 3 levels to get to project root
    project_root = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    prompt_dir = os.path.join(project_root, "agents", adw_id, agent_name, "prompts")
    os.makedirs(prompt_dir, exist_ok=True)

    # Save prompt to file
    prompt_file = os.path.join(prompt_dir, f"{command_name}.txt")
    with open(prompt_file, "w") as f:
        f.write(prompt)


def prompt_claude_code_with_retry(
    request: AgentPromptRequest,
    max_retries: int = 3,
    retry_delays: List[int] = None,
) -> AgentPromptResponse:
    """Execute Claude Code with retry logic for certain error types.

    Args:
        request: The prompt request configuration
        max_retries: Maximum number of retry attempts (default: 3)
        retry_delays: List of delays in seconds between retries (default: [1, 3, 5])

    Returns:
        AgentPromptResponse with output and retry code
    """
    if retry_delays is None:
        retry_delays = [1, 3, 5]

    # Ensure we have enough delays for max_retries
    while len(retry_delays) < max_retries:
        retry_delays.append(retry_delays[-1] + 2)  # Add incrementing delays

    last_response = None
    start_time = time.time()

    # Best-effort slash command extraction for observability
    command = None
    if request.prompt.startswith("/"):
        command = request.prompt.split()[0]

    # Observability is fail-silent: emit_event returning False is tolerated
    emit_event(
        request.adw_id,
        "agent",
        "agent_call_start",
        payload={
            "model": request.model,
            "agent_name": request.agent_name,
            "command": command,
            "output_file": request.output_file,
        },
        agent_name=request.agent_name,
    )

    for attempt in range(max_retries + 1):  # +1 for initial attempt
        if attempt > 0:
            # This is a retry
            delay = retry_delays[attempt - 1]
            emit_event(
                request.adw_id,
                "agent",
                "agent_call_retry",
                payload={
                    "attempt": attempt,
                    "retry_code": (
                        last_response.retry_code.value if last_response else None
                    ),
                    "delay": delay,
                },
                agent_name=request.agent_name,
            )
            time.sleep(delay)

        response = prompt_claude_code(request)
        last_response = response

        # Check if we should retry based on the retry code
        if response.success or response.retry_code == RetryCode.NONE:
            # Success or non-retryable error
            break

        # Check if this is a retryable error
        if response.retry_code in [
            RetryCode.CLAUDE_CODE_ERROR,
            RetryCode.TIMEOUT_ERROR,
            RetryCode.EXECUTION_ERROR,
            RetryCode.ERROR_DURING_EXECUTION,
        ]:
            if attempt < max_retries:
                continue
            else:
                break

    emit_event(
        request.adw_id,
        "agent",
        "agent_call_end",
        payload={
            "success": last_response.success if last_response else False,
            "retry_code": (
                last_response.retry_code.value if last_response else None
            ),
            "duration_ms": int((time.time() - start_time) * 1000),
        },
        agent_name=request.agent_name,
    )

    return last_response


def prompt_harness(request: AgentPromptRequest) -> AgentPromptResponse:
    """Execute the active coding-agent harness with the given prompt config.

    Routes through the harness adapter layer (``HARNESS_REGISTRY``): the adapter
    checks its binary, builds the CLI argv, and parses the resulting output into
    an ``AgentPromptResponse``. The active harness comes from the request
    (defaults claude), so the no-env default path is the historical Claude Code
    behaviour, byte-for-byte.
    """
    # Import here to avoid a circular import at module load time.
    from .harness import get_harness_adapter

    adapter = get_harness_adapter(request.harness)

    # Check if the harness binary is installed
    error_msg = adapter.check_installed()
    if error_msg:
        return AgentPromptResponse(
            output=error_msg,
            success=False,
            session_id=None,
            retry_code=RetryCode.NONE,  # Installation error is not retryable
        )

    # Save prompt before execution
    save_prompt(request.prompt, request.adw_id, request.agent_name)

    # Create output directory if needed
    output_dir = os.path.dirname(request.output_file)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    # Build the harness-specific command argv
    cmd = adapter.build_argv(request)

    # Set up environment with only required variables
    env = get_claude_env()

    try:
        # Open output file for streaming
        with open(request.output_file, "w") as output_f:
            result = subprocess.run(
                cmd,
                stdout=output_f,  # Stream directly to file
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                cwd=request.working_dir,  # Use working_dir if provided
            )

        # Delegate parsing of the harness output to the adapter
        return adapter.parse_output(
            request.output_file,
            result.returncode,
            result.stderr if result.stderr else "",
        )

    except subprocess.TimeoutExpired:
        error_msg = "Error: harness command timed out after 5 minutes"
        return AgentPromptResponse(
            output=error_msg,
            success=False,
            session_id=None,
            retry_code=RetryCode.TIMEOUT_ERROR,
        )
    except Exception as e:
        error_msg = f"Error executing harness: {e}"
        return AgentPromptResponse(
            output=error_msg,
            success=False,
            session_id=None,
            retry_code=RetryCode.EXECUTION_ERROR,
        )


# Backward-compatible alias: the engine and tests historically call
# prompt_claude_code; it now drives whichever harness the request selects.
def prompt_claude_code(request: AgentPromptRequest) -> AgentPromptResponse:
    """Backward-compatible shim — see ``prompt_harness``."""
    return prompt_harness(request)


def execute_template(request: AgentTemplateRequest) -> AgentPromptResponse:
    """Execute a Claude Code template with slash command and arguments.

    This function automatically selects the appropriate model based on:
    1. The slash command being executed
    2. The model_set stored in the ADW state (base or heavy)

    Example:
        request = AgentTemplateRequest(
            agent_name="planner",
            slash_command="/implement",
            args=["plan.md"],
            adw_id="abc12345"
        )
        # If state has model_set="heavy", this resolves the heavy tier
        # (claude/anthropic -> "opus"); base/missing resolves main -> "sonnet".
        response = execute_template(request)
    """
    from .harness import get_active_harness, get_active_provider, resolve_model

    # Resolve the abstract tier for this command, then the concrete model id for
    # the active harness/provider. With no env set this is claude/anthropic and
    # the same concrete models as before.
    tier = get_model_for_slash_command(request)
    harness = get_active_harness()
    provider = get_active_provider()
    concrete_model = resolve_model(tier, harness, provider)
    request = request.model_copy(
        update={
            "model": concrete_model,
            "harness": harness,
            "provider": provider,
            "tier": tier,
        }
    )

    # Construct prompt from slash command and args
    prompt = f"{request.slash_command} {' '.join(request.args)}"

    # Create output directory with adw_id at project root
    # __file__ is in adws/adw_modules/, so we need to go up 3 levels to get to project root
    project_root = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    output_dir = os.path.join(
        project_root, "agents", request.adw_id, request.agent_name
    )
    os.makedirs(output_dir, exist_ok=True)

    # Build output file path
    output_file = os.path.join(output_dir, "raw_output.jsonl")

    # Create prompt request with specific parameters
    prompt_request = AgentPromptRequest(
        prompt=prompt,
        adw_id=request.adw_id,
        agent_name=request.agent_name,
        model=request.model,
        harness=request.harness,
        provider=request.provider,
        tier=request.tier,
        dangerously_skip_permissions=True,
        output_file=output_file,
        working_dir=request.working_dir,  # Pass through working_dir
    )

    # Execute with retry logic and return response (prompt_claude_code now handles all parsing)
    return prompt_claude_code_with_retry(prompt_request)
