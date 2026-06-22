defmodule RepoBuilder.Harness.ModelResolver do
  @moduledoc """
  The single, harness-blind model-resolution seam (issue resolve-spawned-worker-models).

  Maps an operator/orchestrator-selected model to the **latest** model of the same
  family, so a concrete pinned id never silently spawns a stale sibling. Called at the
  two points where the orchestrator "selects a model" for a worker — `create_agent`
  (worker spec) and `configure_tier` (roster entry) — before the value is persisted,
  priced, displayed, and spawned.

  Two resolution strategies, chosen by harness:

    * **Claude** — a concrete `claude-<family>-<version>` id collapses to its family
      *alias* (`opus`/`sonnet`/`haiku`/`fable`). The `claude` CLI itself always resolves
      that alias to the newest member of the family, so this needs zero "latest-version"
      maintenance. An already-alias selection and an unknown family pass through unchanged.
    * **any other harness** (pi, …) — the selection resolves to the first (latest-first)
      entry of the merged ordered catalog (`Pi.Models.list/1` ++
      `Registry.orchestrator_models/2`) sharing the same *family stem*. When no sibling
      can be determined the original selection is returned unchanged.

  Pure (no process state) and fail-soft: a `nil`/blank model, an unknown family, a cold/
  absent catalog, or an unknown harness all return the input unchanged — never a crash
  and never a blank model.
  """
  alias RepoBuilder.Harness.Pi.Models, as: PiModels
  alias RepoBuilder.Harness.Registry

  @claude_families ~w(opus sonnet haiku fable)

  # The Claude family-alias matcher: a concrete id like `claude-opus-4-5` yields `opus`.
  @claude_family ~r/^claude-(opus|sonnet|haiku|fable)\b/

  # Trailing version-token stripper used to compute a family stem. Removes a SINGLE
  # trailing version-ish segment so versioned siblings collapse to one family key while
  # distinct variants stay separate:
  #
  #   * `claude-opus-4-1` -> `claude-opus`   (strips `-4-1`)
  #   * `MiniMax-M2`      -> `MiniMax`       (strips `-M2`)
  #   * `gpt-5`           -> `gpt`           (strips `-5`)
  #   * `gpt-5-mini`      -> `gpt-5-mini`    (trailing `-mini` is not a version)
  #   * `glm-4.5-air`     -> `glm-4.5-air`   (trailing `-air` is not a version)
  #
  # Deliberately conservative: it only strips a trailing numeric/`M<n>`/8-digit-date run,
  # so when in doubt the resolver declines to upgrade rather than risk a wrong-family jump
  # (e.g. `gpt-5-mini` must never cross-upgrade to `gpt-5`).
  @version_suffix ~r/[-_](?:v?\d+(?:[.\-]\d+)*|M\d+|\d{8})$/i

  @doc """
  Resolve `model` to the latest of its family for `harness`+`provider`. Fail-soft: a
  `nil`/blank model, unknown family, absent catalog, or unknown harness returns the
  input unchanged.
  """
  @spec latest(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def latest(_harness, _provider, nil), do: nil
  def latest(_harness, _provider, ""), do: ""
  def latest("claude", _provider, model) when is_binary(model), do: latest_claude(model)

  def latest(harness, provider, model) when is_binary(model),
    do: latest_from_catalog(harness, provider, model)

  # Claude: collapse a concrete id to its family alias (the CLI resolves the alias to
  # latest). An already-alias selection and an unknown family pass through unchanged.
  @spec latest_claude(String.t()) :: String.t()
  defp latest_claude(model) when model in @claude_families, do: model

  defp latest_claude(model) do
    case Regex.run(@claude_family, model) do
      [_full, family] when is_binary(family) -> family
      _ -> model
    end
  end

  # Catalog harnesses: pick the first (latest-first) catalog entry whose family stem
  # matches the selection's stem; otherwise return the selection unchanged.
  @spec latest_from_catalog(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  defp latest_from_catalog(harness, provider, model) do
    stem = family_stem(model)

    (PiModels.list(provider) ++ Registry.orchestrator_models(harness, provider))
    |> Enum.uniq()
    |> Enum.find(model, &(family_stem(&1) == stem))
  end

  # Strip a trailing version token so versioned siblings collapse to one family key.
  @spec family_stem(String.t()) :: String.t()
  defp family_stem(model), do: String.replace(model, @version_suffix, "")
end
