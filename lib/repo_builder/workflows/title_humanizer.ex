defmodule RepoBuilder.Workflows.TitleHumanizer do
  @moduledoc """
  Fast-tier, launch-time ADW title humanizer (issue-unified-adw-swimlane-cards).

  ADW display titles come from a workflow's `name`/`type`, but those are sometimes
  machine-looking (`"orch-adw-848273"`, a hex blob, a UUID). When a launched
  workflow's name looks machine-generated, this dispatches a ONE-SHOT **Fast-tier**
  agent (the orchestrator's operator-assigned `fast` roster model) to propose a short,
  human-friendly title, then persists it to `Workflow.metadata["title"]` and
  broadcasts so open consoles upgrade the card title live.

  It mirrors `RepoBuilder.Explain`: resolve the `fast` roster entry, run a one-shot
  ephemeral session with persistence + the global feed disabled, never block the
  caller. The dispatch is fire-and-forget and **always returns `:ok`** — a missing
  Fast tier, a non-machine name, an already-humanized workflow, or a runner failure
  all leave the heuristic title untouched and never error a launch.

  The runner is injected behind a config seam (`:runner`) so tests mock it.
  """
  alias RepoBuilder.{Explain, Orchestrators}
  alias RepoBuilder.Workflows
  alias RepoBuilder.Workflows.Workflow

  @runner_callback {RepoBuilder.Workflows.TitleHumanizer.Server, :dispatch, 2}

  @doc """
  Gate and (fire-and-forget) dispatch a Fast-tier humanization for `workflow`.

  No-ops (returning `:ok`) when: a `metadata["title"]` is already set; the
  `name`/`type` is already human-friendly; `orchestrator_id` is nil/unknown; or the
  orchestrator has no `fast` roster entry. Otherwise dispatches the one-shot runner.
  """
  @spec maybe_humanize_async(Workflow.t(), Ecto.UUID.t() | nil) :: :ok
  def maybe_humanize_async(%Workflow{} = workflow, orchestrator_id) do
    cond do
      already_humanized?(workflow) -> :ok
      not machine_name?(title_source(workflow)) -> :ok
      true -> dispatch(workflow, orchestrator_id)
    end
  end

  @doc """
  Sanitize a model-proposed `raw` title, persist it to `metadata["title"]`, and
  broadcast it. Called by the runner on a successful reply. A blank/invalid reply or
  a persistence failure is a silent no-op (the heuristic title stands).
  """
  @spec apply_title(Workflow.t(), String.t()) :: :ok
  def apply_title(%Workflow{} = workflow, raw) when is_binary(raw) do
    case sanitize(raw) do
      "" ->
        :ok

      title ->
        case Workflows.put_workflow_title(workflow, title) do
          {:ok, updated} ->
            _ = RepoBuilder.Dashboard.broadcast_workflow_title(updated.id, title)
            :ok

          {:error, _changeset} ->
            :ok
        end
    end
  end

  def apply_title(%Workflow{}, _raw), do: :ok

  @doc """
  Build the tight rename instruction from the workflow's `type` and step names.
  """
  @spec build_prompt(Workflow.t()) :: String.t()
  def build_prompt(%Workflow{} = workflow) do
    steps =
      workflow.steps
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "You are naming an AI Developer Workflow for a dashboard. Reply with a SHORT, " <>
      "human-friendly title of AT MOST 4 plain words in Title Case — no punctuation, " <>
      "no quotes, no preamble, no explanation. " <>
      "Workflow type: #{workflow.type || "unknown"}. " <>
      "Steps: #{if steps == "", do: "none", else: steps}."
  end

  @doc """
  Heuristic: does `value` look machine-generated (vs. a human-friendly label)?

  Machine-like = blank/nil, a UUID, a long unbroken digit/hex run, low vowel ratio,
  or a high distinct-character density typical of random ids. Pure and total.
  """
  @spec machine_name?(String.t() | nil) :: boolean()
  def machine_name?(nil), do: true

  def machine_name?(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> true
      uuid?(trimmed) -> true
      true -> token_machine?(core_token(trimmed))
    end
  end

  # --- gating helpers ---

  @spec already_humanized?(Workflow.t()) :: boolean()
  defp already_humanized?(%Workflow{metadata: metadata}) do
    case Map.get(metadata, "title") do
      title when is_binary(title) -> String.trim(title) != ""
      _ -> false
    end
  end

  # Prefer the (often machine-like) name as the humanization trigger; fall back to type.
  @spec title_source(Workflow.t()) :: String.t() | nil
  defp title_source(%Workflow{name: name}) when is_binary(name) and name != "", do: name
  defp title_source(%Workflow{type: type}), do: type

  @spec dispatch(Workflow.t(), Ecto.UUID.t() | nil) :: :ok
  defp dispatch(_workflow, nil), do: :ok

  defp dispatch(%Workflow{} = workflow, orchestrator_id) do
    with {:ok, orchestrator} <- Orchestrators.fetch(orchestrator_id),
         {:ok, config} <- Explain.fast_config(orchestrator) do
      _ = invoke_runner(workflow, config)
      :ok
    else
      _ -> :ok
    end
  end

  @spec invoke_runner(Workflow.t(), Explain.fast_config()) :: term()
  defp invoke_runner(workflow, config) do
    {mod, fun, _arity} =
      Application.get_env(:repo_builder, __MODULE__)[:runner] || @runner_callback

    apply(mod, fun, [workflow, config])
  end

  # --- detector helpers ---

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @spec uuid?(String.t()) :: boolean()
  defp uuid?(value), do: Regex.match?(@uuid_regex, value)

  # The "interesting" token of a name: strip a leading human-ish prefix
  # (`orch-adw-`, `custom-`) and split on separators, taking the longest segment so
  # `"orch-adw-848273"` is judged on `"848273"`, not the friendly prefix.
  @spec core_token(String.t()) :: String.t()
  defp core_token(value) do
    value
    |> String.split(~r/[-_\s]+/, trim: true)
    |> Enum.max_by(&String.length/1, fn -> value end)
  end

  @spec token_machine?(String.t()) :: boolean()
  defp token_machine?(token) do
    letters = String.replace(token, ~r/[^a-z]/i, "")
    digits = String.replace(token, ~r/[^0-9]/, "")
    has_alpha = letters != ""
    has_digit = digits != ""

    cond do
      # A long unbroken digit run (ids, timestamps): "848273", "20260620".
      String.length(digits) >= 5 -> true
      # A mixed alphanumeric blob ("232sdasdasd", "a1b2c3d4") reads machine-like.
      has_alpha and has_digit and String.length(token) >= 6 -> true
      # Short or empty alpha content can't carry a human label.
      String.length(letters) < 3 -> String.length(token) >= 5
      # A long all-letter token with very few vowels (random consonant run).
      String.length(token) >= 10 and vowel_ratio(letters) < 0.25 -> true
      true -> false
    end
  end

  @spec vowel_ratio(String.t()) :: float()
  defp vowel_ratio(""), do: 0.0

  defp vowel_ratio(letters) do
    vowels = letters |> String.downcase() |> String.replace(~r/[^aeiou]/, "") |> String.length()
    vowels / String.length(letters)
  end

  # --- sanitizer ---

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(raw) do
    raw
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/^["'`]+|["'`.]+$/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(6)
    |> Enum.join(" ")
    |> String.slice(0, 60)
    |> String.trim()
  end
end
