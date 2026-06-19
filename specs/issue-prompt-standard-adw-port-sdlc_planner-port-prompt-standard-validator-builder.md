# Feature: Port the "prompt-standard" feature (validator + builder + CLI) from the Python repo as its canonical home

## Metadata
issue_number: `prompt-standard` (port — no GitHub issue; this is a relocation of an existing, frozen-in-Python feature into its canonical Elixir home)
adw_id: `port`
issue_json: `{ "title": "Port the 'prompt-standard' feature from the Python repo to this Elixir/Phoenix repo as its canonical home", "body": "The prompt-standard feature (a §7 checklist validator + a Population A/B prompt builder + a validate/lint CLI) was implemented in the Python repo by mistake. It belongs here. The Python impl stays as a frozen, read-only reference (commit 6249331). Port it faithfully into RepoBuilder as the canonical home, honoring the typed Elixir standard, and ship it as mix tasks." }`

## Feature Description

A self-contained **prompt standard** toolkit for `repo_builder_elixir`: a machine-enforced
quality gate for two distinct prompt populations, plus a generator that always emits
conforming prompts, plus a CLI. It is a **relocation** of an existing, working feature
(`prompt_builder/` in the Python repo at commit `6249331`) into its canonical Elixir home,
where it coexists with the orchestration contexts.

The feature defines and enforces a **standard** for prompt `.md` files:

- **Population A** — factory *slash-command* prompts. They **have** YAML frontmatter
  (`description`, `argument-hint`, optional `allowed-tools`/`model`) and follow the
  `# Purpose → ## Variables → ## Instructions → (## Expertise) → ## Workflow → ## Report`
  taxonomy.
- **Population B** — runtime `.md` prompts. They are **frontmatter-FREE** (the loader does
  raw `File.read!`, so YAML would leak verbatim to the model) and follow the
  `# <Role> → ## Core Operating Principle → ## Your Tools (### Routing rules) → …`
  taxonomy.

Three layers, mirroring the Python package `prompt_builder/`:

1. **`RepoBuilder.PromptStandard.Validator`** — the §7 checklist. **HARD** checks H1–H9
   (H10 is intentionally **deferred/skipped**, matching the Python source — see H10 note)
   are pass/fail; **SOFT** checks S1–S5 are advisory warnings. Auto-detects population
   from frontmatter presence (present → A, else → B), overridable.
2. **`RepoBuilder.PromptStandard.Builder`** — assembles Population A and Population B
   prompts, performs closed-registry `{{TOKEN}}` substitution via `String.replace/3`
   (Path-1), and a combined `build_and_validate/2` that runs the validator as a quality
   gate, returning `{:error, %ValidationResult{}}` on any HARD failure (tagged-tuple, not
   a raise — per the typed standard).
3. **Mix CLI** — `mix repo_builder.prompt_standard.validate <file> [--population A|B]` and
   `mix repo_builder.prompt_standard.lint <dir> [--population A|B]`, with exit codes
   `0` (pass) / `1` (hard failure) / `2` (usage error) — a 1:1 mapping of the Python
   `python -m prompt_builder {validate,lint}` contract.

The spec itself (`ai_docs/prompt-standard-spec.md`, language-agnostic) ports into
`ai_docs/` as the editable living standard, with a header noting the Elixir port is
canonical and the Python copy is frozen reference.

## User Story
As a **prompt author / orchestration engineer working in `repo_builder_elixir`**
I want to **lint any `.md` prompt file against the §7 quality gate and generate conforming
Population A/B prompts from Elixir**
So that **prompts shipped in this repo (and injected into agents) are structurally sound,
never leak unresolved `{{TOKEN}}` sentinels to the model, never mix incompatible slot
mechanisms, and stay auditable through a typed, dialyzer-green, mix-native toolchain.**

## Problem Statement
The prompt standard was built in the **wrong repo** (Python). Today it lives at
`/data/1.Projects/repo_builder/prompt_builder/` and is frozen there at commit `6249331`.
`repo_builder_elixir` — the orchestration platform that actually *consumes* and *injects*
prompts into harness agents — has **no** equivalent: no validator, no builder, no lint CLI.
Prompt correctness (frontmatter validity, no mixed `{{TOKEN}}`/`{slot}`, no leaked sentinels,
population-correct taxonomy) is therefore unenforced on the Elixir side. The feature needs a
canonical, typed Elixir home that coexists with the existing `agents/`, `definitions/`,
`harness/`, and `explain/` contexts and that passes the enforced `mix precommit` gate.

## Solution Statement
Introduce a new **`RepoBuilder.PromptStandard`** context (a new top-level domain under
`lib/repo_builder/`, deliberately **not** `RepoBuilder.Prompts` — see Namespace Decision
below). It is a **pure, dependency-free-at-runtime** toolkit: no DB, no Ecto, no Oban, no
HTTP — only `yaml_elixir` (already a dep + in `plt_add_apps`), `typedstruct`, and the stdlib.
The context exposes a typed `Validator`, a typed `Builder`, shared domain structs
(`Population`, `ValidationResult`, `Frontmatter`), a closed `TOKEN_REGISTRY`, and two
`Mix.Tasks.RepoBuilder.PromptStandard.*` tasks. The spec markdown ports into `ai_docs/`.
Behavior is a faithful port of the Python source; the public surface is reshaped to the
typed-Elixir idiom (tagged tuples over raising, `typedstruct` structs, `@spec` everywhere).

---

## Namespace Decision (load-bearing — read before implementing)

The user-supplied context proposed `RepoBuilder.Prompts` for this feature. **That name is
already taken** by `lib/repo_builder/prompts.ex` + `lib/repo_builder/prompts/prompt.ex` — a
DB-backed "reusable prompt template" context (Ecto schema `prompts`, `BUILD_PROMPT.md` §8).
The spec itself opens with a warning that **"two distinct kinds of 'prompt' must never be
conflated."** Putting a file-linter into `RepoBuilder.Prompts` would conflate the §8 DB
template registry with the §7 file standard. Therefore the port uses a **distinct
namespace**, `RepoBuilder.PromptStandard`, which:

- matches the feature's own name ("prompt-standard") and the spec filename
  (`prompt-standard-spec.md`),
- leaves the existing `RepoBuilder.Prompts` context untouched,
- follows the repo's per-domain layout (`lib/repo_builder/<context>.ex` +
  `lib/repo_builder/<context>/*.ex`).

## Reference-vs-Context Correction (the user's check IDs were wrong)

The user's context described H-checks as `h000_valid_yaml_frontmatter`,
`h010_mandatory_keys`, `h020_no_extra_keys`, … . **That schema does not exist in the
reference.** The actual Python source (`prompt_builder/validator.py` +
`prompt_builder/models.py`) implements:

- a **`Population`** enum (`A`, `B`) and a **closed `TOKEN_REGISTRY`** frozenset
  (`{{SUBAGENT_MAP}}`, `{{HARNESS_CATALOG}}`),
- **HARD checks H1–H9** (H10 is **intentionally deferred/skipped** with a printed
  `SKIP` reason — see the `H10_SKIP_NOTE` in `__main__.py`), and
- **SOFT checks S1–S5**.

This plan ports the **actual reference** (H1–H9 + S1–S5, Population A/B, closed registry),
verbatim in behavior. The `h000/h010/…` schema is disregarded.

---

## Relevant Files
Use these files to implement the feature:

**Authoritative architecture / standards (read first):**
- `BUILD_PROMPT.md` — the frozen architecture/spec; §3 (typed style guide origin), §8
  (persistence contexts — confirms `RepoBuilder.Prompts` is the DB-template context we must
  NOT collide with), §11 (directory layout), §13 (testing).
- `ai_docs/typed-elixir-standard.md` — **enforced**. Rules 1 (`@spec` every public fn),
  3 (`typedstruct` + `@enforce_keys`), 5 (precise types), 6 (wire ≠ domain — YAML
  frontmatter is a wire boundary), 8 (decoders never raise), 9 (one nullable convention),
  10 (contexts are the only Repo callers — N/A here, this context is Repo-free).
- `AGENTS.md` — Elixir/Mix/Ecto/Phoenix guidelines (no nested modules per file; lists use
  `Enum.at`; `yaml_elixir` is the YAML lib; `req` for HTTP — none needed here).

**Existing patterns to mirror (the closest analogs):**
- `lib/repo_builder/definitions/slash_command.ex` — **the model to copy** for typedstruct +
  pure, fail-silent file `scan`, `@spec` on everything, string-keyed frontmatter access.
- `lib/repo_builder/orchestrator/template.ex` (`from_markdown/1`, `split_frontmatter`) —
  existing `YamlElixir`-backed frontmatter splitter. **Reference for the fence logic**, but
  the validator needs its own split (see `Frontmatter` design note in Phase 2) because
  `Template.from_markdown/1` conflates "absent" with "malformed" and merges `body` into the
  attrs map — the validator must distinguish frontmatter *presence* (population detection),
  *malformed YAML* (H1), and *missing keys* (H1) as three separate outcomes.
- `lib/repo_builder/definitions.ex` — context-module shape (`@moduledoc`, `@type` aliases,
  pure read API).
- `mix.exs` — `:yaml_elixir` and `:typedstruct` already present; `:yaml_elixir` already in
  `plt_add_apps`; `precommit` alias = `compile --warnings-as-errors`, `deps.unlock --unused`,
  `format`, `test`.
- `.credo.exs` — `{Credo.Check.Readability.Specs, [include_defp: false]}` is the `@spec`
  gate (exempts `@impl`).

**Reference source (read-only frozen truth — `/data/1.Projects/repo_builder/`, commit `6249331`):**
- `prompt_builder/validator.py` — the §7 checklist (port H1–H9, S1–S5 + section taxonomy +
  `_classify_heading` longest-prefix logic + `_detect_population` + `_extract_frontmatter`).
- `prompt_builder/builder.py` — `build_population_a/b`, `render/2`, `build_and_validate`.
- `prompt_builder/models.py` — `Population`, `TOKEN_REGISTRY`, `ValidationResult`,
  `PromptValidationError` (becomes a tagged tuple in Elixir, not an exception).
- `prompt_builder/__main__.py` — the CLI (`validate`, `lint`, exit codes 0/1/2, the H10
  `SKIP` row, the `_msgs_for` prefix-with-colon guard against H1/H10 collision).
- `tests/test_prompt_builder.py` — **32 tests** (not 23; the `def test_` count is 32 and the
  commit-6249331 message confirms "32 passing"); the **behavioral contract** to mirror in
  ExUnit. Map ports by test name, not by ordinal — see the recomputed cross-refs in Step 11.
- `ai_docs/prompt-standard-spec.md` — the spec (ports into `ai_docs/`).
- `ai_docs/prompt-anatomy.md` — the L1–L7 ladder + section taxonomy reference (ports into
  `ai_docs/`).

### New Files

**Context + domain (`lib/repo_builder/prompt_standard/`):**
- `lib/repo_builder/prompt_standard.ex` — the context façade (`validate/1,2`,
  `validate_file/1,2`, `build_population_a/1`, `build_population_b/1`, `render/2`,
  `build_and_validate/2`, `lint/1,2`, `population/0`, `token_registry/0`). Pure,
  no state, no Repo.
- `lib/repo_builder/prompt_standard/population.ex` — `Population` typedstruct/union (`:a | :b`)
  + `from_string/1`, `to_string/1`, `detect/1`.
- `lib/repo_builder/prompt_standard/token_registry.ex` — closed `TOKEN_REGISTRY` (`MapSet`
  of `{{SUBAGENT_MAP}}`, `{{HARNESS_CATALOG}}`) + `member?/1` + `list/0`.
- `lib/repo_builder/prompt_standard/validation_result.ex` — `ValidationResult` typedstruct
  (`passed`, `errors`, `warnings`, `population`) + `Inspect` impl that mirrors the Python
  `__str__` (`PASS`/`FAIL` table).
- `lib/repo_builder/prompt_standard/frontmatter.ex` — pure splitter:
  `parse/1 -> {:ok, map, body} | :absent | {:error, :malformed}` + `present?/1`.
- `lib/repo_builder/prompt_standard/taxonomy.ex` — the A/B section-heading sets, the
  A-only/B-only/shared derivations, and `classify_heading/1` (longest-prefix) — a direct
  port of the Python module-level constants + `_classify_heading`.
- `lib/repo_builder/prompt_standard/checks.ex` — the compiled regexes (`@double_brace`,
  `@single_brace`, `@frontmatter`, `@heading`, `@bom`) + small pure helpers
  (`find_tokens/1`, `find_slots/1`, `headings/1`). Keeps the validator readable.
- `lib/repo_builder/prompt_standard/validator.ex` — `Validator` module: `validate/1,2,3` +
  `validate_file/1,2` + the H1–H9 and S1–S5 implementations (private, one `defp` per check,
  each appending to an `errors`/`warnings` accumulator).
- `lib/repo_builder/prompt_standard/builder.ex` — `Builder` module:
  `build_population_a/1`, `build_population_b/1`, `render/2`, `build_and_validate/2`
  (returns `{:ok, String.t(), ValidationResult.t()} | {:error, ValidationResult.t()}`).

**CLI (`lib/mix/tasks/` — created for the first time here):**
- `lib/mix/tasks/repo_builder/prompt_standard/validate.ex` →
  `Mix.Tasks.RepoBuilder.PromptStandard.Validate` → `mix repo_builder.prompt_standard.validate`.
- `lib/mix/tasks/repo_builder/prompt_standard/lint.ex` →
  `Mix.Tasks.RepoBuilder.PromptStandard.Lint` → `mix repo_builder.prompt_standard.lint`.

**Spec docs (ported, language-agnostic — `ai_docs/`):**
- `ai_docs/prompt-standard-spec.md` — port of the Python `ai_docs/prompt-standard-spec.md`
  with a new header declaring the Elixir repo canonical and Python frozen.
- `ai_docs/prompt-anatomy.md` — port of the Python `ai_docs/prompt-anatomy.md` (the L1–L7
  reference the spec cites).

**Tests (`test/repo_builder/prompt_standard/`):**
- `test/repo_builder/prompt_standard/validator_test.exs` — H1–H9 negatives/positives, S1–S5,
  population auto-detect, the H6 Path-2 regression, the tightened H7 longest-prefix cases
  (Ports of Python tests 9–12, 20, 22–29 — the validator H/S checks).
- `test/repo_builder/prompt_standard/builder_test.exs` — Pop A/B assembly, level-≥7
  `## Expertise` ordering, `render/2` + injection invariant, unregistered-token rejection,
  `build_and_validate/2` ok/error (Ports of Python tests 1–8, 13–19, 21).
- `test/repo_builder/prompt_standard/taxonomy_test.exs` — `classify_heading/1` prefix
  cases (`## Workflow` vs `## Workflow Pattern`, shared headings, suffixed headings).
- `test/repo_builder/prompt_standard/frontmatter_test.exs` — present/absent/malformed split.
- `test/repo_builder/prompt_standard/cli_test.exs` — exit codes 0/1/2 for `validate` and
  `lint` by invoking the task modules' `run/1` and asserting `System.halt` via
  `ExUnit.CaptureIO`/capturing, plus a temp-dir clean directory (Ports of Python tests 30–32).

## Implementation Plan

### Phase 1: Foundation (types, registry, taxonomy, frontmatter)
Lay the typed domain primitives that the validator and builder both depend on. No behavior
yet — just the closed vocabulary the standard is built from. This phase is pure data + pure
functions, fully unit-testable in isolation.

- `Population` union + parse/detect.
- `TOKEN_REGISTRY` closed set.
- The A/B section taxonomy + `classify_heading/1` longest-prefix classifier (the trickiest
  pure logic in the whole feature — `## Workflow` is a literal prefix of `## Workflow
  Pattern`; shared headings `## Instructions`/`## Variables` classify as `:shared` and never
  fail).
- `Frontmatter.parse/1` distinguishing **absent** / **malformed** / **ok(map, body)**.
- `ValidationResult` typedstruct + `Inspect` (mirrors the Python `__str__` PASS/FAIL report).

### Phase 2: Core Implementation (validator + builder)
Port the two engines. The validator is the §7 gate; the builder consumes it.

- `Validator.validate/1,2,3`: auto-detect population, split frontmatter, run H1–H9
  (H10 skipped) + S1–S5, fold into one `ValidationResult`. Every check is a private
  `defp` returning `{errors, warnings}` deltas so the order in the source is preserved and
  each check is independently unit-testable. The H-check IDs in messages keep the
  `H1:` / `H10:` colon-prefix convention so the CLI's `_msgs_for`-equivalent prefix match
  is unambiguous (guard against the H1/H10 prefix collision — direct port).
- `Builder.build_population_a/1` and `build_population_b/1`: faithful port of the section
  assembly (frontmatter for A; frontmatter-FREE for B; level ≥ 7 inserts `## Expertise`
  before `## Workflow`). Inputs are typedstructs (`PopAInput`, `PopBInput`) — not loose
  keyword lists — to keep Dialyzer precise.
- `Builder.render/2`: `String.replace/3` over the closed registry; reject unregistered
  tokens with `{:error, {:unregistered_tokens, [String.t()]}}`; assert the injection
  invariant (`"{{" not in rendered and "}}" not in rendered`) and return
  `{:error, :injection_invariant_violated}` if it fails — **never raise** (typed standard
  rule 8).
- `Builder.build_and_validate/2`: build → validate → return
  `{:ok, prompt, %ValidationResult{}} | {:error, %ValidationResult{}}` (the Elixir shape of
  Python's "raise `PromptValidationError` carrying the result").

### Phase 3: Integration (CLI + spec docs + tests)
Expose the engines as mix tasks and port the spec + the test suite.

- Two `Mix.Tasks.RepoBuilder.PromptStandard.*` modules implementing `run/1` with the exact
  Python exit-code contract (`0`/`1`/`2` via `System.halt/1`). The `validate` task prints the
  per-check status table (H1–H9 PASS/FAIL, H10 SKIP with the deferred note, S1–S5 notes);
  the `lint` task prints one line per file + a `Summary:` line.
- Port `prompt-standard-spec.md` and `prompt-anatomy.md` into `ai_docs/`, marking the
  Elixir repo canonical.
- Port the 32 Python tests into the ExUnit files above (behavioral parity is the acceptance
  bar — see Acceptance Criteria).

---

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### Step 1 — Read the frozen reference + enforced standard end-to-end
- Read `/data/1.Projects/repo_builder/prompt_builder/{models,builder,validator,__main__}.py`
  and `/data/1.Projects/repo_builder/tests/test_prompt_builder.py` in full.
- Read `/data/1.Projects/repo_builder/ai_docs/prompt-standard-spec.md` (§1, §4, §5, §7 are
  load-bearing) and `prompt-anatomy.md`.
- Re-read `ai_docs/typed-elixir-standard.md` rules 1, 3, 5, 6, 8, 9 and
  `lib/repo_builder/definitions/slash_command.ex` as the structural template.

### Step 2 — Scaffold the context directory and the `Population` + `TOKEN_REGISTRY` types
- Create `lib/repo_builder/prompt_standard/population.ex`:
  `@type t :: :a | :b`, `from_string/1` (`"A"`/`"B"` → `:a`/`:b`, else
  `{:error, :unknown_population}`), `detect/1` (frontmatter-present → `:a`, else `:b`),
  `to_string/1`. `@spec` on every public fn.
- Create `lib/repo_builder/prompt_standard/token_registry.ex`: module attribute
  `@tokens MapSet.new(["{{SUBAGENT_MAP}}", "{{HARNESS_CATALOG}}"])`, `list/0`, `member?/1`.
- Create the empty context façade `lib/repo_builder/prompt_standard.ex` with `@moduledoc`
  and `alias`es; public functions are added as the engines land.

### Step 3 — Port the section taxonomy and the longest-prefix classifier
- Create `lib/repo_builder/prompt_standard/taxonomy.ex` with the verbatim heading sets:
  - `population_a_sections/0` → `["# Purpose", "## Variables", "## Instructions",
    "## Expertise", "## Workflow", "## Report"]`.
  - `population_b_sections/0` → `["## Core Operating Principle", "## Your Tools",
    "### Routing rules", "## Instructions", "## Variables", "## Guidelines",
    "## Context Window Management", "## Important Notes", "## ADW Workflows",
    "## Workflow Pattern", "## Agent Specialization Examples",
    "## Available Subagent Templates"]`.
  - Derived `a_only/0`, `b_only/0` (set differences), `all_sections/0` (union).
- Port `_classify_heading/1` exactly: collect every section `s` for which
  `String.starts_with?(heading, s)` (Python `heading.startswith(s)` — the SECTION is a
  prefix of the HEADING, not the reverse), pick the **longest**, classify as `:a` / `:b` /
  `:shared` / `nil`. `@spec
  classify_heading(String.t()) :: :a | :b | :shared | nil`.
- Write `test/repo_builder/prompt_standard/taxonomy_test.exs` covering: `## Workflow`→`:a`,
  `## Workflow Pattern`→`:b`, `## Instructions`→`:shared`, `## Your Tools`→`:b`,
  `## Core Operating Principle — ALWAYS DELEGATE`→`:b` (suffixed), `## Unknown`→`nil`.

### Step 4 — Port the frontmatter splitter
- Create `lib/repo_builder/prompt_standard/frontmatter.ex`:
  - `@frontmatter_re ~r/\A---\s*\n(.*?)\n---\s*\n/s` (anchored, DOTALL — direct port of the
    Python `^---\s*\n(.*?)\n---\s*\n` with `re.DOTALL`).
  - `present?/1` → boolean (regex match) — used for population detection and H1.
  - `parse/1` → `{:ok, %{String.t() => term()}, body} | :absent | {:error, :malformed}`:
    absent if no match; else `YamlElixir.read_from_string/2` → `{:ok, map}` keeps the
    string-keyed wire map (rule 6 — never atomize untrusted YAML keys); `{:ok, _non_map}` or
    `{:error, _}` → `{:error, :malformed}`. **Never raise** (rule 8).
  - `body/1` → the substring after the closing fence (absent → whole content).
- Write `test/repo_builder/prompt_standard/frontmatter_test.exs`: present+valid,
  absent (Pop B), malformed YAML (`description: [unclosed`), body extraction.

### Step 5 — Port `ValidationResult`
- Create `lib/repo_builder/prompt_standard/validation_result.ex` with `typedstruct
  enforce: true`: `passed: boolean()`, `errors: [String.t()]`, `warnings: [String.t()]`,
  `population: Population.t()`. Add a `new/2` helper that computes `passed` from `errors == []`.
- Implement `Inspect` producing the Python `__str__` report
  (`ValidationResult [PASS|FAIL] population=A` + `  ERROR: …` / `  WARN:  …` lines) so
  `iex` and test failures read like the Python tool.

### Step 6 — Port the regex helpers (`checks.ex`)
- Create `lib/repo_builder/prompt_standard/checks.ex` with the compiled module attributes:
  `@double_brace ~r/\{\{[A-Z_]+\}\}/`, `@single_brace ~r/\{[a-zA-Z_][a-zA-Z0-9_]*\}/`,
  `@heading ~r/^(#{1,3} .+)$/m`, plus `find_tokens/1`, `find_slots/1`, `headings/1`,
  `has_bom?/1` (`String.starts_with?(content, "\uFEFF")` — Python uses `content.startswith("\ufeff")`, so anchor at the start; `=~` is a looser "contains" match and is not byte-faithful), and `strip_double_brace/1` (for the H3
  "single-brace excluding `{{…}}`" computation — direct port).

### Step 7 — Port the Validator (H1–H9 + S1–S5)
- Create `lib/repo_builder/prompt_standard/validator.ex` with `validate(content,
  population \\ nil, rendered \\ nil)` and `validate_file(path, population \\ nil)`.
  `validate_file` reads via `File.read/1` (never `File.read!`).
- Implement each check as a private `defp h1(state, …)`, …, `h9(...)`, `s1(...)`, …, `s5(...)`,
  each returning `{[error], [warning]}` deltas folded into the accumulator in source order.
  Faithful, line-for-line port of the logic:
  - **H1** (Pop A: frontmatter present + valid YAML + `description`+`argument-hint` present;
    Pop B: frontmatter MUST be absent). Uses `Frontmatter.present?/1` + `Frontmatter.parse/1`.
  - **H2** (`# Purpose` heading present, Pop A only; `~r/^# Purpose\b/m`).
  - **H3** (no mixed `{{TOKEN}}` and `{slot}` — uses `strip_double_brace/1`).
  - **H4** (every `{{TOKEN}}` ∈ `TOKEN_REGISTRY`).
  - **H5** (injection invariant on `rendered` if given, else best-effort on content; message
    differs per branch — port both).
  - **H6** (Pop B + `has_single and not has_double`: collect slot names, smoke-render via
    `:io_lib.format`/`String.replace`-free `.format`-equivalent — see H6 note below).
  - **H7** (foreign-exclusive headings via `classify_heading/1`; shared never fails).
  - **H8** (no UTF-8 BOM).
  - **H9** (no unresolved `$ARGUMENTS` in rendered Pop A).
  - **H10** — **deliberately NOT implemented as a check**; it lives only as a `SKIP` row in
    the CLI table (Step 9) with the deferred note, exactly matching `__main__.py`.
  - **S1–S5** (purpose length, declared-vs-used slots, workflow ≥ 2 numbered steps, report
    presence/length, TODO/FIXME).
  - Keep the `Hx:` / `Sx:` **colon-prefix** on every message so the CLI's per-check bucketing
    is prefix-exact (ports the `_msgs_for` H1/H10-collision guard).
- **H6 note (the one genuine language gap):** Python uses `str.format(**slots)` as the
  render smoke-test. Elixir has no `str.format`. The faithful equivalent: attempt
  `:io_lib.format/2` is **not** semantically equivalent (different grammar). Instead, mirror
  the *intent* — a Path-2 template is valid iff it contains **only** its named `{slot}`
  tokens and **no stray** `{`/`}`. Implement H6 as: strip every declared `{slot}` occurrence,
  then assert the remainder contains neither `{` nor `}`. If it does → H6 FAIL with the same
  message intent ("stray or malformed braces"). Validate this against Python tests 22/23
  (must PASS) and 24 (stray `}` → FAIL) — they are the H6 regression contract. Document the
  equivalence in the validator's `@moduledoc` so reviewers see it is intentional.

### Step 8 — Port the Builder
- Create `lib/repo_builder/prompt_standard/builder.ex`:
  - Define typedstruct inputs `PopAInput` (fields: `name`, `purpose`, `variables`,
    `instructions`, `workflow`, `report`, `level`, `expertise`, `description`,
    `argument_hint`, `allowed_tools`, `model`) and `PopBInput` (`name`, `core_principle`,
    `tools`, `routing_rules`, `instructions`, `guidelines`). Required fields enforced,
    optionals `enforce: false`.
  - `build_population_a/1` → `String.t()` — frontmatter block (`description`,
    `argument-hint`, optional `allowed-tools`/`model`) + `# Purpose` + optional sections +
    level-≥7 `## Expertise` before `## Workflow` + default Workflow scaffold + optional
    Report. Join with `"\n\n"` + trailing `\n` (port the `"\n\n".join(parts) + "\n"`).
  - `build_population_b/1` → `String.t()` — **no** frontmatter; `# <name>` +
    `## Core Operating Principle` + optional Instructions/Your Tools(+`### Routing
    rules`)/Guidelines.
  - `render/2` → `{:ok, String.t()} | {:error, reason}` where `reason ::`
    `{:unregistered_tokens, [String.t()]} | :injection_invariant_violated`. Reject tokens
    not in `TOKEN_REGISTRY` before substituting; assert the invariant after.
  - `build_and_validate/2` → `{:ok, String.t(), ValidationResult.t()} |
    {:error, ValidationResult.t()}`.

### Step 9 — Port the CLI as mix tasks
- Create `lib/mix/tasks/repo_builder/prompt_standard/validate.ex` (module
  `Mix.Tasks.RepoBuilder.PromptStandard.Validate`, `@shortdoc`, `@moduledoc` with usage +
  exit codes, `@impl Mix.Task` `run/1`). Parse `argv`: first positional = file path;
  optional `--population A|B`. Not-a-file or missing arg → print to `:stderr` + `System.halt(2)`.
  Print the per-check table (H1–H9 PASS/FAIL with message bodies, H10 `SKIP` with the
  deferred note, S1–S5 notes) and `System.halt(0)` on pass / `System.halt(1)` on fail.
- Create `lib/mix/tasks/repo_builder/prompt_standard/lint.ex` (`…Lint`): recursive
  `Path.wildcard(dir <> "/**/*.md")`; one `PASS/FAIL  N errors  <rel>` line each; a
  `Summary: N files, N pass, N fail` line; exit `0`/`1`/`2` (no `.md` files → exit 2 with
  the Python "no .md files" message).
- Port the `_H10_SKIP_NOTE` and `_msgs_for`/`_body` helpers into a shared
  `lib/repo_builder/prompt_standard/cli_format.ex` used by both tasks (keeps the table
  rendering DRY and testable without spinning a task).

### Step 10 — Port the spec docs into `ai_docs/`
- Copy `/data/1.Projects/repo_builder/ai_docs/prompt-standard-spec.md` →
  `ai_docs/prompt-standard-spec.md`; prepend a header block: *"Canonical home:
  `repo_builder_elixir`. The copy at `/data/1.Projects/repo_builder/ai_docs/` is frozen
  reference (commit 6249331) and must not diverge."* Leave §1–§6 and §8 otherwise
  byte-identical (the spec is language-agnostic).
- **§7 doc/impl divergence (reconcile it in the ported header — do NOT silently inherit it):**
  the spec markdown's §7 is an *aspirational proposal* — HARD H1–H10 + SOFT S1–S7, with
  per-check semantics that the shipped `prompt_builder/validator.py` does **not** literally
  implement (e.g. spec H2 = "runtime prompts are front-matter-free", spec H8 =
  "file-missing fallback defined", spec H9 = "SQL audit row validity"). The Python validator
  instead implements a *different* H1–H9 + S1–S5 (see the Reference-vs-Context Correction
  above and Step 7): its H2 is "`# Purpose` heading present", its H8 is "no UTF-8 BOM", its
  H9 is "no `$ARGUMENTS` placeholder". **This port's behavioral truth is `validator.py`
  (the 32 tests assert it), NOT spec §7.** Add a one-paragraph note under the ported spec's
  header stating exactly this, so the doc and the shipped
  `RepoBuilder.PromptStandard.Validator` do not silently disagree. Rewriting spec §7 to
  match the implementation is out of scope here — list it as a follow-up.
- Copy `prompt-anatomy.md` → `ai_docs/prompt-anatomy.md` verbatim (it is pure reference).
- `prompt-builder-guide.md` (also added in commit 6249331) is intentionally **not** ported:
  it documents the Python call signatures; the Elixir API differs (`typedstruct` inputs,
  tagged-tuple returns), so porting it verbatim would mislead. Re-derive an Elixir API
  section later if desired.

### Step 11 — Write the test suite (behavioral parity with the 32 Python tests)
- `validator_test.exs`: ports Python tests 9–12, 20, 22–29 — H1 fail (Pop A no frontmatter; Pop B
  *with* frontmatter), H3 mixed, H4 unregistered, S5 TODO, H6 pass (canonical Path-2 +
  minimal) / H6 fail (stray brace), H7 tightened (A-with-B-heading fails, B-with-A-heading
  fails, clean A passes, clean B passes, shared + `## Workflow Pattern` legal in B). Plus
  H2/H8/H9 negatives and S1–S4.
- `builder_test.exs`: ports tests 1–8, 13–19, 21 — Pop A frontmatter +
  sections, Pop B frontmatter-free + sections, `render` replaces `{{SUBAGENT_MAP}}` /
  rejects unregistered, injection invariant (pass + raise-equivalent error), level-7
  Expertise-before-Workflow ordering, `build_and_validate` ok + error carrying the result,
  TOKEN_REGISTRY contents, both-tokens render.
- `taxonomy_test.exs`, `frontmatter_test.exs` (from Steps 3–4).
- `cli_test.exs`: ports tests 30–32 — `validate` good file → exit 0 + `Overall: PASS`;
  `validate` bad file → exit 1 + `Overall: FAIL`; `lint` clean dir → exit 0 + `Summary: …
  N pass, 0 fail`. Assert exit codes by capturing `System.halt` (use
  `ExUnit.Assertions` + a captured process, or assert on the task's printed output and the
  halt arg via `ExUnit.CaptureIO` wrapping a `try/catch` on `:erlang.halt/1`-equivalent —
  see Testing Strategy note).

### Step 12 — Run the full validation gate (last step)
- Run every command in **Validation Commands** below, top to bottom, and fix until green.

---

## Testing Strategy

### Unit Tests
- One test file per module (`taxonomy`, `frontmatter`, `validation_result`, `validator`,
  `builder`, `cli`). Each H-check and S-check has at least one **negative** (fails the
  check) and one **positive** (passes the check) case, mirroring the Python suite's
  structure so behavioral parity is auditable test-by-test.
- Roundtrip tests: every `build_population_a/b` output must `Validator.validate/1` to
  `passed: true` (ports the two Python roundtrip tests — these are the strongest
  end-to-end guarantees).
- The injection invariant (`"{{" not in rendered and "}}" not in rendered`) is asserted
  verbatim in every `render/2` test (it is the spec's single machine-checked rule, §5a).

### Edge Cases
- H6 `.format`-equivalence: the canonical Path-2 prompt (two named slots) MUST pass; a stray
  unmatched `}` MUST fail — these two are the H6 regression contract (Python tests 22–24).
- H7 longest-prefix: `## Workflow` (A) vs `## Workflow Pattern` (B) must NOT collide; shared
  `## Instructions`/`## Variables` must never fail in either population (Python tests 25–29).
- Population auto-detect: frontmatter-present → `:a`; absent → `:b`; `--population` override.
- Malformed YAML frontmatter is `{:error, :malformed}` (H1 fail), distinct from absent.
- BOM (`\uFEFF`) detection (H8).
- `render/2` with two tokens in one pass; `render/2` with one unregistered token.
- CLI: missing file → exit 2; empty dir (no `.md`) → exit 2; mixed pass/fail dir → exit 1.
- Validator never raises on adversarial input (garbage bytes, huge file, binary in YAML).

### CLI exit-code testing note
`Mix.Task.run/2` calls `System.halt/1` on non-zero exit. In ExUnit, assert exit codes by
running the task inside a child process (`Task.async`/`System.cmd` of `mix …`) OR by
refactoring the decision (`pass?/1`, `exit_code/1`) into a pure function and testing that
directly, with one integration test per task that captures the printed table via
`ExUnit.CaptureIO`. Prefer the pure-function split so most CLI tests need no process spawn.

## Acceptance Criteria
1. `RepoBuilder.PromptStandard.Validator.validate/2` reproduces the §7 H1–H9 + S1–S5
   behavior of `prompt_builder/validator.py` byte-for-byte in spirit; every one of the 32
   Python tests has a passing Elixir counterpart.
2. `RepoBuilder.PromptStandard.Builder` produces Population A/B prompts that **round-trip**
   through the validator to `passed: true`; `render/2` enforces the closed `TOKEN_REGISTRY`
   and the injection invariant, returning tagged tuples (never raising).
3. `mix repo_builder.prompt_standard.validate <file>` exits `0`/`1`/`2` and prints the
   per-check table (H1–H9 PASS/FAIL, H10 SKIP with the deferred note, S1–S5 notes);
   `mix repo_builder.prompt_standard.lint <dir>` exits `0`/`1`/`2` and prints the per-file +
   `Summary:` lines — matching the Python `python -m prompt_builder {validate,lint}`
   contract.
4. The feature lives under `RepoBuilder.PromptStandard` and does **not** touch, rename, or
   collide with the existing `RepoBuilder.Prompts` (DB-template) context; it adds no Ecto
   schema, no migration, and no new dependency.
5. `ai_docs/prompt-standard-spec.md` and `ai_docs/prompt-anatomy.md` exist, with the Elixir
   repo declared canonical and the Python copy frozen.
6. The full gate is green: `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`,
   `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` (no new
   `.dialyzer_ignore.exs` entries), and `mix precommit`.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/prompt_standard/` — the new feature suite (validator, builder,
  taxonomy, frontmatter, cli).
- `mix test test/repo_builder/prompt_standard/validator_test.exs` — the H/S checks in isolation.
- `mix test test/repo_builder/prompt_standard/builder_test.exs` — assembly + render + roundtrips.
- `mix test test/repo_builder/prompt_standard/cli_test.exs` — exit codes 0/1/2.
- Manual smoke (proof of CLI parity): create a temp Pop-B prompt with `{{BAD_TOKEN}}` and run
  `mix repo_builder.prompt_standard.validate /tmp/bad.md --population B` → expect `Overall:
  FAIL`, an `H4` row, and shell exit code `1` (`echo $?`).
- Manual smoke: run `mix repo_builder.prompt_standard.lint ai_docs` → expect a `Summary:`
  line and exit `0` (the ported spec/anatomy docs are valid markdown; the linter auto-detects
  them as Population B and they carry no `{{TOKEN}}`/`{slot}`, so they pass).
- Runtime cross-check via Tidewave (`http://localhost:4000/tidewave/mcp`, dev only):
  `project_eval` —
  `RepoBuilder.PromptStandard.validate("# X\n\n## Core Operating Principle\n\nDo good.\n")`
  → assert `passed: true`, `population: :b`.
- `mix compile --warnings-as-errors` — compile clean; the gradual set-theoretic type checker
  and `warnings_as_errors` must pass.
- `mix test --warnings-as-errors` — full ExUnit suite with zero failures.
- `mix format --check-formatted` — formatting.
- `mix credo --strict` — lint, including `Credo.Check.Readability.Specs` (the `@spec` gate).
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.
- `mix precommit` — the repo's consolidated gate (`compile --warnings-as-errors`,
  `deps.unlock --unused`, `format`, `test`).

## Notes

- **No UI.** This feature is a typed library + CLI; it has no LiveView surface, so no
  `test/repo_builder_web/live/…` test and no Playwright screenshot are required (the
  `/feature` UI-test guidance does not apply). The dashboard is untouched.
- **No DB / no migration / no HTTP / no new deps.** Only `yaml_elixir` (present + in
  `plt_add_apps`) and `typedstruct` (present, `runtime: false`) are used. `req` is not
  needed. Do **not** add a dependency.
- **H10 stays deferred**, exactly as in the Python source: it is a `SKIP` row in the CLI
  table with the `managed_agent_system_prompt_template.md` note, never a real check. This is
  faithful port behavior, not an oversight — see `__main__.py` `_H10_SKIP_NOTE` and the
  validator docstring.
- **Exception → tagged tuple.** Python's `PromptValidationError` (an exception carrying the
  `ValidationResult`) becomes `{:error, %ValidationResult{}}` in Elixir (typed standard rule
  8 + the "tagged results, not exceptions" pattern). `render/2` likewise returns
  `{:error, reason}` instead of raising `ValueError`.
- **Frontmatter boundary.** YAML frontmatter is the wire boundary (rule 6): keep it
  string-keyed (as `YamlElixir` returns), never `String.to_atom/1` the keys, never feed raw
  YAML into a domain struct.
- **H6 `.format` gap is documented.** Elixir has no `str.format`; H6 is implemented as
  "strip declared `{slot}`s, then assert no stray `{`/`}`" — semantically equivalent to the
  Python render smoke-test for the cases the spec cares about (Python tests 22–24 are the
  contract). The equivalence is called out in the validator `@moduledoc`.
- **Spec §7 ≠ the shipped validator.** The ported `ai_docs/prompt-standard-spec.md` §7
  describes an aspirational H1–H10 + S1–S7; the Python (and thus Elixir) validator
  implements H1–H9 + S1–S5 with different per-check semantics. Behavioral truth = the
  validator (asserted by the 32 tests), reconciled in the ported spec header — see Step 10.
- **Suite is 32 tests, not 23.** Earlier drafts cited "23"; the `def test_` count is 32 and
  the commit-6249331 message confirms "32 passing". Step-11 cross-references are recomputed
  from the actual test order (builder: 1–8, 13–19, 21; validator: 9–12, 20, 22–29; cli:
  30–32).
- **Python repo stays frozen.** Do not edit `/data/1.Projects/repo_builder/`. The Elixir
  port is the canonical home going forward; the Python `prompt_builder/` package is
  read-only reference at commit `6249331`.
- **Future (out of scope):** wiring `build_and_validate/2` into the orchestrator's
  `_load_system_prompt`-equivalent as a boot-time gate, and re-enabling H10 once a managed
  template ships. Both are listed in the spec's §8 open questions and are deliberately
  deferred by this port.
