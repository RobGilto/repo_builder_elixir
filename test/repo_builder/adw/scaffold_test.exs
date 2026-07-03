defmodule RepoBuilder.Adw.ScaffoldTest do
  @moduledoc """
  Unit tests for the deterministic Python-ADW generator `RepoBuilder.Adw.Scaffold`.

  The `:iso` render is pinned BYTE-FOR-BYTE against a committed golden fixture
  produced by `adws/adw_new.py make_script(local=false)`, so the Elixir template and
  the Python CLI twin cannot silently drift. The `:local_iso` render is asserted on
  its single-`<adw-id>` + `run_local_workflow` contract. `generate/1` is exercised for
  its filesystem side effects (0755 mode, overwrite refusal) against a tmp root.

  `async: true` — pure render + isolated tmp dirs, no shared app env.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Adw.Scaffold

  @golden_path Path.expand(
                 "../../support/fixtures/adw/adw_plan_build_review_iso.py.golden",
                 __DIR__
               )

  describe "render/1 :iso" do
    test "reproduces the adw_new.py golden fixture byte-for-byte" do
      golden = File.read!(@golden_path)

      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan_build_review",
                 steps: [:plan, :build, :review],
                 flavor: :iso
               })

      assert script == golden
    end

    test "slugifies a dashed/spaced display name into the filename stem" do
      assert {:ok, script} =
               Scaffold.render(%{name: "Plan Build", steps: [:plan, :build], flavor: :iso})

      assert script =~ "adw_plan_build_iso.py"
      assert script =~ "os.path.join(script_dir, \"adw_plan_iso.py\")"
      assert script =~ "from adw_modules.workflow_ops import ensure_adw_id"
    end
  end

  describe "render/1 :local_iso" do
    test "emits the single-<adw-id> monolithic contract, not the chaining form" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan_build",
                 steps: [:plan, :build],
                 flavor: :local_iso
               })

      assert script =~ "Usage: uv run adw_plan_build_local_iso.py <adw-id>"
      assert script =~ "from adw_modules.workflow_ops import run_local_workflow"
      assert script =~ "run_local_workflow(adw_id, STEPS, logger)"
      assert script =~ ~s(STEPS = ["plan", "build"])

      # It must NOT emit the subprocess-chaining GitHub form.
      refute script =~ "issue_number"
      refute script =~ "subprocess.run"
    end
  end

  describe "render/1 with step tuples {step, prompt}" do
    test "extracts step name from tuples; custom prompts are NOT embedded in the script" do
      assert {:ok, script} =
               Scaffold.render(%{
                 name: "plan_build",
                 steps: [{:plan, nil}, {:build, "Custom build prompt"}],
                 flavor: :iso
               })

      # Script renders correctly — step names are extracted from tuples.
      assert script =~ "adw_plan_iso.py"
      assert script =~ "adw_build_iso.py"
      # Custom prompt is NOT embedded in the generated script (it's a runner template).
      refute script =~ "Custom build prompt"
    end

    test "generates the same :local_iso script with or without custom prompts" do
      assert {:ok, with_prompts} =
               Scaffold.render(%{
                 name: "combo",
                 steps: [{:plan, "custom plan"}, {:build, nil}],
                 flavor: :local_iso
               })

      assert {:ok, without_prompts} =
               Scaffold.render(%{
                 name: "combo",
                 steps: [:plan, :build],
                 flavor: :local_iso
               })

      assert with_prompts == without_prompts
    end

    test "rejects a bad step name inside a tuple" do
      assert {:error, {:invalid_step, :deploy}} =
               Scaffold.render(%{name: "x", steps: [{:plan, nil}, {:deploy, "x"}], flavor: :iso})
    end
  end

  describe "render/1 validation" do
    test "rejects an unknown step without raising" do
      assert {:error, {:invalid_step, :deploy}} =
               Scaffold.render(%{name: "x", steps: [:plan, :deploy], flavor: :iso})
    end

    test "rejects an empty step list" do
      assert {:error, :no_steps} = Scaffold.render(%{name: "x", steps: [], flavor: :iso})
    end

    test "rejects a name that slugifies to empty" do
      assert {:error, :invalid_name} =
               Scaffold.render(%{name: "///", steps: [:plan], flavor: :iso})
    end

    test "rejects a non-map request" do
      assert {:error, :invalid_request} = Scaffold.render("nope")
    end
  end

  describe "generate/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb_scaffold_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, root: tmp}
    end

    test "writes an executable (0755) script under <root>/adws/", %{root: root} do
      assert {:ok, gen} =
               Scaffold.generate(%{
                 name: "demo_pbr",
                 steps: [:plan, :build, :review],
                 flavor: :iso,
                 root: root
               })

      assert gen.name == "demo_pbr"
      assert gen.path == Path.join([root, "adws", "adw_demo_pbr_iso.py"])
      assert File.exists?(gen.path)
      assert File.read!(gen.path) == gen.script

      %File.Stat{mode: mode} = File.stat!(gen.path)
      assert Bitwise.band(mode, 0o777) == 0o755
    end

    test "refuses to overwrite an existing script unless asked", %{root: root} do
      req = %{name: "dup", steps: [:plan], flavor: :iso, root: root}

      assert {:ok, _gen} = Scaffold.generate(req)
      assert {:error, :exists} = Scaffold.generate(req)
      assert {:ok, _gen} = Scaffold.generate(Map.put(req, :overwrite, true))
    end

    test "the local flavor writes the _local_iso filename", %{root: root} do
      assert {:ok, gen} =
               Scaffold.generate(%{
                 name: "loc",
                 steps: [:plan, :build],
                 flavor: :local_iso,
                 root: root
               })

      assert Path.basename(gen.path) == "adw_loc_local_iso.py"
    end
  end
end
