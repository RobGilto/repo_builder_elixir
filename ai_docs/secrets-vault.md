# Per-project encrypted secrets vault

Operators deposit secret values (API keys, tokens, passwords) **per project**; worker
agents receive them as environment variables, while the orchestrator can only ever
reference them **by name** (e.g. `$STRIPE_API_KEY`). The value is never in the
orchestrator's LLM token stream, so prompt injection ("print the key") has nothing to
reveal — the property is structural, not promptual.

## Components

- **`RepoBuilder.Secrets.Cipher`** — pure AES-256-GCM via `:crypto.crypto_one_time_aead/7`.
  Wire format `<<iv::96, tag::128, ciphertext::binary>>`, Base64 for the DB column. Random
  12-byte IV per encryption, 16-byte tag, empty AAD. Master key from `SECRETS_KEY`
  (base64 of 32 raw bytes) → `config :repo_builder, RepoBuilder.Secrets, key: …`.
  Fail-closed: `{:error, :no_key}` when unset; never raises.
- **`project_secrets` table / `RepoBuilder.Secrets.ProjectSecret`** — `project_id`
  (nullable = "the platform itself"), `name` (env-var shape `^[A-Z][A-Z0-9_]*$`),
  `ciphertext` (Base64 blob, `@derive {Inspect, except: [:ciphertext]}`), `last_four`
  (masked UI hint only). Unique per `(project_id, name)`; a partial unique index covers the
  NULL/platform scope.
- **`RepoBuilder.Secrets`** — the only `Repo` caller. `put_secret/3` (encrypt + upsert,
  rotate = overwrite), `list_names/1` (names + last_four + updated_at — NEVER plaintext or
  ciphertext), `delete_secret/2`, `resolve_env/1` (the single decrypt-into-`name => value`
  site), `active_values/1` (plaintext values for value-scrubbing).
- **Injection seam** — `Session.Server` merges the decrypted vault as the lowest-precedence
  env layer UNDER `:harness_secrets`, tool secrets, and explicit `opts[:secrets]`. Decrypt
  happens once at spawn; the value never enters argv or `.mcp.json` (placeholders only).
  **Workers only** — the orchestrator brain is gated out (`config[:orchestrator]`), so
  plaintext lives only in worker children.
- **Names-only system prompt** — `SystemPrompt.project_secrets_block/1` lists the names
  (with a `••••last_four` hint); empty state omits the block entirely.
- **Value-based defense-in-depth** — `Harness.Redact.scrub_values/2` replaces every exact
  occurrence of each secret value (any string, any depth) with `[REDACTED]`. Applied at the
  three echo surfaces a *worker* could leak through: the live PubSub broadcast, the
  persisted worker `text`, and orchestrator system-log error reasons. Per-session value set
  captured at spawn (`State.secret_values`) — no hot-path decrypt; empty set is a no-op.

## Threat model

**Defends:** value extraction via the orchestrator LLM (it only sees names);
value-at-rest disclosure (AES-256-GCM column); value leakage into logs / the live feed
(just-in-time decrypt + value-scrubbing); value in argv / process listing (env-only).

**Does NOT defend (by design):** a worker is *trusted with the value at runtime* — it must
use it; a malicious worker CLI could exfiltrate it over the network. The secret lives
decrypted in the worker's OS-child env (`/proc/<pid>/environ`). The `SECRETS_KEY` master
key is as trusted as the host. Same trust boundary as every existing harness credential —
generalized, not weakened.

## Out of scope (v1)

No key rotation / re-encryption tooling (single `SECRETS_KEY`; the wire format leaves room
for a key-version byte). No per-secret scoping to specific workers (every worker for a
project gets the project's full env set). Orchestrator write path is operator-only (a
write-only "deposit" tool can be added later with no schema change).
