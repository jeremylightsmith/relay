defmodule RelayWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias RelayWeb.CoreComponents

  describe "owner_pill/1" do
    test "renders the Human pill with the primary token" do
      html = render_component(&CoreComponents.owner_pill/1, owner: :human)

      assert html =~ "badge-primary"
      assert html =~ "Human"
      assert html =~ ~s(data-owner="human")
      refute html =~ "badge-secondary"
    end

    test "renders the AI pill with the secondary token" do
      html = render_component(&CoreComponents.owner_pill/1, owner: :ai)

      assert html =~ "badge-secondary"
      assert html =~ "AI"
      assert html =~ ~s(data-owner="ai")
      refute html =~ "badge-primary"
    end
  end

  describe "stage_column/1" do
    test "renders the name, owner pill, and empty-state placeholder when empty" do
      html = render_component(&CoreComponents.stage_column/1, id: "stage-col-1", name: "Backlog", owner: :human)

      assert html =~ ~s(id="stage-col-1")
      assert html =~ "Backlog"
      assert html =~ "badge-primary"
      assert html =~ "stage-empty"
      assert html =~ "No cards yet"
    end

    test "renders slot content instead of the empty state" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.stage_column id="stage-col-4" name="Code" owner={:ai}>
          <div id="card-1">A card</div>
        </CoreComponents.stage_column>
        """)

      assert html =~ ~s(id="card-1")
      assert html =~ "badge-secondary"
      refute html =~ "stage-empty"
    end
  end
end
