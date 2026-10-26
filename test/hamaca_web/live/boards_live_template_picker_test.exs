defmodule HamacaWeb.BoardsLiveTemplatePickerTest do
  @moduledoc """
  RE442: "New board" on `/boards` opens a template picker instead of creating Hamaca's
  fixed board, and creates a board from whichever template is chosen — RE455: under the board
  name and card key typed at the top of the picker.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Repo
  alias Hamaca.Setup
  alias HamacaWeb.TemplatePickerComponents
  alias Schemas.Board
  alias Schemas.Card

  setup :register_and_log_in_user

  setup %{user: user} do
    _default = Boards.get_or_create_default_board(user)
    :ok
  end

  defp open_picker(conn) do
    {:ok, view, _html} = live(conn, ~p"/boards")
    view |> element("#top-bar-new-board") |> render_click()
    view
  end

  # The template cards; RE447's 4th card (`#template-card-copy`) is a copy option, not a
  # template.
  @template_cards ~s{#template-picker [id^="template-card-"]:not(#template-card-copy)}

  defp card_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@template_cards)
    |> LazyHTML.attribute("id")
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  test "1. the top-bar New board opens the picker on the offered cards, Bare minimum selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards")
    refute has_element?(view, "#template-picker")

    view |> element("#top-bar-new-board") |> render_click()

    assert has_element?(view, "#template-picker")

    assert card_ids(view) == [
             "template-card-bare-minimum",
             "template-card-design-led"
           ]

    assert has_element?(view, "#template-radio-bare-minimum[checked]")
    refute has_element?(view, "#template-radio-design-led[checked]")
    assert has_element?(view, "#template-picker-create .pending-idle", "Create board")
  end

  test "2. the New board tile opens the picker without creating a board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards")
    before = Repo.aggregate(Board, :count)

    view |> element("#new-board-button") |> render_click()

    assert has_element?(view, "#template-picker")
    assert view |> card_ids() |> length() == 2
    assert has_element?(view, "#template-radio-bare-minimum[checked]")
    assert Repo.aggregate(Board, :count) == before
  end

  test "3. selecting a template relabels the button and moves the selected border", %{conn: conn} do
    view = open_picker(conn)

    view |> element("#template-picker-form") |> render_change(%{"template" => "design-led"})

    assert has_element?(view, "#template-picker-create .pending-idle", "Create board")
    assert has_element?(view, "#template-card-design-led.border-primary")
    refute has_element?(view, "#template-card-bare-minimum.border-primary")
    assert has_element?(view, "#template-radio-design-led[checked]")
  end

  test "4. Three-brain is hidden for now: no card, and ?template=three-brain leaves the picker closed",
       %{conn: conn} do
    view = open_picker(conn)
    refute has_element?(view, "#template-card-three-brain")
    refute has_element?(view, ~s([id^="template-warning-"]))

    {:ok, view, _html} = live(conn, ~p"/boards?template=three-brain")
    refute has_element?(view, "#template-picker")
  end

  test "5. (RE455 14) submitting creates the named, keyed board from the template and opens it (RE443: the setup wizard lives there)",
       %{conn: conn} do
    view = open_picker(conn)

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#template-picker-form")
             |> render_submit(%{"template" => "design-led", "name" => "Acme Checkout", "key" => "AC"})

    assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)

    board = Repo.get_by!(Board, slug: slug)
    assert board.name == "Acme Checkout"
    assert board.key == "AC"

    main_stages =
      board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.name)

    assert main_stages == ["Backlog", "Next up", "Design", "Plan", "Code", "Review", "Deploy", "Done"]
  end

  test "6. Cancel and ✕ both close the picker", %{conn: conn} do
    view = open_picker(conn)

    view |> element("#template-picker-cancel") |> render_click()
    refute has_element?(view, "#template-picker")

    view |> element("#top-bar-new-board") |> render_click()
    assert has_element?(view, "#template-picker")

    view |> element("#template-picker-close") |> render_click()
    refute has_element?(view, "#template-picker")
  end

  test "7. ?template=<slug> opens the picker with that template selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards?template=design-led")

    assert has_element?(view, "#template-picker")
    assert has_element?(view, "#template-radio-design-led[checked]")
    refute has_element?(view, "#template-radio-bare-minimum[checked]")
    assert has_element?(view, "#template-picker-create .pending-idle", "Create board")
  end

  test "8. an unknown ?template= leaves the picker closed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards?template=nope")

    refute has_element?(view, "#template-picker")
  end

  test "9. the strips show main stage names only, no WIP, and mark Review sub-lanes", %{conn: conn} do
    view = open_picker(conn)
    # The template cards only: RE447's copy card names "WIP limits" in its plain-copy note.
    picker_text = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(@template_cards) |> LazyHTML.text()

    refute picker_text =~ ~r/wip/i
    refute picker_text =~ ~r/default board/i

    for template <- Boards.offered_templates() do
      names = texts(view, "#template-stages-#{template.slug} > span:not(.template-arrow)")
      assert names == Enum.map(template.stages, & &1.name)
      refute Enum.any?(names, &String.contains?(&1, ":"))
    end

    assert has_element?(view, ~s(.template-review-marker[title="has a Review sub-lane"]))
  end

  test "10. the facts row counts stages, flows and skills", %{conn: conn} do
    view = open_picker(conn)

    assert [stages, flows, skills] = texts(view, "#template-facts-bare-minimum > span")
    assert stages =~ ~r/^\d+ stages$/
    assert flows =~ ~r/^\d+ flows$/
    assert skills =~ ~r/^\d+ skills$/
  end

  test "11. with no seeded examples, no card links to a public example (RE444)", %{conn: conn} do
    view = open_picker(conn)

    assert count(view, ~s([id^="template-example-"])) == 0
  end

  test "12. each template card links to its seeded public example in a new window (RE444)", %{conn: conn} do
    Hamaca.Examples.seed!(insert(:user), [])
    view = open_picker(conn)

    doc = view |> render() |> LazyHTML.from_fragment()
    link = LazyHTML.query(doc, "a#template-example-bare-minimum")

    assert LazyHTML.attribute(link, "href") == ["/examples/bare-minimum"]
    assert LazyHTML.attribute(link, "target") == ["_blank"]
    assert LazyHTML.attribute(link, "rel") == ["noopener"]
    assert LazyHTML.text(link) =~ "See the public example: Streaks (bare-minimum)"
    assert link |> LazyHTML.query(".hero-arrow-top-right-on-square") |> Enum.count() == 1
    assert link |> LazyHTML.query(".sr-only") |> LazyHTML.text() |> String.trim() == "(opens in a new window)"

    assert has_element?(view, "#template-example-design-led")
  end

  describe "RE455: board name + card key up front" do
    defp change(view, params), do: view |> element("#template-picker-form") |> render_change(params)

    defp identity_text(view) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#template-picker-identity") |> LazyHTML.text()
    end

    test "9. the picker opens with an empty name and key, Create disabled, and no Untitled board", %{conn: conn} do
      view = open_picker(conn)

      assert has_element?(view, ~s(#template-picker-name[value=""]))
      assert has_element?(view, ~s(#template-picker-key[value=""]))
      assert has_element?(view, "#template-picker-create[disabled]")
      refute render(view) =~ "Untitled board"
    end

    test "10. the key follows the name until the user edits it", %{conn: conn} do
      view = open_picker(conn)

      change(view, %{"template" => "bare-minimum", "name" => "Zeta Rollout", "key" => "", "_target" => ["name"]})
      assert has_element?(view, ~s(#template-picker-key[value="ZE"]))

      change(view, %{"name" => "Zeta Rollout", "key" => "QX", "_target" => ["key"]})
      change(view, %{"name" => "Alpha", "key" => "QX", "_target" => ["name"]})
      assert has_element?(view, ~s(#template-picker-key[value="QX"]))
      assert has_element?(view, ~s(#template-picker-name[value="Alpha"]))
    end

    test "11. clearing the key does not turn derivation back on", %{conn: conn} do
      view = open_picker(conn)

      change(view, %{"name" => "Zeta", "key" => "ZE", "_target" => ["key"]})
      change(view, %{"name" => "Zeta", "key" => "", "_target" => ["key"]})
      change(view, %{"name" => "Bravo", "key" => "", "_target" => ["name"]})

      assert has_element?(view, ~s(#template-picker-key[value=""]))
      assert has_element?(view, "#template-picker-key-hint", "Needs 2 letters")
    end

    test "12. the server sanitizes a typed key to its letters, upper-cased", %{conn: conn} do
      view = open_picker(conn)

      change(view, %{"name" => "", "key" => "a1c", "_target" => ["key"]})

      assert has_element?(view, ~s(#template-picker-key[value="AC"]))
    end

    test "13. a name with one letter derives a one-letter key, never RL", %{conn: conn} do
      view = open_picker(conn)

      change(view, %{"name" => "A1", "key" => "", "_target" => ["name"]})

      assert has_element?(view, ~s(#template-picker-key[value="A"]))
      assert has_element?(view, "#template-picker-key-hint", "Needs 2 letters")
      assert has_element?(view, "#template-picker-create[disabled]")
      refute has_element?(view, ~s(#template-picker-key[value="RL"]))
      refute identity_text(view) =~ "RL"
    end

    test "16. a key the server rejects keeps the picker open with the error inline", %{conn: conn, user: user} do
      view = open_picker(conn)
      before = length(Boards.list_boards(user))

      view
      |> element("#template-picker-form")
      |> render_submit(%{"template" => "bare-minimum", "name" => "Acme", "key" => "A"})

      assert length(Boards.list_boards(user)) == before
      assert has_element?(view, "#template-picker")
      assert has_element?(view, "#template-picker-key-hint", "must be exactly 2 letters")
      assert has_element?(view, ~s(#template-picker-name[value="Acme"]))
    end

    # Scenario 16 names "can't be blank", but `Schemas.Board.changeset/2` casts with
    # `empty_values: []`, so a trimmed-blank name fails its length rule instead — the message
    # Board settings shows for the same input. The picker shows whatever the changeset says.
    test "16b. a blank name the server rejects shows its message under the name and keeps the view alive", %{
      conn: conn,
      user: user
    } do
      view = open_picker(conn)
      before = length(Boards.list_boards(user))

      view
      |> element("#template-picker-form")
      |> render_submit(%{"template" => "bare-minimum", "name" => "   ", "key" => "AC"})

      assert length(Boards.list_boards(user)) == before
      assert texts(view, "#template-picker-name-hint") == ["should be at least 1 character(s)"]
      assert has_element?(view, "#template-picker-name.input-error")
      assert render(view) =~ "template-picker"
    end

    test "17. Cancel resets the name and key for the next open", %{conn: conn} do
      view = open_picker(conn)
      change(view, %{"name" => "Acme Checkout", "key" => "AC", "_target" => ["key"]})
      assert has_element?(view, ~s(#template-picker-key[value="AC"]))

      view |> element("#template-picker-cancel") |> render_click()
      view |> element("#top-bar-new-board") |> render_click()

      assert has_element?(view, ~s(#template-picker-name[value=""]))
      assert has_element?(view, ~s(#template-picker-key[value=""]))
      assert has_element?(view, "#template-picker-create[disabled]")
    end
  end

  describe "RE447: the 4th option, copy from a board I have access to" do
    setup %{user: user} do
      {:ok, relay} = Boards.create_board(user, %{name: "Hamaca", slug: unique_slug("relay")})
      {:ok, acme} = Boards.create_board(user, %{name: "Acme web", slug: unique_slug("acme-web")})
      {:ok, secret} = Boards.create_board(insert(:user), %{name: "Secret", slug: unique_slug("secret")})
      %{relay: relay, acme: acme, secret: secret}
    end

    defp select_copy(view, params \\ %{}) do
      view
      |> element("#template-picker-form")
      |> render_change(Map.merge(%{"template" => TemplatePickerComponents.copy_option()}, params))
    end

    test "7. selecting the copy card lists only the boards the user is a member of", %{
      conn: conn,
      relay: relay,
      acme: acme,
      secret: secret
    } do
      view = open_picker(conn)
      select_copy(view)

      assert has_element?(view, "#copy-source-#{relay.slug}")
      assert has_element?(view, "#copy-source-#{acme.slug}")
      refute has_element?(view, "#copy-source-#{secret.slug}")

      for template <- Boards.offered_templates() do
        assert has_element?(view, "#template-card-#{template.slug}")
      end
    end

    test "8. the search narrows the list and choosing a source relabels the button", %{
      conn: conn,
      relay: relay,
      acme: acme
    } do
      view = open_picker(conn)
      select_copy(view)

      select_copy(view, %{"copy_query" => "acme"})
      assert has_element?(view, "#copy-source-#{acme.slug}")
      refute has_element?(view, "#copy-source-#{relay.slug}")

      select_copy(view, %{"copy_from" => acme.slug})
      assert has_element?(view, "#template-picker-create .pending-idle", "Copy Acme web")
    end

    test "9. a default board's flows name .claude/agents files, so the picker warns with +N more", %{
      conn: conn,
      user: user,
      relay: relay
    } do
      view = open_picker(conn)
      select_copy(view, %{"copy_from" => relay.slug})

      files = Enum.find(Boards.copy_sources(user), &(&1.slug == relay.slug)).files
      assert length(files) > 5

      assert has_element?(view, "#template-copy-warning")
      [names] = texts(view, "#template-copy-warning-files")
      assert String.ends_with?(names, "+#{length(files) - 5} more")
    end

    test "10. (RE455 15) submitting the copy creates a plain copy of Hamaca under the typed name and key", %{
      conn: conn,
      user: user,
      relay: relay
    } do
      view = open_picker(conn)
      select_copy(view, %{"copy_from" => relay.slug})

      # Nothing is pre-filled from the copy source.
      assert has_element?(view, ~s(#template-picker-name[value=""]))
      assert has_element?(view, ~s(#template-picker-key[value=""]))

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#template-picker-form")
               |> render_submit(%{
                 "template" => TemplatePickerComponents.copy_option(),
                 "copy_from" => relay.slug,
                 "name" => "Copy Test",
                 "key" => "CT"
               })

      assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)
      copy = Boards.get_board(user, slug)
      assert copy.name == "Copy Test"
      assert copy.key == "CT"

      main_names = fn board ->
        board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.name)
      end

      assert main_names.(copy) == main_names.(relay)
      assert Repo.aggregate(from(c in Card, where: c.board_id == ^copy.id), :count) == 0

      step_one = Enum.find(Setup.checklist(copy).steps, &(&1.id == "1"))
      assert step_one.evidence == "copied from Hamaca"
    end

    test "11. a board the user isn't in gets the same refusal as an unknown board", %{
      conn: conn,
      user: user,
      secret: secret
    } do
      view = open_picker(conn)
      select_copy(view)
      before = length(Boards.list_boards(user))

      for slug <- [secret.slug, "no-such-board"] do
        html =
          view
          |> element("#template-picker-form")
          |> render_submit(%{"template" => TemplatePickerComponents.copy_option(), "copy_from" => slug})

        assert html =~ "That board isn&#39;t available to copy. Pick another."
        assert has_element?(view, "#template-picker")
        assert length(Boards.list_boards(user)) == before
      end
    end
  end

  # RE469 — a Free owner at the limit (the setup's default board is their one board): the footer
  # sells instead of creating, and the server refuses a create that bypasses it.
  describe "at the Free limit" do
    setup do
      Process.put(:billing_enabled, true)
      %{today: Date.utc_today()}
    end

    defp fill_identity(view) do
      view
      |> element("#template-picker-form")
      |> render_change(%{"template" => "bare-minimum", "name" => "Second", "key" => "SE"})
    end

    test "6. the footer becomes the upgrade panel", %{conn: conn} do
      view = open_picker(conn)
      fill_identity(view)

      assert has_element?(view, "#template-picker-upgrade", "Free includes one board.")
      assert view |> element("#template-picker-upgrade-name") |> render() =~ ">Second</b>"
      assert view |> element("#template-picker-upgrade-source") |> render() =~ ">Bare minimum</b>"
      assert has_element?(view, "#template-picker-cancel")
      assert has_element?(view, "#template-picker-upgrade-create", "Upgrade and create →")
      refute has_element?(view, "#template-picker-create")
      refute has_element?(view, "#template-picker-upgrade-link")
    end

    test "7. a create that bypasses the footer is refused and inserts nothing", %{conn: conn, user: user} do
      view = open_picker(conn)

      html =
        view
        |> element("#template-picker-form")
        |> render_submit(%{"template" => "bare-minimum", "name" => "Second", "key" => "SE"})

      assert html =~ "Free includes one board. Upgrade for unlimited boards."
      assert has_element?(view, "#template-picker")
      assert length(Boards.list_boards(user)) == 1
    end

    test "8. a Free owner whose only board is archived can create", %{conn: conn, user: user} do
      user |> Boards.get_or_create_default_board() |> Boards.archive_board()
      view = open_picker(conn)
      fill_identity(view)

      assert has_element?(view, "#template-picker-create")
      refute has_element?(view, "#template-picker-upgrade")
      assert_creates(view)
    end

    test "8. an active owner with 3 boards can create", %{conn: conn, user: user, today: today} do
      {:ok, _} = Boards.create_board(user, %{name: "Two", key: "TW", slug: unique_slug("two")})
      {:ok, _} = Boards.create_board(user, %{name: "Three", key: "TH", slug: unique_slug("three")})
      insert(:billing_account, user: user, paid_through: Date.add(today, 30), billing_day: today.day)
      view = open_picker(conn)
      fill_identity(view)

      assert has_element?(view, "#template-picker-create")
      assert_creates(view)
    end

    defp assert_creates(view) do
      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#template-picker-form")
               |> render_submit(%{"template" => "bare-minimum", "name" => "Second", "key" => "SE"})

      assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)
      assert Repo.get_by!(Board, slug: slug).name == "Second"
    end
  end
end
