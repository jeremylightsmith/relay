defmodule RelayWeb.BoardLiveDependencyGateTest do
  @moduledoc "RE93 — the board's queued face chip obeys the SAME gate the scheduler does."
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Cards
  alias Relay.Repo

  setup :register_and_log_in_user

  setup %{conn: conn, user: user} do
    board = insert(:board, owner: user, key: "RE")
    insert(:membership, board: board, user: user)

    next_up = insert(:stage, board: board, name: "Next up", category: :unstarted, type: :queue, position: 1)
    code = insert(:stage, board: board, name: "Code", category: :in_progress, type: :work, position: 2)
    done = insert(:stage, board: board, name: "Done", category: :complete, type: :done, position: 3)

    insert(:flow,
      board: board,
      key: "code",
      enabled: true,
      pulls_from_stage_id: next_up.id,
      works_in_stage_id: code.id
    )

    a = insert(:card, stage: next_up, ref_number: 1, status: :ready, title: "Dependent")
    b = insert(:card, stage: next_up, ref_number: 2, status: :ready, title: "Blocker")
    insert(:card_owner, card: a)
    insert(:card_owner, card: b)

    %{conn: conn, board: board, next_up: next_up, done: done, a: a, b: b}
  end

  # The board stream is `:"stage_cards_<stage_id>"` (BoardLive.stream_name/1) with LiveView's
  # default dom_id, so a card's element is `#stage_cards_<stage_id>-<card_id>`.
  defp card_el(card), do: "#stage_cards_#{card.stage_id}-#{card.id}"

  test "a blocked card shows no queued face; clearing the blockers brings it back", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    assert has_element?(view, "#{card_el(ctx.a)} .run-face-queued")

    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    refute has_element?(view, "#{card_el(ctx.a)} .run-face-queued")

    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, [])
    assert has_element?(view, "#{card_el(ctx.a)} .run-face-queued")
  end

  test "moving the blocker to Done repaints the DEPENDENT with no reload", ctx do
    {:ok, _} = Cards.set_dependencies(ctx.board, ctx.a, ["RE2"])
    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    refute has_element?(view, "#{card_el(ctx.a)} .run-face-queued")

    {:ok, _} = Cards.move_card(ctx.b, ctx.done, 0, :agent)

    assert has_element?(view, "#{card_el(ctx.a)} .run-face-queued")
  end

  test "archiving a blocker repaints a DONE-column dependent instead of leaving it stale", ctx do
    dependent = insert(:card, stage: ctx.done, ref_number: 3, status: :in_review, title: "Original title")
    insert(:card_owner, card: dependent)
    {:ok, _} = Cards.set_dependencies(ctx.board, dependent, ["RE2"])

    {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.board.slug}")
    assert has_element?(view, card_el(dependent), "Original title")

    # Mutate the row directly, bypassing Cards.update_card's own broadcast, so the ONLY
    # thing that can pick up the new title is refresh_blocked_by's terminal-stage repaint —
    # proving that repaint actually re-streams the card instead of skipping it (RE93).
    Repo.update!(Ecto.Changeset.change(dependent, title: "Updated title"))

    {:ok, _} = Cards.archive_card(ctx.b)

    assert has_element?(view, card_el(dependent), "Updated title")
  end
end
