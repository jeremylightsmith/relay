defmodule RelayWeb.BoardLiveTagTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Card

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages
    {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec", tag: "spec"})
    %{board: board, backlog: backlog, card: card}
  end

  describe "drawer TAGS section" do
    test "shows the tag as the shipped badge chip when set", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      # badge badge-ghost badge-sm — pinned to the Relay Board artboard's rail chip
      assert has_element?(view, "#card-tag-display.badge.badge-ghost.badge-sm", "#spec")
      refute has_element?(view, "#card-tag-form")
    end

    test "shows the italic None placeholder when unset",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Untagged"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY2")
      render_async(view)

      assert has_element?(view, "#card-tag-display .italic", "None")
      refute has_element?(view, "#card-tag-display.badge")
    end

    test "clicking the value opens the editor with a datalist of the board's tags",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, _} = Cards.create_card(backlog, %{title: "Other", tag: "infra"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      view |> element("#card-tag-display") |> render_click()

      assert has_element?(view, "#card-tag-form input#card-tag-input")
      assert has_element?(view, ~s(#card-tag-input[list="card-tag-datalist"]))
      assert has_element?(view, ~s(#card-tag-datalist option[value="infra"]))
      assert has_element?(view, ~s(#card-tag-datalist option[value="spec"]))
    end

    test "committing a value sets the tag on the drawer and the card face",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      view |> element("#card-tag-display") |> render_click()
      view |> form("#card-tag-form", card: %{tag: "design"}) |> render_submit()

      assert Repo.get!(Card, card.id).tag == "design"
      assert has_element?(view, "#card-tag-display.badge.badge-ghost.badge-sm", "#design")
      refute has_element?(view, "#card-tag-form")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-tag", "#design")
    end

    test "a #-prefixed padded value is stored normalized",
         %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      view |> element("#card-tag-display") |> render_click()
      view |> form("#card-tag-form", card: %{tag: " #infra "}) |> render_submit()

      assert Repo.get!(Card, card.id).tag == "infra"
      assert has_element?(view, "#card-tag-display", "#infra")
    end

    test "committing empty clears the tag everywhere", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      view |> element("#card-tag-display") |> render_click()
      view |> form("#card-tag-form", card: %{tag: ""}) |> render_submit()

      assert Repo.get!(Card, card.id).tag == nil
      assert has_element?(view, "#card-tag-display .italic", "None")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-tag")
    end

    test "cancel closes the editor without saving", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=MY1")
      render_async(view)

      view |> element("#card-tag-display") |> render_click()
      view |> element("#card-tag-cancel") |> render_click()

      refute has_element?(view, "#card-tag-form")
      assert Repo.get!(Card, card.id).tag == "spec"
    end
  end
end
