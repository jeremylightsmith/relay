defmodule RelayWeb.BoardsLiveTemplatePickerTest do
  @moduledoc """
  RE442: "New board" on `/boards` opens a three-template picker instead of creating Relay's
  fixed board, and creates "Untitled board" from whichever template is chosen.
  """
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo
  alias Relay.Setup
  alias RelayWeb.TemplatePickerComponents
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

  # The three template cards; RE447's 4th card (`#template-card-copy`) is a copy option, not a
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

  test "1. the top-bar New board opens the picker on three cards, Bare minimum selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards")
    refute has_element?(view, "#template-picker")

    view |> element("#top-bar-new-board") |> render_click()

    assert has_element?(view, "#template-picker")

    assert card_ids(view) == [
             "template-card-bare-minimum",
             "template-card-design-led",
             "template-card-three-brain"
           ]

    assert has_element?(view, "#template-radio-bare-minimum[checked]")
    refute has_element?(view, "#template-radio-design-led[checked]")
    assert has_element?(view, "#template-picker-create", "Create board from Bare minimum")
  end

  test "2. the New board tile opens the picker without creating a board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boards")
    before = Repo.aggregate(Board, :count)

    view |> element("#new-board-button") |> render_click()

    assert has_element?(view, "#template-picker")
    assert view |> card_ids() |> length() == 3
    assert has_element?(view, "#template-radio-bare-minimum[checked]")
    assert Repo.aggregate(Board, :count) == before
  end

  test "3. selecting a template relabels the button and moves the selected border", %{conn: conn} do
    view = open_picker(conn)

    view |> element("#template-picker-form") |> render_change(%{"template" => "three-brain"})

    assert has_element?(view, "#template-picker-create", "Create board from Three-brain")
    assert has_element?(view, "#template-card-three-brain.border-primary")
    refute has_element?(view, "#template-card-bare-minimum.border-primary")
    assert has_element?(view, "#template-radio-three-brain[checked]")
  end

  test "4. only Three-brain carries a warning", %{conn: conn} do
    view = open_picker(conn)

    assert has_element?(
             view,
             "#template-warning-three-brain",
             "Needs runners signed in to Claude Code, Codex and Gemini CLI"
           )

    refute has_element?(view, "#template-warning-bare-minimum")
    refute has_element?(view, "#template-warning-design-led")
  end

  test "5. submitting creates Untitled board from the template and opens the board (RE443: the setup wizard lives there)",
       %{conn: conn} do
    view = open_picker(conn)

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#template-picker-form") |> render_submit(%{"template" => "design-led"})

    assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)

    board = Repo.get_by!(Board, slug: slug)
    assert board.name == "Untitled board"

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
    assert has_element?(view, "#template-picker-create", "Create board from Design-led")
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

    for template <- Boards.templates() do
      names = texts(view, "#template-stages-#{template.slug} > span:not(.template-arrow)")
      assert names == Enum.map(template.stages, & &1.name)
      refute Enum.any?(names, &String.contains?(&1, ":"))
    end

    assert count(view, "#template-stages-design-led .template-review-marker") == 2
    assert count(view, "#template-stages-three-brain .template-review-marker") == 1
    assert count(view, "#template-stages-bare-minimum .template-review-marker") == 0

    assert has_element?(view, ~s(#template-stages-design-led .template-review-marker[title="has a Review sub-lane"]))
  end

  test "10. the facts row counts stages, flows and skills", %{conn: conn} do
    view = open_picker(conn)

    assert texts(view, "#template-facts-bare-minimum > span") == ["6 stages", "2 flows", "0 skills"]
    assert texts(view, "#template-facts-design-led > span") == ["8 stages", "3 flows", "0 skills"]
    assert texts(view, "#template-facts-three-brain > span") == ["6 stages", "2 flows", "0 skills"]
  end

  test "11. with no seeded examples, no card links to a public example (RE444)", %{conn: conn} do
    view = open_picker(conn)

    assert count(view, ~s([id^="template-example-"])) == 0
  end

  test "12. each template card links to its seeded public example in a new window (RE444)", %{conn: conn} do
    Relay.Examples.seed!(insert(:user), [])
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
    assert has_element?(view, "#template-example-three-brain")
  end

  describe "RE447: the 4th option, copy from a board I have access to" do
    setup %{user: user} do
      {:ok, relay} = Boards.create_board(user, %{name: "Relay", slug: unique_slug("relay")})
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

      for template <- Boards.templates() do
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
      assert has_element?(view, "#template-picker-create", "Copy Acme web's stages and flows")
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

    test "10. submitting the copy creates a plain copy of Relay and opens it", %{
      conn: conn,
      user: user,
      relay: relay
    } do
      view = open_picker(conn)
      select_copy(view, %{"copy_from" => relay.slug})

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#template-picker-form")
               |> render_submit(%{"template" => TemplatePickerComponents.copy_option(), "copy_from" => relay.slug})

      assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)
      copy = Boards.get_board(user, slug)
      assert copy.name == "Untitled board"

      main_names = fn board ->
        board |> Boards.list_stages() |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.map(& &1.name)
      end

      assert main_names.(copy) == main_names.(relay)
      assert Repo.aggregate(from(c in Card, where: c.board_id == ^copy.id), :count) == 0

      step_one = Enum.find(Setup.checklist(copy).steps, &(&1.id == "1"))
      assert step_one.evidence == "copied from Relay"
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
end
