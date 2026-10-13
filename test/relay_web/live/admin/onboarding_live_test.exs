defmodule RelayWeb.Admin.OnboardingLiveTest do
  @moduledoc "RE448: the superadmin `/admin/onboarding` per-board guided-setup progress page."
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Boards.Templates
  alias Relay.Repo
  alias Relay.Setup
  alias Schemas.BoardSetupStep
  alias Schemas.Scope

  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()))
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp create!(name, owner \\ nil) do
    owner = owner || insert(:user)
    {:ok, board} = Boards.create_board(owner, %{name: name, slug: unique_slug("onb"), template: "bare-minimum"})
    board
  end

  defp set_step!(board, id, fields),
    do: Repo.update_all(from(s in BoardSetupStep, where: s.board_id == ^board.id and s.step == ^id), set: fields)

  defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  # Every step a report moves, in order: step 5 is walked through its sub-steps, never directly.
  @walk ~w(2 3 4 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 6 7)

  # Finishes every reportable step before top-level step `id`.
  defp advance_to!(board, id) do
    first = if id == "5", do: "5.1", else: id
    for prior <- Enum.take_while(@walk, &(&1 != first)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    board
  end

  defp stuck!(name), do: name |> create!() |> advance_to!("3") |> tap(&set_step!(&1, "3", reached_at: ago(3 * 3600)))

  defp done!(name) do
    board = advance_to!(create!(name), "7")
    {:ok, _} = Setup.advance(board, "7", :done, %{})
    board
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp squish(string), do: string |> String.split() |> Enum.join(" ")

  defp text_of(view, selector), do: view |> text(selector) |> squish()

  # Scenario 3
  test "with no guided-setup boards shows the empty state, no table and zero counts", %{conn: conn} do
    insert(:board)

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, "#onboarding-empty", "No boards have been created with guided setup yet.")
    refute has_element?(view, "#onboarding-table")
    assert text_of(view, "#onboarding-filter-all") == "all 0"
  end

  # Scenario 4
  test "lists a guided-setup board with its columns and skips plain boards", %{conn: conn} do
    owner = insert(:user, email: "ana@pantry.io")
    pantry = create!("Pantry", owner)
    insert(:board, name: "Legacy")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, ~s(#admin-back[href="/admin"]))
    assert has_element?(view, "h1", "Onboarding")
    assert text_of(view, "#onboarding-loaded") =~ ~r/loaded \d\d:\d\d/

    headers =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#onboarding-table thead th")
      |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))

    assert headers == ["Board", "Owner", "Template", "LLM", "Current step", "On step", "Total", "Last evidence / error"]

    row = "#onboarding-row-#{pantry.id}"
    assert has_element?(view, row, "Pantry")
    assert has_element?(view, row, "ana@pantry.io")
    assert has_element?(view, row, Templates.get("bare-minimum").name)
    assert text_of(view, "#{row}-step") == "2 · Pick your default LLM"
    assert has_element?(view, "#{row}-step.badge-soft.badge-primary.whitespace-nowrap")
    # Full-width layout (smoke RE448): the default max-w-2xl column squeezed the 8-column table.
    refute has_element?(view, ".max-w-2xl #onboarding-table")
    refute has_element?(view, "#onboarding-table tbody tr", "Legacy")
  end

  # Scenario 5
  test "flags a board on the same step for over two hours as stuck", %{conn: conn} do
    a = advance_to!(create!("A"), "3")
    set_step!(a, "3", reached_at: ago(3 * 3600 + 12 * 60))
    b = create!("B")
    set_step!(b, "2", reached_at: ago(6 * 60))

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, "#onboarding-row-#{a.id}-stuck.badge.badge-warning", "stuck")
    assert text_of(view, "#onboarding-row-#{a.id}-on-step") == "3h 12m"
    refute has_element?(view, "#onboarding-row-#{b.id}-stuck")
    assert text_of(view, "#onboarding-row-#{b.id}-on-step") == "6m"
  end

  # Scenario 6
  test "a failed step gets an error badge and its error as the last line", %{conn: conn} do
    board = advance_to!(create!("Failing"), "4")
    {:ok, _} = Setup.advance(board, "4", :failed, %{error: "Preflight stopped: python3 isn't on your PATH"})

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, "#onboarding-row-#{board.id}-step.badge-error")
    assert text_of(view, "#onboarding-row-#{board.id}-last") == "✕ Preflight stopped: python3 isn't on your PATH"
  end

  # Scenario 7
  test "a finished board shows step 7 as a success badge and no time on step", %{conn: conn} do
    board = done!("Finished")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert text_of(view, "#onboarding-row-#{board.id}-step") == "7 · First card claimed"
    assert has_element?(view, "#onboarding-row-#{board.id}-step.badge-success")
    assert text_of(view, "#onboarding-row-#{board.id}-on-step") == "—"
  end

  # Scenario 8
  test "filter chips count every state and narrow the loaded rows", %{conn: conn} do
    stuck = stuck!("Stuck")
    going = create!("Going")
    done = done!("Done")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert text_of(view, "#onboarding-filter-all") == "all 3"
    assert text_of(view, "#onboarding-filter-in_progress") == "in progress 1"
    assert text_of(view, "#onboarding-filter-stuck") == "stuck 1"
    assert text_of(view, "#onboarding-filter-done") == "done 1"

    rows = fn -> Enum.filter([stuck, going, done], &has_element?(view, "#onboarding-row-#{&1.id}")) end

    assert has_element?(view, "#onboarding-filter-all.badge-primary:not(.badge-ghost)")
    assert has_element?(view, "#onboarding-filter-stuck.badge-ghost:not(.badge-primary)")

    view |> element("#onboarding-filter-stuck") |> render_click()
    assert rows.() == [stuck]
    assert has_element?(view, "#onboarding-filter-stuck.badge:not(.badge-ghost)")
    assert has_element?(view, "#onboarding-filter-all.badge-ghost")
    assert has_element?(view, "#onboarding-filter-done.badge-ghost")
    assert has_element?(view, "#onboarding-filter-in_progress.badge-ghost")

    view |> element("#onboarding-filter-done") |> render_click()
    assert rows.() == [done]

    view |> element("#onboarding-filter-in_progress") |> render_click()
    assert rows.() == [going]

    view |> element("#onboarding-filter-all") |> render_click()
    assert rows.() == [stuck, going, done]
    assert has_element?(view, "#onboarding-filter-all.badge:not(.badge-ghost)")
  end

  test "an unknown filter leaves the current one in place", %{conn: conn} do
    stuck = stuck!("Stuck")
    going = create!("Going")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")
    view |> element("#onboarding-filter-stuck") |> render_click()
    render_click(view, "filter", %{"filter" => "bogus"})

    assert has_element?(view, "#onboarding-row-#{stuck.id}")
    refute has_element?(view, "#onboarding-row-#{going.id}")
  end

  # Scenario 9
  test "clicking a row patches ?board= and shows its read-only checklist", %{conn: conn} do
    board = advance_to!(create!("Pantry Co"), "5")
    set_step!(board, "5.1", status: :done)

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")
    refute has_element?(view, "#onboarding-detail")

    view |> element("#onboarding-row-#{board.id}") |> render_click()

    assert_patch(view, "/admin/onboarding?board=#{board.slug}")
    assert has_element?(view, "#onboarding-detail", "Pantry Co")
    assert has_element?(view, "#onboarding-detail #onboarding-checklist-step-5-1")
    assert has_element?(view, "#onboarding-detail #onboarding-checklist-step-5-8")
    refute has_element?(view, "#onboarding-detail button")
    refute has_element?(view, "#onboarding-detail input")
    assert text_of(view, "#onboarding-detail-footer") == "stuck = same step > 2h · Relay.Setup.stuck_after/0"
  end

  # Scenario 10
  test "opening ?board= directly selects a stuck board", %{conn: conn} do
    board = stuck!("Stuck")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding?board=#{board.slug}")

    assert has_element?(view, "#onboarding-detail .badge-warning", "stuck")
    assert has_element?(view, "#onboarding-row-#{board.id}.bg-base-200")
  end

  # Scenario 11
  # Smoke: with the 380px detail pane open the table must still fit all eight columns, so
  # the long cells truncate (full text kept in `title`) and tighten while a row is selected.
  test "long cells truncate, and tighten while the detail pane is open", %{conn: conn} do
    owner = insert(:user, email: "a.very.long.owner.address+smoke@example.com")
    board = "Pantry" |> create!(owner) |> advance_to!("7")
    row = "#onboarding-row-#{board.id}"

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, "#{row}-step.max-w-\\[260px\\][title='7 · Watch an agent pick up your first card']")
    assert has_element?(view, "#{row}-step > span.truncate")
    assert has_element?(view, "#{row}-owner.truncate.max-w-\\[200px\\][title='#{owner.email}']")
    assert has_element?(view, "#{row}-last.truncate.max-w-\\[240px\\]")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding?board=#{board.slug}")

    assert has_element?(view, "#{row}-step.max-w-\\[140px\\]")
    assert has_element?(view, "#{row}-owner.max-w-\\[120px\\]")
    assert has_element?(view, "#{row}-last.max-w-\\[110px\\]")
  end

  test "an unknown ?board= renders without a detail pane", %{conn: conn} do
    create!("Pantry")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding?board=does-not-exist")

    assert has_element?(view, "h1", "Onboarding")
    refute has_element?(view, "#onboarding-detail")
  end

  # Scenario 12
  test "links a board name only when the superadmin is a member", %{conn: conn, admin: admin} do
    m = create!("Mine")
    insert(:membership, board: m, user: admin)
    t = create!("Theirs")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")

    assert has_element?(view, ~s(#onboarding-row-#{m.id} a[href="/board/#{m.slug}"]))
    assert has_element?(view, "#onboarding-row-#{t.id}", "Theirs")
    refute has_element?(view, "#onboarding-row-#{t.id} a")
  end

  # Scenario 13
  test "is a snapshot: a later advance does not change the open page", %{conn: conn} do
    board = create!("Pantry")

    {:ok, view, _html} = live(conn, ~p"/admin/onboarding")
    {:ok, _} = Setup.advance(board, "2", :done, %{})
    render(view)

    assert text_of(view, "#onboarding-row-#{board.id}-step") == "2 · Pick your default LLM"
  end
end
