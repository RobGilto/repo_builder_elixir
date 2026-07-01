defmodule RepoBuilder.Config.DevSecretsKeyTest do
  @moduledoc """
  Regression guard (issue-1): config/dev.exs MUST provide a usable per-project secrets
  vault master key so the vault is enabled in local dev — otherwise every deposit fails
  fail-closed with "secrets vault is not configured" and the external-API provisioning
  feature is unusable out of the box.
  """
  use ExUnit.Case, async: true

  test "config/dev.exs provides a 32-byte base64 vault master key" do
    cfg = Config.Reader.read!("config/dev.exs", env: :dev)
    key = get_in(cfg, [:repo_builder, RepoBuilder.Secrets])[:key]

    assert is_binary(key) and key != "",
           "config/dev.exs must set config :repo_builder, RepoBuilder.Secrets, key: <base64>"

    assert {:ok, raw} = Base.decode64(key)
    assert byte_size(raw) == 32, "the dev vault key must be base64 of exactly 32 bytes"
  end
end
