defmodule RelayWeb.Admin.ApiLiveTest do
  # async: false — reads/writes the app-wide RelayWeb.ApiLog singleton.
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RelayWeb.ApiLog

  setup do
    ApiLog.clear()
    _ = :sys.get_state(ApiLog)
    :ok
  end

  defp sample(attrs) do
    Map.merge(
      %{
        at: DateTime.utc_now(),
        method: "GET",
        path: "/api/board",
        query: "",
        status: 200,
        duration_ms: 3,
        board: nil,
        remote_ip: "127.0.0.1",
        params: "%{}"
      },
      attrs
    )
  end

  describe "when logged out" do
    test "redirects to the sign-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/api")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "shows an empty state when nothing has been recorded", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/api")
      assert html =~ "No API requests recorded yet"
    end

    test "renders recorded requests for a board the user owns", %{conn: conn, user: user} do
      ApiLog.record(
        sample(%{
          path: "/api/cards/RLY-9",
          status: 200,
          board: %{name: "My board", key: "RLY", owner_id: user.id}
        })
      )

      _ = :sys.get_state(ApiLog)

      {:ok, _view, html} = live(conn, ~p"/admin/api")
      assert html =~ "/api/cards/RLY-9"
    end

    test "appends a new request live on a PubSub broadcast for a board the user owns", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/api")

      ApiLog.record(
        sample(%{
          method: "POST",
          path: "/api/cards/RLY-9/move",
          status: 201,
          board: %{name: "My board", key: "RLY", owner_id: user.id}
        })
      )

      # Synchronize with the (separate) ApiLog process and the LiveView process
      # so the broadcast is guaranteed to be applied before we render — avoids
      # a race between the async cast/broadcast and this assertion.
      _ = :sys.get_state(ApiLog)
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "/api/cards/RLY-9/move"
    end

    test "does not render another user's board requests", %{conn: conn} do
      other_user = insert(:user)

      ApiLog.record(
        sample(%{
          path: "/api/cards/OTH-1",
          status: 200,
          board: %{name: "Other board", key: "OTH", owner_id: other_user.id}
        })
      )

      _ = :sys.get_state(ApiLog)

      {:ok, _view, html} = live(conn, ~p"/admin/api")
      refute html =~ "/api/cards/OTH-1"
      assert html =~ "No API requests recorded yet"
    end

    test "does not render requests with no attributable board", %{conn: conn} do
      ApiLog.record(sample(%{path: "/api/board", status: 401, board: nil}))
      _ = :sys.get_state(ApiLog)

      {:ok, _view, html} = live(conn, ~p"/admin/api")
      refute html =~ "/api/board"
      assert html =~ "No API requests recorded yet"
    end

    test "does not append another user's board request received live", %{conn: conn} do
      other_user = insert(:user)
      {:ok, view, _html} = live(conn, ~p"/admin/api")

      ApiLog.record(
        sample(%{
          path: "/api/cards/OTH-2",
          status: 200,
          board: %{name: "Other board", key: "OTH", owner_id: other_user.id}
        })
      )

      _ = :sys.get_state(ApiLog)
      _ = :sys.get_state(view.pid)

      refute render(view) =~ "/api/cards/OTH-2"
    end
  end
end
