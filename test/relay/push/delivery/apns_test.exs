defmodule Relay.Push.Delivery.APNSTest do
  use Relay.DataCase, async: true

  alias Relay.Push
  alias Relay.Push.Delivery.APNS
  alias Schemas.DeviceToken

  # Error-response cases log `[apns] ...` errors on purpose; capture them (shown only on failure).
  @moduletag :capture_log

  @payload %{
    "aps" => %{"alert" => %{"title" => "Ready for your review", "body" => "RLY-1: A card"}, "badge" => 2},
    "card_ref" => "RLY-1",
    "board_slug" => "my-board",
    "kind" => "in_review"
  }

  # A throwaway P-256 key in PEM form. Apple ships a PKCS#8 `.p8`; JOSE reads
  # both, and the signing path is identical.
  defp test_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  # ADR 0009 rule 1: the config is a test-local value passed into deliver/3, never written into
  # application env. JWT.reset/0 still has to run because the provider-token cache is a genuine
  # process-global (:persistent_term) — but every test in this file signs with its own key, so
  # resetting before each one is what makes them independent rather than what serialises them.
  setup do
    APNS.JWT.reset()
    on_exit(&APNS.JWT.reset/0)

    %{
      apns: [
        key: test_key_pem(),
        key_id: "ABC1234567",
        team_id: "TEAM123456",
        topic: "com.relay.mobile",
        env: "sandbox"
      ]
    }
  end

  defp decode_jwt_header(bearer) do
    "bearer " <> jwt = bearer
    [header, claims, _sig] = String.split(jwt, ".")
    {decode_segment(header), decode_segment(claims)}
  end

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "posts the payload to the sandbox host with APNs headers", %{apns: apns} do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:apns_request, conn.request_path, conn.req_headers, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("device-token-xyz", @payload, apns)

    assert_received {:apns_request, path, headers, body}
    assert path == "/3/device/device-token-xyz"
    assert body == @payload

    headers = Map.new(headers)
    assert headers["apns-topic"] == "com.relay.mobile"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
  end

  test "signs an ES256 provider JWT carrying kid, iss and iat", %{apns: apns} do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:auth, Map.new(conn.req_headers)["authorization"]})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("device-token-xyz", @payload, apns)

    assert_received {:auth, bearer}
    {header, claims} = decode_jwt_header(bearer)

    assert header["alg"] == "ES256"
    assert header["kid"] == "ABC1234567"
    assert claims["iss"] == "TEAM123456"
    assert is_integer(claims["iat"])
  end

  test "reuses the cached JWT across sends rather than re-signing", %{apns: apns} do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:auth, Map.new(conn.req_headers)["authorization"]})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("tok-1", @payload, apns)
    assert :ok = APNS.deliver("tok-2", @payload, apns)

    assert_received {:auth, first}
    assert_received {:auth, second}
    assert first == second
  end

  test "a 410 Unregistered prunes the device row", %{apns: apns} do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-gone")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(410, Jason.encode!(%{"reason" => "Unregistered"}))
    end)

    assert {:error, {:apns, 410}} = APNS.deliver("tok-gone", @payload, apns)
    assert Repo.aggregate(DeviceToken, :count) == 0
  end

  test "a 400 BadDeviceToken prunes the device row", %{apns: apns} do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-bad")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"reason" => "BadDeviceToken"}))
    end)

    assert {:error, {:apns, 400}} = APNS.deliver("tok-bad", @payload, apns)
    assert Repo.aggregate(DeviceToken, :count) == 0
  end

  test "a 400 for another reason does not prune", %{apns: apns} do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-keep")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"reason" => "PayloadTooLarge"}))
    end)

    assert {:error, {:apns, 400}} = APNS.deliver("tok-keep", @payload, apns)
    assert Repo.aggregate(DeviceToken, :count) == 1
  end

  test "a transport error returns an error and never raises", %{apns: apns} do
    Req.Test.stub(APNS, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _reason} = APNS.deliver("tok-x", @payload, apns)
  end

  test "targets the production host when env is production", %{apns: apns} do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:host, conn.host})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("tok-x", @payload, Keyword.put(apns, :env, "production"))
    assert_received {:host, "api.push.apple.com"}
  end

  # The behaviour callback still works with no config passed: it reads the app's configured
  # APNs credentials once, at the boundary. In :test that keyword list is empty, so this proves
  # the delegation compiles and fails the way a mis-configured production would — it must not
  # raise a FunctionClauseError from the arity change.
  test "deliver/2 delegates to deliver/3 with the application's configured credentials" do
    assert_raise KeyError, fn -> APNS.deliver("tok-x", @payload) end
  end
end
