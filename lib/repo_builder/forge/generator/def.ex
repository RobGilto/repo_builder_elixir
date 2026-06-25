defmodule RepoBuilder.Forge.Generator.Def do
  @moduledoc """
  One generator definition (forge-meta-artifact-generation): the vendored prompt
  `template` filename, the `Plugins.Contribution` kind the produced artifact lands as,
  and the `asset_subdir` it occupies inside the packaged plugin. Split into its own
  module so `Forge.Generator` can reference the struct from a compile-time attribute.
  """
  use TypedStruct

  alias RepoBuilder.Forge.Generator
  alias RepoBuilder.Plugins.Contribution

  typedstruct enforce: true do
    field :kind, Generator.kind()
    field :template, String.t()
    field :contribution_kind, Contribution.kind()
    field :asset_subdir, String.t()
  end
end
