---
command: plan_f3
version: 1.0.0
description: HTML-first implementation plan into specs/, planf3 format (self-contained, no ~/.claude dependency; named /plan_f3 so the user-scope planf3 skill can never shadow it)
---

# Plan F3 (project-vendored, command /plan_f3)

Create a detailed, **HTML-first** implementation plan for the `REQUEST` and save it to the
`specs/` directory. The plan is a single self-contained `.html` page: browsable, image-slotted,
and consumable by the agent trifecta (engineer, team, AI agents). This command is fully
self-contained in this repository — it must never read the machine's `~/.claude`
directories. (Provenance: adapted one-time from the user-scope planf3 skill.)

The plan's lifecycle workflows (Build / Update Plan / Update References / Image Generation)
are vendored at `ai_docs/planf3/` — downstream steps (e.g. `/implement`) follow those.

## Variables

REQUEST: $ARGUMENTS

> **Argument contract (why `$ARGUMENTS`, not `$1 $2 $3`).** This command takes the
> **entire** argument string as one lossless value. Do NOT rely on positional variables
> (`$1`/`$2`/`$3`): the server-side slash expander fills those by splitting on whitespace,
> so any argument containing spaces — a JSON payload, or a freeform sentence — gets shredded
> across the slots. Binding the whole string to `REQUEST` keeps the request intact.

Derive the plan variables from `REQUEST`:

- **ADW harness form (most common):** the harness invokes
  `/planf3 <issue_number> <adw_id> <issue_json>`, so `REQUEST` arrives as two bare tokens
  followed by a JSON object (e.g. `9891906 0d9c026a {"number": 9891906, "title": …}`).
  Bind them exactly: first token → `issue_number`, second token → `adw_id`, and the JSON's
  `title`/`body` are the request. These are REAL identifiers — you MUST use them verbatim
  in `PLAN_FILE` below; do not invent substitutes.
- If `REQUEST` is a single JSON object, use its `number` → `issue_number`, its
  `title`/`body` as the request, and any `adw_id` it carries (else synthesize a short one).
- Otherwise treat the full `REQUEST` string as the freeform request; set `issue_number` and
  `adw_id` to a short descriptive placeholder derived from the request.
- If `REQUEST` is empty or is only a few stray words (garbled positional fragments), STOP and
  report that the caller should re-invoke with the full request (or the issue JSON) as a
  single argument — do not fabricate a request.

PLAN_FILE: `specs/issue-{issue_number}-adw-{adw_id}-sdlc_planner-{descriptive-name}.html`
(replace `{descriptive-name}` with a short kebab-case name derived from the request, e.g.
"add-auth-system"). The images directory, if ever needed, is the same path without `.html`.

> **The filename is LOAD-BEARING.** The ADW engine locates your plan by globbing
> `specs/issue-{issue_number}-adw-{adw_id}*` when parsing your reply fails. A plan saved
> under any other name is invisible to the pipeline and FAILS the whole run. Never
> shorten, rename, or "improve" this convention.

## Instructions

- IMPORTANT: You're writing a plan, not implementing. Fill the `Plan Format` below; replace
  EVERY `{{...}}` placeholder with real content and duplicate `<!-- repeat -->` blocks as
  needed. No `{{}}` token may remain in the saved file.
- Keep the document self-contained: all CSS in the single `<style>` block; no external
  stylesheets or scripts.
- Research the codebase before planning. Start with `BUILD_PROMPT.md` (authoritative
  architecture/spec) and `README.md`; check `.claude/commands/conditional_docs.md` for docs
  your task requires and list any matches in the plan's Relevant Files.
- This is an **Elixir/Phoenix/OTP** application. Honor the typed style guide in
  `BUILD_PROMPT.md` §3: `@spec` on every public function (`@impl true` callbacks exempt),
  `@type`/`typedstruct`/`@enforce_keys` for domain data, precise types over `any()`/`map()`,
  `{:ok, t()} | {:error, reason()}` over raising. Keep DB access behind `@spec`'d context
  modules — LiveViews/controllers/OTP processes never touch `Repo`/`Ecto.Query` directly (§8).
- Prefer **Tidewave** for research and validation planning: `get_docs`/`get_source_location`
  for exact-version library docs; `project_eval`, `execute_sql_query`, `get_logs` for
  validation steps. Note such steps in the plan.
- If the request includes UI work (Phoenix LiveView, §9): plan a `Phoenix.LiveViewTest`
  integration test in `test/repo_builder_web/live/test_<descriptive_name>_test.exs`, list it
  under New Files, and add its `mix test` invocation to the Validation Commands.
- If a new library is needed, plan the `mix.exs` pin + `mix deps.get` and record it in Notes.
- Every phase ends with a Testing Strategy task and the 🔁 validation loop; the plan ends
  with global Validation Commands. Default global gate for this repo:
  - `mix compile --warnings-as-errors`
  - `mix test --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix credo --strict`
  - `mix dialyzer`

### Image policy (cost-aware; controlled by `PLANF3_IMAGES`)

Read the `PLANF3_IMAGES` environment variable:

- **`placeholders` (or unset — the default):** you MUST fill every image slot with a stock
  image from the repo library `specs/.planf3-assets/placeholders/`. This is a zero-cost
  `<img src>` file reference to a PNG already committed in the repo — it is NOT image
  generation, costs nothing, and requires no API or network. Do NOT leave slots as HTML
  comments in this mode. Map slot kind → file:
  hero → `hero.png`, problem → `problem.png`, solution → `solution.png`, any phase image →
  `phase.png`, notes/questionables → `notes.png`. Embed as
  `<img class="placeholder" src=".planf3-assets/placeholders/<file>.png" alt="<intended bespoke subject>">`
  and suffix the figcaption with " (stock placeholder)". The `alt`/figcaption must still
  describe the *intended* bespoke subject so a later upgrade keeps the design intent.
- **`none`:** leave every slot as its HTML comment placeholder (no `<img>`).
- **`generate`:** generate bespoke images with
  `uv run scripts/generate_gpt_image.py "<prompt>" <out.png> --size 1536x1024 --quality high`
  into the plan's images directory, per `ai_docs/planf3/image-generation.md`. Requires
  `OPENAI_API_KEY` in the environment; if it is absent, DEGRADE to `placeholders` behaviour
  and append a one-line note to the plan's Amendments section — never fail the run.

NEVER call OpenAI unless `PLANF3_IMAGES=generate` and the key is present.

### Metadata rules

- `created`: current ISO-8601 timestamp. All other metadata fields are comma-separated,
  append-only lists — never overwrite or remove existing entries.
- `agent name`: `sdlc_planner`. `session id`: the `adw_id`.
- `back refs`: the issue and any prior specs/docs consulted. `forward refs`: leave `—`.

## Relevant Files

Focus research on: `BUILD_PROMPT.md`, `README.md`, `AGENTS.md` (if present), `mix.exs`,
`lib/repo_builder/**`, `lib/repo_builder_web/**`, `config/**`, `priv/repo/migrations/**`,
`test/**`, `scripts/**`, `adws/**`. Ignore everything else.

## Plan Format

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Plan: {{PLAN_TITLE}}</title>
<style>
  /* Synced visual identity — professional, focused, minimal. Adjust the palette to suit
     the plan's theme; keep everything in this single style block. */
  :root {
    --ink: #1c2733; --ink-soft: #44525f; --muted: #6f7b86;
    --paper: #f7f5f1; --card: #ffffff;
    --accent: #b45309; --accent-soft: #fdf1e3;
    --new: #1d4ed8; --line: #e3ded6;
    --mono: ui-monospace, Menlo, Consolas, monospace;
    --sans: -apple-system, "Segoe UI", system-ui, sans-serif;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--paper); color: var(--ink); font-family: var(--sans); line-height: 1.6; }
  main { max-width: 920px; margin: 0 auto; padding: 48px 32px 96px; }
  h1 { font-size: 1.9rem; line-height: 1.25; margin: 0 0 12px; }
  h2 { font-size: 1.35rem; margin: 56px 0 12px; padding-bottom: 8px; border-bottom: 2px solid var(--line); }
  h3 { font-size: 1.08rem; margin: 28px 0 8px; }
  h4 { font-size: 0.98rem; margin: 22px 0 6px; color: var(--ink-soft); }
  code { font-family: var(--mono); font-size: 0.86em; background: #eeeae2; padding: 1px 5px; border-radius: 4px; }
  pre { background: #212833; color: #e8e4da; padding: 16px 18px; border-radius: 8px; overflow-x: auto; font-size: 0.82rem; }
  pre code { background: none; padding: 0; color: inherit; }
  figure { margin: 28px 0; text-align: center; }
  figure img { max-width: 100%; border-radius: 10px; border: 1px solid var(--line); }
  figcaption { font-size: 0.85rem; color: var(--muted); margin-top: 10px; }
  details.meta { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 10px 16px; margin: 18px 0; font-size: 0.88rem; }
  details.meta dl { display: grid; grid-template-columns: 130px 1fr; gap: 4px 16px; margin: 12px 0 4px; }
  details.meta dt { font-weight: 600; color: var(--muted); }
  details.meta dd { margin: 0; font-family: var(--mono); font-size: 0.82rem; overflow-wrap: anywhere; }
  .tag { display: inline-block; font-size: 0.7rem; font-weight: 700; text-transform: uppercase; padding: 2px 8px; border-radius: 999px; margin-right: 6px; }
  .tag.existing { background: var(--accent-soft); color: var(--accent); }
  .tag.new { background: #e5edff; color: var(--new); }
  .files ul { list-style: none; padding-left: 0; }
  .files li { padding: 7px 0; border-bottom: 1px dashed var(--line); font-size: 0.93rem; }
  .phase { background: var(--card); border: 1px solid var(--line); border-left: 4px solid var(--accent); border-radius: 10px; padding: 22px 26px; margin: 26px 0; }
  .status { color: var(--accent); font-weight: 700; }
  ul.checklist { list-style: none; padding-left: 4px; }
  ul.checklist li { padding: 4px 0; font-size: 0.93rem; }
  .loop { background: var(--accent-soft); border: 1px solid #ecd3b4; border-radius: 8px; padding: 12px 16px; margin: 18px 0 4px; font-size: 0.9rem; }
  #questionables details, #amendments details { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 10px 16px; margin: 12px 0; }
  .qa-answer { color: var(--ink-soft); font-size: 0.93rem; }
  table { border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 0.9rem; background: var(--card); }
  th, td { border: 1px solid var(--line); padding: 8px 12px; text-align: left; vertical-align: top; }
  th { background: #efece5; }
</style>
</head>
<body>
<main>

  <header>
    <h1>Plan: {{PLAN_TITLE}}</h1>
    <details class="meta">
      <summary>Metadata</summary>
      <dl>
        <dt>created</dt>      <dd>{{CREATED_ISO}}</dd>
        <dt>modified</dt>     <dd>{{MODIFIED_ISO_LIST}}</dd>
        <dt>commits</dt>      <dd>{{COMMIT_SHA_LIST}}</dd>
        <dt>agent name</dt>   <dd>{{AGENT_NAME_LIST}}</dd>
        <dt>session id</dt>   <dd>{{SESSION_ID_LIST}}</dd>
        <dt>back refs</dt>    <dd>{{BACK_REFERENCES}}</dd>
        <dt>forward refs</dt> <dd>{{FORWARD_REFERENCES}}</dd>
      </dl>
    </details>
  </header>

  <!-- Hero image slot — fill per the Image policy (stock placeholder by default). -->
  <figure>
    <!-- {{HERO_IMAGE: subject describing the plan at a glance}} -->
    <figcaption>{{HERO_IMAGE_CAPTION}}</figcaption>
  </figure>

  <section id="purpose">
    <h2>Purpose</h2>
    <p>{{PURPOSE}}</p>
  </section>

  <section id="problem">
    <h2>Problem</h2>
    <p>{{PROBLEM}}</p>
    <figure>
      <!-- {{PROBLEM_IMAGE: subject visualizing the problem this plan addresses}} -->
      <figcaption>{{PROBLEM_IMAGE_CAPTION}}</figcaption>
    </figure>
  </section>

  <section id="solution">
    <h2>Solution</h2>
    <p>{{SOLUTION}}</p>
    <figure>
      <!-- {{SOLUTION_IMAGE: subject visualizing the proposed solution}} -->
      <figcaption>{{SOLUTION_IMAGE_CAPTION}}</figcaption>
    </figure>
  </section>

  <section id="files" class="files">
    <h2>Relevant Files</h2>
    <h3>Existing Files</h3>
    <ul>
      <!-- repeat -->
      <li><span class="tag existing">existing</span> <code>{{EXISTING_FILE_PATH}}</code> — {{WHY_RELEVANT}}</li>
    </ul>
    <h3>New Files</h3>
    <ul>
      <!-- repeat -->
      <li><span class="tag new">new</span> <code>{{NEW_FILE_PATH}}</code> — {{WHY_NEEDED}}</li>
    </ul>
  </section>

  <section id="phases">
    <h2>Implementation Phases</h2>
    <p><strong>IMPORTANT:</strong> Execute every phase and task step by step, in order, top to bottom.</p>
    <p>Status markers: <code>[]</code> idle · <code>[wip]</code> in progress · <code>[x]</code> complete · <code>[f]</code> failed. All start as <code>[]</code>; the Build Plan workflow updates them as it works.</p>

    <!-- repeat: one .phase block per phase -->
    <div class="phase">
      <h3><code class="status">[]</code> Phase {{PHASE_NUMBER}}: {{PHASE_NAME}}</h3>
      <p>{{PHASE_DESCRIPTION}}</p>

      <!-- Optional focused image for this phase -->
      <figure>
        <!-- {{PHASE_IMAGE: subject describing this phase's architecture/flow}} -->
        <figcaption>{{PHASE_IMAGE_CAPTION}}</figcaption>
      </figure>

      <!-- repeat: one <h4> + checklist per task -->
      <h4>{{TASK_NUMBER}}. {{TASK_NAME}}</h4>
      <ul class="checklist">
        <!-- repeat -->
        <li><code class="status">[]</code> {{SPECIFIC_ACTION}}</li>
      </ul>

      <!-- Final task of every phase: Testing Strategy + validation loop -->
      <h4>{{LAST_TASK_NUMBER}}. Testing Strategy</h4>
      <p>{{TESTING_APPROACH: technology used to test/validate, including edge cases}}</p>
      <ul class="checklist">
        <!-- repeat -->
        <li><code class="status">[]</code> <code>{{VALIDATION_COMMAND}}</code> — {{WHAT_IT_PROVES}}</li>
      </ul>
      <div class="loop">
        🔁 <strong>Do not exit this phase until every box above is checked.</strong>
        If any command fails, fix the cause and re-run — loop until all pass.
      </div>
    </div>
  </section>

  <section id="validation">
    <h2>Validation Commands</h2>
    <p>Execute these commands to validate the entire plan is complete:</p>
    <ul class="checklist">
      <!-- repeat -->
      <li><code class="status">[]</code> <code>{{VALIDATION_COMMAND}}</code> — {{WHAT_IT_PROVES}}</li>
    </ul>
    <div class="loop">
      🔁 <strong>The plan is not complete until every box is checked and every command passes. If for some reason a step is not possible to complete, mark it with [f] and move on if possible.</strong>
    </div>
  </section>

  <!-- Include this section only when surfacing open decisions/assumptions/risks. -->
  <section id="questionables">
    <h2>Questionables</h2>
    <!-- repeat: one <details> per questionable decision / assumption / risk -->
    <details>
      <summary>{{QUESTIONABLE}}</summary>
      <p class="qa-answer">{{ASSUMPTION_OR_RATIONALE}}</p>
    </details>
  </section>

  <section id="notes">
    <h2>Notes</h2>
    {{NOTES: free-form. Context, dependencies, tradeoffs, rejected approaches, risks,
      future work, references. Author rich, bespoke HTML as needed.}}
  </section>

  <!-- Append-only history of changes made AFTER first execution. Never edited during Create. -->
  <section id="amendments">
    <h2>Amendments</h2>
    <!-- repeat: one entry per amendment, newest at the bottom -->
    <details>
      <summary>{{AMEND_ISO}} — {{AMEND_SUMMARY}}</summary>
      <p>{{AMEND_DETAIL: what changed and why}}</p>
    </details>
  </section>

</main>
</body>
</html>
```

## Report

- **HARD OUTPUT CONTRACT — the ADW engine parses your ENTIRE final message as a file
  path.** Your final reply must be exactly the relative plan path and NOTHING else:

  ```
  specs/issue-9891906-adw-0d9c026a-sdlc_planner-pg-sh-version-flag.html
  ```

- No prose, no summary, no headings, no backticks, no "Plan saved to…", no trailing
  notes. Any extra text makes the path unparseable and fails the run. Put any summary
  INSIDE the plan document (Notes section), never in the reply.
