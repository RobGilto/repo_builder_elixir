# Keyless dashboard demo seed (BUILD_PROMPT.md §13).
#
# Drives the platform end-to-end using the `fake` harness — no real CLI, no API
# key — so the LiveView dashboard shows real agent + workflow swimlanes and
# persisted logs.
#
#   1. start the server:   iex -S mix phx.server   (or `mix phx.server`)
#   2. open the dashboard: http://localhost:4000/dashboard
#   3. in another shell:   mix run priv/repo/demo_seeds.exs
#
# Run it again any time to fire another round. Open the printed agent/workflow
# URLs to see the per-lane detail views and the persisted event history.
#
# NOTE: the `fake` harness is registered in :dev only (config/config.exs), so this
# script must run in the dev environment (the default for `mix run`).

alias RepoBuilder.Agents
alias RepoBuilder.Session.Supervisor, as: SessionSupervisor
alias RepoBuilder.WorkflowEngine

if Application.fetch_env!(:repo_builder, :harnesses)["fake"] == nil do
  raise """
  The `fake` harness is not registered. Run this in the :dev environment
  (plain `mix run priv/repo/demo_seeds.exs`), not MIX_ENV=prod/test.
  """
end

# --- 1. A demo agent on the fake harness (idempotent by unique name) ----------

agent_name = "demo-fake-agent"

agent =
  case Enum.find(Agents.list_agents(), &(&1.name == agent_name)) do
    nil ->
      {:ok, a} =
        Agents.create_agent(%{
          name: agent_name,
          harness: "fake",
          provider: :anthropic,
          config: %{}
        })

      IO.puts("created agent #{a.id} (#{a.name})")
      a

    existing ->
      IO.puts("reusing agent #{existing.id} (#{existing.name})")
      existing
  end

# --- 2. A live session: streams canned canonical events to the dashboard ------
# Use the agent UUID as BOTH the registry/topic key (`agent_id`) and the FK
# (`agent_db_id`) so the seeded dashboard lane and the live lane share a dom id
# and the events persist to agent_logs under this agent.

session_id = "demo-#{System.system_time(:second)}"

{:ok, pid} =
  SessionSupervisor.start_session(
    agent_id: agent.id,
    agent_db_id: agent.id,
    session_id: session_id,
    harness: "fake",
    prompt: "Say hello from the fake harness and call a demo tool."
  )

ref = Process.monitor(pid)
IO.puts("started fake session #{session_id} (pid #{inspect(pid)}) — streaming…")

receive do
  {:DOWN, ^ref, :process, _pid, reason} ->
    IO.puts("session finished (#{inspect(reason)}); events persisted to agent_logs")
after
  15_000 ->
    IO.puts("session still running after 15s; interrupting")
    SessionSupervisor.interrupt(agent.id)
end

# --- 3. An example ADW (plan → build → review → fix) on the fake harness -------

{:ok, workflow} =
  WorkflowEngine.create_example_workflow(
    "demo-fake-workflow-#{System.system_time(:second)}",
    "fake"
  )

{:ok, run_id, _runner} = WorkflowEngine.start_workflow(workflow)
IO.puts("started workflow run #{run_id} (#{workflow.name})")

# Give the deterministic state machine a moment to advance through its steps so
# the workflow_run row reflects transitions before the script exits.
Process.sleep(3_000)

IO.puts("""

Demo seeded. Open:
  dashboard:  http://localhost:4000/dashboard
  agent:      http://localhost:4000/agents/#{agent.id}
  workflow:   http://localhost:4000/workflows/#{run_id}
  metrics:    http://localhost:4000/dev/dashboard
""")
