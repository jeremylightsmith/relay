defmodule RelayWeb.BoardLiveReviewTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Comment

  setup :register_and_log_in_user

  # Default 8-stage pipeline: Backlog | Next up | Spec | Plan | Code(:work, ai) |
  # Review(:review type) | Deploy(:work, ai) | Done. Review is a review-type stage by
  # seed default, so it's already a gate — its reject target defaults to Code (the
  # previous main stage); Code (type :work) is never itself a review-type stage.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    deploy = Enum.find(board.stages, &(&1.name == "Deploy"))
    %{board: board, code: code, review: review, deploy: deploy}
  end

  defp in_review_card(stage, title \\ "Review me") do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  test "no review panel renders for a card that is not in review", %{conn: conn, review: review, user: user} do
    {:ok, _card} = Cards.create_card(review, %{title: "Still queued"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
  end

  test "an in_review card on a gated stage shows the full green panel", %{conn: conn, review: review, user: user} do
    in_review_card(review)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    assert has_element?(view, "#review-approve", "Approve → Deploy")
    assert has_element?(view, "#review-request-changes", "Request changes")
    refute has_element?(view, "#review-request-note")
  end

  test "Approve names the parent's Done substage when the card is in a review substage",
       %{conn: conn, code: code, user: user} do
    {:ok, review_sub} = Boards.enable_lane(code, :review)
    {:ok, _done_sub} = Boards.enable_lane(code, :done)
    in_review_card(review_sub)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#review-approve", "Approve → Code · Done")
  end

  test "an in_review card on a non-gated stage shows the banner but no decision buttons", %{
    conn: conn,
    code: code,
    user: user
  } do
    in_review_card(code)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    refute has_element?(view, "#review-approve")
    refute has_element?(view, "#review-request-changes")
    refute has_element?(view, "#review-mark-done")
    refute has_element?(view, "#review-pull")
  end

  test "Approve advances the card to the next main stage and logs :approved",
       %{conn: conn, user: user, board: board, review: review, deploy: deploy} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#review-approve") |> render_click()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == deploy.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
    assert has_element?(view, "#stage-col-#{deploy.position}-cards .board-card", "Review me")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "approved")

    entry = reloaded |> Activity.list_timeline() |> Enum.find(&match?(%Schemas.Activity{type: :approved}, &1))
    assert entry.actor_type == :user
    assert entry.user_id == user.id
  end

  test "Request changes expands in place, names the target, and routes back with the note",
       %{conn: conn, user: user, board: board, code: code, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#review-request-changes") |> render_click()

    assert has_element?(view, "#review-reject-panel", "Code")
    assert has_element?(view, "#review-request-note")
    refute has_element?(view, "#review-approve")

    assert has_element?(view, "#review-reject-panel", "Returns to")
    assert has_element?(view, "#review-reject-panel", "Code")
    assert has_element?(view, "#review-send-back", "Reject → Code")
    assert has_element?(view, ~s|#review-send-back[style*="oklch(0.62 0.14 65)"]|)
    refute has_element?(view, "#review-reject-target")
    refute has_element?(view, "#review-approve")

    view
    |> form("#review-reject-form", reject: %{note: "Tighten the error handling"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == code.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-conversation .timeline-comment-body", "Tighten the error handling")
    assert has_element?(view, "#card-drawer-activity .timeline-activity-phrase", "requested changes")

    timeline = Activity.list_timeline(reloaded)
    note = Enum.find(timeline, &match?(%Comment{body: "Tighten the error handling"}, &1))
    assert note.actor_type == :user
    assert note.user_id == user.id
    assert Enum.any?(timeline, &match?(%Schemas.Activity{type: :rejected}, &1))
  end

  test "the reject panel shows the derived destination and offers no picker",
       %{conn: conn, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)
    view |> element("#review-request-changes") |> render_click()

    assert has_element?(view, "#review-reject-panel", "the reject target set on this stage")
    assert has_element?(view, "#review-send-back", "Reject → Code")
    refute has_element?(view, "#review-reject-target")
  end

  test "a review stage that is the board's first column shows Approve but no Request changes",
       %{conn: conn, user: user} do
    {:ok, board} = Boards.create_board(user, %{name: "Gate first", key: "RLY"})
    first = board.stages |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.min_by(& &1.position)
    {:ok, first} = Boards.update_stage(first, %{type: :review})
    in_review_card(first)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    assert has_element?(view, "#review-approve")
    refute has_element?(view, "#review-request-changes")
  end

  test "Send back with an empty note is a no-op with an inline prompt",
       %{conn: conn, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#review-request-changes") |> render_click()
    view |> form("#review-reject-form", reject: %{note: "   "}) |> render_submit()

    assert has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-note-error")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :in_review
  end

  test "Cancel collapses the note sub-panel back to the button row", %{conn: conn, review: review, user: user} do
    in_review_card(review)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    render_async(view)

    view |> element("#review-request-changes") |> render_click()
    assert has_element?(view, "#review-reject-panel")

    view |> element("#review-cancel-reject") |> render_click()

    refute has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-approve")
  end

  test "the review and needs-input panels are mutually exclusive by status",
       %{conn: conn, review: review, user: user} do
    card = in_review_card(review)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    assert has_element?(view, "#review-panel")
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which palette?")

    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
    assert has_element?(view, "#needs-input-panel", "Which palette?")
  end

  test "review transitions from elsewhere update an open drawer live (MMF 18)",
       %{conn: conn, review: review, user: user} do
    {:ok, card} = Cards.create_card(review, %{title: "Live review"})

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    refute has_element?(view, "#review-panel")

    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")

    {:ok, _approved} = Cards.approve(card)
    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
  end
end
