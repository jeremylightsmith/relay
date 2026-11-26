defmodule HamacaWeb.OAuthHTML do
  @moduledoc """
  The OAuth consent screen and its error page (`HamacaWeb.OAuthController`, RE519). The
  consent bullets come from `Hamaca.Connections.capabilities/1` and are never typed here.
  """
  use HamacaWeb, :html

  embed_templates "oauth_html/*"

  @doc "The client's self-declared name, or a neutral stand-in when it gave none."
  @spec client_label(String.t() | nil) :: String.t()
  def client_label(name) when is_binary(name) do
    if String.trim(name) == "", do: "An application", else: name
  end

  def client_label(_name), do: "An application"

  @doc ~s(The sign-in provider as people say it: "google" → "Google".)
  @spec provider_label(String.t() | nil) :: String.t()
  def provider_label("google"), do: "Google"
  def provider_label("apple"), do: "Apple"
  def provider_label(provider) when is_binary(provider), do: String.capitalize(provider)
  def provider_label(_provider), do: ""

  @doc "Splits the `cannot` sentence around its first \"can't\", so the template can emphasise it."
  @spec cannot_parts(String.t()) :: {String.t(), String.t() | nil, String.t()}
  def cannot_parts(sentence) do
    case String.split(sentence, "can't", parts: 2) do
      [before, rest] -> {before, "can't", rest}
      [whole] -> {whole, nil, ""}
    end
  end
end
