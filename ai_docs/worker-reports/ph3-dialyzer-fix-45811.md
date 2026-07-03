# Worker report: ph3-dialyzer-fix (idle)

All 6 edits confirmed. Final report:

## Dialyzer-fix worker report

**1. Six @spec edits applied:**

| # | File:line | Before | After |
|---|---|---|---|
| 1 | `lib/repo_builder/adw/combo.ex:163` | `@spec get(map(), atom()) :: term()` | `@spec get(map(), :flavor \| :name \| :steps) :: any()` |
| 2 | `lib/repo_builder/adw/combos.ex:121` | `@spec delete(String.t()) :: :ok \| {:error, reason()}` | `@spec delete(binary()) :: :ok \| {:error, atom()}` |
| 3 | `lib/repo_builder/adw/combos.ex:138` | `@spec rm(String.t()) :: :ok \| {:error, reason()}` | `@spec rm(binary()) :: :ok \| {:error, atom()}` |
| 4 | `lib/repo_builder/adw/combos.ex:216` | `@spec get(map(), atom()) :: term()` | `@spec get(map(), :flavor \| :initial_prompt \| :local \| :name \| :overwrite \| :spec \| :steps) :: any()` *(wrapped to 2 lines for `mix format` line-length)* |
| 5 | `lib/repo_builder/adw/scaffold.ex:89` | `@spec valid_steps() :: [step()]` | `@spec valid_steps() :: [:build \| :document \| :patch \| :plan \| :review \| :ship \| :test, ...]` |
| 6 | `lib/repo_builder/adw/scaffold.ex:131` | `@spec flavor(term()) :: {:ok, flavor()} \| {:error, reason()}` | `@spec flavor(term()) :: {:error, :invalid_flavor} \| {:ok, :iso \| :local_iso}` *(param kept as `term()` not `_` — see note)* |

**2. 7th warning (`Orchestrators.leader_brain_attrs/2` @ orchestrator.ex:218):** **Pre-existing.** `git blame` shows it was introduced by commit `70952cc` on 2026-06-27 (weeks before this workstream). The most recent touch to orchestrator.ex (commit `dd3ff46`) was at line 701+, not line 218. **NOT in `.dialyzer_ignore.exs`** — the only entries there are `wire.ex`, `manifest.ex`, `quality_gate.ex` for `:no_return`.

**3. Gate exit codes (re-run):**
- FMT=0, COMPILE=0, CREDO=0, TEST=0, DIALYZER=2

**4. Dialyzer still red:** The 6 workstream warnings are gone (Total errors 13→7, Skipped 6). The single remaining warning is the pre-existing orchestrator one above — quoted verbatim:

```
lib/repo_builder/orchestrator.ex:218:contract_supertype
@spec leader_brain_attrs(map(), String.t()) :: map()
Success typing: @spec leader_brain_attrs(%{binary() => %{binary() => nil | binary()}}, binary()) :: %{
  :harness => atom() | binary(),
  :model => _,
  :provider => _,
  :session_id => nil,
  _ => _
}
```

**Note on fix #6:** The brief's literal "Replace with" was `@spec flavor(_) :: …`. `_/0` is dialyzer's unbound-variable notation, not valid Elixir typespec — it produced `Kernel.TypespecError` and broke compile. I substituted `term()` in the param position (matches the module's existing convention) while keeping the return-type narrowing verbatim. The orchestrator should decide whether to fix or ignore the 7th pre-existing warning.
