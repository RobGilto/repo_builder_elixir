defmodule RepoBuilder.Orchestrators do
  @moduledoc """
  Context for durable orchestrators (BUILD_PROMPT.md §8). The ONLY `Repo` caller
  for `orchestrators`. Every public function is `@spec`'d and returns tagged
  tuples; nothing raises on the happy/expected-error paths.

  Owns the per-orchestrator bearer token used to scope the MCP tool surface: the
  PLAINTEXT token is returned exactly once by `mint_token/1` and never persisted;
  only its SHA-256 hash is stored, and `verify_token/2` compares in constant time.
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Repo

  @default_name "default"

  @doc "The configured default orchestrator settings (harness/model)."
  @spec config() :: keyword()
  def config, do: Application.get_env(:repo_builder, :orchestrator, [])

  @spec default_harness() :: String.t()
  def default_harness do
    config()[:default_harness] || List.first(RepoBuilder.Harness.Registry.known()) || "fake"
  end

  @spec list() :: [Orchestrator.t()]
  def list, do: Repo.all(from(o in Orchestrator, order_by: [asc: o.name]))

  @doc "Fetch an orchestrator by id."
  @spec fetch(Ecto.UUID.t()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  def fetch(id) do
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      orchestrator -> {:ok, orchestrator}
    end
  end

  @doc """
  Idempotently fetch-or-create the singleton "default" orchestrator. On first call
  it is created with `harness` (defaulting to the configured orchestrator harness)
  and the configured default model; subsequent calls return the existing row
  unchanged (its harness/model are NOT overwritten).
  """
  @spec get_or_create_default(String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_default(harness \\ nil) do
    case Repo.get_by(Orchestrator, name: @default_name) do
      %Orchestrator{} = orchestrator ->
        {:ok, orchestrator}

      nil ->
        harness = harness || default_harness()

        %Orchestrator{}
        |> Orchestrator.changeset(%{
          name: @default_name,
          harness: harness,
          model: config()[:default_model]
        })
        |> Repo.insert()
        |> handle_default_race()
    end
  end

  # Two concurrent first-calls can race on the unique :name; the loser hits the
  # constraint and we read the winner's row instead of surfacing an error.
  @spec handle_default_race({:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  defp handle_default_race({:ok, _} = ok), do: ok

  defp handle_default_race({:error, _changeset} = error) do
    case Repo.get_by(Orchestrator, name: @default_name) do
      %Orchestrator{} = orchestrator -> {:ok, orchestrator}
      nil -> error
    end
  end

  @spec create(map()) :: {:ok, Orchestrator.t()} | {:error, Ecto.Changeset.t()}
  def create(params) do
    %Orchestrator{}
    |> Orchestrator.changeset(params)
    |> Repo.insert()
  end

  @doc "Persist the resumable CLI session id captured from the last turn."
  @spec set_session(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_session(id, session_id), do: update_fields(id, %{session_id: session_id})

  @spec set_status(Ecto.UUID.t(), Orchestrator.status()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def set_status(id, status), do: update_fields(id, %{status: status})

  @doc """
  Add `amount` USD to the running total (float→Decimal boundary, §8 rule 10). A
  `nil` amount is a no-op (unpriced harnesses contribute nothing).
  """
  @spec add_cost(Ecto.UUID.t(), float() | Decimal.t() | nil) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  def add_cost(id, nil) do
    # No-op for unpriced turns: return the (unchanged) row so callers never branch.
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      %Orchestrator{} = orchestrator -> {:ok, orchestrator}
    end
  end

  def add_cost(id, amount) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{total_cost_usd: current} = orchestrator ->
        total = Decimal.add(current, to_decimal(amount))
        update_record(orchestrator, %{total_cost_usd: total})
    end
  end

  @doc """
  Mint a fresh per-orchestrator bearer token: returns the PLAINTEXT (caller passes
  it to the harness via env) and stores only its hash. Re-minting rotates the token.
  """
  @spec mint_token(Ecto.UUID.t()) :: {:ok, String.t()} | {:error, :not_found}
  def mint_token(id) do
    case Repo.get(Orchestrator, id) do
      nil ->
        {:error, :not_found}

      %Orchestrator{} = orchestrator ->
        token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        case update_record(orchestrator, %{token_hash: hash(token)}) do
          {:ok, _orchestrator} -> {:ok, token}
          {:error, _changeset} -> {:error, :not_found}
        end
    end
  end

  @doc "Verify a plaintext bearer token against the stored hash (constant-time)."
  @spec verify_token(Ecto.UUID.t(), String.t()) ::
          {:ok, Orchestrator.t()} | {:error, :unauthorized}
  def verify_token(id, token) when is_binary(token) do
    with %Orchestrator{token_hash: stored} when is_binary(stored) <- Repo.get(Orchestrator, id),
         true <- Plug.Crypto.secure_compare(stored, hash(token)) do
      {:ok, Repo.get(Orchestrator, id)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_token(_id, _token), do: {:error, :unauthorized}

  # --- private ---

  @spec update_fields(Ecto.UUID.t(), map()) :: {:ok, Orchestrator.t()} | {:error, :not_found}
  defp update_fields(id, params) do
    case Repo.get(Orchestrator, id) do
      nil -> {:error, :not_found}
      %Orchestrator{} = orchestrator -> update_record(orchestrator, params)
    end
  end

  @spec update_record(Orchestrator.t(), map()) ::
          {:ok, Orchestrator.t()} | {:error, :not_found}
  defp update_record(orchestrator, params) do
    orchestrator
    |> Orchestrator.changeset(params)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :not_found}
    end
  end

  @spec to_decimal(float() | Decimal.t()) :: Decimal.t()
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)

  @spec hash(String.t()) :: String.t()
  defp hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
end
