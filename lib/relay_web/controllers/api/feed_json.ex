defmodule RelayWeb.Api.FeedJSON do
  @moduledoc """
  The native inbox's row shape (RLY-80). Every row carries enough to render without a
  second fetch: the ref, its board and stage, why it needs you, and (on structured
  needs-input rows) the questions the native stepper renders as option buttons.
  """

  alias Relay.Boards
  alias Relay.Cards

  def feed(%{rows: rows}) do
    %{data: Enum.map(rows, &row/1), meta: %{count: length(rows)}}
  end

  defp row(%{card: card} = entry) do
    # One parent lookup per row, feeding BOTH the breadcrumb and the grouping field —
    # stage_display_name/1 would otherwise Repo.get! the parent again, and reason/1 a third time.
    top = Boards.top_level_stage(card.stage)
    stage_name = Boards.stage_display_name(card.stage, top)

    %{
      ref: Cards.ref(card.board, card),
      title: card.title,
      board: %{name: card.board.name, key: card.board.key, slug: card.board.slug},
      # INPUT-01's breadcrumb is "<Board> / <Stage>" (RLY-89). Cards.needs_you_feed/1 already
      # preloads :stage, and reason/1 already renders it for in_review rows.
      stage: stage_name,
      # RLY-156: the TOP-LEVEL stage the native inbox groups by, and the board-order
      # `position` it renders those groups in. A sub-lane card carries its parent's
      # name, type, AND position, so `Code · Review` groups under CODE, takes Code's
      # colour, and sorts at Code's place in the board — not the sub-lane's high position.
      # Additive — `stage` above is still the breadcrumb and is unchanged.
      stage_group: %{name: top.name, type: to_string(top.type), position: top.position},
      tag: card.tag,
      status: card.status,
      # == status. Explicit, because the mobile two-type contract (needs_input | in_review)
      # is narrower than the board's needs-you rollup and must not silently follow it.
      kind: card.status,
      reason: reason(entry, stage_name),
      blocked_at: card.blocked_since || card.updated_at,
      questions: entry.questions
    }
  end

  # The row's one-line "why it needs you". needs_input: the flattened latest question.
  # in_review: the PR url when there is one, else the stage display name row/1 already resolved.
  defp reason(%{card: %{status: :needs_input}} = entry, _stage_name), do: entry.question

  defp reason(%{card: %{status: :in_review, pr_url: pr_url}}, _stage_name) when is_binary(pr_url) and pr_url != "",
    do: pr_url

  defp reason(%{card: %{status: :in_review}}, stage_name), do: stage_name
end
