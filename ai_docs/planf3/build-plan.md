# planf3 — Build Plan workflow (project-vendored)

How to implement/execute a planf3 HTML plan from `specs/*.html`. Used by `/implement` and
`/implement_elixir` when the plan path ends in `.html`. Self-contained in this repo — no
`~/.claude` dependency. (Provenance: adapted from the user-scope planf3 skill.)

Task status markers: `[]` idle · `[wip]` in progress · `[x]` complete · `[f]` failed.

1. **Locate the Plan** — Resolve the path to the target plan `.html` under `specs/`.
2. **Absorb Context** — Read the full plan: the metadata header, every section, and every
   back reference (depth 1) so you fully understand prior/related work before writing code.
3. **Execute Phases** — The plan's structure is `<section id="phases">` containing ordered
   `.phase` blocks; each phase has `<h4>` tasks with `<ul class="checklist">` items, and a
   final Testing Strategy task with a 🔁 loop. For each phase in order, top to bottom:
   - Announce the phase you are starting.
   - Set the phase (`<h3>`) and current task markers to `[wip]` in the plan file — edit the
     `<code class="status">` element text in place. The plan file is the live progress ledger.
   - Implement the task's specific actions.
   - Run that phase's Testing Strategy commands; loop on failure until they pass.
   - Mark each task `[x]` when complete, or `[f]` if it cannot be made to pass (append a
     one-line reason to the plan's Amendments section), then move on.
   - Do not start the next phase until the current phase's tasks and tests resolve.
4. **Final Validation** — Run the plan's global `<section id="validation">` commands and
   confirm every box passes; check the boxes in the plan file.
5. **Update Metadata** — Append the current ISO timestamp to `modified`, append agent name /
   session id, and append the relevant commit SHA(s) to the metadata header (append-only —
   never overwrite existing entries).
6. **Report** — Summarize what was built per phase, the final status of every task, and any
   `[f]` failures that need attention.
