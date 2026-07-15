defmodule RelayWeb.Api.FeedJSON do
  @moduledoc """
  The native inbox's row shape (RLY-80). Every row carries enough to render without a
  second fetch: the ref, its board, why it needs you, and (on structured needs-input
  rows) the questions the native stepper renders as option buttons.
  """

  alias Relay.Boards
  alias Relay.Cards

  def feed(%{rows: rows}) do
    %{data: Enum.map(rows, &row/1), meta: %{count: length(rows)}}
  end

  defp row(%{card: card} = entry) do
    %{
      ref: Cards.ref(card.board, card),
      title: card.title,
      board: %{name: card.board.name, key: card.board.key, slug: card.board.slug},
      tag: card.tag,
      status: card.status,
      # == status. Explicit, because the mobile two-type contract (needs_input | in_review)
      # is narrower than the board's needs-you rollup and must not silently follow it.
      kind: card.status,
      reason: reason(entry),
      blocked_at: card.blocked_since || card.updated_at,
      questions: entry.questions
    }
  end

  # The row's one-line "why it needs you". needs_input: the flattened latest question.
  # in_review: the PR url when there is one, else the review stage's display name.
  defp reason(%{card: %{status: :needs_input}} = entry), do: entry.question

  defp reason(%{card: %{status: :in_review, pr_url: pr_url}}) when is_binary(pr_url) and pr_url != "", do: pr_url

  defp reason(%{card: %{status: :in_review} = card}), do: Boards.stage_display_name(card.stage)
end
