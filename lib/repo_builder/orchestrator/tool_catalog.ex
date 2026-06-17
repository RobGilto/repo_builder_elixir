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

  alias RepoBuilder.WorkflowEngine.Catalog

  @doc "All orchestrator tool definitions, in a stable order."
  @spec tools() :: [tool_def()]
  def tools do
    [
      %{
        name: "create_agent",
        description:
          "Create a new worker agent owned by this orchestrator. Prefer `category` (fast/main/heavy/leader) to spawn into the operator-configured harness/provider/model for that tier; that fails if no model is assigned to the category. Returns the worker's id and name. Names are unique within this orchestrator.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Unique worker name."},
            "category" => %{
              "type" => "string",
              "enum" => ["fast", "main", "heavy", "leader"],
              "description" =>
                "Worker model tier to spawn into (resolves to the operator-assigned harness/provider/model). Preferred over an explicit harness/model."
            },
            "harness" => %{
              "type" => "string",
              "description" =>
                "Registered harness the worker runs on (e.g. claude, pi). Ignored when `category` is given."
            },
            "model" => %{"type" => "string", "description" => "Optional model override."},
            "system_prompt" => %{
              "type" => "string",
              "description" => "Optional worker system prompt."
            },
            "subagent_template" => %{
              "type" => "string",
              "description" =>
                "Optional name of a saved subagent template (see `list_agent_templates`). Applies the template's current body as the worker's system prompt and its model/category. An explicit `system_prompt`/`model` overrides the template; the template's name+version are recorded on the worker."
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
          "Launch a named AI Developer Workflow on a harness. Choose `workflow_type` from the catalog (see the AVAILABLE ADW TYPES in your system prompt); defaults to `#{Catalog.default_type()}` (plan→build→review→fix). Returns the workflow run id (use `check_adw` to watch per-step progress).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "The work item / task description."},
            "workflow_type" => %{
              "type" => "string",
              "enum" => Enum.map(Catalog.types(), & &1.slug),
              "description" =>
                "Which catalog workflow type to run (default: #{Catalog.default_type()})."
            },
            "harness" => %{
              "type" => "string",
              "description" => "Harness for the workflow steps (default: orchestrator's harness)."
            }
          },
          "required" => ["input"]
        }
      },
      %{
        name: "update_agent",
        description:
          "Update a worker by name. At least one of `system_prompt`, `model`, or `harness` must be provided; `harness` is validated against the registry. `provider`/`category` are not updatable here — delete and re-create to change tier.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."},
            "system_prompt" => %{"type" => "string", "description" => "New worker system prompt."},
            "model" => %{"type" => "string", "description" => "New model."},
            "harness" => %{
              "type" => "string",
              "description" => "New registered harness (e.g. claude, pi)."
            }
          },
          "required" => ["name"]
        }
      },
      %{
        name: "delete_agent",
        description:
          "Delete a worker by name. Any live session is stopped first, then the row is removed and the console roster updates live.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."}
          },
          "required" => ["name"]
        }
      },
      %{
        name: "read_system_logs",
        description:
          "Page through recent system logs (newest first). Optional `level` and `message_contains` filters; `limit`/`offset` paginate.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "description" => "Page size (default 50, max 200)."},
            "offset" => %{"type" => "integer", "description" => "Rows to skip (default 0)."},
            "level" => %{
              "type" => "string",
              "enum" => ["debug", "info", "warn", "error"],
              "description" => "Filter by log level."
            },
            "message_contains" => %{
              "type" => "string",
              "description" => "Case-insensitive substring match on the message."
            }
          },
          "required" => []
        }
      },
      %{
        name: "check_adw",
        description:
          "Inspect an ADW run by id: status, current step, cost, artifacts, plus completed/total progress, a per-step status+cost list, and a recent per-step activity tail. Pairs with `start_adw`.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "run_id" => %{
              "type" => "string",
              "description" => "The workflow run id from start_adw."
            }
          },
          "required" => ["run_id"]
        }
      },
      %{
        name: "get_config",
        description:
          "Read this orchestrator's current configuration: its own harness/provider/model, the worker-tier roster (fast/main/heavy/leader with each tier's harness/provider/model or 'unassigned'), the registered harnesses, and the available models per harness/provider. Use this first when a spawn fails with 'no model selected' to see what needs configuring.",
        input_schema: %{"type" => "object", "properties" => %{}, "required" => []}
      },
      %{
        name: "configure_tier",
        description:
          "Assign a harness/provider/model to a worker tier (fast/main/heavy/leader) so `create_agent` with that `category` can spawn. `model` is required; `harness` defaults to the orchestrator's harness; `provider` is optional (open identity). Use this to self-unblock when a tier is unassigned.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "category" => %{
              "type" => "string",
              "enum" => ["fast", "main", "heavy", "leader"],
              "description" => "Worker tier to configure."
            },
            "harness" => %{
              "type" => "string",
              "description" =>
                "Registered harness for the tier (default: orchestrator's harness)."
            },
            "provider" => %{
              "type" => "string",
              "description" => "Optional provider (open identity)."
            },
            "model" => %{"type" => "string", "description" => "Model to assign to the tier."}
          },
          "required" => ["category", "model"]
        }
      },
      %{
        name: "set_orchestrator_config",
        description:
          "Update this orchestrator's own configuration. Provide any of `harness` (validated against the registry; switching resets provider/model to that harness's defaults), `provider` (resets model), and `model`. At least one is required.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "harness" => %{
              "type" => "string",
              "description" => "New registered harness (resets provider/model to its defaults)."
            },
            "provider" => %{"type" => "string", "description" => "New provider (resets model)."},
            "model" => %{"type" => "string", "description" => "New model."}
          },
          "required" => []
        }
      },
      %{
        name: "report_cost",
        description:
          "Report this orchestrator's session id, status, running USD cost, cumulative input/output/total tokens, and context-window usage % (from the latest turn's occupancy). Includes a warning when usage is high — call it to watch your own spend and context pressure.",
        input_schema: %{"type" => "object", "properties" => %{}, "required" => []}
      },
      %{
        name: "compact_agent",
        description:
          "Compact a worker's context by dispatching `/compact` to it (sugar over command_agent). Use it on a worker approaching its context-window limit to free up room before its output degrades.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Target worker name."}
          },
          "required" => ["name"]
        }
      },
      %{
        name: "list_agent_templates",
        description:
          "List the available subagent templates (name + description) — the reusable worker recipes you can apply with `create_agent`'s `subagent_template`. This is the on-demand form of the SUBAGENT MAP in your system prompt.",
        input_schema: %{"type" => "object", "properties" => %{}, "required" => []}
      },
      %{
        name: "get_agent_template",
        description:
          "Read one subagent template's current version: its description, system-prompt body, and optional model/category/harness.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Template name."}
          },
          "required" => ["name"]
        }
      },
      %{
        name: "save_agent_template",
        description:
          "Create or refine a subagent template, writing a NEW version (history is preserved). `system_prompt` is the worker recipe's body. Use this to mint your own reusable specialists; the saved template is then applicable via `create_agent(subagent_template:)`.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Template name (kebab-case, e.g. `test-writer`)."
            },
            "description" => %{
              "type" => "string",
              "description" => "One-line summary shown in the subagent map."
            },
            "system_prompt" => %{
              "type" => "string",
              "description" => "The worker's system-prompt body (the recipe)."
            },
            "model" => %{"type" => "string", "description" => "Optional default model."},
            "category" => %{
              "type" => "string",
              "enum" => ["fast", "main", "heavy", "leader"],
              "description" => "Optional default worker tier."
            }
          },
          "required" => ["name", "description", "system_prompt"]
        }
      }
    ]
  end

  @doc "The set of tool names this catalog advertises."
  @spec names() :: [String.t()]
  def names, do: Enum.map(tools(), & &1.name)
end
