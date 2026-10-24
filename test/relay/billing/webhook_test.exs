defmodule Relay.Billing.WebhookTest do
  use ExUnit.Case, async: true

  alias Relay.Billing.Webhook

  @secret "whsec_test_fake"
  @ts 1_700_000_000
  @body ~s({"type":"x"})

  defp header(body, ts \\ @ts, secret \\ @secret) do
    hex = :hmac |> :crypto.mac(:sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{hex}"
  end

  test "tolerance_s/0 is 300" do
    assert Webhook.tolerance_s() == 300
  end

  test "a correctly signed body inside the tolerance verifies to its event" do
    assert Webhook.verify(@body, header(@body), @secret, 1_700_000_100) == {:ok, %{"type" => "x"}}
  end

  test "any one matching v1 among several verifies" do
    "t=" <> _ = signed = header(@body)
    assert {:ok, _event} = Webhook.verify(@body, signed <> ",v1=deadbeef", @secret, @ts)
    assert {:ok, _event} = Webhook.verify(@body, "t=#{@ts},v1=deadbeef," <> tl_v1(signed), @secret, @ts)
  end

  test "a tampered body is refused" do
    assert Webhook.verify(~s({"type":"y"}), header(@body), @secret, 1_700_000_100) == {:error, :invalid_signature}
  end

  test "a timestamp more than 300s old is refused" do
    assert Webhook.verify(@body, header(@body), @secret, 1_700_000_301) == {:error, :invalid_signature}
  end

  test "a nil header is refused" do
    assert Webhook.verify(@body, nil, @secret, 1_700_000_100) == {:error, :invalid_signature}
  end

  test "a malformed header or the wrong secret is refused" do
    assert Webhook.verify(@body, "garbage", @secret, @ts) == {:error, :invalid_signature}
    assert Webhook.verify(@body, "t=abc,v1=00", @secret, @ts) == {:error, :invalid_signature}
    assert Webhook.verify(@body, header(@body, @ts, "whsec_other"), @secret, @ts) == {:error, :invalid_signature}
  end

  test "a blank secret never verifies" do
    assert Webhook.verify(@body, header(@body, @ts, ""), "", @ts) == {:error, :invalid_signature}
  end

  defp tl_v1(signed), do: signed |> String.split(",") |> List.last()
end
