defmodule RepoBuilderWeb.PageControllerTest do
  use RepoBuilderWeb.ConnCase

  test "GET / serves the orchestration console", %{conn: conn} do
    conn = get(conn, ~p"/")
    # `/` is now the multi-layered ConsoleLive (was the Phoenix landing page);
    # the static (dead) render includes the console shell.
    assert html_response(conn, 200) =~ ~s(id="console-header")
  end
end
