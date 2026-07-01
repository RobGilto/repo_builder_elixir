# Feature: Fast-agent MCP smart import for the Registered APIs registry

## Metadata
issue_number: `the`
adw_id: `api`
issue_json: `registry`

## Feature Description
On the **Registered APIs** settings panel (issue-external-api-mcp-provisioning) an
operator today registers an external MCP/API by hand-filling a multi-field form
(name, transport, url/command, args, auth scheme, secret name, …). That is precise but
tedious and error-prone: most MCP servers already ship a canonical config blob (a
Claude-Desktop / `.mcp.json` `mcpServers` map, a single server object, or a vendor's
copy-paste snippet), and operators often just have that JSON on the clipboard.

This feature adds a **Smart import** affordance to the panel: a single textarea where
the operator pastes an MCP config (raw JSON, a Claude-style `mcpServers` map, or even a
free-form description like "register the Pixellab MCP at https://api.pixellab.ai/mcp
with a bearer token"). A **deterministic parser** handles well-formed JSON instantly
(free, offline, fully testable); when the input is fuzzy or structurally incomplete, a
one-shot **Fast-tier agent** (the orchestrator's operator-assigned `fast` roster model,
mirroring `RepoBuilder.Explain`) is dispatched to interpret it. The importer then either:

1. **Drafts a registration** — pre-fills the existing register form with the parsed
   fields (one-click confirm), and auto-registers directly when it is high-confidence and
   passes the changeset; or
2. **Asks one clarifying question** — when something is unclear or missing (e.g. "Is this
   `http` or `sse`?", or "Deposit the bearer token as secret `PIXELLAB_API_KEY` — the
   config didn't include a value"), surfaced as an inline banner above the pre-filled form.

Crucially, the importer is **secret-safe** (BUILD_PROMPT §6, reference-not-value): any
literal token found in the pasted config is stripped locally, never stored on the row,
and never sent to the LLM — it is staged into the existing *Deposit a secret* form for
the operator to confirm. The registration row carries only the secret **name**.

## User Story
As an **operator configuring external APIs for my orchestrators**
I want to **paste an MCP server config (or describe it) and have a fast agent turn it into a registration draft, asking me only about what's genuinely unclear**
So that **I can register an MCP provider in one paste instead of hand-filling eight fields, without ever leaking the auth token into the registry or a model prompt**.

## Problem Statement
Registering an external MCP/API is a manual, multi-field form. The canonical artifact
operators already possess — the server's JSON config — cannot be used directly. There is
no path from "I have this `mcpServers` snippet" to a registered, provision-ready row, and
nothing helps when the snippet is incomplete (missing transport, ambiguous auth, inline
token that must become a vault reference). The existing `RepoBuilder.ExternalApis` context
and `ExternalApi` changeset already encode the *target* contract (closed `transport`/
`auth_scheme` enums, conditional url/command/secret_name requirements, name shape); what's
missing is an ingestion front-end that maps arbitrary MCP config shapes onto that contract.

## Solution Statement
Add a **deterministic-first, agent-fallback** smart-import pipeline that produces an
`ImportResult` (a register-draft or a clarifying question) and feeds it into the *existing*
register/deposit write paths — reusing the `ExternalApi.changeset/2` validation and unique
constraints rather than bypassing them.

- **Deterministic parser** (`RepoBuilder.ExternalApis.McpImport`, pure): recognizes the
  common MCP config shapes — a `{"mcpServers": {name => server}}` map, a bare single-server
  object, and stdio/http/sse variants — and maps them to string-keyed `ExternalApi` params
  plus a *staged* (never-persisted, never-LLM'd) secret value when the config embeds one.
  Returns `{:ok, ImportResult}` for recognized JSON, or `{:needs_agent, hint}` when the
  input isn't structured. This mirrors `RepoBuilder.Plans.Planner`'s "deterministic — fast,
  free, testable" doctrine and works **even with no Fast agent configured**.
- **Fast-agent fallback** (`RepoBuilder.ExternalApis.SmartImport` context + ephemeral
  `SmartImport.Server`): when the parser says `{:needs_agent, _}`, resolve the orchestrator's
  `fast` roster entry via `RepoBuilder.Explain.fast_config/1` and dispatch a one-shot,
  non-persisted harness session (exact mirror of `RepoBuilder.Explain` / `Explain.Server`:
  subscribe to the private agent topic, `broadcast_feed?: false`, no `agent_db_id`, watchdog
  timeout). The agent is constrained to reply with a strict JSON envelope
  (`{"action":"register"|"question", "question":…, "api":{…}}`), which the server parses into
  an `ImportResult` and sends back as `{:smart_import_result, request_id, result}`. The
  runner is injected behind a `:runner` config seam (exactly like
  `RepoBuilder.Workflows.TitleHumanizer`) so tests never hit a model.
- **LiveView integration**: a collapsible *Smart import* block at the top of
  `external_apis_panel` with a `<textarea>` and a "Parse with Fast agent" submit. The
  `smart_import_api` handler runs the deterministic path synchronously (auto-register or
  pre-fill) and, on `{:needs_agent, _}`, flips to a `:running` state and awaits the async
  result. The result pre-fills the register form (`api_form`), stages the secret into the
  deposit form, and/or shows the clarifying question banner — all reusing existing
  `register_api` / `deposit_api_secret` events for the actual writes.

This is additive: no schema/migration change, no change to the provisioning or injection
seams, and the manual register form is untouched.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/external_apis.ex` — the registry context (the ONLY `Repo` caller for
  `external_apis`, BUILD_PROMPT §8). The smart import reuses `create/1`/`update/2`; no new
  `Repo` access is added here.
- `lib/repo_builder/external_apis/external_api.ex` — the schema + `changeset/2` that defines
  the **target contract** the parser must satisfy: closed `transport`
  (`:http|:sse|:stdio`) / `auth_scheme` (`:none|:bearer|:header`) enums, `@name_format`
  (`^[a-z][a-z0-9_-]*$`), `@secret_format` (`^[A-Z][A-Z0-9_]*$`), conditional
  url/command/secret_name requirements. `transports/0` and `auth_schemes/0` enumerate the
  closed sets. The parser maps onto exactly these fields and field shapes.
- `lib/repo_builder/explain.ex` — **the one-shot Fast-agent pattern to mirror.**
  `fast_config/1` resolves the orchestrator's `fast` roster entry to `{harness, provider,
  model}` (reuse it verbatim); `explain/2` shows the request-id correlation + ephemeral
  dispatch shape to copy for `SmartImport.import/2`.
- `lib/repo_builder/explain/server.ex` — the ephemeral `:temporary` GenServer to mirror for
  `SmartImport.Server`: subscribe to `agent:<id>:events` before start, `Session.Supervisor.
  start_session/1` with `broadcast_feed?: false`, accumulate finalized `TextDelta`, prefer
  `Done.final_text`, watchdog timeout, reply to `reply_to` and stop. Copy its structure;
  swap the reply tag to `:smart_import_result` and add JSON parsing of the reply.
- `lib/repo_builder/explain/request.ex` — the request struct to mirror for
  `SmartImport.Request`.
- `lib/repo_builder/workflows/title_humanizer.ex` — the **`:runner` config seam** to mirror
  (`Application.get_env(:repo_builder, __MODULE__)[:runner] || @default`) so the LiveView and
  context tests stub the agent dispatch instead of spawning a session. Also the model of a
  Fast-tier helper that degrades gracefully when no Fast tier is set.
- `lib/repo_builder/plans/planner.ex` — precedent for a "deterministic — fast, free,
  testable" pure model call; the `McpImport` parser follows the same no-LLM-when-possible
  doctrine.
- `lib/repo_builder_web/live/console_live.ex` — the Registered APIs handlers
  (`register_api`, `update_api`, `deposit_api_secret`, `load_external_apis/1`,
  `blank_api_form/0`, `api_form_from/1`, `normalize_api_params/2`, `secret_scope_id/2`) and
  the `explain_selected/2` + `handle_info({:explain_result, …})` async pattern to mirror for
  `smart_import_api` + `handle_info({:smart_import_result, …})`.
- `lib/repo_builder_web/components/console_components.ex` — `external_apis_panel/1` (where the
  Smart import block + question banner go), `api_row/1`, the existing register and deposit
  `<.form>`s whose events the importer reuses.
- `lib/repo_builder/application.ex` — supervision tree; add a
  `RepoBuilder.SmartImportSupervisor` `DynamicSupervisor` next to the existing
  `ExplainSupervisor` / `TitleHumanizerSupervisor`.
- `lib/repo_builder/harness/fake.ex` — the FakeHarness used by the ephemeral `SmartImport.
  Server` test (keyless `harness: "fake"`, deterministic `done` with `final_text`).
- `config/config.exs` / `config/test.exs` — harness registry + Fake-harness defaults;
  add the `SmartImport` `:runner` seam default and the test stub override.
- `BUILD_PROMPT.md` — §4 (event contract / §4.1 redaction), §6 (secrets discipline:
  reference-not-value, fail-closed), §9 (LiveView), §10 (open-identity/closed-contract).
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (always-on row of the
  conditional-docs router): `@spec` on every public function, `typedstruct`/`@enforce_keys`,
  precise types, `{:ok, t()} | {:error, reason()}` over raising, wire-vs-domain boundary.
- `ai_docs/secrets-vault.md` — the per-project encrypted vault + name-only orchestrator
  exposure + threat model; confirms the staged-token-never-persisted/never-LLM'd rule.

### New Files
- `lib/repo_builder/external_apis/import_result.ex` — the `ImportResult` `typedstruct`: the
  shared outcome of both the deterministic parser and the agent (`action`, `api_params`,
  `secret_name`, `secret_value`, `question`, `source`).
- `lib/repo_builder/external_apis/mcp_import.ex` — the **pure** deterministic parser:
  `parse/1 :: {:ok, ImportResult.t()} | {:needs_agent, String.t()} | {:error, reason()}`,
  plus the JSON-extraction (`extract_json/1`, fence-stripping) and shape-mapping helpers.
- `lib/repo_builder/external_apis/smart_import.ex` — the orchestration context:
  `import/2 :: {:ok, ImportResult.t()} | {:ok, {:async, request_id}} | {:error, reason()}`,
  the strict-JSON `build_prompt/1`, and `parse_agent_reply/1`.
- `lib/repo_builder/external_apis/smart_import/request.ex` — the ephemeral request struct.
- `lib/repo_builder/external_apis/smart_import/server.ex` — the ephemeral one-shot runner.
- `test/repo_builder/external_apis/mcp_import_test.exs` — pure-parser unit tests (all shapes).
- `test/repo_builder/external_apis/smart_import_test.exs` — context tests (deterministic
  short-circuit + agent dispatch via the stubbed `:runner` + agent-reply parsing).
- `test/repo_builder/external_apis/smart_import/server_test.exs` — ephemeral runner over the
  Fake harness (mirrors `test/repo_builder/explain/server_test.exs`).
- `test/repo_builder_web/live/test_smart_api_import_test.exs` — `Phoenix.LiveViewTest`
  integration test driving the textarea → assert pre-filled form / question banner /
  auto-registered row / staged secret.

## Implementation Plan
### Phase 1: Foundation
Define the shared `ImportResult` struct and the pure `McpImport` parser — the contract that
both the deterministic and agent paths produce, mapping arbitrary MCP config shapes onto the
existing `ExternalApi.changeset/2` field set. Add unit tests covering every recognized shape
and the secret-staging rule. This phase has **no UI, no LLM, no DB** — it is pure and fully
testable, and already delivers smart import for well-formed JSON.

### Phase 2: Core Implementation
Add the Fast-agent fallback: the `SmartImport` context (deterministic short-circuit, else
resolve `fast_config/1` and dispatch), the ephemeral `SmartImport.Request`/`Server` (mirror
of `Explain`), the supervisor child, the strict-JSON prompt, and the agent-reply parser
(fence-strip + `Jason` + coerce to `ImportResult`). Wire the `:runner` config seam so tests
stub dispatch. Add context + server tests.

### Phase 3: Integration
Add the Smart import UI to `external_apis_panel/1`, the `smart_import_api` handler +
`handle_info({:smart_import_result, …})` + new assigns to `ConsoleLive`, the form-prefill /
question-banner / secret-staging glue (reusing `register_api` / `deposit_api_secret`), and
the LiveView integration test. Run the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Add the `ImportResult` domain struct
- Create `lib/repo_builder/external_apis/import_result.ex` using `TypedStruct`
  (BUILD_PROMPT §3 / typed standard). Fields (all `enforce` where total):
  - `action :: :register | :question`
  - `api_params :: %{optional(String.t()) => term()}` — string-keyed, ready to pass straight
    into `ExternalApi.changeset/2` (keys: `"name"`, `"provider"`, `"transport"`, `"url"`,
    `"command"`, `"args"`, `"auth_scheme"`, `"auth_header"`, `"secret_name"`, `"description"`,
    `"instructions"`, `"metadata"`). Default `%{}`.
  - `secret_name :: String.t() | nil` — the env-var name a bearer/header registration
    references (also present in `api_params["secret_name"]`; surfaced separately to pre-fill
    the deposit form).
  - `secret_value :: String.t() | nil` — a token the parser stripped from the pasted config,
    **staged** for the deposit form. NEVER persisted on the row, NEVER sent to the LLM.
    `enforce: false`.
  - `question :: String.t() | nil` — set when `action == :question`.
  - `source :: :deterministic | :agent` — provenance, for the flash/telemetry.
- Add `@type t` and a `@spec`'d constructor `new/1` (or rely on the struct + `typedstruct`).
- Add a moduledoc citing issue-external-api-mcp-provisioning and the reference-not-value rule.

### 2. Implement the pure deterministic parser `RepoBuilder.ExternalApis.McpImport`
- Create `lib/repo_builder/external_apis/mcp_import.ex`. Pure, total, no `Repo`, no I/O.
- Public API:
  - `@spec parse(String.t()) :: {:ok, ImportResult.t()} | {:needs_agent, String.t()} | {:error, atom()}`
    - `extract_json/1`: trim, strip ```` ```json ```` / ```` ``` ```` fences, `Jason.decode/1`.
      On decode failure → `{:needs_agent, "input is not JSON; interpreting as a description"}`
      (so free-form text routes to the agent), unless empty → `{:error, :empty}`.
    - Recognize shapes:
      - `%{"mcpServers" => map}` (Claude Desktop / `.mcp.json`): if exactly one entry, map it;
        if multiple, return `action: :question` listing the names ("Found N servers: a, b, c —
        paste one at a time, or tell me which to register.") with `api_params` for the first as
        a draft.
      - A bare single-server object (`%{"command" => _}` or `%{"url" => _}` or
        `%{"type"/"transport" => _}`): map directly. Derive `name` from a `"name"` key, else
        `{:needs_agent, "config has no server name"}`.
  - `@spec map_server(String.t(), map()) :: ImportResult.t()` — the per-server mapping:
    - **transport**: from `"transport"`/`"type"` (`"http"|"sse"|"stdio"`), else inferred —
      `command` ⇒ `:stdio`; `url` ending in `/sse` (case-insensitive) ⇒ `:sse`; other `url`
      ⇒ `:http`. Unknown ⇒ leave nil and set a question ("Is this http or sse?").
    - **url/command/args**: copy `"url"`, `"command"`; coerce `"args"` to a `[String.t()]`.
    - **name**: lowercase + replace invalid chars to match `@name_format`
      (`^[a-z][a-z0-9_-]*$`); if it can't be made valid, ask.
    - **auth + secret extraction (secret-safe)**: inspect `"env"` (stdio) and `"headers"`
      (http/sse):
      - `Authorization: Bearer <tok>` header ⇒ `auth_scheme: "bearer"`, `secret_name` derived
        (uppercased `"<NAME>_API_KEY"` or the env key if present), `secret_value: <tok>` staged.
      - A non-Authorization custom header (e.g. `X-Api-Key: <tok>`) ⇒ `auth_scheme: "header"`,
        `auth_header: <HeaderName>`, `secret_name` derived, `secret_value` staged.
      - An `env` var whose name matches `@secret_format` and whose value looks like a token ⇒
        `auth_scheme` per transport norms, `secret_name: <ENV_NAME>`, `secret_value` staged.
      - No credential found ⇒ `auth_scheme: "none"`.
    - Build `api_params` string-keyed. Set `action: :register` when name + transport +
      (url|command) are all present and unambiguous; otherwise `action: :question` with a
      precise one-line `question` and the partial draft retained.
    - `source: :deterministic`. Strip every literal token out of `api_params` — the token lives
      ONLY in `secret_value`.
- Keep all enum values as **strings** in `api_params` (Ecto.Enum casts strings); never put a
  raw token into `api_params` or `metadata`.

### 3. Unit-test the pure parser
- Create `test/repo_builder/external_apis/mcp_import_test.exs` (`async: true`). Cover:
  - Claude `mcpServers` single http server with `url` ⇒ `:register`, transport `http`.
  - stdio server with `command` + `args` ⇒ `:register`, transport `stdio`.
  - sse server (`url` ending `/sse`, or explicit `"type":"sse"`) ⇒ transport `sse`.
  - `Authorization: Bearer <tok>` header ⇒ `auth_scheme "bearer"`, derived `secret_name`,
    `secret_value` staged, **and assert the token is absent from `api_params`** (security).
  - custom header (`X-Api-Key`) ⇒ `auth_scheme "header"`, `auth_header` set.
  - `env`-embedded `PIXELLAB_API_KEY` token ⇒ `secret_name "PIXELLAB_API_KEY"`,
    `secret_value` staged, not in params.
  - multiple servers in `mcpServers` ⇒ `:question` listing names.
  - ambiguous transport (object with neither url nor command, or `url` without a transport
    hint that can't be inferred) ⇒ `:question`.
  - non-JSON free-form text ⇒ `{:needs_agent, _}`; empty string ⇒ `{:error, :empty}`.
  - the produced `api_params` round-trips through `ExternalApi.changeset/2` to a **valid**
    changeset for the happy cases (the parser's output satisfies the real contract).

### 4. Add the `SmartImport.Request` struct and the ephemeral `SmartImport.Server`
- Create `lib/repo_builder/external_apis/smart_import/request.ex` mirroring
  `RepoBuilder.Explain.Request` (`request_id`, `blob`/`prompt`, `harness`, `provider`,
  `model`, `reply_to`). Use `typedstruct enforce: true`.
- Create `lib/repo_builder/external_apis/smart_import/server.ex` mirroring
  `RepoBuilder.Explain.Server`:
  - `:temporary` GenServer under `RepoBuilder.SmartImportSupervisor`.
  - `start/1` via `DynamicSupervisor.start_child/2`; `init` → `{:continue, :launch}`.
  - `handle_continue(:launch, …)`: subscribe to `agent:<agent_id>:events` BEFORE starting;
    `Session.Supervisor.start_session/1` with `agent_id: "smart-import-<request_id>"`,
    `harness`, `prompt`, `model`, `provider`, `cwd: nil`, `broadcast_feed?: false`, and NO
    `agent_db_id`/`orchestrator_db_id` (ephemeral, non-persisted, off the global feed).
  - Accumulate finalized `Event.TextDelta{partial?: false}`; on `Event.Done` prefer
    `final_text`; parse it via `SmartImport.parse_agent_reply/1` into an `ImportResult`
    (`source: :agent`); reply `{:smart_import_result, request_id, {:ok, result}}` to
    `reply_to` and stop. On `Event.Error` / watchdog timeout → `{:error, reason}` and stop.
  - `@watchdog_ms 60_000`; cancel the timer in `terminate/2`.
- These are `@impl true` callbacks (exempt from the `@spec`-on-every-public-fn rule); the
  non-callback helpers carry `@spec`s.

### 5. Implement the `SmartImport` orchestration context + `:runner` seam
- Create `lib/repo_builder/external_apis/smart_import.ex`:
  - `@spec import(Orchestrator.t(), String.t()) :: {:ok, ImportResult.t()} | {:ok, {:async, String.t()}} | {:error, :no_fast_agent | atom()}`
    - First call `McpImport.parse/1`. On `{:ok, result}` (deterministic hit) return it
      synchronously — **this path needs no Fast agent**. On `{:error, reason}` return it.
    - On `{:needs_agent, _hint}`: resolve `Explain.fast_config/1`; on `{:error,
      :no_fast_agent}` propagate it; else build the request and dispatch the runner, returning
      `{:ok, {:async, request_id}}`.
  - `@spec build_prompt(String.t()) :: String.t()` — instruct the model to reply with ONLY a
    JSON object `{"action":"register"|"question","question":"…","api":{name,transport,url,
    command,args,auth_scheme,auth_header,secret_name,provider,description}}`, using the closed
    enum vocabularies (`ExternalApi.transports/0`, `ExternalApi.auth_schemes/0`), to put the
    secret **name** (never a value) in `secret_name`, and to choose `action:"question"` when a
    required field is unknowable. No prose, no fences.
  - `@spec parse_agent_reply(String.t()) :: {:ok, ImportResult.t()} | {:error, atom()}` —
    fence-strip + `Jason.decode` + validate `action`/enum membership; coerce to `ImportResult`
    with `source: :agent`. Malformed reply ⇒ `{:error, :bad_agent_reply}`.
  - `:runner` seam: dispatch through
    `Application.get_env(:repo_builder, __MODULE__)[:runner] || {SmartImport.Server, :start, 1}`
    (mirror `TitleHumanizer.invoke_runner/2`) so tests stub it.
- Add the default seam to `config/config.exs` and a recording stub override in `config/test.exs`
  (mirror the `TitleHumanizer` test config) — OR set it per-test with `Application.put_env`
  (mirror `title_humanizer_test.exs`). Prefer per-test `put_env` to avoid a global test default.

### 6. Register the supervisor child
- In `lib/repo_builder/application.ex`, add
  `{DynamicSupervisor, name: RepoBuilder.SmartImportSupervisor, strategy: :one_for_one}`
  next to `RepoBuilder.ExplainSupervisor` / `RepoBuilder.TitleHumanizerSupervisor`.

### 7. Context + server tests for the agent path
- `test/repo_builder/external_apis/smart_import_test.exs` (`async: false` where it sets env):
  - deterministic short-circuit: a JSON blob returns `{:ok, %ImportResult{source: :deterministic}}`
    WITHOUT dispatching the runner (stub records nothing).
  - `:needs_agent` free-form input with a Fast tier present dispatches the runner (stubbed,
    records `{:dispatched, request}`); with no Fast tier returns `{:error, :no_fast_agent}`.
  - `parse_agent_reply/1`: a well-formed `register` envelope → `ImportResult` (action
    `:register`, params mapped); a `question` envelope → action `:question` with the question;
    fenced JSON (```` ```json ````) is tolerated; garbage → `{:error, :bad_agent_reply}`.
- `test/repo_builder/external_apis/smart_import/server_test.exs` (`use RepoBuilder.SessionCase,
  async: false`, mirror `explain/server_test.exs`): start the server with `harness: "fake"`,
  a Fake model, and a `reply_to: self()`; assert `{:smart_import_result, ^request_id, {:ok,
  %ImportResult{}}}` arrives (the Fake `done.final_text` must be a parseable JSON envelope —
  if the canned Fake text isn't JSON, drive the server's `parse_agent_reply` path by asserting
  on `{:error, :bad_agent_reply}` for the canned non-JSON text, which still proves the runner +
  reply wiring end-to-end). Persisting nothing (no `agent_logs`) is implied by the ephemeral opts.

### 8. Add the Smart import UI to `external_apis_panel/1`
- In `lib/repo_builder_web/components/console_components.ex`, add a collapsible **Smart import
  (Fast agent)** block at the top of `external_apis_panel/1`:
  - a `<form phx-submit="smart_import_api">` with a `<textarea name="blob">` (placeholder:
    "Paste an MCP config (mcpServers JSON, a single server object) or describe the server.
    Tokens are stripped locally and staged for the vault — never stored on the row."), and a
    submit button labeled "Parse with Fast agent".
  - a status region driven by a new `@smart_import` assign:
    `:idle` (nothing), `:running` (spinner "Parsing…"), `{:question, text}` (an inline banner
    with the clarifying question above the pre-filled form), `{:error, msg}` (actionable error,
    e.g. the no-Fast-agent message reused from `no_fast_agent_message/0`).
  - Pass the new assigns through from `ConsoleLive`’s render (`smart_import={@smart_import}`).
- Add `attr :smart_import, :map` (with a sensible default) to the component and thread it from
  the panel caller. Keep the existing register/deposit forms exactly as-is.

### 9. Wire `ConsoleLive` — handler, async result, prefill glue
- New mount assigns:
  `smart_import: %{status: :idle, request_id: nil}` and
  `api_secret_prefill: %{scope: nil, name: nil, value: nil}` (to pre-fill the deposit form).
- `handle_event("smart_import_api", %{"blob" => blob}, socket)`:
  - resolve the current orchestrator (mirror `explain_selected/2`:
    `with id <- orchestrator_id, {:ok, orch} <- Orchestrators.fetch(id)`); the deterministic
    path does not strictly need an orchestrator, but the agent fallback does — if there is no
    orchestrator AND the parser returns `{:needs_agent, _}`, show an actionable error.
  - call `SmartImport.import(orchestrator, blob)`:
    - `{:ok, %ImportResult{action: :register} = r}`: attempt `ExternalApis.create(scoped(r.
      api_params))`; on success → flash "Imported <name>", reset smart_import to `:idle`,
      `load_external_apis/1`, and stage the deposit (`api_secret_prefill`) when `r.secret_value`
      present; on changeset error → pre-fill `api_form` with the draft+errors so the operator
      fixes it (still surfaces the closed-contract validation).
    - `{:ok, %ImportResult{action: :question} = r}`: pre-fill `api_form` from `r.api_params`,
      set `smart_import.status` to `{:question, r.question}`, stage the secret if present.
    - `{:ok, {:async, request_id}}`: set `smart_import` to `%{status: :running, request_id:
      request_id}`.
    - `{:error, :no_fast_agent}` → `{:error, no_fast_agent_message()}`; other `{:error, _}` →
      a generic actionable error.
- `handle_info({:smart_import_result, request_id, result}, socket)` (mirror the
  `{:explain_result, …}` superseded-request guard): when `request_id` matches the live one,
  apply the same `ImportResult` handling as the synchronous branch (register / prefill+question
  / stage secret).
- Helpers (`@spec`'d): `apply_import_result/2` (shared by the sync + async branches),
  `stage_secret_prefill/2`, and reuse `normalize_api_params/2`, `secret_scope_id/2`,
  `blank_api_form/0`, `to_form(changeset, as: :api)`. Pre-fill the deposit form by threading
  `@api_secret_prefill` into the existing deposit `<.form>` field `value`s.
- Scope: the imported row's `project_id` follows the active project the same way `register_api`
  does today (`normalize_api_params/2`); the staged secret's scope defaults to match.

### 10. LiveView integration test
- Create `test/repo_builder_web/live/test_smart_api_import_test.exs` using
  `Phoenix.LiveViewTest` (mount the console on the Settings → Registered APIs tab). Stub the
  `SmartImport` `:runner` (per-test `Application.put_env`) for the agent path, but exercise the
  **deterministic** path with real JSON for the primary assertions (no model needed):
  - Submitting a single-http-server `mcpServers` JSON auto-registers: assert a success flash and
    that the new row renders in the user/project list (`element/2` / `render` contains the name),
    and that the row shows the secret as needing deposit when a bearer token was present.
  - Submitting a bearer-token config stages the secret: assert the deposit form is pre-filled
    with the derived `secret_name` (and the token value is present only in the staged deposit
    field, never rendered into the registry row).
  - Submitting an ambiguous config renders the clarifying-question banner and pre-fills the
    register form (assert the question text + a pre-filled `name` input value).
  - Free-form text with NO Fast agent configured shows the actionable "no Fast agent" message.
  - Free-form text WITH a stubbed runner flips to `:running`, then simulate the async reply
    (`send(view.pid, {:smart_import_result, request_id, {:ok, %ImportResult{…}}})` or trigger
    the recorded stub) and assert the form pre-fills / row registers.
- Optionally capture a Playwright screenshot of `http://localhost:4000` (Settings → Registered
  APIs) showing the Smart import block + a pre-filled draft as visual proof.

### 11. Run the full validation gate
- Run every command in **Validation Commands**; all must pass with zero warnings/errors and
  zero regressions. Optionally verify in the live dev app via Tidewave `project_eval`:
  `RepoBuilder.ExternalApis.McpImport.parse(~s({"mcpServers":{"pixellab":{"url":"https://api.pixellab.ai/mcp","type":"http","headers":{"Authorization":"Bearer sk-x"}}}}))`
  returns an `{:ok, %ImportResult{action: :register, secret_name: "PIXELLAB_API_KEY",
  secret_value: "sk-x"}}` with NO token in `api_params`.

## Testing Strategy
### Unit Tests
- **`McpImport` (pure)** — exhaustive shape coverage (Claude `mcpServers`, single object,
  http/sse/stdio, bearer/custom-header/env-token auth, name sanitization, multi-server
  question, ambiguous-transport question, non-JSON → `:needs_agent`, empty → `:error`), plus a
  **security assertion** that no literal token ever lands in `api_params`, and a
  **contract assertion** that happy-path `api_params` produce a valid `ExternalApi.changeset/2`.
- **`SmartImport` context** — deterministic short-circuit (no runner dispatch), agent dispatch
  via stubbed `:runner`, `{:error, :no_fast_agent}` when the tier is unset, and
  `parse_agent_reply/1` over register/question/fenced/garbage envelopes.
- **`SmartImport.Server`** — ephemeral one-shot over the Fake harness replies
  `{:smart_import_result, request_id, _}` and persists nothing (mirror of the Explain server
  test).
- **LiveView** — the end-to-end deterministic flows + the async agent flow with a stubbed
  runner (see step 10).

### Edge Cases
- Multiple servers in one `mcpServers` map → a single clarifying question, not a silent
  partial import.
- A config that embeds a live token → the token is staged into the deposit form and stripped
  from the row params and the LLM prompt (never persisted, never logged — `broadcast_feed?:
  false`, no `agent_db_id`, redaction seam intact).
- Transport that can't be inferred (object with neither `url` nor `command`) → question.
- A name that can't be coerced to `@name_format` (e.g. starts with a digit) → question.
- No Fast agent configured + free-form input → actionable error (deterministic JSON still works).
- Agent returns malformed / non-JSON / fenced JSON → `{:error, :bad_agent_reply}` (no crash;
  the watchdog also bounds a hung provider to `{:error, :timeout}`).
- A superseded async request (operator submits twice) → only the live `request_id` is applied.
- Duplicate name (already registered) → the reused `register_api`/`create` path surfaces the
  existing unique-constraint changeset error; the importer pre-fills the form with that error.

## Acceptance Criteria
- The Registered APIs panel shows a **Smart import (Fast agent)** block with a textarea and a
  "Parse with Fast agent" button.
- Pasting a well-formed single-server `mcpServers` JSON registers (or one-click pre-fills) a
  valid `external_apis` row with the correct transport/url-or-command/auth_scheme/secret_name —
  **without any Fast agent configured** (deterministic path).
- Any literal token in the pasted config is **staged into the Deposit-a-secret form** (correct
  `secret_name` pre-filled) and is **never** written to the `external_apis` row and **never**
  placed in the LLM prompt; the registry row references the secret by name only.
- Fuzzy / incomplete input dispatches the orchestrator's Fast tier (one-shot, non-persisted,
  off the global feed) and yields either a pre-filled draft or a single inline clarifying
  question.
- With no Fast tier configured, free-form input shows the actionable "no Fast agent" message;
  structured JSON still imports.
- All new public functions have `@spec`s; structs use `typedstruct`/`@enforce_keys`; the parser
  is pure and total; no new `Repo` access outside the `ExternalApis` context.
- `mix compile --warnings-as-errors`, `mix test --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo --strict`, and `mix dialyzer` all pass with zero new warnings,
  zero regressions.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix test test/repo_builder/external_apis/mcp_import_test.exs` — the pure parser (all shapes +
  the no-token-in-params security assertion + changeset round-trip).
- `mix test test/repo_builder/external_apis/smart_import_test.exs` — context: deterministic
  short-circuit, agent dispatch via stubbed runner, `parse_agent_reply/1`, no-Fast-agent.
- `mix test test/repo_builder/external_apis/smart_import/server_test.exs` — ephemeral runner over
  the Fake harness, persisting nothing.
- `mix test test/repo_builder_web/live/test_smart_api_import_test.exs` — the LiveView smart-import
  flow (auto-register, secret staging, question banner, async agent path).
- `mix test test/repo_builder/external_apis_test.exs test/repo_builder/orchestrator/external_apis_tools_test.exs test/repo_builder_web/live/test_external_apis_panel_test.exs`
  — the existing registry + provisioning + panel tests still green (no regression).
- `mix compile --warnings-as-errors` — compile clean (set-theoretic checker + warnings).
- `mix test --warnings-as-errors` — full ExUnit suite, zero failures.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, including the `@spec` convention.
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependency.** `Jason` is already a dep (used across the harness wire layer); the
  parser and agent-reply decoder use it. No migration — the feature maps onto the existing
  `external_apis` schema and the existing register/deposit write paths.
- **Why deterministic-first.** Most MCP configs are structured JSON; parsing them with a pure
  function is free, offline, instant, and exhaustively testable (mirroring
  `RepoBuilder.Plans.Planner`). The Fast agent is the fallback for genuinely fuzzy input — and
  because the deterministic path needs no model, smart import works on a fresh install before
  any Fast tier is assigned.
- **Security posture (BUILD_PROMPT §6 / `ai_docs/secrets-vault.md`).** The reference-not-value
  rule is preserved end-to-end: the parser strips tokens locally into `secret_value` (staged
  for the deposit form), never into `api_params`/`metadata`; the agent prompt is built to carry
  only the secret **name**; the ephemeral session runs with `broadcast_feed?: false` and no
  persistence, and the `Harness.Redact` seam covers raw-chunk logging. Document in the textarea
  placeholder that operators may paste config with or without a live token — either way the row
  never holds the value.
- **Reuse over rebuild.** The actual DB writes go through the existing
  `ExternalApis.create/1`/`update/2` + `ExternalApi.changeset/2` (closed-contract validation,
  unique constraints) and the existing `deposit_api_secret` event — the importer only produces
  drafts and pre-fills, so the closed `transport`/`auth_scheme` contract and the
  name/secret-format validations are enforced exactly once, in one place.
- **Future considerations (out of scope):** auto-registering ALL servers from a multi-server
  `mcpServers` map in one action; fetching the provider's `doc_urls`/`allowed_tools` via the
  agent; a "test connection" probe after import; importing from a URL the operator pastes
  (fetch-then-parse). Each is additive on top of the `ImportResult` contract.
```
