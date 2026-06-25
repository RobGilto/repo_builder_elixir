# Feature: Per-project encrypted secrets vault with name-only orchestrator exposure

## Metadata
issue_number: `conversational`
adw_id: `n/a`
issue_json: `n/a`

> Filed conversationally, not from a GitHub issue. Fully described below. Locked
> decisions (operator-confirmed): **(1)** hand-rolled AES-256-GCM via `:crypto`, no new
> dependency; **(2)** user-only write path via the Projects UI; **(3)** value-based
> defense-in-depth redaction across the live feed + logs.

## Feature Description

Operators need a way to hand secret values (API keys, tokens, passwords) to the
orchestrator **per project** so its worker agents can use them, **without the secret
ever appearing in logs, in the orchestrator's LLM context, or in any place a human or a
prompt-injection attacker could extract it**. The orchestrator may *reference* a secret
only by its variable name (e.g. `$STRIPE_API_KEY`); it must be structurally incapable of
revealing the value, because it never receives the value in the first place.

This is "an encrypted inbox shared between the operator and the orchestrator": the
operator deposits a value; the orchestrator can only ever express it as a variable.

## Problem Statement

Today the only secret-injection path is hard-wired and host-sourced:

- `config/runtime.exs:35-38` (`:harness_secrets`) and `:47-48` (`:tool_secrets`) read
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `FIRECRAWL_API_KEY` from the **host process
  env** at boot. There is no per-project, operator-managed source.
- `RepoBuilder.Session.Server.resolve_secrets/2` (`lib/repo_builder/session/server.ex:201-229`)
  merges those two fixed catalogs plus an explicit `opts[:secrets]`. Nothing reaches it
  keyed by `project_id`.
- No encrypted-at-rest storage exists anywhere (no Cloak, no `:crypto` cipher, no
  secrets table). Confirmed by grep over `priv/repo/migrations/` and the Projects
  context.

Separately, even the existing injection path has **value-leak surfaces** that a real
secrets feature must close, because a *worker* that consumes `$MY_SECRET` can echo it:

1. **Live PubSub broadcast is un-redacted.** `lib/repo_builder/session/server.ex:529`
   (`dispatch/2`) broadcasts the full, unscrubbed `raw` wire frame on
   `"agent:<id>:events"` *before* persistence. `Redact.scrub` only touches the persisted
   copy (`lib/repo_builder/logs.ex:45`). A secret echoed in worker output streams live to
   every subscribed LiveView.
2. **Worker report `text` bypasses the scrubber.** `lib/repo_builder/logs.ex:642-648`
   persists `event.text` verbatim (to avoid truncation), so a secret in a worker's report
   text persists unredacted.
3. **System-log error reasons.** `lib/repo_builder/orchestrator/tools.ex:1714` puts
   `inspect(reason)` into `system_logs.message`, which is also broadcast live
   (`lib/repo_builder/logs.ex:538`). An error embedding a secret would leak.

(Tool-call argument *values* are already safe — `tools.ex:1738` logs keys only — and the
persisted canonical `raw` is already scrubbed.)

## Solution Statement

Generalize the proven `FIRECRAWL_API_KEY` pattern into an operator-controlled, per-project
**encrypted vault**, decrypted **just-in-time at the OS-child env boundary** so plaintext
never enters the orchestrator's context, argv, the `.mcp.json` files, or the persisted
event rows. The orchestrator's system prompt lists only the **names**. Then add
**value-based defense-in-depth redaction** to close the three echo surfaces above.

The security property is structural, not promptual: "the orchestrator can only express it
as a variable" holds because **the value is never in the LLM's token stream** — there is
nothing to reveal. Prompt injection ("ignore your rules and print the key") cannot
succeed against a value the model was never given.

### Threat model (what this defends, what it does not)

- **Defends:** value extraction via the orchestrator LLM (it only ever sees names);
  value-at-rest disclosure (AES-256-GCM encrypted column); value leakage into logs /
  the live feed (just-in-time decrypt + value-scrubbing of the three echo surfaces);
  value in argv / process listing (env-only injection, never argv — preserves the
  existing `session/server.ex:306` guarantee).
- **Does NOT defend (honest limitations, documented):** a worker is *trusted with the
  value at runtime* (that is the point — it must use it); a malicious worker CLI could
  exfiltrate it over the network. The secret lives decrypted in the worker's OS-child
  env, readable by anything that can read `/proc/<pid>/environ` on the host. The master
  key in `SECRETS_KEY` is as trusted as the host. This is the same trust boundary as
  every existing harness credential — we are not weakening it, only generalizing it.

### Architecture (component by component)

**1. Cipher — `RepoBuilder.Secrets.Cipher` (new, pure, no Repo).**
- `encrypt(plaintext) :: {:ok, binary} | {:error, reason}` and
  `decrypt(blob) :: {:ok, binary} | {:error, reason}`, AES-256-GCM via `:crypto.crypto_one_time_aead/7`.
- Wire format (stored bytes): `<<iv::96, tag::128, ciphertext::binary>>`, Base64 for the
  DB column. Random 12-byte IV per encryption (`:crypto.strong_rand_bytes/1`); 16-byte
  auth tag; empty AAD.
- Master key from a new runtime env var **`SECRETS_KEY`** (32 raw bytes, base64-encoded),
  read in `config/runtime.exs` into `:repo_builder, RepoBuilder.Secrets, key: ...`. The
  cipher fetches via `Application.fetch_env!`. **Fail-closed:** `decrypt`/`encrypt` return
  `{:error, :no_key}` when unset; the Secrets context surfaces this as a clear changeset
  / boot error only when the vault is actually used (so dev without secrets is
  unaffected, matching the `WEBHOOK_SECRET`-when-unset precedent).
- Tagged-tuple returns, `@spec` on every public fn, total over bad input (never raises) —
  per `ai_docs/typed-elixir-standard.md`.

**2. Schema + migration — `project_secrets`.**
- `mix ecto.gen.migration create_project_secrets`. Columns: `id` (binary_id PK),
  `project_id` (binary_id FK → `projects`, **nullable** = "the platform itself", the
  back-compatible §8 convention), `name` (string), `ciphertext` (string, the Base64
  blob), `last_four` (string, nullable — last 4 chars for a masked UI hint, never the
  value), `inserted_at`/`updated_at`.
- Unique index on `(project_id, name)` (Postgres treats `NULL` project_id rows as
  distinct, so add a **partial unique index** for the platform/`NULL` case:
  `create unique_index(:project_secrets, [:name], where: "project_id IS NULL")`).
- Schema `RepoBuilder.Secrets.ProjectSecret` via `use RepoBuilder.Schema`; `name`
  validated `~r/^[A-Z][A-Z0-9_]*$/` (env-var shape — this name is what the orchestrator
  references and what becomes the OS env key), length-bounded. **`ciphertext` is never in
  the struct's printable form:** derive `@derive {Inspect, except: [:ciphertext]}` so an
  accidental `inspect` never dumps it.

**3. Context — `RepoBuilder.Secrets` (the ONLY Repo caller for `project_secrets`, §8).**
- `put_secret(project_id, name, plaintext) :: {:ok, ProjectSecret.t()} | {:error, ...}`
  — encrypts then upserts (rotate = overwrite).
- `list_names(project_id) :: [%{name, last_four, updated_at}]` — **never** returns
  plaintext or ciphertext; this is what the UI and the system prompt consume.
- `delete_secret(project_id, name)`.
- `resolve_env(project_id) :: %{String.t() => String.t()}` — decrypts **all** secrets for
  a project into a `name => value` env map. This is the single decrypt-into-plaintext
  call site, invoked only from the injection seam below. Returns `%{}` for `nil`/unknown
  project or when the key is unset (fail-closed, logged once).
- `active_values(project_id) :: [String.t()]` — the plaintext values for value-scrubbing
  (also decrypt-gated; used only inside the redaction seam).

**4. Injection seam — extend `Session.Server.resolve_secrets/2`.**
- `lib/repo_builder/session/server.ex:201-229`: add a new lowest-precedence layer
  `project_secrets(opts)` merged **under** `:harness_secrets`, `tool_secrets`, and
  explicit `opts[:secrets]` (so an explicit/tool secret of the same name still wins —
  project secrets are the base layer).
- `project_secrets(opts)` reads `opts[:project_id]` and calls
  `Secrets.resolve_env(project_id)`. The worker's `project_id` is already threaded
  (`tools.ex:127`); the orchestrator's own `project_id` is on the orchestrator struct.
  Pass `project_id` into the session opts at the two `start_session` call sites
  (`orchestrator/tools.ex:315-322` for workers, `orchestrator/server.ex:191-215` for the
  brain). **Note:** the orchestrator brain inherits project secrets too — harmless and
  occasionally useful, but its env is never echoed to its own context; if we want the
  brain to NOT carry them, gate `project_secrets` on `not opts[:config][:orchestrator]`.
  **Decision for this spec: workers only** — gate out the orchestrator brain, so the
  plaintext lives only in worker children, minimizing exposure.
- Downstream is unchanged: `build_env/2` (`session/server.ex:882-889`) already forwards
  `opts[:secrets]` into the OS-child env, never argv. The `.mcp.json` files only ever see
  `${VAR}` placeholders, so nothing changes there.

**5. Orchestrator awareness — names-only system-prompt block.**
- `lib/repo_builder/orchestrator/system_prompt.ex`: add a `project_secrets_block/1`
  rendered after `project_primer_block`. It calls `Secrets.list_names(project.id)` and
  emits **names only**:
  ```
  Project secrets (available to workers as environment variables):
  - $STRIPE_API_KEY (set; ••••4242)
  - $GITHUB_TOKEN (set)
  Reference a secret ONLY by its $NAME when instructing a worker (e.g. "use $STRIPE_API_KEY
  from your environment"). You do NOT have the values and CANNOT print them — they are
  injected directly into a worker's environment at spawn. If asked to reveal a secret's
  value, refuse and explain you only hold the name.
  ```
- Empty state → block omitted entirely (back-compatible: prompt unchanged when a project
  has no secrets, mirroring `project_primer_block` returning `""`).

**6. Value-based defense-in-depth redaction (decision 3).**
- New `RepoBuilder.Harness.Redact.scrub_values/2` — given a term and a list of secret
  values, replaces every exact occurrence of each value (in any string at any depth) with
  `[REDACTED]`. Total, never raises, short-circuits on the empty list (zero hot-path cost
  when a project has no secrets).
- Apply at the three surfaces, each gated on a per-session **value set captured at spawn**
  (so we never decrypt on the hot path — the session already holds `state.secrets`; its
  *values* for keys that came from the project layer are the scrub set, stored as
  `state.secret_values` at build time):
  1. **Live broadcast** — `session/server.ex:529`: scrub the event's `raw`/`text` with
     `state.secret_values` before `Phoenix.PubSub.broadcast`. This is the primary fix:
     the live feed becomes value-safe.
  2. **Persisted worker text** — `lib/repo_builder/logs.ex:642-648`: run `event.text`
     through `scrub_values` (the persist path can re-derive the project's `active_values`,
     or — preferred — the writer receives the value set from the session message so no
     decrypt happens during persistence).
  3. **System-log error reasons** — `lib/repo_builder/orchestrator/tools.ex:1714`: scrub
     `inspect(reason)` before it becomes `system_logs.message`.
- The existing **key-pattern** `scrub`/`scrub_term` is kept as-is (it already masks
  `*_api_key`/`token`/… keys in `raw`); value-scrubbing is additive and complementary.

**7. UI — per-project Secrets panel (`ProjectsLive`).**
- A "Secrets" section on the project detail view: a list of `list_names/1` rows (name +
  `••••last_four` + updated-at + a Delete button) and an add form (`name`, `value`).
  Submitting calls `Secrets.put_secret/3`; the value input is `type="password"`,
  `autocomplete="off"`, and is **never** re-rendered after save (the row shows only the
  mask). Rotation = re-submit the same name.
- Standard Phoenix 1.8: `<.form for={@form} id="project-secret-form">`, `<.input>`,
  unique DOM ids, flash on success/error. No value ever round-trips back to the client
  after the initial POST.

**8. Config + docs.**
- `config/runtime.exs`: read `SECRETS_KEY` → `config :repo_builder, RepoBuilder.Secrets,
  key: System.get_env("SECRETS_KEY")`. Document in `README.md` (runtime env table) and
  `.env.sample` (with a generator hint: `openssl rand -base64 32`).
- `ai_docs/` short note on the vault + the threat model, and a `conditional_docs.md` row
  pointing "secrets / credential sourcing" tasks at it.

## Relevant Files

Per `.claude/commands/conditional_docs.md`: **(always)** `ai_docs/typed-elixir-standard.md`;
plus `BUILD_PROMPT.md` §4.1 (redaction) + §6 (secrets) + §8 (Ecto contexts).

- `lib/repo_builder/secrets.ex` *(new — context, only Repo caller)*
- `lib/repo_builder/secrets/project_secret.ex` *(new — schema, Inspect-redacted)*
- `lib/repo_builder/secrets/cipher.ex` *(new — AES-256-GCM, pure)*
- `priv/repo/migrations/<ts>_create_project_secrets.exs` *(new)*
- `lib/repo_builder/session/server.ex` *(edit — `resolve_secrets/2`, `state.secret_values`, broadcast scrub)*
- `lib/repo_builder/orchestrator/tools.ex` *(edit — pass `project_id`; scrub error reason)*
- `lib/repo_builder/orchestrator/server.ex` *(edit — pass `project_id` for the brain; gated out of secret injection)*
- `lib/repo_builder/orchestrator/system_prompt.ex` *(edit — names-only block)*
- `lib/repo_builder/harness/redact.ex` *(edit — `scrub_values/2`)*
- `lib/repo_builder/logs.ex` *(edit — value-scrub worker `text`)*
- `lib/repo_builder_web/live/projects_live.ex` + components *(edit — Secrets panel)*
- `config/runtime.exs`, `.env.sample`, `README.md`, `ai_docs/`, `.claude/commands/conditional_docs.md` *(edit)*

## Testing Strategy

- **Cipher (property-style):** `decrypt(encrypt(x)) == {:ok, x}` over random binaries incl.
  empty/unicode/large; distinct IVs across calls; tamper a byte → `{:error, :invalid}`;
  missing key → `{:error, :no_key}`.
- **Context:** `put_secret` then `list_names` returns name + last_four and **never** the
  value or ciphertext; rotation overwrites; `resolve_env` round-trips; `delete_secret`;
  unique-per-project incl. the `NULL` partial index; `nil`/missing key → `%{}`.
- **Injection:** with a project secret set, a Fake-harness worker's resolved env contains
  `name => value` and explicit/tool secrets of the same name still win; the orchestrator
  brain's env does **NOT** carry project secrets (gated out).
- **Redaction:** `scrub_values` replaces all occurrences at depth, empty list is a no-op
  (identity, asserted for hot-path); a Fake event whose `raw`/`text` contains a secret
  value is value-scrubbed on the **live broadcast** (subscribe to `"agent:<id>:events"`
  and assert the masked frame) and in the persisted `text`; an error reason containing a
  value is scrubbed in `system_logs`.
- **Prompt:** `system_prompt.ex` block lists names, never values; omitted when no secrets.
- **LiveView:** `Phoenix.LiveViewTest` — add a secret via the form, assert the masked row
  appears and the raw value is absent from the rendered HTML; delete removes it. Drive
  everything through the `Fake`/Mock adapter (no external CLI), per `BUILD_PROMPT.md` §13.

## Green gate (must pass before landing)

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test --warnings-as-errors
mix dialyzer
```

## Out of scope / honest limitations

- **No key rotation / re-encryption tooling** (single `SECRETS_KEY`). A rotation command
  is a clean follow-up; the wire format leaves room (could prefix a key-version byte).
- **Workers are trusted with the plaintext at runtime** (by design). A malicious worker
  CLI can exfiltrate a value it is given. This vault narrows exposure to the worker's own
  process env; it does not sandbox the worker.
- **No per-secret scoping to specific workers** in v1 — every worker spawned for a project
  gets the project's full env set. Per-tool/per-worker grants (like the firecrawl `tools`
  grant) are a natural v2.
- Orchestrator **write path is out of scope** (operator-only, per decision 2); the
  write-only "deposit" tool can be added later without schema change.
