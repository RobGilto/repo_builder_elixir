defmodule RepoBuilder.Orchestrator.ToolCatalog do
  @moduledoc """
  The SINGLE source of truth for the orchestrator's agent-management tool
  definitions (name / description / JSON-Schema input). Both bindings advertise
  the IDENTICAL tools from here: the MCP `tools/list` response
  (`RepoBuilderWeb.OrchestratorMCPController`) and the pi extension manifest
  (`priv/orchestrator/pi_extension`). Pure data — no side effects.
  """

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @doc "All orchestrator tool definitions, in a stable order."
  @spec tools() :: [tool_def()]
  def tools do
    [
      %{
        name: "create_agent",
        description:
          "Create a new worker agent owned by this orchestrator. Returns the worker's id and name. Names are unique within this orchestrator.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Unique worker name."},
            "harness" => %{
              "type" => "string",
              "description" => "Registered harness the worker runs on (e.g. claude, pi)."
            },
            "model" => %{"type" => "string", "description" => "Optional model override."},
            "system_prompt" => %{
              "type" => "string",
              "description" => "Optional worker system prompt."
            }
          },
          "required" => ["name"]
        }
      },
      %{
        name: "command_agent",
        description:
          "Dispatch a task prompt to a worker by name. Starts (or resumes) the worker's session; returns immediately once dispatched.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."},
            "prompt" => %{"type" => "string", "description" => "The task to run."}
          },
          "required" => ["name", "prompt"]
        }
      },
      %{
        name: "list_agents",
        description: "List all worker agents owned by this orchestrator and their status.",
        input_schema: %{"type" => "object", "properties" => %{}}
      },
      %{
        name: "check_agent_status",
        description: "Get a worker's current status, recent event tail, and accumulated cost.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."},
            "limit" => %{
              "type" => "integer",
              "description" => "How many recent events to tail (default 20)."
            }
          },
          "required" => ["name"]
        }
      },
      %{
        name: "interrupt_agent",
        description: "Interrupt a worker's currently running session.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."}
          },
          "required" => ["name"]
        }
      },
      %{
        name: "start_adw",
        description:
          "Launch the seeded plan→build→review→fix AI Developer Workflow on a harness. Returns the workflow run id.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "The work item / task description."},
            "harness" => %{
              "type" => "string",
              "description" => "Harness for the workflow steps (default: orchestrator's harness)."
            }
          },
          "required" => ["input"]
        }
      }
    ]
  end

  @doc "The set of tool names this catalog advertises."
  @spec names() :: [String.t()]
  def names, do: Enum.map(tools(), & &1.name)
end
