defmodule HamacaWeb.OAuthController do
  @moduledoc """
  The OAuth 2.1 authorization server for Claude clients (RE519, ADR 0015). claude.ai,
  Desktop, mobile and Claude Code register here, send the signed-in human through the
  consent screen, and swap the code for `relaym_` tokens that act as that user on `/mcp`.
  It never acts as the agent and never mints a board key. `Hamaca.Connections` does the
  domain work, and this module speaks the protocol.

    * `register/2` (`POST /oauth/register`): RFC 7591 dynamic registration of a public client.
    * `token/2` (`POST /oauth/token`): the `authorization_code` and `refresh_token` grants,
      form-encoded or JSON. Every response is `cache-control: no-store`.
    * `authorize/2` (`GET /oauth/authorize`) and `decide/2` (`POST /oauth/authorize`): the
      consent screen and its Allow / Cancel, in the `:browser` pipeline for the session and
      CSRF.

  An unknown client or unregistered `redirect_uri` is always answered here with a 400 page.
  We never redirect to an unvalidated URI, and the consent form's hidden fields are re-checked
  on the POST because they are attacker-controlled.
  """

  use HamacaWeb, :controller

  alias Hamaca.Boards
  alias Hamaca.Connections
  alias HamacaWeb.ContentSecurityPolicy
  alias HamacaWeb.OAuthMetadata

  # The authorize request the consent form carries through to `decide/2` as hidden inputs.
  @hidden_fields ~w(client_id redirect_uri code_challenge code_challenge_method state resource)a

  # ── registration ───────────────────────────────────────────────────────────

  def register(conn, params) do
    case Connections.register_client(params) do
      {:ok, client} ->
        metadata = OAuthMetadata.authorization_server()

        conn
        |> put_status(:created)
        |> json(%{
          client_id: client.client_id,
          client_name: client.client_name,
          redirect_uris: client.redirect_uris,
          token_endpoint_auth_method: hd(metadata.token_endpoint_auth_methods_supported),
          grant_types: metadata.grant_types_supported,
          response_types: metadata.response_types_supported,
          client_id_issued_at: DateTime.to_unix(client.inserted_at)
        })

      {:error, error} ->
        conn |> put_status(:bad_request) |> json(error_body(error))
    end
  end

  # ── token ──────────────────────────────────────────────────────────────────

  def token(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case grant(params) do
      {:ok, token_response} -> json(conn, token_response)
      {:error, :invalid_client} -> conn |> put_status(:unauthorized) |> json(error_body(:invalid_client))
      {:error, error} -> conn |> put_status(:bad_request) |> json(error_body(error))
    end
  end

  defp grant(%{"grant_type" => "authorization_code"} = params), do: Connections.exchange_code(params)
  defp grant(%{"grant_type" => "refresh_token"} = params), do: Connections.refresh(params)
  defp grant(%{"grant_type" => type}) when is_binary(type) and type != "", do: {:error, :unsupported_grant_type}
  defp grant(_params), do: {:error, :invalid_request}

  # ── authorize ──────────────────────────────────────────────────────────────

  def authorize(conn, params) do
    case validate(params, check_response_type: true) do
      {:ok, client, request} ->
        if user = current_user(conn) do
          render_consent(conn, user, client, request)
        else
          sign_in(conn, authorize_path(conn.request_path, conn.query_string))
        end

      other ->
        reject(conn, other)
    end
  end

  def decide(conn, params) do
    case validate(params, check_response_type: false) do
      {:ok, client, request} ->
        if user = current_user(conn) do
          finish(conn, user, client, request, params["decision"])
        else
          sign_in(conn, authorize_path("/oauth/authorize", authorize_query(request)))
        end

      other ->
        reject(conn, other)
    end
  end

  defp finish(conn, user, client, request, "allow") do
    {:ok, code} =
      Connections.authorize(user, client, %{
        redirect_uri: request.redirect_uri,
        code_challenge: request.code_challenge,
        resource: request.resource
      })

    redirect_back(conn, request.redirect_uri, code: code, state: request.state)
  end

  defp finish(conn, _user, _client, request, _cancel) do
    redirect_back(conn, request.redirect_uri, error: "access_denied", state: request.state)
  end

  # Check 1 (client + redirect_uri) runs first and failing it never redirects; check 2 (the
  # rest of the request) fails by redirecting back to the now-trusted redirect_uri.
  defp validate(params, opts) do
    with client_id when is_binary(client_id) <- params["client_id"],
         client when not is_nil(client) <- Connections.get_client(client_id),
         redirect_uri when is_binary(redirect_uri) <- params["redirect_uri"],
         true <- Connections.redirect_uri_registered?(client, redirect_uri) do
      request = %{
        client_id: client_id,
        redirect_uri: redirect_uri,
        code_challenge: present(params["code_challenge"]),
        code_challenge_method: present(params["code_challenge_method"]),
        state: present(params["state"]),
        resource: present(params["resource"])
      }

      case request_error(params, request, opts[:check_response_type]) do
        nil -> {:ok, client, request}
        error -> {:redirect_error, request, error}
      end
    else
      _invalid -> :invalid_client
    end
  end

  defp request_error(params, request, check_response_type?) do
    metadata = OAuthMetadata.authorization_server()

    cond do
      check_response_type? and params["response_type"] not in metadata.response_types_supported ->
        "unsupported_response_type"

      is_nil(request.code_challenge) ->
        "invalid_request"

      request.code_challenge_method not in metadata.code_challenge_methods_supported ->
        "invalid_request"

      is_nil(request.state) ->
        "invalid_request"

      request.resource not in [nil, OAuthMetadata.resource_url()] ->
        "invalid_request"

      true ->
        nil
    end
  end

  defp reject(conn, :invalid_client) do
    conn
    |> put_status(:bad_request)
    |> render(:error, page_title: "Can't connect")
  end

  defp reject(conn, {:redirect_error, request, error}) do
    redirect_back(conn, request.redirect_uri, error: error, state: request.state)
  end

  defp render_consent(conn, user, client, request) do
    board_count = user |> Boards.list_boards() |> length()

    conn
    |> put_resp_header("content-security-policy", consent_policy(request.redirect_uri))
    |> render(:authorize,
      page_title: "Connect Claude",
      client_name: client.client_name,
      user: user,
      capabilities: Connections.capabilities(board_count),
      hidden: Map.take(request, @hidden_fields),
      not_you_path: ~p"/logout?#{[return_to: authorize_path(conn.request_path, conn.query_string)]}"
    )
  end

  # Allow / Cancel redirect to the client's origin. "Not you?" (and Allow / Cancel after the
  # session expired) redirect through `/auth/google` to Google sign-in. Browsers enforce
  # `form-action` on every hop, so both origins are allowed.
  defp consent_policy(redirect_uri) do
    ContentSecurityPolicy.header([origin(redirect_uri), ContentSecurityPolicy.google_sign_in_origin()])
  end

  defp sign_in(conn, return_to) do
    redirect(conn, to: "/auth/google?return_to=" <> URI.encode_www_form(return_to))
  end

  defp authorize_path(path, ""), do: path
  defp authorize_path(path, query), do: path <> "?" <> query

  defp authorize_query(request) do
    request
    |> Map.take(@hidden_fields)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:response_type, hd(OAuthMetadata.authorization_server().response_types_supported))
    |> URI.encode_query()
  end

  # The redirect_uri is registered (check 1), and registration forbids a fragment, so the
  # params append to its query with `&`, or start one with `?`.
  defp redirect_back(conn, redirect_uri, params) do
    query = params |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> URI.encode_query()
    separator = if String.contains?(redirect_uri, "?"), do: "&", else: "?"

    redirect(conn, external: redirect_uri <> separator <> query)
  end

  defp origin(uri) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(uri)

    if port == URI.default_port(scheme),
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end

  defp current_user(%{assigns: %{current_scope: %{user: user}}}), do: user
  defp current_user(_conn), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp error_body(error), do: %{error: Atom.to_string(error), error_description: description(error)}

  defp description(:invalid_redirect_uri),
    do: "Each redirect URI must be an https:// URL, or http:// on localhost or 127.0.0.1, without a fragment."

  defp description(:invalid_client_metadata) do
    limits = Connections.registration_limits()

    "redirect_uris must be a list of 1 to #{limits.max_redirect_uris} URIs, and client_name a string " <>
      "of at most #{limits.max_client_name_length} characters."
  end

  defp description(:invalid_grant), do: "The code or refresh token is invalid, expired, revoked or already used."
  defp description(:invalid_client), do: "Unknown client_id."
  defp description(:invalid_request), do: "A required parameter is missing or malformed."

  defp description(:unsupported_grant_type),
    do: "grant_type must be one of: #{Enum.join(OAuthMetadata.authorization_server().grant_types_supported, ", ")}."
end
