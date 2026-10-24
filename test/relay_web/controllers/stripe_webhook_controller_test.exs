defmodule RelayWeb.StripeWebhookControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Billing

  @secret "whsec_test_fake"

  defp signed_post(conn, event, secret \\ @secret) do
    body = Jason.encode!(event)
    ts = System.os_time(:second)
    hex = :hmac |> :crypto.mac(:sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{ts},v1=#{hex}")
    |> post(~p"/webhooks/stripe", body)
  end

  defp setup_completed(user),
    do: %{
      "id" => "evt_1",
      "type" => "checkout.session.completed",
      "data" => %{"object" => %{"id" => "local_4242_#{user.id}", "mode" => "setup"}}
    }

  describe "with billing enabled" do
    setup do
      Process.put(:billing_enabled, true)
      user = insert(:user)
      insert(:billing_account, user: user, trial_ends_on: Date.add(Date.utc_today(), 10))
      %{user: user}
    end

    test "a signed setup-mode checkout.session.completed saves the card", %{conn: conn, user: user} do
      conn = signed_post(conn, setup_completed(user))

      assert json_response(conn, 200) == %{"ok" => true}
      assert Billing.get_account(user).card_last4 == "4242"
    end

    test "a bad signature is refused and changes nothing", %{conn: conn, user: user} do
      conn = signed_post(conn, setup_completed(user), "whsec_wrong")

      assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 400)
      assert Billing.get_account(user).card_last4 == nil
    end

    test "a missing signature is refused", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/stripe", Jason.encode!(setup_completed(user)))

      assert %{"error" => %{"code" => "invalid_signature"}} = json_response(conn, 400)
    end

    test "an unrelated, correctly signed event is acknowledged and changes nothing", %{conn: conn, user: user} do
      event = %{setup_completed(user) | "type" => "invoice.paid"}
      conn = signed_post(conn, event)

      assert json_response(conn, 200) == %{"ok" => true}
      assert Billing.get_account(user).card_last4 == nil
    end
  end

  test "with billing disabled the webhook is not found", %{conn: conn} do
    user = insert(:user)
    conn = signed_post(conn, setup_completed(user))

    assert json_response(conn, 404)
    assert Billing.get_account(user) == nil
  end

  describe "RelayWeb.RawBodyReader" do
    test "keeps the raw body for the Stripe webhook only, and still returns it" do
      webhook = Plug.Test.conn(:post, "/webhooks/stripe", ~s({"a":1}))
      assert {:ok, ~s({"a":1}), webhook} = RelayWeb.RawBodyReader.read_body(webhook, [])
      assert webhook.private[:raw_body] == ~s({"a":1})

      other = Plug.Test.conn(:post, "/api/cards", ~s({"a":1}))
      assert {:ok, ~s({"a":1}), other} = RelayWeb.RawBodyReader.read_body(other, [])
      refute Map.has_key?(other.private, :raw_body)
    end
  end

  describe "GET /dev/billing-checkout" do
    @succeed "/account/billing?setup=local_4242_1"
    @decline "/account/billing?setup=local_0341_1"

    test "links back to the succeed and decline paths", %{conn: conn} do
      conn = get(conn, ~p"/dev/billing-checkout?#{[succeed: @succeed, decline: @decline]}")
      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("a#dev-checkout-succeed") |> LazyHTML.attribute("href") == [@succeed]
      assert document |> LazyHTML.query("a#dev-checkout-decline") |> LazyHTML.attribute("href") == [@decline]
    end

    test "refuses a return that is not a same-origin path", %{conn: conn} do
      for bad <- ["https://evil.example/x", "//evil.example/x", "/\\evil.example/x"] do
        conn = get(conn, ~p"/dev/billing-checkout?#{[succeed: bad, decline: @decline]}")
        assert response(conn, 400)
      end

      conn = get(conn, ~p"/dev/billing-checkout?#{[succeed: @succeed, decline: "https://evil.example/x"]}")
      assert response(conn, 400)
      assert conn |> recycle() |> get(~p"/dev/billing-checkout") |> response(400)
    end
  end
end
