defmodule RepoBuilder.Harness.WireTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.Wire

  test "accepts a well-formed string-keyed JSON object with a binary type discriminator" do
    assert Wire.conforms?(%{"type" => "session", "id" => "x"}, :pi)
    assert Wire.conforms?(%{"type" => "result", "nested" => %{"a" => [1, 2, 3]}}, :claude)
  end

  test "rejects non-objects, atom-keyed maps, and a missing/non-binary type" do
    refute Wire.conforms?(%{"no_type" => 1}, :claude)
    refute Wire.conforms?(%{type: "atom_keyed"}, :claude)
    refute Wire.conforms?(%{"type" => 123}, :claude)
    refute Wire.conforms?("not a map", :pi)
    refute Wire.conforms?(nil, :pi)
  end

  test "never raises and always returns a boolean" do
    assert is_boolean(Wire.conforms?(%{"type" => "x", "weird" => "value"}, :pi))
    assert is_boolean(Wire.conforms?([1, 2, 3], :claude))
  end
end
