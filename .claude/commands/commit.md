---
command: commit
version: 1.0.0
---

---
description: Generate a single Conventional Commit message for the current changes
argument-hint: [agent_name] [issue_type] [issue_json]
allowed-tools: Read, Bash
---

# Commit Message

Generate ONE Conventional Commit message for the changes currently in the working tree.
Do **not** stage, commit, or push anything — the calling workflow performs the
`git add -A && git commit` itself. Your entire job is to emit the message text.

## Variables

agent_name: $1
issue_type: $2
issue_json: $3

## Workflow

- Inspect the changes with `git status --porcelain` and `git diff` (and `git diff --staged`).
- Derive a Conventional Commit `type` from `issue_type`: `/feature`→`feat`, `/bug`→`fix`,
  `/chore`→`chore` (default `feat` if unclear).
- Parse `issue_json` (it has `number`, `title`, `body`) to ground the subject in the task.

## Message Format

```
<type>: <imperative, ≤72-char summary of the actual change>

<1–4 bullet lines describing what changed and why>

Closes #<issue number from issue_json, only if it is a real issue (< 1,000,000)>
```

## Report

- IMPORTANT: Return **exclusively** the commit message text and nothing else — no code
  fences, no preamble, no trailing commentary. The first line is the subject; the rest is
  the body. This raw output becomes the commit message verbatim.
