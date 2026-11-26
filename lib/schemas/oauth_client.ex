defmodule Schemas.OAuthClient do
  @moduledoc """
  An OAuth client registered dynamically by a Claude client (RE519, owned by
  `Hamaca.Connections`). `client_id` is a public random id (no client secret — public
  clients prove possession with PKCE). `redirect_uris` are matched exactly at authorize
  time. `client_name` and `redirect_uris` are the only fields taken from input, and only
  after `Hamaca.Connections.register_client/1` has validated them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "oauth_clients" do
    field :client_id, :string
    field :client_name, :string
    field :redirect_uris, {:array, :string}

    has_many :grants, Schemas.OAuthGrant, foreign_key: :oauth_client_id

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built client row."
  def changeset(oauth_client) do
    oauth_client
    |> change()
    |> validate_required([:client_id, :redirect_uris])
    |> unique_constraint(:client_id)
  end
end
