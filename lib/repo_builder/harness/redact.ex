defmodule RepoBuilder.Harness.Redact do
  @moduledoc """
  Secret scrubbing for the persisted `raw` escape hatch (BUILD_PROMPT.md §4.1).

  `scrub/1` masks known credential keys at ANY nesting depth in maps AND lists
  (string- or atom-keyed), and truncates oversized blobs. It is total over an
  arbitrary `term()` and NEVER raises.

  The in-flight (PubSub) event keeps the full `raw`; only the persisted copy
  (`agent_logs.payload`, §8) is scrubbed via this module.
  """
  alias RepoBuilder.Harness.Event

  @redacted "[REDACTED]"
  @max_blob_bytes 10_000
  @truncated_suffix "...[truncated]"

  # Lowercased substrings; a key whose downcased name CONTAINS any of these is masked.
  @secret_key_patterns ~w(
    api_key apikey authorization auth_token token secret password passwd
    credential anthropic_api_key openai_api_key access_key access_token
    refresh_token bearer private_key session_key x-api-key
  )

  @doc "Return the event with its `raw` map recursively scrubbed of secrets and oversized blobs."
  @spec scrub(Event.t()) :: Event.t()
  def scrub(%{raw: raw} = event), do: %{event | raw: scrub_term(raw)}

  @doc "Recursively scrub an arbitrary term (exposed for persisting non-event payloads)."
  @spec scrub_term(term()) :: term()
  def scrub_term(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if secret_key?(k), do: {k, @redacted}, else: {k, scrub_term(v)}
    end)
  end

  def scrub_term(list) when is_list(list), do: Enum.map(list, &scrub_term/1)

  def scrub_term(bin) when is_binary(bin) and byte_size(bin) > @max_blob_bytes do
    binary_part(bin, 0, @max_blob_bytes) <> @truncated_suffix
  end

  def scrub_term(other), do: other

  @spec secret_key?(term()) :: boolean()
  defp secret_key?(key) when is_binary(key) do
    down = String.downcase(key)
    Enum.any?(@secret_key_patterns, &String.contains?(down, &1))
  end

  defp secret_key?(key) when is_atom(key) and not is_nil(key) do
    secret_key?(Atom.to_string(key))
  end

  defp secret_key?(_key), do: false
end
