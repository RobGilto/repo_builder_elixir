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
 * Tool definitions are NOT hand-maintained here. They are sourced at load from
 * `RepoBuilder.Orchestrator.ToolCatalog.pi_manifest_json/0` — the single source of
 * truth shared with the MCP `tools/list` path — written by the spawn to the file at
 * `PI_ORCH_TOOLS_PATH` and read below. Any tool added to the catalog propagates here
 * automatically, so the two bindings can never drift.
 *
 * Env (injected by RepoBuilder.Harness.Pi.orchestrator_spawn/2):
 *   PI_ORCH_BASE_URL  — full URL of this orchestrator's MCP endpoint
 *   PI_ORCH_TOKEN     — per-orchestrator bearer token (never logged)
 *   PI_ORCH_TOOLS_PATH — absolute path to the generated tool manifest (JSON)
 */

// Type-only import (erased at runtime — does not affect extension loading).
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";

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

interface ToolDef {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

// Load the tool manifest from the file the Elixir spawn generated from
// ToolCatalog.pi_manifest_json/0 (the single source of truth). A missing/empty/
// unreadable path registers NOTHING rather than throwing at load — the extension
// still loads cleanly; the orchestrator simply has no tools until the env is wired.
function loadTools(): ToolDef[] {
  const path = process.env.PI_ORCH_TOOLS_PATH ?? "";
  if (!path) {
    return [];
  }

  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ToolDef[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

const tools = loadTools();

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
