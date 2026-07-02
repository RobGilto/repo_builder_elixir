# Bug: Worker spec stage truncation — specs delivered inline via inspect_repo exceed 8 KB cap

## Metadata
issue_number: `log-40875`
adw_id: `spec-delivery`
issue_json: `log-40875-to-log-40888-worker-spec-truncation`

## Bug Description

When the orchestrator drives a workstream's `:spec` stage, it dispatches `/feature` / `/bug` /
`/chore` / `/plan` to a worker. The worker saves the spec to `specs/*.md` and returns the path.
The orchestrator then calls `inspect_repo(op: "read_file", path: "specs/...")` to verify the
spec was produced (per the `leader_expertise_block` "VERIFY, never assume" rule).

`inspect_repo` `read_file` has a hard `@inspect_read_cap 8_000` byte cap. Any spec larger than
8 KB is returned with `"truncated": true`. In log-40875 the orchestrator's thinking explicitly
states "The spec is truncated" — the spec content ends mid-sentence and the orchestrator cannot
verify that the spec is complete or correct. This forces additional turns to re-investigate and
wastes orchestrator context on verification that yields incomplete information.

**Affected logs:** log-40875 through log-40888 (orchestrator `glm-5.2` reviewing autocomplete
spec + supervisor `glm-4.6` running test suite).

## Problem Statement

Orchestrator agents MUST verify spec stage output before recording `record_stage("spec", "passed")`.
The verify step (`inspect_repo / read_file`) returns truncated content for any spec >8 KB, so
the orchestrator cannot confirm the spec is complete. This produces an epistemic gap: the
orchestrator either (a) trusts a partial read and records a potentially incomplete spec, or (b)
spends extra turns re-investigating.

## Solution Statement

Change where spec-stage workers SAVE the spec file and what they DELIVER to the orchestrator:

1. **Save to `ai_docs/`** — Spec workers save the spec to `ai_docs/<phase-title>-spec.md`
   (NOT in `specs/`). This is the established platform pattern for agent-written documents
   referenced by path (handovers, worker reports, analysis docs all go to `ai_docs/`).

2. **Deliver the file ADDRESS** — The worker's final message is exclusively the `ai_docs/` path.
   The orchestrator receives this path, records it via `record_stage(artifact: "<path>")`, and
   does NOT attempt `inspect_repo(read_file)` on the spec. The returned path is proof the file
   was written — content verification is unnecessary for the spec stage (the implement stage
   worker reads it directly from disk). The orchestrator only needs to confirm the path is
   non-blank and starts with `ai_docs/`.

This approach is O(1) in spec size: delivering a path never truncates regardless of how large
the spec grows.

**What changes:**
- `system_prompt.ex` `phased_delivery_block` — spec stage dispatch instruction updated to tell
  the worker to save to `ai_docs/` and return the path; orchestrator told NOT to read back
  content.
- `.claude/commands/plan.md` — add override clause to honor an explicit `ai_docs/` save
  instruction in the task description.
- `.claude/commands/bug.md` — same.
- `.claude/commands/feature.md` — same.
- `.claude/commands/chore.md` — same.

## Steps to Reproduce

1. Run an orchestrator with a multi-phase workstream.
2. Observe the spec stage: orchestrator dispatches `/plan <task>` → worker saves to
   `specs/issue-...md` → worker returns path.
3. Orchestrator calls `inspect_repo(op: "read_file", path: "specs/...")`.
4. The spec is > 8 KB → response includes `"truncated": true` → orchestrator cannot verify.

## Root Cause Analysis

`read_file_jailed/2` in `tools.ex` caps content at `@inspect_read_cap` (8 000 chars):
```elixir
@inspect_read_cap 8_000
# ...
"content" => cap_text(content),
"truncated" => byte_size(content) > @inspect_read_cap
```

Detailed spec plans (bug plans, feature plans) routinely exceed 8 KB because they include:
- Full codebase-relevant file lists
- Step-by-step tasks with bullet points
- Validation commands
- Plan format boilerplate

The `phased_delivery_block` system prompt tells the orchestrator:
> "dispatch `/feature`|`/bug`|`/chore`|`/plan` to produce a `specs/…md`,
> then `record_stage(stage: "spec", outcome: "passed", artifact: "<spec_path>")`"

And `leader_expertise_block` says:
> "VERIFY, never assume: do NOT trust a worker's claim. Use `inspect_repo` (read_file)
> to check the ACTUAL tree."

Together these drive the orchestrator to read back the spec content, hitting the cap on large
specs. The fix removes the content-read verification requirement for the spec stage entirely —
the path returned by the worker is sufficient proof (files don't appear in the working tree
unless written).

## Relevant Files

- `lib/repo_builder/orchestrator/system_prompt.ex` — contains `phased_delivery_block/0`
  (lines ~577-618) and `leader_expertise_block/0` (lines ~540-569); the spec stage dispatch
  instruction must be updated here.
- `.claude/commands/plan.md` — `/plan` command; saves to `specs/`; needs override clause for
  explicit `ai_docs/` save instructions in the task.
- `.claude/commands/bug.md` — `/bug` command; same.
- `.claude/commands/feature.md` — `/feature` command; same.
- `.claude/commands/chore.md` — `/chore` command; same.

No new files. No migrations. No runtime code changes. No library additions.

## Step by Step Tasks

### 1. Update `phased_delivery_block` in `system_prompt.ex`

Change the `* spec:` line in `phased_delivery_block/0` to instruct the orchestrator to:
- Tell the dispatched spec worker to save to `ai_docs/<phase-title>-spec.md`
- Receive only the `ai_docs/` path from the worker's final message
- Record the path as the artifact immediately — no `inspect_repo(read_file)` on the spec

**Old text (line ~586-587):**
```
    * spec: dispatch `/feature` | `/bug` | `/chore` | `/plan` to produce a `specs/…md`,
      then `record_stage(stage: "spec", outcome: "passed", artifact: "<spec_path>")`.
```

**New text:**
```
    * spec: dispatch `/feature` | `/bug` | `/chore` | `/plan` with this explicit instruction
      appended to the task message: "Save the spec to `ai_docs/<phase-title>-spec.md` (NOT in
      `specs/`) and return ONLY that `ai_docs/` path as your final message." When the worker
      returns the path, call `record_stage(stage: "spec", outcome: "passed", artifact:
      "<ai_docs_path>")`. Do NOT call `inspect_repo(read_file)` on the spec file — specs can
      exceed the 8 KB read cap and will be truncated; the returned `ai_docs/` path IS the
      deliverable (the implement stage reads it from disk directly).
```

### 2. Add save-location override to `/plan.md`

In `.claude/commands/plan.md`, add a clause to the `## Workflow` section (after the "If no
`prompt` is provided" line) so the worker honors an explicit `ai_docs/` path instruction:

```
- If the task description contains an explicit save-location instruction (e.g., "Save the
  spec to `ai_docs/<name>-spec.md`"), save the plan to that location instead of `specs/`.
  Return the exact path where the file was saved.
```

Also update the filename line in the Workflow so it reads:
```
- Create the plan in `specs/` (default) or in the path specified by any save-location
  instruction in the task, with filename `issue-{adw_id}-adw-{adw_id}-sdlc_planner-{descriptive-name}.md`
  (for `specs/`) or `<phase-title>-spec.md` (for `ai_docs/`).
```

### 3. Add save-location override to `/bug.md`

Same clause in `.claude/commands/bug.md`'s `## Instructions` section (after the "minimal number
of changes" bullet):

```
- If the task description contains an explicit save-location instruction (e.g., "Save the spec
  to `ai_docs/<name>-spec.md`"), save the plan to that location instead of the default
  `specs/` directory. Return the exact `ai_docs/` path where the file was saved.
```

### 4. Add save-location override to `/feature.md`

Same clause in `.claude/commands/feature.md`'s `## Instructions` section.

### 5. Add save-location override to `/chore.md`

Same clause in `.claude/commands/chore.md`'s `## Instructions` section.

### 6. Run the validation gate

Execute all commands in the **Validation Commands** section below.

## Validation Commands

These are all prompt-file changes (no Elixir code changed), so the compile/dialyzer/credo
gates are sufficient to confirm zero regressions.

- `mix compile --warnings-as-errors` — compile clean; no Elixir code changed but still must pass.
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures (no test code changed).
- `mix format --check-formatted` — formatting (no Elixir code changed).
- `mix credo --strict` — lint pass (no Elixir code changed).
- `mix dialyzer` — no new warnings (no Elixir code changed).

Additionally, verify the textual fix is present:

```bash
# Confirm the new spec stage instruction is in system_prompt.ex
grep -c "ai_docs/" lib/repo_builder/orchestrator/system_prompt.ex
# Expect: at least 1 new match in phased_delivery_block

# Confirm override clauses added to all 4 command files
grep -c "save-location instruction" .claude/commands/plan.md
grep -c "save-location instruction" .claude/commands/bug.md
grep -c "save-location instruction" .claude/commands/feature.md
grep -c "save-location instruction" .claude/commands/chore.md
# Expect: 1 in each
```

## Notes

- **No code changes to `tools.ex`**: the `@inspect_read_cap` stays at 8 000 — it still applies
  to ALL other `read_file` calls (reading implementation files, test files, etc.) which are
  expected to be smaller. The fix is behavioral: the orchestrator stops reading spec files.

- **Backward compatibility**: humans who run `/bug`, `/feature`, `/chore`, `/plan` directly
  (without an explicit `ai_docs/` instruction) continue to get specs in `specs/` — the override
  only fires when the task explicitly says where to save. This keeps the human workflow intact.

- **Implement stage is unaffected**: `/implement <spec_path>` receives the `ai_docs/` path (e.g.,
  `ai_docs/add-autocomplete-spec.md`) and reads it directly from disk — no change needed there.

- **Existing `specs/` files**: any specs already written to `specs/` are unaffected and can be
  manually passed to `/implement` as before.

- **Evidence source**: logs 40875-40888, session 2026-07-02, orchestrator `glm-5.2`, worker
  `glm-4.6`; the orchestrator's thinking at log 40881-40883 explicitly states "The spec is
  truncated at 4KB" after `inspect_repo(read_file)` on the autocomplete spec.
