defmodule RepoBuilder.Console.EventPresenter do
  @moduledoc """
  Typed presenter mapping a canonical event (live path) or a persisted log payload
  (reconnect backfill) into a small, explicit **render model** for the console event
  stream (issue polished-event-stream-cards).

  This is the single source of truth shared by the live `record_event` path and the
  `log_to_row` backfill path, so both render identical cards — mirroring how
  `RepoBuilder.Logs.context_size/1` and the counter derivation are already shared across
  live and backfill. Pure: no `Repo`, never raises; unexpected shapes degrade to `nil`/`[]`.

  `from_event/1` is the high-fidelity live path (clean `Event` structs). `from_payload/2`
  reads the persisted `agent_logs.payload` (the scrubbed `raw` for tool events,
  `%{"text", "thinking"}` for text), so older rows render with the new polish too — at
  best-effort fidelity for the variants whose persisted payload is the raw wire frame.
  """

  alias RepoBuilder.Harness.Event

  @typedoc "A file touched during a turn, surfaced in the \"Consumed N files\" card."
  @type file_activity :: %{
          path: String.t(),
          action: :read | :write | :edit,
          bytes: non_neg_integer() | nil
        }

  @typedoc """
  The console event-row render model: a one-line `summary`, an optional clean content
  `preview` (collapsed), an optional full `detail` (expanded "Show More"), the
  `tool_name` driving the pill, an `error?` accent flag, and any consumed `files`.
  """
  @type render_model :: %{
          summary: String.t(),
          preview: String.t() | nil,
          detail: String.t() | nil,
          tool_name: String.t() | nil,
          error?: boolean(),
          files: [file_activity()]
        }

  # Longest collapsed preview/summary string before truncation; full text rides on `detail`.
  @preview_limit 240
  @summary_limit 200

  # ToolCall input keys worth surfacing in the compact one-line preview, in priority order.
  @preferred_input_keys ~w(command file_path path pattern query url description prompt)

  # Fixed payload-string → action atom map (NEVER `String.to_atom/1` on payload data).
  @file_actions %{"read" => :read, "write" => :write, "edit" => :edit}

  @doc "Render model for a live canonical `Event.t()` (high fidelity)."
  @spec from_event(Event.t()) :: render_model()
  def from_event(%Event.ToolCall{name: name, input: input}),
    do: tool_call_model(name, input, [])

  def from_event(%Event.ToolResult{is_error: error?, content: content}),
    do: tool_result_model(nil, error?, content, content)

  def from_event(%Event.TextDelta{text: text, raw: raw}),
    do: text_model(text, extract_files(raw))

  def from_event(%Event.Usage{input_tokens: input, output_tokens: output}),
    do: usage_model(input, output)

  def from_event(%Event.Status{kind: kind, detail: detail}),
    do: status_model(to_string(kind), detail)

  def from_event(%Event.Done{reason: reason}),
    do: base(%{summary: "reason=#{reason}"})

  def from_event(%Event.Error{reason: reason, message: message}),
    do: base(%{summary: "#{reason}: #{message}", error?: true})

  def from_event(%Event.SessionStarted{}),
    do: base(%{summary: "session started"})

  @doc """
  Render model from a persisted `event_type` + `payload` (backfill). Mirrors `from_event/1`
  where the persisted shape allows; degrades cleanly (never raising, never dumping raw maps
  into the collapsed body) where the payload is the raw wire frame (tool/usage/status/done).
  """
  @spec from_payload(atom(), map()) :: render_model()
  def from_payload(:tool_call, payload),
    do: tool_call_model(payload_string(payload, "name") || "", payload_map(payload, "input"), [])

  def from_payload(:tool_result, payload),
    do: tool_result_model(nil, payload_error?(payload), payload, payload)

  def from_payload(:text_delta, payload),
    do: text_model(payload_string(payload, "text") || "", extract_files(payload))

  def from_payload(:usage, payload),
    do: usage_model(payload_int(payload, "input_tokens"), payload_int(payload, "output_tokens"))

  def from_payload(:status, payload),
    do: status_model(payload_string(payload, "kind") || "status", payload)

  def from_payload(:done, payload),
    do: base(%{summary: "reason=#{payload_string(payload, "reason") || "done"}"})

  def from_payload(:error, payload),
    do:
      base(%{
        summary:
          "#{payload_string(payload, "reason") || "error"}: #{payload_string(payload, "message") || ""}",
        error?: true
      })

  def from_payload(_type, _payload), do: base(%{summary: ""})

  @doc """
  Plain-text projection of a render model for search/copy (`passes?`,
  `selected_copy_payload`): summary + preview + detail with substring-duplicates dropped
  (so a response row's first-line summary does not repeat its full body).
  """
  @spec search_text(render_model()) :: String.t()
  def search_text(%{summary: summary, preview: preview, detail: detail}) do
    parts = Enum.reject([summary, preview, detail], &blank?/1)

    parts
    |> Enum.reject(fn p -> Enum.any?(parts, fn q -> q != p and String.contains?(q, p) end) end)
    |> Enum.join("\n")
  end

  # --- per-variant builders (shared by live + backfill) ---------------------

  @spec tool_call_model(String.t(), map(), [file_activity()]) :: render_model()
  defp tool_call_model(name, input, files) do
    %{
      summary: "Using tool" <> name_suffix(name),
      preview: compact_inputs(input),
      detail: pretty_inputs(input),
      tool_name: blank_to_nil(name),
      error?: false,
      files: files
    }
  end

  @spec tool_result_model(String.t() | nil, boolean(), term(), term()) :: render_model()
  defp tool_result_model(tool_name, error?, content, files_source) do
    flat = flatten_content(content)

    %{
      summary: "Tool result" <> name_suffix(tool_name || ""),
      preview: clamp(flat),
      detail: long_detail(flat),
      tool_name: blank_to_nil(tool_name),
      error?: !!error?,
      files: extract_files(files_source)
    }
  end

  @spec text_model(String.t(), [file_activity()]) :: render_model()
  defp text_model(text, files) do
    %{
      summary: clamp_summary(first_line(text)),
      preview: nil,
      detail: long_detail(text),
      tool_name: nil,
      error?: false,
      files: files
    }
  end

  @spec usage_model(integer(), integer()) :: render_model()
  defp usage_model(input, output),
    do: base(%{summary: "in=#{input} out=#{output}"})

  @spec status_model(String.t(), map()) :: render_model()
  defp status_model(kind, detail) do
    %{
      summary: kind,
      preview: compact_inputs(detail),
      detail: pretty_inputs(detail),
      tool_name: nil,
      error?: false,
      files: []
    }
  end

  # The minimal render model — a summary line only, with optional `error?` accent.
  @spec base(%{optional(:summary) => String.t(), optional(:error?) => boolean()}) ::
          render_model()
  defp base(fields) do
    %{
      summary: Map.get(fields, :summary, ""),
      preview: nil,
      detail: nil,
      tool_name: nil,
      error?: Map.get(fields, :error?, false),
      files: []
    }
  end

  # --- content flattening ---------------------------------------------------

  @doc """
  Flatten a tool-result `content` term into a readable plain string (or `nil`). Handles
  the Claude block-list shape (`[%{"type" => "text", "text" => "…"}]`), the nested
  `%{"content" => …}` envelope, the pi string result, and a bare string. Any other term
  (integer, deeply-nested map, nil) degrades to `nil` — never raises.
  """
  @spec flatten_content(term()) :: String.t() | nil
  def flatten_content(nil), do: nil
  def flatten_content(text) when is_binary(text), do: blank_to_nil(text)
  def flatten_content(%{"content" => inner}), do: flatten_content(inner)
  def flatten_content(%{"text" => text}) when is_binary(text), do: blank_to_nil(text)

  def flatten_content(list) when is_list(list) do
    list
    |> Enum.map(&block_text/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  def flatten_content(_other), do: nil

  @spec block_text(term()) :: String.t() | nil
  defp block_text(%{"text" => text}) when is_binary(text), do: blank_to_nil(text)
  defp block_text(text) when is_binary(text), do: blank_to_nil(text)
  defp block_text(_other), do: nil

  # --- file activity --------------------------------------------------------

  @doc """
  Extract `file_activity` entries from a term that carries a `"files"` list of
  `%{"path", "action", "bytes"|"size"}` maps. Any other shape yields `[]`. Pure, total.
  """
  @spec extract_files(term()) :: [file_activity()]
  def extract_files(%{"files" => files}) when is_list(files),
    do: Enum.flat_map(files, &file_entry/1)

  def extract_files(_other), do: []

  @spec file_entry(term()) :: [file_activity()]
  defp file_entry(%{"path" => path} = entry) when is_binary(path),
    do: [%{path: path, action: file_action(entry), bytes: file_bytes(entry)}]

  defp file_entry(_entry), do: []

  @spec file_action(map()) :: :read | :write | :edit
  defp file_action(%{"action" => action}) when is_binary(action),
    do: Map.get(@file_actions, action, :read)

  defp file_action(_entry), do: :read

  @spec file_bytes(map()) :: non_neg_integer() | nil
  defp file_bytes(%{"bytes" => bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp file_bytes(%{"size" => bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp file_bytes(_entry), do: nil

  # --- input formatting -----------------------------------------------------

  # Compact one-line preview of a tool/status input map: the first preferred key, else the
  # first key. Empty map ⇒ nil (no preview block). Never dumps the raw `%{}` form.
  @spec compact_inputs(map()) :: String.t() | nil
  defp compact_inputs(input) when is_map(input) and map_size(input) == 0, do: nil

  defp compact_inputs(input) when is_map(input) do
    case preferred_pair(input) do
      {key, value} ->
        clamp("#{key}: #{scalar(value)}")

      nil ->
        input |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{scalar(v)}" end) |> clamp()
    end
  end

  # Full multi-line "key: value" detail of an input map (expanded view), or nil if empty.
  @spec pretty_inputs(map()) :: String.t() | nil
  defp pretty_inputs(input) when map_size(input) == 0, do: nil

  defp pretty_inputs(input),
    do: input |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{scalar(v)}" end)

  @spec preferred_pair(map()) :: {String.t(), term()} | nil
  defp preferred_pair(input) do
    Enum.find_value(@preferred_input_keys, fn key ->
      case Map.fetch(input, key) do
        {:ok, value} -> {key, value}
        :error -> nil
      end
    end)
  end

  # A value rendered as a short scalar string: binaries/numbers verbatim, anything else
  # via a compact `inspect` (so a nested map never blows up the one-line preview).
  @spec scalar(term()) :: String.t()
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_number(value), do: to_string(value)
  defp scalar(value) when is_boolean(value), do: to_string(value)
  defp scalar(value), do: inspect(value, limit: 5, printable_limit: 120)

  # --- payload accessors (backfill, best-effort) ----------------------------
  # `payload` is always the persisted `agent_logs.payload` map; each accessor reads one
  # key defensively and falls back to a typed default for a missing/wrong-typed value.

  @spec payload_string(map(), String.t()) :: String.t() | nil
  defp payload_string(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _other -> nil
    end
  end

  @spec payload_map(map(), String.t()) :: map()
  defp payload_map(payload, key) do
    case Map.get(payload, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  @spec payload_int(map(), String.t()) :: non_neg_integer()
  defp payload_int(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  @spec payload_error?(map()) :: boolean()
  defp payload_error?(payload),
    do: payload["is_error"] == true or payload["isError"] == true

  # --- string helpers -------------------------------------------------------

  @spec name_suffix(String.t()) :: String.t()
  defp name_suffix(name) do
    case blank_to_nil(name) do
      nil -> ""
      value -> ": #{value}"
    end
  end

  @spec first_line(String.t()) :: String.t()
  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
  end

  # Full text behind "Show More" — only when it adds something over the collapsed view
  # (multi-line or longer than the summary cap); otherwise nil so expand shows nothing new.
  @spec long_detail(String.t() | nil) :: String.t() | nil
  defp long_detail(nil), do: nil

  defp long_detail(text) when is_binary(text) do
    cond do
      String.contains?(text, "\n") -> text
      String.length(text) > @summary_limit -> text
      true -> nil
    end
  end

  @spec clamp(String.t() | nil) :: String.t() | nil
  defp clamp(nil), do: nil
  defp clamp(text), do: truncate(text, @preview_limit)

  @spec clamp_summary(String.t()) :: String.t()
  defp clamp_summary(text), do: truncate(text, @summary_limit)

  # Inference-only spec — the two literal `max` call-sites (200/240) supertype under
  # :underspecs, so a hand-written `pos_integer()` spec is rejected by dialyzer.
  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
