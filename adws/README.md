# AI Developer Workflow (ADW) System - Isolated Workflows

ADW automates software development using isolated git worktrees. The `_iso` suffix stands for "isolated" - these workflows run in separate git worktrees, enabling multiple agents to run at the same time in their own respective directories. Each workflow gets its own complete copy of the repository with dedicated ports and filesystem isolation.

## Key Concepts

### Isolated Execution
Every ADW workflow runs in an isolated git worktree under `trees/<adw_id>/` with:
- Complete filesystem isolation
- Dedicated port ranges (backend: 9100-9114, frontend: 9200-9214)
- Independent git branches
- Support for 15 concurrent instances

### ADW ID
Each workflow run is assigned a unique 8-character identifier (e.g., `a1b2c3d4`). This ID:
- Tracks all phases of a workflow (plan → build → test → review → document)
- Appears in GitHub comments, commits, and PR titles
- Creates an isolated worktree at `trees/{adw_id}/`
- Allocates unique ports deterministically
- Enables resuming workflows and debugging

### State Management
ADW uses persistent state files (`agents/{adw_id}/adw_state.json`) to:
- Share data between workflow phases
- Track worktree locations and port assignments
- Enable workflow composition and chaining
- Track essential workflow data:
  - `adw_id`: Unique workflow identifier
  - `issue_number`: GitHub issue being processed
  - `branch_name`: Git branch for changes
  - `plan_file`: Path to implementation plan
  - `issue_class`: Issue type (`/chore`, `/bug`, `/feature`)
  - `worktree_path`: Absolute path to isolated worktree
  - `backend_port`: Allocated backend port (9100-9114)
  - `frontend_port`: Allocated frontend port (9200-9214)

### Pluggable Harness, Provider & Model Tiers
The engine is harness-agnostic. A flat adapter layer
(`adw_modules/harness.py`) lets a step run through **Claude Code** (`claude`) or
the **pi coding agent** (`pi`), against any provider either supports
(`anthropic`, `openai`, `zai`, …). Models are addressed by an **abstract tier**
rather than a concrete id:

- **`fast` / `main` / `heavy`** — each `(harness, provider)` pair resolves a tier
  to a concrete model via `harness_catalog()` (claude+anthropic: `fast→haiku`,
  `main→sonnet`, `heavy→opus`). The `model_set` run-profile (`base`/`heavy`) now
  selects a *tier* per command instead of a concrete model.
- **Active selection** comes from env: `ADW_HARNESS` (default `claude`) and
  `ADW_PROVIDER` (default `anthropic`); `ADW_MODEL_{FAST,MAIN,HEAVY}` override
  the concrete id per tier. **With nothing set, behaviour is byte-for-byte the
  historical Claude Code + Anthropic path** (`main→sonnet`, `heavy→opus`).
- The orchestrator's gear (⚙) Settings panel writes the operator's choice to
  `orchestration/.harness.json`, which `adw_launcher` injects into each run.

See `app_docs/pi-harness-sdk.md` for the pi CLI/flag/event-stream reference.

## Quick Start

### 1. Set Environment Variables

```bash
export GITHUB_REPO_URL="https://github.com/owner/repository"
export ANTHROPIC_API_KEY="sk-ant-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export CLAUDE_CODE_PATH="/path/to/claude"  # Optional, defaults to "claude"
export GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # Optional, only if using different account than 'gh auth login'
```

### 2. Install Prerequisites

```bash
# GitHub CLI
brew install gh              # macOS
# or: sudo apt install gh    # Ubuntu/Debian
# or: winget install --id GitHub.cli  # Windows

# Claude Code CLI
# Follow instructions at https://docs.anthropic.com/en/docs/claude-code

# Python dependency manager (uv)
curl -LsSf https://astral.sh/uv/install.sh | sh  # macOS/Linux
# or: powershell -c "irm https://astral.sh/uv/install.ps1 | iex"  # Windows

# Authenticate GitHub
gh auth login
```

### 3. Run Isolated ADW Workflows

```bash
cd adws/

# Process a single issue in isolation (plan + build)
uv run adw_plan_build_iso.py 123

# Process with testing in isolation (plan + build + test)
uv run adw_plan_build_test_iso.py 123

# Process with review in isolation (plan + build + test + review)
uv run adw_plan_build_test_review_iso.py 123

# Process with review but skip tests (plan + build + review)
uv run adw_plan_build_review_iso.py 123

# Process with documentation (plan + build + document)
uv run adw_plan_build_document_iso.py 123

# Complete SDLC workflow in isolation
uv run adw_sdlc_iso.py 123

# Zero Touch Execution - Complete SDLC with auto-ship (⚠️ merges to main!)
uv run adw_sdlc_zte_iso.py 123

# Run individual isolated phases
uv run adw_plan_iso.py 123              # Planning phase (creates worktree)
uv run adw_patch_iso.py 123             # Patch workflow (creates worktree)
uv run adw_build_iso.py 123 <adw-id>    # Build phase (requires worktree)
uv run adw_test_iso.py 123 <adw-id>     # Test phase (requires worktree)
uv run adw_review_iso.py 123 <adw-id>   # Review phase (requires worktree)
uv run adw_document_iso.py 123 <adw-id> # Documentation phase (requires worktree)
uv run adw_ship_iso.py 123 <adw-id>     # Ship phase (approve & merge PR)

# Run continuous monitoring (polls every 20 seconds)
uv run adw_triggers/trigger_cron.py

# Start webhook server (for instant GitHub events)
uv run adw_triggers/trigger_webhook.py
```

## One-Shot Slash Command Runner (No Worktree)

#### adw_slash_command.py - Friendly single-command runner
The lowest-ceremony path in `adws/`: fire **one** slash command through Claude
Code's headless mode with **no GitHub issue, no worktree, and no ADW state**. It
reuses the existing engine (`prompt_claude_code_with_retry`) so retry, JSONL
parsing, prompt logging, and `--dangerously-skip-permissions` all come for free.

**Usage:**
```bash
uv run adws/adw_slash_command.py <command> [args...] \
  [--model sonnet|opus] [--agent-name NAME] [--adw-id ID] \
  [--working-dir PATH] [--json] [--dry-run]
```

- `<command>` — `/feature` or `feature` (a leading `/` is added if missing).
- `[args...]` — joined with spaces as the command argument string; flags/paths
  meant for the command (e.g. `specs/x.md`, `--foo`) pass through verbatim.
- `--model` (default `sonnet`, explicit value wins), `--agent-name` (default
  `ops`), `--adw-id` (default: fresh 8-char hex), `--working-dir` (default: repo
  root).
- `--json` — emit the structured `adw.slash_command.result/1` object as the
  **only** thing on stdout (logs go to stderr), so `… --json | jq` is clean.
- `--dry-run` — compose the prompt + request and print the would-be result;
  **never** invokes Claude (hermetic, offline). Exits 0.

Accepts **any** `/command` (not limited to the ADW `SlashCommand` registry).
Output is logged to `agents/<adw_id>/<agent>/raw_output.jsonl` like the rest of
the ADW system. Exit code is `0` on success, non-zero on failure (with
`retry_code` in the result); empty command → usage error, exit 2.

**Examples:**
```bash
# Drive any spec through the engine in one line (no issue plumbing):
uv run adws/adw_slash_command.py /build specs/issue-g-….md --json

# Inspect the composed prompt offline, no Claude call:
uv run adws/adw_slash_command.py /feature "specs/x.md" --dry-run --json
```

## ADW Isolated Workflow Scripts

### Entry Point Workflows (Create Worktrees)

#### adw_plan_iso.py - Isolated Planning
Creates isolated worktree and generates implementation plans.

**Usage:**
```bash
uv run adw_plan_iso.py <issue-number> [adw-id]
```

**What it does:**
1. Creates isolated git worktree at `trees/<adw_id>/`
2. Allocates unique ports (backend: 9100-9114, frontend: 9200-9214)
3. Sets up environment with `.ports.env`
4. Fetches issue details and classifies type
5. Creates feature branch in worktree
6. Generates implementation plan in isolation
7. Commits and pushes from worktree
8. Creates/updates pull request

#### adw_patch_iso.py - Isolated Patch Workflow
Quick patches in isolated environment triggered by 'adw_patch' keyword.

**Usage:**
```bash
uv run adw_patch_iso.py <issue-number> [adw-id]
```

**What it does:**
1. Searches for 'adw_patch' in issue/comments
2. Creates isolated worktree with unique ports
3. Creates targeted patch plan in isolation
4. Implements specific changes
5. Commits and creates PR from worktree

#### adw_plan_build_local_iso.py - GitHub-Optional Plan + Build (Local Launch Contract)
Plan + build driven entirely by a local run record — **no GitHub issue, no
remote, no `gh` required**. New in ADW 1.3.0.

**Usage:**
```bash
# 1. The launcher (orchestrator app, chat agent, or a one-liner) writes the
#    task context FIRST:
uv run python -c "import sys; sys.path.insert(0,'adws'); \
  from adw_modules import local_ops; \
  print(local_ops.create_run('ab12cd34','plan_build_local','Build a /health endpoint')['adw_id'])"
# 2. The workflow pulls everything from agents/<adw-id>/run.json:
uv run adws/adw_plan_build_local_iso.py ab12cd34
```

**What it does:**
1. Loads + validates `agents/<adw_id>/run.json` (`adw.run/1`, see
   `adw_modules/local_ops.py`); marks it `in_progress`
2. Synthesizes a local issue from the prompt (stable numeric id ≥ 9,000,000
   keeps `issue-{n}-adw-{id}` spec/branch conventions intact)
3. Creates worktree + ports + branch (falls back to local `main`/`master`
   when `origin/main` is unavailable — works on repos with no remote)
4. Plan step via `/feature` (agent `sdlc_planner`), build step via
   `/implement` (agent `sdlc_implementor`), commit in the worktree (no push)
5. Narrates all progress as `adw.event/1` lines (`source: "workflow"`,
   plus `step_start`/`step_end` swimlane markers) instead of issue comments
6. Optional enrichment: a real `input_data.issue_number` + working `gh` adds
   best-effort issue comments — failures never break the run

**Not webhook-launchable** (webhook triggers are issue-driven by definition)
and never in `DEPENDENT_WORKFLOWS` — it is an entry point.

### Local (GitHub-Optional) Entry-Point Workflows

All eight local workflows share the same contract as
`adw_plan_build_local_iso`: CLI takes only `<adw-id>`, all task context comes
from `agents/<adw_id>/run.json` (`adw.run/1`, see `adw_modules/local_ops.py`),
the issue is synthesized from the prompt, progress streams as `adw.event/1`
lines, and commits stay in the worktree (no push). A real
`input_data.issue_number` adds best-effort GitHub comments as optional
enrichment. None are webhook-launchable or in `DEPENDENT_WORKFLOWS`.

| Workflow | Phases | total_steps |
|---|---|---|
| `adw_plan_local_iso.py` | plan | 1 |
| `adw_patch_local_iso.py` | patch-plan + patch-implement (the prompt IS the patch spec — no `adw_patch` keyword needed) | 2 |
| `adw_plan_build_local_iso.py` | plan + build | 2 |
| `adw_plan_build_review_local_iso.py` | plan + build + review | 3 |
| `adw_plan_build_test_local_iso.py` | plan + build + test | 3 |
| `adw_plan_build_document_local_iso.py` | plan + build + document | 3 |
| `adw_plan_build_test_review_local_iso.py` | plan + build + test + review | 4 |
| `adw_sdlc_local_iso.py` | plan + build + test + review + document | 5 |

Local-mode simplifications for the test/review phases: E2E tests are always
skipped (prompt-mode runs have no guaranteed browser context) and the
test/review resolution loops are disabled — failures and blockers are
narrated as warnings (non-fatal gate), matching `adw_sdlc_iso`'s non-fatal
test phase. `--skip-e2e` / `--skip-resolution` are accepted for CLI
compatibility where the GitHub twin takes them.

**Usage (same for all):**
```bash
# 1. Write the run record (orchestrator app or local_ops.create_run)
# 2. Launch with the adw-id only:
uv run adws/adw_sdlc_local_iso.py <adw-id>
```

### Dependent Workflows (Require Existing Worktree)

#### adw_build_iso.py - Isolated Implementation
Implements solutions in existing isolated environment.

**Requirements:**
- Existing worktree created by `adw_plan_iso.py` or `adw_patch_iso.py`
- ADW ID is mandatory

**Usage:**
```bash
uv run adw_build_iso.py <issue-number> <adw-id>
```

**What it does:**
1. Validates worktree exists
2. Switches to correct branch if needed
3. Locates plan file in worktree
4. Implements solution in isolated environment
5. Commits and pushes from worktree

#### adw_test_iso.py - Isolated Testing
Runs tests in isolated environment.

**Requirements:**
- Existing worktree
- ADW ID is mandatory

**Usage:**
```bash
uv run adw_test_iso.py <issue-number> <adw-id> [--skip-e2e]
```

**What it does:**
1. Validates worktree exists
2. Runs tests with allocated ports
3. Auto-resolves failures in isolation
4. Optionally runs E2E tests
5. Commits results from worktree

#### adw_review_iso.py - Isolated Review
Reviews implementation in isolated environment.

**Requirements:**
- Existing worktree
- ADW ID is mandatory

**Usage:**
```bash
uv run adw_review_iso.py <issue-number> <adw-id> [--skip-resolution]
```

**What it does:**
1. Validates worktree exists
2. Reviews against spec in isolation
3. Captures screenshots using allocated ports
4. Auto-resolves blockers in worktree
5. Uploads screenshots and commits

#### adw_document_iso.py - Isolated Documentation
Generates documentation in isolated environment.

**Requirements:**
- Existing worktree
- ADW ID is mandatory

**Usage:**
```bash
uv run adw_document_iso.py <issue-number> <adw-id>
```

**What it does:**
1. Validates worktree exists
2. Analyzes changes in worktree
3. Generates documentation in isolation
4. Commits to `app_docs/` from worktree

### Orchestrator Scripts

#### adw_plan_build_iso.py - Isolated Plan + Build
Runs planning and building in isolation.

**Usage:**
```bash
uv run adw_plan_build_iso.py <issue-number> [adw-id]
```

#### adw_plan_build_test_iso.py - Isolated Plan + Build + Test
Full pipeline with testing in isolation.

**Usage:**
```bash
uv run adw_plan_build_test_iso.py <issue-number> [adw-id]
```

#### adw_plan_build_test_review_iso.py - Isolated Plan + Build + Test + Review
Complete pipeline with review in isolation.

**Usage:**
```bash
uv run adw_plan_build_test_review_iso.py <issue-number> [adw-id]
```

#### adw_plan_build_review_iso.py - Isolated Plan + Build + Review
Pipeline with review, skipping tests.

**Usage:**
```bash
uv run adw_plan_build_review_iso.py <issue-number> [adw-id]
```

#### adw_plan_build_document_iso.py - Isolated Plan + Build + Document
Documentation pipeline in isolation.

**Usage:**
```bash
uv run adw_plan_build_document_iso.py <issue-number> [adw-id]
```

#### adw_sdlc_iso.py - Complete Isolated SDLC
Full Software Development Life Cycle in isolation.

**Usage:**
```bash
uv run adw_sdlc_iso.py <issue-number> [adw-id] [--skip-e2e] [--skip-resolution]
```

**Phases:**
1. **Plan**: Creates worktree and implementation spec
2. **Build**: Implements solution in isolation
3. **Test**: Runs tests with dedicated ports
4. **Review**: Validates and captures screenshots
5. **Document**: Generates comprehensive docs

**Output:**
- Isolated worktree at `trees/<adw_id>/`
- Feature implementation on dedicated branch
- Test results with port isolation
- Review screenshots from isolated instance
- Complete documentation in `app_docs/`

#### adw_ship_iso.py - Approve and Merge PR
Final shipping phase that validates state and merges to main.

**Requirements:**
- Complete ADWState with all fields populated
- Existing worktree and PR
- ADW ID is mandatory

**Usage:**
```bash
uv run adw_ship_iso.py <issue-number> <adw-id>
```

**What it does:**
1. Validates all ADWState fields have values
2. Verifies worktree exists
3. Finds PR for the branch
4. Approves the PR
5. Merges PR to main using squash method

**State validation ensures:**
- `adw_id` is set
- `issue_number` is set
- `branch_name` exists
- `plan_file` was created
- `issue_class` was determined
- `worktree_path` exists
- `backend_port` and `frontend_port` allocated

#### adw_sdlc_zte_iso.py - Zero Touch Execution
Complete SDLC with automatic shipping - no human intervention required.

**Usage:**
```bash
uv run adw_sdlc_zte_iso.py <issue-number> [adw-id] [--skip-e2e] [--skip-resolution]
```

**Phases:**
1. **Plan**: Creates worktree and implementation spec
2. **Build**: Implements solution in isolation
3. **Test**: Runs tests (stops on failure)
4. **Review**: Validates implementation (stops on failure)
5. **Document**: Generates comprehensive docs
6. **Ship**: Automatically approves and merges PR

**⚠️ WARNING:** This workflow will automatically merge code to main if all phases pass!

**Output:**
- Complete feature implementation
- Automatic PR approval
- Code merged to main branch
- Production deployment

### Automation Triggers

#### trigger_cron.py - Polling Monitor
Continuously monitors GitHub for triggers.

**Usage:**
```bash
uv run adw_triggers/trigger_cron.py
```

**Triggers on:**
- New issues with no comments
- Any issue where latest comment is exactly "adw"
- Polls every 20 seconds

**Workflow selection:**
- Uses `adw_plan_build_iso.py` by default
- Supports all isolated workflows via issue body keywords

#### trigger_webhook.py - Real-time Events
Webhook server for instant GitHub event processing.

**Usage:**
```bash
uv run adw_triggers/trigger_webhook.py
```

**Configuration:**
- Default port: 8001
- Endpoints:
  - `/gh-webhook` - GitHub event receiver
  - `/health` - Health check
- GitHub webhook settings:
  - Payload URL: `https://your-domain.com/gh-webhook`
  - Content type: `application/json`
  - Events: Issues, Issue comments

**Security:**
- Validates GitHub webhook signatures
- Requires `GITHUB_WEBHOOK_SECRET` environment variable

## How ADW Works

1. **Issue Classification**: Analyzes GitHub issue and determines type:
   - `/chore` - Maintenance, documentation, refactoring
   - `/bug` - Bug fixes and corrections
   - `/feature` - New features and enhancements

2. **Planning**: `sdlc_planner` agent creates implementation plan with:
   - Technical approach
   - Step-by-step tasks
   - File modifications
   - Testing requirements

3. **Implementation**: `sdlc_implementor` agent executes the plan:
   - Analyzes codebase
   - Implements changes
   - Runs tests
   - Ensures quality

4. **Integration**: Creates git commits and pull request:
   - Semantic commit messages
   - Links to original issue
   - Implementation summary

## Common Usage Scenarios

### Process a bug report in isolation
```bash
# User reports bug in issue #789
uv run adw_plan_build_iso.py 789
# ADW creates isolated worktree, analyzes, creates fix, and opens PR
```

### Run multiple workflows concurrently
```bash
# Process three issues in parallel
uv run adw_plan_build_iso.py 101 &
uv run adw_plan_build_iso.py 102 &
uv run adw_plan_build_iso.py 103 &
# Each gets its own worktree and ports
```

### Run complete SDLC in isolation
```bash
# Full SDLC with review and documentation
uv run adw_sdlc_iso.py 789
# Creates worktree at trees/abc12345/
# Runs on ports 9107 (backend) and 9207 (frontend)
# Generates complete documentation with screenshots
```

### Zero Touch Execution (Auto-ship)
```bash
# Complete SDLC with automatic PR merge
uv run adw_sdlc_zte_iso.py 789
# ⚠️ WARNING: Automatically merges to main if all phases pass!
# Creates worktree, implements, tests, reviews, documents, and ships
```

### Manual shipping workflow
```bash
# After running SDLC, manually approve and merge
uv run adw_ship_iso.py 789 abc12345
# Validates all state fields are populated
# Approves PR
# Merges to main using squash method
```

### Run individual phases
```bash
# Plan only (creates worktree)
uv run adw_plan_iso.py 789

# Build in existing worktree
uv run adw_build_iso.py 789 abc12345

# Test in isolation
uv run adw_test_iso.py 789 abc12345

# Ship when ready
uv run adw_ship_iso.py 789 abc12345
```

### Enable automatic processing
```bash
# Start cron monitoring
uv run adw_triggers/trigger_cron.py
# New issues are processed automatically
# Users can comment "adw" to trigger processing
```

### Deploy webhook for instant response
```bash
# Start webhook server
uv run adw_triggers/trigger_webhook.py
# Configure in GitHub settings
# Issues processed immediately on creation
```

### Triggering Workflows via GitHub Issues

Include the workflow name in your issue body to trigger a specific isolated workflow:

**Available Workflows:**
- `adw_plan_iso` - Isolated planning only
- `adw_patch_iso` - Quick patch in isolation
- `adw_plan_build_iso` - Plan and build in isolation
- `adw_plan_build_test_iso` - Plan, build, and test in isolation
- `adw_plan_build_test_review_iso` - Plan, build, test, and review in isolation
- `adw_sdlc_iso` - Complete SDLC in isolation

**Example Issue:**
```
Title: Add export functionality
Body: Please add the ability to export data to CSV.
Include workflow: adw_plan_build_iso
```

**Note:** Dependent workflows (`adw_build_iso`, `adw_test_iso`, `adw_review_iso`, `adw_document_iso`) require an existing worktree and cannot be triggered directly via webhook.

## Worktree Architecture

### Worktree Structure

```
trees/
├── abc12345/              # Complete repo copy for ADW abc12345
│   ├── .git/              # Worktree git directory
│   ├── .env               # Copied from main repo
│   ├── .ports.env         # Port configuration
│   ├── app/               # Application code
│   ├── adws/              # ADW scripts
│   └── ...
└── def67890/              # Another isolated instance
    └── ...

agents/                    # Shared state location (not in worktree)
├── abc12345/
│   └── adw_state.json     # Persistent state
└── def67890/
    └── adw_state.json
```

### Port Allocation

Each isolated instance gets unique ports:
- Backend: 9100-9114 (15 ports)
- Frontend: 9200-9214 (15 ports)
- Deterministic assignment based on ADW ID hash
- Automatic fallback if preferred ports are busy

**Port Assignment Algorithm:**
```python
def get_ports_for_adw(adw_id: str) -> Tuple[int, int]:
    """Deterministically assign ports based on ADW ID."""
    index = int(adw_id[:8], 36) % 15
    backend_port = 9100 + index
    frontend_port = 9200 + index
    return backend_port, frontend_port
```

**Example Allocations:**
```
ADW abc12345: Backend 9107, Frontend 9207
ADW def67890: Backend 9103, Frontend 9203
```

### Benefits of Isolated Workflows

1. **Parallel Execution**: Run up to 15 ADWs simultaneously
2. **No Interference**: Each instance has its own:
   - Git worktree and branch
   - Filesystem (complete repo copy)
   - Backend and frontend ports
   - Environment configuration
3. **Clean Isolation**: Changes in one instance don't affect others
4. **Easy Cleanup**: Remove worktree to clean everything
5. **Better Debugging**: Isolated environment for troubleshooting
6. **Experiment Safely**: Test changes without affecting main repo

### Cleanup and Maintenance

Worktrees persist until manually removed:

```bash
# Remove specific worktree
git worktree remove trees/abc12345

# List all worktrees
git worktree list

# Clean up worktrees (removes invalid entries)
git worktree prune

# Remove worktree directory if git doesn't know about it
rm -rf trees/abc12345
```

**Best Practices:**
- Remove worktrees after PR merge
- Monitor disk usage (each worktree is a full repo copy)
- Use `git worktree prune` periodically
- Consider automation for cleanup after 7 days

## Troubleshooting

### Environment Issues
```bash
# Check required variables
env | grep -E "(GITHUB|ANTHROPIC|CLAUDE)"

# Verify GitHub auth
gh auth status

# Test Claude Code
claude --version
```

### Common Errors

**"No worktree found"**
```bash
# Check if worktree exists
git worktree list
# Run an entry point workflow first
uv run adw_plan_iso.py <issue-number>
```

**"Port already in use"**
```bash
# Check what's using the port
lsof -i :9107
# Kill the process or let ADW find alternative ports
```

**"Worktree validation failed"**
```bash
# Check worktree state
cat agents/<adw-id>/adw_state.json | jq .worktree_path
# Verify directory exists
ls -la trees/<adw-id>/
```

**"Agent execution failed"**
```bash
# Check agent output in worktree
cat trees/<adw-id>/agents/*/planner/raw_output.jsonl | tail -1 | jq .
```

### Debug Mode
```bash
export ADW_DEBUG=true
uv run adw_plan_build_iso.py 123  # Verbose output
```

## Configuration

### ADW Tracking
Each workflow run gets a unique 8-character ID (e.g., `a1b2c3d4`) that appears in:
- Issue comments: `a1b2c3d4_ops: ✅ Starting ADW workflow`
- Output files: `agents/a1b2c3d4/sdlc_planner/raw_output.jsonl`
- Git commits and PRs

### Model Selection

ADW supports dynamic model selection based on workflow complexity. Users can specify whether to use a "base" model set (optimized for speed and cost) or a "heavy" model set (optimized for complex tasks).

#### How to Specify Model Set

Include `model_set base` or `model_set heavy` in your GitHub issue or comment:

```
Title: Add export functionality  
Body: Please add the ability to export data to CSV.
Include workflow: adw_plan_build_iso model_set heavy
```

If not specified, the system defaults to "base".

#### Model Mapping

Each slash command has a configured model for both base and heavy sets:

```python
SLASH_COMMAND_MODEL_MAP = {
    "/implement": {"base": "sonnet", "heavy": "opus"},
    "/review": {"base": "sonnet", "heavy": "opus"},
    "/classify_issue": {"base": "sonnet", "heavy": "sonnet"},
    # ... etc
}
```

#### Commands Using Opus in Heavy Mode

The following commands switch to Opus when using the heavy model set:
- `/implement` - Complex implementation tasks
- `/resolve_failed_test` - Debugging test failures
- `/resolve_failed_e2e_test` - Debugging E2E test failures
- `/document` - Documentation generation
- `/chore`, `/bug`, `/feature` - Issue-specific implementations
- `/planf3` - HTML-first planning (repo-vendored planf3 format)
- `/patch` - Creating patches for changes

#### HTML plans (planf3)

The plan step can author **HTML-first planf3 plans** instead of the markdown
`/feature`-family templates. Set the environment variable
`ADW_PLAN_COMMAND=/planf3` (validated against the plan-capable set
`/planf3|/feature|/bug|/chore`; unknown values warn and fall back to the
classified issue class). The override reroutes only the plan step — issue
classification and branch naming still use the class commands.

- Output: `specs/issue-{n}-adw-{id}-sdlc_planner-{name}.html` (same stem as the
  markdown specs; `find_spec_file` and the local fallbacks discover both
  `.md` and `.html`).
- Consumption: `/implement` and `/implement_elixir` execute planf3 phases
  top-to-bottom and flip the plan's `[]`/`[wip]`/`[x]` status markers in place
  (semantics: `ai_docs/planf3/build-plan.md`).
- Images: controlled by `PLANF3_IMAGES` (`placeholders` default — stock library
  at `specs/.planf3-assets/placeholders/`, zero OpenAI cost; `none`; `generate`
  — requires `OPENAI_API_KEY`, injected from the platform secrets vault). The
  console setting "Plan images: use placeholders" drives this variable.

#### Model Selection Flow

1. User triggers workflow with optional `model_set` parameter
2. ADW extracts and stores model_set in state (defaults to "base")
3. Each slash command execution:
   - Loads state to get model_set
   - Looks up appropriate model from SLASH_COMMAND_MODEL_MAP
   - Executes with selected model

#### Testing Model Selection

```bash
python adws/adw_tests/test_model_selection.py
```

This verifies:
- All commands have both base and heavy mappings
- Model selection logic works correctly
- State persistence includes model_set
- Default behavior when no state exists

### Modular Architecture
The system uses a modular architecture optimized for isolated execution:

- **State Management**: `ADWState` tracks worktree paths and ports
- **Worktree Operations**: `worktree_ops.py` manages isolated environments
- **Git Operations**: `git_ops.py` supports `cwd` parameter for worktree context
- **Workflow Operations**: Core logic in `workflow_ops.py` with `working_dir` support
- **Agent Integration**: `agent.py` executes Claude Code in worktree context

### Workflow Output Structure

Each ADW workflow creates an isolated workspace:

```
agents/
└── {adw_id}/                     # Unique workflow directory
    ├── adw_state.json            # Persistent state file
    ├── {adw_id}_plan_spec.md     # Implementation plan
    ├── planner/                  # Planning agent output
    │   └── raw_output.jsonl      # Claude Code session
    ├── implementor/              # Implementation agent output
    │   └── raw_output.jsonl
    ├── tester/                   # Test agent output
    │   └── raw_output.jsonl
    ├── reviewer/                 # Review agent output
    │   ├── raw_output.jsonl
    │   └── review_img/           # Screenshots directory
    ├── documenter/               # Documentation agent output
    │   └── raw_output.jsonl
    └── patch_*/                  # Patch resolution attempts

app_docs/                         # Generated documentation
└── features/
    └── {feature_name}/
        ├── overview.md
        ├── technical-guide.md
        └── images/
```

## Structured Observability Events

Beyond issue comments, `execution.log` files, and `adw_state.json`, the engine
emits a machine-readable event stream: versioned JSON lines (schema
`adw.event/1`) appended to `agents/<adw_id>/events.jsonl` by
`adw_modules/observability.py`. This is the stable, zero-dependency contract an
orchestration app tails or polls — no PostgreSQL, no WebSockets required.

**Event schema** (`adw.event/1`) — one JSON object per line:

```json
{
  "schema": "adw.event/1",
  "ts": "<ISO-8601 UTC>",
  "adw_id": "abc12345",
  "source": "agent | state | workflow",
  "event_type": "agent_call_start | agent_call_retry | agent_call_end | state_saved | ...",
  "agent_name": "sdlc_planner",
  "payload": {},
  "summary": null
}
```

**Two engine chokepoints** emit automatically (no workflow script was edited):

- `agent.prompt_claude_code_with_retry()` — every engine agent call passes
  through it (including `execute_template` and `adw_slash_command.py`). Emits
  `agent_call_start` (model, agent_name, best-effort `command`, output_file),
  `agent_call_retry` (attempt, retry_code, delay), and `agent_call_end`
  (success, retry_code, duration_ms).
- `ADWState.save()` — emits `state_saved` (workflow_step + the full state
  snapshot) after each successful state write.

**Properties:**

- **Fail-silent.** `emit_event` never raises; any failure returns `False` and
  the workflow proceeds unaffected. Non-serializable payloads degrade to
  `str()` and still emit.
- **Kill switch.** `ADW_EVENTS_DISABLED=1` suppresses all writes (emits return
  `False`, nothing touches disk).
- **Module-anchored paths.** Resolution mirrors `ADWState.get_state_path()` —
  the root is the checkout containing `adws/`, never the cwd — so events land
  beside `adw_state.json` under `agents/<adw_id>/`. Pass `working_dir` to
  override explicitly.
- **Per-adw_id isolation.** Concurrent ADWs append to different files; no
  shared-file contention.

**Reading the stream:** `observability.read_events(adw_id)` returns the parsed
list (malformed lines skipped silently, `[]` if absent) — this is the polling
seam a generated orchestration app builds on. Hermetic tests:
`uv run adw_tests/test_observability.py`.

## Security Best Practices

- Store tokens as environment variables, never in code
- Use GitHub fine-grained tokens with minimal permissions
- Set up branch protection rules
- Require PR reviews for ADW changes
- Monitor API usage and set billing alerts

## Technical Details

### Core Components

#### Modules
- `adw_modules/agent.py` - Claude Code CLI integration with worktree support
- `adw_modules/data_types.py` - Pydantic models including worktree fields
- `adw_modules/github.py` - GitHub API operations
- `adw_modules/git_ops.py` - Git operations with `cwd` parameter support
- `adw_modules/state.py` - State management tracking worktrees and ports
- `adw_modules/workflow_ops.py` - Core workflow operations with isolation
- `adw_modules/worktree_ops.py` - Worktree and port management
- `adw_modules/utils.py` - Utility functions

#### Entry Point Workflows (Create Worktrees)
- `adw_plan_iso.py` - Isolated planning workflow
- `adw_patch_iso.py` - Isolated patch workflow

#### Dependent Workflows (Require Worktrees)
- `adw_build_iso.py` - Isolated implementation workflow
- `adw_test_iso.py` - Isolated testing workflow
- `adw_review_iso.py` - Isolated review workflow
- `adw_document_iso.py` - Isolated documentation workflow

#### Orchestrators
- `adw_plan_build_iso.py` - Plan & build in isolation
- `adw_plan_build_test_iso.py` - Plan & build & test in isolation
- `adw_plan_build_test_review_iso.py` - Plan & build & test & review in isolation
- `adw_plan_build_review_iso.py` - Plan & build & review in isolation
- `adw_plan_build_document_iso.py` - Plan & build & document in isolation
- `adw_sdlc_iso.py` - Complete SDLC in isolation

### Branch Naming
```
{type}-{issue_number}-{adw_id}-{slug}
```
Example: `feat-456-e5f6g7h8-add-user-authentication`
