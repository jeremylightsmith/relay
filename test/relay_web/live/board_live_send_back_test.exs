defmodule RelayWeb.BoardLiveSendBackTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  # Default pipeline: Backlog1 | Spec2 | Plan3 | Code4 | Review5 | Deploy6 | Done7.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, review} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})
    %{board: board, spec: spec, code: code, review: review}
  end

  test "the amber banner renders for a card with an open rejection and names the target", %{
    conn: conn,
    code: code,
    review: review,
    user: user
  } do
    {:ok, card} = Cards.create_card(review, %{title: "Redo me"})
    {:ok, _sent} = Cards.send_back(card, code, "Handle the empty case", :agent)

    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    assert has_element?(view, "#rejection-banner", "Changes requested")
    assert has_element?(view, "#rejection-banner", "Handle the empty case")
    assert has_element?(view, "#rejection-banner", "Code")
  end

  test "no banner for a clean card", %{conn: conn, code: code, user: user} do
    {:ok, _card} = Cards.create_card(code, %{title: "Clean"})
    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    refute has_element?(view, "#rejection-banner")
  end

  test "the universal Send back control moves the card and opens the banner", %{
    conn: conn,
    board: board,
    spec: spec,
    code: code
  } do
    {:ok, _card} = Cards.create_card(code, %{title: "Bounce me"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")

    view |> element("#send-back") |> render_click()
    assert has_element?(view, "#send-back-panel")

    view
    |> form("#send-back-form", send_back: %{to: spec.id, note: "This is really a spec problem"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == spec.id
    assert reloaded.rejection.note == "This is really a spec problem"
    assert has_element?(view, "#rejection-banner", "This is really a spec problem")
  end

  test "Send back with an empty note is a no-op with an inline prompt", %{
    conn: conn,
    board: board,
    spec: spec,
    code: code
  } do
    {:ok, _card} = Cards.create_card(code, %{title: "Bounce me"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    view |> element("#send-back") |> render_click()
    view |> form("#send-back-form", send_back: %{to: spec.id, note: "   "}) |> render_submit()

    assert has_element?(view, "#send-back-error")
    assert Cards.get_card_by_ref(board, "RLY-1").stage_id == code.id
  end

  test "no Send back control on the first stage (nothing before it)", %{conn: conn, board: board} do
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))
    {:ok, _card} = Cards.create_card(backlog, %{title: "First"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#send-back")
  end

  test "the gate reject panel exposes a target picker defaulting to the configured reject_to", %{
    conn: conn,
    board: board,
    code: code,
    review: review
  } do
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, _} = Cards.set_status(card, %{status: :in_review})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    view |> element("#review-request-changes") |> render_click()

    assert has_element?(view, "#review-reject-target")

    view
    |> form("#review-reject-form", reject: %{to: code.id, note: "Tighten it"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == code.id
    assert reloaded.rejection
  end

  test "Mark done clears an open rejection", %{conn: conn, board: board, code: code, review: review} do
    {:ok, card} = Cards.create_card(review, %{title: "Done me"})
    {:ok, sent} = Cards.send_back(card, code, "fix", :agent)
    {:ok, _in_review} = Cards.set_status(sent, %{status: :in_review})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=RLY-1")
    assert has_element?(view, "#rejection-banner")

    view |> element("#review-mark-done") |> render_click()

    assert Cards.get_card_by_ref(board, "RLY-1").rejection == nil
    refute has_element?(view, "#rejection-banner")
  end
end
