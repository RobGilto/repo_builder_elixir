defmodule RepoBuilder.Adw.CombosTest do
  @moduledoc """
  Context tests for `RepoBuilder.Adw.Combos` — the only module that touches the
  combos filesystem. Hermetic: each test points the writable root at a fresh tmp dir
  via the `Application.get_env(:repo_builder, RepoBuilder.Adw.Combos)[:root]` seam, so
  the real `adws/.combos` and platform `adws/` are never touched.

  `async: false` — mutates the shared `:repo_builder, RepoBuilder.Adw.Combos` app env.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Adw.{Combo, Combos, StepSpec}

  defp step(name, prompt \\ nil),
    do: %StepSpec{name: name, prompt: prompt, harness: nil, provider: nil, model: nil}

  setup do
    original = Application.get_env(:repo_builder, Combos)
    tmp = Path.join(System.tmp_dir!(), "rb_combos_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:repo_builder, Combos, root: tmp)

    on_exit(fn ->
      if original,
        do: Application.put_env(:repo_builder, Combos, original),
        else: Application.delete_env(:repo_builder, Combos)

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp valid(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Plan Build Review",
        steps: ["plan", "build", "review"],
        flavor: :iso,
        spec: "the spec",
        initial_prompt: "do the thing"
      },
      overrides
    )
  end

  describe "save/1" do
    test "writes the sidecar, materializes the .py, and round-trips through fetch/1", %{tmp: tmp} do
      assert {:ok, %Combo{} = combo} = Combos.save(valid())

      assert combo.name == "plan_build_review"
      assert combo.steps == [step(:plan), step(:build), step(:review)]
      assert combo.flavor == :iso
      assert combo.spec == "the spec"
      assert combo.initial_prompt == "do the thing"

      sidecar = Path.join([tmp, "adws", ".combos", "plan_build_review.json"])
      script = Path.join([tmp, "adws", "adw_plan_build_review_iso.py"])
      assert File.exists?(sidecar)
      assert File.exists?(script)
      assert combo.script_path == script

      # The .combos/ subdir must NOT masquerade as a discoverable ADW script.
      refute String.ends_with?(sidecar, ".py")

      assert {:ok, fetched} = Combos.fetch("Plan Build Review")
      assert fetched.name == "plan_build_review"
      assert fetched.steps == [step(:plan), step(:build), step(:review)]
      assert fetched.spec == "the spec"
    end

    test "the local flavor generates the monolithic _local_iso script", %{tmp: tmp} do
      assert {:ok, combo} = Combos.save(valid(%{name: "local demo", flavor: :local_iso}))

      assert combo.flavor == :local_iso
      assert Path.basename(combo.script_path) == "adw_local_demo_local_iso.py"

      assert File.read!(Path.join([tmp, "adws", "adw_local_demo_local_iso.py"])) =~
               "run_local_workflow"
    end

    test "a blank spec/prompt normalizes to nil" do
      assert {:ok, combo} = Combos.save(valid(%{spec: "   ", initial_prompt: ""}))
      assert combo.spec == nil
      assert combo.initial_prompt == nil
    end

    test "the direct flavor generates the monolithic _direct script", %{tmp: tmp} do
      assert {:ok, combo} = Combos.save(valid(%{name: "direct demo", flavor: :direct}))

      assert combo.flavor == :direct
      assert Path.basename(combo.script_path) == "adw_direct_demo_direct.py"

      script_text = File.read!(Path.join([tmp, "adws", "adw_direct_demo_direct.py"]))
      assert script_text =~ "run_local_workflow(adw_id, STEPS, logger, isolated=False)"

      # Sidecar round-trips through fetch with flavor: :direct.
      assert {:ok, fetched} = Combos.fetch("direct_demo")
      assert fetched.flavor == :direct
    end

    test "a name collision returns {:error, :exists} unless overwrite" do
      assert {:ok, _combo} = Combos.save(valid())
      assert {:error, :exists} = Combos.save(valid())
      assert {:ok, _combo} = Combos.save(valid(%{overwrite: true}))
    end

    test "an empty step list is rejected without raising" do
      assert {:error, _reason} = Combos.save(valid(%{steps: []}))
    end

    test "a name that slugifies to empty is rejected" do
      assert {:error, _reason} = Combos.save(valid(%{name: "///"}))
    end
  end

  describe "save/1 with harness and custom prompts" do
    test "persists harness and step prompts; fetch/1 round-trips them", %{tmp: tmp} do
      attrs = %{
        name: "Custom Build",
        steps: [{:plan, nil}, {:build, "Build with Elixir conventions"}],
        flavor: :iso,
        harness: "pi"
      }

      assert {:ok, combo} = Combos.save(attrs)
      assert combo.harness == "pi"
      assert combo.steps == [step(:plan), step(:build, "Build with Elixir conventions")]

      sidecar = Path.join([tmp, "adws", ".combos", "custom_build.json"])
      assert File.exists?(sidecar)

      assert {:ok, fetched} = Combos.fetch("Custom Build")
      assert fetched.harness == "pi"
      assert fetched.steps == [step(:plan), step(:build, "Build with Elixir conventions")]
    end

    test "backward compatibility: old plain-string sidecar decodes without crashing", %{tmp: tmp} do
      # Write a sidecar in the old format (plain string list, no harness field).
      old_json =
        Jason.encode!(%{
          "name" => "old_combo",
          "steps" => ["plan", "build"],
          "flavor" => "iso",
          "spec" => nil,
          "initial_prompt" => nil,
          "script_path" => "",
          "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
        })

      sidecar_dir = Path.join([tmp, "adws", ".combos"])
      File.mkdir_p!(sidecar_dir)
      File.write!(Path.join(sidecar_dir, "old_combo.json"), old_json)

      assert {:ok, combo} = Combos.fetch("old_combo")
      assert combo.steps == [step(:plan), step(:build)]
      assert combo.harness == nil
    end
  end

  describe "list/0 and list/1" do
    test "returns saved combos sorted by name" do
      assert {:ok, _} = Combos.save(valid(%{name: "zebra", steps: ["plan"]}))
      assert {:ok, _} = Combos.save(valid(%{name: "alpha", steps: ["plan"]}))

      names = Combos.list() |> Enum.map(& &1.name)
      assert names == ["alpha", "zebra"]
    end

    test "returns [] when the combos dir does not exist", %{tmp: tmp} do
      assert Combos.list(tmp) == []
    end
  end

  describe "fetch/1" do
    test "returns {:error, :not_found} for an unknown combo" do
      assert {:error, :not_found} = Combos.fetch("nope")
    end
  end

  describe "delete/1" do
    test "removes the sidecar but leaves the generated .py", %{tmp: tmp} do
      assert {:ok, combo} = Combos.save(valid())
      sidecar = Path.join([tmp, "adws", ".combos", "plan_build_review.json"])

      assert File.exists?(sidecar)
      assert :ok = Combos.delete("Plan Build Review")
      refute File.exists?(sidecar)
      # The .py is now a normal discovered ADW; delete leaves it in place.
      assert File.exists?(combo.script_path)
    end

    test "returns {:error, :not_found} for an unknown combo" do
      assert {:error, :not_found} = Combos.delete("nope")
    end
  end
end
