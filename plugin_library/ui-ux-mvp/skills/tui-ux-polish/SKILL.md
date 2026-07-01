---
name: tui-ux-polish
description: Surface-specific guidance for polishing terminal UIs (curses, ratatui, ink, bubbletea, blessed) — pane layout responsive to terminal size, discoverable key bindings with a footer/help, focus and selection highlighting, color-safe design with a NO_COLOR fallback readable in light and dark terminals, and a self-validation recipe that captures a rendered terminal snapshot and asserts layout and keybinding invariants. Use when building or refining a terminal (TUI) surface. Builds on ui-ux-foundations.
---

# TUI UX Polish

Surface-specific polish for terminal user interfaces. Assumes the `ui-ux-foundations` rubric.

## Layout
- Compose in panes; be responsive to terminal size and reflow on resize.
- No overflow — content must fit the current dimensions without wrapping into garbage or clipping silently.
- Fit and remain usable at the standard 80x24 minimum.

## Key bindings
- Discoverable: show active bindings in a footer or a help overlay.
- Follow conventions: `q` to quit, arrow keys and `hjkl` for movement, `Tab` to move focus.
- Make the bound keys visible where the user will look for them.

## Focus & color
- Clear focus/selection highlight so the active pane/item is obvious.
- Color-safe: honor `NO_COLOR` and provide a no-color fallback that stays fully readable.
- Readable in both light and dark terminals — do not depend on a specific background.
- Avoid unicode/glyphs that may not render in all terminals; provide ASCII fallbacks.

## Self-validation recipe
- Capture a terminal snapshot (the rendered output) as the artifact.
- Assert layout and keybinding invariants: footer/help present, focus indicator visible, output fits 80x24.
- Report evidence and pass/fail per invariant; failures feed the fix loop, then re-run.

## When to use
Load when building or refining a terminal (TUI) surface.
