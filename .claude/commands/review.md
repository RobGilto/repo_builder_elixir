---
command: review
version: 1.0.0
---

# Review

Follow the `Instructions` below to **review work done against a specification file** (specs/*.md) to ensure implemented features match requirements. Use the spec file to understand the requirements and then use the git diff if available to understand the changes made. Capture screenshots of critical functionality paths as documented in the `Instructions` section. If there are issues, report them if not then report success.

## Variables

adw_id: $ARGUMENT
spec_file: $ARGUMENT
agent_name: $ARGUMENT if provided, otherwise use 'review_agent'
review_image_dir: `<absolute path to codebase>/agents/<adw_id>/<agent_name>/review_img/`

## Instructions

- Check current git branch using `git branch` to understand context
- Run `git diff origin/main` to see all changes made in current branch. Continue even if there are no changes related to the spec file.
- Find the spec file by looking for specs/*.md files in the diff that match the current branch name
- Read the identified spec file to understand requirements
- IMPORTANT: Verify the implementation against the spec using **Tidewave** runtime intelligence (Phoenix MCP at `http://localhost:4000/tidewave/mcp`) — this is the primary review mechanism for an Elixir/Phoenix app:
  - `project_eval` — evaluate Elixir in the running app to confirm the spec's behavior actually holds (e.g. drive a context function or OTP process and inspect the result), rather than only reading code.
  - `execute_sql_query` — confirm the spec's persistence requirements against the live DB (rows written, enums/JSONB round-trip, `cost_usd` NULL-vs-0, FK/unique constraints).
  - `get_logs` — confirm no errors/stacktraces and no secrets leaked into `agent_logs`/`system_logs` while exercising the path.
  - `get_docs` / `get_source_location` — resolve exact-version library behavior and jump to definitions while reviewing.
- IMPORTANT: If the work can be validated by UI validation then (if not skip the section):
  - The dashboard is Phoenix LiveView. Prefer Tidewave Web's browser verification + **vision mode** (screenshots/video) to capture visual proof. If Tidewave Web is unavailable, fall back to the Playwright MCP server against `http://localhost:4000`.
  - IMPORTANT: To be clear, we're not testing. We know the functionality works. We're reviewing the implementation against the spec to make sure it matches what was requested.
  - IMPORTANT: Take screen shots along the way to showcase the new functionality and any issues you find
    - Capture visual proof of working features through targeted screenshots
    - Navigate to the application and capture screenshots of only the critical paths based on the spec
    - Compare implemented changes with spec requirements to verify correctness
    - Do not take screenshots of the entire process, only the critical points.
    - IMPORTANT: Aim for `1-5` screenshots to showcase that the new functionality works as specified.
    - If there is a review issue, take a screenshot of the issue and add it to the `review_issues` array. Describe the issue, resolution, and severity.
    - Number your screenshots in the order they are taken like `01_<descriptive name>.png`, `02_<descriptive name>.png`, etc.
    - IMPORTANT: Be absolutely sure to take a screen shot of the critical point of the new functionality
    - IMPORTANT: Copy all screenshots to the provided `review_image_dir`
    - IMPORTANT: Store the screenshots in the `review_image_dir` and be sure to use full absolute paths.
    - Focus only on critical functionality paths - avoid unnecessary screenshots
    - Ensure screenshots clearly demonstrate that features work as specified
    - Use descriptive filenames that indicate what part of the change is being verified
- IMPORTANT: Issue Severity Guidelines
  - Think hard about the impact of the issue on the feature and the user
  - Guidelines:
    - `skippable` - the issue is non-blocker for the work to be released but is still a problem
    - `tech_debt` - the issue is non-blocker for the work to be released but will create technical debt that should be addressed in the future
    - `blocker` - the issue is a blocker for the work to be released and should be addressed immediately. It will harm the user experience or will not function as expected.
- IMPORTANT: Return ONLY the JSON array with test results
  - IMPORTANT: Output your result in JSON format based on the `Report` section below.
  - IMPORTANT: Do not include any additional text, explanations, or markdown formatting
  - We'll immediately run JSON.parse() on the output, so make sure it's valid JSON
- Ultra think as you work through the review process. Focus on the critical functionality paths and the user experience. Don't report issues if they are not critical to the feature.

## Setup

Prepare the Phoenix application for review:
- Ensure deps and DB are ready: `mix deps.get`, then `mix ecto.create && mix ecto.migrate` (skip if already provisioned).
- Start the server (Tidewave is mounted in dev via `plug Tidewave`, `{:tidewave, "~> 0.5", only: :dev}`): `mix phx.server`.
- The application URL is `http://localhost:4000` (override with the `PORT` env var or `.ports.env` if running in a worktree). The Tidewave MCP endpoint is `http://localhost:4000/tidewave/mcp`.
- If `.claude/commands/prepare_app.md` exists, you may read and execute it instead of the steps above.

## Report

- IMPORTANT: Return results exclusively as a JSON array based on the `Output Structure` section below.
- `success` should be `true` if there are NO BLOCKING issues (implementation matches spec for critical functionality)
- `success` should be `false` ONLY if there are BLOCKING issues that prevent the work from being released
- `review_issues` can contain issues of any severity (skippable, tech_debt, or blocker)
- `screenshots` should ALWAYS contain paths to screenshots showcasing the new functionality, regardless of success status. Use full absolute paths.
- This allows subsequent agents to quickly identify and resolve blocking errors while documenting all issues

### Output Structure

```json
{
    success: "boolean - true if there are NO BLOCKING issues (can have skippable/tech_debt issues), false if there are BLOCKING issues",
    review_summary: "string - 2-4 sentences describing what was built and whether it matches the spec. Written as if reporting during a standup meeting. Example: 'The natural language query feature has been implemented with drag-and-drop file upload and interactive table display. The implementation matches the spec requirements for SQL injection protection and supports both CSV and JSON formats. Minor UI improvements could be made but all core functionality is working as specified.'",
    review_issues: [
        {
            "review_issue_number": "number - the issue number based on the index of this issue",
            "screenshot_path": "string - /absolute/path/to/screenshot_that_shows_review_issue.png",
            "issue_description": "string - description of the issue",
            "issue_resolution": "string - description of the resolution",
            "issue_severity": "string - severity of the issue between 'skippable', 'tech_debt', 'blocker'"
        },
        ...
    ],
    screenshots: [
        "string - /absolute/path/to/screenshot_showcasing_functionality.png",
        "string - /absolute/path/to/screenshot_showcasing_functionality.png",
        "...",
    ]
}
