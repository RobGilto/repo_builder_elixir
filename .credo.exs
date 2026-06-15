# Credo configuration — enforces the typed coding standard (ai_docs/typed-elixir-standard.md).
#
# Uses the `extra`/`disabled` merge syntax so all of Credo's default checks stay
# enabled and we only ADD the @spec gate on top. Run with `mix credo --strict`.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/", ~r"/priv/"]
      },
      strict: true,
      checks: %{
        extra: [
          # Rule 1 of the typed standard: every public function needs an @spec.
          # The check exempts @impl callback implementations automatically.
          {Credo.Check.Readability.Specs, [include_defp: false]}
        ]
      }
    }
  ]
}
