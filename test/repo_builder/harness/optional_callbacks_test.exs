# A MINIMAL adapter — implements ONLY the mandatory behaviour. The fact that this
# compiles under --warnings-as-errors proves the CustomSpawn callbacks are correctly
# declared @optional_callbacks (BUILD_PROMPT.md §4.2 / M1 acceptance).
defmodule RepoBuilder.Harness.MinimalAdapterFixture do
  @behaviour RepoBuilder.Harness

  @impl true
  def command(_opts), do: {"true", [], [], %{harness: :minimal}}

  @impl true
  def normalize(_raw, _ctx), do: :skip
end

# A FULL adapter — additionally implements the optional CustomSpawn behaviour.
defmodule RepoBuilder.Harness.CustomAdapterFixture do
  @behaviour RepoBuilder.Harness
  @behaviour RepoBuilder.Harness.CustomSpawn

  @impl RepoBuilder.Harness
  def command(_opts), do: {"true", [], [], %{harness: :custom}}

  @impl RepoBuilder.Harness
  def normalize(_raw, _ctx), do: :skip

  @impl RepoBuilder.Harness.CustomSpawn
  def start_session(_opts), do: {:ok, :handle}

  @impl RepoBuilder.Harness.CustomSpawn
  def send_input(_session, _data), do: :ok

  @impl RepoBuilder.Harness.CustomSpawn
  def interrupt(_session), do: :ok

  @impl RepoBuilder.Harness.CustomSpawn
  def terminate(_session), do: :ok
end

defmodule RepoBuilder.Harness.OptionalCallbacksTest do
  use ExUnit.Case, async: true

  alias RepoBuilder.Harness.{
    Claude,
    CustomAdapterFixture,
    CustomSpawn,
    Fake,
    MinimalAdapterFixture,
    Pi
  }

  test "a minimal adapter implements only the mandatory callbacks" do
    assert function_exported?(MinimalAdapterFixture, :command, 1)
    assert function_exported?(MinimalAdapterFixture, :normalize, 2)
  end

  test "function_exported?/3 discriminates whether an adapter implements CustomSpawn" do
    refute function_exported?(MinimalAdapterFixture, :start_session, 1)
    assert function_exported?(CustomAdapterFixture, :start_session, 1)
    assert function_exported?(CustomAdapterFixture, :send_input, 2)
    assert function_exported?(CustomAdapterFixture, :interrupt, 1)
    assert function_exported?(CustomAdapterFixture, :terminate, 1)
  end

  test "the real adapters do not implement CustomSpawn (driven by the generic runtime)" do
    for adapter <- [Claude, Pi, Fake] do
      refute function_exported?(adapter, :start_session, 1)
    end
  end

  test "CustomSpawn declares exactly the four optional callbacks" do
    optional = CustomSpawn.behaviour_info(:optional_callbacks)

    assert Enum.sort(optional) ==
             Enum.sort(start_session: 1, send_input: 2, interrupt: 1, terminate: 1)
  end
end
