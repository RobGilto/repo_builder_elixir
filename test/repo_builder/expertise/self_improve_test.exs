defmodule RepoBuilder.Expertise.SelfImproveTest do
  @moduledoc """
  Self-healing Phase 5: the LEARN step — re-sync a domain's mental model against changed code by
  appending the next version, with `:keep`/blank/unchanged producing no churn. `async: false`:
  overrides the writable experts root app-wide.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Expertise
  alias RepoBuilder.Expertise.SelfImprove

  setup do
    dir = Path.join(System.tmp_dir!(), "experts-si-#{System.unique_integer([:positive])}")
    original = Application.get_env(:repo_builder, :orchestrator, [])
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :experts_dir, dir))

    on_exit(fn ->
      Application.put_env(:repo_builder, :orchestrator, original)
      File.rm_rf(dir)
    end)

    %{domain: "si-domain-#{System.unique_integer([:positive])}"}
  end

  test "run/2 writes the next version from the learned body", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "stale model")

    assert {:ok, model} =
             SelfImprove.run(domain, fn current ->
               assert current == "stale model"
               {:ok, "refreshed model validated against code"}
             end)

    assert model.version == 2
    assert Expertise.render(domain) == "refreshed model validated against code"
  end

  test "run/2 is :unchanged when learn returns :keep", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "model")
    assert :unchanged = SelfImprove.run(domain, fn _current -> :keep end)
    assert {:ok, %{version: 1}} = Expertise.fetch(domain)
  end

  test "run/2 is :unchanged when the learned body is identical", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "model")
    assert :unchanged = SelfImprove.run(domain, fn current -> {:ok, current} end)
    assert {:ok, %{version: 1}} = Expertise.fetch(domain)
  end

  test "run/2 is :unchanged when the learned body is blank", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "model")
    assert :unchanged = SelfImprove.run(domain, fn _current -> {:ok, "   "} end)
  end

  test "run/2 surfaces a learn error", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "model")
    assert {:error, :boom} = SelfImprove.run(domain, fn _current -> {:error, :boom} end)
  end

  test "run/2 caps an oversized learned body", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "small")
    huge = String.duplicate("y", 40_000)
    assert {:ok, model} = SelfImprove.run(domain, fn _current -> {:ok, huge} end)
    assert byte_size(model.body) <= 16_000
  end
end
