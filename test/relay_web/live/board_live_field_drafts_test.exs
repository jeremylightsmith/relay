defmodule RelayWeb.BoardLiveFieldDraftsTest do
  @moduledoc """
  RE362 — unsaved text in the drawer's markdown editors survives switching cards and closing the
  drawer, for the life of the LiveView. Coming back to the card reopens the editor with the
  draft and an "Unsaved draft restored · Discard" note; Save/Cancel/Esc/Discard clear it.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages
    {:ok, first} = Cards.create_card(backlog, %{title: "First"})

    {:ok, first} =
      Cards.update_card(first, %{description: "Saved description", acceptance_criteria: "Saved criteria"})

    {:ok, second} = Cards.create_card(backlog, %{title: "Second"})

    %{board: board, first: first, second: second}
  end

  defp open(conn, board, card) do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  defp show(view, board, card) do
    render_patch(view, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")
    render_async(view)
    view
  end

  defp close(view, board) do
    render_patch(view, ~p"/board/#{board.slug}")
    view
  end

  defp type_description(view, text) do
    view
    |> element("#card-drawer-description-form")
    |> render_change(%{"card" => %{"description" => text}})
  end

  test "typing fresh shows no restored note", %{conn: conn, board: board, first: first} do
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "draft text 362")

    assert has_element?(view, "#card-drawer-description-input", "draft text 362")
    refute has_element?(view, "#card-drawer-description-draft-restored")
  end

  # Acceptance criterion 1: clicking the board background outside the drawer must not throw
  # the open editor away. The scrim is a close link at rest, and inert while one is open.
  test "the scrim does not close the drawer while a markdown editor is open", ctx do
    %{conn: conn, board: board, first: first} = ctx
    view = open(conn, board, first)
    assert has_element?(view, "a#card-drawer-scrim")

    render_click(view, "edit_description", %{})
    type_description(view, "draft text 362")

    refute has_element?(view, "a#card-drawer-scrim")
    assert has_element?(view, "#card-drawer-scrim")
    assert has_element?(view, "#card-drawer-description-input", "draft text 362")

    view |> element("#card-drawer-description-form") |> render_submit(%{"card" => %{"description" => "x"}})
    assert has_element?(view, "a#card-drawer-scrim")
  end

  test "a Description draft survives switching cards and closing the drawer", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "draft text 362")

    show(view, board, second)
    refute has_element?(view, "#card-drawer-description-input")

    close(view, board)
    show(view, board, first)

    assert has_element?(view, "#card-drawer-description-input", "draft text 362")
    assert has_element?(view, "#card-drawer-description-draft-restored", "Unsaved draft restored")
    assert has_element?(view, "#card-drawer-description-discard", "Discard")
  end

  test "Save commits the draft and clears it", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "draft text 362")
    show(view, board, second)
    show(view, board, first)

    view
    |> element("#card-drawer-description-form")
    |> render_submit(%{"card" => %{"description" => "draft text 362"}})

    refute has_element?(view, "#card-drawer-description-input")

    show(view, board, second)
    show(view, board, first)

    refute has_element?(view, "#card-drawer-description-input")
    refute has_element?(view, "#card-drawer-description-draft-restored")
    assert has_element?(view, "#card-drawer-description-view", "draft text 362")
    assert Cards.get_card_by_ref(board, Cards.ref(board, first)).description == "draft text 362"
  end

  test "Cancel throws the draft away", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "throwaway")

    view |> element("#card-drawer-description-cancel") |> render_click()
    show(view, board, second)
    show(view, board, first)

    refute has_element?(view, "#card-drawer-description-input")
    assert has_element?(view, "#card-drawer-description-view", "Saved description")
  end

  test "Discard resets to the saved value and keeps the editor open", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_acceptance_criteria", %{})

    view
    |> element("#card-drawer-acceptance-criteria-form")
    |> render_change(%{"card" => %{"acceptance_criteria" => "throwaway"}})

    show(view, board, second)
    show(view, board, first)
    assert has_element?(view, "#card-drawer-acceptance-criteria-draft-restored")

    view |> element("#card-drawer-acceptance-criteria-discard") |> render_click()

    assert has_element?(view, "#card-drawer-acceptance-criteria-input", "Saved criteria")
    refute has_element?(view, "#card-drawer-acceptance-criteria-input", "throwaway")
    refute has_element?(view, "#card-drawer-acceptance-criteria-draft-restored")

    # The draft is gone, so leaving and coming back lands at rest.
    show(view, board, second)
    show(view, board, first)
    refute has_element?(view, "#card-drawer-acceptance-criteria-input")
  end

  test "a draft equal to the saved value is dropped without a note", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "Saved description")

    show(view, board, second)
    show(view, board, first)

    refute has_element?(view, "#card-drawer-description-input")
    refute has_element?(view, "#card-drawer-description-draft-restored")
  end

  test "Spec, Plan and public description drafts reopen too", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)

    render_click(view, "edit_spec", %{})
    view |> element("#card-drawer-spec-form") |> render_change(%{"card" => %{"spec" => "spec draft"}})

    render_click(view, "edit_plan", %{})
    view |> element("#card-plan-form") |> render_change(%{"card" => %{"plan" => "plan draft"}})

    render_click(view, "start_public_desc", %{})
    view |> element("#public-desc-form") |> render_change(%{"public_description" => "public draft"})

    show(view, board, second)
    show(view, board, first)

    assert has_element?(view, "#card-drawer-spec-input", "spec draft")
    assert has_element?(view, "#card-drawer-spec-draft-restored")
    assert has_element?(view, "#card-plan-input", "plan draft")
    assert has_element?(view, "#card-plan-draft-restored")
    assert has_element?(view, "#public-desc-input", "public draft")
    assert has_element?(view, "#public-desc-draft-restored", "Unsaved draft restored")
  end

  test "saving a restored public description clears its draft", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "start_public_desc", %{})
    view |> element("#public-desc-form") |> render_change(%{"public_description" => "public draft"})
    show(view, board, second)
    show(view, board, first)

    view |> form("#public-desc-form", %{"public_description" => "public draft"}) |> render_submit()

    show(view, board, second)
    show(view, board, first)

    refute has_element?(view, "#public-desc-input")
    refute has_element?(view, "#public-desc-draft-restored")
    assert has_element?(view, "#card-drawer-public-description", "public draft")
  end

  test "discarding a restored public description resets it and keeps the editor open", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    {:ok, _card} = Cards.set_public_description(first, "Saved public")
    view = open(conn, board, first)
    render_click(view, "start_public_desc", %{})
    view |> element("#public-desc-form") |> render_change(%{"public_description" => "public draft"})
    show(view, board, second)
    show(view, board, first)

    view |> element("#public-desc-discard") |> render_click()

    assert has_element?(view, "#public-desc-input", "Saved public")
    refute has_element?(view, "#public-desc-draft-restored")
  end

  test "drafts live only as long as the LiveView", %{conn: conn, board: board, first: first} do
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    type_description(view, "draft text 362")

    reloaded = open(conn, board, first)

    refute has_element?(reloaded, "#card-drawer-description-input")
    assert has_element?(reloaded, "#card-drawer-description-view", "Saved description")
  end

  test "a late or unknown draft event is ignored", ctx do
    %{conn: conn, board: board, first: first, second: second} = ctx
    view = open(conn, board, first)
    render_click(view, "edit_description", %{})
    view |> element("#card-drawer-description-cancel") |> render_click()

    # Arrives after Cancel closed the editor (debounce) — must not resurrect a draft.
    render_hook(view, "draft_field", %{"card" => %{"description" => "late"}})
    # Not a drafted field at all.
    render_hook(view, "draft_field", %{"card" => %{"title" => "nope"}})
    render_hook(view, "discard_draft", %{"field" => "title"})

    show(view, board, second)
    show(view, board, first)

    refute has_element?(view, "#card-drawer-description-input")
    assert Cards.get_card_by_ref(board, Cards.ref(board, first)).title == "First"
  end
end
