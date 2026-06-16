defmodule RepoBuilderWeb.AgentColorsTest do
  @moduledoc "Determinism + totality of the per-agent color helper (BUILD_PROMPT.md §9)."
  use ExUnit.Case, async: true

  alias RepoBuilderWeb.AgentColors

  test "is deterministic: same input always yields the same color" do
    for key <- ["agent-1", "robert", "", "🤖", String.duplicate("x", 300)] do
      assert AgentColors.hex(key) == AgentColors.hex(key)
      assert AgentColors.rgb(key) == AgentColors.rgb(key)
      assert AgentColors.class(key) == AgentColors.class(key)
    end
  end

  test "every color is drawn from the fixed palette" do
    for key <- ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"] do
      assert AgentColors.hex(key) in AgentColors.palette()
    end
  end

  test "is total over arbitrary binaries (never raises, including empty)" do
    for key <- ["", "x", <<0, 255, 10>>, "name with spaces", "uuid-1234-5678"] do
      assert is_binary(AgentColors.hex(key))
      assert AgentColors.rgb(key) =~ ~r/^\d+, \d+, \d+$/
      assert AgentColors.class(key) =~ ~r/^agent-color-\d+$/
    end
  end

  test "assigns/1 bundles hex, rgb, and class consistently" do
    a = AgentColors.assigns("worker-7")
    assert a.hex == AgentColors.hex("worker-7")
    assert a.rgb == AgentColors.rgb("worker-7")
    assert a.class == AgentColors.class("worker-7")
  end
end
