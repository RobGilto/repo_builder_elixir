defmodule RepoBuilderWeb.ConsoleLive.SettingsPanel do
  @moduledoc """
  Settings panel of the console (docs/audit-2026-07.md F3, Phase 3): the system-prompt,
  working-dir + directory-picker, reasoning-effort, timezone, settings-tab, and
  stack-layers catalog event handlers extracted verbatim from `ConsoleLive`.
  `ConsoleLive` delegates the panel's events here; cross-panel helpers
  (`update_orchestrator/3`, `seed_definitions/1`, `backfill_events/1`, …) live in
  `ConsoleLive.Shared`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.{Definitions, Orchestrators, StackLayers}
  alias RepoBuilder.FileBrowser
  alias RepoBuilder.StackLayers.StackLayer
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(save_system_prompt set_system_prompt_mode reset_system_prompt save_working_dir
             clear_working_dir open_dir_picker dir_picker_browse dir_picker_goto
             close_dir_picker dir_picker_select set_reasoning_effort set_timezone
             select_settings_tab save_layer edit_layer cancel_layer_edit delete_layer
             toggle_planf3_placeholders)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  # Save the custom system prompt + mode. Blank text persists as nil (spawn falls
  # back to the generated default). The mode comes from the hidden field (current
  # toggle state); never `String.to_atom/1` on operator input.
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("save_system_prompt", %{"system_prompt" => text} = params, socket) do
    mode = system_prompt_mode(params["mode"])

    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_system_prompt(&1, Shared.nilify_blank(text), mode),
      "Could not save system prompt"
    )
  end

  # Persist the append/replace mode immediately (consistent with the other settings),
  # keeping the current stored prompt text unchanged.
  def handle_event("set_system_prompt_mode", %{"mode" => mode}, socket) do
    mode = system_prompt_mode(mode)
    text = Shared.nilify_blank(socket.assigns.orchestrator_system_prompt)

    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_system_prompt(&1, text, mode),
      "Could not set prompt mode"
    )
  end

  # Reset to the generated default (clears the override, restores :append).
  def handle_event("reset_system_prompt", _params, socket) do
    Shared.update_orchestrator(
      socket,
      &Orchestrators.reset_system_prompt(&1),
      "Could not reset system prompt"
    )
  end

  # Persist the orchestrator + worker working directory. Blank clears it (back to an
  # isolated per-session workspace); a non-blank value must be an absolute path to an
  # existing directory, validated before it is stored (no silent un-runnable cwd).
  def handle_event("save_working_dir", %{"working_dir" => dir}, socket) do
    save_working_dir(socket, dir)
  end

  # Clear the working dir (blank ⇒ each agent gets an isolated scratch workspace).
  def handle_event("clear_working_dir", _params, socket) do
    save_working_dir(socket, "")
  end

  # Open the directory picker, starting at the current working dir when it is a valid
  # directory, otherwise the project root (the default).
  def handle_event("open_dir_picker", _params, socket) do
    start =
      case Shared.nilify_blank(socket.assigns.orchestrator_working_dir) do
        path when is_binary(path) ->
          if File.dir?(path), do: path, else: FileBrowser.project_root()

        nil ->
          FileBrowser.project_root()
      end

    {:noreply, socket |> assign(:dir_picker_open?, true) |> load_dir_picker(start)}
  end

  def handle_event("dir_picker_browse", %{"path" => path}, socket) do
    {:noreply, load_dir_picker(socket, path)}
  end

  # Browse straight to a typed/pasted absolute path. Blank ⇒ no-op (no flash spam);
  # otherwise reuse load_dir_picker/2 (expands, lists, flashes + keeps prior view on error).
  def handle_event("dir_picker_goto", %{"path" => path}, socket) do
    case String.trim(path) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, load_dir_picker(socket, trimmed)}
    end
  end

  def handle_event("close_dir_picker", _params, socket) do
    {:noreply, assign(socket, :dir_picker_open?, false)}
  end

  # Commit the currently-browsed directory as the orchestrator cwd, then close the picker.
  def handle_event("dir_picker_select", _params, socket) do
    {:noreply, socket} = save_working_dir(socket, socket.assigns.dir_picker_path)
    {:noreply, assign(socket, :dir_picker_open?, false)}
  end

  # Persist the harness-blind reasoning effort immediately (consistent with the other
  # orchestrator settings). The next run_turn spawns with the per-harness flag.
  def handle_event("set_reasoning_effort", %{"effort" => effort}, socket) do
    Shared.update_orchestrator(
      socket,
      &Orchestrators.set_reasoning_effort(&1, reasoning_effort(effort)),
      "Could not set reasoning effort"
    )
  end

  # Persist the operator's display timezone and re-render the center stream in the new
  # zone (the select snaps back to @timezone on an invalid/failed write — no-op here).
  def handle_event("set_timezone", %{"timezone" => zone}, socket) do
    case socket.assigns.orchestrator_id do
      nil ->
        {:noreply, put_flash(socket, :error, "No orchestrator available")}

      id ->
        case Orchestrators.set_timezone(id, zone) do
          {:ok, orchestrator} ->
            socket =
              socket
              |> Shared.assign_orchestrator_selection(orchestrator)
              |> Shared.backfill_events()
              |> refresh_cost_center_on_tz()

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  # Flip the planf3 plan-image policy (General tab, spec
  # planf3-html-plans-for-heavy-adw-planner Phase 5). Persist the new value, then reseed
  # both assigns so the OFF-state missing-key warning reflects the vault right now.
  def handle_event("toggle_planf3_placeholders", _params, socket) do
    case RepoBuilder.Settings.put_planf3_image_placeholders(
           not socket.assigns.planf3_placeholders?
         ) do
      {:ok, _stored} ->
        {:noreply, Shared.seed_planf3_image_policy(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save the plan-image setting")}
    end
  end

  def handle_event("select_settings_tab", %{"tab" => tab}, socket) do
    selected = settings_tab(tab)
    socket = assign(socket, :settings_tab, selected)
    socket = if selected == :cost_center, do: Shared.load_cost_center(socket), else: socket
    socket = if selected == :stack_layers, do: load_stack_layers(socket), else: socket

    socket =
      if selected == :default_models,
        do: assign(socket, :default_model_rows, Shared.default_model_rows()),
        else: socket

    {:noreply, socket}
  end

  # --- stack layers catalog CRUD (stack-layers subsystem) ---

  # Save a catalog layer: `update_layer/2` when an edit is in flight, else `create_layer/1`.
  # On success re-derive the catalog and reset to create mode; a validation error re-renders
  # the form with the changeset; a stale id (concurrent delete) falls back to create mode.
  def handle_event("save_layer", %{"stack_layer" => params}, socket) do
    result =
      case socket.assigns.editing_layer_id do
        nil ->
          StackLayers.create_layer(params)

        id ->
          case StackLayers.get_layer(id) do
            nil -> {:error, :not_found}
            layer -> StackLayers.update_layer(layer, params)
          end
      end

    case result do
      {:ok, _layer} ->
        {:noreply, socket |> load_stack_layers() |> reset_layer_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :stack_layer_form, to_form(changeset, as: :stack_layer))}

      {:error, :not_found} ->
        {:noreply, socket |> load_stack_layers() |> reset_layer_form()}
    end
  end

  def handle_event("edit_layer", %{"id" => id}, socket) do
    case StackLayers.get_layer(id) do
      nil ->
        {:noreply, socket}

      %StackLayer{} = layer ->
        {:noreply,
         assign(socket,
           editing_layer_id: layer.id,
           stack_layer_form: to_form(StackLayer.changeset(layer, %{}), as: :stack_layer)
         )}
    end
  end

  def handle_event("cancel_layer_edit", _params, socket) do
    {:noreply, reset_layer_form(socket)}
  end

  def handle_event("delete_layer", %{"id" => id}, socket) do
    _ = StackLayers.delete_layer(id)
    socket = load_stack_layers(socket)

    socket =
      if socket.assigns.editing_layer_id == id, do: reset_layer_form(socket), else: socket

    {:noreply, socket}
  end

  # --- private ---

  # Validate + persist a working directory on the orchestrator (shared by the prompt
  # modal's CWD button, the Clear button, and the directory picker's "Use" action).
  @spec save_working_dir(Socket.t(), String.t()) :: {:noreply, Socket.t()}
  defp save_working_dir(socket, dir) do
    case validate_working_dir(dir) do
      {:ok, working_dir} ->
        {:noreply, socket} =
          Shared.update_orchestrator(
            socket,
            &Orchestrators.set_working_dir(&1, working_dir),
            "Could not save working directory"
          )

        # Re-resolve the merged definitions for the new working dir: refresh/1 updates
        # the watcher's tracked dir + broadcasts to every console; the local re-seed
        # makes this console's chips update without waiting on the round-trip.
        :ok = Definitions.refresh(working_dir)
        {:noreply, Shared.seed_definitions(socket)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Load one directory's listing into the picker assigns; flash + keep the prior view
  # on an unreadable/missing path so the picker never lands in a broken state.
  @spec load_dir_picker(Socket.t(), String.t()) :: Socket.t()
  defp load_dir_picker(socket, path) do
    case FileBrowser.list(path) do
      {:ok, listing} ->
        socket
        |> assign(:dir_picker_path, listing.path)
        |> assign(:dir_picker_parent, listing.parent)
        |> assign(:dir_picker_dirs, listing.dirs)

      {:error, _reason} ->
        put_flash(socket, :error, "Cannot open directory: #{path}")
    end
  end

  # Validate an operator-supplied working directory: blank ⇒ {:ok, nil} (clear it);
  # otherwise it must be an ABSOLUTE path to an EXISTING directory before we store it,
  # so a turn never spawns into a missing/relative cwd.
  @spec validate_working_dir(String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  defp validate_working_dir(dir) when is_binary(dir) do
    case Shared.nilify_blank(dir) do
      nil ->
        {:ok, nil}

      path ->
        cond do
          not absolute_path?(path) ->
            {:error, "Working directory must be an absolute path"}

          not File.dir?(path) ->
            {:error, "Working directory does not exist: #{path}"}

          true ->
            {:ok, Path.expand(path)}
        end
    end
  end

  @spec absolute_path?(String.t()) :: boolean()
  defp absolute_path?(path), do: Path.type(path) == :absolute

  # Guard operator-supplied mode string into the closed atom set (never
  # String.to_atom/1 on input). Anything but "replace" defaults to :append.
  @spec system_prompt_mode(String.t() | nil) :: :append | :replace
  defp system_prompt_mode("replace"), do: :replace
  defp system_prompt_mode(_other), do: :append

  # Guard operator-supplied effort string into the closed atom set (never
  # String.to_atom/1 on input). Anything unrecognized defaults to :default (no flag).
  @spec reasoning_effort(String.t() | nil) :: RepoBuilder.Orchestrator.Orchestrator.effort()
  defp reasoning_effort("off"), do: :off
  defp reasoning_effort("low"), do: :low
  defp reasoning_effort("medium"), do: :medium
  defp reasoning_effort("high"), do: :high
  defp reasoning_effort("max"), do: :max
  defp reasoning_effort(_other), do: :default

  @spec settings_tab(String.t()) ::
          :general
          | :appearance
          | :about
          | :prompt
          | :templates
          | :cost_center
          | :stack_layers
          | :default_models
          | :external_apis
          | :logs
  defp settings_tab("appearance"), do: :appearance
  defp settings_tab("about"), do: :about
  defp settings_tab("prompt"), do: :prompt
  defp settings_tab("templates"), do: :templates
  defp settings_tab("cost_center"), do: :cost_center
  defp settings_tab("stack_layers"), do: :stack_layers
  defp settings_tab("default_models"), do: :default_models
  defp settings_tab("external_apis"), do: :external_apis
  defp settings_tab("logs"), do: :logs
  defp settings_tab(_other), do: :general

  # The period-spend windows are timezone-relative — recompute them when the operator
  # changes timezone WHILE looking at the Cost Center tab so the numbers track the new zone.
  @spec refresh_cost_center_on_tz(Socket.t()) :: Socket.t()
  defp refresh_cost_center_on_tz(%{assigns: %{settings_tab: :cost_center}} = socket),
    do: Shared.load_cost_center(socket)

  defp refresh_cost_center_on_tz(socket), do: socket

  @spec load_stack_layers(Socket.t()) :: Socket.t()
  defp load_stack_layers(socket) do
    assign(socket, :stack_layer_rows, StackLayers.list_layers())
  end

  @spec reset_layer_form(Socket.t()) :: Socket.t()
  defp reset_layer_form(socket) do
    assign(socket,
      editing_layer_id: nil,
      stack_layer_form: to_form(StackLayer.changeset(%StackLayer{}, %{}), as: :stack_layer)
    )
  end
end
