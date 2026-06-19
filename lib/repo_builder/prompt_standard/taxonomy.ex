defmodule RepoBuilder.PromptStandard.Taxonomy do
  @moduledoc """
  The A/B section-heading taxonomies and the longest-prefix heading classifier (port of
  the Python module-level constants + `_classify_heading` in `prompt_builder/validator.py`).

  `## Instructions` and `## Variables` are SHARED by both populations and must never trip
  H7. Classification uses the LONGEST section name that prefixes the heading, which is
  required because Population A's `## Workflow` is a literal prefix of Population B's
  `## Workflow Pattern` — a naive prefix test would misclassify the latter as A.
  """

  # Population A: factory slash-command sections (canonical order).
  @population_a_sections [
    "# Purpose",
    "## Variables",
    "## Instructions",
    "## Expertise",
    "## Workflow",
    "## Report"
  ]

  # Population B: runtime .md prompt sections (canonical order per §1c).
  @population_b_sections [
    "## Core Operating Principle",
    "## Your Tools",
    "### Routing rules",
    "## Instructions",
    "## Variables",
    "## Guidelines",
    "## Context Window Management",
    "## Important Notes",
    "## ADW Workflows",
    "## Workflow Pattern",
    "## Agent Specialization Examples",
    "## Available Subagent Templates"
  ]

  @a_set MapSet.new(@population_a_sections)
  @b_set MapSet.new(@population_b_sections)
  @a_only MapSet.difference(@a_set, @b_set)
  @b_only MapSet.difference(@b_set, @a_set)
  @all_sections MapSet.union(@a_set, @b_set)

  @type classification :: :a | :b | :shared | nil

  @doc "The Population A canonical section headings."
  @spec population_a_sections() :: [String.t()]
  def population_a_sections, do: @population_a_sections

  @doc "The Population B canonical section headings."
  @spec population_b_sections() :: [String.t()]
  def population_b_sections, do: @population_b_sections

  @doc "Headings exclusive to Population A (set difference A − B)."
  @spec a_only() :: MapSet.t(String.t())
  def a_only, do: @a_only

  @doc "Headings exclusive to Population B (set difference B − A)."
  @spec b_only() :: MapSet.t(String.t())
  def b_only, do: @b_only

  @doc "Union of both taxonomies (used for longest-prefix classification)."
  @spec all_sections() :: MapSet.t(String.t())
  def all_sections, do: @all_sections

  @doc """
  Classify a markdown heading against the A/B taxonomies: `:a` for a Population-A-only
  section, `:b` for a Population-B-only section, `:shared` for one in both, or `nil` for a
  heading matching neither. Uses the longest matching section name (the section is a prefix
  of the heading, mirroring Python `heading.startswith(s)`).
  """
  @spec classify_heading(String.t()) :: classification()
  def classify_heading(heading) when is_binary(heading) do
    @all_sections
    |> Enum.filter(fn section -> String.starts_with?(heading, section) end)
    |> longest()
    |> classify()
  end

  @spec longest([String.t()]) :: String.t() | nil
  defp longest([]), do: nil
  defp longest(matches), do: Enum.max_by(matches, &String.length/1)

  @spec classify(String.t() | nil) :: classification()
  defp classify(nil), do: nil

  defp classify(section) do
    cond do
      MapSet.member?(@a_only, section) -> :a
      MapSet.member?(@b_only, section) -> :b
      true -> :shared
    end
  end
end
