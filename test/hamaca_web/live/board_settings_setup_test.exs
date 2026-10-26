defmodule HamacaWeb.BoardSettingsSetupTest do
  @moduledoc """
  RE446 task 4: Board settings → Setup (card mockup "Payoff — first card turns violet, Settings →
  Setup, connect a machine", frame C) — the finished line, Reopen setup wizard, Connect a machine,
  the onboarding answers and the machines table. Boards without a checklist have no Setup section.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hamaca.ApiKeys
  alias Hamaca.Boards
  alias Hamaca.Repo
  alias Hamaca.Setup
  alias HamacaWeb.BoardSettingsLive
  alias Schemas.BoardSetupStep
  alias Schemas.Card
  alias Schemas.Stage

  setup :register_and_log_in_user

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

  defp create!(user) do
    {:ok, board} = Boards.create_board(user, %{name: "Streaks", slug: unique_slug("streaks"), template: "bare-minimum"})
    board
  end

  # Every step a report moves, in catalog order: a parent with children is walked through them.
  defp walk do
    parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
    for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
  end

  # Finishes every reportable step of `target` (board or machine) before `id`.
  defp advance_to!(target, id) do
    for prior <- Enum.take_while(walk(), &(&1 != id)),
        Setup.reportable_id(Setup.checklist(target)) == prior,
        do: {:ok, _} = Setup.advance(target, prior, :done, %{})

    target
  end

  defp set_completed_at!(board, step_id, at) do
    {1, _} =
      Repo.update_all(
        from(s in BoardSetupStep, where: s.board_id == ^board.id and is_nil(s.machine_id) and s.step == ^step_id),
        set: [completed_at: at]
      )
  end

  # A bare-minimum board whose step 2 picked Claude Code (minting the owner's key), with step 6
  # ticked by a heartbeat from runner "jl-mbp" (claude signed in) and step 7 by a claim.
  defp finished!(user) do
    board = create!(user)
    {:ok, %{token: token}} = Setup.choose_llm(board, user, "claude-code")
    {:ok, key} = ApiKeys.authenticate_key(token)
    advance_to!(board, Setup.step_id(:runner))

    harnesses = [%{"key" => "claude-code", "installed" => true, "signed_in" => true}]
    runner = insert(:runner, board: board, name: "jl-mbp", host: "jl-mbp", harnesses: harnesses)
    :ok = Setup.observe_heartbeat(key, runner)

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

    %{board: board, key: key}
  end

  # The text of each element `selector` matches inside `within`.
  defp texts(view, within, selector) do
    view
    |> element(within)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp setup_url(board), do: ~p"/board/#{board.slug}/settings?section=setup"

  # Scenario 1
  test "a board with no checklist has no Setup tab or rail link, and ?section=setup is General",
       %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")
    refute has_element?(view, "#settings-tab-setup")
    refute has_element?(view, "#settings-nav-setup")

    {:ok, view, _html} = live(conn, setup_url(board))
    assert has_element?(view, "#general-pane")
    refute has_element?(view, "#setup-pane")
  end

  # Scenario 2
  test "a finished board shows the finished line, Reopen and Connect a machine", %{conn: conn, user: user} do
    %{board: board} = finished!(user)
    [created | _] = Setup.steps()
    set_completed_at!(board, created.id, ~U[2026-10-12 14:02:00Z])
    set_completed_at!(board, Setup.step_id(:first_claim), ~U[2026-10-12 14:42:00Z])

    {:ok, view, _html} = live(conn, setup_url(board))

    assert has_element?(view, "#setup-pane h2", "Setup")
    assert text(view, "#setup-finished-line") == "Finished 12 Oct, 14:42 · 7 of 7 · 40 min"

    assert text(view, "#setup-reopen") == "Reopen setup wizard"
    assert attr(view, "#setup-reopen", "class") == "btn btn-sm"

    assert text(view, "#setup-connect") == "➕ Connect a machine"
    assert attr(view, "#setup-connect", "class") == "btn btn-sm btn-primary"
    assert attr(view, "#setup-connect", "href") == "/board/#{board.slug}?setup=connect"
  end

  # Scenario 3
  test "an unfinished board reads In progress with its position", %{conn: conn, user: user} do
    board = user |> create!() |> advance_to!(Setup.step_id(:install))

    {:ok, view, _html} = live(conn, setup_url(board))

    assert text(view, "#setup-finished-line") == "In progress · 4 of 7"
  end

  describe "project answers" do
    # Scenario 4
    test "shows the 5.3 answers with their labels, caption and footnote", %{conn: conn, user: user} do
      board = user |> create!() |> advance_to!(Setup.step_id(:interview))
      answers = %{"done" => "PR merged", "never_touch" => "priv/repo/migrations"}
      {:ok, _} = Setup.advance(board, Setup.step_id(:interview), :done, %{data: %{"answers" => answers}})

      {:ok, view, _html} = live(conn, setup_url(board))

      block = text(view, "#setup-project-answers")
      assert block =~ "from onboarding · also in .relay/project.md"
      assert texts(view, "#setup-project-answers-done", "span") == ["Done means", "PR merged"]
      assert texts(view, "#setup-project-answers-never_touch", "span") == ["Never touch", "priv/repo/migrations"]

      assert text(view, "#setup-project-answers-footnote") ==
               "A copy for reference. To change one, edit .relay/project.md in the repo; the next onboard run reports it here."
    end

    # Scenario 4, no answers
    test "with no answers says onboarding records them in 5.3", %{conn: conn, user: user} do
      board = create!(user)

      {:ok, view, _html} = live(conn, setup_url(board))

      assert text(view, "#setup-project-answers") =~ "No answers yet. Onboarding records them in step 5.3."
    end
  end

  # Scenario 5
  test "the machines table lists the board's own machine and a member's", %{conn: conn, user: user} do
    %{board: board, key: key} = finished!(user)
    sam = insert(:user, name: "Sam")
    insert(:membership, board: board, user: sam, email: sam.email)
    {:ok, %{machine: machine, token: sam_token}} = Setup.connect_machine(board, sam)
    advance_to!(machine, Setup.step_id(:install))
    {:ok, sam_key} = ApiKeys.authenticate_key(sam_token)

    {:ok, view, _html} = live(conn, setup_url(board))

    assert has_element?(view, "table#setup-machines.table.table-sm")

    assert texts(view, "#setup-machines", "thead th") == ["Machine", "Person", "Key", "Harnesses", "Setup"]

    board_row = text(view, "#setup-machines-board")
    assert board_row =~ "jl-mbp"
    assert board_row =~ user.name
    assert board_row =~ "…#{key.last_four}"
    assert board_row =~ "claude ✓"
    assert has_element?(view, "#setup-machines-board .badge.badge-sm.badge-success.badge-soft", "✓ 7/7")

    assert texts(view, "#setup-machines", "#setup-machines-#{machine.id} td") == [
             "—",
             "Sam",
             "…#{sam_key.last_four}",
             "—",
             "4 install"
           ]

    assert has_element?(view, "#setup-machines-#{machine.id} .badge.badge-sm.badge-primary.badge-soft", "4 install")
  end

  # Scenario 6
  test "Reopen setup wizard reopens a closed setup and goes to the board", %{conn: conn, user: user} do
    %{board: board} = finished!(user)
    {:ok, _} = Setup.close(board)

    {:ok, view, _html} = live(conn, setup_url(board))
    view |> element("#setup-reopen") |> render_click()

    assert_redirect(view, "/board/#{board.slug}")
    assert Setup.checklist(board).closed? == false

    {:ok, board_view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(board_view, "#setup-panel")

    for %{parent: nil, id: id} <- Setup.steps() do
      assert has_element?(board_view, ~s(#setup-step-#{id}[data-status="done"]))
    end
  end

  # Scenario 7
  test "the section is labelled Setup in the rail", %{conn: conn, user: user} do
    board = create!(user)

    assert BoardSettingsLive.section_label(:setup) == "Setup"

    {:ok, view, _html} = live(conn, setup_url(board))
    assert text(view, "#settings-nav-setup") == BoardSettingsLive.section_label(:setup)
    assert text(view, "#settings-tab-setup") == BoardSettingsLive.section_label(:setup)
  end
end
