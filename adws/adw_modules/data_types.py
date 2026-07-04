"""Data types for GitHub API responses and Claude Code agent."""

from datetime import datetime
from typing import Optional, List, Literal
from pydantic import BaseModel, Field
from enum import Enum


# Retry codes for Claude Code execution errors
class RetryCode(str, Enum):
    """Codes indicating different types of errors that may be retryable."""

    CLAUDE_CODE_ERROR = "claude_code_error"  # General Claude Code CLI error
    TIMEOUT_ERROR = "timeout_error"  # Command timed out
    EXECUTION_ERROR = "execution_error"  # Error during execution
    ERROR_DURING_EXECUTION = "error_during_execution"  # Agent encountered an error
    NONE = "none"  # No retry needed


# Supported slash commands for issue classification
# These should align with your custom slash commands in .claude/commands that you want to run
IssueClassSlashCommand = Literal["/chore", "/bug", "/feature"]

# Model set types for ADW workflows (run-profile: selects a tier per command)
ModelSet = Literal["base", "heavy"]

# Coding-agent harness the engine shells out to.
# "claude" = Claude Code (the historical default), "pi" = the pi coding agent.
Harness = Literal["claude", "pi"]

# LLM provider the harness talks to. Claude Code is implicitly "anthropic";
# pi spans many providers (extensible — these are the ones the catalog knows).
Provider = Literal["anthropic", "openai", "zai", "minimax"]

# Abstract model tier. Each (harness, provider) resolves a tier to a concrete
# model id (e.g. claude+anthropic: fast->haiku, main->sonnet, heavy->opus).
ModelTier = Literal["fast", "main", "heavy"]

# ADW workflow types (all isolated now)
ADWWorkflow = Literal[
    "adw_plan_iso",  # Planning only
    "adw_patch_iso",  # Direct patch from issue
    "adw_build_iso",  # Building only (dependent workflow)
    "adw_test_iso",  # Testing only (dependent workflow)
    "adw_review_iso",  # Review only (dependent workflow)
    "adw_document_iso",  # Documentation only (dependent workflow)
    "adw_ship_iso",  # Ship/deployment workflow
    "adw_sdlc_ZTE_iso",  # Zero Touch Execution - full SDLC with auto-merge
    "adw_plan_build_iso",  # Plan + Build
    "adw_plan_build_local_iso",  # Plan + Build from a local run.json (GitHub-optional)
    "adw_plan_local_iso",  # Plan only from a local run.json (GitHub-optional)
    "adw_patch_local_iso",  # Patch from a local run.json (GitHub-optional)
    "adw_plan_build_review_local_iso",  # Plan + Build + Review from a local run.json (GitHub-optional)
    "adw_plan_build_test_local_iso",  # Plan + Build + Test from a local run.json (GitHub-optional)
    "adw_plan_build_test_review_local_iso",  # Plan + Build + Test + Review from a local run.json (GitHub-optional)
    "adw_plan_build_document_local_iso",  # Plan + Build + Document from a local run.json (GitHub-optional)
    "adw_sdlc_local_iso",  # Full SDLC from a local run.json (GitHub-optional)
    "adw_plan_build_test_iso",  # Plan + Build + Test
    "adw_plan_build_test_review_iso",  # Plan + Build + Test + Review
    "adw_plan_build_document_iso",  # Plan + Build + Document
    "adw_plan_build_review_iso",  # Plan + Build + Review
    "adw_sdlc_iso",  # Complete SDLC: Plan + Build + Test + Review + Document
]

# All slash commands used in the ADW system
# Includes issue classification commands and ADW-specific commands
SlashCommand = Literal[
    # Issue classification commands
    "/chore",
    "/bug",
    "/feature",
    # ADW workflow commands
    "/planf3",  # HTML-first planner (repo-vendored planf3; plan-step alternative to the class commands)
    "/classify_issue",
    "/classify_adw",
    "/generate_branch_name",
    "/commit",
    "/pull_request",
    "/implement",
    "/test",
    "/resolve_failed_test",
    "/test_e2e",
    "/resolve_failed_e2e_test",
    "/review",
    "/patch",
    "/document",
    "/track_agentic_kpis",
    # Installation/setup commands
    "/install_worktree",
]


class GitHubUser(BaseModel):
    """GitHub user model."""

    id: Optional[str] = None  # Not always returned by GitHub API
    login: str
    name: Optional[str] = None
    is_bot: bool = Field(default=False, alias="is_bot")


class GitHubLabel(BaseModel):
    """GitHub label model."""

    id: str
    name: str
    color: str
    description: Optional[str] = None


class GitHubMilestone(BaseModel):
    """GitHub milestone model."""

    id: str
    number: int
    title: str
    description: Optional[str] = None
    state: str


class GitHubComment(BaseModel):
    """GitHub comment model."""

    id: str
    author: GitHubUser
    body: str
    created_at: datetime = Field(alias="createdAt")
    updated_at: Optional[datetime] = Field(
        None, alias="updatedAt"
    )  # Not always returned


class GitHubIssueListItem(BaseModel):
    """GitHub issue model for list responses (simplified)."""

    number: int
    title: str
    body: str
    labels: List[GitHubLabel] = []
    created_at: datetime = Field(alias="createdAt")
    updated_at: datetime = Field(alias="updatedAt")

    class Config:
        populate_by_name = True


class GitHubIssue(BaseModel):
    """GitHub issue model."""

    number: int
    title: str
    body: str
    state: str
    author: GitHubUser
    assignees: List[GitHubUser] = []
    labels: List[GitHubLabel] = []
    milestone: Optional[GitHubMilestone] = None
    comments: List[GitHubComment] = []
    created_at: datetime = Field(alias="createdAt")
    updated_at: datetime = Field(alias="updatedAt")
    closed_at: Optional[datetime] = Field(None, alias="closedAt")
    url: str

    class Config:
        populate_by_name = True


class AgentPromptRequest(BaseModel):
    """Coding-agent prompt configuration (harness-agnostic).

    ``model`` is the resolved *concrete* model id the harness receives
    (e.g. "sonnet", "opus", "glm-5.1"). ``harness``/``provider``/``tier``
    carry the abstraction the engine resolved that id from; defaults keep the
    historical claude/anthropic/main behaviour when nothing is configured.
    """

    prompt: str
    adw_id: str
    agent_name: str = "ops"
    model: str = "sonnet"
    harness: Harness = "claude"
    provider: Provider = "anthropic"
    tier: ModelTier = "main"
    dangerously_skip_permissions: bool = False
    output_file: str
    working_dir: Optional[str] = None


class AgentPromptResponse(BaseModel):
    """Claude Code agent response."""

    output: str
    success: bool
    session_id: Optional[str] = None
    retry_code: RetryCode = RetryCode.NONE


class AgentTemplateRequest(BaseModel):
    """Coding-agent template execution request (harness-agnostic).

    ``model`` is populated by ``execute_template`` with the concrete model id
    resolved from the per-command tier and the active harness/provider.
    """

    agent_name: str
    slash_command: SlashCommand
    args: List[str]
    adw_id: str
    model: str = "sonnet"
    harness: Harness = "claude"
    provider: Provider = "anthropic"
    tier: ModelTier = "main"
    working_dir: Optional[str] = None


class ClaudeCodeResultMessage(BaseModel):
    """Claude Code JSONL result message (last line)."""

    type: str
    subtype: str
    is_error: bool
    duration_ms: int
    duration_api_ms: int
    num_turns: int
    result: str
    session_id: str
    total_cost_usd: float


class TestResult(BaseModel):
    """Individual test result from test suite execution."""

    test_name: str
    passed: bool
    execution_command: str
    test_purpose: str
    error: Optional[str] = None


class E2ETestResult(BaseModel):
    """Individual E2E test result from browser automation."""

    test_name: str
    status: Literal["passed", "failed"]
    test_path: str  # Path to the test file for re-execution
    screenshots: List[str] = []
    error: Optional[str] = None

    @property
    def passed(self) -> bool:
        """Check if test passed."""
        return self.status == "passed"


class ADWStateData(BaseModel):
    """Minimal persistent state for ADW workflow.

    Stored in agents/{adw_id}/adw_state.json
    Contains only essential identifiers to connect workflow steps.
    """

    adw_id: str
    issue_number: Optional[str] = None
    branch_name: Optional[str] = None
    plan_file: Optional[str] = None
    issue_class: Optional[IssueClassSlashCommand] = None
    worktree_path: Optional[str] = None
    backend_port: Optional[int] = None
    frontend_port: Optional[int] = None
    model_set: Optional[ModelSet] = "base"  # Default to "base" model set
    all_adws: List[str] = Field(default_factory=list)


class ReviewIssue(BaseModel):
    """Individual review issue found during spec verification."""

    review_issue_number: int
    screenshot_path: str  # Local file path to screenshot (e.g., "agents/ADW-123/reviewer/review_img/error.png")
    screenshot_url: Optional[str] = (
        None  # Public URL after upload (e.g., "https://domain.com/adw/ADW-123/review/error.png")
    )
    issue_description: str
    issue_resolution: str
    issue_severity: Literal["skippable", "tech_debt", "blocker"]


class ReviewResult(BaseModel):
    """Result from reviewing implementation against specification."""

    success: bool
    review_summary: (
        str  # 2-4 sentences describing what was built and whether it matches the spec
    )
    review_issues: List[ReviewIssue] = []
    screenshots: List[str] = (
        []
    )  # Local file paths (e.g., ["agents/ADW-123/reviewer/review_img/ui.png"])
    screenshot_urls: List[str] = (
        []
    )  # Public URLs after upload, indexed-aligned with screenshots


class DocumentationResult(BaseModel):
    """Result from documentation generation workflow."""

    success: bool
    documentation_created: bool
    documentation_path: Optional[str] = None
    error_message: Optional[str] = None


class ADWExtractionResult(BaseModel):
    """Result from extracting ADW information from text."""
    
    workflow_command: Optional[str] = None  # e.g., "adw_plan_iso" (without slash)
    adw_id: Optional[str] = None  # 8-character ADW ID
    model_set: Optional[ModelSet] = "base"  # Model set to use, defaults to "base"
    
    @property
    def has_workflow(self) -> bool:
        """Check if a workflow command was extracted."""
        return self.workflow_command is not None
