defmodule RepoBuilder.StackLayers do
  @moduledoc """
  Stack Layers context (stack-layers subsystem): the operator's managed catalog of
  typed tech-stack layers (frontend / backend / database / tooling) and the per-project
  composition that mixes one-or-more layers into a project's stack. The **only** `Repo`
  caller for both `stack_layers` and `project_stack_layers` (BUILD_PROMPT.md §8).

  Two concerns:

    * **Catalog** — CRUD over the typed layer rows. An operator edit/create marks the
      row `source: :manual` so a future `seed_default_layers/0` never clobbers it.
    * **Composition** — the per-project selection (`project_stack_layers`). The enabled
      selection, grouped by type, composes the stack contract injected into every worker
      (`StackLayers.Contract`).
  """
  import Ecto.Query, only: [from: 2]

  alias RepoBuilder.Repo
  alias RepoBuilder.StackLayers.{ProjectStackLayer, StackLayer}

  @type layer_type :: StackLayer.layer_type()

  # The shape of a starter-catalog row in `default_layers/0` (kept precise so the
  # `:underspecs` dialyzer flag stays satisfied).
  @type default_attrs :: %{
          layer_type: layer_type(),
          name: String.t(),
          language: String.t(),
          reasoning: String.t()
        }

  # --- catalog CRUD ---

  @doc "All catalog rows, ordered `layer_type, name`."
  @spec list_layers() :: [StackLayer.t()]
  def list_layers do
    Repo.all(from(l in StackLayer, order_by: [asc: l.layer_type, asc: l.name]))
  end

  @doc """
  Enabled catalog rows grouped by `layer_type` (`%{type => [layer]}`), each list ordered
  by name. Drives the per-type pickers in the UI.
  """
  @spec list_layers_by_type() :: %{layer_type() => [StackLayer.t()]}
  def list_layers_by_type do
    from(l in StackLayer, where: l.enabled == true, order_by: [asc: l.name])
    |> Repo.all()
    |> Enum.group_by(& &1.layer_type)
  end

  @doc "Fetch one catalog row by id, or `nil` when it does not exist."
  @spec get_layer(Ecto.UUID.t()) :: StackLayer.t() | nil
  def get_layer(id), do: Repo.get(StackLayer, id)

  @doc "Create a catalog row (operator action → `source: :manual`)."
  @spec create_layer(map()) :: {:ok, StackLayer.t()} | {:error, Ecto.Changeset.t()}
  def create_layer(params) do
    %StackLayer{}
    |> StackLayer.changeset(manual(params))
    |> Repo.insert()
  end

  @doc "Update a loaded catalog row (operator edit → `source: :manual`)."
  @spec update_layer(StackLayer.t(), map()) ::
          {:ok, StackLayer.t()} | {:error, Ecto.Changeset.t()}
  def update_layer(%StackLayer{} = layer, params) do
    layer
    |> StackLayer.changeset(manual(params))
    |> Repo.update()
  end

  @doc "Delete a catalog row by id. Cascades its `project_stack_layers` selections."
  @spec delete_layer(Ecto.UUID.t()) :: {:ok, StackLayer.t()} | {:error, term()}
  def delete_layer(id) do
    case Repo.get(StackLayer, id) do
      nil -> {:error, :not_found}
      %StackLayer{} = layer -> Repo.delete(layer)
    end
  end

  # --- per-project selection ---

  @doc """
  The enabled layers selected for a project, ordered by `layer_type, name`. A `nil`
  project (the platform orchestrator) — or one with no selection — yields `[]`.
  """
  @spec layers_for_project(Ecto.UUID.t() | nil) :: [StackLayer.t()]
  def layers_for_project(nil), do: []

  def layers_for_project(project_id) when is_binary(project_id) do
    Repo.all(
      from l in StackLayer,
        join: s in ProjectStackLayer,
        on: s.stack_layer_id == l.id,
        where: s.project_id == ^project_id and l.enabled == true,
        order_by: [asc: l.layer_type, asc: l.name]
    )
  end

  @doc "Select a catalog layer for a project (idempotent — re-selecting is a no-op)."
  @spec select_layer(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ProjectStackLayer.t()} | {:error, Ecto.Changeset.t()}
  def select_layer(project_id, stack_layer_id) do
    %ProjectStackLayer{}
    |> ProjectStackLayer.changeset(%{
      "project_id" => project_id,
      "stack_layer_id" => stack_layer_id
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :stack_layer_id]
    )
  end

  @doc "Deselect a catalog layer for a project. `:ok` even when no row existed."
  @spec deselect_layer(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def deselect_layer(project_id, stack_layer_id) do
    Repo.delete_all(
      from s in ProjectStackLayer,
        where: s.project_id == ^project_id and s.stack_layer_id == ^stack_layer_id
    )

    :ok
  end

  @doc """
  Replace a project's entire selection with `stack_layer_ids` (mix & match). Runs in a
  transaction: clears the existing rows, then inserts the new set.
  """
  @spec set_project_layers(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def set_project_layers(project_id, stack_layer_ids) when is_list(stack_layer_ids) do
    Repo.transaction(fn ->
      Repo.delete_all(from s in ProjectStackLayer, where: s.project_id == ^project_id)
      Enum.each(stack_layer_ids, &select_layer(project_id, &1))
    end)

    :ok
  end

  @doc """
  Best-effort auto-seed: select every enabled catalog layer whose `language` matches the
  detected `stack["language"]` or `stack["build_tool"]`. No-op when the project already
  has a selection (never clobbers operator choices) or when nothing matches. Returns the
  number of layers selected.
  """
  @spec seed_project_from_stack(Ecto.UUID.t(), map() | nil) :: {:ok, non_neg_integer()}
  def seed_project_from_stack(project_id, stack) do
    if has_selection?(project_id) do
      {:ok, 0}
    else
      count =
        stack
        |> stack_languages()
        |> layers_matching_languages()
        |> Enum.reduce(0, fn layer, acc -> acc + select_count(project_id, layer.id) end)

      {:ok, count}
    end
  end

  # --- default catalog ---

  @doc """
  Idempotently seed the starter layer catalog. Each row is inserted, or — when it
  already exists as a `:seed` row — refreshed; a row an operator has edited to `:manual`
  is preserved untouched. Returns the number of seed rows processed.
  """
  @spec seed_default_layers() :: {:ok, non_neg_integer()}
  def seed_default_layers do
    count =
      Enum.reduce(default_layers(), 0, fn attrs, acc ->
        case Repo.get_by(StackLayer, layer_type: attrs.layer_type, name: attrs.name) do
          %StackLayer{source: :manual} ->
            acc

          %StackLayer{} = existing ->
            existing |> StackLayer.changeset(Map.put(attrs, :source, :seed)) |> Repo.update()
            acc + 1

          nil ->
            %StackLayer{} |> StackLayer.changeset(Map.put(attrs, :source, :seed)) |> Repo.insert()
            acc + 1
        end
      end)

    {:ok, count}
  end

  # --- internals ---

  @spec manual(map()) :: map()
  defp manual(params), do: params |> stringify_keys() |> Map.put("source", "manual")

  @spec select_count(Ecto.UUID.t(), Ecto.UUID.t()) :: 0 | 1
  defp select_count(project_id, stack_layer_id) do
    case select_layer(project_id, stack_layer_id) do
      {:ok, _} -> 1
      _ -> 0
    end
  end

  @spec has_selection?(Ecto.UUID.t()) :: boolean()
  defp has_selection?(project_id) do
    Repo.exists?(from s in ProjectStackLayer, where: s.project_id == ^project_id)
  end

  @spec stack_languages(map() | nil) :: [String.t()]
  defp stack_languages(stack) when is_map(stack) do
    [stack["language"], stack["build_tool"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp stack_languages(_stack), do: []

  @spec layers_matching_languages([String.t()]) :: [StackLayer.t()]
  defp layers_matching_languages([]), do: []

  defp layers_matching_languages(languages) do
    from(l in StackLayer, where: l.enabled == true)
    |> Repo.all()
    |> Enum.filter(&(String.downcase(&1.language) in languages))
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @spec default_layers() :: [default_attrs()]
  defp default_layers do
    [
      %{
        layer_type: :backend,
        name: "Phoenix",
        language: "elixir",
        reasoning:
          "Build the backend in Elixir on Phoenix. Keep DB access behind @spec'd context " <>
            "modules — controllers, LiveViews, and OTP processes never touch Repo or " <>
            "Ecto.Query directly. Put an @spec on every public function and prefer tagged " <>
            "tuples ({:ok, t} | {:error, reason}) over raising."
      },
      %{
        layer_type: :backend,
        name: "Phoenix LiveView",
        language: "elixir",
        reasoning:
          "Build interactive server-rendered UI with Phoenix LiveView in Elixir. State " <>
            "lives in the LiveView socket; render with HEEx function components. No inline " <>
            "JavaScript frameworks — use JS commands and hooks for client behaviour."
      },
      %{
        layer_type: :frontend,
        name: "Svelte",
        language: "typescript",
        reasoning:
          "Build the frontend in TypeScript with Svelte. Components live under src/; call " <>
            "the backend over HTTP/JSON only — never embed server-side calls or secrets in " <>
            "components. Keep types precise; avoid `any`."
      },
      %{
        layer_type: :frontend,
        name: "React",
        language: "typescript",
        reasoning:
          "Build the frontend in TypeScript with React. Function components and hooks only; " <>
            "talk to the backend over a typed HTTP client. Keep components pure and types " <>
            "precise — no `any`."
      },
      %{
        layer_type: :backend,
        name: "FastAPI",
        language: "python",
        reasoning:
          "Build the backend in Python with FastAPI. Use Pydantic models for request/" <>
            "response schemas and type hints on every endpoint. Keep DB access behind a " <>
            "repository/service layer — routes never run raw queries inline."
      },
      %{
        layer_type: :backend,
        name: "Node",
        language: "javascript",
        reasoning:
          "Build the backend in JavaScript on Node. Use async/await (never blocking I/O), " <>
            "validate input at the edge, and keep route handlers thin — push logic into " <>
            "services/modules."
      },
      %{
        layer_type: :backend,
        name: "Go",
        language: "go",
        reasoning:
          "Build the backend in Go. Handle every error explicitly (no silent `_`), keep " <>
            "packages small and cohesive, and use the standard library before reaching for " <>
            "dependencies."
      },
      %{
        layer_type: :database,
        name: "PostgreSQL",
        language: "sql",
        reasoning:
          "Persist data in PostgreSQL. Every migration is reversible; money is `numeric` " <>
            "(never float); add indexes for foreign keys and hot query paths. Prefer " <>
            "constraints in the schema over application-only checks."
      },
      %{
        layer_type: :database,
        name: "SQLite",
        language: "sql",
        reasoning:
          "Persist data in SQLite. Keep migrations reversible and schema simple; remember " <>
            "SQLite's dynamic typing — be explicit about column affinities and validate at " <>
            "the application boundary."
      },
      %{
        layer_type: :frontend,
        name: "Godot",
        language: "gdscript",
        reasoning:
          "Build the game/engine layer in Godot with GDScript. Organise scenes and nodes " <>
            "idiomatically, keep scripts attached to their nodes, and use signals for " <>
            "decoupled communication rather than tight references."
      },
      %{
        layer_type: :tooling,
        name: "Docker",
        language: "dockerfile",
        reasoning:
          "Containerise with Docker. Pin base-image tags, keep images small (multi-stage " <>
            "builds, minimal layers), never bake secrets into an image, and prefer a " <>
            "non-root runtime user."
      }
    ]
  end
end
