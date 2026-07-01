---
name: quality-gate-foundations
description: The five-stage green gate discipline for Python — format, lint (strict/no-warnings), static types (the cheapest verifier), test, and mutation/property testing. Use when writing or fixing Python code so every phase passes a binary red/green "am I done?" oracle, and to understand why mutation testing catches the vacuous tests a line-coverage gate rewards. Mutation/property stages are pre-merge (run at workstream close), not per edit.
---

# Quality Gate Foundations — Python

The quality gate is your **single "am I done?" oracle**: one ordered sequence of commands,
each with a binary pass/fail exit code. A phase only advances once every per-phase stage is
green. These five properties are why the gate is a *feedback loop*, not just a command list.

## The five transferable properties

1. **One command, one exit code.** Each stage is a single wrapper the worker can run and read
   a red/green from. Don't eyeball output — trust the exit code.
2. **No-warnings tier.** `--warnings-as-errors` everywhere. A permitted warning is a warning
   that ships. This is the single most important trait for LLM-written code.
3. **Static types are the cheapest verifier.** The type stage catches hallucinated APIs and
   contract drift *without executing anything*. In spec-driven work, type signatures **are**
   machine-checkable spec fragments — maximize them (strict config, annotated signatures).
4. **Deterministic, parseable output.** `file:line:rule` diagnostics let you locate and
   self-correct. A flaky red teaches nothing.
5. **Fast.** The loop runs dozens of times per task. Sub-second checks change what you can
   afford to run per edit.

## The five stages (Python)

| Stage | Command | Strict? | Cadence |
|-------|---------|---------|---------|
| format | `ruff format --check` | yes | per phase |
| lint | `ruff check` | yes | per phase |
| type | `pyright --strict / mypy --strict` | yes | per phase |
| test | `pytest` | yes | per phase |
| mutation | `mutmut` | advisory | **pre-merge (close)** |

## Why mutation testing (the "coverage lies" layer)

Models are exceptionally good at tests that **pass and hit coverage while asserting nothing** —
the vacuous-test failure mode a line-coverage gate actively *rewards*. Mutation testing is the
antidote: it perturbs the code and requires some test to fail; if none does, the test was
theater. It is slow (it re-runs the suite per mutant), so it runs at **`pre_merge` cadence
(workstream close)**, not per edit.

## Property-based testing

Property tests (**Hypothesis**) are the other spec-encoding lever: assert invariants drawn
straight from the spec, which is far harder to trivially satisfy than example-based tests.
Reach for them where the spec states a general law, not just a single example. Like mutation,
run deeper property sweeps at **pre-merge/nightly** cadence.
