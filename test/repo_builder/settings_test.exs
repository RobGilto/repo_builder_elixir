defmodule RepoBuilder.SettingsTest do
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Settings

  describe "default_agent_models/0" do
    test "falls back to the configured default when no row exists" do
      assert Settings.default_agent_models() ==
               Application.get_env(:repo_builder, :default_agent_models, %{})
    end

    test "returns the persisted roster once set, with string keys (JSONB round-trip)" do
      {:ok, _} = Settings.set_default_agent_model("main", "fake", nil, "my-model")

      roster = Settings.default_agent_models()
      assert roster["main"] == %{"harness" => "fake", "provider" => nil, "model" => "my-model"}
      # no atom keys leak through JSONB
      refute Enum.any?(Map.keys(roster), &is_atom/1)
    end
  end

  describe "planf3_image_placeholders?/0" do
    test "defaults to true when no row exists (placeholders — zero image spend)" do
      assert Settings.planf3_image_placeholders?()
    end

    test "round-trips a persisted false and back" do
      assert {:ok, false} = Settings.put_planf3_image_placeholders(false)
      refute Settings.planf3_image_placeholders?()

      assert {:ok, true} = Settings.put_planf3_image_placeholders(true)
      assert Settings.planf3_image_placeholders?()
    end
  end

  describe "set_default_agent_model/4" do
    test "sets one tier and merges with existing tiers" do
      {:ok, _} = Settings.set_default_agent_model("fast", "fake", nil, "f1")
      {:ok, roster} = Settings.set_default_agent_model("heavy", "fake", "anthropic", "h1")

      assert roster["fast"]["model"] == "f1"
      assert roster["heavy"] == %{"harness" => "fake", "provider" => "anthropic", "model" => "h1"}
    end

    test "rejects an unknown category" do
      assert {:error, :invalid_category} =
               Settings.set_default_agent_model("bogus", "fake", nil, "m")
    end

    test "rejects an unregistered harness" do
      assert {:error, :unknown_harness} =
               Settings.set_default_agent_model("main", "not-a-harness", nil, "m")
    end
  end

  describe "set_default_agent_models/1" do
    test "bulk-replaces the whole roster" do
      {:ok, _} = Settings.set_default_agent_model("fast", "fake", nil, "old")

      roster = %{"main" => %{"harness" => "fake", "provider" => nil, "model" => "new"}}
      {:ok, saved} = Settings.set_default_agent_models(roster)

      assert saved == roster
      assert Settings.default_agent_models() == roster
      refute Map.has_key?(Settings.default_agent_models(), "fast")
    end
  end
end
