# planf3 — Update Plan workflow (project-vendored)

How to change, extend, or revise an existing planf3 HTML plan in `specs/`. Self-contained
in this repo — no `~/.claude` dependency.

1. **Identify the Plan** — Locate the target plan `.html` file under `specs/`.
2. **Scope the Change** — Think hard about exactly what is being changed, extended, or
   revised; keep the edit surgical and touch only the affected sections.
3. **Apply the Change** — Edit the relevant plan sections in place, preserving existing
   structure, content, and conventions (status markers, tags, figure/figcaption pairs).
   Upgrading a stock image: any `<img class="placeholder">` may be replaced with a bespoke
   render per `image-generation.md` — swap the `src`, drop the `placeholder` class, remove
   the "(stock placeholder)" figcaption suffix, keep the figure.
4. **Update Metadata** — Append the current ISO timestamp to `modified` and append the agent
   name / session id to their lists; never overwrite existing metadata entries.
5. **Record Amendment** — Append a new entry to the Amendments section (newest at the
   bottom) summarizing what changed and why.
6. **Report** — Summarize the change made and the amendment recorded.
