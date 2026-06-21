# Worker report: adw-launch-debugger (idle)

AH HA! The error messages are going to **STDOUT**, not stderr! That's why the `stderr_tail` is empty. The Python script is writing these errors to stdout, and since they're not valid JSON, they're being skipped by the NDJSON parser.

Now I have the complete picture. Let me write the report:

## Root Cause Analysis

**a) The exact platform command:**
```bash
uv run /data/1.Projects/repo_builder_elixir/adws/adw_plan_build_test_review_local_iso.py \
  --prompt "test prompt" \
  --working-dir /data/1.Projects/repo_builder_elixir \
  --adw-id adw-SQ9WkuPr4pq0Etaz \
  --emit json
```

**b) The REAL captured stderr text:**
The script writes error messages to **STDOUT** (not stderr), producing:
```
ADW Logger initialized - ID: --prompt
ADW Plan Build Test Review Local Iso starting - ID: --prompt
Missing or corrupt run record for --prompt
```

Stderr is completely empty, which is why the platform shows only `{:exit_status, 256}` with no diagnostic text.

**c) The true root cause:**

**CLI contract mismatch** between the ADW harness and the `_local_iso` workflow scripts:

- **ADW harness** (`lib/repo_builder/harness/adw.ex:50-76`): Builds commands for `adws/adw_workflows/adw_*.py` scripts, which accept `--prompt`, `--working-dir`, `--adw-id`, `--model`, `--emit` **flags**

- **Local-iso scripts** (`adws/adw_*_local_iso.py`): Expect a **single positional argument** (the ADW ID) and read all context from a pre-written `agents/<adw_id>/run.json` file

When the platform tries to launch a `_local_iso` script using the flag-based command, the Python argparser interprets `--prompt` as the positional ADW ID argument, then fails with "Missing or corrupt run record for --prompt" because no such run file exists.

**d) The minimal fix:**

**Option 1 — Immediate workaround (code change):**

Add a conditional path in `lib/repo_builder/harness/adw.ex:command/1` that detects `_local_iso` scripts and builds a positional-argument command instead:

```elixir
# Around line 57, after resolving the script path:
is_local_iso? = String.contains?(script, "_local_iso.py")

args =
  if is_local_iso? do
    # Local-iso scripts: positional ADW ID only
    pre_args ++ [script, adw_id]
  else
    # Standard workflows: flag-based
    pre_args ++
      [script] ++
      ["--prompt", opts.prompt, "--working-dir", cwd, "--adw-id", adw_id] ++
      model_args(model) ++
      ["--emit", "json"]
  end
```

**Option 2 — Operator workaround (no code change):**

The operator should NOT select `plan_build_test_review_local_iso` from the UI — it's an internal/file-based workflow, not an orchestrator-driven one. The catalog should only offer the `adw_workflows/` scripts (`plan_build`, `plan_build_review`, `plan_build_review_fix`).

**e) Orphan worktrees/branches:**

```bash
git worktree list
# Output: /data/1.Projects/repo_builder_elixir 57c81ed [dev]
```

No orphan worktrees exist. The script failed before creating one because it couldn't even parse its arguments.

**Secondary issue — stderr vs stdout:**

The `_local_iso` scripts write errors to stdout (not stderr), and those non-JSON lines are silently skipped by the NDJSON parser in `Session.Server`. The platform correctly captures stderr in `stderr_tail`, but since stderr is empty, no diagnostic appears in the error payload. This is a second, independent issue — the scripts should write errors to stderr.
