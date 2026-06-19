defmodule RepoBuilder.PromptStandard.PopAInput do
  @moduledoc """
  Typed input for `RepoBuilder.PromptStandard.Builder.build_population_a/1` — a factory
  slash-command (Population A). `name` and `purpose` are required; everything else is
  optional. `level >= 7` inserts an `## Expertise` section before `## Workflow` (the
  Workflow-frozen / Expertise-living invariant from prompt-anatomy.md).
  """
  use TypedStruct

  typedstruct do
    field :name, String.t(), enforce: true
    field :purpose, String.t(), enforce: true
    field :variables, String.t() | nil
    field :instructions, String.t() | nil
    field :workflow, String.t() | nil
    field :report, String.t() | nil
    field :level, non_neg_integer(), default: 1
    field :expertise, String.t() | nil
    field :description, String.t(), default: ""
    field :argument_hint, String.t(), default: ""
    field :allowed_tools, String.t() | nil
    field :model, String.t() | nil
  end
end
