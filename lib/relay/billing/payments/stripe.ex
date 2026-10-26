defmodule Relay.Billing.Payments.Stripe do
  @moduledoc """
  The real `Relay.Billing.Payments` (RE460): `Req` calls to the Stripe API with the
  `:stripe_secret_key` bearer, read through `Relay.Config` at call time. No Stripe SDK.

  Answers `{:error, :not_configured}` before any HTTP when the key is blank, and
  `{:error, {:stripe, status, body}}` for any answer it does not expect. `:stripe_req_options`
  (plain app env) is merged into every request — test injects its `Req.Test` plug there, so no
  test reaches Stripe. Requests are never retried here: the hourly clock is the retry, and an
  unanswered charge is resolved with `find_payment/3`, never resent blind.
  """

  @behaviour Relay.Billing.Payments

  alias Relay.Billing.Payments

  @api "https://api.stripe.com/v1"

  @impl true
  def create_setup_checkout(customer_id, user, return_url) do
    with :ok <- ensure_configured(),
         {:ok, customer_id} <- ensure_customer(customer_id, user) do
      [
        {"mode", "setup"},
        {"currency", "usd"},
        {"customer", customer_id},
        {"payment_method_types[0]", "card"},
        # Stripe fills in the literal `{CHECKOUT_SESSION_ID}` on the way back.
        {"success_url", Payments.with_setup_param(return_url, "{CHECKOUT_SESSION_ID}")},
        {"cancel_url", return_url},
        {"metadata[user_id]", to_string(user.id)},
        {"setup_intent_data[metadata][user_id]", to_string(user.id)}
      ]
      |> post("/checkout/sessions")
      |> case do
        {:ok, %{status: 200, body: %{"url" => url}}} -> {:ok, %{url: url, customer_id: customer_id}}
        other -> unexpected(other)
      end
    end
  end

  defp ensure_customer(customer_id, _user) when is_binary(customer_id), do: {:ok, customer_id}

  defp ensure_customer(nil, user) do
    [{"name", user.name || ""}, {"email", user.email || ""}, {"metadata[user_id]", to_string(user.id)}]
    |> post("/customers")
    |> case do
      {:ok, %{status: 200, body: %{"id" => id}}} -> {:ok, id}
      other -> unexpected(other)
    end
  end

  @impl true
  def fetch_setup("cs_" <> _rest = session_id) do
    with :ok <- ensure_configured() do
      "/checkout/sessions/#{encode(session_id)}"
      |> get([{"expand[]", "setup_intent.payment_method"}])
      |> case do
        {:ok, %{status: 200, body: %{"status" => "complete", "setup_intent" => %{} = intent} = session}} ->
          setup(session, intent["payment_method"])

        {:ok, %{status: 200}} ->
          {:error, :incomplete}

        other ->
          unexpected(other)
      end
    end
  end

  def fetch_setup("seti_" <> _rest = setup_intent_id) do
    with :ok <- ensure_configured() do
      "/setup_intents/#{encode(setup_intent_id)}"
      |> get([{"expand[]", "payment_method"}])
      |> case do
        {:ok, %{status: 200, body: %{"status" => "succeeded"} = intent}} -> setup(intent, intent["payment_method"])
        {:ok, %{status: 200}} -> {:error, :incomplete}
        other -> unexpected(other)
      end
    end
  end

  def fetch_setup(_id), do: {:error, :not_found}

  # `owner` is the session or setup intent: it carries the customer and `metadata.user_id`.
  defp setup(owner, %{"id" => payment_method_id, "card" => %{} = card}) do
    case Integer.parse(to_string(get_in(owner, ["metadata", "user_id"]))) do
      {user_id, ""} ->
        {:ok,
         %{
           user_id: user_id,
           customer_id: owner["customer"],
           payment_method_id: payment_method_id,
           brand: card["brand"],
           last4: card["last4"],
           exp_month: card["exp_month"],
           exp_year: card["exp_year"]
         }}

      _no_user ->
        {:error, :incomplete}
    end
  end

  defp setup(_owner, _payment_method), do: {:error, :incomplete}

  @impl true
  def charge(customer_id, payment_method_id, amount_cents, idempotency_key, meta) do
    with :ok <- ensure_configured() do
      form =
        [
          {"amount", to_string(amount_cents)},
          {"currency", "usd"},
          {"customer", customer_id},
          {"payment_method", payment_method_id},
          {"confirm", "true"},
          {"off_session", "true"},
          {"description", meta.description},
          {"metadata[billing_payment_attempt_id]", to_string(meta.attempt_id)},
          {"expand[]", "latest_charge"}
        ] ++ if(meta.receipt_email, do: [{"receipt_email", meta.receipt_email}], else: [])

      form
      |> post("/payment_intents", headers: [{"idempotency-key", idempotency_key}])
      |> charged()
    end
  end

  # Only the bank refusing the card is a decline. A charge still processing may yet succeed, and a
  # timeout or 5xx says nothing about whether the card was charged: the caller finds out later.
  defp charged({:ok, %{status: 200, body: %{"status" => "succeeded", "id" => id} = intent}}),
    do: {:ok, %{id: id, receipt_url: receipt_url(intent)}}

  defp charged({:ok, %{status: 200, body: %{"status" => "processing", "id" => id}}}), do: {:error, {:processing, id}}
  defp charged({:ok, %{status: 200, body: %{"status" => status}}}), do: {:error, {:declined, "payment " <> status}}
  defp charged({:ok, %{status: 402, body: %{"error" => error}}}), do: {:error, {:declined, decline_reason(error)}}
  defp charged(other), do: unexpected(other)

  # `insufficient_funds` reads as "insufficient funds"; with no decline code, Stripe's message; with
  # neither, "card declined".
  defp decline_reason(%{"decline_code" => code}) when is_binary(code), do: String.replace(code, "_", " ")

  defp decline_reason(error) do
    case error["message"] do
      message when is_binary(message) -> if String.trim(message) == "", do: "card declined", else: message
      _none -> "card declined"
    end
  end

  defp receipt_url(%{"latest_charge" => %{"receipt_url" => url}}) when is_binary(url), do: url
  defp receipt_url(_intent), do: nil

  @impl true
  def find_payment(customer_id, payment_intent_id, attempt) do
    with :ok <- ensure_configured() do
      if payment_intent_id, do: read_intent(payment_intent_id), else: search_intents(customer_id, attempt, nil)
    end
  end

  defp read_intent(payment_intent_id) do
    case get("/payment_intents/#{encode(payment_intent_id)}", [{"expand[]", "latest_charge"}]) do
      {:ok, %{status: 200, body: %{"id" => _id} = intent}} -> {:ok, found(intent)}
      {:ok, %{status: 404}} -> {:ok, :none}
      other -> unexpected(other)
    end
  end

  # The intent a charge made carries `metadata[billing_payment_attempt_id]`; it cannot predate the
  # attempt row, so the listing starts a minute before it (clock skew) and pages forward.
  defp search_intents(customer_id, attempt, starting_after) do
    params =
      [
        {"customer", customer_id},
        {"created[gte]", to_string(DateTime.to_unix(attempt.inserted_at) - 60)},
        {"limit", "100"},
        {"expand[]", "data.latest_charge"}
      ] ++ if(starting_after, do: [{"starting_after", starting_after}], else: [])

    case get("/payment_intents", params) do
      {:ok, %{status: 200, body: %{"data" => intents} = page}} when is_list(intents) ->
        case Enum.find(intents, &(get_in(&1, ["metadata", "billing_payment_attempt_id"]) == to_string(attempt.id))) do
          %{} = intent -> {:ok, found(intent)}
          nil -> next_page(page, customer_id, attempt)
        end

      other ->
        unexpected(other)
    end
  end

  defp next_page(%{"has_more" => true, "data" => [_ | _] = intents}, customer_id, attempt),
    do: search_intents(customer_id, attempt, List.last(intents)["id"])

  defp next_page(_last_page, _customer_id, _attempt), do: {:ok, :none}

  defp found(intent) do
    %{
      id: intent["id"],
      status: intent["status"],
      decline_reason: if(error = intent["last_payment_error"], do: decline_reason(error)),
      receipt_url: receipt_url(intent)
    }
  end

  # One path segment, whatever the id holds: `cs/../x y` cannot walk to another endpoint.
  defp encode(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp get(path, params) do
    request(method: :get, url: @api <> path, params: params)
  end

  defp post(form, path, opts \\ []) do
    [method: :post, url: @api <> path, form: form]
    |> Keyword.merge(opts)
    |> request()
  end

  defp request(opts) do
    [auth: {:bearer, secret_key()}, retry: false]
    |> Keyword.merge(opts)
    |> Req.request(Application.get_env(:relay, :stripe_req_options, []))
  end

  defp secret_key, do: Relay.Config.get(:stripe_secret_key)

  defp ensure_configured do
    case secret_key() do
      key when is_binary(key) -> if String.trim(key) == "", do: {:error, :not_configured}, else: :ok
      _none -> {:error, :not_configured}
    end
  end

  defp unexpected({:ok, resp}), do: {:error, {:stripe, resp.status, resp.body}}
  defp unexpected({:error, reason}), do: {:error, reason}
end
