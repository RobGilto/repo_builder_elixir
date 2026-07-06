# Dialyzer ignore filters (referenced by mix.exs :dialyzer config).
#
# Keep this list MINIMAL — every entry is a documented, justified exception.
# `list_unused_filters: true` in mix.exs fails CI when an entry here goes stale,
# so prune entries when the underlying warning is fixed.
#
# Each entry is `{path}` | `{path, warning}` | `{path, warning, line}`.
# Generate strict entries with: mix dialyzer --format ignore_file_strict
[
  # TypeCheck's `@type!` macro generates a 0-arity type-descriptor function per declared
  # wire type (`json_value/0`+`frame/0`, `wire_value/0`+`wire/0`). Dialyzer reads these
  # generated builders as `:no_return` (it cannot prove the macro-built term is returned).
  # They are confined to a nested `Types`/`Wire` module and driven ONLY through TypeCheck's
  # COMPILE-TIME `conforms?/2` macro, so the dependent `:extra_range` false positive that
  # used to cascade onto the real public `conforms?` functions is now gone — only the
  # generated builders themselves remain flagged. Exercised by RepoBuilder.Harness.WireTest
  # and RepoBuilder.Plugins.ManifestTest. Pinned to type_check 0.13.7 (latest release; no
  # newer version supports Elixir 1.20).
  {"lib/repo_builder/harness/wire.ex", :no_return},
  {"lib/repo_builder/plugins/manifest.ex", :no_return},
  {"lib/repo_builder/plugins/quality_gate.ex", :no_return},
  {"lib/repo_builder/plugins/design_system.ex", :no_return},
  # Contract supertype — `leader_brain_attrs/2` (defp, no external callers) returns
  # `map()` in its spec to avoid exposing an internal implementation shape. The actual
  # runtime value is a fixed-key map `%{harness: _, provider: _, model: _, session_id: _}`
  # that callers (e.g. `apply_harness_defaults/2`) always access via pattern matching,
  # so the relaxed spec is a deliberate internal design choice, not a safety concern.
  {"lib/repo_builder/orchestrator.ex", :contract_supertype, 218},
  # maybe_put/3 key is typed as String.t() (the public contract); Dialyzer narrows it to
  # the literal constant strings used at the two call sites. Keeping the broader spec is
  # safer since new fields can be added without widening the type declaration.
  {"lib/repo_builder/adw/step_spec.ex", :contract_supertype}
]
