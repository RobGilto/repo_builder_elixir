---
name: web-ui-polish
description: Surface-specific guidance for polishing web front-ends (HTML/CSS/JS, LiveView, React, Tailwind/DaisyUI) — responsive layout, semantic markup, focus and keyboard navigation, form and state handling, and a playwright-cli self-validation recipe that captures screenshots, accessibility snapshots, console and network logs, and a durable smoke test. Use when building or refining a web interface and needing to prove it meets the UI/UX MVP rubric with real browser evidence. Builds on ui-ux-foundations.
---

# Web UI Polish

Surface-specific polish for web applications. Assumes the `ui-ux-foundations` rubric.

## Layout & structure
- Mobile-first; fluid grids; a small set of sensible breakpoints (do not target device widths, target content).
- Semantic HTML: `nav`, `main`, `header`, `footer`, `button`, `a` — not div-soup. Buttons for actions, links for navigation.
- Responsive without horizontal overflow; test narrow and wide.

## Interaction & forms
- Focus and keyboard navigation on every control; logical tab order matching visual order.
- Every input has an associated label; show inline error states with accessible messaging.
- Handle loading, empty, and error states explicitly — never a blank screen or a silent failure.

## Styling
- Tailwind/DaisyUI-friendly: restrained utility use, extract repeated clusters to components.
- Use design tokens (theme colors, spacing scale) rather than ad-hoc values.
- One accent, neutral ramp, AA contrast (see foundations).

## Self-validation recipe
Drive the built app with the `playwright-cli` shell tool. It is harness-agnostic and works under both Claude and pi. Prefer it over Playwright MCP: the CLI writes artifacts to disk instead of flooding context.

Steps:
1. Launch/serve the app; navigate to the primary route(s).
2. Take a screenshot and an accessibility snapshot.
3. Capture console logs and network logs into `playwright-reports/<timestamp>/`.
4. Generate a durable `.spec.ts` smoke test that encodes the invariants below.

Pass/fail on the rubric:
- Primary navigation is reachable (no dead ends).
- Focus is visible on interactive elements.
- No console errors.
- No failed network requests.

Report evidence (artifact paths + which rubric items passed/failed). A failure feeds the fix loop, then re-run.

## When to use
Load when building or refining a web front-end surface.
