defmodule Relay.Push.Delivery.APNSTest do
  # Not async: sets the global Relay.Push apns config.
  use Relay.DataCase, async: false

  alias Relay.Push
  alias Relay.Push.Delivery.APNS
  alias Schemas.DeviceToken

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

  setup do
    previous = Application.get_env(:relay, Push)

    Application.put_env(
      :relay,
      Push,
      Keyword.put(previous, :apns,
        key: test_key_pem(),
        key_id: "ABC1234567",
        team_id: "TEAM123456",
        topic: "com.relay.mobile",
        env: "sandbox"
      )
    )

    APNS.JWT.reset()

    on_exit(fn ->
      Application.put_env(:relay, Push, previous)
      APNS.JWT.reset()
    end)

    :ok
  end

  defp decode_jwt_header(bearer) do
    "bearer " <> jwt = bearer
    [header, claims, _sig] = String.split(jwt, ".")
    {decode_segment(header), decode_segment(claims)}
  end

  defp decode_segment(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "posts the payload to the sandbox host with APNs headers" do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:apns_request, conn.request_path, conn.req_headers, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("device-token-xyz", @payload)

    assert_received {:apns_request, path, headers, body}
    assert path == "/3/device/device-token-xyz"
    assert body == @payload

    headers = Map.new(headers)
    assert headers["apns-topic"] == "com.relay.mobile"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
  end

  test "signs an ES256 provider JWT carrying kid, iss and iat" do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:auth, Map.new(conn.req_headers)["authorization"]})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("device-token-xyz", @payload)

    assert_received {:auth, bearer}
    {header, claims} = decode_jwt_header(bearer)

    assert header["alg"] == "ES256"
    assert header["kid"] == "ABC1234567"
    assert claims["iss"] == "TEAM123456"
    assert is_integer(claims["iat"])
  end

  test "reuses the cached JWT across sends rather than re-signing" do
    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:auth, Map.new(conn.req_headers)["authorization"]})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("tok-1", @payload)
    assert :ok = APNS.deliver("tok-2", @payload)

    assert_received {:auth, first}
    assert_received {:auth, second}
    assert first == second
  end

  test "a 410 Unregistered prunes the device row" do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-gone")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(410, Jason.encode!(%{"reason" => "Unregistered"}))
    end)

    assert {:error, {:apns, 410}} = APNS.deliver("tok-gone", @payload)
    assert Repo.aggregate(DeviceToken, :count) == 0
  end

  test "a 400 BadDeviceToken prunes the device row" do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-bad")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"reason" => "BadDeviceToken"}))
    end)

    assert {:error, {:apns, 400}} = APNS.deliver("tok-bad", @payload)
    assert Repo.aggregate(DeviceToken, :count) == 0
  end

  test "a 400 for another reason does not prune" do
    user = insert(:user)
    {:ok, _} = Push.register_device(user, "tok-keep")

    Req.Test.stub(APNS, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"reason" => "PayloadTooLarge"}))
    end)

    assert {:error, {:apns, 400}} = APNS.deliver("tok-keep", @payload)
    assert Repo.aggregate(DeviceToken, :count) == 1
  end

  test "a transport error returns an error and never raises" do
    Req.Test.stub(APNS, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _reason} = APNS.deliver("tok-x", @payload)
  end

  test "targets the production host when env is production" do
    config = Application.get_env(:relay, Push)
    apns = Keyword.put(config[:apns], :env, "production")
    Application.put_env(:relay, Push, Keyword.put(config, :apns, apns))

    test_pid = self()

    Req.Test.stub(APNS, fn conn ->
      send(test_pid, {:host, conn.host})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = APNS.deliver("tok-x", @payload)
    assert_received {:host, "api.push.apple.com"}
  end
end
