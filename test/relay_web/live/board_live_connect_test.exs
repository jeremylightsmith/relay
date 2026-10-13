defmodule RelayWeb.BoardLiveConnectTest do
  @moduledoc """
  RE446 task 4: connect a machine (`/board/:slug?setup=connect`, card mockup "Payoff — first card
  turns violet, Settings → Setup, connect a machine", frame D). A board member runs the same wizard
  for their own machine: a member note, the board-wide steps skipped, `n of 6`, their own key, a
  pull-only onboard and their runner. Mounting never mints; "Mint my key" does.
  """
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo
  alias Relay.Setup
  alias Schemas.ApiKey
  alias Schemas.Card
  alias Schemas.SetupMachine
  alias Schemas.Stage

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The element's own attribute, not its descendants'.
  defp attr(view, selector, name) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> List.first()
  end

  defp marker(view, selector), do: text(view, "#{selector} > .setup-marker-col > .setup-marker")

  # Every step a report moves, in catalog order: a parent with children is walked through them.
  defp walk do
    parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
    for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
  end

  # Finishes every reportable step of `target` (board or machine) before `id`; `nil` finishes all.
  defp advance_to!(target, id) do
    for prior <- Enum.take_while(walk(), &(&1 != id)),
        Setup.reportable_id(Setup.checklist(target)) == prior,
        do: {:ok, _} = Setup.advance(target, prior, :done, %{})

    target
  end

  defp step_dom(id), do: "#setup-step-#{String.replace(id, ".", "-")}"

  # A finished template board owned by Jeremy, with Sam a member signed in.
  setup %{conn: conn} do
    owner = insert(:user, name: "Jeremy")
    {:ok, board} = Boards.create_board(owner, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})
    advance_to!(board, Setup.step_id(:first_claim))

    stage = Repo.one!(from(s in Stage, where: s.board_id == ^board.id, order_by: s.position, limit: 1))
    card = insert(:card, stage: stage, title: "Streak counter")
    ref = Card.format_ref(board.key, card.ref_number)

    {:ok, _} =
      Setup.advance(board, Setup.step_id(:first_claim), :done, %{
        evidence: "#{ref} claimed 14:42 by jl-mbp",
        data: %{
          "card_ref" => ref,
          "card_id" => card.id,
          "runner" => "jl-mbp",
          "machine" => "jl-mbp",
          "verb" => "planning"
        }
      })

    sam = insert(:user, name: "Sam")
    insert(:membership, board: board, user: sam, email: sam.email)

    %{conn: log_in_user(conn, sam), board: board, sam: sam, ref: ref}
  end

  defp connect_url(board), do: ~p"/board/#{board.slug}?setup=connect"

  defp sam_machine(sam), do: Repo.one!(from(m in SetupMachine, where: m.user_id == ^sam.id))

  defp mint!(view) do
    view |> element("#setup-mint-key") |> render_click()
    view
  end

  # Scenario 8
  test "mounting shows the connect panel with the board-wide steps skipped and mints nothing",
       %{conn: conn, board: board, sam: sam, ref: ref} do
    {:ok, view, _html} = live(conn, connect_url(board))

    panel = text(view, "#setup-panel")
    assert panel =~ "Connect a machine to Streaks"
    assert panel =~ "2 of 6"

    assert text(view, "#setup-member-note") ==
             "SA Signed in as Sam, a member of Streaks. The key this mints is Sam's, and so is the runner. " <>
               "Not a member? Ask an owner to add you in Members first."

    claimed_on =
      Calendar.strftime(
        Enum.find(Setup.checklist(board).steps, &(&1.id == Setup.step_id(:first_claim))).completed_at,
        "%-d %b"
      )

    [created | _] = Setup.steps()

    for {id, evidence} <- [
          {created.id, "already set up"},
          {Setup.step_id(:llm), "board-wide · already chosen"},
          {Setup.step_id(:first_claim), "board-wide · #{ref} claimed #{claimed_on}"}
        ] do
      assert attr(view, step_dom(id), "data-status") == "skipped"
      assert marker(view, step_dom(id)) == "–"
      assert text(view, "#{step_dom(id)} .setup-evidence") == evidence
    end

    assert text(view, "#setup-mint-key") == "Mint my key"
    assert Repo.all(from(m in SetupMachine, where: m.user_id == ^sam.id)) == []
  end

  test "a skipped connect row's marker and evidence are muted, with no ✓", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, connect_url(board))
    [created | _] = Setup.steps()

    marker_style =
      view
      |> element("#{step_dom(created.id)} > .setup-marker-col > .setup-marker")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("style")
      |> List.first()

    assert marker_style =~ "width:24px;height:24px;border-radius:50%"
    assert marker_style =~ "border:1.5px dashed var(--color-base-300)"
    assert marker_style =~ "color:color-mix(in oklab, var(--color-base-content) 40%, transparent)"

    evidence_style = attr(view, "#{step_dom(created.id)} .setup-evidence", "style")
    assert evidence_style =~ "font-size:10.5px"
    assert evidence_style =~ "color:color-mix(in oklab, var(--color-base-content) 55%, transparent)"
    refute text(view, "#{step_dom(created.id)} .setup-evidence") =~ "✓"
  end

  # Scenario 9
  test "Mint my key connects Sam's machine with Sam's key", %{conn: conn, board: board, sam: sam} do
    {:ok, view, _html} = live(conn, connect_url(board))
    mint!(view)

    assert text(view, "#setup-key-box") =~ "export RELAY_API_KEY=relay_"
    machine = sam_machine(sam)
    assert machine.user_id == sam.id
    assert %ApiKey{created_by_id: created_by_id} = Repo.get!(ApiKey, machine.api_key_id)
    assert created_by_id == sam.id
  end

  test "Mint a new key on a saved connect re-mints the machine's key", %{conn: conn, board: board, sam: sam} do
    {:ok, view, _html} = live(conn, connect_url(board))
    mint!(view)
    first_key_id = sam_machine(sam).api_key_id

    {:ok, reloaded, _html} = live(conn, connect_url(board))
    refute has_element?(reloaded, "#setup-key-box")
    mint!(reloaded)

    assert text(reloaded, "#setup-key-box") =~ "export RELAY_API_KEY=relay_"
    assert Repo.aggregate(from(m in SetupMachine, where: m.user_id == ^sam.id), :count) == 1
    assert sam_machine(sam).api_key_id != first_key_id
  end

  # Scenario 10
  test "a report on Sam's machine re-renders the connect panel live", %{conn: conn, board: board, sam: sam} do
    {:ok, view, _html} = live(conn, connect_url(board))
    mint!(view)

    {:ok, _} = Setup.advance(sam_machine(sam), Setup.step_id(:key), :done, %{})

    panel = text(view, "#setup-panel")
    assert panel =~ "3 of 6"
    assert attr(view, "#setup-panel progress", "value") == "50"

    install = text(view, step_dom(Setup.step_id(:install)))
    assert install =~ "Install on this machine"
    assert install =~ Setup.install_command(RelayWeb.Endpoint.url(), board.slug)

    onboard = text(view, step_dom(Setup.step_id(:onboard)))
    assert onboard =~ "Onboard, pull only"
    assert text(view, "#{step_dom(Setup.step_id(:onboard))} .setup-actor-tag") == "AI · terminal"

    assert onboard =~
             "Pulls the board's flows and checks the Relay files are already on origin/main. No interview, no customizing."

    refute has_element?(view, step_dom(Setup.step_id(:interview)))
  end

  # Scenario 11
  test "a finished connect shows You're set up; Close setup leaves connect mode", %{conn: conn, board: board, sam: sam} do
    {:ok, view, _html} = live(conn, connect_url(board))
    mint!(view)
    advance_to!(sam_machine(sam), nil)

    assert text(view, "#setup-done") =~ "You're set up."
    assert has_element?(view, "#setup-close")
    assert has_element?(view, "#setup-connect-another")

    view |> element("#setup-close") |> render_click()

    assert_patch(view, "/board/#{board.slug}")
    refute has_element?(view, "#setup-panel", "Connect a machine to")
  end

  test "Connect another machine on a finished connect starts a fresh, unsaved one",
       %{conn: conn, board: board, sam: sam} do
    {:ok, view, _html} = live(conn, connect_url(board))
    mint!(view)
    advance_to!(sam_machine(sam), nil)

    view |> element("#setup-connect-another") |> render_click()

    assert text(view, "#setup-panel") =~ "2 of 6"
    assert text(view, "#setup-mint-key") == "Mint my key"
  end

  # Scenario 12
  test "connect mode shows even when the board's setup is closed, and leaving it shows no setup",
       %{conn: conn, board: board} do
    {:ok, _} = Setup.close(board)

    {:ok, view, _html} = live(conn, connect_url(board))
    assert text(view, "#setup-panel") =~ "Connect a machine to Streaks"
    refute has_element?(view, "#setup-chip")
    refute has_element?(view, "#setup-callout")

    render_patch(view, ~p"/board/#{board.slug}")

    refute has_element?(view, "#setup-panel")
    refute has_element?(view, "#setup-chip")
  end
end
