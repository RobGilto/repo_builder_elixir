defmodule RepoBuilder.Harness.AdwNormalizeTest do
  @moduledoc """
  Unit tests for the ADW harness adapter (issue-the-adw-gap): `command/1` argv
  construction and `normalize/2` mapping of the neutral stdout-JSON event contract
  onto canonical `Harness.Event` structs — including malformed/unknown/older-schema
  tolerance (never raises). Pure; no DB, no spawn.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Adw
  alias RepoBuilder.Harness.Event

  @ctx %{harness: :adw, model: "claude-sonnet-4-6", price_table: %{}}

  defp normalize(raw), do: Adw.normalize(raw, @ctx)

  describe "command/1" do
    test "builds the uv-run argv with --emit json and a typed session_ctx" do
      opts = %{
        prompt: "ship the thing",
        model: "claude-sonnet-4-6",
        cwd: "/tmp/project",
        sink: self(),
        config: %{
          "adw_type" => "plan_build",
          "adw_script" => "/repo/adws/adw_workflows/adw_plan_build.py",
          "adw_id" => "adw-123"
        }
      }

      assert {"uv", args, env, ctx} = Adw.command(opts)

      assert ["run", "/repo/adws/adw_workflows/adw_plan_build.py" | rest] = args
      assert "--prompt" in rest
      assert "ship the thing" in rest
      assert "--working-dir" in rest
      assert "/tmp/project" in rest
      assert "--adw-id" in rest
      assert "adw-123" in rest
      assert Enum.chunk_every(rest, 2) |> Enum.any?(&(&1 == ["--emit", "json"]))
      assert {"ADW_EMIT", "json"} in env
      assert ctx.harness == :adw
      assert ctx.adw_type == "plan_build"
      assert ctx.adw_id == "adw-123"
    end

    test "an adw_runner override swaps the interpreter (test/fixture seam)" do
      opts = %{
        prompt: "x",
        model: nil,
        cwd: "/tmp/p",
        sink: self(),
        config: %{
          "adw_type" => "faketest",
          "adw_script" => "/tmp/p/fake.py",
          "adw_runner" => "bash"
        }
      }

      assert {"bash", ["/tmp/p/fake.py" | rest], _env, _ctx} = Adw.command(opts)
      # No --model flag when model is nil.
      refute "--model" in rest
    end

    test "falls back to the conventional adw_workflows path when no script is configured" do
      opts = %{
        prompt: "x",
        model: nil,
        cwd: "/tmp/p",
        sink: self(),
        config: %{"adw_type" => "plan_build"}
      }

      assert {"uv", ["run", script | _rest], _env, _ctx} = Adw.command(opts)
      assert script == "/tmp/p/adws/adw_workflows/adw_plan_build.py"
    end
  end

  describe "normalize/2 — per-type mapping" do
    test "session_started" do
      assert {:ok, [%Event.SessionStarted{harness: :adw, session_id: "adw-1", model: "m"}]} =
               normalize(%{
                 "type" => "session_started",
                 "adw_id" => "adw-1",
                 "session_id" => "adw-1",
                 "model" => "m"
               })
    end

    test "step_start → ToolCall named for the step" do
      assert {:ok, [%Event.ToolCall{harness: :adw, name: "plan", id: "plan", input: input}]} =
               normalize(%{
                 "type" => "step_start",
                 "adw_step" => "plan",
                 "index" => 1,
                 "total" => 3
               })

      assert input["phase"] == "start"
      assert input["total"] == 3
    end

    test "step_end → ToolResult carrying status + cost; failed marks is_error" do
      assert {:ok,
              [%Event.ToolResult{harness: :adw, id: "build", is_error: true, content: content}]} =
               normalize(%{
                 "type" => "step_end",
                 "adw_step" => "build",
                 "status" => "failed",
                 "cost_usd" => 0.02
               })

      assert content["status"] == "failed"
      assert content["cost_usd"] == 0.02
    end

    test "tool / tool_result" do
      assert {:ok, [%Event.ToolCall{name: "Bash", input: %{"command" => "ls"}}]} =
               normalize(%{
                 "type" => "tool",
                 "adw_step" => "build",
                 "name" => "Bash",
                 "input" => %{"command" => "ls"}
               })

      assert {:ok, [%Event.ToolResult{is_error: false, content: "ok"}]} =
               normalize(%{"type" => "tool_result", "content" => "ok"})
    end

    test "text (assistant + thinking)" do
      assert {:ok, [%Event.TextDelta{text: "hi", thinking?: false}]} =
               normalize(%{"type" => "text", "text" => "hi"})

      assert {:ok, [%Event.TextDelta{text: "hmm", thinking?: true}]} =
               normalize(%{"type" => "text", "text" => "hmm", "thinking" => true})
    end

    test "usage uses an explicit cost_usd when present" do
      assert {:ok, [%Event.Usage{input_tokens: 10, output_tokens: 5, cost_usd: 0.03}]} =
               normalize(%{
                 "type" => "usage",
                 "input_tokens" => 10,
                 "output_tokens" => 5,
                 "cost_usd" => 0.03
               })
    end

    test "usage derives cost from the price table when cost_usd is absent" do
      ctx = %{harness: :adw, model: "m", price_table: %{"m" => 3.0}}

      assert {:ok, [%Event.Usage{cost_usd: cost}]} =
               Adw.normalize(
                 %{"type" => "usage", "input_tokens" => 1_000_000, "output_tokens" => 0},
                 ctx
               )

      # (1_000_000 + 0) / 1_000_000 * 3.0 == 3.0 (priced, not nil).
      assert cost == 3.0
    end

    test "cache tokens contribute to the derived cost when cost_usd is absent" do
      ctx = %{harness: :adw, model: "m", price_table: %{"m" => 10.0}}

      assert {:ok, [%Event.Usage{cost_usd: cost, cache_read: 1_000_000}]} =
               Adw.normalize(
                 %{
                   "type" => "usage",
                   "input_tokens" => 0,
                   "output_tokens" => 0,
                   "cache_read" => 1_000_000
                 },
                 ctx
               )

      # cache_read 1_000_000 * 10.0 * 0.1 == 1.0 (cache is now priced).
      assert cost == 1.0
    end

    test "done (success + failure reasons)" do
      assert {:ok, [%Event.Done{ok: true, reason: :success}]} =
               normalize(%{"type" => "done", "ok" => true, "reason" => "success"})

      assert {:ok, [%Event.Done{ok: false, reason: :error_during_execution}]} =
               normalize(%{"type" => "done", "ok" => false})
    end

    test "error maps a known reason, else :unknown" do
      assert {:ok, [%Event.Error{message: "boom", reason: :provider_error}]} =
               normalize(%{"type" => "error", "message" => "boom", "reason" => "provider_error"})

      assert {:ok, [%Event.Error{reason: :unknown}]} =
               normalize(%{"type" => "error", "message" => "weird", "reason" => "made_up"})
    end
  end

  describe "normalize/2 — tolerance (never raises)" do
    test "unknown type → :skip" do
      assert :skip = normalize(%{"type" => "totally_new_event", "adw_step" => "plan"})
    end

    test "a newer schema_version is skipped, not crashed" do
      assert :skip = normalize(%{"schema_version" => 999, "type" => "text", "text" => "hi"})
    end

    test "schema_version 1 is honored" do
      assert {:ok, [%Event.TextDelta{}]} =
               normalize(%{"schema_version" => 1, "type" => "text", "text" => "hi"})
    end

    test "missing required fields → :skip (no raise)" do
      assert :skip = normalize(%{"type" => "step_start"})
      assert :skip = normalize(%{"type" => "tool"})
      assert :skip = normalize(%{"type" => "text"})
    end

    test "a non-map / garbage frame → :skip" do
      assert :skip = normalize("not a map")
      assert :skip = normalize(%{"no" => "type"})
    end
  end
end
