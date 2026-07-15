defmodule RelayWeb.Api.DeviceControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Push
  alias Schemas.DeviceToken

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/all/devices" do
    setup :register_and_log_in_user

    test "registers the device for the signed-in user", %{conn: conn, user: user} do
      conn = post(conn, ~p"/api/all/devices", %{"token" => "tok-abc", "platform" => "ios"})

      assert json_response(conn, 201) == %{"ok" => true}
      assert device = Relay.Repo.get_by(DeviceToken, token: "tok-abc")
      assert device.user_id == user.id
      assert device.platform == :ios
    end

    test "is idempotent for a repeated registration", %{conn: conn} do
      post(conn, ~p"/api/all/devices", %{"token" => "tok-abc"})
      conn = post(conn, ~p"/api/all/devices", %{"token" => "tok-abc"})

      assert json_response(conn, 201) == %{"ok" => true}
      assert Relay.Repo.aggregate(DeviceToken, :count) == 1
    end

    test "400s when the token is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/all/devices", %{})
      assert json_response(conn, 400)["error"]
    end

    test "400s when the token is blank", %{conn: conn} do
      conn = post(conn, ~p"/api/all/devices", %{"token" => ""})
      assert json_response(conn, 400)["error"]
    end
  end

  describe "DELETE /api/all/devices/:token" do
    setup :register_and_log_in_user

    test "unregisters the device", %{conn: conn, user: user} do
      {:ok, _} = Push.register_device(user, "tok-abc")

      conn = delete(conn, ~p"/api/all/devices/tok-abc")

      assert response(conn, 204)
      assert Relay.Repo.aggregate(DeviceToken, :count) == 0
    end

    test "is idempotent", %{conn: conn} do
      conn = delete(conn, ~p"/api/all/devices/never-registered")
      assert response(conn, 204)
    end

    test "does not delete another user's device", %{conn: conn} do
      other = insert(:user)
      {:ok, _} = Push.register_device(other, "tok-other")

      conn = delete(conn, ~p"/api/all/devices/tok-other")

      assert response(conn, 204)
      assert Relay.Repo.aggregate(DeviceToken, :count) == 1
    end
  end

  describe "authentication" do
    test "POST 401s without a session", %{conn: conn} do
      conn = post(conn, ~p"/api/all/devices", %{"token" => "tok-abc"})

      assert json_response(conn, 401)["error"]
      assert Relay.Repo.aggregate(DeviceToken, :count) == 0
    end

    test "DELETE 401s without a session", %{conn: conn} do
      conn = delete(conn, ~p"/api/all/devices/tok-abc")
      assert json_response(conn, 401)["error"]
    end
  end
end
