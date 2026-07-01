---
name: desktop-ui-polish
description: Surface-specific guidance for polishing native and desktop GUI apps (Electron, Tauri, native toolkits) — window and menu conventions, standard shortcuts, platform affordances, information density, resizable layouts, and native dialogs, plus a self-validation recipe that captures a window screenshot where launchable and honestly reports a blocked/failed test where it cannot. Use when building or refining a desktop application surface. Builds on ui-ux-foundations.
---

# Desktop UI Polish

Surface-specific polish for native/desktop GUI applications. Assumes the `ui-ux-foundations` rubric.

## Conventions & affordances
- Native menu bar with the expected menus; standard shortcuts (Cmd/Ctrl+S save, +Q quit, +W close window).
- Standard window controls and behavior for the target platform; follow that platform's HIG affordances.
- Native dialogs for open/save/confirm rather than reinventing them in-window.

## Layout & density
- Desktop tolerates (and expects) higher information density than web — do not waste the viewport.
- Resizable, reflowing layouts; sensible min sizes; panes/splitters where appropriate.
- Keyboard shortcuts and accelerators for frequent actions, surfaced in menus.

## Self-validation recipe
- Where the harness can launch the app in the environment, capture a window screenshot as the artifact and check it against the rubric.
- Where the app cannot launch in the environment (no display, missing runtime, sandbox limits), record the test stage as blocked/failed with a clear, specific reason.
- Never fake a pass. Honest reporting: a blocked test is a blocked test, not a green check.

## When to use
Load when building or refining a desktop application surface.
