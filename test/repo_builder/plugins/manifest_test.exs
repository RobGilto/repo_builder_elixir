defmodule RepoBuilder.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Plugins.{Contribution, Manifest}

  @valid ~s({"id":"x","name":"X","version":"1.0.0","contributions":[{"kind":"command_pack","path":"commands"}]})

  describe "parse/1" do
    test "normalizes a valid manifest into the typed struct" do
      assert {:ok, %Manifest{id: "x", name: "X", version: "1.0.0", contributions: [contribution]}} =
               Manifest.parse(@valid)

      assert %Contribution{kind: :command_pack, path: "commands"} = contribution
    end

    test "rejects malformed JSON without raising" do
      assert {:error, :invalid_json} = Manifest.parse("{not json")
    end

    test "rejects an unknown contribution kind" do
      json = ~s({"id":"x","name":"X","version":"1.0.0","contributions":[{"kind":"bogus"}]})
      assert {:error, :unknown_kind} = Manifest.parse(json)
    end

    test "rejects missing required fields" do
      assert {:error, :missing_required_fields} = Manifest.parse(~s({"id":"x"}))
    end

    test "rejects a non-semver version" do
      assert {:error, :bad_version} =
               Manifest.parse(~s({"id":"x","name":"X","version":"not-semver"}))
    end

    test "never raises on arbitrary/odd input" do
      for input <- ["", "[]", "123", "null", ~s({"id":1}), ~s({"contributions":"x"})] do
        assert match?({:error, _}, Manifest.parse(input)),
               "expected an error tuple for #{inspect(input)}"
      end
    end
  end

  describe "predicates" do
    test "compat?/2 honours the platform requirement" do
      {:ok, manifest} =
        Manifest.parse(
          ~s({"id":"x","name":"X","version":"1.0.0","compat":{"platform":">= 3.0.0"}})
        )

      assert Manifest.compat?(manifest, "3.1.0")
      refute Manifest.compat?(manifest, "2.0.0")
    end

    test "compat?/2 is true when no requirement is declared" do
      {:ok, manifest} = Manifest.parse(@valid)
      assert Manifest.compat?(manifest, "0.0.1")
    end

    test "conforms?/1 validates the wire shape via TypeCheck" do
      assert Manifest.conforms?(%{"id" => "x", "name" => "X"})
      refute Manifest.conforms?("not a map")
      refute Manifest.conforms?(%{1 => "non-string key"})
    end

    test "code?/1 detects a code layer" do
      {:ok, plain} = Manifest.parse(@valid)
      refute Manifest.code?(plain)

      {:ok, coded} =
        Manifest.parse(~s({"id":"x","name":"X","version":"1.0.0","code":{"on_load":"M"}}))

      assert Manifest.code?(coded)
    end
  end
end
