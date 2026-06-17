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
