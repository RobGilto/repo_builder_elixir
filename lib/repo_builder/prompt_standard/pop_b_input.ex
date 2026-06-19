defmodule RepoBuilder.PromptStandard.PopBInput do
  @moduledoc """
  Typed input for `RepoBuilder.PromptStandard.Builder.build_population_b/1` — a runtime
  `.md` prompt (Population B), front-matter-FREE. `name` and `core_principle` are required;
  the rest are optional sections.
  """
  use TypedStruct

  typedstruct do
    field :name, String.t(), enforce: true
    field :core_principle, String.t(), enforce: true
    field :tools, String.t() | nil
    field :routing_rules, String.t() | nil
    field :instructions, String.t() | nil
    field :guidelines, String.t() | nil
  end
end
