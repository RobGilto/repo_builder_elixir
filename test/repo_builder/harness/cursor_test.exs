defmodule RepoBuilder.Harness.CursorTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{Cursor, Registry}

  test "implements ONLY the mandatory behaviour (no CustomSpawn) — a minimal adapter" do
    # function_exported?/3 needs the module loaded.
    {:module, _} = Code.ensure_loaded(Cursor)
    assert function_exported?(Cursor, :command, 1)
    assert function_exported?(Cursor, :normalize, 2)
    refute function_exported?(Cursor, :start_session, 1)
  end

  test "command/1 builds the cursor-agent argv; secrets go in env, not argv" do
    opts = %{
      prompt: "do it",
      model: nil,
      cwd: ".",
      sink: self(),
      secrets: %{"CURSOR_KEY" => "sk"}
    }

    {exe, args, env, ctx} = Cursor.command(opts)

    assert exe == "cursor-agent"
    assert "do it" in args
    refute "sk" in args
    assert {"CURSOR_KEY", "sk"} in env
    assert ctx == %{harness: :cursor}
  end

  test "normalize/2 is a stub that skips every frame" do
    assert Cursor.normalize(%{"type" => "anything"}, %{harness: :cursor}) == :skip
  end

  test "resolves through the registry (one config entry, zero core edits)" do
    assert Registry.fetch("cursor") == {:ok, Cursor}
  end
end
