defmodule RelayWeb.ExampleBoardLiveTest do
  @moduledoc """
  RE444: `/examples/:template` renders a template's seeded example board read-only, signed in or
  out — banner, intro, WIP explainer, the stages and sample cards, one section per flow with a
  clickable graph and node panel, and a read-only card detail. Every mutating event is swallowed.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Examples

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp query(view, selector), do: view |> doc() |> LazyHTML.query(selector)

  defp count(view, selector), do: view |> query(selector) |> Enum.count()

  defp texts(view, selector), do: view |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp text(view, selector), do: view |> query(selector) |> LazyHTML.text() |> String.trim()

  defp attr(view, selector, name), do: view |> query(selector) |> LazyHTML.attribute(name)

  defp stage_id(board, name), do: Enum.find(board.stages, &(&1.name == name and is_nil(&1.parent_id))).id

  defp column(view, name) do
    view
    |> query(".stage-column")
    |> Enum.find(&(&1 |> LazyHTML.query(".stage-name") |> LazyHTML.text() |> String.trim() == name))
  end

  describe "with the examples seeded" do
    setup do
      Examples.seed!(insert(:user), [])
      :ok
    end

    test "1. signed out, the page mounts with the title, badges, banner and a sign-in Use link", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      assert text(view, "h1#example-title") == "Streaks (bare-minimum)"
      assert has_element?(view, "#example-badge-public")
      assert has_element?(view, "#example-badge-read-only")
      assert text(view, "#example-banner-text") =~ "This is a public example of the Bare minimum template."
      assert text(view, "a#use-template") == "Use the bare-minimum template"
      assert attr(view, "a#use-template", "href") == ["/auth/google?return_to=%2Fboards%3Ftemplate%3Dbare-minimum"]
    end

    test "2. signed in, Use links straight to the picker with the template selected", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      {:ok, view, _html} = live(conn, ~p"/examples/design-led")

      assert attr(view, "a#use-template", "href") == ["/boards?template=design-led"]
      assert text(view, "a#use-template") == "Use the design-led template"

      {:ok, boards, _html} = live(conn, ~p"/boards?template=design-led")
      assert has_element?(boards, "#template-picker")
      assert has_element?(boards, "#template-radio-design-led[checked]")
    end

    test "3. the main stages render in order, every card undraggable, no mutating controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      assert texts(view, ".stage-column .stage-name") == ["Backlog", "Plan", "Implement", "Review", "Deploy", "Done"]

      assert count(view, "article.board-card") == 14
      assert view |> attr("article.board-card", "draggable") |> Enum.all?(&(&1 == "false"))

      for selector <- [~s([id$="-ai-listening"]), ".stage-compose", ~s([phx-hook="BoardDnD"]), ~s(a[href*="/settings"])] do
        assert count(view, selector) == 0, "expected no #{selector}"
      end

      forms = view |> query("form") |> LazyHTML.attribute("id")
      assert Enum.reject(forms, &String.starts_with?(&1 || "", "example-card")) == []
    end

    test "4. the full stage is amber with wip 2/2 and a FULL note; Review carries WHY", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      implement = column(view, "Implement")
      assert LazyHTML.attribute(implement, "data-wip") == ["at"]
      assert implement |> LazyHTML.query(".stage-wip") |> LazyHTML.text() |> String.trim() == "wip 2/2"
      assert implement |> LazyHTML.query(~s(.stage-note[data-kind="full"])) |> LazyHTML.text() =~ "ST12 waits in Plan"

      review = column(view, "Review")
      assert review |> LazyHTML.query(~s(.stage-note[data-kind="why"])) |> Enum.count() == 1

      assert text(view, "#wip-explainer") =~ "wip 2/2"
      assert text(view, "#wip-here") =~ "Implement is full (2/2)"
    end

    test "5. design-led: Design cards, a review chip on PA26, a full Code stage, 16 cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/design-led")

      design_titles =
        view
        |> column("Design")
        |> LazyHTML.query(".card-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "Weekly meal-plan calendar" in design_titles
      assert "Recipe card redesign" in design_titles

      assert count(view, ~s(article[data-ref="PA26"] .card-review-chip)) == 1
      assert view |> column("Code") |> LazyHTML.attribute("data-wip") == ["at"]
      assert count(view, "article.board-card") == 16
    end

    test "6. a needs-input card previews its question; working shows no progress; Done is grey", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      assert count(view, ~s(article[data-ref="ST11"] .card-needs-input)) == 1
      assert text(view, ~s(article[data-ref="ST11"] .card-question-preview)) == "Should weeks start on Sunday or Monday?"
      assert text(view, ~s(article[data-ref="ST10"] .card-status)) == "working"
      assert attr(view, ~s(article[data-ref="ST1"]), "data-done") == ["true"]
    end

    test "7. flows render in stage order, each with its own graph and node panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      ids = view |> query(~s(section[id^="example-flow-"])) |> LazyHTML.attribute("id")
      assert ids == ["example-flow-plan", "example-flow-implement"]

      assert has_element?(view, "#flow-graph-plan")
      assert has_element?(view, "#flow-graph-implement")
      refute has_element?(view, "#flow-graph")
      assert has_element?(view, ~s(#node-panel-plan[data-node="plan"]))
      assert has_element?(view, ~s(#node-panel-implement[data-node="implement"]))

      {:ok, led, _html} = live(conn, ~p"/examples/design-led")

      assert led |> query(~s(section[id^="example-flow-"])) |> LazyHTML.attribute("id") ==
               ["example-flow-design", "example-flow-plan", "example-flow-code"]

      assert has_element?(led, ~s(#node-panel-code[data-node="screenshots"]))
    end

    test "8. clicking a node shows it in the flow's panel with its agent and inline prompt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/three-brain")

      view |> element(~s(#flow-graph-three-brain-plan [data-node="claude_plan"])) |> render_click()

      assert has_element?(view, ~s(#node-panel-three-brain-plan[data-node="claude_plan"]))
      assert text(view, "#node-panel-three-brain-plan-llm") == "Claude Code · Claude Opus"

      view |> element(~s(#flow-graph-three-brain-plan [data-node="gpt_plan"])) |> render_click()

      assert text(view, "#node-panel-three-brain-plan-llm") == "Codex · GPT"
      assert text(view, "#node-panel-three-brain-plan-inline") == "inline · no skill"
      assert text(view, "#node-panel-three-brain-plan-prompt") =~ "You are one of three planners"
    end

    test "9. an unknown node or flow leaves the selection as it was", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/three-brain")

      render_hook(view, "select_node", %{"flow" => "three-brain-plan", "key" => "nope"})
      render_hook(view, "select_node", %{"flow" => "nope", "key" => "judge"})

      assert attr(view, "#node-panel-three-brain-plan", "data-node") == ["gpt_plan"]
    end

    test "10. a card opens read-only with its status, question and tasks, and closes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      view |> element(~s(article[data-ref="ST11"])) |> render_click()

      assert text(view, "#example-card-modal") =~ "Monthly calendar view"
      assert text(view, "#example-card-status") == "needs input"
      assert text(view, "#example-card-question") =~ "Should weeks start on Sunday or Monday?"

      view |> element("#example-card-close") |> render_click()
      refute has_element?(view, "#example-card-modal")

      view |> element(~s(article[data-ref="ST10"])) |> render_click()

      assert count(view, "#example-card-tasks li") == 4
      assert count(view, ~s(#example-card-tasks li[data-done="true"])) == 1
    end

    test "11. mutating events are swallowed: nothing moves, nothing is created", %{conn: conn} do
      {:ok, board} = Boards.get_example_board("bare-minimum")
      plan = stage_id(board, "Plan")
      backlog = stage_id(board, "Backlog")

      {:ok, view, _html} = live(conn, ~p"/examples/bare-minimum")

      render_hook(view, "move_card", %{"ref" => "ST18", "stage_id" => plan, "index" => 0})
      render_hook(view, "create_card", %{"stage_id" => backlog, "card" => %{"title" => "x"}})
      render_hook(view, "compose", %{"stage-id" => backlog})
      render_hook(view, "set_status", %{"ref" => "ST18", "status" => "working"})
      render_hook(view, "collapse_stage", %{"stage-id" => backlog})

      card = Cards.get_card_by_ref(board, "ST18")
      assert card.stage_id == backlog
      assert card.status == :ready
      assert length(Cards.list_cards(board)) == 14
      refute has_element?(view, ~s([id$="-composer"]))
      assert render(view)
    end

    test "12. an unknown template slug 404s", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/examples/nope") end
    end
  end

  describe "with no examples seeded" do
    test "12. a known template slug 404s", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/examples/bare-minimum") end
    end
  end
end
