defmodule Relay.Billing.Payments.StripeTest do
  use ExUnit.Case, async: true

  alias Relay.Billing.Payments.Stripe

  @meta %{description: "Relay · Aug 12 – Sep 11, 2026", receipt_email: "owner@example.com", attempt_id: 7}

  # Answers every request with `status`/`body` and reports it to the test as
  # `{:stripe_request, method, path, headers, form_or_query}`.
  defp stub(status, body) do
    test = self()

    Req.Test.stub(Stripe, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      params = if raw == "", do: URI.decode_query(conn.query_string), else: URI.decode_query(raw)
      send(test, {:stripe_request, conn.method, conn.request_path, conn.req_headers, params})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  describe "charge/5" do
    test "a succeeded intent is the charge, its receipt the latest charge's" do
      stub(200, %{
        "id" => "pi_1",
        "status" => "succeeded",
        "latest_charge" => %{"receipt_url" => "https://pay.stripe.com/receipts/x"}
      })

      assert Stripe.charge("cus_1", "pm_1", 2000, "billing-1-2026-08-12-1", @meta) ==
               {:ok, %{id: "pi_1", receipt_url: "https://pay.stripe.com/receipts/x"}}

      assert_received {:stripe_request, "POST", "/v1/payment_intents", headers, form}
      assert {"idempotency-key", "billing-1-2026-08-12-1"} in headers
      assert {"authorization", "Bearer sk_test_fake"} in headers

      assert %{
               "off_session" => "true",
               "confirm" => "true",
               "amount" => "2000",
               "currency" => "usd",
               "customer" => "cus_1",
               "payment_method" => "pm_1",
               "receipt_email" => "owner@example.com",
               "description" => "Relay · Aug 12 – Sep 11, 2026",
               "metadata[billing_payment_attempt_id]" => "7",
               "expand[]" => "latest_charge"
             } = form
    end

    test "a 402 is a decline, its reason the decline code in words" do
      stub(402, %{"error" => %{"decline_code" => "insufficient_funds"}})
      assert Stripe.charge("cus_1", "pm_1", 2000, "k", @meta) == {:error, {:declined, "insufficient funds"}}
    end

    test "a processing intent is still processing" do
      stub(200, %{"id" => "pi_1", "status" => "processing"})
      assert Stripe.charge("cus_1", "pm_1", 2000, "k", @meta) == {:error, {:processing, "pi_1"}}
    end

    test "a 500 is an unexpected answer" do
      stub(500, %{"error" => %{"message" => "boom"}})
      assert {:error, {:stripe, 500, _body}} = Stripe.charge("cus_1", "pm_1", 2000, "k", @meta)
    end
  end

  describe "with no secret key" do
    setup do
      Process.put(:stripe_secret_key, "")
      stub(200, %{})
      :ok
    end

    test "charge/5 is not configured and sends nothing" do
      assert Stripe.charge("cus_1", "pm_1", 2000, "k", @meta) == {:error, :not_configured}
      refute_received {:stripe_request, _method, _path, _headers, _params}
    end

    test "create_setup_checkout/3 is not configured and sends nothing" do
      user = %Schemas.User{id: 5, name: "Ada", email: "ada@example.com"}
      assert Stripe.create_setup_checkout(nil, user, "https://relay.test/account/billing") == {:error, :not_configured}
      refute_received {:stripe_request, _method, _path, _headers, _params}
    end
  end

  describe "create_setup_checkout/3" do
    test "creates the customer first, then a setup-mode session returning to the page" do
      test = self()

      Req.Test.stub(Stripe, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:stripe_request, conn.request_path, URI.decode_query(raw)})

        case conn.request_path do
          "/v1/customers" -> Req.Test.json(conn, %{"id" => "cus_new"})
          "/v1/checkout/sessions" -> Req.Test.json(conn, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/cs_1"})
        end
      end)

      user = %Schemas.User{id: 5, name: "Ada", email: "ada@example.com"}

      assert Stripe.create_setup_checkout(nil, user, "https://relay.test/account/billing") ==
               {:ok, %{url: "https://checkout.stripe.com/c/cs_1", customer_id: "cus_new"}}

      assert_received {:stripe_request, "/v1/customers",
                       %{"name" => "Ada", "email" => "ada@example.com", "metadata[user_id]" => "5"}}

      assert_received {:stripe_request, "/v1/checkout/sessions", session}

      assert %{
               "mode" => "setup",
               "currency" => "usd",
               "customer" => "cus_new",
               "payment_method_types[0]" => "card",
               "success_url" => "https://relay.test/account/billing?setup={CHECKOUT_SESSION_ID}",
               "cancel_url" => "https://relay.test/account/billing",
               "metadata[user_id]" => "5",
               "setup_intent_data[metadata][user_id]" => "5"
             } = session
    end

    test "keeps a return URL's query, appending setup= with &" do
      stub(200, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/cs_1"})
      user = %Schemas.User{id: 5, name: "Ada", email: "ada@example.com"}

      assert {:ok, %{url: "https://checkout.stripe.com/c/cs_1"}} =
               Stripe.create_setup_checkout("cus_known", user, "https://relay.test/boards?pending=abc.def")

      assert_received {:stripe_request, "POST", "/v1/checkout/sessions", _headers, session}

      assert %{
               "success_url" => "https://relay.test/boards?pending=abc.def&setup={CHECKOUT_SESSION_ID}",
               "cancel_url" => "https://relay.test/boards?pending=abc.def"
             } = session
    end

    test "reuses a known customer" do
      stub(200, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/cs_1"})
      user = %Schemas.User{id: 5, name: "Ada", email: "ada@example.com"}

      assert {:ok, %{customer_id: "cus_known"}} = Stripe.create_setup_checkout("cus_known", user, "https://relay.test/b")
      assert_received {:stripe_request, "POST", "/v1/checkout/sessions", _headers, %{"customer" => "cus_known"}}
      refute_received {:stripe_request, "POST", "/v1/customers", _headers, _form}
    end
  end

  describe "fetch_setup/1" do
    @card %{"brand" => "visa", "last4" => "4242", "exp_month" => 8, "exp_year" => 2028}

    test "a complete session is its saved card, the user from its metadata" do
      stub(200, %{
        "id" => "cs_1",
        "status" => "complete",
        "customer" => "cus_1",
        "metadata" => %{"user_id" => "5"},
        "setup_intent" => %{"id" => "seti_1", "payment_method" => %{"id" => "pm_1", "card" => @card}}
      })

      assert Stripe.fetch_setup("cs_1") ==
               {:ok,
                %{
                  user_id: 5,
                  customer_id: "cus_1",
                  payment_method_id: "pm_1",
                  brand: "visa",
                  last4: "4242",
                  exp_month: 8,
                  exp_year: 2028
                }}

      assert_received {:stripe_request, "GET", "/v1/checkout/sessions/cs_1", _headers,
                       %{"expand[]" => "setup_intent.payment_method"}}
    end

    test "an incomplete session is incomplete" do
      stub(200, %{"id" => "cs_1", "status" => "open"})
      assert Stripe.fetch_setup("cs_1") == {:error, :incomplete}
    end

    test "a succeeded setup intent is its saved card" do
      stub(200, %{
        "id" => "seti_1",
        "status" => "succeeded",
        "customer" => "cus_1",
        "metadata" => %{"user_id" => "5"},
        "payment_method" => %{"id" => "pm_1", "card" => @card}
      })

      assert {:ok, %{user_id: 5, payment_method_id: "pm_1", last4: "4242"}} = Stripe.fetch_setup("seti_1")
      assert_received {:stripe_request, "GET", "/v1/setup_intents/seti_1", _headers, %{"expand[]" => "payment_method"}}
    end

    test "an id is one path segment" do
      stub(200, %{"id" => "cs_1", "status" => "open"})
      Stripe.fetch_setup("cs_../x y")
      assert_received {:stripe_request, "GET", "/v1/checkout/sessions/cs_..%2Fx%20y", _headers, _params}
    end

    test "any other id is not found, with no request" do
      stub(200, %{})
      assert Stripe.fetch_setup("local_4242_5") == {:error, :not_found}
      refute_received {:stripe_request, _method, _path, _headers, _params}
    end
  end

  describe "find_payment/3" do
    @attempt %{id: 7, inserted_at: ~U[2026-08-12 10:00:00Z]}

    test "reads a known intent by id" do
      stub(200, %{
        "id" => "pi_1",
        "status" => "succeeded",
        "latest_charge" => %{"receipt_url" => "https://pay.stripe.com/receipts/x"}
      })

      assert Stripe.find_payment("cus_1", "pi_1", @attempt) ==
               {:ok,
                %{id: "pi_1", status: "succeeded", decline_reason: nil, receipt_url: "https://pay.stripe.com/receipts/x"}}

      assert_received {:stripe_request, "GET", "/v1/payment_intents/pi_1", _headers, _params}
    end

    test "a missing intent is none" do
      stub(404, %{"error" => %{"message" => "No such payment_intent"}})
      assert Stripe.find_payment("cus_1", "pi_1", @attempt) == {:ok, :none}
    end

    test "searches the customer's intents for the attempt's metadata" do
      stub(200, %{
        "has_more" => false,
        "data" => [
          %{"id" => "pi_0", "status" => "succeeded", "metadata" => %{"billing_payment_attempt_id" => "6"}},
          %{
            "id" => "pi_7",
            "status" => "requires_payment_method",
            "metadata" => %{"billing_payment_attempt_id" => "7"},
            "last_payment_error" => %{"decline_code" => "card_declined"}
          }
        ]
      })

      assert Stripe.find_payment("cus_1", nil, @attempt) ==
               {:ok, %{id: "pi_7", status: "requires_payment_method", decline_reason: "card declined", receipt_url: nil}}

      assert_received {:stripe_request, "GET", "/v1/payment_intents", _headers,
                       %{"customer" => "cus_1", "created[gte]" => created}}

      assert created == to_string(DateTime.to_unix(@attempt.inserted_at) - 60)
    end

    test "no intent naming the attempt is none" do
      stub(200, %{"has_more" => false, "data" => []})
      assert Stripe.find_payment("cus_1", nil, @attempt) == {:ok, :none}
    end
  end
end
