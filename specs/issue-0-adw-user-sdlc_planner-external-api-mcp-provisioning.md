# Feature: Registered External API / MCP Providers — orchestrator-transferred, worker-provisioned

## Metadata
issue_number: `0`
adw_id: `user`
issue_json: `{"title":"Register external API/MCP providers (with prompts + doc URLs) at user scope (all orchestrators) and project scope (the project orchestrator); orchestrator does NOT use them itself — it transfers/provisions them to workers as needed","body":"Support registering APIs and their associated prompts and/or URL documentation so an orchestrator can transfer (not use itself) an MCP server / API to a worker as needed. Example: https://www.pixellab.ai/mcp — registered as `claude mcp add pixellab https://api.pixellab.ai/mcp -t http -H \"Authorization: Bearer xxxxxx-...\"` with docs at https://api.pixellab.ai/mcp/docs. Must be registerable into the system and provisioned on demand to workers."}`

## Feature Description

Today a worker can only be granted research tools from a **closed, hard-coded catalog** (`RepoBuilder.Harness.McpTools`, which knows exactly one tool: `firecrawl`). Adding a new external capability (e.g. the **Pixellab** image-generation MCP at `https://api.pixellab.ai/mcp`) requires an Elixir code edit plus a `:tool_secrets` config entry — there is no operator-facing way to register a new API/MCP server and no way for the orchestrator to discover and **delegate** it to a worker.

This feature introduces a durable, two-scope **External API registry**:

- **User scope ("all orchestrators")** — a platform-wide registration (`project_id IS NULL`) visible to every orchestrator on every project. The Pixellab MCP, registered once, becomes available everywhere.
- **Project scope ("the project orchestrator")** — a registration bound to one project (`project_id = <id>`), visible only to that project's orchestrator and its workers.

Each registration carries:

- **Identity & transport** — a `name` (the MCP server key, e.g. `pixellab`), a `transport` (`http` | `sse` | `stdio`), and the connection details: `url` (for http/sse) **or** `command` + `args` (for stdio, e.g. `npx -y firecrawl-mcp`).
- **Auth** — an optional `auth_scheme` (`bearer` | `header` | `none`) plus the **name of an encrypted-vault secret** (`secret_name`, e.g. `PIXELLAB_API_KEY`) that holds the token. The literal token is **never** stored on the registration row — only the vault reference — reusing the existing AES-256-GCM `RepoBuilder.Secrets` vault.
- **Guidance for the orchestrator/worker** — `description` (a short capability summary), `instructions` (a prompt fragment telling a worker *how* to use the API), and `doc_urls` (a list of documentation URLs, e.g. `https://api.pixellab.ai/mcp/docs`). These are surfaced to the orchestrator so it knows the capability exists and when to delegate, and prepended to the **worker's** charter when provisioned.
- **`allowed_tools`** — the tool-name wildcard(s) the worker may call (default `mcp__<name>__*`).

Critically, the **orchestrator never calls these tools itself** — the orchestrator brain is a delegation-only session (`--disallowedTools`, `--no-builtin-tools`). Instead, the orchestrator **transfers** a registered API to a worker at spawn/command time: `create_agent` / `command_agent` gain an `apis` argument naming which registered servers to provision, and a new `list_apis` MCP tool lets the orchestrator discover what is registered (with the documentation/instructions) so it can decide what to hand off.

The worker spawn path then writes the MCP server into the worker's `.mcp.json` (Claude) / `.pi-mcp.json` (pi) — including HTTP transport with a `Authorization: Bearer ${SECRET}` header — and the vault secret is injected into the worker's child env so the `${SECRET}` placeholder expands at run time.

## User Story

As a **platform operator (and the orchestrator acting on my behalf)**
I want to **register external APIs/MCP servers — with their auth, documentation, and usage prompts — at the user scope (all orchestrators) or a single project's scope, and have the orchestrator hand them to workers on demand**
So that **new capabilities (like the Pixellab image MCP) can be added without code changes, kept out of the orchestrator's own tool surface, and provisioned only to the workers that actually need them — with credentials sourced from the encrypted vault.**

## Problem Statement

1. **No dynamic catalog.** `RepoBuilder.Harness.McpTools` is a closed atom set (`@known %{"firecrawl" => :firecrawl}`). New MCP servers cannot be added at runtime, by an operator, or per-project.
2. **No scoping.** There is no notion of a user-scope vs project-scope external API; the firecrawl grant is global and code-defined.
3. **No orchestrator delegation seam.** The orchestrator cannot discover available APIs or choose to transfer one to a worker; `create_agent`/`command_agent` only understand the hard-coded firecrawl `tools` list.
4. **No place for API documentation/prompts.** The registration's *instructions* (how a worker should use the API) and *doc URLs* have nowhere to live and never reach the orchestrator's decision-making or the worker's charter.
5. **Credentials.** A new API's bearer token must be stored securely (the vault) and injected only into the workers that are actually provisioned the API — not the orchestrator, and not unrelated workers.

## Solution Statement

Add a durable **`RepoBuilder.ExternalApis` context** + `external_apis` table (binary_id PK, JSONB columns, `project_id` nullable for the user/platform scope — mirroring `project_secrets`). A registration references a vault secret by name for auth, never storing the token.

Generalize the worker MCP-grant seam so it is the union of the existing static `McpTools` catalog **and** the dynamic DB registry:

- A new resolver, `RepoBuilder.ExternalApis.Provisioning`, turns a list of *provisioned API names* (resolved against the orchestrator's project scope + user scope) into the same three fragments the adapters already consume: `mcp_servers/1` (JSON `mcpServers` fragment, http/sse/stdio shapes), `allowed_tools/1` (Claude `--allowedTools` patterns), and `secret_keys/1` (`{server_key, env_var}` pairs to fold into the child env).
- The worker spawn paths (`Harness.Claude.worker_mcp_args/1`, `Harness.Pi.worker_mcp_args/1`) **merge** the static firecrawl fragment with the dynamic provisioned fragment — one code change per adapter, then it is data-driven forever.
- The secret injection seam (`Session.Server.merge_secrets/3` → new `api_secrets/1`) resolves each provisioned API's `secret_name` from the **encrypted vault** (`Secrets.resolve_env/1` keyed to the worker's project) and folds it into the worker's child env so `${SECRET}` expands. Workers only (the orchestrator brain stays out, per the existing `orchestrator_session?/1` gate).

The orchestrator delegates via:

- A new **`list_apis`** MCP tool (returns each registration's name/scope/description/instructions/doc_urls/transport — but never the secret) so the orchestrator can discover capabilities and read the usage prompt.
- An **`apis`** array argument on `create_agent` (persisted into the worker's `config["apis"]`) and on `command_agent` (provision at command time), naming which registered servers to transfer to that worker. When provisioned, the API's `instructions` + `doc_urls` are prepended to the worker's system prompt so the worker knows how to use it.
- The orchestrator **system prompt** gains a compact "Registered APIs you may delegate to workers" section listing the available registrations (name + one-line description), so the brain is aware without an explicit `list_apis` round-trip.

Operator UI: a **Registered APIs** settings panel in `ConsoleLive` with a user-scope list (all orchestrators) and a project-scope list (the active project's orchestrator), each supporting register/edit/delete and a secret-deposit field that writes through to the vault.

No new harness, no event-contract change, no new external dependency. Follows the open-identity / closed-contract doctrine (BUILD_PROMPT §10): `transport`/`auth_scheme` are closed `Ecto.Enum`s; `name`/`provider`/`url` are open strings validated at the changeset boundary.

## Relevant Files
Use these files to implement the feature:

- `lib/repo_builder/harness/mcp_tools.ex` — the current closed worker-tool catalog. The **template** for the dynamic resolver's fragment shapes (`mcp_servers/1`, `allowed_tools/1`, `secret_keys/1`). Stays as the static firecrawl catalog; the new provisioning resolver is merged alongside it.
- `lib/repo_builder/harness/claude.ex` — `worker_mcp_args/1` (~line 119) writes the worker `.mcp.json` from `McpTools.mcp_servers/1`. Extend to merge dynamic provisions; `mcp_config_json/1` (~line 71) is the **http+bearer** shape to copy for http/sse transports. `orchestrator_config?/1` gate stays.
- `lib/repo_builder/harness/pi.ex` — `worker_mcp_args/1` (~line 107) writes `.pi-mcp.json`. Same extension as Claude.
- `lib/repo_builder/session/server.ex` — `merge_secrets/3` (~line 240), `tool_secrets/1` (~line 278), `project_secrets/1`/`orchestrator_session?/1` (~line 259-272). Add `api_secrets/1` that resolves each provisioned API's vault secret into the worker child env (workers only). The decrypted vault is already available via `Secrets.resolve_env/1`.
- `lib/repo_builder/secrets.ex` — the encrypted vault context. `put_secret/3`, `list_names/1`, `resolve_env/1`. The registration's `secret_name` references a row here; the UI's secret-deposit writes through `put_secret/3`.
- `lib/repo_builder/orchestrator/tools.ex` — `create_agent/2` (~line 184, persists `config`), `command_agent/2` (~line 380, builds session opts), `worker_session_config/1` (~line 2014). Add `apis` arg handling (`maybe_put_apis/2` mirroring `maybe_put_tools/2` at ~line 2357), the new `list_apis` handler, and prepend provisioned API instructions to the worker `system_prompt` (alongside `prepend_stack_contract`/`with_reporting_clause`).
- `lib/repo_builder/orchestrator/tool_catalog.ex` — `tools/0` (~line 20). Add the `list_apis` tool definition and the `apis` array property on `create_agent`/`command_agent` input schemas.
- `lib/repo_builder/orchestrator/system_prompt.ex` — `build/1`. Add the "Registered APIs you may delegate" section listing the orchestrator's in-scope registrations (name + description), so the brain is aware of what it can transfer. Mirror how secrets names are already surfaced (name-only, never the value).
- `lib/repo_builder/orchestrator.ex` (`RepoBuilder.Orchestrators`) — provides `project_id` for an orchestrator (the scope key). The resolver reads user-scope (`nil`) + the orchestrator's project-scope registrations.
- `lib/repo_builder/projects/project.ex` / `lib/repo_builder/projects.ex` — `project_id` FK target; the project-scope registrations reference it (`on_delete: :delete_all`, like `project_secrets`).
- `lib/repo_builder_web/live/console_live.ex` — the console LiveView. Add the Registered APIs panel events (`register_api`, `update_api`, `delete_api`, `deposit_api_secret`) and assigns (user-scope + project-scope lists). Goes through the `ExternalApis` context, never `Repo`.
- `lib/repo_builder_web/components/console_components.ex` — render the Registered APIs panel (forms + lists). Reference `console_components` patterns for the existing secrets/roster panels.
- `lib/repo_builder/schema.ex` — `use RepoBuilder.Schema` for the new schema (binary_id PK/FK defaults).
- `config/runtime.exs` — `:tool_secrets` / `:harness_secrets` blocks (~line 35-47); referenced only to confirm vault is the source for dynamic API secrets (no new config key required).
- `BUILD_PROMPT.md` — §4.1 (redaction), §6 (secrets), §8 (contexts/Ecto/JSONB/Decimal), §9 (LiveView), §10 (open-identity/closed-contract, "add a capability = data not code").
- `ai_docs/typed-elixir-standard.md` — the enforced typed standard (`@spec` on every public fn, `typedstruct`/`@enforce_keys`, tagged tuples, no raises on expected paths, wire-vs-domain rule 6).
- `ai_docs/secrets-vault.md` — the vault threat model + name-only orchestrator exposure (the registration's auth must follow this).
- `AGENTS.md` — Phoenix v1.8 + LiveView guidelines for the panel.

### New Files

- `lib/repo_builder/external_apis.ex` — `RepoBuilder.ExternalApis` context: the ONLY `Repo` caller for `external_apis`. CRUD + scope resolution (`list_for_scope/1`, `list_in_scope_for/1`, `fetch_by_names/2`). Every public fn `@spec`'d, tagged tuples, no raises.
- `lib/repo_builder/external_apis/external_api.ex` — `RepoBuilder.ExternalApis.ExternalApi` Ecto schema (`typedstruct`/`@enforce_keys` via `use RepoBuilder.Schema`) + `changeset/2`. Closed `Ecto.Enum` `transport`/`auth_scheme`/`status`; open `:string` `name`/`provider`/`url`; JSONB `args`/`doc_urls`/`allowed_tools`/`metadata`.
- `lib/repo_builder/external_apis/provisioning.ex` — `RepoBuilder.ExternalApis.Provisioning`: turns provisioned API rows into adapter fragments (`mcp_servers/1`, `allowed_tools/1`, `secret_keys/1`, `instructions/1`) — the dynamic analogue of `Harness.McpTools`, with per-transport server-spec shapes (http/sse bearer header; stdio command/args).
- `priv/repo/migrations/<ts>_create_external_apis.exs` — `external_apis` table (binary_id PK, nullable `project_id` FK `on_delete: :delete_all`, JSONB columns, partial unique indexes on `(project_id, name)` and platform-`NULL` `name`, mirroring `create_project_secrets.exs`).
- `test/repo_builder/external_apis_test.exs` — context unit tests (scope resolution, changeset validation, secret-name reference, no plaintext on the row).
- `test/repo_builder/external_apis/provisioning_test.exs` — resolver tests (http+bearer fragment shape, stdio fragment, allowed_tools patterns, secret_keys pairs, static+dynamic merge).
- `test/repo_builder_web/live/test_external_apis_panel_test.exs` — `Phoenix.LiveViewTest` integration test: register a user-scope API in the console, assert it renders in both scopes appropriately, deposit its secret, and assert the orchestrator's effective provision list includes it.

## Implementation Plan

### Phase 1: Foundation
Create the durable data layer and the secret-reference model. Introduce the `external_apis` table and the `ExternalApis` context + schema, scoped exactly like `project_secrets` (nullable `project_id`; `nil` = user/platform scope = all orchestrators). Auth is a **reference** to a vault secret name, never the token. This phase is purely additive — no existing behavior changes.

### Phase 2: Core Implementation
Build the provisioning resolver (`ExternalApis.Provisioning`) that converts a set of in-scope, provisioned API rows into the adapter fragments (`mcp_servers`/`allowed_tools`/`secret_keys`/`instructions`), with per-transport server shapes (http/sse with `Authorization: Bearer ${SECRET}`, stdio `command`/`args`). Wire it into the two worker spawn paths (`Claude.worker_mcp_args/1`, `Pi.worker_mcp_args/1`) by **merging** with the static `McpTools` fragment, and into the secret-injection seam (`Session.Server.api_secrets/1`) so each provisioned API's vault secret reaches only the workers granted it.

### Phase 3: Integration
Expose the registry to the orchestrator (the delegation seam): the `list_apis` MCP tool, the `apis` argument on `create_agent`/`command_agent`, persistence into the worker's `config["apis"]`, prepending the API `instructions`/`doc_urls` to the worker charter, and a "Registered APIs you may delegate" section in the orchestrator system prompt. Then the operator UI: a Registered APIs settings panel (user + project scope) in `ConsoleLive`, going through the context, with a vault-write secret-deposit field. Finish with the LiveView integration test and the full validation gate.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Schema + migration for `external_apis`
- Create `priv/repo/migrations/<ts>_create_external_apis.exs` (use `mix ecto.gen.migration create_external_apis`). Table `external_apis`, `primary_key: false`, `add :id, :binary_id, primary_key: true`. Columns:
  - `name :string, null: false` (the MCP server key, e.g. `"pixellab"`; env-var-safe-ish, validated in changeset).
  - `provider :string` (optional human label, open identity).
  - `transport :string, null: false` (closed enum at the schema layer: `http` | `sse` | `stdio`).
  - `url :string` (for http/sse).
  - `command :string`, `args {:array, :string}, default: []` (for stdio).
  - `auth_scheme :string, null: false, default: "none"` (`none` | `bearer` | `header`).
  - `auth_header :string` (header name when `auth_scheme = header`; defaults to `Authorization` for `bearer`).
  - `secret_name :string` (the vault secret reference, e.g. `"PIXELLAB_API_KEY"`; NEVER the token).
  - `description :string`, `instructions :text` (the worker-facing usage prompt).
  - `doc_urls {:array, :string}, default: []`.
  - `allowed_tools {:array, :string}, default: []`.
  - `status :string, null: false, default: "active"` (`active` | `disabled`).
  - `metadata :map, default: %{}` (JSONB, string-keyed).
  - `add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)` — nullable; `nil` = user/platform scope.
  - `timestamps(type: :utc_datetime_usec)`.
- Add two **partial unique indexes** on `name` (mirror `create_project_secrets.exs`): one `where: "project_id IS NOT NULL"` over `[:project_id, :name]`, one `where: "project_id IS NULL"` over `[:name]` — so a name is unique within a project and within the platform scope independently.
- Create `lib/repo_builder/external_apis/external_api.ex` — `RepoBuilder.ExternalApis.ExternalApi`, `use RepoBuilder.Schema`. Define `@type t`/`typedstruct` per the typed standard. `Ecto.Enum` for `transport`/`auth_scheme`/`status`. `changeset/2`:
  - `cast` all fields; `validate_required([:name, :transport])`.
  - `validate_format(:name, ~r/^[a-z][a-z0-9_-]*$/)` (a valid MCP server key).
  - `validate_inclusion` for the three enums.
  - Conditional: when `transport in [:http, :sse]` require `url`; when `:stdio` require `command`.
  - When `auth_scheme in [:bearer, :header]` require `secret_name`; `validate_format(:secret_name, ~r/^[A-Z][A-Z0-9_]*$/)` (env-var shape, matches `ProjectSecret`).
  - `unique_constraint(:name, name: ...)` for both partial indexes.
- `@impl true` callbacks (if any) exempt from `@spec`; everything else `@spec`'d.

### 2. `ExternalApis` context
- Create `lib/repo_builder/external_apis.ex` — `RepoBuilder.ExternalApis`, the ONLY `Repo` caller for `external_apis`. Public API (all `@spec`'d, tagged tuples, no raises):
  - `list_for_scope(project_id :: Ecto.UUID.t() | nil) :: [ExternalApi.t()]` — the registrations OWNED by exactly that scope (project rows, or platform `NULL` rows). Drives the two UI lists.
  - `list_in_scope_for(project_id :: Ecto.UUID.t() | nil) :: [ExternalApi.t()]` — the **effective** set visible to an orchestrator on `project_id`: platform (`NULL`) rows **plus** that project's rows, `status: :active` only, project rows shadowing a same-named platform row. This is the orchestrator-visibility + provisioning lookup.
  - `fetch_by_names(project_id, names :: [String.t()]) :: [ExternalApi.t()]` — resolve a provision list against `list_in_scope_for/1` (drops unknown/disabled names). Used by the resolver.
  - `get/1`, `create/1`, `update/2`, `delete/1` — CRUD via changeset; `create`/`update` return `{:ok, t} | {:error, changeset}`.
- Add `test/repo_builder/external_apis_test.exs`: scope resolution (platform vs project, shadowing), `status: :disabled` excluded from `list_in_scope_for`, changeset validation (missing url for http, missing secret_name for bearer), name uniqueness per scope, and that the row never holds a token.

### 3. Provisioning resolver (`ExternalApis.Provisioning`)
- Create `lib/repo_builder/external_apis/provisioning.ex` — `RepoBuilder.ExternalApis.Provisioning`. Mirrors `Harness.McpTools`' fragment API but operates on `ExternalApi.t()` rows (no closed atom set). Public fns (`@spec`'d):
  - `mcp_servers([ExternalApi.t()]) :: %{String.t() => map()}` — `name => server_spec`. Per-transport (inference-only specs, like `McpTools.server_spec/1`):
    - `http`/`sse`: `%{"type" => "http"|"sse", "url" => url, "headers" => auth_headers(api)}` where `auth_headers/1` is `%{header => "Bearer ${SECRET_NAME}"}` for `:bearer`, `%{header => "${SECRET_NAME}"}` for `:header`, `%{}` for `:none`. The literal token is NEVER inlined — only the `${SECRET_NAME}` placeholder.
    - `stdio`: `%{"command" => command, "args" => args, "env" => %{}}` (env injected at the session boundary, not here).
  - `allowed_tools([ExternalApi.t()]) :: [String.t()]` — each row's `allowed_tools` if set, else `["mcp__#{name}__*"]`.
  - `secret_keys([ExternalApi.t()]) :: [{String.t(), String.t()}]` — `{name, secret_name}` for rows whose `auth_scheme != :none` and `secret_name` present.
  - `instructions([ExternalApi.t()]) :: String.t()` — a charter fragment concatenating each provisioned API's `description`/`instructions`/`doc_urls` (for prepending to the worker system prompt). Empty string for `[]`.
- Add `test/repo_builder/external_apis/provisioning_test.exs`: http+bearer fragment exact shape (placeholder, not token), stdio fragment, default vs custom allowed_tools, secret_keys pairs filtered by auth_scheme, instructions concatenation, and `[]` → empty fragments.

### 4. Merge dynamic provisions into the worker spawn paths
- In `lib/repo_builder/harness/claude.ex` `worker_mcp_args/1`: keep the `orchestrator_config?` short-circuit. Resolve the worker's provisioned APIs from `opts.config["apis"]` against the worker's project (`opts[:project_id]`) via `ExternalApis.fetch_by_names/2`, build the dynamic fragment from `Provisioning`, and **merge** it with the existing static `McpTools` fragment before writing `.mcp.json`:
  - `servers = Map.merge(McpTools.mcp_servers(tools), Provisioning.mcp_servers(apis))`
  - `allowed = McpTools.allowed_tools(tools) ++ Provisioning.allowed_tools(apis)`
  - Skip writing the file only when BOTH are empty (a plain worker is byte-for-byte unchanged).
- Do the identical merge in `lib/repo_builder/harness/pi.ex` `worker_mcp_args/1` (writes `.pi-mcp.json`; pi has no `--allowedTools`, so only the servers fragment merges).
- Keep both adapters reading `opts[:project_id]` (already threaded by `Session.Server`/`command_agent`). If a harness adapter must avoid a `Repo` call at spawn, resolve the rows in `command_agent`/`create_agent` and pass the resolved server specs in `config` instead — **decision: resolve at spawn in the adapter via the context** (consistent with how `McpTools` is read in-adapter; the context is a pure read). Note this in the test.

### 5. Inject the provisioned API secrets into the worker env
- In `lib/repo_builder/session/server.ex`, add `api_secrets/1` and fold it into `merge_secrets/3` (after `tool_secrets/1`, before explicit `opts[:secrets]` overrides). It must be WORKERS ONLY — reuse the `orchestrator_session?/1` gate so the orchestrator brain never receives the token.
  - For each provisioned API name in `opts[:config]["apis"]`, resolve the row (`ExternalApis.fetch_by_names/2` scoped to `opts[:project_id]`), and for each `{_name, secret_name}` from `Provisioning.secret_keys/1`, pull the value from the **encrypted vault** for the worker's project (`Secrets.resolve_env(project_id)[secret_name]`) — the same JIT-decrypt seam already used for project secrets — and put `{secret_name, value}` into the env. Drop unset/nil so only resolvable secrets are injected.
  - A platform-scope API (`project_id IS NULL`) whose secret lives in the platform vault (`Secrets.resolve_env(nil)`) must also resolve — so `api_secrets/1` merges the platform vault and the project vault (project shadows platform), matching `list_in_scope_for/1`.
- This makes the `${SECRET_NAME}` placeholder written by `Provisioning.mcp_servers/1` expand from the child env at CLI read time (same mechanism as firecrawl's `${FIRECRAWL_API_KEY}`). Add a `resolve_secrets/2`-style hermetic test path so the merge is unit-testable without a live process.

### 6. Orchestrator delegation seam — tools & catalog
- In `lib/repo_builder/orchestrator/tool_catalog.ex` `tools/0`:
  - Add a `list_apis` tool: no required args (optional `scope` filter), described as "List the external APIs/MCP servers registered for this orchestrator (platform + project scope) that you may PROVISION to a worker. You cannot call these tools yourself — pass their names in `apis` to `create_agent`/`command_agent`."
  - Add an `apis` property (array of strings) to the `create_agent` AND `command_agent` input schemas, documented as "names of registered external APIs to provision to this worker."
- In `lib/repo_builder/orchestrator/tools.ex`:
  - Add the `list_apis` handler → `ExternalApis.list_in_scope_for(orchestrator_project_id(orchestrator_id))`, returning name/provider/scope/transport/description/instructions/doc_urls/allowed_tools — but NEVER `secret_name` value or any token (name-only auth exposure, per the vault threat model). Add to the `dispatch/3` table.
  - In `create_agent/2`: parse an `apis` arg (validate each name against `ExternalApis.list_in_scope_for/1`; reject unknown names with a helpful error listing available names) and persist it via a new `maybe_put_apis/2` (mirrors `maybe_put_tools/2` at ~line 2357) into `config["apis"]`. Prepend the provisioned APIs' `Provisioning.instructions/1` to the worker `system_prompt` (in the existing `prepend_stack_contract |> with_reporting_clause` pipeline), so the worker reads how to use the API.
  - In `command_agent/2`: ensure `worker_session_config/1` carries `config["apis"]` through to the session opts (it already passes the worker `config`; confirm `apis` survives), and `project_id` is set (already pinned at create time) so the resolver/secret seam scope is correct.
- Add tool-level tests (extend the existing `tools` test suite): `list_apis` returns in-scope rows without secrets; `create_agent` with a known `apis` name persists `config["apis"]` and prepends instructions; an unknown `apis` name errors.

### 7. Orchestrator system-prompt awareness
- In `lib/repo_builder/orchestrator/system_prompt.ex` `build/1`: add a "Registered APIs you may delegate to workers" section listing `ExternalApis.list_in_scope_for(orchestrator.project_id)` as `name — description` lines, with a one-line instruction that the orchestrator must NOT call them itself but pass names in `apis` when spawning/commanding a worker. Surface name + description ONLY (never the secret). Empty scope ⇒ omit the section (back-compatible prompt).
- Extend the system-prompt test to assert the section appears when a registration is in scope and is absent otherwise, and that no secret value/`secret_name` token leaks into the prompt.

### 8. LiveView Registered APIs panel
- Create the integration test FIRST: `test/repo_builder_web/live/test_external_apis_panel_test.exs` using `Phoenix.LiveViewTest`:
  - `live/2` the console on a project; open the Registered APIs panel.
  - `render_submit` the register form with a user-scope Pixellab entry (`name: "pixellab"`, `transport: "http"`, `url: "https://api.pixellab.ai/mcp"`, `auth_scheme: "bearer"`, `secret_name: "PIXELLAB_API_KEY"`, `doc_urls: ["https://api.pixellab.ai/mcp/docs"]`). Assert it renders in the user-scope list and that `ExternalApis.list_in_scope_for(project_id)` includes it.
  - Deposit the secret (`PIXELLAB_API_KEY`) and assert `Secrets.list_names/1` shows it masked (never plaintext).
  - Register a project-scope API and assert it shows only in the project list.
  - Delete one and assert it disappears.
  - Reference real DOM ids (`#external-apis-panel`, `#register-api-form`, `#api-list-user`, `#api-list-project`).
- In `lib/repo_builder_web/live/console_live.ex`: add assigns (`user_apis`, `project_apis`) loaded via `ExternalApis.list_for_scope/1`, and `handle_event` clauses `register_api`/`update_api`/`delete_api`/`deposit_api_secret` (the last writes through `Secrets.put_secret/3`). Re-broadcast/refresh on change. All DB access through `ExternalApis`/`Secrets` contexts — never `Repo`.
- In `lib/repo_builder_web/components/console_components.ex`: render the panel — two scoped lists + a register/edit form (transport select drives which fields show: url vs command/args; auth_scheme select drives secret_name/auth_header). Show `last_four`-style masked indicator for whether the referenced secret is present. Follow the existing roster/secrets panel markup conventions.
- Optionally capture a Playwright screenshot of `http://localhost:4000` showing the panel as visual proof.

### 9. Validation
- Run the full `Validation Commands` below; every command must pass with zero warnings/errors. Verify end-to-end via Tidewave `project_eval` that an orchestrator on a project with a registered Pixellab API resolves it (`ExternalApis.list_in_scope_for/1`), that `Provisioning.mcp_servers/1` produces the `{"type":"http","url":...,"headers":{"Authorization":"Bearer ${PIXELLAB_API_KEY}"}}` fragment, and that a `create_agent` with `apis: ["pixellab"]` persists `config["apis"]` — without the token ever appearing on the registration row or in the orchestrator prompt.

## Testing Strategy

### Unit Tests
- **`ExternalApis` context** — scope resolution (`list_for_scope` vs `list_in_scope_for`), project-shadows-platform, `:disabled` excluded from effective set, changeset validation matrix (http requires url; stdio requires command; bearer/header requires `secret_name`; name format; per-scope uniqueness), and that no token is ever persisted on the row.
- **`Provisioning` resolver** — exact http+bearer/sse/stdio server-spec shapes (placeholder, not literal token), default and custom `allowed_tools`, `secret_keys` filtered by `auth_scheme`, instructions concatenation, and empty-input ⇒ empty fragments.
- **Worker spawn merge** — `Claude.worker_mcp_args/1` and `Pi.worker_mcp_args/1` emit the merged static-firecrawl + dynamic-provision `.mcp.json`/`.pi-mcp.json`; orchestrator config short-circuits to `[]`; a worker with neither tools nor apis is byte-for-byte unchanged.
- **Secret injection** — `Session.Server.resolve_secrets/2` (hermetic seam) folds the provisioned API's vault secret into the worker env (project + platform vault, project shadows), and the orchestrator session is gated out (no token).
- **Orchestrator tools** — `list_apis` returns in-scope rows without secrets; `create_agent`/`command_agent` accept/validate `apis`, persist `config["apis"]`, prepend instructions; unknown name errors.
- **System prompt** — the "Registered APIs" section appears/omits correctly and leaks no secret.
- **LiveView** — register/edit/delete across both scopes; secret deposit writes to the vault masked.

### Edge Cases
- A provisioned API name that is **unknown or disabled** in the orchestrator's scope → dropped by `fetch_by_names/2` (no `.mcp.json` entry), and `create_agent` rejects it up front with a helpful error.
- A project-scope API **shadowing** a same-named platform API → the project row wins in `list_in_scope_for/1`.
- `auth_scheme: :none` (a public MCP) → no `secret_keys`, no env injection, no `headers`.
- A registration whose `secret_name` has **no deposited vault value** → no env var injected (fail-soft); the `${SECRET}` placeholder stays literal (CLI gets an unset var) — surfaced in the UI as "secret missing".
- The **orchestrator brain** must NEVER receive the token nor be able to call the tool itself (gated by `orchestrator_session?/1` for env, `--disallowedTools`/`--no-builtin-tools` already deny tool calls).
- Deleting a **project** cascades (`on_delete: :delete_all`) its project-scope registrations; platform registrations survive.
- stdio transport with `args` from JSONB (string array round-trips cleanly).
- Redaction: a token value that *is* injected into a worker env must be in the scrub set (verify `active_values`/`Redact` already covers vault values; the API token lives in the vault, so it is already scrubbed).

## Acceptance Criteria
- An operator can register an external API/MCP server (e.g. Pixellab `http` + `bearer` + doc URL) at **user scope** (visible to all orchestrators) and at **project scope** (visible to one project's orchestrator) from the console, with the token stored only in the encrypted vault (the registration row holds `secret_name`, never the token).
- The orchestrator can **discover** registered APIs (`list_apis`) and read their instructions/doc URLs, and its system prompt lists what it may delegate — but it **cannot call them itself**.
- The orchestrator can **transfer** an API to a worker via `apis: ["pixellab"]` on `create_agent`/`command_agent`; the worker's `.mcp.json`/`.pi-mcp.json` gains the server (http+bearer header), the worker's child env gets the vault secret so `${SECRET}` expands, and the API's instructions are prepended to the worker's charter.
- A worker NOT provisioned an API, and the orchestrator brain, receive neither the server nor the secret.
- Scope rules hold: platform rows are visible everywhere; project rows only on their project; a project row shadows a same-named platform row; disabled rows are never provisioned.
- No token ever appears on the registration row, in `list_apis`, or in the orchestrator system prompt.
- The full validation gate is green: compile (warnings-as-errors + set-theoretic types), full test suite, format, Credo `--strict` (every public fn `@spec`'d), Dialyzer (no new warnings).

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `mix ecto.migrate` — apply the `create_external_apis` migration cleanly.
- `mix test test/repo_builder/external_apis_test.exs` — the context unit tests.
- `mix test test/repo_builder/external_apis/provisioning_test.exs` — the resolver tests.
- `mix test test/repo_builder_web/live/test_external_apis_panel_test.exs` — the LiveView integration test.
- `mix test --warnings-as-errors` — full ExUnit suite (Postgres-backed) with zero failures.
- `mix compile --warnings-as-errors` — gradual set-theoretic type checker + `warnings_as_errors` clean.
- `mix format --check-formatted` — formatted.
- `mix credo --strict` — lint, incl. the "every public function has an `@spec`" convention (new context, schema, resolver, tools).
- `mix dialyzer` — `@spec`/contract checking, no new warnings, no stale ignore filters.

## Notes
- **No new dependency.** Reuses the existing `RepoBuilder.Secrets` AES-256-GCM vault for credentials and the existing `.mcp.json`/placeholder mechanism for credential expansion. `:req` is present if a future enhancement wants to validate a `doc_urls` endpoint at registration time (out of scope here).
- **Doctrine alignment (BUILD_PROMPT §10):** `transport`/`auth_scheme`/`status` are closed `Ecto.Enum`s (the closed contract); `name`/`provider`/`url`/`secret_name` are open `:string`s validated at the changeset boundary (open identity). Adding a new API is a **data edit** (a DB row), not adapter surgery — exactly the property `McpTools`' moduledoc aspires to, now realized dynamically.
- **Why a reference, not the token, on the row:** mirrors `ProjectSecret` and the §6/§4.1 secrets discipline — the orchestrator and UI see only the `secret_name` (name-only exposure), the token is JIT-decrypted solely at the worker child-env boundary, and it is already in the redaction scrub set.
- **`McpTools` is intentionally left as-is** (the static firecrawl catalog). The dynamic registry is *additive and merged*, so firecrawl keeps working unchanged and the two paths can coexist. A future cleanup could migrate firecrawl into the DB registry, but that is not required.
- **Adapter `Repo` read at spawn:** the worker spawn paths already read the static catalog in-adapter; reading the dynamic context there is a pure query and keeps the resolution scope (project) authoritative. If a future constraint forbids `Repo` in an adapter, pre-resolve the server specs in `command_agent` and thread them through `config` — the resolver API is shaped to allow either.
- **Tidewave validation** (`http://localhost:4000/tidewave/mcp`): use `execute_sql_query` to confirm the partial unique indexes and a registered row's columns, `project_eval` to confirm `ExternalApis.list_in_scope_for/1` scoping and the `Provisioning.mcp_servers/1` fragment shape, and `get_logs` if a worker spawn fails to expand `${SECRET}`.
- **Future considerations:** per-API rate/usage accounting (reuse the cost telemetry seam), an `enabled_by_default` flag to auto-provision an API to every worker on a project, and a "test connection" button that fetches a `doc_urls` endpoint to validate auth before saving.
