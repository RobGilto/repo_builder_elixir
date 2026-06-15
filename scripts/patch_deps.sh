#!/usr/bin/env bash
# Reapply local dependency patches required by this environment.
#
# WHY THIS EXISTS
# ---------------
# type_check 0.13.7 (its latest release) references the `Regex.re_version`
# struct field, which was removed in Elixir 1.20. We delete that one line so it
# compiles. No newer type_check release exists that supports Elixir 1.20.
#
# Re-run after any `mix deps.get` / `mix deps.clean` that restores pristine dep
# sources, then `mix deps.compile type_check && mix compile`. Idempotent.
#
# NOTE: erlexec/muontrap previously needed native-build workarounds because the
# old project path contained a space ("TAC Repos"). The project now lives at a
# space-free path (/data/1.Projects/...), so those deps build normally and no
# longer need patching.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/deps/type_check/lib/type_check/default_overrides/regex.ex"

if [ -f "$TC" ] && grep -q "re_version: term()," "$TC"; then
  sed -i '/re_version: term(),/d' "$TC"
  echo "==> type_check: removed Regex.re_version line (Elixir 1.20 compat)"
else
  echo "==> type_check: nothing to patch (already applied or file moved)"
fi
