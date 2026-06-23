defmodule RepoBuilder.Commands.Resolved do
  @moduledoc """
  The result of resolving a command name for a project (agentic-layer adaptor): the
  final, capability-token-filled `body` plus the provenance of where it came from
  (`layer`/`pack`/`version`) so the UI can show an operator exactly how each command
  resolves for a repo.
  """
  use TypedStruct

  @type layer :: :repo_local | :pinned_pack | :stack_pack | :generic

  typedstruct enforce: true do
    field :name, String.t()
    field :body, String.t()
    field :layer, layer()
    field :pack, String.t() | nil
    field :version, String.t() | nil
    field :provenance, String.t()
  end
end
