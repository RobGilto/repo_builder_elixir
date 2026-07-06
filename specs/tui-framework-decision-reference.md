---
title: TUI Framework Decision Reference
purpose: Agent-facing knowledge base for choosing a TUI framework and its components by tech stack
audience: Orchestrator agents that CRUD/generate TUIs
verified: 2026-07-06
---

# TUI Framework Decision Reference

A knowledge base for agents that must pick a TUI framework + components based on the target
tech stack. Read §1 to route by language, §2 for per-framework capsules, §3 for the
cross-framework component map, §4 for the deciding factors, §5 for agent code-gen rules.

---

## 1. Stack router (language → default framework)

| Target language / stack | Default framework | Why |
|---|---|---|
| **JS / TypeScript / Node / React** | **Ink** (+ `@inkjs/ui`) | React-for-terminal; what Claude Code, Gemini CLI, Copilot CLI, Wrangler use. Match the ecosystem. |
| **Go** | **Bubble Tea** (+ Bubbles + Lip Gloss; Huh for forms) | Cohesive Charm stack, single static binary, most polished component set. |
| **Rust** | **Ratatui** (+ tui-textarea / tui-input as needed) | The only serious Rust TUI; max performance & control, single binary. |
| **Python** | **Textual** (or **Rich** alone for non-interactive) | Biggest built-in widget set + CSS engine; Rich for one-shot/streamed output. |
| **Elixir / BEAM** | **Ratatouille** (+ **Owl** for prompts/output) | Elm Architecture on termbox; drives from the same BEAM node. See §2.7. |
| **Shell script (bash/zsh), no compile** | **Gum** (Charm) | Prebuilt pickers/prompts as CLI commands; zero code. |
| **C# / .NET** | **Spectre.Console** | 40+ polished renderables + prompts + CLI parser. See §2.6. |
| **JS/TS needing high perf / 3D / code-diff views** | **OpenTUI** | Native Zig core, Yoga flexbox, Tree-sitter, WebGPU 3D, SSH. See §2.5. |
| **C / C++ / Zig (single binary, graphics)** | notcurses (C) · FTXUI (C++) · libvaxis (Zig) | Multimedia/graphics + WASM (FTXUI). See §2.6. |
| **Just a prompt wizard (not a full TUI)** | **@clack/prompts** (JS) · Owl (Elixir) · Rich Prompt (Py) | Don't reach for a framework for a linear question flow. |
| **Need same app in terminal AND browser** | **Textual** (`textual-serve`) | Only mainstream framework with first-class browser serving. |
| **Serve TUI over SSH (no client install)** | **Bubble Tea + Wish** (Go) | SSH-served TUIs with pubkey auth. |

**Override rules:**
- If the user needs a **single static binary** for arbitrary machines → prefer **Go (Bubble Tea)** or **Rust (Ratatui)**; avoid Textual (Python runtime) and be aware Ink ships Node.
- If the user needs **maximum render throughput / high FPS** (token streaming over huge tables, real-time visualizers) → Ratatui > Bubble Tea > Textual > Ink. (Ink has a repaint ceiling; see §2.1.)
- If the team's existing language is fixed, that almost always wins over marginal framework advantages.

---

## 2. Per-framework capsules

### 2.1 Ink — JS/TS (React for the terminal)

- **Version/maturity (2026-07-06):** ink@7.1.0, ~39k★, ~3.87M weekly npm downloads, MIT, single maintainer (Vadim Demedes). Ships its own TS types.
- **Model:** Custom React reconciler → **Yoga (Flexbox)** layout → ANSI diff to stdout. Retained/declarative (React state → repaint). React DevTools attach.
- **Production users:** Claude Code, Gemini CLI, GitHub Copilot CLI, Cloudflare Wrangler, Shopify CLI, Prisma, Gatsby, Terraform CDK, Qwen Code (forks Gemini CLI).
- **Built-in components:** `<Box>` (flex container/borders/spacing), `<Text>` (all visible text + inline style), `<Newline>`, `<Spacer>` (flex-grow gap), `<Static>` (append-only, never re-rendered — logs/chat), `<Transform>` (post-process rendered string).
- **Hooks:** `useInput` (keys), `useApp` (`exit()`), `useStdin/useStdout/useStderr`, `useFocus` + `useFocusManager` (tab nav), and v6/7: `useWindowSize` (resize), `measureElement`/`useBoxMetrics` (size a scroll viewport), `useCursor`, `useAnimation`.
- **Component library — prefer `@inkjs/ui` (v2) first:** TextInput, EmailInput, PasswordInput, ConfirmInput, Select, MultiSelect, Spinner, ProgressBar, Badge, StatusMessage, Alert, OrderedList, UnorderedList (themeable). Standalone `ink-*` only for gaps: `ink-big-text`, `ink-gradient`, `ink-link` (OSC-8), `ink-table` (check v6/7 compat). Testing: `ink-testing-library` (`render`, `lastFrame`, `stdin.write`). File-based CLI framework: `pastel`.
- **Staleness flags:** `ink-progress-bar` (2019), `ink-multi-select` (2020), `ink-table` (2023) predate ink@6/7 → prefer `@inkjs/ui` equivalents.
- **Limits/gotchas:** repaint/reconcile ceiling (~30 FPS class) → laggy on high-frequency streaming/large live tables; wrap append-only output in `<Static>` + memoize; `useInput` needs raw-mode TTY (guard `isRawModeSupported`); never `console.log` into the managed region (use `<Static>`/`useStdout().write`); heavier cold start (React+Yoga WASM). This ceiling is *why OpenTUI exists* (pending report).
- **Pick when:** JS/TS + React team, human-paced interactivity, want to match the AI-CLI stack. **Avoid when:** need max FPS, tiny fast-exit binary, or you're not in JS.

### 2.2 Charm / Bubble Tea — Go (The Elm Architecture)

- **Versions (2026):** bubbletea v2.0.8 (~44k★), bubbles v2.1.1 (~8.6k★), lipgloss v2.0.5, huh v2.0.3, gum v0.17.0 (~24k★), glamour v2.0.1, wish v2.0.1. All MIT, pure Go, active. **v2 migration in progress:** imports moving `github.com/charmbracelet/<pkg>` → `charm.land/<pkg>`; `tea.KeyMsg` → `tea.KeyPressMsg`.
- **Model — Elm/MVU:** one `Model` struct implements `Init() (Model, Cmd)`, `Update(Msg) (Model, Cmd)` (only place state mutates; big type-switch on Msg), `View() string` (pure). `Cmd = func() Msg` = async side effect run in a goroutine; `tea.Batch/Sequence/Tick/Every`. `tea.NewProgram(model).Run()`; `p.Send(msg)` injects external events. **Never do I/O in Update/View — return a Cmd.**
- **Production users:** Azure Aztify, CockroachDB, AWS eks-node-viewer, MinIO client, chezmoi, gh-dash, glow, Charm's own AI agent **Crush**.
- **Bubbles components:** textinput, textarea, list (fuzzy filter + pagination + help built in), table, viewport (scroll long content/markdown), paginator, progress, spinner, stopwatch, timer, filepicker, help (auto key-hint bar), key (keybinding manager — idiomatic), cursor. Extras: `charm-and-friends/additional-bubbles`.
- **Lip Gloss (styling/layout):** chained styles (Bold/Foreground/Padding/Border/Align), borders (Rounded/Thick/Double/custom), `JoinHorizontal/JoinVertical/Place` composition, color profiles auto-downsample (truecolor→256→16→1-bit), adaptive light/dark, sub-packages `table`/`list`/`tree` (static renderers). **Not a layout solver** — you compute widths from `lipgloss.Width()` + `WindowSizeMsg`.
- **Huh? (forms):** field types Input, Text, Select[T], MultiSelect[T], Confirm, Note, FilePicker; `Group` = a page (multi-group = wizard); `.Value(&var)`, `.Validate(fn)`; **`WithAccessible(true)`** falls back to plain prompts for screen readers; forms are themselves `tea.Model`s (standalone or embedded). Themes: Charm/Dracula/Base16.
- **Gum (shell, no Go):** choose, confirm, input, write, filter (fuzzy), file, spin, table, pager, style, join, format (markdown), log.
- **Others:** Glamour (Markdown→ANSI, powers gh/glab/tea CLIs; render then show in a viewport), Wish (SSH-served TUIs, `bubbletea` middleware + auth/ratelimit/git), Harmonica (spring animation, dormant-but-stable).
- **Gotchas:** v1/v2 mixing = top failure mode; model passed/returned by value (always `return m, cmd`); embedded child components must forward `msg` to their `Update` AND bubble up their `Cmd` (else spinners/timers stop); test `Update` as a pure function (or `x/exp/teatest`, VHS for visual); cache Lip Gloss styles outside the render hot path.
- **Pick when:** Go, want cohesive batteries-included stack + single binary. **Within Charm:** shell → Gum; wizard/prompts → Huh; full app → Bubble Tea+Bubbles+Lip Gloss; remote → Wish; markdown → Glamour.

### 2.3 Ratatui — Rust (immediate-mode)

- **Version (2026):** ratatui 0.30.2 (Jun 2026), ~21.5k★, ~15,800 dependents, MIT, **pre-1.0 (0.x breaks on minor — pin versions)**. Successor to dead `tui-rs` (don't use tui-rs).
- **Model — immediate-mode:** YOU own the loop and state. `Terminal<B>` + `terminal.draw(|frame| ...)` each frame (Ratatui diffs Buffer/Cell, writes only changes). **No built-in event loop / MVU / async** — you write `loop { draw; handle_events; if quit break }`. Events come from the **backend** (crossterm default; also termion/termwiz/termina; TestBackend for unit tests). 0.30 split into `ratatui-core` + backend crates.
- **Production users:** Atuin, GitUI, Yazi, oatmeal, bottom, television.
- **Built-in widgets:** Block (borders/titles — wrap almost everything), Paragraph (wrapped/scrolled text), **List** (StatefulWidget + `ListState`), **Table** (StatefulWidget + `TableState`), Tabs, Gauge, LineGauge, BarChart, Chart (x/y plot), Sparkline, **Scrollbar** (StatefulWidget + `ScrollbarState` — draws only, you compute scroll), Canvas (freeform/maps/games), **Clear** (blank a Rect → render popups/modals over it), Calendar (`time` feature). Widget = stateless rebuild each frame; StatefulWidget = you own+pass state each frame.
- **Layout:** Cassowary constraint solver. `Layout::new(direction, [Constraint...]).split(area)`; Constraints: `Length`, `Percentage`, `Ratio`, `Min`, `Max`, `Fill(weight)`; `Flex` (Start/Center/SpaceBetween/…) distributes leftover space. Recomputed every draw (responsive automatically). Nest layouts for grids; center popups via percentage splits or `Flex::Center`.
- **Styling:** `Style` (fg/bg/Modifier), `Color` (named/Indexed(256)/Rgb), `Modifier` bitflags, **`Stylize` trait** (`"x".red().bold().on_blue()` — idiomatic). Text model: `Span` (styled run) → `Line` (spans) → `Text` (lines). `ratatui-macros` for `span!/line!/text!`.
- **Ecosystem (core deliberately omits input & tree):** `tui-textarea` (multi-line editor), `tui-input` (headless single-line), `tui-tree-widget` (tree/file hierarchy), `tui-logger` (log pane + tracing), `ratatui-image` (Sixel/Kitty/iTerm images), `tui-big-text`, `throbber-widgets-tui` (spinner), `tui-widget-list`, `tui-scrollview`, `color-eyre` (panic hook — restores terminal on crash; near-mandatory). Framework layers: **`tui-realm`** (Elm-like), `rat-salsa`/`rat-widget`, or the docs' hand-rolled "Component architecture" (Component trait + Action enum + mpsc channel).
- **Gotchas:** you manage raw mode + alt screen + **terminal restore on panic** (use `ratatui::init()/restore()` + `color-eyre`); stateful widgets need externally-owned state (creating fresh `ListState` each frame resets selection); widgets consumed on render (rebuild each frame); on Windows filter `KeyEventKind::Press` (double events); async = tokio + `EventStream` + `mpsc`/`select!` into one loop, never block draw; multiple crossterm major versions in dep graph break events (use `crossterm_0_x` flags).
- **Pick when:** Rust, want control/perf/single binary. Want Elm structure → `tui-realm`.

### 2.4 Textual & Rich — Python

- **Relationship:** **Rich** = rendering/print library (styled output, no event loop). **Textual** = full async app framework built on Rich (event loop, widget DOM, CSS, focus, screens). Rule: Rich = library you call; Textual = framework that calls you.
- **Versions/status (2026):** Textual ~v8.2.8, ~36k★; Rich ~v15.0.0, ~52k★; both MIT. **⚠ Textualize (the company) shut down May 2025** — Textual/Rich continue as open source maintained by Will McGugan personally; still releasing, but factor **single-maintainer / slower-roadmap risk** into multi-year bets. No hostile fork; canonical repos remain authoritative.
- **Production users:** Posting (API client), Harlequin (SQL IDE), Memray (Bloomberg), Dolphie (MySQL monitor), Toolong, Elia (LLM chat), Trogon.
- **App architecture:** `App` (root) → `Screen` (stack: push/pop/switch; `ModalScreen` for dialogs) → `Widget` DOM tree. `compose()` yields child widgets. **Reactive attributes** (`reactive()`/`var()`) auto-trigger re-render + `watch_/validate_/compute_` hooks. **Messages**: events (`on_mount`, `on_key`, `on_click`) + bubbling widget messages (`Button.Pressed`, `Input.Changed`, `DataTable.RowSelected`); handle via `on_*` or `@on(Button.Pressed, "#save")`. **Workers** (`@work`, `@work(thread=True)`, `exclusive=True`) for async/blocking work — never block the loop.
- **TCSS (key differentiator):** CSS-like `.tcss` files, hot-reloadable, real selectors (type/`#id`/`.class`/pseudo `:hover :focus :dark`). Box model + units (cells/`%`/`fr`/`auto`/`vw`). Layouts: `vertical`/`horizontal`/**`grid`** (`grid-size`, spans)/**`dock`** (pin header/footer/sidebar)/**`layers`** (z-order overlays). Theme tokens `$primary/$surface/$error/…`; built-in themes (textual-dark, nord, gruvbox, dracula, catppuccin…). Prefer `.tcss` + IDs/classes over inline `styles.*`.
- **Built-in widgets (large set):** Inputs — Button, Input, MaskedInput, TextArea (tree-sitter syntax highlight), Checkbox, Switch, RadioSet/RadioButton, Select, SelectionList, OptionList, ListView/ListItem. Data — **DataTable**, Tree, DirectoryTree, Collapsible, TabbedContent/TabPane, Tabs, ContentSwitcher. Rich content — Markdown/MarkdownViewer. Feedback — ProgressBar, LoadingIndicator (`widget.loading=True`), **Log** (fast plain) / **RichLog** (any Rich renderable). Display — Static, Label, Digits, Pretty, Rule, Placeholder, Sparkline, Link, Header, Footer, Tooltip. Containers — Container, Vertical/Horizontal, Grid, Center/Middle, VerticalScroll/ScrollableContainer, ItemGrid (reflow).
- **Rich standalone:** Console (`print` with `[markup]`), Text/Style, Table, Panel, Columns, Progress (`track()`), Syntax, Markdown, Tree, **Live** (re-render region in place), Layout (split screen for Live dashboards), Prompt/Confirm/IntPrompt, Traceback (`install()`), `inspect()`, `RichHandler` logging.
- **Dev experience:** `textual-dev` → `textual run --dev` (TCSS hot reload), **`textual console`** (receives app logs/prints/events), `textual serve` (browser). Testing: **Pilot** (`app.run_test()`, `pilot.press/click/pause`), **pytest-textual-snapshot** (SVG diff).
- **Gotchas:** blocking the event loop freezes the UI (top bug) → use workers; update widgets from threads via `call_from_thread`; `compose()` must be fast/side-effect-free (setup in `on_mount`); `query_one` fails before mount; `@work(exclusive=True)` for search-as-you-type; **ships Python runtime, no single binary** (pipx/uv/PyInstaller); Log vs RichLog throughput.
- **Pick Rich alone** for scripts/loggers/one-shot formatted output/read-only Live dashboards. **Pick Textual** for interactive multi-screen apps, or when you want the same app in a browser.

### 2.5 OpenTUI — JS/TS with a native Zig core (the Ink successor)

- **Identity:** TypeScript TUI lib over a **native Zig rendering core** (C ABI). By the OpenCode/SST/terminal.shop crowd (Dax "thdxr"). Repo moved `sst/opentui` → **`anomalyco/opentui`** (canonical). npm scope `@opentui/*`; site opentui.com.
- **Why it exists:** escapes Ink's ceilings — pushes frame diffing, ANSI gen, rope text buffers, and layout into Zig; **framework-agnostic** (React is one front-end, not the substrate).
- **Runtime:** TS (~75%) over Zig (~20%). Runs primarily on **Bun** (`Bun.dlopen()` FFI); prebuilt native binaries for mac/Linux/Windows x64+arm64. Building from source needs a specific Zig version (0.15.x — moving target). `bun create tui` scaffolds.
- **Rendering:** Zig shadow-buffer diff + run-length ANSI ("sub-ms frame times"), hit-grid for mouse. **Real flexbox via native Yoga.** **`@opentui/three` renders actual Three.js WebGPU 3D scenes as ASCII** — unique in this whole reference.
- **Components (core renderables):** `BoxRenderable`, `TextBufferRenderable`/`EditBufferRenderable` (rope buffers), `ScrollBoxRenderable` (viewport culling), `CodeRenderable` (**Tree-sitter syntax highlighting**), `DiffRenderable` (unified/split diffs). `extend({tag: CustomRenderable})`.
- **Bindings:** `@opentui/core` (imperative + C ABI), `@opentui/react`, `@opentui/solid`, `@opentui/vue` (**unmaintained**), `@opentui/three`, `@opentui/keymap`, **`@opentui/ssh`** (serve TUIs over SSH).
- **Maturity (2026):** pre-1.0 but fast — ~12.3k★, 116 contributors, v0.4.3 (Jul 3 2026). Users: **OpenCode** today, terminal.shop rolling in. Official agent skill: `npx skills add anomalyco/opentui --skill opentui`.
- **Caveats:** pre-1.0 churn; Bun-centric (Node secondary); needs native binaries or Zig toolchain; Vue binding dead; smaller ecosystem than Ink.
- **Pick when:** new TS/JS TUI needing **high perf, large scroll buffers, code/diff views, syntax highlighting, GPU/3D, React *or* Solid, or SSH serving** — i.e. you've hit Ink's ceiling. **Avoid when:** need Node-first stability or a frozen API → stay on Ink.

### 2.6 Other options by language (survey + maintenance status, 2026)

**JS/TS (beyond Ink/OpenTUI):**
- Full-screen: **terminal-kit** (actively maintained, single-maintainer — best non-React full-screen option) · **blessed / neo-blessed / blessed-contrib** = *legacy/abandoned* (2015/2018/2022), maintain-only · **tuir** (Ink fork + built-in keymaps/nav/modals, beta single-author) · **ratatat** (Ink-compatible, Rust diff engine, early — likely what a stray "29" reference meant).
- Prompt wizards (NOT full-screen TUIs): **@clack/prompts** (modern default, very active) · **@inquirer/prompts** (largest ecosystem, active) · **enquirer**/**prompts** (stable but dormant).
- CLI arg parsers (NOT TUIs — agents confuse these): **oclif** (CLI-as-product framework) · **yargs** (parser). Pair with a prompt lib for interactivity.

**Go (beyond Bubble Tea):**
- **tcell** = low-level cell backend under most non-Charm Go TUIs (use **v2**; v3 late-2025 has breaking changes, less adopted).
- **tview** (rivo) = widget-rich **retained/OO** toolkit on tcell — best stock tables/forms/trees; powers **k9s**; single low-cadence maintainer (fork: **cview**). **tview vs Bubble Tea:** need heavy stock widgets now (ops dashboard) + comfortable imperative → tview; custom async UI + testability + long-term maintenance → Bubble Tea (safer greenfield).
- **termui** (dataviz, semi-dormant; fork `gotui`) · **awesome-gocui/gocui** (minimalist, powers lazygit/lazydocker) · **pterm** (line-based pretty output, NOT full-screen; great for CLIs/CI).

**Rust (beyond Ratatui):**
- **cursive** = **retained/callback** view-tree (library owns loop + widget state). Reach for it on form/dialog/menu-heavy apps; Ratatui for control + ecosystem size.
- **iocraft** (React-like hooks+props, `taffy` flexbox) · **r3bl_tui** (async/reactive, mid-consolidation — verify) · MVU layers over Ratatui: **tui-realm** (safest maintained), reratui, tui-react.

**Python (beyond Textual/Rich):**
- **prompt_toolkit** = the **REPL/line-editor engine** behind IPython/pgcli/mycli. Pick when the app is fundamentally line/prompt editing (shells, REPLs); Textual for multi-widget apps.
- **urwid** (veteran retained toolkit, **actively maintained again** 2025 — stable portable choice without Textual's CSS/reactive layer) · **py-cui** (grid-layout over curses) · **npyscreen** (stale, avoid new work).

**Other languages:**
- **.NET / C#: Spectre.Console** — very polished, 40+ renderables (tables/trees/charts/prompts/live/Canvas) + `Spectre.Console.Cli` parser. De facto .NET console-UI lib; beautiful output/prompts, not a full-screen retained framework.
- **C: notcurses** — high-perf ncurses replacement, **best-in-class multimedia** (Sixel/Kitty graphics, image/video). Revived, v3.0.17 (2026). For graphics from C, not stock widgets.
- **C++: FTXUI** — functional/declarative React-like (screen→dom→component), zero deps, cross-platform incl. **WASM**. The default serious C++ TUI.
- **Zig: libvaxis** — low-level cells + **vxfw** (Flutter-like framework); terminfo-free, Kitty graphics; tracks pre-1.0 Zig (churn).
- **Java: Lanterna** (Swing-like, pure Java, stable-but-quiet) · watch **TamboUI** (ratatui-inspired, 2026, unproven).
- **Haskell: brick** (declarative on `vty`, actively maintained, v2.10 — the standard).

### 2.7 Elixir / BEAM (your repo_builder stack)

- **Ratatouille** (`ndreynolds/ratatouille`) — **Elm Architecture** (model/update/view/subscribe) with view diffing, built on **termbox** via `ex_termbox` (v0.5.x). Mature-but-quiet; capped by termbox's feature set. The natural fit — TEA maps cleanly onto Elixir's immutable/message-passing model.
- **Owl** (`fuelen/owl`) — complementary **CLI toolkit** (colored tags, `Owl.IO` prompts, select/multiselect, tables, live output, progress). Actively used. **Use Owl for prompt/output UX, Ratatouille for a full-screen interactive app** — they compose.
- **Practical note for repo_builder:** if the TUI is a control surface for an Elixir/OTP system, Ratatouille lets you drive it from the same BEAM node (subscribe to PubSub/GenServer messages as TEA subscriptions). If you only need styled prompts/log output in a mix task or CLI, Owl alone is lighter. If you need richer widgets than termbox allows, the pragmatic escape hatch is a Go (Bubble Tea) or Rust (Ratatui) sidecar spoken to over a port — but that adds a non-BEAM binary.

---

## 3. Cross-framework component decision map

"User needs X → use Y", per stack. `—` = not first-class (hand-build or reconsider stack).

| Need | Ink (JS) | Bubble Tea (Go) | Ratatui (Rust) | Textual (Python) |
|---|---|---|---|---|
| Layout container / borders | `<Box>` | Lip Gloss style + `Join*` | `Block` + `Layout` | Container / TCSS `grid`,`dock` |
| Static / wrapped text | `<Text>` | Lip Gloss render | `Paragraph` | `Static` / `Label` |
| Single-line input | `@inkjs/ui` TextInput | Bubbles textinput / Huh Input | `tui-input` | `Input` |
| Password / masked | `@inkjs/ui` PasswordInput | textinput (echo mode) | `tui-input` | `MaskedInput` / `Input(password)` |
| Multi-line editor | (hand-build) | Bubbles textarea | `tui-textarea` | `TextArea` |
| Single-select menu | `@inkjs/ui` Select | Bubbles list / Huh Select | `List`+`ListState` | `Select` / `OptionList` |
| Multi-select | `@inkjs/ui` MultiSelect | Huh MultiSelect | `List` (custom) | `SelectionList` |
| Yes/no confirm | `@inkjs/ui` ConfirmInput | Huh Confirm | (hand-build) | `Button` / modal |
| Fuzzy filter list | (hand-build) | Bubbles list (filter on) | (custom) | (filter + list) |
| Data table | `ink-table` (check compat) | Bubbles table | `Table`+`TableState` | `DataTable` |
| Tree / hierarchy | (hand-build) | (hand-build) | `tui-tree-widget` | `Tree` / `DirectoryTree` |
| Tabs / view switch | (hand-build) | (hand-build) | `Tabs` + own index | `TabbedContent` / `ContentSwitcher` |
| Spinner (indeterminate) | `@inkjs/ui` Spinner | Bubbles spinner / Huh spinner | `throbber-widgets-tui` | `LoadingIndicator` |
| Progress bar (determinate) | `@inkjs/ui` ProgressBar | Bubbles progress | `Gauge` / `LineGauge` | `ProgressBar` |
| Scroll long content | `<Box overflow>` + measure | Bubbles viewport | `Scrollbar`+`ScrollbarState` | `VerticalScroll` |
| Streaming logs | `<Static>` | Bubbles viewport | `tui-logger` | `Log` / `RichLog` |
| Render Markdown | (community) | Glamour | (custom) | `Markdown` / `MarkdownViewer` |
| Line/scatter chart | — | — | `Chart` | (Rich/plotext) |
| Bar chart | — | — | `BarChart` | — |
| Sparkline | — | — | `Sparkline` | `Sparkline` |
| Popup / modal | (layout) | (Lip Gloss `Place`) | `Clear` + widget | `ModalScreen` |
| File picker | (hand-build) | Bubbles filepicker / Huh | (custom) | `DirectoryTree` |
| Big banner text | `ink-big-text` | (figlet) | `tui-big-text` | `Digits` (numbers) |
| Clickable link | `ink-link` | (Lip Gloss hyperlink) | (OSC-8) | `Link` |
| Keybindings + help bar | `useInput` | Bubbles key + help | (own dispatch) | `BINDINGS` + `Footer` |
| Forms / wizard | `@inkjs/ui` fields | **Huh** groups | `tui-realm` | Screens + widgets |
| Serve over SSH | — | **Wish** | — | (via ssh) |
| Serve in browser | — | — | — | **textual-serve** |
| Unit test the UI | `ink-testing-library` | test `Update` / teatest | `TestBackend` | Pilot + snapshot |

---

## 4. Decision factors (weigh these per project)

1. **Language lock-in** — the target stack's language almost always decides. Don't cross languages for marginal gains.
2. **Distribution** — single static binary (Go/Rust) vs runtime dependency (Python Textual; Node Ink). Matters for shipping to arbitrary machines.
3. **Paradigm** — retained/reactive (Ink React, Textual DOM) vs Elm/MVU (Bubble Tea) vs immediate-mode (Ratatui). Affects how much scaffolding an agent must generate and how state is modeled.
4. **Component richness vs control** — Textual (most built-in widgets + CSS) > Charm (cohesive mid set) > Ink (small core + `@inkjs/ui`) > Ratatui (primitives, you assemble; richest *control*).
5. **Performance ceiling** — Ratatui > Bubble Tea > Textual > Ink for high-frequency full-screen updates. Ink's repaint ceiling bites on token-streaming + large live tables.
6. **Styling model** — Textual TCSS (real CSS files/selectors/themes, hot reload) is the richest; Lip Gloss (chained styles + adaptive color); Ink (flexbox props); Ratatui (`Stylize` + manual layout constraints).
7. **Testing story** — Textual Pilot + SVG snapshots (strongest); Ink `ink-testing-library`; Bubble Tea pure-`Update` tests / teatest / VHS; Ratatui `TestBackend`.
8. **Special capabilities** — browser serving → Textual; SSH serving → Wish (Go); shell-only prompts → Gum; images in terminal → `ratatui-image`.
9. **Maintenance/roadmap risk** — Textual is single-maintainer post-company-closure (still alive, MIT); Ink single-maintainer but huge usage; Charm & Ratatui have active teams. Prefer actively-teamed projects for long-horizon bets.
10. **Version currency** — Ratatui is pre-1.0 (pin exact); Charm is mid v1→v2 import migration (`charm.land/*`, `tea.KeyPressMsg`); Ink stale `ink-*` widgets → prefer `@inkjs/ui`.

### 4.1 Paradigm map (the biggest fork in the road)

The rendering/state paradigm shapes how much scaffolding an agent generates and how state is modeled. It's often more decisive than which library within a language.

| Paradigm | How it works | Frameworks | Trade-off |
|---|---|---|---|
| **Immediate-mode** | You redraw the whole frame from your own state each tick; lib diffs buffers | Ratatui, notcurses, FTXUI-dom | Max control + perf; more boilerplate; you own all state |
| **Elm / MVU** | Model → Update(msg) → View; messages + commands | Bubble Tea, Ratatouille, tui-realm | Very testable, clean async; learning curve, verbose for simple UIs |
| **Retained / reactive** | Declarative components + reactive state + CSS/flexbox | Textual, Ink, OpenTUI, iocraft | Least code for rich apps; cede render control; heavier runtime |
| **Callback / view-tree** | Build widget tree, wire callbacks, lib owns loop + widget state | tview, cursive, urwid, Lanterna, blessed | Fast for forms/dialogs, GUI-dev familiar; harder to unit-test; mutable state |

### 4.2 Quick heuristics (language-independent)

- Single-binary CLI tool, custom UI, async-heavy → **Bubble Tea** (Go) or **Ratatui** (Rust).
- Fast off-the-shelf widgets / ops dashboard → **tview** (Go) · **Spectre.Console** (.NET) · **Textual** (Python).
- React/TS shop needing perf / 3D / SSH → **OpenTUI**; conservative React-TUI → **Ink**.
- REPL / shell / line editor → **prompt_toolkit** (Python).
- Just a prompt wizard, not a TUI → **@clack/prompts** or **@inquirer/prompts** (don't reach for a framework).
- Terminal images / video → **notcurses** (C) or **libvaxis** (Zig).
- Pretty non-interactive output only → **Rich** (Python) · **pterm** (Go) · **Spectre** (.NET).
- Serve in a **browser** → **Textual** (textual-serve) or **FTXUI** (WASM). Serve over **SSH** → **Wish** (Go) or **@opentui/ssh**.

### 4.3 Maintenance-risk flags (2026) — bias agents away from dead deps

- **Legacy / abandoned — maintain-only, don't pick for new work:** blessed, neo-blessed, blessed-contrib, prompts, Enquirer (dormant), npyscreen, termui (semi-dormant).
- **Single-maintainer / low-cadence — usable but weigh risk:** tview, cursive, terminal-kit, Ink, Textual/Rich (post-Textualize company closure, community-funded), Ratatouille.
- **Pre-1.0 API churn — pin exact versions:** Ratatui (0.x), OpenTUI (0.4.x; some docs cite stale 0.1.x), libvaxis (tracks pre-1.0 Zig).
- **In-flight migration — don't mix versions:** Charm v1→v2 (`charm.land/*`, `tea.KeyPressMsg`), tcell v2↔v3.
- **Unidentified/early — verify before use:** a stray "29" reference is likely `ratatat`; TamboUI (Java), crystal_tui, nimwave are early/low-activity.

---

## 5. Code-generation rules for agents (per framework)

- **Ink:** scaffold React components; put append-only output in `<Static>`; memoize hot subtrees; guard `useInput` with raw-mode check; default widgets to `@inkjs/ui`, not stale `ink-*`.
- **Bubble Tea:** always scaffold `Model`/`Init`/`Update`/`View`; route ALL async work through `Cmd` (never block `Update`); `return m, cmd`; forward+bubble child `Update`/`Cmd`; pin ONE major version (v1 `github.com/charmbracelet` + `tea.KeyMsg` **or** v2 `charm.land` + `tea.KeyPressMsg`) — never mix.
- **Ratatui:** generate the full harness (raw mode, alt screen, panic-restore via `ratatui::init/restore` + `color-eyre`, event loop, quit); store `ListState`/`TableState`/`ScrollbarState` in the app struct (not per-frame); filter `KeyEventKind::Press`; pin exact 0.x version; reach for `tui-input`/`tui-textarea`/`tui-tree-widget` (core has none).
- **Textual:** never block the loop — use `@work`/`@work(thread=True)`; do setup in `on_mount` not `compose`; put styling in `.tcss` with IDs/classes; use `@on(...)` handlers; `call_from_thread` for cross-thread UI updates; `@work(exclusive=True)` for search-as-you-type.

---

## 6. Canonical docs

- **Ink:** https://github.com/vadimdemedes/ink · `@inkjs/ui` https://github.com/vadimdemedes/ink-ui · https://www.npmjs.com/package/ink
- **Bubble Tea / Charm:** https://github.com/charmbracelet/bubbletea · bubbles /bubbles · lipgloss /lipgloss · huh /huh · gum /gum · glamour /glamour · wish /wish · https://charm.sh
- **Ratatui:** https://ratatui.rs/ · https://docs.rs/ratatui · https://github.com/ratatui/ratatui · https://github.com/ratatui/awesome-ratatui
- **Textual / Rich:** https://textual.textualize.io/ · widget gallery /widget_gallery/ · https://rich.readthedocs.io/ · textual-serve https://github.com/Textualize/textual-serve
- **OpenTUI:** https://github.com/anomalyco/opentui · https://opentui.com · `awesome-opentui`
- **Elixir:** Ratatouille https://github.com/ndreynolds/ratatouille · Owl https://github.com/fuelen/owl
- **Others:** tview https://github.com/rivo/tview · cursive https://github.com/gyscos/cursive · prompt_toolkit https://github.com/prompt-toolkit/python-prompt-toolkit · Spectre.Console https://spectreconsole.net · FTXUI https://github.com/ArthurSonzogni/FTXUI · notcurses https://github.com/dankamongmen/notcurses · libvaxis https://github.com/rockorager/libvaxis · brick https://github.com/jtdaugherty/brick · @clack/prompts https://github.com/bombshell-dev/clack
