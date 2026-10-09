defmodule RelayWeb.BoardLivePausedFlowsTest do
  @moduledoc """
  RE432 — the board shows one amber banner per flow paused by a broken board shape (one summary
  banner for 3+), and the paused flow's column header chip reads "AI paused". Both clear (and
  appear) live on `{:stages_changed, board_id}`.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name and is_nil(&1.parent_id)))

  # An empty stage auto-collapses to its strip (the dot-only chip) — a card keeps the header chip.
  defp expand!(stage) do
    {:ok, _card} = Cards.create_card(stage, %{title: "Keeps #{stage.name} open"})
    stage
  end

  defp chip_selector(stage), do: "#stage-col-#{stage.position}-ai-listening"

  # Deploy pulls from Review (no queue between) — `:upstream_review`, so an enabled deploy flow
  # is paused.
  defp insert_deploy_flow(board, enabled \\ true) do
    insert_flow_working_in(stage_named(board, "Deploy"), key: "deploy", enabled: enabled)
  end

  defp enable_flow!(board, key) do
    {:ok, flow} = board |> Flows.get_flow!(key) |> Flows.enable_flow()
    flow
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp text(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp attr(view, selector, name),
    do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  test "4. an editor sees the deploy banner with Fix in Stages and the AI paused chip", %{
    conn: conn,
    board: board
  } do
    insert_deploy_flow(board)
    deploy = expand!(stage_named(board, "Deploy"))
    [problem] = Flows.shape_problems(board)
    assert problem.flow_key == "deploy"

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#paused-flow-banners #paused-flow-banner-deploy")
    assert text(view, "#paused-flow-banner-deploy") =~ squish(Relay.Markdown.to_plain(problem.why))
    assert attr(view, "#paused-flow-banner-deploy-fix", "href") =~ ~r/#stage-#{deploy.id}-row$/

    assert attr(view, chip_selector(deploy), "data-flow-paused") == "true"
    assert text(view, chip_selector(deploy)) == "AI paused"
  end

  test "4. a healthy flow's chip keeps AI and is not paused", %{conn: conn, board: board} do
    enable_flow!(board, "code")
    insert_deploy_flow(board)
    code = expand!(stage_named(board, "Code"))

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert attr(view, chip_selector(code), "data-flow-paused") == "false"
    assert text(view, chip_selector(code)) == "AI"
  end

  test "5. an archived board shows the ask line and no Fix link", %{conn: conn, board: board} do
    insert_deploy_flow(board)
    {:ok, board} = Boards.archive_board(board)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#paused-flow-banner-deploy #paused-flow-banner-deploy-ask")
    refute has_element?(view, "#paused-flow-banner-deploy-fix")
  end

  test "6. a disabled flow on a broken shape is not paused", %{conn: conn, board: board} do
    insert_deploy_flow(board, false)
    deploy = stage_named(board, "Deploy")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, ~s([id^="paused-flow-banner-"]))
    assert attr(view, chip_selector(deploy), "data-flow-paused") == "false"
  end

  test "7. three paused flows collapse into one summary banner", %{conn: conn, board: board} do
    enable_flow!(board, "plan")
    enable_flow!(board, "code")
    insert_deploy_flow(board)
    {:ok, _} = Boards.disable_lane(stage_named(board, "Spec"), :done)
    {:ok, _} = Boards.disable_lane(stage_named(board, "Plan"), :done)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "#paused-flows-summary-banner")
    assert text(view, "#paused-flows-summary-banner") =~ "3 flows are paused — Plan, Code and Deploy —"
    refute has_element?(view, ~s([id^="paused-flow-banner-"]))
  end

  test "8. fixing the shape from another session clears the banner and chip live", %{
    conn: conn,
    board: board
  } do
    insert_deploy_flow(board)
    deploy = expand!(stage_named(board, "Deploy"))

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    assert has_element?(view, "#paused-flow-banner-deploy")

    {:ok, _} = Boards.enable_lane(stage_named(board, "Review"), :done)
    render(view)

    refute has_element?(view, "#paused-flow-banner-deploy")
    assert attr(view, chip_selector(deploy), "data-flow-paused") == "false"
    assert text(view, chip_selector(deploy)) == "AI"
  end

  test "9. breaking the shape from another session shows the banner live", %{conn: conn, board: board} do
    enable_flow!(board, "plan")

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
    refute has_element?(view, "#paused-flow-banner-plan")

    {:ok, _} = Boards.disable_lane(stage_named(board, "Spec"), :done)
    render(view)

    assert has_element?(view, "#paused-flow-banner-plan")
  end
end
