defmodule RelayWeb.BoardLiveReviewTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Comment

  setup :register_and_log_in_user

  # Default pipeline (positions 1-7): Backlog | Spec | Plan | Code(:ai) |
  # Review(:human) | Deploy(:ai) | Done. Review becomes an approval gate
  # whose reject target is Code; Code stays ungated.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    deploy = Enum.find(board.stages, &(&1.name == "Deploy"))
    {:ok, review} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})
    %{board: board, code: code, review: review, deploy: deploy}
  end

  defp in_review_card(stage, title \\ "Review me") do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  test "no review panel renders for a card that is not in review", %{conn: conn, review: review} do
    {:ok, _card} = Cards.create_card(review, %{title: "Still queued"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
  end

  test "an in_review card on a gated stage shows the full green panel", %{conn: conn, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    assert has_element?(view, "#review-approve", "Approve → Deploy")
    assert has_element?(view, "#review-request-changes", "Request changes")
    assert has_element?(view, "#review-mark-done", "Mark done")
    assert has_element?(view, "#review-pull", "Pull")
    refute has_element?(view, "#review-request-note")
  end

  test "an in_review card on a non-gated stage shows only Mark done and Pull", %{conn: conn, code: code} do
    in_review_card(code)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    refute has_element?(view, "#review-approve")
    refute has_element?(view, "#review-request-changes")
    assert has_element?(view, "#review-mark-done")
    assert has_element?(view, "#review-pull")
  end

  test "Approve advances the card to the next main stage and logs :approved",
       %{conn: conn, user: user, board: board, review: review, deploy: deploy} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-approve") |> render_click()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == deploy.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
    assert has_element?(view, "#stage-col-#{deploy.position}-cards .board-card", "Review me")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "approved")

    entry = reloaded |> Activity.list_timeline() |> Enum.find(&match?(%Schemas.Activity{type: :approved}, &1))
    assert entry.actor_type == :user
    assert entry.user_id == user.id
  end

  test "Request changes expands in place, names the target, and routes back with the note",
       %{conn: conn, user: user, board: board, code: code, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()

    assert has_element?(view, "#review-reject-panel", "Code")
    assert has_element?(view, "#review-request-note")
    refute has_element?(view, "#review-approve")

    view
    |> form("#review-reject-form", reject: %{note: "Tighten the error handling"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == code.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-timeline .timeline-comment-body", "Tighten the error handling")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "requested changes")

    timeline = Activity.list_timeline(reloaded)
    note = Enum.find(timeline, &match?(%Comment{body: "Tighten the error handling"}, &1))
    assert note.actor_type == :user
    assert note.user_id == user.id
    assert Enum.any?(timeline, &match?(%Schemas.Activity{type: :rejected}, &1))
  end

  test "Send back with an empty note is a no-op with an inline prompt",
       %{conn: conn, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()
    view |> form("#review-reject-form", reject: %{note: "   "}) |> render_submit()

    assert has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-note-error")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :in_review
  end

  test "Cancel collapses the note sub-panel back to the button row", %{conn: conn, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()
    assert has_element?(view, "#review-reject-panel")

    view |> element("#review-cancel-reject") |> render_click()

    refute has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-approve")
  end

  test "Mark done sets :done, logs the status change, and removes the panel",
       %{conn: conn, user: user, board: board, code: code} do
    in_review_card(code)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-mark-done") |> render_click()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.status == :done

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "set status to done")

    entry =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Schemas.Activity{type: :status_changed, meta: %{"to_status" => "done"}}, &1))

    assert entry.actor_type == :user
    assert entry.user_id == user.id
  end

  test "Pull adds the signed-in user as an owner and hides the button",
       %{conn: conn, user: user, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    assert has_element?(view, "#review-pull")

    view |> element("#review-pull") |> render_click()

    refute has_element?(view, "#review-pull")
    assert has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-rail .rail-owner", "Test User")
    assert has_element?(view, "#card-drawer-rail .rail-active-worker", "Test User")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "added Test User as owner")

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert Enum.any?(reloaded.owners, &(&1.actor_type == :user and &1.user_id == user.id))
  end

  test "the review and needs-input panels are mutually exclusive by status",
       %{conn: conn, review: review} do
    card = in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    assert has_element?(view, "#review-panel")
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which palette?")

    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
    assert has_element?(view, "#needs-input-panel", "Which palette?")
  end

  test "review transitions from elsewhere update an open drawer live (MMF 18)",
       %{conn: conn, review: review} do
    {:ok, card} = Cards.create_card(review, %{title: "Live review"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    refute has_element?(view, "#review-panel")

    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")

    {:ok, _approved} = Cards.approve(card)
    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
  end
end
