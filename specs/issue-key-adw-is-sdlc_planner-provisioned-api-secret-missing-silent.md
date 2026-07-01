# Bug: Provisioned external-API secret silently absent from the worker env — worker burns turns hunting a credential the platform claimed was provisioned

## Metadata
issue_number: `key`
adw_id: `is`
issue_json: `not`

## Bug Description
An orchestrator provisioned the registered external API `pixellab` (an `http`-transport
MCP server, `auth_scheme: bearer`, `secret_name: PIXELLAB_API_KEY`) to a `pi` worker
(`mech-artist`). The orchestrator told the worker, in its `original_ask`, that *"Your
PixelLab API key is in the environment variable `PIXELLAB_API_KEY` (already provisioned)"*.
It was **not** provisioned — `PIXELLAB_API_KEY` was never in the worker's child env.

In `agent_logs` `log_no` **27051–27225** (the referenced range) the worker:
- ran `printenv PIXELLAB_API_KEY` → **empty** (log 27062/27065);
- found the generated `.mcp.json` with `"Authorization":"Bearer ${PIXELLAB_API_KEY}"`
  (log 27072);
- connected to the `pixellab` MCP server (52 tools listed, log 27089) but **every tool
  call returned `401: Missing Authorization header`** (logs 27123, 27138) because the
  `${PIXELLAB_API_KEY}` placeholder expanded to empty;
- then spent **dozens of turns** (and the orchestrator a re-dispatch, logs 27053–27054)
  hunting `~/.bashrc`, `~/.pi`, `.env*`, `~/.config`, `mcp-cache.json`, even attempting a
  raw `curl` with an unexpanded `${PIXELLAB_API_KEY}` — searching for a credential that
  the platform never actually injected and that does not exist anywhere on disk.

- **Expected:** When a worker is provisioned an external API whose `secret_name` is **not
  resolvable** from the vault, the platform surfaces this **loudly and immediately** (a
  persisted, operator-visible signal) rather than spawning the worker with an
  unresolvable `${SECRET}` placeholder and no warning. The operator is told to deposit the
  missing secret; the worker is not sent chasing a ghost credential.
- **Actual:** `RepoBuilder.Session.Server`'s secret-injection seam **silently fail-softs**
  (`resolve_api_secret_values/2` drops the unresolved `secret_name`), the worker is spawned
  with a placeholder that can never expand, and **no warning is emitted anywhere** — to the
  operator, the orchestrator, or the worker. The failure only manifests deep inside the
  worker as an opaque MCP `401`, after large token/turn waste.

## Problem Statement
The provisioning secret-injection path (`Session.Server.api_secrets/1` →
`resolve_api_secret_values/2`, issue-external-api-mcp-provisioning) is **fail-soft by
design**: a provisioned API whose `secret_name` is missing from the project + platform
vault is dropped, leaving the `${SECRET}` placeholder literal. That fail-soft is correct
as a *security* default (never inject a half-resolved value), but it is a **silent blind
spot**: nothing records or signals that a worker was provisioned an API it cannot actually
authenticate to. The result is a confusing `401` deep in the worker, wasted turns, and an
orchestrator that confidently (and wrongly) tells the worker the key is "already
provisioned".

The bug is **not** that the secret resolves incorrectly — it is that the platform provides
**no signal** when a provisioned secret is absent.

## Solution Statement
Make the missing-secret condition **loud and persisted at spawn**, without weakening the
fail-soft security posture. At the single harness-agnostic seam where the child env is
assembled (`RepoBuilder.Session.Server`), compute the set of provisioned-API
`secret_name`s that did **not** resolve into the merged child env, and for each, dispatch a
**non-terminal** `RepoBuilder.Harness.Event.Status` event (new `kind: :missing_secret`)
plus a `Logger.warning`. This:

1. persists an operator-visible, queryable row in `agent_logs` (via the existing
   `dispatch/2` → `Logs.Writer` path) the moment the worker spawns — so the operator
   immediately sees *"provisioned API `pixellab` references vault secret `PIXELLAB_API_KEY`
   which is missing — deposit it"* instead of decoding a `401`;
2. costs nothing on the happy path (no missing secrets ⇒ zero events, byte-identical
   behavior);
3. is harness-agnostic — it fires identically for `claude` and `pi` workers because both
   spawn through `Session.Server`.

As a bounded second part (directly prevents the *wasted-turns* symptom), when one or more
provisioned secrets are missing, **prepend a single clear warning line to the worker
prompt** so the worker does not chase a non-existent credential:
*"NOTE: the following provisioned API secret(s) are NOT available in your environment and
their MCP auth will fail: PIXELLAB_API_KEY. Do not search for them; report the missing
secret and stop."* This is a one-line, opt-in (only-when-missing) prompt prefix — the
prompt is byte-identical when nothing is missing.

The fix is surgical: it adds detection + signalling at one existing seam and **does not
change** the resolution logic, the fail-soft drop, the redaction model, or the `${SECRET}`
expansion mechanism.

## Steps to Reproduce
1. Ensure the dev vault key is configured (issue-1 fix — `config/dev.exs` has
   `config :repo_builder, RepoBuilder.Secrets, key: <base64-32>`), so deposits *can*
   succeed but the operator has **not** deposited the API's secret.
2. Register a user/platform-scope external API: name `pixellab`, transport `http`, url
   `https://api.pixellab.ai/mcp`, auth scheme `bearer`, secret name `PIXELLAB_API_KEY`,
   status `active`. **Do not** deposit `PIXELLAB_API_KEY` into the vault.
3. Have an orchestrator `command_agent` a worker with `config["apis"] = ["pixellab"]`
   (any provider/harness; the original incident used `pi`/`zai`).
4. Observe: the worker spawns with no error; `printenv PIXELLAB_API_KEY` is empty; the
   generated `.mcp.json`/`.pi-mcp.json` carries `Bearer ${PIXELLAB_API_KEY}`; the pixellab
   MCP server connects but every tool call returns `401: Missing Authorization header`; and
   **nothing in the console feed or `agent_logs` warns that the secret was missing**.

Headless root-cause confirmation (in the live dev app / Tidewave `project_eval`):
```elixir
# The provisioned API resolves...
RepoBuilder.ExternalApis.fetch_by_names("<worker_project_id>", ["pixellab"])
|> RepoBuilder.ExternalApis.Provisioning.secret_keys()
# => [{"pixellab", "PIXELLAB_API_KEY"}]

# ...but the merged child env carries NO PIXELLAB_API_KEY (fail-soft drop):
RepoBuilder.Session.Server.resolve_secrets(
  [project_id: "<worker_project_id>", config: %{"apis" => ["pixellab"]}],
  "pi"
) |> Map.has_key?("PIXELLAB_API_KEY")
# => false   (and today: no warning is emitted anywhere)
```

Confirm the DB precondition (the secret is genuinely absent):
- `execute_sql_query`: `select name, project_id from project_secrets;` → no
  `PIXELLAB_API_KEY` row (in the incident, only `OPENAI_API_KEY` for an unrelated project).
- `select name, project_id, secret_name, status from external_apis;` → the `pixellab` row
  exists, platform-scope (`project_id` NULL), `active`, `secret_name = PIXELLAB_API_KEY`.

## Root Cause Analysis
The secret-injection seam is in `lib/repo_builder/session/server.ex`:

- `merge_secrets/3` (line ~241) folds `api_secrets(opts)` into the worker's child env.
- `api_secrets/1` (line ~264) gathers the provisioned `{server, secret_name}` pairs via
  `ExternalApis.fetch_by_names/2` → `Provisioning.secret_keys/1`, then calls
  `resolve_api_secret_values/2`.
- `resolve_api_secret_values/2` (line ~285) builds
  `vault = Map.merge(Secrets.resolve_platform_env(), Secrets.resolve_env(project_id))`
  and, for each `{_server, secret_name}`, keeps the pair **only if** `Map.get(vault,
  secret_name)` is non-nil:
  ```elixir
  for {_server, secret_name} <- keys,
      value = Map.get(vault, secret_name),
      not is_nil(value),          # <-- a missing secret is SILENTLY dropped here
      into: %{},
      do: {secret_name, value}
  ```

When `PIXELLAB_API_KEY` is absent from both the platform vault and the project vault, the
comprehension's guard drops it. The worker's env therefore never contains the key, but the
generated MCP config (`Provisioning.mcp_servers/1` →
`server_spec/1`/`auth_headers/1`, and `harness/pi.ex` `worker_mcp_args/1` writing
`.pi-mcp.json`; the claude path writes `.mcp.json`) still emits the literal
`Bearer ${PIXELLAB_API_KEY}` placeholder. At read time the harness expands `${...}` from
the (empty) child env → an empty/absent `Authorization` header → `401`.

The fail-soft drop is intentional and correct (a partially-resolved credential must never
be injected — BUILD_PROMPT §6). The **defect** is the absence of any signal: the platform
has all the information at spawn time to know that a *provisioned* API's required
`secret_name` did not resolve, yet it emits nothing. The orchestrator compounds the
confusion by asserting in the worker charter that the key is "already provisioned".

Root cause, precisely: **`Session.Server` drops an unresolved provisioned secret with no
observable signal (no event, no log, no worker hint)**, so a foreseeable misconfiguration
(API registered + provisioned, secret not deposited) degrades into an opaque downstream
`401` and large wasted worker effort.

## Relevant Files
Use these files to fix the bug:

- `lib/repo_builder/session/server.ex` — **the fix site.** `api_secrets/1` /
  `resolve_api_secret_values/2` compute the resolved provisioned secrets; `merge_secrets/3`
  and `build_state/2` assemble `state.secrets`; `handle_continue(:spawn, state)` (line
  ~332) spawns the child and is where the missing-secret `Status` events should be
  dispatched (worker-only, before `spawn_child/5`); `dispatch/2` (line ~635) is the
  existing persist+broadcast path; `error_event/3` is the pattern to mirror for a
  non-terminal builder. Add a `missing_api_secrets/2` helper and emit per-missing
  `Event.Status` events.
- `lib/repo_builder/harness/event.ex` — `Event.Status` (line ~122) is the **non-terminal**
  signal carrier. Add `:missing_secret` to its `:kind` union so the new event is typed and
  queryable (and so the gradual type checker + Dialyzer stay green).
- `lib/repo_builder/external_apis/provisioning.ex` — `secret_keys/1` yields the
  `{server, secret_name}` pairs whose absence we detect; read to confirm the pair shape and
  the `auth_scheme != :none` gate (a public `:none` API contributes no pair, so it is
  correctly never flagged).
- `lib/repo_builder/external_apis.ex` — `fetch_by_names/2` / `list_in_scope_for/1`: the
  provisioned-row resolution (platform + project, project shadows platform) the detection
  must mirror exactly so scope semantics match injection.
- `lib/repo_builder/secrets.ex` — `resolve_env/1` + `resolve_platform_env/0`: the vault
  resolvers; confirms the merged-vault key set the detection compares against (do not change
  these — detection must reuse the *same* merged env that `merge_secrets/3` produced, i.e.
  compare against `state.secrets`, to avoid a second decrypt and to stay consistent with
  precedence/overrides).
- `lib/repo_builder/harness/pi.ex` — `worker_mcp_args/1` (line ~121) writes `.pi-mcp.json`
  with the `${SECRET}` placeholder; confirms the pi worker path that produced the incident
  (the fix is harness-agnostic in `Session.Server`, but this shows why pi 401'd).
- `lib/repo_builder/harness/claude.ex` — the claude analogue writing `.mcp.json`; confirms
  the same `Session.Server` seam covers both harnesses.
- `lib/repo_builder/session/logs.ex` (and `logs/writer.ex`) — the persist path
  `dispatch/2` uses; confirm a `Status` event with `kind: :missing_secret` persists a
  normal `agent_logs` row (it should, via `record_for/2`).
- `BUILD_PROMPT.md` — §4 (event contract, the `Status` non-terminal signal) + §4.1
  (redaction) + §6 (secrets discipline, fail-closed/fail-soft, name-only exposure);
  confirms the fix must preserve the reference-not-value, never-inject-a-partial-credential
  model and only *add* an observability signal.
- `ai_docs/secrets-vault.md` — the vault threat model + name-only orchestrator exposure;
  confirms surfacing the *name* of a missing secret (never its value) is allowed and is the
  correct operator signal.

### New Files
- `test/repo_builder/session/missing_api_secret_signal_test.exs` — a unit test of the new
  detection helper (`missing_api_secrets/2` or equivalent): given a provisioned API whose
  `secret_name` is absent from the merged env, it returns that `{api, secret_name}`; given
  the secret present, it returns `[]`; an orchestrator session and a `:none`-auth API
  return `[]`. Asserts the fail-soft drop is unchanged AND a missing secret is now
  detected.
- `test/repo_builder/session/missing_api_secret_event_test.exs` — an integration test (a
  `RepoBuilder.SessionCase`-style test driving `Session.Server` with the FakeHarness) that
  spawns a worker provisioned an API with a missing vault secret and asserts a persisted /
  broadcast `Event.Status{kind: :missing_secret}` naming `PIXELLAB_API_KEY` is emitted; and
  that a worker whose secret IS deposited emits **no** such event (happy-path byte-identity).

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Read the spec/docs slice for this seam
- Read `BUILD_PROMPT.md` §4 (event contract — `Status` is the canonical non-terminal
  signal), §4.1 (redaction), §6 (secrets discipline: fail-soft, never inject a partial
  credential, name-only exposure). Read `ai_docs/secrets-vault.md` (name-only exposure
  permits naming a *missing* secret, never its value).
- Reproduce the failure live first (Tidewave `project_eval` snippet in **Steps to
  Reproduce**) to confirm `resolve_secrets/2` drops `PIXELLAB_API_KEY` and that nothing is
  emitted today; capture the `agent_logs`/`project_secrets`/`external_apis` state with
  `execute_sql_query` as the documented precondition.

### 2. Add the `:missing_secret` kind to `Event.Status`
- In `lib/repo_builder/harness/event.ex`, extend the `Event.Status` `:kind` union
  (currently `:retry | :init_detail | :plugin_install | :rate_limit`) with
  `:missing_secret`. Keep `detail :: map()` as the carrier for
  `%{api: name, secret_name: name}` (NEVER the value). Update the moduledoc one-liner to
  mention the new kind.
- Verify no normalizer or consumer pattern-matches the closed `:kind` set exhaustively in a
  way that would now warn (grep `kind:` / `%Event.Status{`); if a `case` exists, add the
  new clause (default/passthrough) so the set-theoretic checker + Dialyzer stay green.

### 3. Add the detection helper in `Session.Server`
- In `lib/repo_builder/session/server.ex`, add a `@spec`'d, total helper that, given the
  spawn `opts`/state and the already-merged child env (`state.secrets`), returns the list
  of provisioned `{api_name, secret_name}` pairs whose `secret_name` is **absent** from the
  merged env. Reuse the EXISTING resolution — do not decrypt a second time:
  ```elixir
  @spec missing_api_secrets(map(), %{optional(String.t()) => String.t()}) ::
          [{String.t(), String.t()}]
  defp missing_api_secrets(config, secrets) when is_map(config) and is_map(secrets) do
    if orchestrator_config?(config) do
      []
    else
      names = config["apis"] || []

      project_id_unused = ...  # see note below
      # Resolve the SAME provisioned rows api_secrets/1 used, then keep only the
      # {server, secret_name} pairs whose secret_name is not a key of `secrets`.
    end
  end
  ```
  - Mirror `api_secrets/1`'s scope EXACTLY: `ExternalApis.fetch_by_names(project_id, names)`
    → `Provisioning.secret_keys/1` → keep pairs where `not Map.has_key?(secrets, secret_name)`.
    Pass `project_id` through (the helper needs the worker's `project_id`; thread it from
    `opts`/state rather than re-deriving). Gate to workers only via
    `orchestrator_config?/1` (orchestrators never provision — they hold no token).
  - Public-API correctness: `Provisioning.secret_keys/1` already excludes `auth_scheme:
    :none` and blank `secret_name`, so a public API can never be falsely flagged. Confirm
    with a test case.

### 4. Emit a non-terminal `Status` event (and a `Logger.warning`) per missing secret at spawn
- Add a small builder mirroring `error_event/3`:
  ```elixir
  @spec missing_secret_event(State.t(), String.t(), String.t()) :: Event.Status.t()
  defp missing_secret_event(state, api_name, secret_name) do
    %Event.Status{
      harness: state.harness,
      kind: :missing_secret,
      detail: %{api: api_name, secret_name: secret_name},
      raw: %{
        "message" =>
          "provisioned API #{api_name} references vault secret #{secret_name} which is " <>
            "missing — deposit it (Settings → vault) so the worker can authenticate"
      }
    }
  end
  ```
- In `handle_continue(:spawn, %State{} = state)` (line ~332), BEFORE `spawn_child/5`,
  compute `missing_api_secrets(state.config, state.secrets)` and, for each missing pair,
  `dispatch/2` a `missing_secret_event/3` and `Logger.warning(...)`. Fold the dispatched
  state back (`dispatch/2` returns a new `State`) so the spawn continues from the updated
  state. No missing secrets ⇒ no events, no log, byte-identical happy path.
- Keep this NON-terminal: the worker still spawns and runs. (Do not block the spawn — a
  worker provisioned several APIs may legitimately need only some; blocking would be a
  behavior change. The signal is observability, not a gate.)

### 5. (Bounded) prepend a single worker-prompt warning when a provisioned secret is missing
- Still in `handle_continue(:spawn, …)` (or in `build_state/2` when assembling
  `state.prompt`), when `missing_api_secrets/2` is non-empty, prepend ONE line to the
  worker prompt naming the missing secret(s):
  `"NOTE: provisioned API secret(s) not available in your environment (MCP auth will fail): #{names}. Do not search the filesystem for them; report the missing secret and stop."`
  - Prompt is byte-identical when nothing is missing (gate on the non-empty list).
  - This directly prevents the log-27051…27225 symptom (the worker filesystem-grepping for
    a ghost credential). Keep it to a single prepended line — do not restructure the prompt.

### 6. Unit test the detection helper
- Create `test/repo_builder/session/missing_api_secret_signal_test.exs`. Drive the detection
  (via the `@doc false` test seam if you expose one, or by calling `resolve_secrets/2` then
  the helper) for: (a) provisioned API with secret absent ⇒ `[{api, secret_name}]`;
  (b) secret present in vault ⇒ `[]`; (c) orchestrator session ⇒ `[]`; (d) `:none`-auth
  API ⇒ `[]`. Use the existing test vault key (`config/test.exs`) and seed an
  `external_apis` row + (for the present case) a `project_secrets` row.

### 7. Integration test the emitted event
- Create `test/repo_builder/session/missing_api_secret_event_test.exs` using the project's
  `SessionCase`/FakeHarness pattern (see `erlexec-runtime-gotchas` memory + existing
  `test/repo_builder/session/*` tests). Spawn a worker `Session.Server` with
  `config: %{"apis" => ["pixellab"]}` and a registered-but-undeposited `pixellab` API;
  subscribe to `"agent:<id>:events"` and assert a
  `%Event.Status{kind: :missing_secret, detail: %{secret_name: "PIXELLAB_API_KEY"}}` is
  broadcast/persisted. Add the converse: deposit the secret first ⇒ assert **no**
  `:missing_secret` event (happy-path byte-identity).

### 8. Run the full validation gate
- Run every command in **Validation Commands**; all must pass with zero warnings/errors and
  zero regressions, including the new tests (which fail before the fix, pass after).

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- Reproduce BEFORE the fix (root-cause confirmation) — in `iex -S mix` or Tidewave
  `project_eval`, with the `pixellab` API registered and `PIXELLAB_API_KEY` NOT deposited:
  ```elixir
  RepoBuilder.Session.Server.resolve_secrets(
    [project_id: nil, config: %{"apis" => ["pixellab"]}], "pi"
  ) |> Map.has_key?("PIXELLAB_API_KEY")   # => false (secret dropped)
  ```
  AFTER the fix this is still `false` (fail-soft preserved) but the new tests prove a
  `:missing_secret` Status event is now emitted.
- `mix test test/repo_builder/session/missing_api_secret_signal_test.exs` — the new
  detection unit test (fails before the fix, passes after).
- `mix test test/repo_builder/session/missing_api_secret_event_test.exs` — the new emitted
  -event integration test (fails before the fix, passes after).
- `mix test test/repo_builder/external_apis_test.exs test/repo_builder/external_apis/provisioning_test.exs test/repo_builder/secrets_test.exs`
  — provisioning + vault contexts unchanged.
- `mix test test/repo_builder/session/` — the session runtime suite, including any existing
  `api_secrets` injection test, stays green (fail-soft drop + redaction unchanged).
- `mix compile --warnings-as-errors` — compile clean; the gradual set-theoretic type
  checker and `warnings_as_errors` must pass (including the widened `Event.Status` `:kind`
  union).
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, including the "every public function has an `@spec`"
  convention (the new private helpers/builders carry `@spec`s).
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters (the
  new `:missing_secret` kind must be reflected wherever `Event.Status` is matched).

## Notes
- **No new dependency.** The fix reuses `Event.Status` (existing non-terminal signal),
  the existing `dispatch/2` persist/broadcast path, and the existing
  `ExternalApis`/`Provisioning`/`Secrets` resolution. Net change is detection + one event
  type widening + signalling at one seam.
- **Security posture preserved (BUILD_PROMPT §6).** The fail-soft drop is unchanged — a
  partially/un-resolvable credential is still NEVER injected. The new signal carries only
  the secret's **name** (already exposed to the orchestrator by design via
  `ai_docs/secrets-vault.md`'s name-only model), never its value. The redaction seam
  (`scrub_secret_values/2`) is untouched.
- **Harness-agnostic by construction.** Both `pi` (`.pi-mcp.json`) and `claude`
  (`.mcp.json`) workers spawn through `Session.Server`, so fixing it there fixes both. The
  incident was `pi`/`zai`, but the same blind spot existed for claude workers.
- **Why not also "fix" pi's `${...}` http-header expansion?** The logs show pi connected
  the server but 401'd. That is fully explained by the empty env (the secret was never
  injected because it was never in the vault), so there is no provable pi expansion bug to
  fix here — and re-implementing harness MCP-config expansion would violate the "do not
  reimplement a harness" non-goal (BUILD_PROMPT §1/§10). If, after this fix, a *deposited*
  secret still 401s on pi's http transport, that is a SEPARATE issue (pi header-placeholder
  expansion) to be filed and reproduced independently — keep this fix surgical to the
  silent-missing-secret blind spot.
- **Operator-error vs platform bug.** The triggering misconfiguration (API registered +
  provisioned, secret never deposited) is operator error, but the platform turning that
  into an opaque downstream `401` with zero signal — and an orchestrator that *asserts* the
  key is provisioned — is the platform bug. The fix converts a silent blind spot into a
  loud, actionable signal at the earliest possible point (spawn).
- **Related:** issue-1 (`config/dev.exs` vault key) made deposits *possible* in dev; this
  issue is the next failure mode when an API is provisioned but its secret was not
  deposited. The two are complementary (vault enabled vs. vault populated).
