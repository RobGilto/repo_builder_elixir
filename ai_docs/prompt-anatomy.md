# Prompt Anatomy Reference

> Source of truth: TAC lesson 09 — *Seven Levels of Agentic Prompt Formats*
> (`/data/3.Resources/engineering/TAC Repos/transcripts/lesson_09_seven-levels-agentic-prompt-formats.md`).
> Two orthogonal ideas live here: **sections** (interchangeable Lego blocks a prompt is built from)
> and **levels** (a cumulative ladder of capabilities). Don't confuse them.

A production-grade agentic command prompt is assembled from **interchangeable sections** — *"swappable Lego blocks, each with distinct uses and capabilities."* The common blocks: **Metadata** (frontmatter: description, allowed-tools, model, argument-hint), **Purpose/Title** (what this prompt is for), **Variables** (map `$ARGUMENTS` to named slots so it's reusable), **Workflow** (the ordered step list — the single most valuable section), **Expertise** (domain know-how the agent needs — patterns, standards, decision trees; becomes the *living* layer at level 7), **Examples** (show the desired output/result), **Relevant Files** (point the agent at key files), and **Report** (the exact output format). Separating expertise (*what the agent knows*) from workflow (*what the agent does*) is the critical insight — conflating them produces bloated, brittle prompts.

## Full anatomy (reference)

```markdown
---                                              # optional
description: One-line purpose shown in command picker
argument-hint: <what to pass as $ARGUMENTS>
allowed-tools: Read, Write, Bash(ls*)
model: claude-opus-4-8   # optional — pin only when reasoning depth justifies it
---

# Purpose                                        # REQUIRED
One-sentence purpose statement.

## Variables                                     # optional — dynamic first, static after
USER_REQUEST: $1                                 # prefer $1/$2 over $ARGUMENTS for distinct inputs
FILE_EXTENSIONS: $2 or '*.py'                    # static default reads inline
OUTPUT_DIR: `specs/`                             # static constant

## Instructions                                  # optional — constraints & guidance bullets
- IMPORTANT: if no USER_REQUEST is provided, stop and ask the user for it.
- Constraints, IMPORTANT flags, bans, and best practices live here —
  Instructions = how to behave; Workflow = what to do, in order.

## Expertise                                     # optional but high-leverage
### Decision Tree
- Simple validation → exit codes
- Complex control flow → JSON output

## Workflow                                      # the core section
1. Read prerequisite files to load context
2. Execute core logic (tool calls)
3. Validate output against acceptance criteria

## Report                                        # pin the EXACT output format (near-universal in the mature corpus)
- **What was done**: ...
- **Next step**: ...
```

> Corpus note (tac-13/14, 2026-06): the mature reference commands converge on
> `Purpose → Variables → Instructions → Workflow → Report`. **Instructions**
> (constraint/guidance bullets) is kept distinct from **Workflow** (the numbered
> step sequence); `## Report` appears in nearly every command and often carries a
> fenced template the agent must fill verbatim. Expertise remains this factory's
> extension for L7 living prompts — Instructions and Expertise coexist: Instructions
> hold per-prompt constraints, Expertise holds accumulated domain know-how.

## The 7 levels (capability ladder)

The seven levels are a **cumulative ladder** — each level adds exactly one capability on top of the previous one. *"Every prompt format is about the capability it offers your agent."* Start at the lowest level that does the job; climb only when you hit repeat work (rule of three) or need a new capability. **Levels 1–4 cover 80–90% of real prompts — usually L3–L4 is all you need.** The high levels (5–7) are "meta territory": prompts that build and improve prompts.

| Level | Name | Capability it adds | Tier: use / skill |
|---|---|---|---|
| **L1** | High-level / ad-hoc | Purpose only — say what you want | B / D |
| **L2** | Workflow | a sequential step list | **S** / C |
| **L3** | Control flow | conditions, loops, early returns/STOP | — |
| **L4** | Delegation | spawn sub-agents (parallel), pass them variables | — |
| **L5** | Higher-order | pass prompts/plans *into* prompts | B / A |
| **L6** | Template meta | a prompt that *builds another prompt* | **S** / **S** |
| **L7** | Self-improving (expert) | a prompt that *updates its own/others' expertise* | A / **S** |

### Level 1 — high-level / ad-hoc

Just a Purpose: say what you want. No variables, no workflow.

```markdown
# Purpose
Start the agentic prompt tier-list app for development.
```

**Marker:** no sections beyond Purpose. *"A great place to start, a terrible place to end."* When you repeat the work three times, hand it to an agent and move up a level.

### Level 2 — workflow

Adds the ordered `## Workflow` step list. **The single most important section — most of your value comes from here.**

```markdown
# Build
Follow the Workflow to implement the PATH_TO_PLAN, then Report the work.

## Variables
PATH_TO_PLAN: $ARGUMENTS

## Workflow
- Read the plan at PATH_TO_PLAN. Think hard and implement it into the codebase.

## Report
- Summarize the work. Report files changed with `git diff --stat`.
```

**Marker:** numbered/sequential steps. ("Think hard" is an inference-budget signal, not filler.)

### Level 3 — control flow

Adds **conditions, loops, and early returns** inside the Workflow. This is the *control flow prompt*.

```markdown
## Workflow
1. IMPORTANT: If no PATH_TO_PLAN is provided → immediately STOP and ask the user for it.
2. Read the plan and implement it.
```

**Marker:** `if/else`, `for each`, `STOP`/early-return. See **Control flow patterns** below for the four primitives. The STOP guard before an expensive or irreversible step is the canonical L3 move.

### Level 4 — delegation

The prompt kicks off **other agents** to do the work. Adds the `Task` tool (parallel or sequential) and variables passed *into* the sub-agents.

```markdown
## Workflow
3. For each URL not skipped, use the Task tool in parallel with this exact prompt:
   <scrape_loop_prompt>
   Use @agent-docs-scraper — pass it the url as the prompt
   </scrape_loop_prompt>
4. After all Tasks complete, respond in the Report Format.   # join step
```

**Marker:** `Task` in allowed-tools; "for each X, use Task in parallel"; an explicit join step.

### Level 5 — higher-order

Passes **prompts/plans into prompts** — a stable top-level shell with a swappable inner payload. The shell stays constant; the work (a plan, a sub-prompt) is passed in as a variable.

```markdown
## Variables
PATH_TO_PLAN: $ARGUMENTS   # the plan was itself produced by a planner prompt

## Workflow
1. Read the plan at PATH_TO_PLAN and execute it.
```

**Marker:** a variable that is itself a prompt/plan path. "Providing a consistent structure so your lower-level prompt can be changed and operated on."

### Level 6 — template meta

A prompt whose **output is another prompt** in a fixed format. *"The prompt that builds the prompt."* This is the peak of prompt engineering — templating your engineering scales velocity for you, your team, and your agents.

```markdown
# Build Prompt
Interview the user, then write an agentic command prompt following this anatomy.
## Workflow
1. Grill the user. 2. Decide the level. 3. Draft to that level. 4. Save.
```

**Marker:** it writes a prompt. *(This project's `build-prompt.md` is a Level 6 prompt.)*

### Level 7 — self-improving (expert)

A prompt that **updates its own or another prompt's knowledge** — *"agents updating agents, prompts updating prompts."* The best pattern: a **dynamic `## Expertise` section** that an Improve step rewrites from diffs/learnings, while the Workflow stays frozen. The prompt grows more proficient over time. Rare and advanced — most use cases never need it, but when they fit, these are extremely powerful.

```markdown
# Hook Expert — Improve
## Workflow
1. Run `git diff`; look for new patterns worth capturing.
2. IMPORTANT: If no relevant learnings → STOP. Report "No expertise updates needed."
3. Else update ONLY the ## Expertise section of the Build prompt. Do NOT touch Workflow.
```

**The invariant:** Workflow is frozen; Expertise is the mutable, living layer. **Marker:** a step that edits the Expertise of a prompt. (The Plan/Build/Improve triad is one concrete implementation of this.)

## Control flow patterns

These four primitives are **how you write a Level 3 (control flow) prompt**; Level 4 delegation reuses the loop primitive for parallel Task. All are expressed in natural language inside `## Workflow` — no code syntax needed.

### 1. Conditional branch (if/else)

Indent the branch body. Use imperative labels (`If`, `Else`, `Otherwise`).

```markdown
## Workflow
2. For each URL:
   - If it exists AND is fresh: skip, note "skipped"
   - If it exists AND is older: delete, note "deleted"
   - If it does not exist: proceed to scrape
```

**Rule:** condition on one line, consequences indented below. Agent reads indent as scope.

### 2. Early exit / STOP guard

Place STOP **before** the expensive or irreversible step.

```markdown
## Workflow
5. Evaluate: do changes contain new expertise worth capturing?
   IMPORTANT: If no relevant learnings found → STOP HERE and report "No updates needed."
6. Extract learnings and update ## Expertise...
```

**Rule:** `IMPORTANT:` + `→ STOP` is the convention. Put it before the expensive step so the agent sees the gate first.

### 3. Loop (for each / until)

```markdown
## Workflow
3. For each URL not skipped, use the Task tool in parallel with this exact prompt: ...
4. After all Tasks complete, respond in the Report Format.
```

**Sequential loop:** drop `in parallel`. Always state the join point ("After all … complete") or the agent may report before workers finish.

### 4. Deduplication / reduce

Describe the merge rule before processing; list precedence strongest-first.

```markdown
## Workflow
2. Deduplicate by file_path:
   - If ANY entry has no params → read entire file (wins over all)
   - Otherwise pick entry with offset 0 and largest limit
   - If more than 3 entries for same file → read entire file, move on
```

**Rule:** strongest condition first; include a fallback to prevent edge-case loops.

### Control flow quick reference

| Pattern | Signal phrase | Position |
|---|---|---|
| Branch | `If X: ... Else: ...` | Inside numbered step, indented |
| Early exit | `IMPORTANT: if X → STOP HERE` | Before expensive step |
| Parallel loop | `For each X, use Task tool in parallel` | Step body + join step after |
| Sequential loop | `For each X: do Y` | Step body |
| Reduce/dedup | Precedence list, strongest first | Before the processing step |

## CLAUDE.md sizing rule

`CLAUDE.md` is system context, not documentation. Concise version = tooling + key commands + project structure + 5 dev guidelines ≈ 30 lines. Bloated version = formatting rules, import order, line-length policies — all noise that displaces signal. Rule: if it belongs in a linter config, remove it from `CLAUDE.md`.
