VERDICT: PASS

Scope: Phase 1 only (spec/prompt inputs + non-empty launch prompts), per
specs/issue-adw-builder-combos-adw-adw-prompt-combos-sdlc_planner-adw-builder-spec-prompt-and-combo-scripts.md.

## Verified
- catalog.ex:179-197 `default_prompt_template/1` — single `@spec`'d source of truth,
  covers plan/patch/build/test/review/document/ship + generic fallback; templates
  reference `{{input}}`/`{{spec}}`/prior-step outputs as required. Pure, no map()/any().
- console_components.ex:3887-3890 — new `attr`s declared (`adw_spec`, `adw_prompt`,
  `adw_combos`, `adw_selected_combo`); textareas at 4151-4170 render `{@adw_spec}`/
  `{@adw_prompt}` (assign-bound content, not a stale `value=`), so they correctly
  persist across LiveView re-renders while the modal stays open.
- console_live.ex:274-277 mount defaults; 1618-1624 `adw_set_spec`/`adw_set_prompt`
  handlers; 2288-2338 `launch_adw_builder/4` rewrite — builds per-step
  `prompt_template` via `Catalog.default_prompt_template/1`, chains `on_success`
  correctly, threads `inputs: %{"input" => initial_prompt, "spec" => spec}` with the
  name-only fallback when both blank (matches spec's stated edge case), resets
  `adw_spec`/`adw_prompt` on launch.
- Confirmed against `Runner.render/2` (runner.ex:286-291): `{{key}}` substitution
  contract matches what the test's local `render_template/2` mirrors.
- Ran `mix compile --warnings-as-errors` (clean) and
  `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs
  --warnings-as-errors` — 2/2 passed, assertions match spec's Phase-1 acceptance
  criteria (non-empty `prompt_template`, resolves to typed initial prompt, blank
  fallback launches without crash).

## Minor / non-blocking
- test run logged an `Ecto.StaleEntryError` from the async fake-harness `Runner`
  GenServer racing a concurrent `record_step_state` update (workflow_engine.ex:132,
  runner.ex:172/254) during the launch tests. Did not fail either test and the
  affected module (`WorkflowEngine.Runner`) is outside the Phase-1 diff, but the
  noisy stacktrace suggests a possible pre-existing concurrency edge case worth a
  follow-up look if it starts flaking other suites.
