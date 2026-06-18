defmodule RepoBuilder.Harness.Adw.EventSchema do
  @moduledoc """
  Typed decoder for the NEUTRAL ADW stdout-JSON event contract (issue-the-adw-gap).

  A portable Python ADW run in `--emit json` mode prints exactly one JSON object per
  line to stdout. This module maps each decoded line onto zero-or-more canonical
  `RepoBuilder.Harness.Event` structs — the same canonical stream every other harness
  produces — so the Elixir console, persistence, and cost aggregation are harness-blind.

  ## The contract (schema_version 1)

  Every line is a flat JSON object with a common envelope plus a per-`type` payload:

      {"schema_version": 1, "type": <string>, "adw_id": <string>, "adw_step": <string|null>, ...}

  | `type`            | canonical Event        | notes                                            |
  | ----------------- | ---------------------- | ------------------------------------------------ |
  | `session_started` | `SessionStarted`       | once at stream open; `session_id`/`model`        |
  | `step_start`      | `ToolCall`             | per-step marker (`name` = step slug, `phase`)    |
  | `step_end`        | `ToolResult`           | per-step status/cost/duration                    |
  | `tool`            | `ToolCall`             | a real tool invocation inside a step             |
  | `tool_result`     | `ToolResult`           | a real tool result                               |
  | `text`            | `TextDelta`            | assistant/`thinking` text                        |
  | `usage`           | `Usage`                | tokens + optional `cost_usd` (else derived)      |
  | `done`            | `Done`                 | terminal success                                 |
  | `error`           | `Error`                | terminal failure                                 |

  ## Tolerance (never raises)

  `decode/2` returns `:skip` for an unknown `type`, a missing required field, or a
  `schema_version` this build does not understand (forward/back-compat policy: skip,
  don't crash). A structurally invalid frame is `:skip` too — mirroring the §4.2
  contract that `normalize/2` must never raise on a malformed/unknown frame.
  """
  use TypedStruct

  alias RepoBuilder.Harness.Event
  alias RepoBuilder.Harness.Pricing

  @harness :adw
  @supported_version 1

  @typedoc "Decode context threaded from the adapter's `command/1` (model + price table for cost)."
  @type ctx :: %{optional(atom()) => term()}

  typedstruct module: Envelope, enforce: true do
    @typedoc "The common envelope shared by every neutral ADW event line."
    field :schema_version, integer()
    field :type, String.t()
    field :adw_id, String.t() | nil
    field :adw_step, String.t() | nil
  end

  @doc """
  Decode ONE neutral stdout-JSON frame into canonical events. Never raises; returns
  `:skip` for unknown/older-schema/malformed frames. (The `Harness.normalize/2`
  callback also permits `{:error, _}`; this decoder only ever skips or succeeds.)
  """
  @spec decode(map(), ctx()) :: {:ok, [Event.t()]} | :skip
  def decode(raw, ctx) when is_map(raw) do
    if supported?(raw) do
      decode_type(Map.get(raw, "type"), raw, ctx)
    else
      :skip
    end
  end

  def decode(_raw, _ctx), do: :skip

  # Lenient: a missing version is treated as the current contract; a known integer
  # version must match; anything else (newer/garbled) is skipped, not crashed.
  @spec supported?(map()) :: boolean()
  defp supported?(raw) do
    case Map.get(raw, "schema_version") do
      nil -> true
      v when is_integer(v) -> v == @supported_version
      _ -> false
    end
  end

  @spec decode_type(term(), map(), ctx()) :: {:ok, [Event.t()]} | :skip
  defp decode_type("session_started", raw, _ctx) do
    ok(%Event.SessionStarted{
      harness: @harness,
      session_id: to_string(Map.get(raw, "session_id") || Map.get(raw, "adw_id") || ""),
      model: string_or_nil(Map.get(raw, "model")),
      raw: raw
    })
  end

  defp decode_type("step_start", raw, _ctx) do
    case step_slug(raw) do
      nil ->
        :skip

      step ->
        ok(%Event.ToolCall{
          harness: @harness,
          id: step,
          name: step,
          input: %{
            "phase" => "start",
            "index" => Map.get(raw, "index"),
            "total" => Map.get(raw, "total")
          },
          raw: raw
        })
    end
  end

  defp decode_type("step_end", raw, _ctx) do
    case step_slug(raw) do
      nil ->
        :skip

      step ->
        status = to_string(Map.get(raw, "status") || "succeeded")

        ok(%Event.ToolResult{
          harness: @harness,
          id: step,
          is_error: status in ["failed", "error"],
          content: %{
            "step" => step,
            "status" => status,
            "cost_usd" => Map.get(raw, "cost_usd"),
            "duration_ms" => Map.get(raw, "duration_ms")
          },
          raw: raw
        })
    end
  end

  defp decode_type("tool", raw, _ctx) do
    case string_or_nil(Map.get(raw, "name")) do
      nil ->
        :skip

      name ->
        ok(%Event.ToolCall{
          harness: @harness,
          id: string_or_nil(Map.get(raw, "id")),
          name: name,
          input: map_or_empty(Map.get(raw, "input")),
          raw: raw
        })
    end
  end

  defp decode_type("tool_result", raw, _ctx) do
    ok(%Event.ToolResult{
      harness: @harness,
      id: string_or_nil(Map.get(raw, "id")),
      is_error: Map.get(raw, "is_error", false) == true,
      content: Map.get(raw, "content"),
      raw: raw
    })
  end

  defp decode_type("text", raw, _ctx) do
    case string_or_nil(Map.get(raw, "text")) do
      nil ->
        :skip

      text ->
        ok(%Event.TextDelta{
          harness: @harness,
          text: text,
          thinking?: Map.get(raw, "thinking", false) == true,
          raw: raw
        })
    end
  end

  defp decode_type("usage", raw, ctx) do
    case parse_usage(raw, ctx) do
      %Event.Usage{} = usage -> {:ok, [usage]}
      nil -> :skip
    end
  end

  defp decode_type("done", raw, _ctx) do
    ok(%Event.Done{
      harness: @harness,
      ok: Map.get(raw, "ok", true) != false,
      reason: done_reason(Map.get(raw, "reason"), Map.get(raw, "ok", true) != false),
      final_text: string_or_nil(Map.get(raw, "final_text")),
      cost_usd: float_or_nil(Map.get(raw, "cost_usd")),
      raw: raw
    })
  end

  defp decode_type("error", raw, _ctx) do
    ok(%Event.Error{
      harness: @harness,
      message: to_string(Map.get(raw, "message") || "ADW error"),
      reason: error_reason(Map.get(raw, "reason")),
      retryable: Map.get(raw, "retryable", false) == true,
      raw: raw
    })
  end

  defp decode_type(_unknown, _raw, _ctx), do: :skip

  # --- usage ---

  @spec parse_usage(map(), ctx()) :: Event.Usage.t() | nil
  defp parse_usage(raw, ctx) do
    input = non_neg_int(Map.get(raw, "input_tokens"))
    output = non_neg_int(Map.get(raw, "output_tokens"))

    if is_nil(input) and is_nil(output) do
      nil
    else
      in_tokens = input || 0
      out_tokens = output || 0

      %Event.Usage{
        harness: @harness,
        input_tokens: in_tokens,
        output_tokens: out_tokens,
        cache_read: non_neg_int(Map.get(raw, "cache_read")),
        cache_creation: non_neg_int(Map.get(raw, "cache_creation")),
        cost_usd: usage_cost(raw, in_tokens, out_tokens, ctx),
        raw: raw
      }
    end
  end

  # Prefer an explicit per-event USD cost (the ADW reports Claude's cost directly);
  # otherwise derive from the price table for the run's model (nil ⇒ unpriced).
  @spec usage_cost(map(), non_neg_integer(), non_neg_integer(), ctx()) :: float() | nil
  defp usage_cost(raw, in_tokens, out_tokens, ctx) do
    case float_or_nil(Map.get(raw, "cost_usd")) do
      nil ->
        Pricing.derive(
          Map.get(ctx, :model),
          in_tokens,
          out_tokens,
          Map.get(ctx, :price_table, %{})
        )

      cost ->
        cost
    end
  end

  # --- helpers ---

  @spec ok(Event.t()) :: {:ok, [Event.t()]}
  defp ok(event), do: {:ok, [event]}

  @spec step_slug(map()) :: String.t() | nil
  defp step_slug(raw), do: string_or_nil(Map.get(raw, "adw_step") || Map.get(raw, "step"))

  @spec done_reason(term(), boolean()) :: atom()
  defp done_reason(reason, _ok?)
       when reason in ~w(success clean_exit agent_end max_turns max_budget idle_timeout),
       do: String.to_atom(reason)

  defp done_reason("error_during_execution", _ok?), do: :error_during_execution
  defp done_reason(_reason, true), do: :success
  defp done_reason(_reason, false), do: :error_during_execution

  @spec error_reason(term()) :: atom()
  defp error_reason(reason)
       when reason in ~w(provider_error auto_retry_exhausted idle_timeout spawn_failed no_model_selected),
       do: String.to_atom(reason)

  defp error_reason(_reason), do: :unknown

  @spec string_or_nil(term()) :: String.t() | nil
  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  @spec map_or_empty(term()) :: map()
  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  @spec non_neg_int(term()) :: non_neg_integer() | nil
  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n), do: nil

  @spec float_or_nil(term()) :: float() | nil
  defp float_or_nil(n) when is_float(n), do: n
  defp float_or_nil(n) when is_integer(n), do: n * 1.0
  defp float_or_nil(_n), do: nil
end
