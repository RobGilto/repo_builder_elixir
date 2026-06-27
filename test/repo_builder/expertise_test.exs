defmodule RepoBuilder.ExpertiseTest do
  @moduledoc """
  Self-healing Phase 5: the file-based, versioned, self-improving domain mental model — the
  dual-root render/fetch/save/question/restore, mirroring `Orchestrator.Templates`. `async:
  false` because it overrides the writable experts root app-wide for the test's scope.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Expertise

  setup do
    dir = Path.join(System.tmp_dir!(), "experts-#{System.unique_integer([:positive])}")
    original = Application.get_env(:repo_builder, :orchestrator, [])
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :experts_dir, dir))

    on_exit(fn ->
      Application.put_env(:repo_builder, :orchestrator, original)
      File.rm_rf(dir)
    end)

    %{domain: "test-domain-#{System.unique_integer([:positive])}"}
  end

  test "render/1 is empty for an unknown domain", %{domain: domain} do
    assert Expertise.render(domain) == ""
  end

  test "save/3 then fetch/render round-trips the body", %{domain: domain} do
    {:ok, model} = Expertise.save(domain, "the mental model body")
    assert model.version == 1
    assert {:ok, %{body: "the mental model body"}} = Expertise.fetch(domain)
    assert Expertise.render(domain) == "the mental model body"
  end

  test "save/3 appends monotonic versions", %{domain: domain} do
    {:ok, v1} = Expertise.save(domain, "v1 body")
    {:ok, v2} = Expertise.save(domain, "v2 body")
    assert v1.version == 1
    assert v2.version == 2
    assert Expertise.render(domain) == "v2 body"
  end

  test "question/2 is read-only (no new version written)", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "the body")
    {:ok, %{version: before}} = Expertise.fetch(domain)

    assert {:ok, %{body: "the body"}} = Expertise.question(domain, "how does X work?")

    {:ok, %{version: after_version}} = Expertise.fetch(domain)
    assert after_version == before
  end

  test "restore/2 promotes an old version to a fresh current one", %{domain: domain} do
    {:ok, _} = Expertise.save(domain, "original")
    {:ok, _} = Expertise.save(domain, "revised")

    {:ok, restored} = Expertise.restore(domain, 1)
    assert restored.version == 3
    assert Expertise.render(domain) == "original"
  end

  test "save/3 enforces the size cap" do
    dir = Application.get_env(:repo_builder, :orchestrator, [])[:experts_dir]
    refute is_nil(dir)
    huge = String.duplicate("x", 50_000)
    {:ok, model} = Expertise.save("capped-domain", huge)
    assert byte_size(model.body) <= 16_000
  end

  test "save/3 rejects a blank body and an invalid domain", %{domain: domain} do
    assert {:error, :empty_body} = Expertise.save(domain, "   ")
    assert {:error, :invalid_domain} = Expertise.save("Not A Domain", "body")
  end

  test "the shipped built-in seed resolves from the read-only root" do
    # priv/orchestrator/experts/elixir-phoenix/0001.md ships with the app.
    assert Expertise.render("elixir-phoenix") =~ "domain mental model"
  end
end
