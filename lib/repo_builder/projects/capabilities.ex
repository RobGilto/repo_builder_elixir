defmodule RepoBuilder.Projects.Capabilities do
  @moduledoc """
  The typed per-stack capability map — the small set of values that vary by language
  and that Phase 3's command packs template against (`{{TEST_COMMAND}}` …). Avoids
  duplicating every command body per language: most stacks differ only in these
  dozen values, so a single token-templated command body works everywhere.

  `detect/1` derives sensible defaults from a detected stack descriptor; the operator
  can override any field via the project changeset. Persisted as a string-keyed JSONB
  map on `project.capabilities` (`to_map/1`); read back via `from_map/1`.
  """
  use TypedStruct

  @type stack :: %{optional(String.t()) => term()}

  typedstruct enforce: false do
    field :language, String.t(), default: "unknown"
    field :package_manager, String.t() | nil
    field :test_command, String.t() | nil
    field :build_command, String.t() | nil
    field :lint_command, String.t() | nil
    field :format_command, String.t() | nil
    field :typecheck_command, String.t() | nil
    field :run_command, String.t() | nil
    field :spec_dir, String.t(), default: "specs"
    field :source_dirs, [String.t()], default: []
    field :test_dir, String.t() | nil
  end

  # Per-language defaults. The keys mirror the struct fields. A language absent here
  # falls back to a generic empty map (only spec_dir/language populated).
  @defaults %{
    "elixir" => %{
      package_manager: "mix",
      test_command: "mix test",
      build_command: "mix compile",
      lint_command: "mix credo --strict",
      format_command: "mix format",
      typecheck_command: "mix dialyzer",
      run_command: "mix run",
      spec_dir: "specs",
      source_dirs: ["lib"],
      test_dir: "test"
    },
    "python" => %{
      package_manager: "uv",
      test_command: "uv run pytest",
      build_command: "uv build",
      lint_command: "uv run ruff check",
      format_command: "uv run ruff format",
      typecheck_command: "uv run pyright",
      run_command: "uv run python",
      spec_dir: "specs",
      source_dirs: ["src"],
      test_dir: "tests"
    },
    "node" => %{
      package_manager: "npm",
      test_command: "npm test",
      build_command: "npm run build",
      lint_command: "npm run lint",
      format_command: "npm run format",
      typecheck_command: "npm run typecheck",
      run_command: "npm start",
      spec_dir: "specs",
      source_dirs: ["src"],
      test_dir: "test"
    },
    "rust" => %{
      package_manager: "cargo",
      test_command: "cargo test",
      build_command: "cargo build",
      lint_command: "cargo clippy",
      format_command: "cargo fmt",
      typecheck_command: "cargo check",
      run_command: "cargo run",
      spec_dir: "specs",
      source_dirs: ["src"],
      test_dir: "tests"
    },
    "go" => %{
      package_manager: "go",
      test_command: "go test ./...",
      build_command: "go build ./...",
      lint_command: "golangci-lint run",
      format_command: "gofmt -w .",
      typecheck_command: "go vet ./...",
      run_command: "go run .",
      spec_dir: "specs",
      source_dirs: ["."],
      test_dir: "."
    }
  }

  @fields ~w(package_manager test_command build_command lint_command format_command
             typecheck_command run_command spec_dir source_dirs test_dir)a

  @doc """
  Derive a capability map from a detected stack descriptor (`%{"language" => ...}`).
  An `:unknown`/unrecognised language yields a generic capability map (no commands,
  default `spec_dir`) — every field can still be operator-overridden later.
  """
  @spec detect(stack()) :: t()
  def detect(stack) when is_map(stack) do
    language = to_string(stack["language"] || stack[:language] || "unknown")

    case Map.get(@defaults, language) do
      nil -> %__MODULE__{language: language}
      defaults -> struct(%__MODULE__{language: language}, defaults)
    end
  end

  @doc "Serialize a capability struct to a string-keyed map for JSONB persistence."
  @spec to_map(t()) :: %{optional(String.t()) => term()}
  def to_map(%__MODULE__{} = caps) do
    base = %{"language" => caps.language, "source_dirs" => caps.source_dirs}

    Enum.reduce(@fields, base, fn field, acc ->
      Map.put(acc, Atom.to_string(field), Map.get(caps, field))
    end)
  end

  @doc "Rehydrate a capability struct from a persisted (string-keyed) map."
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(map) when is_map(map) do
    attrs =
      Enum.reduce([:language | @fields], %{}, fn field, acc ->
        case Map.get(map, Atom.to_string(field)) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end
      end)

    struct(%__MODULE__{}, attrs)
  end
end
