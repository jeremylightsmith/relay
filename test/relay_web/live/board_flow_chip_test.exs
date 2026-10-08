defmodule RelayWeb.BoardFlowChipTest do
  # RE409 — the board's AI chip is the link to the flow that works in the stage; a stage is
  # AI-enabled iff a flow works in it (Relay.Flows.stage_flows/1).
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, board} = Boards.create_board(user, %{name: "Chips"})
    spec = stage_named(board, "Spec")
    next_up = stage_named(board, "Next up")

    {:ok, _design} =
      Boards.create_stage(board, %{name: "Design", category: :planning, type: :planning, before: spec})

    board = Boards.get_board!(user, board.slug)
    design = stage_named(board, "Design")

    insert(:flow,
      board: board,
      key: "design",
      works_in_stage_id: design.id,
      pulls_from_stage_id: next_up.id,
      lands_on_stage_id: spec.id
    )

    %{board: board, design: design}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name and is_nil(&1.parent_id)))

  defp chip_selector(stage), do: "#stage-col-#{stage.position}-ai-listening"

  defp set_flow_enabled(board, key, enabled) do
    board
    |> Relay.Flows.get_flow_with_stages(key)
    |> Ecto.Changeset.change(enabled: enabled)
    |> Repo.update!()
  end

  test "a works-in stage's chip links to its flow; pulls-from and lands-on stages have none",
       %{conn: conn, board: board, design: design} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "a#{chip_selector(design)}[href='/board/#{board.slug}/flows/design']")
    refute has_element?(view, chip_selector(stage_named(board, "Next up")))
    refute has_element?(view, chip_selector(stage_named(board, "Review")))
  end

  test "clicking the chip lands on the flow editor", %{conn: conn, board: board, design: design} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert {:ok, _editor, _html} =
             view
             |> element(chip_selector(design))
             |> render_click()
             |> follow_redirect(conn, ~p"/board/#{board.slug}/flows/design")
  end

  test "an archived board shows an enabled flow's chip as a plain label and hides a disabled one",
       %{conn: conn, board: board} do
    set_flow_enabled(board, "spec", true)
    set_flow_enabled(board, "plan", false)
    {:ok, board} = Boards.archive_board(board)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    spec_chip = chip_selector(stage_named(board, "Spec"))
    assert has_element?(view, "span#{spec_chip}")
    refute has_element?(view, "#{spec_chip}[href]")
    refute has_element?(view, chip_selector(stage_named(board, "Plan")))
  end

  test "the drawer's owner dot is AI for a flow stage and human for a no-flow work stage",
       %{conn: conn, board: board, design: design} do
    deploy = stage_named(board, "Deploy")
    {:ok, ai_card} = Cards.create_card(design, %{title: "Drawn by a flow"})
    {:ok, human_card} = Cards.create_card(deploy, %{title: "No flow here"})

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, ai_card)}")
    render_async(view)
    assert has_element?(view, "#card-drawer-stage-chip.badge-secondary", "Design")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, human_card)}")
    render_async(view)
    assert has_element?(view, "#card-drawer-stage-chip.badge-primary", "Deploy")
  end
end
