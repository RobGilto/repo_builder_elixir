defmodule RepoBuilderWeb.SystemLogsLiveTest do
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Logs

  test "seeds persisted logs on mount and appends live inserts", %{conn: conn} do
    {:ok, _} = Logs.create_system_log(%{level: :info, message: "seed-msg"})

    {:ok, view, _html} = live(conn, ~p"/system-logs")
    assert render(view) =~ "seed-msg"

    {:ok, _} = Logs.create_system_log(%{level: :error, message: "live-msg"})
    assert render(view) =~ "live-msg"
  end
end
