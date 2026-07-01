defmodule RepoBuilder.Plugins.QualityGateTest do
  @moduledoc """
  WIRE → DOMAIN validation for the quality-gate descriptor (quality-gate-plugins):
  malformed/partial/unknown-cadence JSON never raises and returns `:error`; valid
  descriptors parse to the typed struct; all 7 builtin descriptors load.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Orchestrator.GateResolver
  alias RepoBuilder.Plugins.QualityGate

  @valid ~s({"stack":"elixir","stages":[{"id":"format","command":"{{FORMAT_COMMAND}}","cadence":"per_phase","diagnostic":"summary"}]})

  describe "parse/1" do
    test "normalizes a valid descriptor into the typed struct" do
      assert {:ok, %QualityGate{stack: "elixir", stages: [stage]}} = QualityGate.parse(@valid)

      assert %QualityGate.Stage{
               id: "format",
               command: "{{FORMAT_COMMAND}}",
               strict: true,
               cadence: :per_phase,
               diagnostic: :summary
             } = stage
    end

    test "defaults label to id, strict to true, cadence per_phase, diagnostic file_line" do
      json = ~s({"stack":"go","stages":[{"id":"lint","command":"golangci-lint run"}]})
      assert {:ok, %QualityGate{stages: [stage]}} = QualityGate.parse(json)
      assert stage.label == "lint"
      assert stage.strict == true
      assert stage.cadence == :per_phase
      assert stage.diagnostic == :file_line
    end

    test "parses the pre_merge cadence and the variant tag" do
      json =
        ~s({"stack":"rust","stages":[{"id":"mutation","command":"cargo mutants","cadence":"pre_merge","strict":false},{"id":"type","command":"cargo check","variant":"strict"}]})

      assert {:ok, %QualityGate{stages: [mutation, type]}} = QualityGate.parse(json)
      assert mutation.cadence == :pre_merge
      assert mutation.strict == false
      assert type.variant == :strict
    end

    test "rejects malformed JSON without raising" do
      assert {:error, :invalid_json} = QualityGate.parse("{not json")
    end

    test "rejects a missing stack/stages" do
      assert {:error, :missing_required_fields} = QualityGate.parse(~s({"stack":"go"}))
      assert {:error, :missing_required_fields} = QualityGate.parse(~s({"stages":[]}))
    end

    test "rejects an unknown cadence" do
      json = ~s({"stack":"go","stages":[{"id":"x","command":"y","cadence":"nightly"}]})
      assert {:error, :unknown_cadence} = QualityGate.parse(json)
    end

    test "rejects an unknown diagnostic" do
      json = ~s({"stack":"go","stages":[{"id":"x","command":"y","diagnostic":"xml"}]})
      assert {:error, :unknown_diagnostic} = QualityGate.parse(json)
    end

    test "rejects a stage missing id/command" do
      assert {:error, :invalid_stage} =
               QualityGate.parse(~s({"stack":"go","stages":[{"id":"x"}]}))
    end

    test "rejects a non-list stages" do
      assert {:error, :invalid_stages} =
               QualityGate.parse(~s({"stack":"go","stages":"nope"}))
    end
  end

  describe "from_wire/1" do
    test "rejects a non-map / non-string-keyed value without raising" do
      assert {:error, :invalid_descriptor} = QualityGate.from_wire("nope")
      assert {:error, :invalid_descriptor} = QualityGate.from_wire(%{1 => 2})
    end
  end

  describe "builtin descriptors" do
    test "all 7 builtin descriptors load and parse" do
      for stack <- ~w(elixir rust go python typescript ruby generic) do
        assert {:ok, %QualityGate{stack: ^stack, stages: [_ | _]}} =
                 QualityGate.read(GateResolver.builtin_path(stack)),
               "builtin gate #{stack} failed to load"
      end
    end
  end
end
