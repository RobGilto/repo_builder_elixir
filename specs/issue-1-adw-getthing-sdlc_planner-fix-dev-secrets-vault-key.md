# Bug: Secrets vault not configured in dev — secret deposit (and external-API provisioning) fails

## Metadata
issue_number: `1`
adw_id: `getthing`
issue_json: `{"title":"Could not deposit secret: secrets vault is not configured (set the SECRETS_KEY env var to enable it)","body":"When registering an external MCP/API (e.g. Pixellab https://api.pixellab.ai/mcp, http transport, Authorization: Bearer <token>) on the Registered APIs settings panel and then depositing its vault secret (PIXELLAB_API_KEY), the deposit fails with the red flash: 'Could not deposit secret: value secrets vault is not configured (set the SECRETS_KEY env var to enable it); name can't be blank'. The registered row shows 'PIXELLAB_API_KEY (missing)'. Expected: depositing the secret works out of the box in local dev so the worker can be provisioned the API."}`

## Bug Description
On the **Registered APIs** settings panel (issue-external-api-mcp-provisioning), an operator registers an external MCP server (Pixellab: `http` transport, `auth_scheme: bearer`, `secret_name: PIXELLAB_API_KEY`) and then uses the **Deposit a secret into the vault** form to store the bearer token. The deposit fails with a red flash:

> Could not deposit secret: value secrets vault is not configured (set the SECRETS_KEY env var to enable it); name can't be blank

The registration row then shows `PIXELLAB_API_KEY (missing)`, so the `${PIXELLAB_API_KEY}` placeholder written into a provisioned worker's `.mcp.json` would never expand.

- **Expected:** In local dev, depositing a vault secret succeeds (masked, never plaintext), the registration shows the secret as present (✓), and a provisioned worker receives the token in its child env.
- **Actual:** Every deposit fails because the AES-256-GCM vault has no master key configured in the dev environment, so `RepoBuilder.Secrets.Cipher` is fail-closed (`{:error, :no_key}`). The entire per-project secrets vault — and therefore the external-API provisioning feature that depends on it — is unusable in dev out of the box.

(The trailing `name can't be blank` is a secondary, cosmetic artifact: the operator left the **Secret name** field empty in that attempt, so the changeset also failed `validate_required([:name, ...])`. The *blocking* failure is the unconfigured vault, which fails even with a correct name.)

## Problem Statement
The per-project encrypted secrets vault requires a 32-byte base64 master key at
`config :repo_builder, RepoBuilder.Secrets, key: <base64>`. That key is provided in
`config/test.exs` (a static test key) and in `config/runtime.exs` (from the `SECRETS_KEY`
OS env var, guarded). **`config/dev.exs` provides no key**, and `SECRETS_KEY` is unset in
a normal `mix phx.server` dev session — so `RepoBuilder.Secrets.Cipher.master_key/0`
returns `{:error, :no_key}` and every `Secrets.put_secret/3` (the deposit write path,
shared by the project-secrets panel and the new Registered-APIs panel) fails fail-closed.

## Solution Statement
Add a clearly-labeled, **dev-only** static vault master key to `config/dev.exs`, mirroring
the existing `config/test.exs` key and the `WEBHOOK_SECRET` dev/test precedent. The
`config/runtime.exs` guard (`if secrets_key = System.get_env("SECRETS_KEY")`) already
overrides this default whenever an operator exports their own `SECRETS_KEY`, so the change
is safe and non-clobbering. Production is unaffected: prod has no dev.exs and falls back to
the runtime env var (vault stays correctly disabled/fail-closed in prod when `SECRETS_KEY`
is unset).

This is a one-line config fix that re-enables the whole vault feature locally. Add a
config-level regression test that evaluates `config/dev.exs` and asserts a usable
(32-byte base64) vault key is present, so the missing-dev-key regression cannot recur.

## Steps to Reproduce
1. Ensure `SECRETS_KEY` is **not** exported in the shell (`unset SECRETS_KEY`).
2. Start the app in dev: `mix phx.server` and open `http://localhost:4000`.
3. Open **Settings → Registered APIs**.
4. Register a user-scope API: name `pixellab`, transport `http`, url
   `https://api.pixellab.ai/mcp`, auth scheme `bearer`, secret name `PIXELLAB_API_KEY`.
5. In **Deposit a secret into the vault**, set Scope `User (platform)`, Secret name
   `PIXELLAB_API_KEY`, Value `<any token>`, click **Deposit**.
6. Observe the red flash: *"Could not deposit secret: value secrets vault is not configured
   (set the SECRETS_KEY env var to enable it); …"*. The row shows `PIXELLAB_API_KEY (missing)`.

Reproduce headlessly (root-cause confirmation):
- `elixir -e 'IO.inspect(get_in(Config.Reader.read!("config/dev.exs", env: :dev), [:repo_builder, RepoBuilder.Secrets]))'` → prints `nil` (no dev key).

## Root Cause Analysis
`RepoBuilder.Secrets.Cipher.master_key/0` reads
`Application.get_env(:repo_builder, RepoBuilder.Secrets, [])[:key]`. The key is wired only
in two places:

- `config/test.exs:204` → `config :repo_builder, RepoBuilder.Secrets, key: "AAAA…AAA="`
  (static, so the test suite's vault works — which is why the existing LiveView panel test
  deposits secrets successfully).
- `config/runtime.exs:57-58` → from `System.get_env("SECRETS_KEY")`, guarded so it does not
  clobber a config-provided key.

`config/dev.exs` has **no** `RepoBuilder.Secrets` key. The cipher's moduledoc and the
runtime.exs comment both assert the design "mirrors WEBHOOK_SECRET" and is "Guarded so it
never clobbers a dev/test config key" — i.e. a **dev** config key was assumed to exist but
was never added. With no key in dev and `SECRETS_KEY` unset, `master_key/0` returns
`{:error, :no_key}`, `encrypt/1` returns `{:error, :no_key}`, and `put_secret/3` surfaces
the `key_error_changeset/2` "secrets vault is not configured" error. The
external-API-provisioning feature is collateral: its `${SECRET}` expansion depends entirely
on the operator being able to deposit the token into this vault.

## Relevant Files
Use these files to fix the bug:

- `config/dev.exs` — **the fix site.** Add the dev-only `config :repo_builder,
  RepoBuilder.Secrets, key: <base64-of-32-bytes>` so the vault is enabled in local dev.
- `config/test.exs` — the existing static-key precedent (line 204) to mirror.
- `config/runtime.exs` — the `SECRETS_KEY` env-var override (lines 51-59); confirms the
  guard means the dev default never clobbers an explicitly-exported operator key.
- `lib/repo_builder/secrets/cipher.ex` — `master_key/0` / `key_present?/0`: the fail-closed
  `{:error, :no_key}` path that produces the symptom; read to confirm the 32-byte base64
  contract the dev key must satisfy.
- `lib/repo_builder/secrets.ex` — `put_secret/3` + `key_error_changeset/2`: where the
  "secrets vault is not configured" error is surfaced (the deposit write path).
- `lib/repo_builder_web/live/console_live.ex` — `deposit_api_secret` handler (and the
  project-secrets `add_secret` handler): the LiveView caller of `Secrets.put_secret/3`.
- `BUILD_PROMPT.md` — §6 (secrets discipline) / §4.1 (redaction); confirms the
  reference-not-value, fail-closed model the fix must preserve.
- `ai_docs/secrets-vault.md` — the vault threat model; confirms a committed dev key is a
  local-dev convenience only (prod sources the key from the OS env, never from a config
  file).

### New Files
- `test/repo_builder/config/dev_secrets_key_test.exs` — a config-level regression test that
  evaluates `config/dev.exs` via `Config.Reader.read!/2` and asserts the
  `RepoBuilder.Secrets` key exists and decodes to exactly 32 bytes, so the dev vault can
  never silently regress to unconfigured again.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the dev-only vault master key to `config/dev.exs`
- Append a clearly-commented block to `config/dev.exs` (near the bottom, after the
  existing dev config), mirroring `config/test.exs:204` and the `WEBHOOK_SECRET`
  dev/test precedent:
  ```elixir
  # Per-project secrets vault master key for LOCAL DEV ONLY
  # (issue-per-project-encrypted-secrets-vault). Base64 of 32 random bytes. This is a
  # throwaway dev key so the vault works out of the box at http://localhost:4000 (deposit
  # a secret, provision an external API). It is NOT a production secret — prod sources the
  # key from the `SECRETS_KEY` OS env var in config/runtime.exs, which OVERRIDES this when
  # set (the runtime.exs guard never clobbers it). Rotate or remove freely.
  config :repo_builder, RepoBuilder.Secrets,
    key: "ZGV2LW9ubHktc2VjcmV0cy12YXVsdC1rZXktMzJieXRl"
  ```
  - The value must be base64 of EXACTLY 32 bytes (`RepoBuilder.Secrets.Cipher` enforces
    `@key_bytes 32`, else `{:error, :bad_key}`). Generate a fresh one with
    `openssl rand -base64 32` and paste it verbatim; confirm `byte_size(Base.decode64!(key)) == 32`.
- Do NOT modify `config/runtime.exs` — its `if secrets_key = System.get_env("SECRETS_KEY")`
  guard already overrides the dev default when an operator exports their own key.

### 2. Add the config-level regression test
- Create `test/repo_builder/config/dev_secrets_key_test.exs`:
  ```elixir
  defmodule RepoBuilder.Config.DevSecretsKeyTest do
    @moduledoc """
    Regression guard (issue-1): config/dev.exs MUST provide a usable per-project secrets
    vault master key so the vault is enabled in local dev — otherwise every deposit fails
    fail-closed with "secrets vault is not configured" and the external-API provisioning
    feature is unusable out of the box.
    """
    use ExUnit.Case, async: true

    test "config/dev.exs provides a 32-byte base64 vault master key" do
      cfg = Config.Reader.read!("config/dev.exs", env: :dev)
      key = get_in(cfg, [:repo_builder, RepoBuilder.Secrets])[:key]

      assert is_binary(key) and key != "",
             "config/dev.exs must set config :repo_builder, RepoBuilder.Secrets, key: <base64>"

      assert {:ok, raw} = Base.decode64(key)
      assert byte_size(raw) == 32, "the dev vault key must be base64 of exactly 32 bytes"
    end
  end
  ```
- Rationale for a config test (not a `Phoenix.LiveViewTest`): the symptom surfaces in the
  LiveView, but the LiveView logic is correct — it already deposits successfully whenever
  the vault is configured (the existing `test/repo_builder_web/live/test_external_apis_panel_test.exs`
  proves this, because `config/test.exs` sets a key). The bug exists ONLY in the dev
  environment's config, which a test-env LiveView case cannot reproduce (test env always
  has a key, so it would pass before AND after). The honest regression guard is therefore a
  direct assertion on the evaluated `config/dev.exs`.

### 3. Manually confirm the deposit path in dev (Tidewave)
- With the dev key in place, restart the app and reproduce the original steps; the deposit
  should succeed and the row should show the secret present (✓), not `(missing)`.
- Optionally confirm via Tidewave `project_eval` in the running dev app:
  `RepoBuilder.Secrets.Cipher.key_present?()` returns `true`; and
  `RepoBuilder.Secrets.put_secret(nil, "PIXELLAB_API_KEY", "dev-token")` returns
  `{:ok, %RepoBuilder.Secrets.ProjectSecret{}}` (then
  `RepoBuilder.Secrets.list_names(nil)` shows it masked, never the value).
- Optionally capture a screenshot of `http://localhost:4000` (Settings → Registered APIs)
  showing the row's secret as present as visual proof.

### 4. Run the full validation gate
- Run every command in **Validation Commands** below; all must pass with zero
  warnings/errors and zero regressions.

## Validation Commands
Execute every command to validate the bug is fixed with zero regressions.

- `elixir -e 'k = get_in(Config.Reader.read!("config/dev.exs", env: :dev), [:repo_builder, RepoBuilder.Secrets])[:key]; true = is_binary(k); 32 = byte_size(Base.decode64!(k)); IO.puts("dev vault key OK")'`
  — reproduces the root cause check: prints `nil`/crashes BEFORE the fix, prints
  `dev vault key OK` AFTER.
- `mix test test/repo_builder/config/dev_secrets_key_test.exs` — the new regression test
  (fails before the fix, passes after).
- `mix test test/repo_builder_web/live/test_external_apis_panel_test.exs` — the
  external-APIs panel deposit flow still green.
- `mix test test/repo_builder/secrets_test.exs test/repo_builder/session/api_secrets_injection_test.exs`
  — vault + provisioned-secret injection unchanged.
- `mix compile --warnings-as-errors` — compile clean (set-theoretic checker + warnings).
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, including the `@spec` convention.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependency.** `Config.Reader` is part of Elixir's standard library; the fix is a
  single config line plus one config-level test.
- **Why commit a dev key?** It is a throwaway, non-production key (the test env already
  commits one at `config/test.exs:204`). It exists so a fresh `git clone` + `mix phx.server`
  has a working vault for the local single-operator workflow. Production never reads it:
  prod has no `config/dev.exs`, and `config/runtime.exs` sources the real key from the
  `SECRETS_KEY` OS env var (fail-closed/disabled when unset). The runtime guard means an
  operator who DOES export `SECRETS_KEY` in dev silently overrides the committed default.
- **Secondary UX (out of scope, optional follow-up):** the deposit error message conflates
  the unconfigured-vault error with `name can't be blank` when the **Secret name** field is
  empty. A small future enhancement could pre-fill the deposit form's secret name from the
  registration row (one click from `edit`), but that is a usability nicety, not the bug —
  keep this fix surgical to the missing dev vault key.
- **BUILD_PROMPT §6 alignment:** the fix preserves the reference-not-value, fail-closed,
  name-only-exposure model — only the *key source* in dev changes; the encryption,
  redaction, and JIT-decrypt-at-worker-boundary seams are untouched.
```
