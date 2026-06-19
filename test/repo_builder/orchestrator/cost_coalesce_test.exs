defmodule RepoBuilder.Orchestrator.CostCoalesceTest do
  @moduledoc """
  Orchestrator per-Usage write coalescing (issue hot-path-writes Part B): a streaming
  turn accumulates cost/usage in GenServer state and writes the `orchestrators` row
  ONCE per turn (on Done/Error/terminate) instead of three get+update pairs per Usage
  frame — while still firing the live `[:repo_builder, :cost, :recorded]` telemetry per
  Usage so `Budget.Guard` enforces caps on every increment.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrators

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  defp base_state(orch) do
    %Server.State{
      orchestrator_id: orch.id,
      agent_id: "orch-agent-#{uniq()}",
      prompt: "go",
      harness: "fake",
      in_process?: false
    }
  end

  # Count `orchestrators` UPDATEs for exactly this orchestrator id (so parallel work
  # can't pollute the count), and count the per-event cost telemetry for it.
  defp attach_counters(orch_id) do
    test_pid = self()
    update_h = {__MODULE__, :update, orch_id}
    cost_h = {__MODULE__, :cost, orch_id}
    # The id reaches the query params as the DUMPED 16-byte binary, not the string UUID.
    {:ok, orch_bin} = Ecto.UUID.dump(orch_id)

    :telemetry.attach(
      update_h,
      [:repo_builder, :repo, :query],
      fn _e, _m, meta, _c ->
        query = meta[:query] || ""

        if is_binary(query) and String.starts_with?(query, "UPDATE") and
             String.contains?(query, "orchestrators") and
             Enum.any?(meta[:params] || [], &(&1 == orch_id or &1 == orch_bin)) do
          send(test_pid, :orch_update)
        end
      end,
      nil
    )

    :telemetry.attach(
      cost_h,
      [:repo_builder, :cost, :recorded],
      fn _e, _m, meta, _c ->
        if meta[:orchestrator_id] == orch_id, do: send(test_pid, :cost_recorded)
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn ->
      :telemetry.detach(update_h)
      :telemetry.detach(cost_h)
    end)
  end

  defp usage(cost, est) do
    %Event.Usage{
      harness: :fake,
      input_tokens: 10,
      output_tokens: 5,
      cost_usd: cost,
      estimated_cost_usd: est
    }
  end

  defp drive(state, events) do
    Enum.reduce(events, state, fn ev, st ->
      {:noreply, st2} = Server.handle_info({:harness_event, ev}, st)
      st2
    end)
  end

  defp count(msg), do: count(msg, 0)

  defp count(msg, acc) do
    receive do
      ^msg -> count(msg, acc + 1)
    after
      0 -> acc
    end
  end

  test "M Usage frames + Done write the orchestrators row exactly once" do
    orch = orchestrator()
    attach_counters(orch.id)

    frames = for _ <- 1..5, do: usage(0.01, 0.02)
    state = drive(base_state(orch), frames)

    # No DB write during streaming.
    assert count(:orch_update) == 0

    {:stop, :normal, _state} =
      Server.handle_info(
        {:harness_event, %Event.Done{harness: :fake, ok: true, reason: :success, cost_usd: nil}},
        state
      )

    # Exactly one orchestrators UPDATE across the whole turn (the flush on Done).
    assert count(:orch_update) == 1

    # Budget parity: the cost telemetry fired once per Usage frame (Done carried nil).
    assert count(:cost_recorded) == 5

    {:ok, settled} = Orchestrators.fetch(orch.id)
    # total_cost_usd = sum of the 5 increments (0.05); context/estimate = last frame.
    assert Decimal.equal?(settled.total_cost_usd, Decimal.from_float(0.05))
    assert settled.input_tokens == 50
    assert settled.output_tokens == 25
    assert settled.context_tokens == 15
    assert Decimal.equal?(settled.estimated_cost_usd, Decimal.from_float(0.02))
    assert settled.status == :idle
  end

  test "a turn that dies before a terminal event flushes accumulated cost in terminate/2" do
    orch = orchestrator()
    attach_counters(orch.id)

    state = drive(base_state(orch), [usage(0.03, 0.04), usage(0.03, 0.05)])
    assert count(:orch_update) == 0

    # Crash before Done/Error: terminate/2 best-effort flushes the accumulated cost.
    :ok = Server.terminate(:killed, state)
    assert count(:orch_update) == 1

    {:ok, settled} = Orchestrators.fetch(orch.id)
    assert Decimal.equal?(settled.total_cost_usd, Decimal.from_float(0.06))
    assert settled.input_tokens == 20
    # No terminal event ⇒ status left as-is (the row was created :idle, never forced).
    refute settled.status == :error
  end

  test "terminate/2 is a no-op once a terminal event already flushed" do
    orch = orchestrator()

    state = drive(base_state(orch), [usage(0.02, 0.02)])

    {:stop, :normal, flushed} =
      Server.handle_info(
        {:harness_event, %Event.Done{harness: :fake, ok: true, reason: :success, cost_usd: nil}},
        state
      )

    {:ok, after_done} = Orchestrators.fetch(orch.id)
    attach_counters(orch.id)

    # flushed?: true short-circuits — no second write.
    :ok = Server.terminate(:normal, flushed)
    assert count(:orch_update) == 0

    {:ok, after_terminate} = Orchestrators.fetch(orch.id)
    assert Decimal.equal?(after_terminate.total_cost_usd, after_done.total_cost_usd)
  end
end
