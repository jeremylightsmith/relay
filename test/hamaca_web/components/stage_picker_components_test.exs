defmodule HamacaWeb.StagePickerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.StagePickerComponents
  alias Schemas.Release
  alias Schemas.Stage
  alias Schemas.StoryActivity
  alias Schemas.StoryStep

  # Board (hierarchical) order: a parent, then its sub-lanes.
  defp stages do
    backlog = %Stage{id: 11, name: "Backlog", type: :queue, parent_id: nil}
    design = %Stage{id: 12, name: "Design", type: :work, parent_id: nil}
    # The composite internal name Boards.enable_lane/2 builds — it must never reach the label.
    review = %Stage{id: 13, name: "Design:Review", type: :review, parent_id: design.id}
    {backlog, design, review}
  end

  defp stage_rows do
    {backlog, design, review} = stages()
    StagePickerComponents.stage_rows([backlog, design, review], MapSet.new([design.id]))
  end

  defp step_fixture do
    capture = %StoryActivity{id: 21, name: "Capture", position: 0}
    empty = %StoryActivity{id: 22, name: "Empty", position: 1}
    # Deliberately out of position order: step_rows/2 sorts each activity's steps by position.
    voice = %StoryStep{id: 32, name: "Voice note", position: 1, story_activity_id: capture.id}
    add = %StoryStep{id: 31, name: "Add card", position: 0, story_activity_id: capture.id}
    {[capture, empty], [voice, add]}
  end

  defp render_picker(attrs) do
    base = %{id: "p", heading: "MOVE 3 CARDS TO STAGE", event: "go", rows: stage_rows()}
    html = render_component(&StagePickerComponents.stage_picker/1, Map.merge(base, Map.new(attrs)))
    {html, LazyHTML.from_fragment(html)}
  end

  defp q(doc, selector), do: LazyHTML.query(doc, selector)
  defp count(doc, selector), do: doc |> q(selector) |> Enum.count()
  defp attr(doc, selector, name), do: doc |> q(selector) |> LazyHTML.attribute(name)
  defp text_of(doc, selector), do: doc |> q(selector) |> LazyHTML.text() |> String.trim()

  defp classes(doc, selector) do
    doc |> attr(selector, "class") |> List.first("") |> String.split()
  end

  describe "mark_values/0 and no_release_id/0" do
    test "the mark set is :all and :some" do
      assert StagePickerComponents.mark_values() == [:all, :some]
    end

    test "the (No release) row id is \"none\"" do
      assert StagePickerComponents.no_release_id() == "none"
    end
  end

  describe "stage_rows/2" do
    # Scenario 1
    test "top-level stages are depth-0 rows owned by AI iff in the set; a sub-lane is a depth-1 lane row" do
      {backlog, design, review} = stages()

      assert [b, d, r] = stage_rows()

      assert %{id: id, kind: :row, depth: 0, owner: :human, label: "Backlog", display_name: "Backlog"} = b
      assert id == backlog.id

      assert %{id: id, kind: :row, depth: 0, owner: :ai, label: "Design", display_name: "Design"} = d
      assert id == design.id

      assert %{id: id, kind: :row, depth: 1, owner: nil, label: "Review", display_name: "Design · Review"} = r
      assert id == review.id
    end
  end

  describe "filter_rows/2" do
    # Scenario 2
    test "a trimmed, case-insensitive match on display_name flattens the kept row to depth 0" do
      {_backlog, _design, review} = stages()

      assert [%{id: id, label: "Design · Review", depth: 0}] = StagePickerComponents.filter_rows(stage_rows(), " REV ")
      assert id == review.id
    end

    # Scenario 3
    test "a blank query returns the rows unchanged" do
      rows = stage_rows()

      assert StagePickerComponents.filter_rows(rows, "") == rows
      assert StagePickerComponents.filter_rows(rows, "   ") == rows
      assert StagePickerComponents.filter_rows(rows, nil) == rows
    end

    # Scenario 5
    test "a header survives only when one of its rows does" do
      {activities, steps} = step_fixture()
      rows = StagePickerComponents.step_rows(activities, steps)

      assert [
               %{kind: :header, id: "act-21", label: "Capture"},
               %{kind: :row, id: 32, label: "Voice note"}
             ] = StagePickerComponents.filter_rows(rows, "voice")

      assert StagePickerComponents.filter_rows(rows, "zzz") == []
    end
  end

  describe "step_rows/2" do
    # Scenario 4
    test "each activity with steps is a header followed by its steps in position order" do
      {activities, steps} = step_fixture()

      assert [
               %{kind: :header, id: "act-21", label: "Capture"},
               %{kind: :row, id: 31, label: "Add card", owner: nil},
               %{kind: :row, id: 32, label: "Voice note", owner: nil}
             ] = StagePickerComponents.step_rows(activities, steps)
    end

    test "an activity with no steps emits nothing" do
      {activities, steps} = step_fixture()
      rows = StagePickerComponents.step_rows(activities, steps)

      refute Enum.any?(rows, &(&1.label == "Empty"))
      refute Enum.any?(rows, &(&1.id == "act-22"))
    end
  end

  describe "release_rows/1" do
    # Scenario 6
    test "the releases in order, then a final (No release) row" do
      rows = StagePickerComponents.release_rows([%Release{id: 1, name: "MVP"}, %Release{id: 2, name: "v2"}])

      assert Enum.map(rows, & &1.label) == ["MVP", "v2", "(No release)"]
      assert List.last(rows).id == "none"
      assert List.last(rows).id == StagePickerComponents.no_release_id()
      assert Enum.all?(rows, &(&1.kind == :row and &1.depth == 0 and &1.owner == nil))
    end
  end

  describe "stage_picker/1" do
    # Scenario 7
    test "renders marks, owner squares, the nested lane guide and the heading, with no count text" do
      {backlog, design, review} = stages()
      {html, doc} = render_picker(marks: %{backlog.id => :some, design.id => :all})

      backlog_row = "#p-#{backlog.id}"
      assert count(doc, "button#{backlog_row}") == 1
      assert attr(doc, backlog_row, "phx-click") == ["go"]
      assert attr(doc, backlog_row, "phx-value-stage_id") == [to_string(backlog.id)]
      assert count(doc, "#{backlog_row} span.bg-primary.h-\\[2px\\]") == 1

      design_row = "#p-#{design.id}"
      assert count(doc, "div#{design_row}") == 1
      assert count(doc, "#{design_row}[phx-click]") == 0
      assert count(doc, "#{design_row} .hero-check") == 1

      review_row = "#p-#{review.id}"
      assert count(doc, "#{review_row} .bg-base-300.w-px") == 1
      assert text_of(doc, review_row) =~ "Review"
      assert count(doc, "#{review_row} .rounded-\\[2px\\]") == 0

      assert "bg-primary/45" in classes(doc, "#{backlog_row} .rounded-\\[2px\\]")
      assert "bg-secondary" in classes(doc, "#{design_row} .rounded-\\[2px\\]")

      text = LazyHTML.text(doc)
      assert text =~ "MOVE 3 CARDS TO STAGE"
      refute text =~ ~r/\d+ of \d+/
      refute html =~ "current"
    end

    test "the panel, heading and rows carry the mockup's classes" do
      {backlog, design, review} = stages()
      {_html, doc} = render_picker(marks: %{design.id => :all}, class: "max-h-[260px]")

      assert classes(doc, "#p") ==
               ~w(bg-base-100 border border-base-300 rounded-box shadow-lg w-64 p-1.5 overflow-y-auto max-h-[260px])

      assert ~w(text-[12.5px] font-medium text-base-content/85) -- classes(doc, "#p-#{backlog.id}") == []
      assert ~w(text-[12.5px] font-semibold text-base-content) -- classes(doc, "#p-#{design.id}") == []
      assert ~w(text-[11.5px] text-base-content/65) -- classes(doc, "#p-#{review.id}") == []

      assert ~w(flex w-full items-center gap-2 rounded-md px-1.5 py-[5px] text-left hover:bg-base-200) --
               classes(doc, "#p-#{backlog.id}") == []

      assert count(doc, "#p-#{backlog.id} > span.w-3\\.5.flex-none:first-child") == 1
      assert text_of(doc, "#p-#{review.id} .font-mono.-ml-1") == "─"
    end

    # Scenario 8
    test "a filter renders the form and shows only the matching rows, flattened" do
      {_backlog, _design, review} = stages()
      {_html, doc} = render_picker(filter: "rev", filter_event: "f")

      assert attr(doc, "#p-filter-form", "phx-change") == ["f"]
      assert attr(doc, "#p-filter-form", "phx-submit") == ["f"]
      assert attr(doc, "#p-filter", "name") == ["q"]
      assert attr(doc, "#p-filter", "placeholder") == ["Filter stages…"]
      assert ~w(input input-xs w-full mb-1.5) -- classes(doc, "#p-filter") == []
      assert [mounted] = attr(doc, "#p-filter", "phx-mounted")
      assert mounted =~ "focus"

      assert doc |> q("[id^='p-1']") |> LazyHTML.attribute("id") == ["p-#{review.id}"]
      assert text_of(doc, "#p-#{review.id}") == "Design · Review"
    end

    test "a nil filter renders no filter box" do
      {_html, doc} = render_picker([])
      assert count(doc, "#p-filter-form") == 0
    end

    # Scenario 9
    test "a filter matching nothing shows No stages match" do
      {_html, doc} = render_picker(filter: "zzz", filter_event: "f")
      assert text_of(doc, "#p-none") == "No stages match"
    end

    # Scenario 10
    test "row_attrs and pending reach every clickable row; the inert :all row has no pressed face" do
      {backlog, design, review} = stages()

      {_html, doc} =
        render_picker(marks: %{design.id => :all}, row_attrs: %{"phx-value-ref" => "RE1"}, pending: true)

      for id <- [backlog.id, review.id] do
        row = "button#p-#{id}"
        assert attr(doc, row, "phx-value-ref") == ["RE1"]
        assert "pending-action" in classes(doc, row)
        assert text_of(doc, "#{row} .pending-face") == "Moving…"
      end

      assert count(doc, "#p-#{design.id} .pending-face") == 0
    end

    test "value_name renames the row's value param" do
      {backlog, _design, _review} = stages()
      {_html, doc} = render_picker(value_name: "release_id")

      assert attr(doc, "#p-#{backlog.id}", "phx-value-release_id") == [to_string(backlog.id)]
    end

    test "act headers render as non-clickable uppercase labels" do
      {activities, steps} = step_fixture()
      {_html, doc} = render_picker(rows: StagePickerComponents.step_rows(activities, steps), heading: "STEP")

      header = ".font-mono.uppercase.text-base-content\\/45"
      assert text_of(doc, header) == "Capture"
      assert count(doc, "#{header}[phx-click]") == 0
      assert count(doc, "button#p-31") == 1
    end
  end
end
