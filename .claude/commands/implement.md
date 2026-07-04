---
command: implement
version: 1.0.0
description: Implement a plan/spec produced by /feature, then make the validation gate pass
argument-hint: [path-to-plan]
allowed-tools: Read, Write, Edit, Bash
---

# Implement

Follow the `Workflow` to implement the `PATH_TO_PLAN` into the codebase, then `Report`
the completed work. This is the load-bearing build step of the ADW pipeline — leave the
repo compiling, formatted, and green.

## Variables

PATH_TO_PLAN: $ARGUMENTS

## Workflow

- If no `PATH_TO_PLAN` is provided, STOP immediately and report the error.
- Read the plan at `PATH_TO_PLAN`. Think hard, then implement every step of its
  `Step by Step Tasks` into the codebase, following the plan's `Acceptance Criteria`.

### HTML plans (planf3 format)

- When `PATH_TO_PLAN` ends in `.html`, the plan is a planf3 document (authored by
  `/planf3`; execution semantics in `ai_docs/planf3/build-plan.md`). Its structure:
  `<section id="phases">` holds ordered `.phase` blocks, each with `<h4>` tasks and
  `<ul class="checklist">` items; `<section id="validation">` holds the global gate.
- Execute phases strictly top to bottom. Honour each phase's Testing Strategy 🔁 loop —
  do not start the next phase until the current phase's checks pass.
- Status-marker protocol — the plan file is the live progress ledger. Before starting a
  phase/task, Edit its `<code class="status">[]</code>` to `[wip]`; on completion `[x]`;
  if a step is impossible, `[f]` plus a one-line reason appended to the plan's
  `<section id="amendments">`.
- The plan's global Validation Commands section replaces the markdown plan's
  `Validation Commands` — run it in full, checking boxes as commands pass.
- This is an **Elixir/Phoenix/OTP** app. Honor the typed style guide in `BUILD_PROMPT.md`
  §3: an `@spec` on every public function (`@impl true` callbacks are exempt),
  `@type`/`typedstruct`/`@enforce_keys` for domain data, precise types over
  `any()`/`map()`, `{:ok, t()} | {:error, reason()}` over raising. Keep DB access behind
  `@spec`'d context modules — LiveViews/controllers/OTP processes never touch
  `Repo`/`Ecto.Query` directly (§8).
- Follow existing patterns and conventions; reuse the existing components/contexts. Don't
  reinvent the wheel. Read `AGENTS.md`, `README.md`, and `BUILD_PROMPT.md` as needed.

### Worktree setup (this may be a fresh isolated worktree)

- Toolchain is mise-pinned (Erlang/Elixir/Postgres). If `mix` can't resolve deps or
  `deps/` is absent, set the worktree up before compiling, in order:
  `mix deps.get` → `mix compile` (the `deps.get` alias auto-patches `type_check` for
  Elixir 1.20 — no manual step).
- Postgres for the test step is a separate running cluster on `localhost:5432`
  (postgres/trust); `mix test` will create the test DB. Do NOT start/stop the cluster.

## Validation

Run the plan's `Validation Commands`. At minimum these must pass before you finish:

- `mix compile --warnings-as-errors`
- `mix format` (then `mix format --check-formatted`)
- `mix credo --strict`
- `mix test --warnings-as-errors`

`mix dialyzer` is best-effort in a fresh worktree (PLT build is slow) — run it if time
allows and fix any new warnings; never delete or weaken existing ignore filters.

Fix every failure you introduce. Do NOT leave the build red, do NOT commit (the workflow
commits separately), and do NOT push.

## Report

- Summarize the work in a concise bullet list.
- Report files and total lines changed with `git diff --stat`.
- State the final status of each validation command you ran.
