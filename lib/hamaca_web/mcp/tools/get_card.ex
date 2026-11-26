defmodule HamacaWeb.Mcp.Tools.GetCard do
  @moduledoc """
  `get_card` (RE519): one card by ref — where it is, who holds the baton, its description, a spec
  excerpt and its recent activity. Resolved through `Hamaca.Cards.resolve_ref/3`, so a card on a
  board the user isn't a member of reads exactly like a missing one.
  """

  @behaviour HamacaWeb.Mcp.Tool

  alias Hamaca.Activity
  alias Hamaca.Boards
  alias Hamaca.Brand
  alias Hamaca.Cards
  alias HamacaWeb.Mcp.Format
  alias HamacaWeb.TimeAgo

  @description_chars 1500
  @spec_chars 1000
  @comment_chars 280
  @timeline_entries 10

  @impl true
  def name, do: "get_card"

  @impl true
  def description do
    "Show one Hamaca card by its ref (e.g. RE519): its board, stage, status, who holds the baton, " <>
      "its description, a spec excerpt and its recent activity. Use it when the user asks about a " <>
      "specific card. Pass `board` (name, key or slug) only when the ref is on more than one board. " <>
      "Always name the board and link each card in your reply."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        ref: %{type: "string", description: "The card's ref, e.g. \"RE519\"."},
        board: %{type: "string", description: "The board's name, key or slug, when the ref is on several boards."}
      },
      required: ["ref"]
    }
  end

  @impl true
  def call(user, %{"ref" => ref} = args) when is_binary(ref) do
    case args["board"] do
      query when is_binary(query) ->
        case Boards.resolve_board(user, query) do
          {:ok, board} -> lookup(user, ref, board)
          {:error, choice} -> {:error, Format.board_choice_error(query, choice)}
        end

      _no_board ->
        lookup(user, ref, nil)
    end
  end

  def call(_user, _args), do: {:error, "ref is required: pass the card's ref, e.g. RE519."}

  defp lookup(user, ref, board) do
    case Cards.resolve_ref(user, ref, board && board.slug) do
      {:ok, board, card} -> {:ok, render(board, card, DateTime.utc_now())}
      {:error, :not_found} when is_nil(board) -> {:error, "No card #{ref} on your boards."}
      {:error, :not_found} -> {:error, "No card #{ref} on #{Format.board_label(board)}."}
      {:error, :ambiguous_ref} -> {:error, ambiguous(user, ref)}
    end
  end

  defp ambiguous(user, ref) do
    boards =
      user
      |> Boards.list_boards()
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&match?({:ok, _board, _card}, Cards.resolve_ref(user, ref, &1.slug)))

    "#{ref} is on more than one of your boards: #{Format.labels(boards)}. Which one? " <>
      "Ask again with `board` set to one of: #{boards |> Enum.map(& &1.slug) |> Enum.sort() |> Enum.join(", ")}."
  end

  defp render(board, card, now) do
    ref = Cards.ref(board, card)
    stage = Enum.find(Boards.list_stages(board), &(&1.id == card.stage_id))

    [
      Enum.join(
        [
          "**#{ref} · #{card.title}** — #{Format.board_label(board)}",
          "Stage: #{stage && stage.name} · Status: #{card.status} · Baton: #{baton(card)}",
          "Link: #{Format.card_url(board, ref)}"
        ],
        "\n"
      ),
      blank_or(card.description, &excerpt(&1, @description_chars)),
      blank_or(card.spec, &("**Spec (excerpt)**\n" <> excerpt(&1, @spec_chars))),
      "**Recent activity**\n" <> timeline(card, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp baton(card) do
    case Cards.active_owner_type(card) do
      :ai -> Brand.agent_name()
      :human -> Enum.map_join(card.owners, ", ", &person(&1.user))
      nil -> "nobody"
    end
  end

  defp timeline(card, now) do
    case card |> Activity.list_timeline() |> Enum.take(-@timeline_entries) do
      [] -> "- Nothing yet."
      entries -> Enum.map_join(entries, "\n", &entry(&1, now))
    end
  end

  defp entry(%Schemas.Comment{} = comment, now) do
    "- #{TimeAgo.ago(now, comment.inserted_at)} · #{author(comment)}: #{comment.body |> one_line() |> excerpt(@comment_chars)}"
  end

  defp entry(%Schemas.Activity{} = activity, now) do
    "- #{TimeAgo.ago(now, activity.inserted_at)} · #{author(activity)} #{activity.type}: #{one_line(activity.text || "")}"
  end

  defp author(%{actor_type: :agent}), do: Brand.agent_name()
  defp author(%{user: user}), do: person(user)

  defp person(%{name: name}) when is_binary(name) and name != "", do: name
  defp person(%{email: email}) when is_binary(email), do: email
  defp person(_unknown), do: "someone"

  defp blank_or(text, render) do
    if is_binary(text) and String.trim(text) != "", do: render.(text)
  end

  defp excerpt(text, chars) do
    if String.length(text) > chars, do: String.slice(text, 0, chars) <> "…", else: text
  end

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")
end
