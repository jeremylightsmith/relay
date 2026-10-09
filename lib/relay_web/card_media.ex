defmodule RelayWeb.CardMedia do
  @moduledoc """
  RE390 — the one item shape every Mockups / Screenshots tile and the same-tab viewer render:

      %{key: String.t() | pos_integer(), src: String.t(), caption: String.t() | nil, kind: :html | :image}

  A mockup's `key` is its attachment id; a screenshot's is its 1-based position among the card's
  openable screenshots. A screenshot this browser can't fetch becomes a placeholder
  (`%{key: nil, src: nil, caption: String.t(), kind: :placeholder}`) — drawn in the drawer only,
  never in a viewer list.

  One rule decides how an item is drawn (`kind/2`): HTML only when its url is an
  `/attachments/<id>` whose content type `Schemas.Attachment.html?/1` accepts; everything else is
  an image. So only same-origin uploaded HTML is ever framed.
  """

  alias RelayWeb.TimeAgo
  alias Schemas.Attachment
  alias Schemas.Card
  alias Schemas.Comment

  @type item :: %{
          required(:key) => String.t() | pos_integer(),
          required(:src) => String.t(),
          required(:caption) => String.t() | nil,
          required(:kind) => :html | :image,
          optional(:byline) => String.t()
        }
  @type placeholder :: %{key: nil, src: nil, caption: String.t(), kind: :placeholder}

  @doc "How an item at `src` is drawn, given the card's `%{attachment_id => content_type}` map."
  @spec kind(String.t(), %{String.t() => String.t()}) :: :html | :image
  def kind(src, types) do
    with {:ok, id} <- Attachment.id_from_path(src),
         true <- Attachment.html?(Map.get(types, id)) do
      :html
    else
      _not_html -> :image
    end
  end

  @doc "The card's mockups (`Schemas.Card.mockup_entries/1`) as items, order kept."
  @spec mockup_items(term(), map()) :: [item()]
  def mockup_items(mockups, types) do
    for %{id: id, caption: caption} <- Card.mockup_entries(mockups) do
      src = RelayWeb.attachment_path(id)
      %{key: id, src: src, caption: caption, kind: kind(src, types)}
    end
  end

  @doc """
  RE427 — every image of every note as an item: comments in the given (oldest-first) order, then
  each comment's `images` order. The byline names the note's author and its age. A comment whose
  `images` is empty or not loaded contributes nothing.
  """
  @spec note_image_items([Comment.t()]) :: [item()]
  def note_image_items(comments) do
    for %Comment{images: images} = comment when is_list(images) <- comments,
        %Attachment{id: id, filename: filename} <- images do
      %{
        key: id,
        src: RelayWeb.attachment_path(id),
        caption: filename,
        kind: :image,
        byline: "From a note by #{author(comment)} · #{TimeAgo.ago(comment.inserted_at)}"
      }
    end
  end

  @doc "How a note's author is named: \"Relay AI\" for the agent, else the user's name or email."
  @spec author(Comment.t()) :: String.t()
  def author(%Comment{actor_type: :agent}), do: "Relay AI"
  def author(%Comment{actor_type: :user, user: user}), do: user.name || user.email

  @doc """
  The `ai_result`'s screenshots as items, with a placeholder wherever an entry can't be drawn.
  Fetchable entries are keyed 1, 2, … in order.
  """
  @spec screens(term(), map()) :: [item() | placeholder()]
  def screens(%{} = ai_result, types) do
    {items, _count} =
      ai_result
      |> Map.get("screens")
      |> ai_list()
      |> Enum.map_reduce(0, fn entry, count -> screen(entry, count, types) end)

    items
  end

  def screens(_ai_result, _types), do: []

  @doc "`screens/2` without the placeholders — the screenshots the viewer can open."
  @spec screenshot_items(term(), map()) :: [item()]
  def screenshot_items(ai_result, types), do: Enum.reject(screens(ai_result, types), &(&1.kind == :placeholder))

  # `ai_result` is a free-form JSON blob an agent writes over the API, so the drawer can never
  # assume a caller honoured the documented shape — and a raise here kills the LiveView on every
  # mount, which the browser sees as an endless reconnect loop (TH8 on `changes`, TH95 on
  # `screens`, where the smoke node wrote bare screenshot paths instead of maps). Every read of
  # the blob goes through a shape-tolerant reader, so no shape can break the render.
  @doc "Coerces an `ai_result` list value: a list is itself, nil / \"\" are empty, anything else is one entry."
  @spec ai_list(term()) :: list()
  def ai_list(value) when is_list(value), do: value
  def ai_list(value) when value in [nil, ""], do: []
  def ai_list(value), do: [value]

  defp screen(%{} = entry, count, types), do: screen_item(text(entry["url"]), text(entry["caption"]), count, types)
  defp screen(entry, count, types) when is_binary(entry), do: screen_item(entry, nil, count, types)
  defp screen(entry, count, _types), do: {placeholder(inspect(entry)), count}

  # A screenshot path on the agent's machine (`tmp/smoke/12-review.png`) is not something this
  # browser can fetch, so it captions the placeholder tile instead of rendering as a broken image.
  defp screen_item(url, caption, count, types) do
    if fetchable_url?(url) do
      {%{key: count + 1, src: url, caption: caption, kind: kind(url, types)}, count + 1}
    else
      {placeholder(caption || (url && Path.basename(url)) || "Screenshot"), count}
    end
  end

  defp placeholder(caption), do: %{key: nil, src: nil, caption: caption, kind: :placeholder}

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  @doc """
  Whether this browser can load `url`: http(s)://, protocol-relative `//`, a `data:image/` URI, a
  root-relative path under one of `RelayWeb.static_paths/0`, or an uploaded `/attachments/<id>`.
  """
  @spec fetchable_url?(term()) :: boolean()
  def fetchable_url?("http://" <> _rest), do: true
  def fetchable_url?("https://" <> _rest), do: true
  def fetchable_url?("//" <> _rest), do: true
  def fetchable_url?("data:image/" <> _rest), do: true

  # A root-relative src only resolves if this app serves that path: a static prefix, or an uploaded
  # attachment (RE322 — `relay attach` hands agents `/attachments/<id>`, a router route rather than a
  # static path, so checking static_paths alone drew every uploaded screenshot as the placeholder).
  # An agent's local screenshot path ("/Users/…/tmp/smoke/12-review.png") is neither, and must not
  # become a broken <img>.
  def fetchable_url?("/" <> path = url) do
    [prefix | _rest] = String.split(path, "/", parts: 2)
    prefix in RelayWeb.static_paths() or RelayWeb.attachment_path?(url)
  end

  def fetchable_url?(_url), do: false
end
