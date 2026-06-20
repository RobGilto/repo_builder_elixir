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
            },
            "tools" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => ["firecrawl"]},
              "description" =>
                "Grant MCP research tools to this worker, e.g. firecrawl web scrape/search/crawl/map/extract. Grant only to workers that need live web access. Omit for none."
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
        description:
          "Get a worker's current status, accumulated cost, and its findings: " <>
            "`final_message` carries the worker's latest result/summary text, and each " <>
            "`recent_events` entry includes a truncated `text` excerpt. This is how you " <>
            "read what a worker actually produced.",
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
          "Launch an AI Developer Workflow. Two modes by `harness`: with `harness:\"adw\"` it runs a REAL portable Python ADW (the full /plan→/build→/review→/fix slash-command logic, plus scout/parallel variants) — pass a `workflow_type` from the discovered ADWS list in your system prompt. With any other harness it runs the lightweight in-app catalog workflow (`#{Catalog.default_type()}` by default). Pick by complexity: trivial→`plan_build`, standard→`plan_build_review_fix`, non-trivial→full SDLC, large/exploratory→a scout/parallel ADW; decompose a big project into several `start_adw` runs you track with `check_adw`. Returns the run id (use `check_adw` to watch per-step progress).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "The work item / task description."},
            "workflow_type" => %{
              "type" => "string",
              "description" =>
                "Which workflow to run. For `harness:\"adw\"` a discovered ADW slug (see your system prompt's ADWS list); otherwise an in-app catalog type (#{Enum.map_join(Catalog.types(), ", ", & &1.slug)}, default #{Catalog.default_type()})."
            },
            "harness" => %{
              "type" => "string",
              "description" =>
                "Harness for the workflow. Use `adw` to run the real portable Python ADWs; omit to use the orchestrator's harness (in-app catalog workflow)."
            },
            "working_dir" => %{
              "type" => "string",
              "description" =>
                "Absolute path to the repo the ADW should operate in. REQUIRED for cross-repo work (the ADW's slash commands resolve from this repo's `.claude/commands/`); defaults to the orchestrator's working directory. Must be an existing directory."
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
            },
            "tools" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => ["firecrawl"]},
              "description" =>
                "Replace the worker's granted MCP research tools (e.g. firecrawl). Pass an empty array to revoke all. Other config (provider/template) is preserved."
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
        name: "get_logs",
        description:
          "Fetch the critical content of persisted console logs by their durable `log-<n>` " <>
            "number (the labels shown on every event in the console, e.g. `log-8219`). Resolve " <>
            "a reference in three shapes: a single `log` (`\"log-8219\"` or `8219`), an inclusive " <>
            "`from`..`to` range (the \"log-8219 to log-8228\" case), or an explicit `numbers` array. " <>
            "Each returned log carries its label, owner (worker/orchestrator), session, event type, " <>
            "harness/provider/model, a capped text excerpt, token/cost usage, and timestamp. Numbers " <>
            "with no row come back under `missing` (never an error); the resolved set is bounded to " <>
            "100 numbers (`capped: true` when truncated). Distinct from `read_system_logs` " <>
            "(the separate system-log audit table) and `check_agent_status` (which tails a worker by name).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "log" => %{
              "type" => "string",
              "description" => "A single log number, e.g. \"log-8219\" or \"8219\"."
            },
            "from" => %{
              "type" => "string",
              "description" => "Inclusive range start, e.g. \"log-8219\" or \"8219\"."
            },
            "to" => %{
              "type" => "string",
              "description" => "Inclusive range end, e.g. \"log-8228\" or \"8228\"."
            },
            "numbers" => %{
              "type" => "array",
              "items" => %{"type" => ["integer", "string"]},
              "description" =>
                "Explicit list of log numbers (bare ints or \"log-<n>\" strings), e.g. [8219, \"log-8225\", 8228]."
            },
            "include_hidden" => %{
              "type" => "boolean",
              "description" => "Include soft-hidden (console-cleared) rows (default false)."
            }
          },
          "required" => []
        }
      },
      %{
        name: "check_adw",
        description:
          "Inspect an ADW run by the id `start_adw` returned: status, cost, completed/total progress, a per-step status+cost list, and a recent activity tail. Works for both modes — in-app catalog runs and real portable `adw`-harness runs (whose per-step status/cost come from the canonical event log). Pairs with `start_adw`.",
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
        name: "clear_context",
        description:
          "Fully reset a worker's context window to blank — reaps its live session and drops its resumable session id so its next task starts a fresh harness session with zero prior history. Use this (not compact_agent) before handing a worker NEW, unrelated work, especially when its context usage is high. Use compact_agent instead when the next task continues prior work.",
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
