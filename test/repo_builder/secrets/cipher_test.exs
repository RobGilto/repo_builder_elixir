defmodule RepoBuilder.Secrets.CipherTest do
  @moduledoc """
  AES-256-GCM round-trip, IV uniqueness, tamper-detection, and fail-closed-when-unset
  for the secrets-vault cipher (issue-per-project-encrypted-secrets-vault).

  `async: false` — one test deletes the shared `RepoBuilder.Secrets` key config.
  """
  use ExUnit.Case, async: false

  alias RepoBuilder.Secrets.Cipher

  defp with_key(_context) do
    original = Application.get_env(:repo_builder, RepoBuilder.Secrets)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:repo_builder, RepoBuilder.Secrets)
  defp restore(cfg), do: Application.put_env(:repo_builder, RepoBuilder.Secrets, cfg)

  describe "with the configured test key" do
    setup :with_key

    test "decrypt(encrypt(x)) == {:ok, x} over varied binaries" do
      for plaintext <- [
            "",
            "hunter2",
            "sk-" <> String.duplicate("x", 4096),
            <<0, 255, 1, 2>>,
            "café 🔐"
          ] do
        assert {:ok, blob} = Cipher.encrypt(plaintext)
        assert {:ok, ^plaintext} = Cipher.decrypt(blob)
      end
    end

    test "each encryption uses a distinct IV (different ciphertext for the same input)" do
      {:ok, a} = Cipher.encrypt("same")
      {:ok, b} = Cipher.encrypt("same")
      assert a != b
      assert {:ok, "same"} = Cipher.decrypt(a)
      assert {:ok, "same"} = Cipher.decrypt(b)
    end

    test "tampering a byte fails the GCM tag check" do
      {:ok, blob} = Cipher.encrypt("secret")
      {:ok, raw} = Base.decode64(blob)
      <<first, rest::binary>> = raw
      tampered = Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
      assert {:error, :invalid} = Cipher.decrypt(tampered)
    end

    test "malformed / non-base64 / too-short blobs decrypt to {:error, :invalid}" do
      assert {:error, :invalid} = Cipher.decrypt("not base64 @@@")
      assert {:error, :invalid} = Cipher.decrypt(Base.encode64("short"))
    end

    test "key_present?/0 is true" do
      assert Cipher.key_present?()
    end
  end

  describe "fail-closed when the master key is unset" do
    test "encrypt and decrypt both return {:error, :no_key}" do
      original = Application.get_env(:repo_builder, RepoBuilder.Secrets)
      Application.delete_env(:repo_builder, RepoBuilder.Secrets)
      on_exit(fn -> restore(original) end)

      assert {:error, :no_key} = Cipher.encrypt("x")
      assert {:error, :no_key} = Cipher.decrypt(Base.encode64("anything"))
      refute Cipher.key_present?()
    end
  end
end
