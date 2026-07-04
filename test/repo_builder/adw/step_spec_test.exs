defmodule RepoBuilder.Adw.StepSpecTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Adw.StepSpec

  describe "from_json/1 — backward compatibility" do
    test "plain atom returns spec with that name" do
      assert {:ok, %StepSpec{name: :plan, prompt: nil}} = StepSpec.from_json(:plan)
    end

    test "plain string returns spec with that name" do
      assert {:ok, %StepSpec{name: :build}} = StepSpec.from_json("build")
    end

    test "two-field string map" do
      assert {:ok, %StepSpec{name: :plan, prompt: "plan it"}} =
               StepSpec.from_json(%{"name" => "plan", "prompt" => "plan it"})
    end

    test "five-field string map round-trips all fields" do
      map = %{
        "name" => "build",
        "prompt" => "build something",
        "harness" => "claude",
        "provider" => "anthropic",
        "model" => "claude-sonnet-4-6"
      }

      assert {:ok, spec} = StepSpec.from_json(map)
      assert spec.name == :build
      assert spec.prompt == "build something"
      assert spec.harness == "claude"
      assert spec.provider == "anthropic"
      assert spec.model == "claude-sonnet-4-6"
    end

    test "blank string prompt normalized to nil" do
      assert {:ok, %StepSpec{prompt: nil}} =
               StepSpec.from_json(%{"name" => "plan", "prompt" => "  "})
    end

    test "unknown step name returns error" do
      assert {:error, {:invalid_step, "bogus"}} = StepSpec.from_json("bogus")
    end

    test "non-string/non-atom returns :invalid_step" do
      assert {:error, :invalid_step} = StepSpec.from_json(42)
    end

    test "StepSpec passthrough" do
      spec = %StepSpec{name: :plan}
      assert {:ok, ^spec} = StepSpec.from_json(spec)
    end
  end

  describe "to_json/1 — serialization" do
    test "minimal spec emits only name" do
      spec = %StepSpec{name: :plan}
      assert StepSpec.to_json(spec) == %{"name" => "plan"}
    end

    test "spec with all fields emits all of them" do
      spec = %StepSpec{
        name: :build,
        prompt: "do it",
        harness: "pi",
        provider: "openai",
        model: "gpt-4o"
      }

      json = StepSpec.to_json(spec)
      assert json["name"] == "build"
      assert json["prompt"] == "do it"
      assert json["harness"] == "pi"
      assert json["provider"] == "openai"
      assert json["model"] == "gpt-4o"
    end

    test "nil fields are omitted" do
      spec = %StepSpec{name: :review, prompt: "p", harness: nil, provider: nil, model: nil}
      json = StepSpec.to_json(spec)
      refute Map.has_key?(json, "harness")
      refute Map.has_key?(json, "provider")
      refute Map.has_key?(json, "model")
    end
  end

  describe "round-trip" do
    test "to_json |> from_json preserves all fields" do
      original = %StepSpec{
        name: :test,
        prompt: "run the suite",
        harness: "claude",
        provider: "anthropic",
        model: "claude-haiku-4-5"
      }

      assert {:ok, restored} = original |> StepSpec.to_json() |> StepSpec.from_json()
      assert restored == original
    end
  end
end
