defmodule RepoBuilder.PromptStandard.Population do
  @moduledoc """
  The two prompt populations the standard recognizes (port of the Python `Population`
  enum in `prompt_builder/models.py`):

    * `:a` — factory *slash-command* prompts. They HAVE YAML frontmatter
      (`description`, `argument-hint`, optional `allowed-tools`/`model`).
    * `:b` — runtime `.md` prompts. They are frontmatter-FREE (the loader does a raw
      `File.read!`, so YAML would leak verbatim to the model).

  Population is auto-detected from a file's content (frontmatter present → `:a`, else
  `:b`), overridable by the caller.
  """
  import Kernel, except: [to_string: 1]

  alias RepoBuilder.PromptStandard.Frontmatter

  @type t :: :a | :b

  @doc "Parse a `--population` flag value (`A`/`B`) into a population atom."
  @spec from_string(String.t()) :: {:ok, t()} | {:error, :unknown_population}
  def from_string("A"), do: {:ok, :a}
  def from_string("B"), do: {:ok, :b}
  def from_string(_other), do: {:error, :unknown_population}

  @doc "Render a population atom back to its canonical A/B label."
  @spec to_string(t()) :: String.t()
  def to_string(:a), do: "A"
  def to_string(:b), do: "B"

  @doc "Detect population from raw file content — frontmatter present → `:a`, else `:b`."
  @spec detect(String.t()) :: t()
  def detect(content) when is_binary(content) do
    if Frontmatter.present?(content), do: :a, else: :b
  end
end
