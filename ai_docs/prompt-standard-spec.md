<!--
CANONICAL HOME: repo_builder_elixir.
The implementation of this standard lives at `lib/repo_builder/prompt_standard/` (the
`RepoBuilder.PromptStandard` context: Validator, Builder, CLI mix tasks). The copy of this
spec at `/data/1.Projects/repo_builder/ai_docs/prompt-standard-spec.md` is FROZEN reference
(commit 6249331) and must not diverge from this one.

SPEC §7 ≠ THE SHIPPED VALIDATOR (read before trusting §7 literally):
§7 below is an *aspirational* proposal — HARD H1–H10 + SOFT S1–S7 with per-check semantics
(e.g. spec H2 = "runtime prompts are front-matter-free", spec H8 = "file-missing fallback",
spec H9 = "SQL audit row validity"). The shipped validator (`prompt_builder/validator.py`,
ported verbatim in behavior to `RepoBuilder.PromptStandard.Validator`) instead implements a
*different* H1–H9 + S1–S5: its H2 = "`# Purpose` heading present", H8 = "no UTF-8 BOM",
H9 = "no unresolved `$ARGUMENTS`". **The behavioral truth is the validator (asserted by the
test suite), NOT spec §7.** H10 is intentionally deferred (a CLI `SKIP` row, never a real
check) pending a managed system-prompt template. Rewriting §7 to match the implementation is
a tracked follow-up, deliberately out of scope for the port.
-->

# Prompt Standard Spec — Reverse-Engineered from Production Artifacts

> **Source (derived from):**
> - `ai_docs/prompt-anatomy.md` — the factory's section taxonomy + L1–L7 capability ladder.
> - `.claude/commands/build-prompt.md`, `.claude/commands/improve-build-prompt.md` — the L6 builder + its L7 self-improve loop.
> - `commands/tac/build-adw-prompt.md`, `commands/tac/improve-adw-builders.md`, `commands/tac/build-adw-orchestrator.md` — the ADW-specialized builders (dual frontmatter, Output Contract, factory invariants).
> - `configs/templates/orchestration/app/backend/prompts/orchestrator_agent_system_prompt.md` — the production orchestrator **system** prompt (20.5 KB).
> - `configs/templates/orchestration/app/backend/prompts/event_summarizer_system_prompt.md` + `event_summarizer_user_prompt.md` — the production summarizer **system+user** prompt pair.
> - `configs/templates/orchestration/app/backend/modules/single_agent_prompt.py` — runtime assembly of the summarizer pair.
> - `configs/templates/orchestration/app/backend/modules/orchestrator_service.py` (`_load_system_prompt`, lines 161–274) — runtime assembly of the orchestrator prompt.
> - `configs/templates/orchestration/app/backend/tests/test_orchestrator_prompt_injection.py` — the only machine-checked invariant on rendered prompts.
> - `configs/templates/orchestration/app/orchestrator_db/migrations/2_prompts.sql` — SQL schema for **recorded** prompts (plus `1_agents.sql` / `0_orchestrator_agents.sql` for the FK + the `agents.system_prompt` column, and `modules/subagent_models.py` for the template frontmatter schema).

---

## Preamble: two prompt populations (read this first)

This codebase contains **two distinct kinds of "prompt"** that must never be conflated. Every section below is precise about which one it refers to.

| Population | Where it lives | Has front-matter? | Consumed by | Built by |
|---|---|---|---|---|
| **A. Factory slash-command prompts** | `.claude/commands/*.md`, source-of-truth `commands/tac/*.md` | **Yes** (`description`/`argument-hint`/`allowed-tools`/`model`, ADW ones add outer `command`/`version`) | An operator's Claude Code/pi TUI picker | `build-prompt.md` (+ `build-adw-prompt.md`) |
| **B. Runtime application prompts** (the **production artifacts**) | `configs/templates/orchestration/app/backend/prompts/*.md` | **No** (none of the three shipped files carry YAML front-matter) | The Claude Agent SDK at runtime via `_load_system_prompt()` / `single_agent_prompt.py` | Hand-authored; **no builder exists for them** |

This spec reverse-engineers the standard for **Population B** (the production runtime prompts), using **Population A's** builder (`build-prompt.md`, the "previous prompt-builder attempt") as the foil for the §6 gap analysis.

Within Population B there are again **two sub-layers of "metadata"** that must not be confused:

- **(B-i) The `.md` prompt file itself** — currently **front-matter-free**; its only "machine contract" is its `{{TOKEN}}` / `{slot}` content (§4) and the invariants the injection test enforces (§5).
- **(B-ii) The `prompts` SQL table** — an **audit log of prompts *sent*** to agents, **not** a registry of prompt *definitions*. A prompt definition lives in a `.md` file; a *sent instance* of it is recorded as a row here (§2).

---

## §1 — PROMPT ANATOMY (heading taxonomy + canonical order)

There are **two competing taxonomies** in this repo. The factory doc defines one; the production prompt follows another. A real standard must reconcile them.

### 1a. The factory taxonomy (from `prompt-anatomy.md`)

`prompt-anatomy.md` defines a prompt as "interchangeable sections — swappable Lego blocks." The canonical section set and the order the mature corpus converges on:

> Corpus note (tac-13/14, 2026-06): the mature reference commands converge on `Purpose → Variables → Instructions → Workflow → Report`. **Instructions** (constraint/guidance bullets) is kept distinct from **Workflow** (the numbered step sequence); `## Report` appears in nearly every command. — `prompt-anatomy.md` (Corpus note block)

Full anatomy block, verbatim labels (`prompt-anatomy.md`, "Full anatomy (reference)"):

```
# Purpose           # REQUIRED
## Variables        # optional — dynamic first, static after
## Instructions     # optional — constraints & guidance bullets
## Expertise        # optional but high-leverage
## Workflow         # the core section
## Report           # pin the EXACT output format
```

Plus an optional **front-matter** block (`---\ndescription / argument-hint / allowed-tools / model\n---`) at the top.

### 1b. The production taxonomy (from `orchestrator_agent_system_prompt.md`)

The shipped orchestrator prompt **does not follow 1a**. Its actual heading order, with exact line numbers:

| Line | Heading | Role |
|---|---|---|
| 1 | `# Orchestrator Agent System Prompt` | Title only (≈ the anatomy's `# Purpose`, but it's a label, not a purpose statement) |
| 5 | `## Core Operating Principle — ALWAYS DELEGATE, NEVER DO THE WORK YOURSELF` | The behavioral invariant / "constitution" (no equivalent in the factory anatomy) |
| 34 | `## Instructions` | Bulleted operating constraints (matches the anatomy label) |
| 49 | `## Variables` | Currently a single constant: `COMMAND_LEVEL_COMPACT_PERCENTAGE: 80%` (line 50) |
| 53 | `## Available Subagent Templates` | Wraps the `{{SUBAGENT_MAP}}` injection slot (line 55) |
| 59 | `## Your Tools` | Tool reference (subsection per tool: `### create_agent` … `### check_adw`, lines 63–182) |
| 184 | `## ADW Workflows` | Domain orientation |
| 198 | `### Active harness & allowed models (orientation)` | Wraps the `{{HARNESS_CATALOG}}` injection slot (line 200) |
| 208 | `### Harness selection (Settings ⚙) and where it applies` | Cross-cutting policy bullets |
| 273 | `### Reference conventions (inserted by the UI)` | Token grammar (`adw:`, `run:`, `#n`) |
| 280 | `### Routing rules` | A markdown **decision table** (Message shape → Action) |
| 326 | `## Context Window Management` | Operational runbook |
| 355 | `## Guidelines` | Softmax principles |
| 363 | `## Agent Specialization Examples` | Few-shot role examples |
| 371 | `## Workflow Pattern` | A numbered *meta*-workflow (Analyze→Plan→Create→Dispatch→Monitor→Report) |
| 380 | `## Important Notes` | Final catch-all bullets |

The summarizer pair is far smaller and **shares no headings at all** with either taxonomy:

- `event_summarizer_system_prompt.md` (169 bytes, 1 line): *"You are a concise log summarizer. Create brief, informative 1-sentence summaries of events. Focus on the key action or information. Keep summaries under 100 characters."* — a bare role statement, no `#` heading.
- `event_summarizer_user_prompt.md` (148 bytes): a 6-line template with two `.format()` slots (`{event_type}`, `{details}`) and the instruction *"Provide ONLY the summary sentence, no other text."* — no heading.

### 1c. Reconciled standard (what a generated runtime prompt should contain)

**Canonical heading order for a runtime system prompt** (synthesizing 1a's labels with 1b's proven structure), in priority order — a prompt MUST lead with 1–2, SHOULD include 3–5, MAY include the rest:

1. `# <Role Title>` — one-line identity (1b line 1).
2. `## Core Operating Principle` (or equivalent invariant header) — the non-negotiable behavioral rule, bolded emphasis, stated before any tooling (1b line 5). This is the production prompt's most load-bearing section and has **no analogue** in the factory anatomy — it must be added to any runtime standard.
3. `## Instructions` — constraint/guidance bullets (1a/1b agree on this label).
4. `## Variables` — named config constants consumed at runtime (1b line 49 holds `COMMAND_LEVEL_COMPACT_PERCENTAGE: 80%`, referenced verbatim in `## Context Window Management`, line 326).
5. `## <Domain> Templates / Catalog` — any section that wraps a `{{TOKEN}}` injection slot (1b lines 53, 198). The wrapping heading is mandatory: a bare `{{TOKEN}}` with no heading renders as an unexplained block.
6. `## Your Tools` — one `### <tool_name>` subsection per tool, each with a bulleted parameter list (1b lines 59–182).
7. `## Routing rules` (when applicable) — a markdown **decision table** mapping input shapes to actions (1b line 280); this is the production prompt's preferred control-flow vehicle (vs. the factory's numbered-`## Workflow`-steps, see §3).
8. `## Context Window Management` / `## Guidelines` / `## Important Notes` — operational runbooks and softmax principles (1b lines 326/355/380).

**A runtime USER prompt** (the summarizer user-prompt pattern) needs none of the above: it is a short instruction + structured data block + an output-format pin ("Provide ONLY …"). See §3 and §4.

---

## §2 — METADATA / FRONT-MATTER SCHEMA (machine-checkable)

Three separate machine-checkable schemas touch "prompts." Each is given in full with type / required-optional / enums / default / purpose, and NOT-NULL / UNIQUE / CHECK flags.

### 2a. Front-matter of a **factory slash-command** prompt file (Population A)

Source: `build-prompt.md` front-matter (lines 1–6) and the "Full anatomy" block of `prompt-anatomy.md`.

| Field | Type | Required? | Enum/Default | Purpose |
|---|---|---|---|---|
| `description` | string | Required (shown in command picker) | — | One-line purpose shown in the picker (`prompt-anatomy.md`, Metadata block) |
| `argument-hint` | string | Optional | — | Hint for what to pass as `$ARGUMENTS` (anatomy Metadata block) |
| `allowed-tools` | comma-list | Optional | — | Least-privilege tool grant; omit if none needed (`build-prompt.md` → Drafting rules) |
| `model` | string | Optional | e.g. `claude-opus-4-8` | Pin only when reasoning depth justifies it (anatomy Metadata block) |

ADW factory prompts (`build-adw-prompt.md` lines 1–10) wrap the above in **dual front-matter**: an **outer** block (`command: <slug>` + `version: X.Y.Z`) then the **inner** Claude block (`description`/`argument-hint`/`allowed-tools`/`model`). The outer `version` is bumped on every Expertise edit (`improve-adw-builders.md` step 5).

### 2b. Front-matter of a **runtime application** prompt file (Population B) — as-shipped

**The three shipped production `.md` prompts carry NO YAML front-matter.** (`grep '^---'` over the three files returns nothing; each begins directly with prose or `#`.) So as-shipped, schema 2a does **not** apply to Population B.

The only machine-checkable "front-matter-like" data on a runtime prompt comes from two other places:

1. The **`SubagentFrontmatter`** pydantic model (`subagent_models.py` lines 13–46) — used when an agent is created from a **template** (`.claude/agents/*.md`), whose `prompt_body` becomes the agent's system prompt (`agent_manager.py` line 1665: `system_prompt = template.prompt_body`):

   | Field | Type | Required? | Validator | Purpose |
   |---|---|---|---|---|
   | `name` | `str` | **Required** (`Field(...)`) | non-empty + kebab-case (`subagent_models.py` 33–38) | Unique template identifier |
   | `description` | `str` | **Required** | non-empty (41–46) | Template description for orchestrator |
   | `tools` | `Optional[List[str]]` | Optional (`None`) | — | Allowed tools; `None` ⇒ all tools |
   | `model` | `Optional[str]` | Optional (`None`) | — | Model override (sonnet/haiku/opus) |
   | `color` | `Optional[str]` | Optional (`None`) | — | UI theme color |

   Plus `SubagentTemplate.prompt_body` (`str`, required, validated non-empty at 65–67) and `file_path`.

2. The two **`agents` / `orchestrator_agents`** SQL columns that store an agent's runtime system prompt as plain `TEXT` (no structure):
   - `agents.system_prompt TEXT` — nullable (`1_agents.sql`).
   - `orchestrator_agents.system_prompt TEXT` — nullable (`0_orchestrator_agents.sql`).

### 2c. The `prompts` SQL table (audit log of prompts *sent*) — full DDL

Source: `2_prompts.sql` (entire file, 22 lines). This is a **history/audit** table (migrations README line 32: *"Prompt history (FK → agents)"*), **not** a prompt-definition registry.

```sql
CREATE TABLE IF NOT EXISTS prompts (
    id TEXT PRIMARY KEY,
    agent_id TEXT REFERENCES agents(id) ON DELETE CASCADE,
    task_slug TEXT,
    author TEXT NOT NULL CHECK (author IN ('engineer', 'orchestrator_agent')),
    prompt_text TEXT NOT NULL,
    summary TEXT,
    timestamp TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    session_id TEXT
);
```

| Column | Type | NULL? | Constraints / Default | Purpose |
|---|---|---|---|---|
| `id` | `TEXT` | **NOT NULL** (PK) | `PRIMARY KEY` | UUID generated in Python (`str(uuid.uuid4())`, `database.py` insert_prompt line 1513) |
| `agent_id` | `TEXT` | NULLable | `REFERENCES agents(id) ON DELETE CASCADE` | FK to the recipient agent; cascades on agent delete (file header comment) |
| `task_slug` | `TEXT` | NULLable | — | Task identifier (e.g. `orchestrator-YYYYMMDD-HHMMSS`, `orchestrator_service.py` line 356) |
| `author` | `TEXT` | **NOT NULL** | **`CHECK (author IN ('engineer', 'orchestrator_agent'))`** — the only enum in the table | Trust boundary: only a human engineer or the orchestrator agent may author a recorded prompt |
| `prompt_text` | `TEXT` | **NOT NULL** | — | The full prompt text sent |
| `summary` | `TEXT` | NULLable | — | Back-filled later by the summarizer (`database.py` line 1335: `UPDATE prompts SET summary = ? WHERE id = ?`) |
| `timestamp` | `TEXT` | **NOT NULL** | `DEFAULT CURRENT_TIMESTAMP` (Python supplies `_now()`, ISO-8601, `database.py` 1533) | Send time |
| `session_id` | `TEXT` | NULLable | — | Claude SDK session id (optional) |

Notes / flags from the DDL:
- **No `UNIQUE`** constraint on any column (contrast `orchestrator_agents.session_id UNIQUE` and `agents`'s `UNIQUE(orchestrator_agent_id, name)`). The `prompts` table is append-only history; duplicates are legal.
- **No `name`/`version`/`active`/`language` columns** — it is not a registry. A "named, versioned prompt definition" concept **does not exist** in this schema; that is an open question (§8).
- FK requires `PRAGMA foreign_keys = ON` per connection (file header comment; same SQLite caveat as `1_agents.sql`).
- Write path: `database.py::insert_prompt(agent_id, task_slug, author, prompt_text, session_id=None)` (lines 1497–1536); the Python signature does **not** accept `id`/`timestamp`/`summary` (generated server-side), and **does not validate `author`** beyond relying on the SQL CHECK.

### 2d. Cross-cutting config that points at prompt files

| Constant | File:line | Default | Notes |
|---|---|---|---|
| `ORCHESTRATOR_SYSTEM_PROMPT_PATH` | `config.py:130–133` | `BACKEND_DIR/prompts/orchestrator_agent_system_prompt.md` | Overridable by env var |
| `AGENT_SYSTEM_PROMPT_TEMPLATE_PATH` | `config.py:182–184` | `BACKEND_DIR/prompts/managed_agent_system_prompt_template.md` | **⚠ The referenced file does not exist on disk** (`find … managed_agent_system_prompt*` returns nothing). Latent gap → §8. |

---

## §3 — PROSE / RUBRIC RULES (soft)

Conventions observable across the production prompts and the builder docs. These are judgment calls, not pass/fail.

**Voice / register**
- Imperative, second-person: *"You are a conductor, not a performer."* / *"NEVER guess what 'ADW' … means"* (orchestrator prompt lines 7, 192).
- Bold for the load-bearing rule and for emphasis inside prose: **"ALWAYS DELEGATE, NEVER DO THE WORK YOURSELF"** (heading line 5), **"Do NOT"** (line 24).
- ALL-CAPS sentinel phrases carry force: `IMPORTANT`, `NEVER`, `REQUIRED`, `STOP` (e.g. orchestrator line 192 *"NEVER guess"*; the factory's `IMPORTANT: if X → STOP HERE` convention, `prompt-anatomy.md` Control flow patterns).

**Structure conventions**
- **Decision tables over numbered steps** for dispatch logic. The orchestrator's `### Routing rules` (line 280) is a 4-row markdown table (`Message shape | Action`); the factory anatomy instead prefers a numbered `## Workflow`. For a meta-agent that routes, **the table is the production preference**.
- One `### <tool>` subsection per tool, each opening with a one-line description then a bulleted parameter list with **`**param**`** bold keys (orchestrator lines 63–182, e.g. `create_agent`).
- A `## Workflow Pattern` of numbered high-level phases is used for *meta*-guidance (orchestrator line 371: Analyze→Plan→Create→Select→Dispatch→Monitor→Report) — distinct from a per-task step list.

**Length**
- Orchestrator system prompt is **large and intentionally so** (20.5 KB, ~385 lines) — it is a long-lived, capability-saturated system prompt, the opposite of the factory's `CLAUDE.md` sizing rule (*"if it belongs in a linter config, remove it"*, `prompt-anatomy.md` "CLAUDE.md sizing rule"). System prompts are exempt from that rule; the rule is for injected *context*, not for the persona definition.
- Summarizer prompts are deliberately tiny (≤169 bytes) — they are cheap, stateless, single-shot calls on Haiku (`single_agent_prompt.py` line 30: `FAST_MODEL = "claude-haiku-4-5-20251001"`). **Size to the call's cost/frequency.**

**Do / Don't (from the builder's Drafting rules, `build-prompt.md`)**
- *Do* separate **Expertise** (what the agent knows) from **Workflow** (what it does) when expertise is genuinely required.
- *Do* include a `## Report` section pinning an **exact fenced output format** for any prompt whose output is consumed downstream (another agent or a human report-reader).
- *Do* open with a required-variable guard: *"IMPORTANT: if no <VAR> is provided, stop and ask the user for it."*
- *Don't* over-build — over-instructing a simple task hurts ("the L1 lesson", `build-prompt.md` Drafting rules).
- *Don't* manufacture capabilities (delegation, meta) the consumer will never use (`build-adw-prompt.md` Level guidance).

**Runtime-specific conventions seen in production**
- Append a **trust caveat** to any injected snapshot: the `{{HARNESS_CATALOG}}` block ends with *"⚠️ Orientation only — this was captured when the session started. The LIVE active harness … are shown every turn …"* (`orchestrator_service.py` lines 249–262). Any injected, possibly-stale data should carry an equivalent disclaimer.
- Pin output shape in user prompts with a "Provide ONLY …, no other text." closer (`event_summarizer_user_prompt.md` last line) — the runtime analogue of the factory's `## Report` fenced template.

---

## §4 — ASSEMBLY MODEL (how a prompt is composed at runtime)

There are **two assembly paths** in production. Both share one pattern: *read a `.md` file → substitute slots → pass as `system_prompt` (and/or `prompt`) to the Claude Agent SDK `query()`.*

### 4a. Path 1 — Orchestrator system prompt (`orchestrator_service._load_system_prompt`)

Signature and contract (`orchestrator_service.py` lines 161–170):

```python
def _load_system_prompt(self) -> str:
    """
    Load orchestrator system prompt from file and inject SUBAGENT_MAP.
    Returns:
        System prompt text with {{SUBAGENT_MAP}} placeholder replaced
    """
```

Flow (all citations `orchestrator_service.py`):

1. **Resolve path** from `config.ORCHESTRATOR_SYSTEM_PROMPT_PATH`, making it absolute under `BACKEND_DIR` if relative (lines 171–175).
2. **File-missing fallback** — if the file is absent, log a warning and return a hardcoded one-liner: *"You are a helpful orchestrator agent that manages other Claude Code agents."* (lines 177–181). **Never raise.**
3. **Read raw text** (lines 183–184).
4. **`{{SUBAGENT_MAP}}` branch** (lines 187–214) — *only* runs `if "{{SUBAGENT_MAP}}" in prompt_text`:
   - Instantiates `SubagentRegistry(self.working_dir, self.logger)` and calls `registry.list_templates()`.
   - If templates exist → builds a markdown bullet list: `"- **{name}**: {description}"` joined by newlines (lines 196–201).
   - If none → fallback string: *"No subagent templates available. Create templates in `.claude/agents/` directory to enable specialized agents."* (lines 206–207) — **never blank**.
   - Substitutes via **`prompt_text.replace("{{SUBAGENT_MAP}}", template_map)`** (line 214). Note: `.replace()`, not `.format()` — see §5.
5. **`{{HARNESS_CATALOG}}` branch** (lines 221–267) — *only* runs `if "{{HARNESS_CATALOG}}" in prompt_text`:
   - `active = harness_settings.active_selection()`; `catalog = harness_settings.get_catalog()`; `tiers = catalog[harness][provider]` (lines 223–225).
   - Resolves the concrete model from the catalog if `active` carries none (lines 228–229).
   - Builds `active_line = "**Active selection (snapshot at session start):** {h}/{p}/{tier} → {model|unresolved}"` (lines 230–235).
   - Builds `tier_rows` = one `"- {tier} → {model}"` line per tier (lines 237–239), or a fallback *"− (no tiers mapped for …)"* line (lines 240–247) — **never blank**.
   - Assembles the block with the mandatory orientation caveat (lines 249–262, quoted in §3) and substitutes via `prompt_text.replace("{{HARNESS_CATALOG}}", harness_catalog_block)` (lines 266–267).
6. **Return** the fully-substituted string (line 269). It is then placed into the SDK options at line 349: `"system_prompt": self._load_system_prompt()`.

**Slots a generated orchestrator-class system prompt MAY contain** (all optional; each guarded by an `if "{{TOKEN}}" in prompt_text` so their absence is legal):

| Token | Mechanism | Resolved from | Rendered as |
|---|---|---|---|
| `{{SUBAGENT_MAP}}` | `str.replace` | `SubagentRegistry.list_templates()` | Markdown bullet list of templates, or a fallback sentence |
| `{{HARNESS_CATALOG}}` | `str.replace` | `harness_settings.active_selection()` + `get_catalog()` | Active-selection line + tier→model rows + orientation caveat |

**Hard rule:** the `{{…}}` tokens use **double braces** and are resolved with `.replace()` — they are a **literal sentinel convention**, NOT Python `str.format` syntax. A prompt author must not switch them to single-brace `{TOKEN}` (that would collide with §4b) or rely on `.format()` escaping.

### 4b. Path 2 — Event summarizer (`single_agent_prompt.py`)

Module-level load (lines 30–37) — **read once at import**, not per call:

```python
FAST_MODEL = "claude-haiku-4-5-20251001"
PROMPTS_DIR = Path(__file__).parent.parent / "prompts"
EVENT_SUMMARIZER_USER_PROMPT = (
    PROMPTS_DIR / "event_summarizer_user_prompt.md"
).read_text()
EVENT_SUMMARIZER_SYSTEM_PROMPT = (
    PROMPTS_DIR / "event_summarizer_system_prompt.md"
).read_text()
```

Assembly (`summarize_event`, lines ~95–230) builds the **user** prompt with Python **`str.format`** on named fields:

```python
prompt = EVENT_SUMMARIZER_USER_PROMPT.format(event_type=event_type, details=details)
system_prompt = EVENT_SUMMARIZER_SYSTEM_PROMPT   # used verbatim, no slots
```

The template's two slots (`event_summarizer_user_prompt.md` lines 3–4):

```
Event Type: {event_type}
{details}
```

Both `prompt` and `system_prompt` are passed to the SDK (`fast_claude_query`, lines ~44–90) via `ClaudeAgentOptions(model=…, system_prompt=system_prompt, …)` and `query(prompt=prompt, options=options)`. `details` is built from **untrusted agent I/O** — e.g. `json.dumps(tool_input, indent=2)` (the `PreToolUse`/`PostToolUse` branch) — and truncated to 500 chars for `text`/`thinking` blocks.

**Slots a generated summarizer-class user prompt MUST contain** when used with `.format()`:

| Slot | Mechanism | Filled with |
|---|---|---|
| `{event_type}` | `str.format` (named) | One of `PreToolUse`/`PostToolUse`/`text`/`thinking`/`tool_use`/`tool_result`/`Stop`/`SubagentStop`/`PreCompact`/`UserPromptSubmit` |
| `{details}` | `str.format` (named) | `json.dumps(event_data, indent=2)` (optionally truncated) |

**Hard rule (mirror of §4a):** the summarizer uses `.format()`, so the `.md` template must contain **only** the named fields `{event_type}` / `{details}` and no other bare `{` / `}` — a stray brace in the template file would raise `KeyError`/`IndexError`/`ValueError` at render. The two assembly paths therefore use **incompatible** slot conventions and must not be mixed (§8).

### 4c. The unified assembly contract (what a generator must emit)

A generated runtime prompt file must declare, for the validator (§7), **which assembly path** it targets and **which slots** it uses:

- **Path 1 (system prompt, `.replace`):** declare zero or more `{{TOKEN}}` tokens from a known registry (currently `{{SUBAGENT_MAP}}`, `{{HARNESS_CATALOG}}`); the loader resolves each, with a per-token fallback; the rendered string is passed as `system_prompt`.
- **Path 2 (templated prompt, `.format`):** declare the named `{slot}`s; the caller fills them; render via `.format(**kwargs)`; passed as `prompt` and/or `system_prompt`.
- **Static (neither):** a prompt with no tokens/slots (e.g. `event_summarizer_system_prompt.md`) is passed verbatim.

---

## §5 — INJECTION-HARDENING RULES (concrete, quoted)

### 5a. The single machine-checked invariant (from `test_orchestrator_prompt_injection.py`)

The test renders a temp prompt carrying only `{{HARNESS_CATALOG}}` against a temp `.harness.json` and asserts the rendered output. The hard assertions, verbatim:

```python
# No leftover template tokens.
assert "{{" not in rendered and "}}" not in rendered        # line 62 / 89
# Active selection line.
assert "pi/zai/main" in rendered                            # line 64
assert "glm-5.1" in rendered                                # line 65
# The allowed-tier rows render — fast row proves we iterate the catalog.
assert "glm-4.5-air" in rendered                            # line 67
# Orientation caveat is present.
assert "Orientation only" in rendered                       # line 69
assert "list_agents" in rendered                            # line 70
```

and the claude variant (lines 90–93): `"claude/anthropic/main"`, `"main → sonnet"`, `"heavy → opus"`, plus the same no-leftover-tokens assertion.

**Distilled hard rules (these are the §7 pass/fail checks):**

1. **No leftover template tokens.** After assembly, the rendered string MUST NOT contain `{{` or `}}` (lines 62, 89). A leaked sentinel reaching the model is a defect. → The loader substitutes every `{{TOKEN}}` it knows; **any `{{TOKEN}}` the loader does NOT know survives and fails this rule.** Therefore: a prompt may only contain tokens from the loader's known registry.
2. **Every token resolves to non-empty content** with the expected anchors (active selection line + at least one tier row proving iteration). Empty injection is treated as a fallback message, never as a raw token and never as a blank (orchestrator_service.py 206–214, 240–247).
3. **Snapshots carry a trust caveat.** Any injected value that can go stale MUST be accompanied by a disclaimer pointing at the live source (the "Orientation only" line, present and asserted). The model is told to trust `list_agents` / `command_agent` results over the snapshot (orchestrator_service.py 249–262).
4. **File-missing is graceful, never a raise.** Missing prompt file → hardcoded default string (orchestrator_service.py 177–181). The system must still boot.

### 5b. Trust-boundary enforcement via SQL

`prompts.author TEXT NOT NULL CHECK (author IN ('engineer', 'orchestrator_agent'))` (`2_prompts.sql`) is the only enum constraint in the schema. It enforces that **only** a human engineer or the orchestrator agent can be recorded as the author of a sent prompt — a structural guard against arbitrary/untrusted authors being written to history. (`insert_prompt` in `database.py` does not re-validate; it relies on this CHECK.)

### 5c. Slot-mechanism rules (derive from §4)

- **Path 1 tokens are `.replace()`-based** ⇒ the surrounding prose may freely contain single `{` / `}` (e.g. JSON examples, code blocks) without breaking render. This is **why** the orchestrator prompt uses double-brace sentinels rather than `.format()`.
- **Path 2 slots are `.format()`-based** ⇒ the template must contain *only* its declared named fields and no stray braces; values substituted in (e.g. `json.dumps` of untrusted `tool_input`) are safe because `str.format` does **not** re-interpret braces inside substituted *values* — only inside the template.
- **The two mechanisms must not be combined in one file.** A file cannot simultaneously be `.replace()`-substituted (Path 1) and `.format()`-substituted (Path 2); pick one and declare it (§4c).

### 5d. Soft injection hygiene in the prompt prose itself

The orchestrator prompt teaches the model conservative handling of untrusted/runtime-injected content (these are prose rules a generated prompt in this family should inherit):

- Image references in user messages must be opened with `Read` before responding (orchestrator prompt `## Instructions`, lines ~43–48) — treats a path as data to inspect, not instructions.
- **"NEVER guess"** domain acronyms (`adw:`); if ambiguous, list options or call a tool rather than confabulating (line 192).
- **Reference conventions are a fixed grammar** (`adw:<workflow>`, `run:<id>`, `#<n>`) defined by the UI (lines 273–278); the model parses, never invents, references.

---

## §6 — PREVIOUS BUILDER GAP ANALYSIS

### 6a. What the existing builder does

- **`build-prompt.md` (L6)** interviews the user, classifies the prompt on the L1–L7 ladder (`prompt-anatomy.md`), drafts to that level, and saves to **`.claude/commands/<slug>.md`** with front-matter (`description`/`argument-hint`/`allowed-tools`/`model`). It separates frozen `## Workflow` from living `## Expertise`.
- **`improve-build-prompt.md` (L7)** folds new learnings into *only* the `## Expertise` section of `build-prompt.md` (Workflow-frozen / Expertise-living invariant).
- **`build-adw-prompt.md` (L6)** specializes the above for ADW *step* prompts: adds a mandatory `## Output Contract`, dual front-matter (`command`/`version` outer + Claude inner), and a Registration checklist for engine-driven commands.
- **`improve-adw-builders.md` (L7)** improves the ADW builders' Expertise and bumps the outer `version` patch.
- **`build-adw-orchestrator.md` (L5/L6)** writes a *spec* (not code) for an orchestration app into a target repo — relevant because it is the provenance of the very `orchestration/` template whose prompts we are standardizing.

### 6b. What is reusable for a *runtime prompt* standard

- **The L1–L7 capability ladder** as a sizing/complexity signal (sizing a runtime prompt's needed richness).
- **Least-privilege `allowed-tools`** discipline — directly applicable to agent-creation system prompts and subagent templates (`SubagentFrontmatter.tools`).
- **Output Contract concept** (`build-adw-prompt.md`) — maps cleanly onto the summarizer's "Provide ONLY …" pin and any future deterministic-output runtime prompt.
- **Expertise/Workflow split + the L7 self-improve loop** — a clean model for keeping a long-lived system prompt's mutable knowledge (`## Variables` constants, routing tables) separable from its frozen constitution (`## Core Operating Principle`).
- **Interview heuristics** (short-circuit, one-gap-at-a-time, respect the user's time) — reusable for any interactive generator.

### 6c. Where it falls short for *runtime* (Population B) prompts

1. **Wrong target path.** Every builder writes to `.claude/commands/<slug>.md` (or `commands/tac/`); runtime prompts live in `app/backend/prompts/*.md`. No builder can emit them today.
2. **Front-matter mismatch.** The builders *require* front-matter; the three shipped runtime prompts have **none**. Forcing 2a front-matter onto a runtime prompt would change the loader contract (`_load_system_prompt` does raw `.read_text()`, not front-matter parsing).
3. **No `{{TOKEN}}` / `{slot}` concept.** The factory anatomy has no notion of runtime injection slots. The orchestrator prompt's two load-bearing `{{TOKEN}}`s and the summarizer's `{slot}`s are first-class in production and invisible to the builder.
4. **No system-vs-user pairing.** The summarizer is a **system+user pair**; the builder only produces single system-prompt/command files.
5. **Anatomy ≠ production structure.** The builder's `Purpose → Variables → Instructions → Workflow → Report` does not match the orchestrator's actual headings (no `# Purpose`, instead `# Title` + `## Core Operating Principle`; routing *tables* not `## Workflow` steps; large `## Your Tools` reference). A builder enforcing the anatomy would produce a structurally wrong orchestrator prompt.
6. **No validator / no test harness.** The builders draft-and-save with a human review loop; they have **no machine check** analogous to `test_orchestrator_prompt_injection.py`. There is no "lint the rendered prompt" step.
7. **No `.format()`-safety discipline.** Nothing in the builder warns that a Path-2 template must avoid stray braces (§5c).
8. **No concept of the `prompts` table or `author` trust boundary.** The builders are file-oriented; they never touch the audit-log schema or its `CHECK` constraint.

**Net:** the previous builder is a strong *slash-command* prompt factory but is structurally blind to runtime prompts. Building a runtime-prompt generator requires extending it with: a runtime target path, a slot/token declaration block, a system+user pair option, a front-matter-free mode, a render-and-validate step, and awareness of the SQL audit schema.

---

## §7 — PROPOSED VALIDATOR CHECKLIST

Two tiers. HARD checks are pass/fail and machine-enforced (cite §2/§4/§5). SOFT checks are judgment-rubric (cite §1/§3).

### 7a. HARD checks (pass/fail)

**H1 — Front-matter (Population A only).** If the file is a factory slash-command, it MUST carry the required front-matter fields: `description` (non-empty); `allowed-tools` omitted-or-minimal-but-complete; ADW commands additionally carry outer `command` + `version` (§2a). *Citation:* `build-prompt.md` front-matter; `build-adw-prompt.md` lines 1–10.

**H2 — Runtime prompts are front-matter-free (Population B, as-shipped).** A file under `app/backend/prompts/` consumed by `_load_system_prompt` / `single_agent_prompt.py` MUST NOT begin with a `---` YAML block unless the loader is updated to parse it (today it does raw `.read_text()`, §4). *Citation:* the three shipped files; `orchestrator_service.py` 183–184.

**H3 — No undeclared/unknown tokens.** Every `{{TOKEN}}` in a Path-1 prompt MUST be in the loader's known registry (currently `{{SUBAGENT_MAP}}`, `{{HARNESS_CATALOG}}`). After render, `assert "{{" not in rendered and "}}" not in rendered` MUST hold (§5a rule 1). *Citation:* `test_orchestrator_prompt_injection.py` lines 62, 89.

**H4 — Every token has a non-empty resolution + fallback.** No token may render blank; empty cases emit a fallback sentence/line (§5a rule 2). *Citation:* `orchestrator_service.py` 206–214, 240–247.

**H5 — Stale-snapshot caveat present.** Any token that injects potentially-stale state MUST be accompanied by a trust disclaimer naming the live source (§5a rule 3). *Citation:* `orchestrator_service.py` 249–262; asserted at test line 69.

**H6 — Slot-template braces (Path 2 only).** A `.format()`-based template MUST contain exactly its declared named fields and no stray `{`/`}`. Render smoke-test: `EVENT_SUMMARIZER_USER_PROMPT.format(event_type="x", details="y")` MUST NOT raise (§5c). *Citation:* `single_agent_prompt.py` `.format()` calls.

**H7 — One mechanism per file.** A prompt file MUST NOT mix `{{TOKEN}}` (`.replace`) and `{slot}` (`.format`) (§5c).

**H8 — File-missing fallback defined.** The loader MUST return a sane default if the prompt file is absent (never raise) (§5a rule 4). *Citation:* `orchestrator_service.py` 177–181.

**H9 — SQL audit row validity (when a prompt is *sent*).** A row written to `prompts` MUST satisfy: `author ∈ {'engineer','orchestrator_agent'}` (CHECK), `prompt_text` non-null, `id`/`timestamp` server-generated, `agent_id` references a live `agents.id` (FK, CASCADE) (§2c). *Citation:* `2_prompts.sql`; `database.py::insert_prompt` 1497–1536.

**H10 — Referenced prompt-file paths exist.** Any path constant pointing at a prompt file (e.g. `ORCHESTRATOR_SYSTEM_PROMPT_PATH`, `AGENT_SYSTEM_PROMPT_TEMPLATE_PATH`) MUST resolve to a file on disk; a missing default (today: `managed_agent_system_prompt_template.md`) is a FAIL. *Citation:* `config.py` 130–133, 182–184; `find` returns nothing for the managed template.

### 7b. SOFT checks (rubric, §1/§3)

- **S1 — Leads with identity + invariant.** Runtime system prompt opens with `# <Role>` then a `## Core Operating Principle`-class invariant before any tooling (§1c). 
- **S2 — Wraps tokens in a heading.** Every `{{TOKEN}}` sits under an explanatory `##`/`###` heading (§1c; orchestrator lines 53, 198).
- **S3 — Tool reference shape.** One `### <tool>` per tool, each with a bulleted `**param**` list (§3; orchestrator 63–182).
- **S4 — Control flow as a table for routing.** Dispatch logic uses a markdown decision table, not prose (§3; orchestrator line 280).
- **S5 — Output pinned.** User/templated prompts end with a "Provide ONLY …, no other text." closer or equivalent fenced contract (§3).
- **S6 — Voice/length fit.** Imperative second-person; ALL-CAPS sentinels (`IMPORTANT`/`NEVER`/`STOP`) reserved for force; size scaled to call cost/frequency (Haiku-sized prompts stay tiny) (§3).
- **S7 — Untrusted-data hygiene prose.** Instructs the model to inspect-not-execute references (images, `adw:`/`run:`/`#n`) and to "never guess" (§5d).

---

## §8 — OPEN QUESTIONS (must resolve before building)

1. **Should runtime `.md` prompts adopt front-matter, and if so who parses it?** Today they are front-matter-free and loaded with raw `.read_text()` (§2b/§4). Adding a `name`/`version`/`assembly-path`/`slots` declaration block would help the validator (§7 H1/H3) but requires `_load_system_prompt` and `single_agent_prompt.py` to strip front-matter before use. **Decision needed:** front-matter for runtime prompts — yes/no, and which loader parses it?

2. **Is there a "named, versioned prompt-definition registry," or is the `.md` file the only definition?** The `prompts` SQL table is an audit log with no `name`/`version`/`active` columns (§2c); the only `version` field in the repo is on ADW *factory* commands (outer `command`/`version`). If runtime prompts need versioning (e.g. A/B, rollback), a new mechanism must be designed. **Decision needed:** versioning model for runtime prompts.

3. **`{{TOKEN}}` (`.replace`) vs `{slot}` (`.format`): one canonical mechanism or both?** They are mutually exclusive within a file (§5c) and incompatible in their brace rules. Should the standard pick one (recommend `.replace`-with-double-braces, since it tolerates prose braces and JSON), or formally support both with a declared `assembly` mode per file?

4. **Should `{{TOKEN}}`s be a closed registry, and how is it extended?** Today only `{{SUBAGENT_MAP}}` and `{{HARNESS_CATALOG}}` exist and H3 treats the set as closed. Adding a token touches `_load_system_prompt` (hard-coded `if "{{X}}" in prompt_text` branches). **Decision needed:** a declarative token registry (data-driven) vs. the current hard-coded branches.

5. **System+user pairing: is the summarizer's two-file pair the canonical pattern?** Nothing in the builder or anatomy models a *pair* of prompts (system + user) consumed together. Should the standard formalize "prompt = a system file + an optional templated user file," and how are they associated (filename convention? a manifest)?

6. **The missing `managed_agent_system_prompt_template.md`.** `config.py:182–184` defaults `AGENT_SYSTEM_PROMPT_TEMPLATE_PATH` to a file that does not exist on disk. Is this a dead reference, an unimplemented feature (per-agent managed-agent prompt templating), or a file that should ship? H10 currently FAILs on it; **resolve before the validator gates on H10.**

7. **Does the orchestrator prompt's structure become the runtime template, or do we refactor it toward the factory anatomy?** They diverge materially (§1): no `# Purpose`, an extra `## Core Operating Principle`, routing tables vs. `## Workflow`. **Decision needed:** is the orchestrator prompt the *exemplar* the generator must reproduce, or should it be refactored to the anatomy (and is that refactor safe given the injection test only covers `{{HARNESS_CATALOG}}`)?

8. **Scope of the injection test.** `test_orchestrator_prompt_injection.py` only covers `{{HARNESS_CATALOG}}` (two harness variants); it does **not** cover `{{SUBAGENT_MAP}}` resolution, the file-missing fallback (H8), or Path-2 `.format()` safety (H6). Should the standard require a test per token + per assembly path? **Decision needed:** required test coverage matrix.

9. **`prompts.author` enum ownership.** The CHECK allows only `engineer` | `orchestrator_agent`. Should *command-level managed agents* (created via `create_agent`) also be allowable authors for the prompts they relay, and should `task_slug` be standardized (today ad-hoc, e.g. `orchestrator-YYYYMMDD-HHMMSS`)?

10. **Generator vs. validator split.** Is this spec feeding (a) a *validator* that lints existing `.md` prompts (read-only), (b) a *generator* that writes them (Population-B analogue of `build-prompt.md`), or both? The §7 checklist serves a validator; a generator additionally needs the §6c extensions. **Confirm the downstream tool's role.**

---

### Confidence note

This spec is grounded entirely in the cited files with verbatim quotes and exact line numbers; no behavior was assumed beyond what the code/tests/DDL express. **High confidence:** §2 (SQL DDL is authoritative), §4 (assembly flow is fully visible in `_load_system_prompt` and `single_agent_prompt.py`), §5a (the test asserts exactly what is quoted), §6 (the builders' contracts are explicit). **Medium confidence:** §1c's "reconciled standard" and §3 are *interpretive* syntheses of two inconsistent taxonomies — the headings and voice are quoted, but the *priority order* and *do/don't* distillation are my judgment and should be ratified against any additional runtime prompts not in the three shipped here. **Explicitly unresolved:** every item in §8, the most load-bearing being #1 (front-matter for runtime prompts), #3 (token vs. slot mechanism), #6 (the missing managed-agent template), and #10 (validator vs. generator scope) — these four gate the architecture of any downstream tooling and must be answered before building.
