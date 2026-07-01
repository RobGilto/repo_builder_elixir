---
name: ui-ux-foundations
description: Universal UX principles that apply to every user-facing surface, plus an explicit anti-AI-slop checklist and a pass/fail MVP review rubric. Use when polishing or reviewing any interface (web, desktop, or terminal) — for establishing visual hierarchy, a consistent spacing and type scale, restrained color and AA contrast, accessibility (focus, keyboard, hit targets), and for gating whether a surface reaches a decent MVP bar. Load this before or alongside a surface-specific polish skill.
---

# UI/UX Foundations

Cross-surface UX principles. Applies to web, desktop, and terminal interfaces alike. Surface-specific skills build on this.

## Visual hierarchy
- Guide the eye with size, weight, spacing, and color — not decoration.
- Exactly one primary action per view; everything else is secondary or tertiary.
- Respect natural scan patterns: F-pattern for text-dense views, Z-pattern for sparse/landing views. Put the most important element where the eye lands first.
- If everything is emphasized, nothing is. Establish a clear first / second / third read.

## Spacing & typography scale
- Use a consistent modular spacing grid (4/8px steps). Do not hand-pick arbitrary margins.
- Type scale on a ~1.25 ratio; cap at ~4 sizes in normal use.
- Limit to 2 font families (one for UI/body, optionally one for headings or mono).
- Generous line-height for body text (~1.5). Constrain line length for readability.

## Color & contrast
- Restrained palette: 1 accent + a neutral ramp. Reserve the accent for emphasis and primary actions.
- Meet WCAG AA: 4.5:1 for body text, 3:1 for large text and meaningful UI boundaries.
- Never encode meaning by color alone — pair color with text, icon, or shape (color-blind + grayscale safe).

## Accessibility
- Visible focus rings on every interactive element; never remove the outline without a replacement.
- Full keyboard navigability with a logical tab order that follows visual order.
- Semantic structure and labels (headings, landmarks, accessible names for controls).
- Respect reduced-motion preferences; avoid motion that cannot be disabled.
- Hit targets >= 44px (or the platform equivalent).

## Avoid AI-slop tells
Anti-pattern list. Presence of these is a review failure, not a style choice:
- Purple/violet gradients everywhere (especially as the default accent).
- Oversized rounded cards with heavy soft drop-shadows on everything.
- No visual hierarchy — every element the same weight, size, and spacing.
- The generic centered hero + exactly three feature cards layout.
- Emoji used as interface icons.
- Copied/templated layouts with no relationship to the actual content.
- Dead-end navigation (links/screens with no way back or forward).
- Inconsistent spacing that ignores any grid.

## The UI/UX MVP review rubric
The pass bar the review stage applies. A "decent MVP" = the rubric passes, not pixel-perfect:
1. Clear visual hierarchy is present.
2. Primary navigation is reachable; no dead ends.
3. Focus is visible and the UI is keyboard operable.
4. AA contrast is met.
5. None of the AI-slop tells above are present.
6. No console/render errors.
7. Consistent spacing and type scale.

Score each item pass/fail with evidence. A failed item feeds the fix loop; re-review after fixing.

## When to use
Load when polishing or reviewing any user-facing interface. Pair with the matching surface skill: `web-ui-polish`, `desktop-ui-polish`, or `tui-ux-polish`.
