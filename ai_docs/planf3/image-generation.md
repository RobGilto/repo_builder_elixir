# planf3 — Image Generation workflow (project-vendored)

How plan images are filled, upgraded, or regenerated. Self-contained in this repo — no
`~/.claude` dependency. The default path costs nothing; OpenAI is opt-in only.

## Image policy (three tiers, controlled by `PLANF3_IMAGES`)

- **`placeholders` (or unset — default):** embed stock images from
  `specs/.planf3-assets/placeholders/`, slot kind → file: hero→`hero.png`,
  problem→`problem.png`, solution→`solution.png`, any phase image→`phase.png`,
  notes/questionables→`notes.png`. Stock embeds carry `class="placeholder"` and a
  figcaption suffix "(stock placeholder)"; `alt` text describes the *intended* bespoke
  subject. Plans live in `specs/`, so the relative src is `.planf3-assets/placeholders/...`.
- **`none`:** leave image slots as HTML comment placeholders.
- **`generate`:** bespoke OpenAI renders (below). Requires `OPENAI_API_KEY`; if absent,
  degrade to `placeholders` and note it in the plan's Amendments — never fail the run.

The platform sets `PLANF3_IMAGES` from the console setting "Plan images: use placeholders"
(Settings modal, General tab; default ON ⇒ `placeholders`).

## Bespoke generation (opt-in)

Scripts (run with `uv run` from the repo root; need `OPENAI_API_KEY`):

- Create: `uv run scripts/generate_gpt_image.py "<prompt>" <output.png> --size 1536x1024 --quality high`
- Edit:   `uv run scripts/edit_gpt_image.py "<instruction>" <output.png> <input.png> --size 1536x1024 --quality high`

Rules for every image prompt:

- always wide format (`--size 1536x1024`) at high quality
- convey the one or two core ideas of that section for a professional software engineer
- match the plan's synced visual identity (professional, focused, minimal — the CSS `:root`
  palette of the plan)
- keep total words shown in the image under 10
- save images to the plan's images directory: `specs/<plan-name>/` (create if missing)

### Create (fill empty slots)

1. Grep the plan for `{{...IMAGE` comment placeholders; each names the intended subject.
2. Write one prompt per slot following the rules above.
3. Run `generate_gpt_image.py` once per slot (parallelize; no reason to block).
4. Replace each comment with `<img src="<plan-name>/<file>.png" alt="...">`, keeping the
   existing `<figure>`/`<figcaption>`.
5. Report the images generated and slots filled.

### Upgrade a stock placeholder

1. Identify the target `<img class="placeholder">` in the plan.
2. Generate the bespoke render from the `alt` text (the intended subject).
3. Swap the `src` to the plan's images directory, drop the `placeholder` class, remove the
   "(stock placeholder)" figcaption suffix.

### Update (change existing bespoke images)

1. Determine which embedded `<img>` to change from the request.
2. Write an edit instruction following the rules above.
3. Run `edit_gpt_image.py` with the existing PNG as input, overwriting it (the script backs
   up the original first).
4. Confirm the `<img>` still points at the updated file; adjust `src`/`alt`/figcaption if
   warranted.
5. Report the images updated and what changed.
