# Worker report: adw-combo-name-input-fix (idle)

All four verification stages are GREEN.

---

## Patch summary

**`lib/repo_builder_web/components/console/adw_builder_components.ex`** — inside the ADW Builder panel's "Workflow name + local toggle + harness picker" row, wrapped the bare `<input id="adw-combo-name">` in a `<div class="flex flex-col gap-1">` with a visible `<label for="adw-combo-name">WORKFLOW NAME</label>` above it (matching the LOAD COMBO label pattern), changed the misleading placeholder from `"Workflow name (optional)"` to `"Combo name"`, and added `aria-label="Workflow name"`. Toggle + harness siblings were left in the same row (minimal patch — option B was unnecessary and would have ballooned the diff).

**`test/repo_builder_web/live/test_adw_builder_save_combo_test.exs`** — added a new `describe "ADW Builder UI binding"` block with one regression test that mounts the console, opens the ADW Builder, and asserts the new label exists, the input bindings are intact, the label text reads "WORKFLOW NAME", and the old "(optional)" copy is gone.

## Line ranges edited

- `lib/repo_builder_web/components/console/adw_builder_components.ex` — original lines **276-287** (input block) replaced with the new label + wrapper + input spanning **276-294** (the outer `<div class="flex items-center gap-2">` row is unchanged; only its first child became the column group).
- `test/repo_builder_web/live/test_adw_builder_save_combo_test.exs` — appended new `describe "ADW Builder UI binding"` block spanning **lines 195-238** (immediately before the module's closing `end`).

## Gate exit codes

- **FMT**: 0
- **COMPILE**: 0
- **CREDO**: 0
- **TEST**: 0 (10 passed, 0 failed)

## New test assertion (verbatim)

```elixir
test "workflow name has a visible <label> bound to the input by id", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/")
  render_click(view, "toggle_adw_builder")

  assert has_element?(view, "label[for=\"adw-combo-name\"]")

  assert has_element?(
           view,
           "input#adw-combo-name[phx-change=\"adw_set_name\"][name=\"name\"]"
         )

  html = render(view)
  assert html =~ "WORKFLOW NAME"
  refute html =~ "Workflow name (optional)"
end
```

## Verdict

**PASS** — All four gate stages GREEN, no fix-loops needed, no hard-rules violated (handler file untouched, Save button `disabled` expression untouched, bare `<input>` preserved, no new deps, no out-of-repo edits).
