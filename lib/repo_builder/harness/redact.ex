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

  @doc """
  Value-based defense-in-depth scrub (issue-per-project-encrypted-secrets-vault): replace
  every exact occurrence of each plaintext in `values` with `[REDACTED]`, in any string at
  any depth of `term`. Complementary to the key-pattern `scrub/1` above.

  Total — never raises. Short-circuits to identity on an empty `values` list, so a project
  with no secrets pays ZERO hot-path cost.
  """
  @spec scrub_values(term(), [String.t()]) :: term()
  def scrub_values(term, []), do: term

  def scrub_values(term, values) when is_list(values) do
    secrets = Enum.filter(values, &(is_binary(&1) and &1 != ""))
    if secrets == [], do: term, else: scrub_values_term(term, secrets)
  end

  @spec scrub_values_term(term(), [String.t()]) :: term()
  defp scrub_values_term(map, secrets) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, scrub_values_term(v, secrets)} end)
  end

  defp scrub_values_term(%_{} = struct, secrets) do
    # Walk a struct's fields too (e.g. an `Event` carrying `raw`/`text`) without losing
    # its type — `Map.from_struct` then rebuild.
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {k, v}, acc -> Map.put(acc, k, scrub_values_term(v, secrets)) end)
  end

  defp scrub_values_term(list, secrets) when is_list(list) do
    Enum.map(list, &scrub_values_term(&1, secrets))
  end

  defp scrub_values_term(bin, secrets) when is_binary(bin) do
    Enum.reduce(secrets, bin, fn secret, acc -> String.replace(acc, secret, @redacted) end)
  end

  defp scrub_values_term(other, _secrets), do: other

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
