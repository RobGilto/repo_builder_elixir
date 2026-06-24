# Dialyzer ignore filters (referenced by mix.exs :dialyzer config).
#
# Keep this list MINIMAL — every entry is a documented, justified exception.
# `list_unused_filters: true` in mix.exs fails CI when an entry here goes stale,
# so prune entries when the underlying warning is fixed.
#
# Each entry is `{path}` | `{path, warning}` | `{path, warning, line}`.
# Generate strict entries with: mix dialyzer --format ignore_file_strict
[
  # TypeCheck's `@type!` macro (harness/wire.ex) generates a 0-arity type-descriptor
  # function per declared wire type (`json_value/0`, `frame/0`). Dialyzer analyzes
  # these generated builders as `:no_return` (it cannot prove the macro-built term
  # is returned), and the dependent `:extra_range` on `conforms?/2` cascades from
  # that false positive. The functions return normally at runtime — the wire-type
  # boundary tests exercise them. Pinned to type_check 0.13.7.
  {"lib/repo_builder/harness/wire.ex", :no_return},
  {"lib/repo_builder/harness/wire.ex", :extra_range},
  # Same TypeCheck `@type!` quirk in the plugin manifest wire boundary
  # (`wire/0`, `wire_value/0`); the dependent `:extra_range` on `conforms?/1`
  # cascades from it. Exercised by RepoBuilder.Plugins.ManifestTest. Pinned to
  # type_check 0.13.7.
  {"lib/repo_builder/plugins/manifest.ex", :no_return},
  {"lib/repo_builder/plugins/manifest.ex", :extra_range}
]
