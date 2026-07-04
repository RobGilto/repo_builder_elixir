defmodule RepoBuilderWeb.TestAdwBuilderPalettePlanF3Test do
  @moduledoc """
  Regression tests for the ADW Builder palette: `:plan_f3` and `:feature` are
  first-class steps with distinct chips and slash commands, and no chip relies
  on display-label aliasing to decide what slash command runs.

  Each of `:plan`, `:plan_f3`, `:feature` exposes its own chip in the palette
  (`~w(plan plan_f3 feature patch build test review document ship)`),
  `adw_step_command/1` no longer maps `"plan" → "feature"`, and the Python
  `adws/adw_new.py:VALID_STEPS` allowlist and `make_script` step loop treat
  each atom distinctly (no `classify_issue` indirection in either new block).

  Models on `test_adw_builder_save_combo_test.exs` for the tmp-dir setup and
  per-test seam.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Adw.Combo
  alias RepoBuilder.Adw.Combos
  alias RepoBuilder.Adw.Scaffold
  alias RepoBuilder.Adw.StepSpec
  alias RepoBuilder.Definitions
  alias RepoBuilderWeb.ConsoleLive.AdwBuilderPanel

  describe "to_step_atom/1 — palette entries" do
    test "plan_f3 resolves" do
      assert {:ok, :plan_f3} = AdwBuilderPanel.to_step_atom("plan_f3")
    end

    test "feature resolves" do
      assert {:ok, :feature} = AdwBuilderPanel.to_step_atom("feature")
    end

    test "plan still resolves (backwards-compat)" do
      assert {:ok, :plan} = AdwBuilderPanel.to_step_atom("plan")
    end

    test "every allowlisted step atom round-trips via StepSpec.from_json/1" do
      for string <- ~w(plan plan_f3 feature patch build test review document ship) do
        assert {:ok, %StepSpec{name: name}} = StepSpec.from_json(string),
               "expected #{string} to parse cleanly through StepSpec.from_json/1"

        assert Atom.to_string(name) == string
      end
    end

    test "unknown steps still return tagged error, never raise" do
      assert {:error, {:invalid_step, "PLAN_F3"}} = StepSpec.from_json("PLAN_F3")

      assert {:error, {:unknown_step, "PLAN_F3"}} =
               AdwBuilderPanel.to_step_atom("PLAN_F3")

      assert {:error, {:unknown_step, "Feature"}} =
               AdwBuilderPanel.to_step_atom("Feature")

      assert {:error, {:unknown_step, ""}} = AdwBuilderPanel.to_step_atom("")
    end
  end

  describe "chip row + dispatch (LiveView integration)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb-palette-pf3-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "adws"))

      prev_combos = Application.get_env(:repo_builder, Combos)
      prev_defs = Application.get_env(:repo_builder, Definitions)

      Application.put_env(:repo_builder, Combos, root: tmp)

      Application.put_env(:repo_builder, Definitions,
        app_root: tmp,
        watch_enabled?: false,
        poll_interval_ms: 30_000
      )

      on_exit(fn ->
        if prev_combos,
          do: Application.put_env(:repo_builder, Combos, prev_combos),
          else: Application.delete_env(:repo_builder, Combos)

        if prev_defs, do: Application.put_env(:repo_builder, Definitions, prev_defs)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "the chip row renders plan, plan_f3 and feature as separate buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")

      assert has_element?(
               view,
               ~s(button[phx-click="adw_add_step"][phx-value-step="plan"])
             )

      assert has_element?(
               view,
               ~s(button[phx-click="adw_add_step"][phx-value-step="plan_f3"])
             )

      assert has_element?(
               view,
               ~s(button[phx-click="adw_add_step"][phx-value-step="feature"])
             )
    end

    test "no plan→feature aliasing: each chip's label is its canonical step atom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      html = render(view)
      doc = LazyHTML.from_document(html)

      # The chip text is the rendered `+ <label>`; assert that the canonical step names
      # all appear in the chip row, with the legacy aliases gone. We use LazyHTML to
      # look up each chip's text content by `phx-value-step`, so the assertion does
      # not depend on HEEx's whitespace/&nbsp; decisions inside the chip body.
      for {step, expected_label} <- [
            {"plan", "+ plan"},
            {"plan_f3", "+ plan_f3"},
            {"feature", "+ feature"},
            {"patch", "+ patch"},
            {"build", "+ implement"},
            {"test", "+ test"},
            {"review", "+ review"},
            {"document", "+ document"},
            {"ship", "+ commit + pr"}
          ] do
        chip_text =
          doc
          |> LazyHTML.query(~s(button[phx-value-step="#{step}"]))
          |> LazyHTML.text()
          |> String.trim()

        assert chip_text == expected_label,
               "chip #{step} rendered as #{inspect(chip_text)}, expected #{inspect(expected_label)}"
      end

      # Specifically: the legacy plan→feature alias is GONE — the "plan" chip
      # renders "+ plan", not "+ feature". The LazyHTML check above already covers
      # this, but we re-state it as a focused negative.
      refute doc
             |> LazyHTML.query(~s(button[phx-value-step="plan"]))
             |> LazyHTML.text()
             |> String.trim()
             |> Kernel.==("+ feature")
    end

    test "clicking plan_f3 adds the step with phx-value-step=\"plan_f3\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_click(view, "adw_add_step", %{"step" => "plan_f3"})

      # The chip is still there (its own button); the step-row gains a row labelled
      # `plan_f3` (NOT `feature`).
      assert has_element?(
               view,
               ~s(button[phx-click="adw_add_step"][phx-value-step="plan_f3"])
             )

      html = render(view)
      assert html =~ "plan_f3"
      # The step-row badge reflects the canonical step name. HEEx may render
      # arbitrary whitespace (newlines + indentation) between the interpolation
      # and the closing </span>, so allow whitespace in the match.
      assert html =~ ~r/plan_f3\s*<\/span>/

      # No alias leakage — the legacy alias would render the step-row as `feature`.
      refute html =~ ~r/class="cns-adw-step-name"[^>]*>\s*feature\s*</
    end

    test "clicking feature adds the step with phx-value-step=\"feature\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "toggle_adw_builder")
      render_click(view, "adw_add_step", %{"step" => "feature"})

      assert has_element?(
               view,
               ~s(button[phx-click="adw_add_step"][phx-value-step="feature"])
             )

      html = render(view)
      # The step-row label is `feature`, not aliased to anything else.
      # HEEx may render arbitrary whitespace between the interpolation and the
      # closing </span>, so allow whitespace in the match.
      assert html =~ ~r/feature\s*<\/span>/
    end

    test "resolve_steps/1 round-trips a [plan_f3, build, test] chain", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/")

      steps = [
        %{id: 1, name: "plan_f3", expanded: false, prompt: nil},
        %{id: 2, name: "build", expanded: false, prompt: nil},
        %{id: 3, name: "test", expanded: false, prompt: nil}
      ]

      assert {:ok, specs} = AdwBuilderPanel.resolve_steps(steps)
      assert Enum.map(specs, & &1.name) == [:plan_f3, :build, :test]
    end
  end

  describe "Scaffold (Python composite script generation)" do
    test "[plan_f3, build, test] renders an :iso script that names plan_f3" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan_f3-build-test",
                 steps: [:plan_f3, :build, :test],
                 flavor: :iso
               })

      # Each step renders a subprocess invocation against adw_<step>_iso.py.
      assert script =~ "adw_plan_f3_iso.py"
      assert script =~ "adw_build_iso.py"
      assert script =~ "adw_test_iso.py"
      # Filename and title reflect the snake_cased stem.
      assert script =~ "adw_plan_f3_build_test_iso.py"
    end

    test "[feature, build, test] renders an :iso script that names feature" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "feature-build-test",
                 steps: [:feature, :build, :test],
                 flavor: :iso
               })

      assert script =~ "adw_feature_iso.py"
      assert script =~ "adw_build_iso.py"
      assert script =~ "adw_test_iso.py"
    end

    test "legacy [plan, build, test] still renders the legacy chain (backwards-compat)" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan-build-test",
                 steps: [:plan, :build, :test],
                 flavor: :iso
               })

      assert script =~ "adw_plan_iso.py"
      assert script =~ "adw_build_iso.py"
      assert script =~ "adw_test_iso.py"
    end

    test "the :local_iso flavor mirrors [plan_f3, build, test] without spawning" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan_f3-build-test",
                 steps: [:plan_f3, :build, :test],
                 flavor: :local_iso
               })

      assert script =~ "Usage: uv run adw_plan_f3_build_test_local_iso.py"
      assert script =~ ~s(STEPS = ["plan_f3", "build", "test"])

      # The monolithic local contract never subprocesses — every step is a plain entry.
      refute script =~ "subprocess.run"
    end

    test "Scaffold refuses unknown atoms with {:error, _} (never raises)" do
      assert {:error, {:invalid_step, :bogus}} =
               Scaffold.render(%{name: "bad", steps: [:bogus], flavor: :iso})

      assert {:error, {:invalid_step, :plan_f}} =
               Scaffold.render(%{name: "bad", steps: [:plan_f], flavor: :iso})
    end

    test "valid_steps/0 includes :plan_f3 and :feature alongside :plan" do
      steps = Scaffold.valid_steps()

      assert :plan in steps
      assert :plan_f3 in steps
      assert :feature in steps
    end
  end

  describe "persisted combos on disk (backwards-compat)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb-pf3-sidecar-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "adws"))

      prev_combos = Application.get_env(:repo_builder, Combos)
      prev_defs = Application.get_env(:repo_builder, Definitions)

      Application.put_env(:repo_builder, Combos, root: tmp)

      Application.put_env(:repo_builder, Definitions,
        app_root: tmp,
        watch_enabled?: false,
        poll_interval_ms: 30_000
      )

      on_exit(fn ->
        if prev_combos,
          do: Application.put_env(:repo_builder, Combos, prev_combos),
          else: Application.delete_env(:repo_builder, Combos)

        if prev_defs, do: Application.put_env(:repo_builder, Definitions, prev_defs)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "a legacy combo JSON with name:\"plan\" round-trips unchanged via Combos.list", %{
      tmp: tmp
    } do
      legacy = %{
        "name" => "plan-build-test",
        "steps" => [
          %{"name" => "plan", "prompt" => nil},
          %{"name" => "build", "prompt" => nil},
          %{"name" => "test", "prompt" => nil}
        ]
      }

      sidecar = Path.join([tmp, "adws", ".combos", "plan-build-test.json"])
      File.mkdir_p!(Path.dirname(sidecar))
      File.write!(sidecar, Jason.encode!(legacy))

      assert [%{name: "plan-build-test"} = combo] = Combos.list(nil)
      assert Enum.map(combo.steps, & &1.name) == [:plan, :build, :test]
    end

    test "a fresh combo JSON with a :plan_f3 + :feature step parses via Combo.from_json/1", %{
      tmp: _tmp
    } do
      combo = %Combo{
        name: "plan_f3-feature-build-test",
        steps: [
          %StepSpec{name: :plan_f3, prompt: nil, harness: nil, provider: nil, model: nil},
          %StepSpec{name: :feature, prompt: nil, harness: nil, provider: nil, model: nil},
          %StepSpec{name: :build, prompt: nil, harness: nil, provider: nil, model: nil},
          %StepSpec{name: :test, prompt: nil, harness: nil, provider: nil, model: nil}
        ],
        flavor: :iso,
        spec: nil,
        initial_prompt: nil,
        harness: nil,
        script_path: "/tmp/adw_plan_f3_feature_build_test_iso.py",
        updated_at: DateTime.utc_now()
      }

      json = Combo.to_json(combo)

      assert {:ok, decoded} = Combo.from_json(json)
      # `from_json/1` preserves the on-disk name verbatim — slugification is a
      # SEPARATE concern handled by `slugify_name/1` (used by `Combos.save/2`
      # before the name ever reaches the sidecar). See the slugify assertions below.
      assert decoded.name == "plan_f3-feature-build-test"
      assert Enum.map(decoded.steps, & &1.name) == [:plan_f3, :feature, :build, :test]
    end

    test "slugify_name/1 slugifies combos with :plan_f3 + :feature steps", %{tmp: _tmp} do
      # The slugifier replaces every run of non-[a-z0-9] with `_`, then trims.
      # Underscores and hyphens both count as separators, so
      # "plan_f3-feature-build-test" → "plan_f3_feature_build_test".
      assert {:ok, "plan_f3_feature_build_test"} =
               Combo.slugify_name("plan_f3-feature-build-test")

      assert {:ok, "feature_build_test"} = Combo.slugify_name("feature build test")
      assert {:ok, "plan_f3"} = Combo.slugify_name("plan_f3")

      # Empty / non-binary inputs stay rejected (never raise).
      assert {:error, :invalid_name} = Combo.slugify_name("   ")
      assert {:error, :missing_name} = Combo.slugify_name(nil)
    end
  end
end
