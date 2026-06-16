defmodule RepoBuilder.Harness.Fake do
  @moduledoc """
  FakeHarness (BUILD_PROMPT.md §13) — a real mandatory-`@behaviour` implementation
  emitting a deterministic canned sequence of canonical events, so session and
  workflow tests run without spawning a real CLI.

  It is fully wired through the generic runtime: `command/1` spawns a `printf` that
  prints the canned wire frames as JSONL, and `normalize/2` maps each frame back to
  its canonical event. `canned_events/0` returns the same sequence directly (derived
  from the frames) for tests/workflows that bypass the process layer.

  The emitted sequence is: `session_started → text_delta* → tool_call → tool_result
  → usage → done`, all with `harness: :fake`.
  """
  @behaviour RepoBuilder.Harness

  alias RepoBuilder.Harness.Event

  @ctx %{harness: :fake}

  @impl true
  def command(opts) do
    config = Map.get(opts, :config, %{})

    frames =
      if orchestrator?(config),
        do: canned_orchestrator_frames(worker_name(config)),
        else: canned_frames()

    lines = Enum.map(frames, &Jason.encode!/1)
    {"printf", ["%s\n" | lines], [], @ctx}
  end

  # The orchestrator session passes `config: %{orchestrator: true}` so the keyless
  # Fake can play a scripted orchestrator (tool_use create_agent → command_agent)
  # for the §13 end-to-end CI loop; worker sessions get the default sequence.
  @spec orchestrator?(map()) :: boolean()
  defp orchestrator?(%{orchestrator: true}), do: true
  defp orchestrator?(%{"orchestrator" => true}), do: true
  defp orchestrator?(_config), do: false

  @spec worker_name(map()) :: String.t()
  defp worker_name(config),
    do: Map.get(config, :worker_name) || Map.get(config, "worker_name") || "worker-1"

  @impl true
  def normalize(%{"type" => "session_started"} = raw, _ctx) do
    {:ok,
     [
       %Event.SessionStarted{
         harness: :fake,
         session_id: Map.get(raw, "session_id", "fake-session"),
         model: Map.get(raw, "model"),
         tools: Map.get(raw, "tools"),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "text_delta", "text" => text} = raw, _ctx) do
    {:ok,
     [
       %Event.TextDelta{
         harness: :fake,
         text: text,
         thinking?: Map.get(raw, "thinking", false),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "tool_call", "name" => name} = raw, _ctx) do
    {:ok,
     [
       %Event.ToolCall{
         harness: :fake,
         id: Map.get(raw, "id"),
         name: name,
         input: Map.get(raw, "input", %{}),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "tool_result"} = raw, _ctx) do
    {:ok,
     [
       %Event.ToolResult{
         harness: :fake,
         id: Map.get(raw, "id"),
         is_error: Map.get(raw, "is_error", false),
         content: Map.get(raw, "content"),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "usage"} = raw, _ctx) do
    {:ok,
     [
       %Event.Usage{
         harness: :fake,
         input_tokens: Map.get(raw, "input_tokens", 0),
         output_tokens: Map.get(raw, "output_tokens", 0),
         cost_usd: Map.get(raw, "cost_usd"),
         raw: raw
       }
     ]}
  end

  def normalize(%{"type" => "done"} = raw, _ctx) do
    {:ok,
     [
       %Event.Done{
         harness: :fake,
         ok: Map.get(raw, "ok", true),
         reason: :success,
         final_text: Map.get(raw, "final_text"),
         raw: raw
       }
     ]}
  end

  def normalize(_raw, _ctx), do: :skip

  @doc "The canned canonical event sequence (derived from the canned wire frames)."
  @spec canned_events() :: [Event.t()]
  def canned_events do
    Enum.flat_map(canned_frames(), fn frame ->
      case normalize(frame, @ctx) do
        {:ok, events} -> events
        _ -> []
      end
    end)
  end

  # Scripted orchestrator turn: greet → create a worker → dispatch a task to it →
  # confirm → done. The tool_call inputs are valid `Orchestrator.Tools` arguments,
  # so Orchestrator.Server's in-process dispatch genuinely creates + commands a
  # worker (the harness-blind CI loop, §13).
  # Inference-only spec — the concrete frame maps narrow below a hand-written
  # `[map()]` (dialyzer contract_supertype); matches `canned_frames/0` having none.
  defp canned_orchestrator_frames(worker_name) do
    [
      %{
        "type" => "session_started",
        "session_id" => "fake-orchestrator",
        "model" => "fake-model",
        "tools" => ["create_agent", "command_agent"]
      },
      %{"type" => "text_delta", "text" => "I'll spin up a worker for that."},
      %{
        "type" => "tool_call",
        "id" => "orch_call_1",
        "name" => "create_agent",
        "input" => %{"name" => worker_name, "harness" => "fake"}
      },
      %{
        "type" => "tool_call",
        "id" => "orch_call_2",
        "name" => "command_agent",
        "input" => %{"name" => worker_name, "prompt" => "Do the assigned task."}
      },
      %{"type" => "text_delta", "text" => "Dispatched to #{worker_name}."},
      %{"type" => "usage", "input_tokens" => 20, "output_tokens" => 8, "cost_usd" => 0.0},
      %{"type" => "done", "ok" => true, "reason" => "success", "final_text" => "Done."}
    ]
  end

  defp canned_frames do
    [
      %{
        "type" => "session_started",
        "session_id" => "fake-session",
        "model" => "fake-model",
        "tools" => ["bash"]
      },
      %{"type" => "text_delta", "text" => "Hello"},
      %{"type" => "text_delta", "text" => " world"},
      %{
        "type" => "tool_call",
        "id" => "call_1",
        "name" => "bash",
        "input" => %{"cmd" => "echo hi"}
      },
      %{"type" => "tool_result", "id" => "call_1", "is_error" => false, "content" => "hi"},
      %{"type" => "usage", "input_tokens" => 10, "output_tokens" => 5, "cost_usd" => 0.0},
      %{"type" => "done", "ok" => true, "reason" => "success", "final_text" => "Hello world"}
    ]
  end
end
