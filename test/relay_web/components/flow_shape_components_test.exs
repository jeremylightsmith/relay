defmodule RelayWeb.FlowShapeComponentsTest do
  @moduledoc """
  RE432 — the Shape callout and its BOARD ORDER strip. Problem maps are built by the domain
  (`Relay.Flows.Shape.problems/2` over in-memory stages), so every WHAT / WHY / fix label is the
  domain's own sentence, never re-typed here.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Flows.Shape
  alias RelayWeb.FlowShapeComponents

  # Spec, Spec · Review, Plan, Plan · Done, Code — flow `deploy` on Plan pulls from a review lane.
  defp upstream_review_problem(enabled \\ true) do
    stages = [
      %{id: 1, name: "Spec", type: :work, parent_id: nil},
      %{id: 2, name: "Spec · Review", type: :review, parent_id: 1},
      %{id: 3, name: "Plan", type: :work, parent_id: nil},
      %{id: 4, name: "Plan · Done", type: :done, parent_id: 3},
      %{id: 5, name: "Code", type: :work, parent_id: nil}
    ]

    [problem] = Shape.problems(stages, [%{key: "deploy", stage_id: 3, enabled: enabled}])
    problem
  end

  defp problem_on(stages, stage_id) do
    [problem] = Shape.problems(stages, [%{key: "f", stage_id: stage_id, enabled: true}])
    problem
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp text(html, selector), do: html |> q(selector) |> LazyHTML.text() |> String.trim()
  defp attr(html, selector, name), do: html |> q(selector) |> LazyHTML.attribute(name) |> List.first()

  describe "shape_callout/1" do
    test "7. a paused problem renders its kind, verbatim markdown and the fix buttons" do
      p = upstream_review_problem()
      assert p.kind == :upstream_review

      html = render_component(&FlowShapeComponents.shape_callout/1, id: "c", problem: p)

      assert LazyHTML.attribute(q(html, ~s(#c[data-kind="upstream_review"][data-paused="true"])), "id") == ["c"]
      assert html |> q("#c-what strong") |> LazyHTML.text() == "Spec · Review"
      assert text(html, "#c-why") == Relay.Markdown.to_plain(p.why)

      assert attr(html, "#c-fix-0", "class") =~ "btn-warning"
      assert text(html, "#c-fix-0") == "Turn on Spec · Done"
      assert attr(html, "#c-fix-0", "phx-click") == "apply_shape_fix"
      assert attr(html, "#c-fix-0", "phx-value-flow-key") == "deploy"
      assert attr(html, "#c-fix-0", "phx-value-index") == "0"
      assert attr(html, "#c-fix-0", "phx-value-action") == "enable_lane"
      assert attr(html, "#c-fix-1", "class") =~ "btn-outline"
      assert attr(html, "#c-fix-1", "phx-value-action") == "insert_queue_stage"
      assert attr(html, "#c-fix-1", "data-confirm") == nil

      assert text(html, "#c-headline") == Relay.Markdown.to_plain(Shape.paused_detail(p))
      assert attr(html, "#c", "style") =~ "border-left:5px solid var(--color-warning)"
      assert has_order_strip?(html)
    end

    test "8. a disabled flow's problem renders the quieter variant with the off headline" do
      html = render_component(&FlowShapeComponents.shape_callout/1, id: "c", problem: upstream_review_problem(false))

      assert attr(html, "#c", "data-paused") == "false"
      assert text(html, "#c-headline") == "Flow deploy is off — it will be paused when turned on."
      style = attr(html, "#c", "style")
      assert style =~ "1px dashed"
      refute style =~ "border-left:5px"
    end

    test "9. read-only hides the FIX buttons" do
      html =
        render_component(&FlowShapeComponents.shape_callout/1,
          id: "c",
          problem: upstream_review_problem(),
          read_only?: true
        )

      assert html |> q(~s([id^="c-fix-"])) |> Enum.count() == 0
    end

    test "9. an error renders the refusal inside the callout" do
      sentence = Relay.Boards.stage_refusal_message(:invalid_anchor)

      html =
        render_component(&FlowShapeComponents.shape_callout/1,
          id: "c",
          problem: upstream_review_problem(),
          error: sentence
        )

      assert text(html, "#c-refusal") == "before/after must name another main stage on this board."
      assert text(html, "#c-refusal") == sentence
    end
  end

  defp has_order_strip?(html), do: html |> q("#c-order") |> Enum.count() == 1

  describe "board_order_strip/1" do
    @stages [
      %{id: 1, name: "Triage", type: :work, parent_id: nil},
      %{id: 2, name: "Backlog", type: :queue, parent_id: nil},
      %{id: 3, name: "Code", type: :work, parent_id: nil}
    ]

    test "10. a first-column :self leads with a ? and no trailing placeholder" do
      p = problem_on(@stages, 1)
      assert p.kind == :no_upstream

      html = render_component(&FlowShapeComponents.board_order_strip/1, id: "s", columns: p.columns)

      assert text(html, "#s-missing-before") == "?"
      assert html |> q("#s-missing-after") |> Enum.count() == 0
      assert attr(html, "#s-col-1", "data-mark") == "self"
      assert attr(html, "#s-col-2", "data-mark") == "none"
      assert text(html, "#s") =~ "BOARD ORDER"
    end

    test "10. a last-column :self trails with a ? and no leading placeholder" do
      p = problem_on(@stages, 3)
      assert p.kind == :no_downstream

      html = render_component(&FlowShapeComponents.board_order_strip/1, id: "s", columns: p.columns)

      assert text(html, "#s-missing-after") == "?"
      assert html |> q("#s-missing-before") |> Enum.count() == 0
    end

    test "10. an :offending column renders in the dashed bad style" do
      html =
        render_component(&FlowShapeComponents.board_order_strip/1,
          id: "s",
          columns: upstream_review_problem().columns
        )

      assert attr(html, "#s-col-2", "data-mark") == "offending"
      assert attr(html, "#s-col-2", "style") =~ "1.5px dashed"
      assert attr(html, "#s-col-3", "data-mark") == "self"
    end
  end

  describe "paused_flow_banners/1" do
    @why "Approving a card in Review moves it straight into **Deploy**. Nothing waits in between."

    defp paused_flow(key, stage_id) do
      %Schemas.Flow{
        key: key,
        stage_id: stage_id,
        enabled: true,
        problem: %{flow_key: key, stage_id: stage_id, enabled: true, why: @why}
      }
    end

    defp banners(flows, editor?),
      do:
        render_component(&FlowShapeComponents.paused_flow_banners/1,
          id: "paused-flow-banners",
          flows: flows,
          slug: "acme",
          editor?: editor?
        )

    defp squish(text), do: text |> String.split() |> Enum.join(" ")

    test "1. an editor sees one banner with the verbatim why and a Fix in Stages link" do
      html = banners([paused_flow("deploy", 7)], true)

      assert squish(text(html, "#paused-flow-banner-deploy")) ==
               squish(
                 "! Flow Deploy is paused: " <>
                   Relay.Markdown.to_plain(@why) <>
                   " No new Deploy runs will start until the board is fixed; runs already going will finish." <>
                   " Fix in Stages →"
               )

      assert html |> q("#paused-flow-banner-deploy strong") |> LazyHTML.text() =~ "Deploy"

      class = attr(html, "#paused-flow-banner-deploy-fix", "class")
      assert class =~ "btn-warning"
      assert class =~ "w-full"
      assert class =~ "drawer:w-auto"
      assert text(html, "#paused-flow-banner-deploy-fix") == "Fix in Stages →"

      assert attr(html, "#paused-flow-banner-deploy-fix", "href") ==
               "/board/acme/settings?section=stages#stage-7-row"

      assert attr(html, "#paused-flow-banner-deploy", "style") =~
               "border-left:5px solid var(--color-warning)"
    end

    test "2. a non-editor gets the ask line and no Fix button" do
      html = banners([paused_flow("deploy", 7)], false)

      assert html |> q("#paused-flow-banner-deploy-fix") |> Enum.count() == 0
      assert text(html, "#paused-flow-banner-deploy-ask") == "Ask a board admin to fix it in Stages settings."
      assert attr(html, "#paused-flow-banner-deploy-ask", "class") =~ "opacity-80"
    end

    test "3. two paused flows render two banners and no summary" do
      html = banners([paused_flow("deploy", 7), paused_flow("plan", 3)], true)

      assert html |> q(~s(#paused-flow-banners > [id^="paused-flow-banner-"])) |> Enum.count() == 2
      assert html |> q("#paused-flows-summary-banner") |> Enum.count() == 0
    end

    test "3. three paused flows collapse into one summary banner" do
      flows = [paused_flow("plan", 3), paused_flow("deploy", 7), paused_flow("retro", 9)]
      html = banners(flows, true)

      assert html |> q("#paused-flows-summary-banner") |> Enum.count() == 1
      assert html |> q(~s([id^="paused-flow-banner-"])) |> Enum.count() == 0

      assert squish(text(html, "#paused-flows-summary-banner")) =~
               ~r/^! 3 flows are paused — Plan, Deploy and Retro —/

      assert attr(html, "#paused-flows-summary-banner-fix", "href") ==
               "/board/acme/settings?section=stages#stage-3-row"
    end

    test "3. three paused flows show the ask line to a non-editor" do
      flows = [paused_flow("plan", 3), paused_flow("deploy", 7), paused_flow("retro", 9)]
      html = banners(flows, false)

      assert html |> q("#paused-flows-summary-banner-fix") |> Enum.count() == 0
      assert text(html, "#paused-flows-summary-banner-ask") == "Ask a board admin to fix it in Stages settings."
    end

    test "3. no paused flows render nothing" do
      html = banners([], true)

      assert html |> q(~s([id^="paused-flow"])) |> Enum.count() == 0
    end
  end
end
