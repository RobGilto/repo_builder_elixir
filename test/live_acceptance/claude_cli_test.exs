defmodule RepoBuilder.LiveAcceptance.ClaudeCliTest do
  @moduledoc """
  Live acceptance against the REAL `claude` CLI (audit F6 / roadmap Phase 5.2):
  converts the formerly manual "does the platform drive the real harness?" check
  into an opt-in automated tier.

  Excluded by default (`test_helper.exs` excludes `:live_acceptance`); run with:

      mix test --only live_acceptance

  Requires the `claude` binary on PATH and a working ANTHROPIC login; skips itself
  (with a clear message) when the CLI is absent so the tag can run harmlessly on
  any machine. Spends real tokens — keep the prompt trivial.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Session

  @moduletag :live_acceptance
  @moduletag timeout: 180_000

  test "a real claude session streams canonical events to a terminal Done" do
    if System.find_executable("claude") do
      agent_id = "live-acceptance-#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(RepoBuilder.PubSub, "agent:#{agent_id}:events")

      {:ok, _pid} =
        Session.Supervisor.start_session(
          agent_id: agent_id,
          harness: "claude",
          prompt: "Reply with exactly the word: pong"
        )

      assert_receive {:harness_event, %Event.Done{} = done}, 150_000
      assert done.ok, "real claude run did not terminate cleanly: #{inspect(done)}"
    else
      IO.puts("live_acceptance: `claude` CLI not on PATH — nothing to drive, skipping")
      assert true
    end
  end
end
