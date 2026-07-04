defmodule RepoBuilderWeb.ConsoleLive.AdwBuilderPanel do
  @moduledoc """
  ADW Builder panel of the console (docs/audit-2026-07.md F3, Phase 3): the builder
  toggle, palette source tab, step add/remove/move/toggle/prompt editing, launch, and
  saved-combo save/load/delete event handlers extracted verbatim from `ConsoleLive`.
  `ConsoleLive` delegates the panel's events here.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.{WorkflowEngine, Workflows}
  alias RepoBuilder.WorkflowEngine.Catalog
  alias RepoBuilder.Workflows.TitleHumanizer
  alias RepoBuilderWeb.ConsoleLive.Shared

  @events ~w(toggle_adw_builder set_palette_tab adw_add_step adw_remove_step adw_move_step
             adw_toggle_step adw_set_name adw_set_spec adw_set_prompt adw_toggle_local
             adw_set_harness adw_set_step_prompt run_adw_builder adw_save_combo
             adw_load_combo adw_delete_combo)

  @doc "The event names this panel owns (ConsoleLive's dispatch guard)."
  @spec events() :: [String.t()]
  def events, do: @events

  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("toggle_adw_builder", _params, socket) do
    {:noreply, assign(socket, adw_builder?: !socket.assigns.adw_builder?)}
  end

  # Switch the prompt palette's BASE/PROJECT source tab (issue palette-source-tabs).
  def handle_event("set_palette_tab", %{"tab" => tab}, socket) do
    tab = if tab == "project", do: :project, else: :base
    {:noreply, assign(socket, :palette_source_tab, tab)}
  end

  def handle_event("adw_add_step", %{"step" => step}, socket) do
    steps = socket.assigns.adw_steps
    id = if steps == [], do: 1, else: Enum.max_by(steps, & &1.id).id + 1
    new_step = %{id: id, name: step, expanded: false, prompt: nil}
    {:noreply, assign(socket, adw_steps: steps ++ [new_step])}
  end

  def handle_event("adw_remove_step", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, adw_steps: Enum.reject(socket.assigns.adw_steps, &(&1.id == id)))}
  end

  def handle_event("adw_move_step", %{"id" => id, "dir" => dir}, socket) do
    id = String.to_integer(id)
    steps = socket.assigns.adw_steps
    idx = Enum.find_index(steps, &(&1.id == id))
    new_idx = if dir == "up", do: idx - 1, else: idx + 1

    if new_idx < 0 or new_idx >= length(steps) do
      {:noreply, socket}
    else
      {item, rest} = List.pop_at(steps, idx)
      {:noreply, assign(socket, adw_steps: List.insert_at(rest, new_idx, item))}
    end
  end

  def handle_event("adw_toggle_step", %{"id" => id}, socket) do
    id = String.to_integer(id)

    steps =
      Enum.map(socket.assigns.adw_steps, fn s ->
        if s.id == id, do: %{s | expanded: !s.expanded}, else: s
      end)

    {:noreply, assign(socket, adw_steps: steps)}
  end

  def handle_event("adw_set_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, adw_name: name)}
  end

  def handle_event("adw_set_spec", %{"spec" => spec}, socket) do
    {:noreply, assign(socket, adw_spec: spec)}
  end

  def handle_event("adw_set_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, adw_prompt: prompt)}
  end

  def handle_event("adw_toggle_local", _params, socket) do
    {:noreply, assign(socket, adw_local?: !socket.assigns.adw_local?)}
  end

  def handle_event("adw_set_harness", %{"harness" => h}, socket) do
    {:noreply, assign(socket, adw_harness: Shared.nilify_blank(h))}
  end

  def handle_event("adw_set_step_prompt", %{"id" => id, "value" => v}, socket) do
    id = String.to_integer(id)
    prompt = if String.trim(v) == "", do: nil, else: v

    steps =
      Enum.map(socket.assigns.adw_steps, fn s ->
        if s.id == id, do: %{s | prompt: prompt}, else: s
      end)

    {:noreply, assign(socket, adw_steps: steps)}
  end

  def handle_event("run_adw_builder", _params, socket) do
    steps = socket.assigns.adw_steps

    if steps == [] do
      {:noreply, put_flash(socket, :error, "Add at least one step before launching")}
    else
      harness = socket.assigns.adw_harness || socket.assigns.orchestrator_harness || "fake"

      name =
        socket.assigns.adw_name
        |> then(&if(&1 == "", do: "custom-adw", else: &1))
        |> String.replace(" ", "-")

      {:noreply, launch_adw_builder(steps, name, harness, socket)}
    end
  end

  # Persist the current build as a named combo: writes the JSON sidecar AND
  # materializes adws/adw_<name>_iso.py (or _local_iso.py) via Combos.save/2, then
  # re-seeds the combo list so a Load-combo dropdown stays current.
  def handle_event("adw_save_combo", _params, socket) do
    %{adw_name: name, adw_steps: steps, adw_local?: local?} = socket.assigns

    cond do
      String.trim(name) == "" ->
        {:noreply, put_flash(socket, :error, "Name the combo before saving")}

      steps == [] ->
        {:noreply, put_flash(socket, :error, "Add at least one step before saving")}

      true ->
        working_dir = Shared.nilify_blank(socket.assigns.orchestrator_working_dir)

        attrs = %{
          name: name,
          steps: Enum.map(steps, fn s -> {String.to_existing_atom(s.name), s[:prompt]} end),
          flavor: if(local?, do: :local_iso, else: :iso),
          spec: socket.assigns.adw_spec,
          initial_prompt: socket.assigns.adw_prompt,
          harness: Shared.nilify_blank(socket.assigns.adw_harness || "")
        }

        case Combos.save(attrs, working_dir) do
          {:ok, combo} ->
            socket =
              socket
              |> assign(adw_combos: Combos.list(working_dir))
              |> put_flash(:info, "Saved combo + generated #{Path.basename(combo.script_path)}")

            {:noreply, socket}

          {:error, :exists} ->
            {:noreply,
             put_flash(socket, :error, "A script for that name already exists — pick a new name")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not save combo: #{inspect(reason)}")}
        end
    end
  end

  # Load-combo reuse: repopulate the builder (steps + flavor + spec + prompt + name)
  # from a saved combo. A blank selection is a no-op that just clears the highlight.
  def handle_event("adw_load_combo", %{"combo" => ""}, socket) do
    {:noreply, assign(socket, adw_selected_combo: "")}
  end

  def handle_event("adw_load_combo", %{"combo" => name}, socket) do
    working_dir = Shared.nilify_blank(socket.assigns.orchestrator_working_dir)

    case Combos.fetch(name, working_dir) do
      {:ok, combo} ->
        steps =
          combo.steps
          |> Enum.with_index(1)
          |> Enum.map(fn {{step_name, custom_prompt}, id} ->
            %{id: id, name: Atom.to_string(step_name), expanded: false, prompt: custom_prompt}
          end)

        socket =
          assign(socket,
            adw_steps: steps,
            adw_name: combo.name,
            adw_local?: combo.flavor == :local_iso,
            adw_spec: combo.spec || "",
            adw_prompt: combo.initial_prompt || "",
            adw_harness: combo.harness || "",
            adw_selected_combo: combo.name
          )

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Combo not found: #{name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not load combo: #{inspect(reason)}")}
    end
  end

  # Delete a saved combo's sidecar (the generated .py stays a normal discovered ADW),
  # then re-seed the combo list so the dropdown stays fresh.
  def handle_event("adw_delete_combo", %{"combo" => name}, socket) do
    working_dir = Shared.nilify_blank(socket.assigns.orchestrator_working_dir)

    case Combos.delete(name, working_dir) do
      :ok ->
        socket =
          socket
          |> assign(adw_combos: Combos.list(working_dir), adw_selected_combo: "")
          |> put_flash(:info, "Deleted combo #{name}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete combo: #{inspect(reason)}")}
    end
  end

  # --- private ---

  defp launch_adw_builder(steps, name, harness, socket) do
    spec = socket.assigns.adw_spec
    initial_prompt = socket.assigns.adw_prompt

    # Each builder step gets a REAL prompt_template from the canonical per-step map
    # (shared with Catalog), so launched steps render against the typed prompt/spec
    # instead of the empty-string default in `Step.from_map/1`.
    step_list =
      steps
      |> Enum.map(fn s ->
        %{
          "name" => s.name,
          "harness" => harness,
          "prompt_template" => s[:prompt] || Catalog.default_prompt_template(s.name),
          "on_success" => "done",
          "on_failure" => "abort"
        }
      end)
      |> Enum.with_index()
      |> Enum.map(fn {step, i} ->
        next = Enum.at(steps, i + 1)
        if next, do: Map.put(step, "on_success", next.name), else: step
      end)

    # Thread the spec + initial prompt into the run as artifacts so `Runner.render/2`
    # resolves `{{input}}`/`{{spec}}`. Fall back to name-only when BOTH are blank,
    # preserving today's behavior for empty launches.
    inputs =
      if blank?(initial_prompt) and blank?(spec) do
        %{"input" => name}
      else
        %{"input" => initial_prompt, "spec" => spec}
      end

    with {:ok, wf} <-
           Workflows.create_workflow(%{
             name: "#{name}-#{System.unique_integer([:positive])}",
             type: "custom",
             steps: step_list
           }),
         {:ok, _run_id, _pid} <- WorkflowEngine.start_workflow(wf, inputs: inputs) do
      # Fire-and-forget Fast-tier title humanization (machine-looking name ⇒ friendly).
      _ = TitleHumanizer.maybe_humanize_async(wf, socket.assigns.orchestrator_id)

      socket
      |> assign(
        adw_builder?: false,
        adw_steps: [],
        adw_name: "",
        adw_spec: "",
        adw_prompt: "",
        adw_harness: nil
      )
      |> put_flash(:info, "ADW launched — check the ADWS tab")
    else
      {:error, reason} -> put_flash(socket, :error, "Could not launch ADW: #{inspect(reason)}")
    end
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
end
