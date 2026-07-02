// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/repo_builder"
import topbar from "../vendor/topbar"

// --- Orchestration console hooks (BUILD_PROMPT.md §9) ---

// Keep a scroll container pinned to the bottom on update. Two gates: the server
// AUTO-FOLLOW toggle (data-auto-follow="false") is the master off-switch, and a
// local check pauses follow when the user scrolls up, resuming once they return
// to the bottom — so live updates never yank you away from scrollback.
const AutoScroll = {
  mounted() {
    this.userAtBottom = true
    this.el.addEventListener(
      "scroll",
      () => {
        const { scrollTop, scrollHeight, clientHeight } = this.el
        this.userAtBottom = scrollHeight - scrollTop - clientHeight < 40
      },
      { passive: true },
    )
    this.scrollToBottom()
  },
  updated() { this.scrollToBottom() },
  scrollToBottom() {
    if (this.el.dataset.autoFollow === "false") return
    if (this.userAtBottom === false) return
    this.el.scrollTop = this.el.scrollHeight
  },
}

// Copy a chip's data-copy text to the clipboard (command-input system info).
const ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy
      if (text && navigator.clipboard) navigator.clipboard.writeText(text)
    })
  },
}

const CommandAutocomplete = {
  mounted() {
    // --- existing CommandPaste: paste-to-upload ---
    this._onPaste = (e) => {
      const items = Array.from(e.clipboardData?.items ?? [])
      const imageItems = items.filter(item => item.kind === "file" && item.type.startsWith("image/"))
      if (imageItems.length === 0) return

      const uploadInput = document.querySelector("input[data-phx-upload-ref][name^='attachments']")
      if (!uploadInput) return

      e.preventDefault()

      const dt = new DataTransfer()
      Array.from(uploadInput.files ?? []).forEach(f => dt.items.add(f))
      imageItems.forEach(item => {
        const file = item.getAsFile()
        if (file) {
          const ext = file.type.split("/")[1] ?? "png"
          const named = new File([file], `paste-${Date.now()}.${ext}`, { type: file.type })
          dt.items.add(named)
        }
      })

      uploadInput.files = dt.files
      uploadInput.dispatchEvent(new Event("change", { bubbles: true }))
    }
    this.el.addEventListener("paste", this._onPaste)

    // --- existing CommandPaste: rb:insert-token (palette chip click) ---
    this._onInsertToken = (e) => {
      const token = e.detail?.token
      if (!token) return

      const el = this.el
      const start = el.selectionStart ?? el.value.length
      const end = el.selectionEnd ?? el.value.length
      const before = el.value.slice(0, start)
      const after = el.value.slice(end)
      const lead = before.length > 0 && !/\s$/.test(before) ? " " : ""
      const trail = after.length > 0 && !/^\s/.test(after) ? " " : ""
      const insert = lead + token + trail

      el.value = before + insert + after
      const caret = before.length + insert.length
      el.setSelectionRange(caret, caret)
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.focus()
    }
    this.el.addEventListener("rb:insert-token", this._onInsertToken)

    // --- new: autocomplete ---
    this._items = []           // parsed from data-autocomplete
    this._activeIdx = -1
    this._dropEl = document.getElementById("autocomplete-dropdown")

    this._readItems()          // parse data attr on mount

    this._onInput = () => this._handleInput()
    this._onKeydown = (e) => this._handleKeydown(e)
    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onKeydown)
    if (this._dropEl) {
      this._dropEl.addEventListener("mousedown", (e) => this._handleDropClick(e))
    }
  },

  updated() {
    // Re-read items when LiveView re-renders the textarea (new defs loaded).
    this._readItems()
  },

  destroyed() {
    this.el.removeEventListener("paste", this._onPaste)
    this.el.removeEventListener("rb:insert-token", this._onInsertToken)
    this.el.removeEventListener("input", this._onInput)
    this.el.removeEventListener("keydown", this._onKeydown)
  },

  // Parse the data-autocomplete JSON attr into this._items.
  _readItems() {
    try {
      this._items = JSON.parse(this.el.dataset.autocomplete || "[]")
    } catch (_) {
      this._items = []
    }
  },

  // Detect the active trigger+query at the caret.
  // Returns {trigger, query, triggerStart} or null.
  _detectTrigger() {
    const el = this.el
    const caret = el.selectionStart ?? el.value.length
    const before = el.value.slice(0, caret)
    // Walk backwards to find trigger char with no intervening whitespace.
    const match = before.match(/([\/\@\!])([^\s\/\@\!]*)$/)
    if (!match) return null
    return {
      trigger: match[1],
      query: match[2],
      triggerStart: caret - match[0].length
    }
  },

  _handleInput() {
    const det = this._detectTrigger()
    if (!det) { this._hide(); return }
    const {trigger, query} = det
    const matches = this._items
      .filter(item => item.trigger === trigger)
      .filter(item => item.label.toLowerCase().startsWith(query.toLowerCase()))
      .slice(0, 10)
    if (matches.length === 0) { this._hide(); return }
    this._activeIdx = 0
    this._render(matches, query)
    this._show()
  },

  _handleKeydown(e) {
    if (!this._dropEl || this._dropEl.style.display === "none") return
    const items = this._dropEl.querySelectorAll("[data-idx]")
    if (e.key === "ArrowDown") {
      e.preventDefault()
      this._activeIdx = Math.min(this._activeIdx + 1, items.length - 1)
      this._updateActive(items)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this._activeIdx = Math.max(this._activeIdx - 1, 0)
      this._updateActive(items)
    } else if (e.key === "Enter" && this._activeIdx >= 0) {
      e.preventDefault()
      const active = items[this._activeIdx]
      if (active) this._select(active.dataset.token)
    } else if (e.key === "Escape") {
      this._hide()
    }
  },

  _handleDropClick(e) {
    const item = e.target.closest("[data-idx]")
    if (item) {
      e.preventDefault() // prevent textarea blur
      this._select(item.dataset.token)
    }
  },

  _select(token) {
    const det = this._detectTrigger()
    if (!det) return
    const el = this.el
    const caret = el.selectionStart ?? el.value.length
    const before = el.value.slice(0, det.triggerStart)
    const after = el.value.slice(caret)
    const lead = before.length > 0 && !/\s$/.test(before) ? " " : ""
    const trail = after.length > 0 && !/^\s/.test(after) ? " " : ""
    el.value = before + lead + token + trail + after
    const pos = det.triggerStart + lead.length + token.length + trail.length
    el.setSelectionRange(pos, pos)
    el.dispatchEvent(new Event("input", { bubbles: true }))
    el.focus()
    this._hide()
  },

  // Render matched items into the dropdown div with cyan prefix highlighting.
  _render(matches, query) {
    if (!this._dropEl) return
    this._dropEl.innerHTML = matches.map((item, idx) => {
      const labelLo = item.label.toLowerCase()
      const qLo = query.toLowerCase()
      const matchLen = qLo.length
      const prefix = item.label.slice(0, matchLen)   // typed portion
      const rest = item.label.slice(matchLen)
      const triggerHtml = item.trigger === "/" ? "/" : item.trigger === "@" ? "@" : "!"
      const active = idx === this._activeIdx ? "background: var(--cns-surface-1, #222);" : ""
      return `<div
        data-idx="${idx}"
        data-token="${escapeHtml(item.token)}"
        class="cns-autocomplete__item"
        role="option"
        style="padding:4px 8px;cursor:pointer;${active}display:flex;flex-direction:column;gap:1px"
        title="${escapeHtml(item.description || item.token)}"
      >
        <span style="font-size:0.7rem;color:var(--cns-text)">
          <span style="color:var(--cns-cyan)">${escapeHtml(triggerHtml + prefix)}</span>${escapeHtml(rest)}
        </span>
        ${item.description ? `<span style="font-size:0.6rem;color:var(--cns-text-2)">${escapeHtml(item.description)}</span>` : ""}
      </div>`
    }).join("")
  },

  _updateActive(items) {
    items.forEach((el, i) => {
      el.style.background = i === this._activeIdx ? "var(--cns-surface-1, #222)" : ""
    })
  },

  _show() {
    if (this._dropEl) this._dropEl.style.display = "block"
  },

  _hide() {
    if (this._dropEl) { this._dropEl.style.display = "none"; this._activeIdx = -1 }
  },
}

// Safe HTML escaper used by the dropdown renderer.
function escapeHtml(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

// Spreadsheet-style click-and-drag range selection of log-row checkboxes
// (issue drag-select). Lives on a STABLE wrapper (#event-stream-wrap), not the
// phx-update="stream" node, so it survives stream DOM churn and leaves AutoScroll
// alone. Pointer Events cover mouse + touch in one path; no drag library.
//
// Gesture: pointerdown on a `.cns-event-row__select` records the anchor row id and a
// mode = OPPOSITE of the anchor's current checked state. pointermove optimistically
// paints the contiguous range between anchor and the row under the pointer to `mode`
// (no per-row round-trip). pointerup commits ONE `select_drag` and swallows the
// trailing synthetic click so it can't double-toggle. A pure click (no drag) does
// nothing here and falls through to the native phx-click="toggle_select".
const DragSelect = {
  mounted() {
    this.dragging = false
    this.didDrag = false
    this.mode = "select"
    this.anchorId = null
    this.painted = new Set()
    this.suppressNextClick = false

    this._onPointerDown = (e) => {
      const box = e.target.closest(".cns-event-row__select")
      if (!box || !this.el.contains(box)) return
      this.dragging = true
      this.didDrag = false
      this.anchorId = box.dataset.rowId
      this.mode = box.checked ? "deselect" : "select"
      this.painted = new Set()
      this.el.classList.add("cns-dragging")
    }

    this._onPointerMove = (e) => {
      if (!this.dragging) return
      const row = document.elementFromPoint(e.clientX, e.clientY)?.closest("[id^='ev-row-']")
      if (!row) return
      const box = row.querySelector(".cns-event-row__select")
      if (!box) return
      if (box.dataset.rowId !== this.anchorId) this.didDrag = true
      this.paintRange(box.dataset.rowId)
    }

    this._onPointerUp = () => {
      if (!this.dragging) return
      const wasDrag = this.didDrag
      const ids = [...this.painted]
      const mode = this.mode
      this.dragging = false
      this.el.classList.remove("cns-dragging")

      if (wasDrag && ids.length > 0) {
        this.suppressNextClick = true
        this.pushEvent("select_drag", {ids, mode})
      }
      this.anchorId = null
      this.painted = new Set()
    }

    // Capture-phase click swallow: one synthetic click follows the commit pointerup;
    // drop exactly that one so the drag doesn't also single-toggle a row.
    this._onClickCapture = (e) => {
      if (!this.suppressNextClick) return
      this.suppressNextClick = false
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown)
    // pointermove/up on document so a release or drag outside the wrapper still works.
    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
    document.addEventListener("pointercancel", this._onPointerUp)
    this.el.addEventListener("click", this._onClickCapture, true)
  },

  // Recompute the inclusive range from the CURRENT DOM each move (rows may arrive live),
  // paint in-range checkboxes to `mode`, and revert rows painted earlier this drag that
  // fell out of range (handles an up-then-down sweep).
  paintRange(currentId) {
    const boxes = [...this.el.querySelectorAll(".cns-event-row__select")]
    const ai = boxes.findIndex(b => b.dataset.rowId === this.anchorId)
    const ci = boxes.findIndex(b => b.dataset.rowId === currentId)
    if (ai === -1 || ci === -1) return

    const [lo, hi] = ai <= ci ? [ai, ci] : [ci, ai]
    const want = this.mode === "select"
    const inRange = new Set()

    for (let i = lo; i <= hi; i++) {
      const box = boxes[i]
      inRange.add(box.dataset.rowId)
      this.paintBox(box, want)
      this.painted.add(box.dataset.rowId)
    }

    // Revert previously-painted, now-out-of-range rows to the OPPOSITE of `want`.
    for (const id of [...this.painted]) {
      if (inRange.has(id)) continue
      const box = boxes.find(b => b.dataset.rowId === id)
      if (box) this.paintBox(box, !want)
      this.painted.delete(id)
    }
  },

  paintBox(box, checked) {
    box.checked = checked
    box.closest(".cns-event-row")?.classList.toggle("cns-event-row--selected", checked)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("pointercancel", this._onPointerUp)
    this.el.removeEventListener("click", this._onClickCapture, true)
  },
}

// Click-to-copy / drag-to-copy-range for the durable log-number chip
// (issue log-copy-chip). Hosted on the stable #logs-pane (NOT #event-stream-wrap,
// which already owns the one permitted phx-hook, DragSelect), so it survives stream
// churn. Delegates from `.cns-event-row__ln[data-log]` cells: a plain click copies
// that cell's `log-XXXX`; a drag across rows copies EVERY spanned log number,
// compressed into consecutive runs and split on gaps (e.g. "log-184 to log-187,
// log-190") so the copy describes exactly which rows were collected, not just the
// two endpoints (direction-agnostic). Mirrors DragSelect's pointer-drag +
// capture-phase click-swallow and ClipboardCopy's clipboard guard. Pure client: no
// server round-trip. Guards on `.cns-event-row__ln` so it never co-fires with
// DragSelect (which guards on `.cns-event-row__select`).
const LogCopy = {
  mounted() {
    this.dragging = false
    this.didDrag = false
    this.anchorEl = null
    this.endEl = null
    this.suppressNextClick = false

    this._onPointerDown = (e) => {
      const cell = e.target.closest?.(".cns-event-row__ln")
      if (!cell || !cell.dataset.log || !this.el.contains(cell)) return
      this.dragging = true
      this.didDrag = false
      this.anchorEl = cell
      this.endEl = cell
      // Suppress native text selection for the gesture (reuses DragSelect's class +
      // its `.cns-dragging * { user-select: none }` rule), so the drag never paints
      // the browser's blue highlight across rows.
      this.el.classList.add("cns-dragging")
    }

    // Track the log cell under the pointer; recompute from the live DOM so rows that
    // arrive mid-gesture are handled at release. An up-then-down sweep is fine — order
    // is resolved from DOM position on pointerup, not from drag direction.
    this._onPointerMove = (e) => {
      if (!this.dragging) return
      const row = document.elementFromPoint(e.clientX, e.clientY)?.closest("[id^='ev-row-']")
      const cell = row?.querySelector(".cns-event-row__ln[data-log]")
      if (!cell) return
      if (cell !== this.anchorEl) this.didDrag = true
      this.endEl = cell
    }

    this._onPointerUp = () => {
      if (!this.dragging) return
      this.dragging = false
      this.el.classList.remove("cns-dragging")
      const anchor = this.anchorEl
      const end = this.endEl
      this.anchorEl = null
      this.endEl = null
      if (!anchor) return

      let text, cells
      if (!this.didDrag || !end || end === anchor) {
        text = anchor.dataset.log
        cells = [anchor]
      } else {
        // Collect EVERY log cell the drag actually spans (not just the two endpoints),
        // recomputed from the live DOM so the copy reflects the real rows on screen.
        cells = this.cellsBetween(anchor, end)
        text = this.formatLogs(cells)
        // Clear any selection that began in the first frame before the class took effect.
        window.getSelection()?.removeAllRanges()
      }

      if (text && navigator.clipboard) navigator.clipboard.writeText(text)
      this.flash(cells)
      this.suppressNextClick = true
    }

    // Capture-phase swallow: drop the synthetic post-drag click AND any click that
    // originates on a log cell, so a copy gesture never fires the row's toggle_event.
    this._onClickCapture = (e) => {
      const onCell = e.target.closest?.(".cns-event-row__ln")
      if (!this.suppressNextClick && !onCell) return
      this.suppressNextClick = false
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown)
    // pointermove/up on document so a release or drag outside the pane still commits.
    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
    document.addEventListener("pointercancel", this._onPointerUp)
    this.el.addEventListener("click", this._onClickCapture, true)
  },

  // Every `.cns-event-row__ln[data-log]` cell in DOM order between two endpoints
  // (inclusive), direction-agnostic. Reads the current DOM so rows that arrived
  // mid-gesture are included.
  cellsBetween(anchor, end) {
    const all = [...this.el.querySelectorAll(".cns-event-row__ln[data-log]")]
    const ai = all.indexOf(anchor)
    const ei = all.indexOf(end)
    if (ai === -1 || ei === -1) return [anchor]
    const [lo, hi] = ai <= ei ? [ai, ei] : [ei, ai]
    return all.slice(lo, hi + 1)
  },

  // Render the spanned cells as an accurate, copy-friendly string. Consecutive log
  // numbers collapse to "log-A to log-B"; gaps split into separate ranges, so a
  // multi-range or sparse selection is described exactly (e.g. "log-184 to log-187,
  // log-190, log-192 to log-193"). Falls back to a comma list if numbers don't parse.
  formatLogs(cells) {
    const nums = [...new Set(
      cells
        .map(c => parseInt(String(c.dataset.log).replace(/^log-/, ""), 10))
        .filter(n => Number.isFinite(n))
    )].sort((a, b) => a - b)
    if (nums.length === 0) return cells.map(c => c.dataset.log).join(", ")

    const runs = []
    let start = nums[0]
    let prev = nums[0]
    for (let i = 1; i < nums.length; i++) {
      if (nums[i] === prev + 1) { prev = nums[i]; continue }
      runs.push([start, prev])
      start = prev = nums[i]
    }
    runs.push([start, prev])
    return runs.map(([a, b]) => (a === b ? `log-${a}` : `log-${a} to log-${b}`)).join(", ")
  },

  flash(cells) {
    cells.forEach(c => c.classList.add("cns-event-row__ln--copied"))
    setTimeout(() => cells.forEach(c => c.classList.remove("cns-event-row__ln--copied")), 600)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("pointercancel", this._onPointerUp)
    this.el.removeEventListener("click", this._onClickCapture, true)
  },
}

// Drag-select for the Log Database manager popup (issue-log-db-manager). A self-contained
// clone of DragSelect scoped to the manager's OWN classes/ids/event so the live main-view
// hook is untouched: checkbox `.log-mgr-row__select`, row matcher `[id^='log-mgr-row-']`,
// painted-row class `.log-mgr-row--selected`, commit event `log_select_drag`. Ids here are
// UUID strings (not the live view's integers), so the two selection systems never collide.
// Reuses DragSelect's `.cns-dragging` user-select suppression on the stable table host.
const LogDragSelect = {
  mounted() {
    this.dragging = false
    this.didDrag = false
    this.mode = "select"
    this.anchorId = null
    this.painted = new Set()
    this.suppressNextClick = false

    this._onPointerDown = (e) => {
      const box = e.target.closest(".log-mgr-row__select")
      if (!box || !this.el.contains(box)) return
      this.dragging = true
      this.didDrag = false
      this.anchorId = box.dataset.rowId
      this.mode = box.checked ? "deselect" : "select"
      this.painted = new Set()
      this.el.classList.add("cns-dragging")
    }

    this._onPointerMove = (e) => {
      if (!this.dragging) return
      const row = document.elementFromPoint(e.clientX, e.clientY)?.closest("[id^='log-mgr-row-']")
      if (!row) return
      const box = row.querySelector(".log-mgr-row__select")
      if (!box) return
      if (box.dataset.rowId !== this.anchorId) this.didDrag = true
      this.paintRange(box.dataset.rowId)
    }

    this._onPointerUp = () => {
      if (!this.dragging) return
      const wasDrag = this.didDrag
      const ids = [...this.painted]
      const mode = this.mode
      this.dragging = false
      this.el.classList.remove("cns-dragging")

      if (wasDrag && ids.length > 0) {
        this.suppressNextClick = true
        this.pushEvent("log_select_drag", {ids, mode})
      }
      this.anchorId = null
      this.painted = new Set()
    }

    this._onClickCapture = (e) => {
      if (!this.suppressNextClick) return
      this.suppressNextClick = false
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown)
    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup", this._onPointerUp)
    document.addEventListener("pointercancel", this._onPointerUp)
    this.el.addEventListener("click", this._onClickCapture, true)
  },

  paintRange(currentId) {
    const boxes = [...this.el.querySelectorAll(".log-mgr-row__select")]
    const ai = boxes.findIndex(b => b.dataset.rowId === this.anchorId)
    const ci = boxes.findIndex(b => b.dataset.rowId === currentId)
    if (ai === -1 || ci === -1) return

    const [lo, hi] = ai <= ci ? [ai, ci] : [ci, ai]
    const want = this.mode === "select"
    const inRange = new Set()

    for (let i = lo; i <= hi; i++) {
      const box = boxes[i]
      inRange.add(box.dataset.rowId)
      this.paintBox(box, want)
      this.painted.add(box.dataset.rowId)
    }

    for (const id of [...this.painted]) {
      if (inRange.has(id)) continue
      const box = boxes.find(b => b.dataset.rowId === id)
      if (box) this.paintBox(box, !want)
      this.painted.delete(id)
    }
  },

  paintBox(box, checked) {
    box.checked = checked
    box.closest(".log-mgr-row")?.classList.toggle("log-mgr-row--selected", checked)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup", this._onPointerUp)
    document.removeEventListener("pointercancel", this._onPointerUp)
    this.el.removeEventListener("click", this._onClickCapture, true)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AutoScroll, ClipboardCopy, CommandAutocomplete, DragSelect, LogCopy, LogDragSelect},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// --- console keyboard shortcuts --------------------------------------------
// A single permanent document listener (NOT a LiveView hook, so it can never be
// detached by a DOM patch). ⌘K / ⌘J just click the existing buttons, which carry
// the LiveView JS commands (show_command opens the modal AND focuses its field in
// one synchronous client-side step — the reliable focus-on-open pattern).
document.addEventListener("keydown", e => {
  const meta = e.metaKey || e.ctrlKey
  if (meta && (e.key === "k" || e.key === "K")) {
    e.preventDefault()
    // Toggle: if the modal is already open, close it; otherwise open + focus.
    const modal = document.getElementById("command-input")
    const open = modal && modal.style.display !== "none"
    document.getElementById(open ? "prompt-close" : "prompt-toggle")?.click()
  } else if (meta && (e.key === "j" || e.key === "J")) {
    e.preventDefault()
    document.getElementById("view-toggle")?.click()
  } else if (e.key === "Enter" && !e.shiftKey && e.target?.id === "command-textarea") {
    // Enter sends the command (Shift+Enter keeps the newline).
    e.preventDefault()
    e.target.form?.requestSubmit()
    // requestSubmit dispatches synchronously, so the command is already read —
    // clear the textarea so the modal reopens empty next time.
    e.target.value = ""
  }
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

