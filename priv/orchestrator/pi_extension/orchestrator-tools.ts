/**
 * repo_builder orchestrator tools — pi extension.
 *
 * pi ships NO MCP by design; custom tools come from a TypeScript extension loaded
 * with `-e <dir>` (see memory `pi-harness-tooling`). This extension registers the
 * SAME agent-management tools the Claude orchestrator gets natively over MCP, and
 * its handlers `fetch` the one Phoenix-hosted MCP-over-HTTP endpoint (JSON-RPC 2.0
 * `tools/call`). The tool LOGIC lives once in Elixir — this is purely a binding.
 *
 * Shape (pi ≥ 0.75): the host injects its API as the argument to the module's
 * DEFAULT export, and tools register via `pi.registerTool({ name, label,
 * description, parameters, execute })` returning `{ content: [{ type, text }] }`.
 * Modeled on the installed, working `pi-mcp-adapter`, which bridges MCP tools into
 * pi exactly like this extension. The earlier global-`pi` + `handler` shape crashed
 * at load with `pi is not defined`.
 *
 * Env (injected by RepoBuilder.Harness.Pi.orchestrator_spawn/2):
 *   PI_ORCH_BASE_URL — full URL of this orchestrator's MCP endpoint
 *   PI_ORCH_TOKEN    — per-orchestrator bearer token (never logged)
 */

// Type-only import (erased at runtime — does not affect extension loading).
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BASE_URL = process.env.PI_ORCH_BASE_URL ?? "";
const TOKEN = process.env.PI_ORCH_TOKEN ?? "";

let rpcId = 0;

async function callTool(
  name: string,
  args: Record<string, unknown>,
): Promise<string> {
  rpcId += 1;
  const res = await fetch(BASE_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: rpcId,
      method: "tools/call",
      params: { name, arguments: args },
    }),
  });

  if (!res.ok) {
    return `tool ${name} failed: HTTP ${res.status}`;
  }

  const body = (await res.json()) as {
    result?: { content?: Array<{ text?: string }>; isError?: boolean };
    error?: { message?: string };
  };

  if (body.error) {
    return `tool ${name} error: ${body.error.message ?? "unknown"}`;
  }

  const text = body.result?.content?.map((c) => c.text ?? "").join("\n") ?? "";
  return text;
}

// Mirror RepoBuilder.Orchestrator.ToolCatalog. The Elixir endpoint is the source
// of truth for validation; these definitions advertise the tools to pi.
const tools = [
  {
    name: "create_agent",
    description:
      "Create a new worker agent owned by this orchestrator. Returns the worker's id and name.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Unique worker name." },
        harness: { type: "string", description: "Registered harness (e.g. claude, pi)." },
        model: { type: "string", description: "Optional model override." },
        system_prompt: { type: "string", description: "Optional worker system prompt." },
        subagent_template: {
          type: "string",
          description:
            "Optional name of a saved subagent template (see list_agent_templates). Applies its body as the worker system prompt and its model/category; explicit system_prompt/model override it. The template name+version are recorded on the worker.",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "command_agent",
    description: "Dispatch a task prompt to a worker by name.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Target worker name." },
        prompt: { type: "string", description: "The task to run." },
      },
      required: ["name", "prompt"],
    },
  },
  {
    name: "list_agents",
    description: "List all worker agents owned by this orchestrator and their status.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "check_agent_status",
    description: "Get a worker's status, recent event tail, and accumulated cost.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Target worker name." },
        limit: { type: "integer", description: "How many recent events to tail." },
      },
      required: ["name"],
    },
  },
  {
    name: "interrupt_agent",
    description: "Interrupt a worker's currently running session.",
    parameters: {
      type: "object",
      properties: { name: { type: "string", description: "Target worker name." } },
      required: ["name"],
    },
  },
  {
    name: "start_adw",
    description: "Launch the seeded plan→build→review→fix workflow. Returns the run id.",
    parameters: {
      type: "object",
      properties: {
        input: { type: "string", description: "The work item / task description." },
        harness: { type: "string", description: "Harness for the workflow steps." },
      },
      required: ["input"],
    },
  },
  {
    name: "update_agent",
    description:
      "Update a worker by name. At least one of system_prompt, model, or harness must be provided; harness is validated against the registry.",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Target worker name." },
        system_prompt: { type: "string", description: "New worker system prompt." },
        model: { type: "string", description: "New model." },
        harness: { type: "string", description: "New registered harness (e.g. claude, pi)." },
      },
      required: ["name"],
    },
  },
  {
    name: "delete_agent",
    description: "Delete a worker by name. Any live session is stopped first.",
    parameters: {
      type: "object",
      properties: { name: { type: "string", description: "Target worker name." } },
      required: ["name"],
    },
  },
  {
    name: "read_system_logs",
    description:
      "Page through recent system logs (newest first). Optional level and message_contains filters.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", description: "Page size (default 50, max 200)." },
        offset: { type: "integer", description: "Rows to skip (default 0)." },
        level: {
          type: "string",
          enum: ["debug", "info", "warn", "error"],
          description: "Filter by log level.",
        },
        message_contains: {
          type: "string",
          description: "Case-insensitive substring match on the message.",
        },
      },
      required: [],
    },
  },
  {
    name: "check_adw",
    description:
      "Inspect an ADW run by id: status, current step, cost, and artifacts. Pairs with start_adw.",
    parameters: {
      type: "object",
      properties: {
        run_id: { type: "string", description: "The workflow run id from start_adw." },
      },
      required: ["run_id"],
    },
  },
  {
    name: "get_config",
    description:
      "Read this orchestrator's current configuration: its own harness/provider/model, the worker-tier roster (fast/main/heavy/leader with each tier's harness/provider/model or 'unassigned'), the registered harnesses, and the available models per harness/provider. Use this first when a spawn fails with 'no model selected'.",
    parameters: { type: "object", properties: {}, required: [] },
  },
  {
    name: "configure_tier",
    description:
      "Assign a harness/provider/model to a worker tier (fast/main/heavy/leader) so create_agent with that category can spawn. model is required; harness defaults to the orchestrator's harness; provider is optional.",
    parameters: {
      type: "object",
      properties: {
        category: {
          type: "string",
          enum: ["fast", "main", "heavy", "leader"],
          description: "Worker tier to configure.",
        },
        harness: {
          type: "string",
          description: "Registered harness for the tier (default: orchestrator's harness).",
        },
        provider: { type: "string", description: "Optional provider (open identity)." },
        model: { type: "string", description: "Model to assign to the tier." },
      },
      required: ["category", "model"],
    },
  },
  {
    name: "set_orchestrator_config",
    description:
      "Update this orchestrator's own configuration. Provide any of harness (validated against the registry; switching resets provider/model to that harness's defaults), provider (resets model), and model. At least one is required.",
    parameters: {
      type: "object",
      properties: {
        harness: {
          type: "string",
          description: "New registered harness (resets provider/model to its defaults).",
        },
        provider: { type: "string", description: "New provider (resets model)." },
        model: { type: "string", description: "New model." },
      },
      required: [],
    },
  },
  {
    name: "report_cost",
    description:
      "Report this orchestrator's session id, status, running USD cost, cumulative input/output/total tokens, and context-window usage % (with a high-usage warning).",
    parameters: { type: "object", properties: {}, required: [] },
  },
  {
    name: "compact_agent",
    description:
      "Compact a worker's context by dispatching /compact to it (sugar over command_agent).",
    parameters: {
      type: "object",
      properties: { name: { type: "string", description: "Target worker name." } },
      required: ["name"],
    },
  },
  {
    name: "list_agent_templates",
    description:
      "List the available subagent templates (name + description) — the reusable worker recipes applicable via create_agent's subagent_template.",
    parameters: { type: "object", properties: {}, required: [] },
  },
  {
    name: "get_agent_template",
    description:
      "Read one subagent template's current version: description, system-prompt body, and optional model/category/harness.",
    parameters: {
      type: "object",
      properties: { name: { type: "string", description: "Template name." } },
      required: ["name"],
    },
  },
  {
    name: "save_agent_template",
    description:
      "Create or refine a subagent template, writing a NEW version. system_prompt is the worker recipe body; applicable afterwards via create_agent(subagent_template:).",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Template name (kebab-case, e.g. test-writer)." },
        description: { type: "string", description: "One-line summary for the subagent map." },
        system_prompt: { type: "string", description: "The worker's system-prompt body." },
        model: { type: "string", description: "Optional default model." },
        category: {
          type: "string",
          enum: ["fast", "main", "heavy", "leader"],
          description: "Optional default worker tier.",
        },
      },
      required: ["name", "description", "system_prompt"],
    },
  },
];

// pi ≥ 0.75 injects the host API as the default export's argument; tools register
// INSIDE this function with an `execute` callback returning canonical content.
export default function (pi: ExtensionAPI) {
  for (const tool of tools) {
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description,
      parameters: tool.parameters,
      async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
        const text = await callTool(tool.name, params as Record<string, unknown>);
        return { content: [{ type: "text", text }] };
      },
    });
  }
}
