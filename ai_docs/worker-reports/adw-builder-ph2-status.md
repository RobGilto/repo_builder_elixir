# Phase 2 status — ADW Builder combos + deterministic script generation

Scope: Plan Steps 5–8 + 10 (Phase 2 only). Phase 1 done; Phase 3 excluded.

## Deliverables
- [x] 1. lib/repo_builder/adw/combo.ex — typedstruct + validate/1, to_json/1, from_json/1, slugify_name/1 (present + verified)
- [x] 2. lib/repo_builder/adw/scaffold.ex — render/1 (_iso byte-parity, _local_iso monolithic) + generate/1 (present + verified; golden parity test green)
- [x] 3. lib/repo_builder/adw/combos.ex — list/0..1, fetch/1..2, save/1..2, delete/1..2 (sidecar + Scaffold.generate + Definitions.refresh; app-env root seam)
- [x] 4. Save-combo button + phx handler (console_components.ex "⭑ Save combo" btn; console_live.ex "adw_save_combo" handler + adw_combos seeded in seed_definitions)
- [x] 5. test/repo_builder/adw/scaffold_test.exs — golden byte-parity, allowlist, overwrite refusal, 0755 (11 tests)
- [x] 6. test/repo_builder/adw/combos_test.exs — sidecar + materialize round-trip vs app-env tmp root (10 tests)

## Notes
- Modules 1–3 were on disk from the prior worker; verified they compile, match the spec,
  and pass the new tests. No correctness fixes were needed.
- Deliverable 4 (Save-combo UI + handler) was NOT on disk — added it.
  - console_components.ex: "⭑ Save combo" button (disabled when no steps or blank name).
  - console_live.ex: alias RepoBuilder.Adw.Combos; `handle_event("adw_save_combo", …)`
    builds attrs from adw_name/adw_steps/adw_local?/adw_spec/adw_prompt → Combos.save/2
    (working-dir root), flashes on :exists / other errors, re-seeds adw_combos.
  - seed_definitions/1 now also seeds `adw_combos: Combos.list(working_dir)`.
- Load-combo dropdown + adw_load_combo/adw_delete_combo handlers are Phase 3 — not added.
- Credo fixes on prior-worker code: replaced single-branch `cond` with `if` in
  Scaffold.generate/1 and Combos.delete/2 (extracted `rm/1` helper, kept delete clauses grouped).

## Gate (final run)
FMT=0 COMPILE=0 CREDO=0 TEST=0

- `mix format --check-formatted` → 0
- `mix compile --force --warnings-as-errors` → 0
- `mix credo --strict` (full project, 507 files) → 0, no issues
- `mix test test/repo_builder/adw/` → 0, 21 passed
- (bonus) `mix test test/repo_builder_web/live/test_adw_builder_combos_test.exs` → 0, 2 passed

## git diff --stat
```
 lib/repo_builder/adw/combo.ex                      | 190 ++++++++++++
 lib/repo_builder/adw/combos.ex                     | 225 ++++++++++++++
 lib/repo_builder/adw/scaffold.ex                   | 331 +++++++++++++++++++++
 .../components/console_components.ex               |  66 +++-
 lib/repo_builder_web/live/console_live.ex          | 106 ++++++-
 test/repo_builder/adw/combos_test.exs              | 136 +++++++++
 test/repo_builder/adw/scaffold_test.exs            | 132 ++++++++
 7 files changed, 1170 insertions(+), 16 deletions(-)
```
