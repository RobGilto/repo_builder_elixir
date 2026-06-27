defmodule RepoBuilder.Expertise.SelfImprove do
  @moduledoc """
  The LEARN step of the expertise ACT→LEARN→REUSE loop (self-healing orchestrator, Phase 5),
  mirroring the reference repo's `plan_build_improve` Step 3.

  After a build ADW completes, `run/2` re-derives a domain's mental model and writes the next
  `Expertise` version: it invokes a `learn_fun` (in production a read-tooled worker that
  re-reads the modules the current model cites — `Module.fun/arity` + line pointers — and diffs
  them against the body; in tests a deterministic function) to produce the refreshed body, then
  appends it via `Expertise.save/3` (size-capped + re-validated). A `learn_fun` that returns
  `:keep` / blank / an error leaves the current model untouched (no spurious version churn).
  """
  require Logger

  alias RepoBuilder.Expertise

  @typedoc "Produces the refreshed model body from the current one (or `:keep` to no-op)."
  @type learn_fun :: (String.t() -> {:ok, String.t()} | :keep | {:error, term()})

  @doc """
  Re-sync `domain`'s mental model. Reads the current body (empty when none yet), runs
  `learn_fun` on it, and on a non-empty result appends a new version. Returns the new model,
  `:unchanged`, or `{:error, reason}`. Never raises.
  """
  @spec run(String.t(), learn_fun()) :: {:ok, Expertise.t()} | :unchanged | {:error, term()}
  def run(domain, learn_fun) when is_binary(domain) and is_function(learn_fun, 1) do
    current = Expertise.render(domain)

    case learn_fun.(current) do
      {:ok, body} when is_binary(body) ->
        if blank?(body) or body == current, do: :unchanged, else: Expertise.save(domain, body)

      :keep ->
        :unchanged

      {:error, reason} ->
        {:error, reason}

      _other ->
        :unchanged
    end
  rescue
    error ->
      Logger.warning("Expertise.SelfImprove failed for #{domain}: #{inspect(error)}")
      {:error, :self_improve_failed}
  end

  @spec blank?(String.t()) :: boolean()
  defp blank?(body), do: String.trim(body) == ""
end
