defmodule Hamaca.Accounts.AppleRevokerTest do
  use ExUnit.Case, async: true

  import Hamaca.AppleRevokeFixtures

  alias Hamaca.Accounts.AppleRevoker
  alias Hamaca.Accounts.AppleRevoker.Apple

  # Failure paths log on purpose; capture it (shown only on a failure).
  @moduletag :capture_log

  setup do
    %{jwk: put_apple_signin_config()}
  end

  test "impl/0 defaults to the Apple implementation and honours an :apple_revoker override" do
    assert AppleRevoker.impl() == Apple
    Process.put(:apple_revoker, __MODULE__)
    assert AppleRevoker.impl() == __MODULE__
  end

  describe "revoke/2" do
    test "exchanges the code with an ES256 client secret, then revokes the refresh token", %{jwk: jwk} do
      stub_apple_ok("apple-sub-1")

      assert Apple.revoke("code-1", "apple-sub-1") == :ok

      assert_received {:apple_request, "/auth/token", token_form}
      assert token_form["code"] == "code-1"
      assert token_form["grant_type"] == "authorization_code"
      assert token_form["client_id"] == "app.hamaca.Hamaca"

      assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: header}} =
               JOSE.JWT.verify_strict(JOSE.JWK.to_public(jwk), ["ES256"], token_form["client_secret"])

      assert header["kid"] == "KEY123"
      assert claims["iss"] == "TEAM123"
      assert claims["sub"] == "app.hamaca.Hamaca"
      assert claims["aud"] == "https://appleid.apple.com"
      assert claims["exp"] - claims["iat"] == 300

      assert_received {:apple_request, "/auth/revoke", revoke_form}
      assert revoke_form["token"] == "r1"
      assert revoke_form["token_type_hint"] == "refresh_token"
      assert revoke_form["client_id"] == "app.hamaca.Hamaca"
      assert revoke_form["client_secret"] == token_form["client_secret"]
    end

    test "revokes the access token when Apple returns no refresh token" do
      stub_apple(%{
        "/auth/token" => {200, token_body("apple-sub-1", %{"refresh_token" => :delete})},
        "/auth/revoke" => {200, %{}}
      })

      assert Apple.revoke("code-1", "apple-sub-1") == :ok

      assert_received {:apple_request, "/auth/revoke", revoke_form}
      assert revoke_form["token"] == "a1"
      assert revoke_form["token_type_hint"] == "access_token"
    end

    test "an id_token for someone else is apple_mismatch and nothing is revoked" do
      stub_apple_ok("someone-else")

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_mismatch}

      assert_received {:apple_request, "/auth/token", _form}
      refute_received {:apple_request, "/auth/revoke", _form}
    end

    test "a refused token exchange is apple_revoke_failed" do
      stub_apple(%{"/auth/token" => {400, %{"error" => "invalid_grant"}}})

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
      refute_received {:apple_request, "/auth/revoke", _form}
    end

    test "a failed revoke call is apple_revoke_failed" do
      stub_apple(%{
        "/auth/token" => {200, token_body("apple-sub-1")},
        "/auth/revoke" => {500, %{"error" => "server_error"}}
      })

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
      assert_received {:apple_request, "/auth/revoke", _form}
    end

    test "a transport error is apple_revoke_failed" do
      Req.Test.stub(Apple, &Req.Test.transport_error(&1, :econnrefused))

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
    end

    test "a token body missing the id_token, or both tokens, is apple_revoke_failed" do
      for overrides <- [
            %{"id_token" => :delete},
            %{"refresh_token" => :delete, "access_token" => :delete}
          ] do
        stub_apple(%{
          "/auth/token" => {200, token_body("apple-sub-1", overrides)},
          "/auth/revoke" => {200, %{}}
        })

        assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
        refute_received {:apple_request, "/auth/revoke", _form}
      end
    end

    test "an explicitly unset team id fails closed without calling Apple" do
      stub_apple_ok("apple-sub-1")
      Process.put(:apple_team_id, false)

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
      refute_received {:apple_request, _path, _form}
    end

    test "no private key configured fails closed without calling Apple" do
      stub_apple_ok("apple-sub-1")

      for unset <- [false, ""] do
        Process.put(:apple_signin_private_key, unset)

        assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
        refute_received {:apple_request, _path, _form}
      end
    end

    test "a malformed private key fails closed without calling Apple" do
      stub_apple_ok("apple-sub-1")
      Process.put(:apple_signin_private_key, "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----\n")

      assert Apple.revoke("code-1", "apple-sub-1") == {:error, :apple_revoke_failed}
      refute_received {:apple_request, _path, _form}
    end

    test "with no signin client id, the first :apple_client_ids entry is the client id" do
      stub_apple_ok("apple-sub-1")
      Process.put(:apple_signin_client_id, false)
      Process.put(:apple_client_ids, ["first.id", "second.id"])

      assert Apple.revoke("code-1", "apple-sub-1") == :ok
      assert_received {:apple_request, "/auth/token", %{"client_id" => "first.id"}}
    end

    test "a single-line private key with literal \\n sequences works" do
      stub_apple_ok("apple-sub-1")
      Process.put(:apple_signin_private_key, String.replace(Process.get(:apple_signin_private_key), "\n", "\\n"))

      assert Apple.revoke("code-1", "apple-sub-1") == :ok
    end
  end
end
