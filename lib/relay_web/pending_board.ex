defmodule RelayWeb.PendingBoard do
  @moduledoc """
  The board a Free owner asked to create when they hit **Upgrade and create →** (RE472), carried
  through the setup Checkout in the return URL (`/boards?pending=<token>`) as a signed,
  short-lived `Phoenix.Token` — nothing is stored server-side. It records the board's name, card
  key and `template` or `copy_from`, the user it was signed for (never trusted for anyone else),
  and `issued_at`, the unix second it was signed, which lets a replayed return find the board it
  already created (`Relay.Boards.get_created_board/3`) instead of creating a second one.
  """

  @salt "pending board"
  @max_age 86_400

  @type t :: %{
          user_id: pos_integer(),
          name: String.t(),
          key: String.t(),
          template: String.t() | nil,
          copy_from: String.t() | nil,
          issued_at: integer()
        }

  @doc "How long a pending-board token stays valid, in seconds: one day."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Signs `attrs` for `user`. Exactly one of `:template` / `:copy_from` is expected. `signed_at:`
  (unix seconds, default now) is both the token's timestamp and the recorded `issued_at`.
  """
  @spec sign(
          Schemas.User.t(),
          %{
            required(:name) => String.t(),
            required(:key) => String.t(),
            optional(:template) => String.t(),
            optional(:copy_from) => String.t()
          },
          keyword()
        ) :: String.t()
  def sign(%Schemas.User{id: user_id}, %{name: name, key: key} = attrs, opts \\ []) do
    signed_at = Keyword.get_lazy(opts, :signed_at, fn -> System.system_time(:second) end)
    # A tuple, not a map: the token rides in a URL, so the payload stays small.
    payload = {user_id, name, key, Map.get(attrs, :template), Map.get(attrs, :copy_from), signed_at}

    Phoenix.Token.sign(RelayWeb.Endpoint, @salt, payload, signed_at: signed_at)
  end

  @doc """
  The pending board `token` carries for `user`: `{:error, :invalid}` for a missing, tampered or
  malformed token, `{:error, :expired}` once it is older than `max_age/0`, and
  `{:error, :wrong_user}` for a token signed for somebody else.
  """
  @spec verify(String.t() | nil, Schemas.User.t()) :: {:ok, t()} | {:error, :invalid | :expired | :wrong_user}
  def verify(token, %Schemas.User{id: user_id}) do
    case Phoenix.Token.verify(RelayWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {^user_id, name, key, template, copy_from, issued_at}} ->
        {:ok, %{user_id: user_id, name: name, key: key, template: template, copy_from: copy_from, issued_at: issued_at}}

      {:ok, {_other_user_id, _name, _key, _template, _copy_from, _issued_at}} ->
        {:error, :wrong_user}

      {:error, :expired} ->
        {:error, :expired}

      _missing_invalid_or_malformed ->
        {:error, :invalid}
    end
  end
end
