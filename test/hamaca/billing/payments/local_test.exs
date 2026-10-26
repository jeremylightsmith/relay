defmodule Hamaca.Billing.Payments.LocalTest do
  use ExUnit.Case, async: true

  alias Hamaca.Billing.Payments.Local

  @user %Schemas.User{id: 7, name: "Ada", email: "ada@example.com"}

  defp checkout_query(url) do
    uri = URI.parse(url)
    {uri.path, URI.decode_query(uri.query)}
  end

  describe "create_setup_checkout/3" do
    test "keeps the return URL's query, appending setup= with &" do
      assert {:ok, %{url: url}} = Local.create_setup_checkout(nil, @user, "http://localhost:4002/boards?pending=abc.def")

      assert {"/dev/billing-checkout", query} = checkout_query(url)
      assert query["succeed"] == "/boards?pending=abc.def&setup=local_4242_7"
      assert query["decline"] == "/boards?pending=abc.def&setup=local_0341_7"
    end

    test "a bare return path gets ?setup=, and the customer is the user's local one" do
      assert {:ok, %{url: url, customer_id: "cus_local_7"}} =
               Local.create_setup_checkout(nil, @user, "http://localhost:4002/account/billing")

      assert {"/dev/billing-checkout", query} = checkout_query(url)
      assert query["succeed"] == "/account/billing?setup=local_4242_7"
      assert query["decline"] == "/account/billing?setup=local_0341_7"
    end
  end
end
