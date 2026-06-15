defmodule RepoBuilder.Webhooks do
  @moduledoc """
  Webhook trigger verification (BUILD_PROMPT.md §7).

  A trigger is authenticated by an HMAC-SHA256 signature over `"<timestamp>.<raw_body>"`
  PLUS a timestamp freshness window (replay protection). An invalid/unsigned/expired
  request is rejected BEFORE any Oban job is enqueued — it never becomes a poison job.

  Verification is constant-time (`Plug.Crypto.secure_compare/2`). The raw body bytes
  (not a re-encoded copy) are signed, so the controller must use the cached raw body.
  """
  alias RepoBuilder.WorkflowEngine
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.Workflow

  @type reason ::
          :missing_secret
          | :bad_signature
          | :expired
          | :invalid_payload
          | :workflow_not_found

  @doc """
  Verify a signed webhook and, if valid, durably enqueue the requested workflow.
  Returns `{:ok, run_id}` or `{:error, reason}`.
  """
  @spec verify_and_trigger(binary(), String.t() | nil, String.t() | nil) ::
          {:ok, Ecto.UUID.t()} | {:error, reason()}
  def verify_and_trigger(raw_body, signature, timestamp) do
    with {:ok, secret} <- fetch_secret(),
         :ok <- verify_timestamp(timestamp),
         :ok <- verify_signature(secret, raw_body, timestamp, signature),
         {:ok, payload} <- decode(raw_body),
         {:ok, workflow} <- fetch_workflow(payload) do
      case WorkflowEngine.enqueue_workflow(workflow, Map.get(payload, "inputs", %{})) do
        {:ok, run_id} -> {:ok, run_id}
        {:error, _reason} -> {:error, :invalid_payload}
      end
    end
  end

  @doc "Compute the hex HMAC-SHA256 signature for a body + timestamp (helper for clients/tests)."
  @spec sign(binary(), String.t(), binary()) :: String.t()
  def sign(secret, timestamp, raw_body) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{timestamp}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  # --- steps ---

  @spec fetch_secret() :: {:ok, binary()} | {:error, :missing_secret}
  defp fetch_secret do
    case config(:secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :missing_secret}
    end
  end

  @spec verify_timestamp(String.t() | nil) :: :ok | {:error, :expired}
  defp verify_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        if abs(System.os_time(:second) - seconds) <= window(), do: :ok, else: {:error, :expired}

      _ ->
        {:error, :expired}
    end
  end

  defp verify_timestamp(_timestamp), do: {:error, :expired}

  @spec verify_signature(binary(), binary(), String.t(), String.t() | nil) ::
          :ok | {:error, :bad_signature}
  defp verify_signature(secret, raw_body, timestamp, signature) when is_binary(signature) do
    expected = sign(secret, timestamp, raw_body)
    if Plug.Crypto.secure_compare(expected, signature), do: :ok, else: {:error, :bad_signature}
  end

  defp verify_signature(_secret, _raw_body, _timestamp, _signature), do: {:error, :bad_signature}

  @spec decode(binary()) :: {:ok, map()} | {:error, :invalid_payload}
  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  @spec fetch_workflow(map()) :: {:ok, Workflow.t()} | {:error, :workflow_not_found}
  defp fetch_workflow(payload) do
    name = Map.get(payload, "workflow_name")

    case name && Enum.find(Workflows.list_workflows(), &(&1.name == name)) do
      nil -> {:error, :workflow_not_found}
      workflow -> {:ok, workflow}
    end
  end

  @spec window() :: pos_integer()
  defp window, do: config(:replay_window_seconds) || 300

  defp config(key) do
    :repo_builder
    |> Application.get_env(:webhooks, [])
    |> Keyword.get(key)
  end
end
