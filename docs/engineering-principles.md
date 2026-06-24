# What's Working — A Reflection on Typed, Functional, Gate-Enforced Development

> A human-facing reflection (not a spec). It abstracts *why* development in this
> repo feels better than past experience, into principles that transfer to other
> projects, languages, and teams. Grounded in this codebase's actual practice:
> the typed-Elixir standard (`ai_docs/typed-elixir-standard.md`), the five-command
> green gate (`.github/workflows/ci.yml`, `.credo.exs`), and the architecture in
> `BUILD_PROMPT.md`.

---

## The one-sentence thesis

**The experience is better because correctness is enforced mechanically, early, and
in layers — so the machine, not your memory or a reviewer's mood, holds the line —
and because functional code, precise types, and fast tests each make the *other two*
more powerful instead of merely coexisting.**

The three things you named — typed enforcement, functional programming, testing
gates — are not three separate wins. They are one system. Pull any one out and the
other two get weaker. The rest of this document unpacks why.

---

## Part 1 — The generalizable principles

Each principle below is stated abstractly first, then shown as it appears here, then
pointed at where else it transfers.

### 1. Defense in depth: stack independent checks that overlap little

**The idea.** No single check catches every class of error, so you layer checks that
fail on *different* things. A bug has to slip past all of them, and they are chosen
precisely so that's unlikely.

**Here.** The standard is explicit that it stacks **four** layers because "no single
layer is sufficient":

| Layer | Catches |
|---|---|
| Set-theoretic compiler (`mix compile`) | bad guards, impossible clauses, proven-absent map keys |
| `@spec` + Dialyzer | declared contract disagreeing with reality |
| `typedstruct` + `@enforce_keys` | struct shape drift, missing required fields at runtime |
| `TypeCheck` / Ecto changesets at boundaries | untrusted external data before it becomes a domain value |

The doc hammers the load-bearing point: *"`mix compile` is not equivalent to running
Dialyzer."* They overlap little, so you run both.

**Transfers to.** Any stack: a linter + a type checker + a test suite + a runtime
schema validator are four cheese slices with holes in different places (the "Swiss
cheese model"). The lesson isn't "use these specific tools" — it's *don't rely on
one gate to catch everything, and deliberately pick gates whose blind spots differ.*

### 2. Shift the cost left: catch errors at the cheapest possible moment

**The idea.** The same bug costs almost nothing at compile time, a little at test
time, more in code review, a lot in production. Push every check as far left as the
tooling allows.

**Here.** `warnings_as_errors: true` turns a soft warning into a hard compile stop.
Types catch shape errors before a test even runs. The boundary validators reject bad
data at the edge instead of letting it corrupt state three layers deep. CI runs the
*exact same* five commands you run locally, so "works on my machine" can't drift from
"passes the gate."

**Transfers to.** Pre-commit hooks, fail-fast CI ordering (this repo's CI is
deliberately ordered `compile → format → credo → test → dialyzer` so the cheapest
check fails first), and "make the error impossible to commit" over "remember not to
do it."

### 3. Make illegal states unrepresentable, instead of checking for them

**The idea.** The strongest validation is the one you never have to write because the
wrong value can't be constructed. Constrain the domain in the type so bad code doesn't
compile.

**Here.**
- Closed sum types: `Harness.Event` is a closed 8-variant union, so the compiler and
  Dialyzer can reason about *exhaustiveness* — a missing `handle_info` clause is
  visible, not a latent runtime crash.
- `@enforce_keys` on every struct: you cannot build a half-initialized struct.
- `Ecto.Enum` for closed domains (`:idle | :running | :error`) so an out-of-domain
  status can't round-trip through the database.

**Transfers to.** Sum types / discriminated unions / sealed classes in any language;
non-nullable-by-default fields; "parse, don't validate." Replacing a runtime `if`
with a type the compiler enforces is almost always a net win.

### 4. Establish a trusted core behind a validated boundary (wire ≠ domain)

**The idea.** Untrusted data (JSON, webhooks, user input) is messy and stringly-typed.
Validate and *normalize* it once, at the edge, into a precise internal shape. After
that boundary, the entire interior gets to assume everything is well-formed — no
defensive re-checking, no "what if this is nil" scattered everywhere.

**Here.** This is rule 6 and arguably the highest-leverage rule in the codebase. Every
harness's raw JSONL is decoded with `Jason.decode/1` (never `decode!`), validated
against a permissive *wire* type, then normalized into the strict canonical
`Event` struct. JSONB is modeled string-keyed; untrusted keys are never atomized.
The orchestrator, persistence, and UI are all "harness-blind" — they only ever see
the trusted domain type.

**Transfers to.** Every system with an outside edge. The discipline — *one*
normalization layer, a hard line between "raw external" and "trusted internal" —
is language-independent and is what makes the rest of the codebase calm.

### 5. Errors are data, not control flow (tagged results over exceptions)

**The idea.** When failure is a returned value (`{:ok, t} | {:error, reason}`), the
type signature enumerates *every* way a call can fail, the caller is forced to handle
it, and decoders can't take down a stream on one bad line.

**Here.** Rule 8: decoder boundaries return `{:ok, t} | :skip | {:error, reason}` and
*never raise*. `reason()` types are named, so the failure modes are part of the
documented contract (`:unknown_harness | :at_capacity | :spawn_failed`).

**Transfers to.** Result/Either/Option types, checked error enums, "make the unhappy
path explicit." Even in exception-based languages, returning structured results at
key seams beats throwing and hoping someone catches.

### 6. One seam, one source of truth — and one place to swap implementations

**The idea.** When a concern has exactly one entry point, that point becomes both the
place you enforce invariants *and* the place you inject test doubles or new behavior.
Centralizing the seam is what makes a system simultaneously safe and changeable.

**Here.**
- **Contexts are the only `Repo` callers** (rule 10). DB invariants are enforced in
  one layer; LiveViews and GenServers can't smuggle a raw query past validation.
- **The harness registry is the single injection seam.** Tests swap a real adapter
  for `Fake`/`Mock` by overriding *one config map entry* — and that's also exactly
  how a third harness is added in production (one module + one config line, zero core
  edits). The test seam and the extension seam are the *same* seam.

**Transfers to.** Dependency-injection points, repository patterns, ports-and-adapters
/ hexagonal architecture. The tell that you've found the right seam: *adding a feature
and mocking it for tests use the same door.*

### 7. The gate is binary, mechanical, and identical everywhere

**The idea.** A check that requires human judgment invites debate and erodes under
deadline pressure. A check that is a pass/fail command does not. Make "is this
correct enough to merge?" a question the machine answers the same way every time.

**Here.** The green gate is five commands, each pass/fail:

```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict          # includes the @spec-on-every-public-fn gate
mix test --warnings-as-errors
mix dialyzer
```

Even normally-subjective concerns are mechanized: "every public function has an
`@spec`" is not a code-review nag, it's `Credo.Check.Readability.Specs` failing the
build. Formatting isn't a style argument, it's `mix format --check-formatted`. This
removes a whole category of review friction and bikeshedding.

**Transfers to.** Any project. The principle: *convert as many "should" rules into
"the build fails" rules as you can.* What's left for human review is then genuinely
about design and intent, not whitespace and missing annotations.

### 8. Discipline needs exactly one documented exception, not zero

**The idea.** A standard with zero exceptions is brittle and gets quietly violated; a
standard whose *one* deliberate looseness is named and justified is trustworthy,
because everyone knows the rule is real everywhere else.

**Here.** The harness identity is intentionally an open `atom()` / `String.t()` — not
a closed `:claude | :pi` union — *specifically so adding a harness needs no core type
edit.* The standard calls this out as "the one deliberate exception" and documents the
trade-off (Dialyzer can't narrow on the harness value, accepted in exchange for true
zero-core-change extensibility). Everywhere else: precise types, no `any()`/`map()`.

**Transfers to.** Every coding standard. Write down the exception and *why*, so it
reads as a considered decision rather than a crack in the wall.

### 9. The standard is a living, owned document — separate from its frozen origin

**The idea.** Rules that live only in people's heads decay. Rules in a versioned doc
that the team edits, with a clear "this file wins" precedence, stay alive.

**Here.** `ai_docs/typed-elixir-standard.md` is explicitly the *living* standard;
`BUILD_PROMPT.md` §3 is the *frozen origin*, "treated as historical context" when the
two disagree. There's a pre-commit checklist and an explicit anti-patterns list
("reject in review").

**Transfers to.** Any team convention. Separate the immutable origin/decision-record
from the editable working standard, and make precedence explicit.

### 10. Functional purity is the substrate that makes 1–9 possible

**The idea.** Pure functions and immutable data aren't a separate "nice to have" —
they're *why* the type checker is powerful, *why* tests are trivial, and *why*
boundaries hold.

**Here, the synergy is the whole point:**
- **Pure normalize functions** (`normalize(raw, ctx) -> {:ok, [event]} | :skip`) are
  input→output with no hidden state, so a property/boundary test is just "feed it
  malformed/partial/multibyte/unknown lines, assert it never raises." No mocks, no
  setup, no teardown. The architecture is *why* there are 187 test files that run
  `async: true` with no external CLIs.
- **Immutability + no side effects** means the set-theoretic compiler has nothing to
  hide behind — it can reason about every value's shape. A type checker over mutable,
  effectful code is far weaker.
- **Pattern matching + closed sum types** turn "did I handle every case?" into a
  compile-time question.
- **OTP "let it crash" + supervision** makes failure *contained* rather than
  catastrophic — one agent or one workflow step failing affects only itself. Safe
  failure is what lets you be aggressive about everything else.

**Transfers to.** Even in non-functional languages: prefer pure functions at the core,
push side effects to the edges, favor immutable data. Every step toward purity makes
your types and tests do more work for free.

---

## Part 2 — Why the three pillars reinforce each other

The reason this feels qualitatively better — not just "stricter" — is the **positive
feedback loop** between the three things you named:

```
        precise types
        ╱            ╲
   make tests      make the compiler
   smaller &       catch more, so the
   more focused    gate is meaningful
        ╲            ╱
     functional purity
   (pure fns + immutability
    + closed sum types)
        │
   makes BOTH of the above
   dramatically more powerful
        │
   fast hermetic test gate
        │
   gives confidence to refactor,
   which keeps types & purity honest
```

- **Types make tests smaller.** You don't write tests for cases the compiler already
  rules out. Tests focus on *behavior*, not shape-checking.
- **Purity makes types stronger.** No hidden mutation means the compiler sees the real
  data flow.
- **The fast gate makes the types worth having.** Because the five commands run on
  every change locally and in CI, a type violation is caught in seconds, not in a
  review three days later. A type system you only check occasionally is barely a type
  system.
- **The gate gives you permission to refactor.** This is the felt difference. When the
  gate is comprehensive, changing code is *safe* — break something and the build tells
  you immediately and precisely. That confidence is the thing that makes day-to-day
  work pleasant.

Remove typing → tests balloon to cover shape bugs and the compiler goes quiet.
Remove purity → types and tests both weaken against hidden state. Remove the gate →
the other two rot because nothing forces them. **The win is the loop, not any vertex.**

---

## Part 3 — What it costs, and why it pays back

Honesty about the trade: this discipline has a real **up-front cost**. Writing
`@spec`s, modeling wire types separately from domain types, building the PLT, keeping
Dialyzer green — it's slower to write the *first* version of a function.

It pays back because:

- **The cost is front-loaded and one-time; the benefit is continuous.** You pay when
  you write; you collect every time you read, change, or trust that code later.
- **Caught-early is exponentially cheaper.** A compile error costs a keystroke; the
  same logic bug in production costs an incident.
- **Cognitive load drops.** Past the validated boundary you *stop re-checking* — the
  types already promised the data is well-formed. You hold less in your head.
- **Onboarding (human or AI agent) is faster.** The rules are explicit and
  machine-checked, so a newcomer gets instant, precise feedback instead of absorbing
  tribal knowledge by osmosis or silently drifting. (This is part of why an AI agent
  produces good code here: the gate is a tight, fast feedback loop it can actually
  use.)
- **Review is about design, not janitorial nits.** The machine already handled specs,
  formatting, and shape; humans spend their attention on intent.

The mental reframe: the gate is not a *wall slowing you down*. It's a *handrail that
lets you move fast without looking down.*

---

## Part 4 — Carrying this to a project that isn't Elixir

If you want this experience elsewhere, port the *principles*, not the tools:

1. **Pick gates with non-overlapping blind spots** (formatter + linter + type checker +
   test runner + runtime schema validator) and run them as one command.
2. **Make the gate binary and identical locally and in CI.** One script. No judgment
   calls in it.
3. **Turn "should" rules into build failures** (lint rules, required annotations,
   coverage floors) so they survive deadline pressure.
4. **Draw one hard boundary** between untrusted external data and your trusted domain;
   validate/normalize once at that edge.
5. **Make illegal states unrepresentable** with the strongest types your language
   offers (sum types, non-null defaults, enums, newtypes).
6. **Return errors as values** at important seams; reserve exceptions for truly
   exceptional.
7. **Find the single seam** for each external concern (DB, network, subprocess) so the
   same door serves both injection and testing.
8. **Push side effects to the edges; keep the core pure** — it's what makes types and
   tests earn their keep.
9. **Write the standard down as a living doc** with a checklist and an anti-pattern
   list, and document the *one* exception you allow.

---

## The shortest version

> Enforce correctness **mechanically** (the machine holds the line), **early** (the
> cheapest moment), and **in layers** (no single gate catches everything). Keep the
> core **pure** and put a **hard validated boundary** at every edge. Then types,
> tests, and functional style stop being three chores and become one reinforcing loop
> — and changing code becomes *safe*, which is the whole feeling of "this is better."
