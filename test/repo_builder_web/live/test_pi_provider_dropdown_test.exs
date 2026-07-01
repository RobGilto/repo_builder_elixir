defmodule RepoBuilderWeb.PiProviderDropdownTest do
  @moduledoc """
  Regression for the "pi provider dropdown shows only anthropic" bug.

  Root cause: `Orchestrators.set_model/2` wrote `model` without consulting the current
  `harness`, so an operator could set a zai model (e.g. `glm-4.6`) on a `claude`
  orchestrator — producing an orphan `{claude, nil, glm-4.6}` triple. The header's
  provider dropdown is derived from the persisted `harness` (`provider_options_for/1`),
  so a `claude` orchestrator correctly offers only `anthropic` — even though the model
  chip advertised a zai model. That made `zai` (and every non-anthropic pi provider)
  unselectable.

  The fix keeps the triple coherent: setting a foreign model clears `provider`, and the
  header dropdown always reflects the harness actually persisted.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrators

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  test "the pi harness surfaces zai (and other pi providers) in the provider dropdown", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "pi"})

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.harness == "pi"
    assert reloaded.provider == nil
    assert reloaded.model == nil

    # The provider dropdown now lists zai (and the full pi provider set), not just
    # anthropic — the original symptom.
    assert has_element?(view, "#orchestrator-provider option[value='zai']")
    assert has_element?(view, "#orchestrator-provider option[value='openai']")
    assert has_element?(view, "#orchestrator-provider option[value='google']")
    # claude-only providers never leak into the pi list.
    refute has_element?(view, "#orchestrator-provider optgroup[label='Claude']")
  end

  test "the claude harness lists only anthropic (the dropdown faithfully reflects harness)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "claude"})

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.harness == "claude"
    assert reloaded.provider == "anthropic"

    # Claude offers only anthropic — this is correct, NOT the bug. The bug was reaching
    # this state while a zai model sat on the row.
    assert has_element?(view, "#orchestrator-provider option[value='anthropic'][selected]")
    refute has_element?(view, "#orchestrator-provider option[value='zai']")
  end

  test "setting a zai model on a claude orchestrator clears provider (no orphan triple)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "claude"})

    # The loophole: pick a zai model while the harness is claude. Before the fix this
    # left {claude, "anthropic", glm-4.6} — a zai model advertised under claude's
    # anthropic-only provider list, with no way to select zai. Drive the event
    # directly (the model isn't in claude's rendered <select> options, so the form
    # helper would reject it — which is exactly the orphan signature).
    render_change(view, "set_model", %{"model" => "glm-4.6"})

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.harness == "claude"
    assert reloaded.model == "glm-4.6"
    # The provider is cleared so the operator must re-pick one that actually offers the
    # model — which forces the harness/provider/model triple back into coherence once
    # they switch to pi.
    assert reloaded.provider == nil
    assert reloaded.session_id == nil

    # The header still renders (claude ⇒ anthropic only); the model chip shows the
    # foreign model as "Current" but the provider dropdown cannot surface zai until the
    # harness is flipped to pi.
    assert has_element?(view, "#orchestrator-model option[value='glm-4.6']")
  end

  test "flipping claude→pi restores the full provider list and clears the stale model", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    # Seed the orphan state directly, then prove the harness switch recovers zai.
    render_click(view, "set_harness", %{"harness" => "claude"})
    render_change(view, "set_model", %{"model" => "glm-4.6"})

    render_click(view, "set_harness", %{"harness" => "pi"})

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.harness == "pi"
    # set_harness always clears the model (no auto-default) and resets provider.
    assert reloaded.model == nil
    assert reloaded.provider == nil

    # Now zai is selectable again — the cascade recovered a coherent state.
    assert has_element?(view, "#orchestrator-provider option[value='zai']")

    # Picking zai then a zai model round-trips cleanly end-to-end.
    view |> form("#orchestrator-provider-form", %{"provider" => "zai"}) |> render_change()
    view |> form("#orchestrator-model-form", %{"model" => "glm-4.6"}) |> render_change()

    {:ok, final} = Orchestrators.fetch(orch.id)
    assert final.harness == "pi"
    assert final.provider == "zai"
    assert final.model == "glm-4.6"
  end

  test "a legitimately-unknown concrete model id is accepted (lists are guidance)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    {:ok, orch} = Orchestrators.get_or_create_default()

    render_click(view, "set_harness", %{"harness" => "claude"})

    # A freshly-released concrete id the registry hasn't catalogued must NOT be treated
    # as foreign (the curated lists are guidance, not a constraint — §10 open identity).
    # Drive the event directly; the id isn't in the rendered <select> options.
    render_change(view, "set_model", %{"model" => "claude-opus-4-99"})

    {:ok, reloaded} = Orchestrators.fetch(orch.id)
    assert reloaded.model == "claude-opus-4-99"
    # Legitimately unknown → provider is preserved (not nulled).
    assert reloaded.provider == "anthropic"
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end
end
