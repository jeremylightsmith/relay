defmodule Relay.Accounts.GoogleTokenValidatorTest do
  use ExUnit.Case, async: true

  alias Relay.Accounts.GoogleTokenValidator

  @valid %{
    "aud" => "test-google-client-id",
    "iss" => "https://accounts.google.com",
    "email" => "ada@example.com",
    "email_verified" => "true",
    "name" => "Ada Lovelace",
    "picture" => "https://example.com/ada.png",
    "sub" => "google-sub-1"
  }

  defp stub_tokeninfo(payload) do
    Req.Test.stub(GoogleTokenValidator, fn conn -> Req.Test.json(conn, payload) end)
  end

  test "returns normalized claims for a valid token" do
    stub_tokeninfo(@valid)

    assert {:ok, claims} = GoogleTokenValidator.validate_token("tok")

    assert claims == %{
             provider: "google",
             provider_uid: "google-sub-1",
             email: "ada@example.com",
             name: "Ada Lovelace",
             avatar_url: "https://example.com/ada.png"
           }
  end

  test "accepts a boolean email_verified too" do
    stub_tokeninfo(%{@valid | "email_verified" => true})
    assert {:ok, _claims} = GoogleTokenValidator.validate_token("tok")
  end

  test "rejects an audience outside the allowlist" do
    stub_tokeninfo(%{@valid | "aud" => "attacker-client-id"})
    assert {:error, :invalid_audience} = GoogleTokenValidator.validate_token("tok")
  end

  test "rejects an unknown issuer" do
    stub_tokeninfo(%{@valid | "iss" => "evil.example.com"})
    assert {:error, :invalid_issuer} = GoogleTokenValidator.validate_token("tok")
  end

  test "rejects an unverified email" do
    stub_tokeninfo(%{@valid | "email_verified" => "false"})
    assert {:error, :email_unverified} = GoogleTokenValidator.validate_token("tok")
  end

  test "treats a non-200 tokeninfo response as an invalid token" do
    Req.Test.stub(GoogleTokenValidator, fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_token"}))
    end)

    assert {:error, :invalid_token} = GoogleTokenValidator.validate_token("expired")
  end

  test "maps a transport failure to :network_error" do
    Req.Test.stub(GoogleTokenValidator, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, :network_error} = GoogleTokenValidator.validate_token("tok")
  end
end
