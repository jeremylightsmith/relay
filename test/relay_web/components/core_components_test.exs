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

  describe "board_card/1" do
    test "renders the title and ref" do
      html = render_component(&CoreComponents.board_card/1, id: "card-1", ref: "RLY-3", title: "Ship MMF 03")

      assert html =~ ~s(id="card-1")
      assert html =~ "Ship MMF 03"
      assert html =~ "RLY-3"
      refute html =~ "card-tag"
    end

    test "renders the #tag when present" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "card-2",
          ref: "RLY-4",
          title: "Tagged",
          tag: "infra"
        )

      assert html =~ "card-tag"
      assert html =~ "#infra"
    end
  end

  describe "stage_column/1" do
    test "renders the name, owner pill, empty state, and compose button when empty" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          owner: :human,
          stage_id: 7
        )

      assert html =~ ~s(id="stage-col-1")
      assert html =~ "Backlog"
      assert html =~ "stage-owner-swatch"
      assert html =~ ~s(data-owner="human")
      assert html =~ "stage-empty"
      assert html =~ "No cards yet"
      assert html =~ ~s(id="stage-col-1-new-card")
      assert html =~ ~s(phx-value-stage-id="7")
      refute html =~ ~s(id="stage-col-1-compose-form")
    end

    test "renders its cards with refs derived from the board key" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          board_key: "RLY",
          cards: [
            {"cards-1", %{title: "First card", tag: "infra", ref_number: 1, status: :queued, progress: nil, owners: []}},
            {"cards-2",
             %{
               title: "Second card",
               tag: nil,
               ref_number: 2,
               status: :working,
               progress: 40,
               owners: [%{actor_type: :agent}]
             }}
          ]
        )

      assert html =~ ~s(id="stage-col-4-cards")
      assert html =~ ~s(id="cards-1")
      assert html =~ "First card"
      assert html =~ "RLY-1"
      assert html =~ "#infra"
      assert html =~ ~s(id="cards-2")
      assert html =~ "RLY-2"
      assert html =~ ~s(data-active-owner="ai")
      assert html =~ "working · 40%"
    end

    test "shows the composer form instead of the compose button when composing" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          owner: :human,
          stage_id: 7,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      assert html =~ ~s(id="stage-col-1-compose-form")
      assert html =~ ~s(name="card[title]")
      assert html =~ ~s(name="stage_id")
      assert html =~ "Cancel"
      refute html =~ ~s(id="stage-col-1-new-card")
    end

    test "collapsed renders the mockup's 44px dashed strip instead of the column" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-6",
          name: "Deploy",
          owner: :ai,
          stage_id: 6,
          count: 0,
          collapsed: true
        )

      # strip identity + mockup values (Relay Board.dc.html lines ~75–81)
      assert html =~ ~s(id="stage-strip-6")
      assert html =~ "width:44px"
      assert html =~ "border:1px dashed oklch(0.90 0.006 255)"
      assert html =~ "background:oklch(0.965 0.004 255)"
      assert html =~ "border-radius:11px"
      assert html =~ "cursor:pointer"
      # 9px owner swatch in the AI colour
      assert html =~ "stage-owner-swatch"
      assert html =~ ~s(data-owner="ai")
      assert html =~ "width:9px;height:9px;border-radius:3px"
      # rotated name + mono count
      assert html =~ "writing-mode:vertical-rl"
      assert html =~ "rotate(180deg)"
      assert html =~ "stage-strip-name"
      assert html =~ "Deploy"
      assert html =~ ~s(class="stage-count")
      # click-to-expand + drop-target contract
      assert html =~ ~s(phx-click="expand_stage")
      assert html =~ ~s(phx-value-stage-id="6")
      assert html =~ ~s(data-stage-id="6")
      assert html =~ "stage-cards"
      # none of the expanded chrome renders
      refute html =~ ~s(id="stage-col-6-new-card")
      refute html =~ "No cards yet"
    end

    test "collapsed shows the total card count across main and sub-lanes" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          count: 0,
          collapsed: true,
          sublanes: [
            %{id: 401, name: "Review", lane: :review, owner: :human, count: 0, cards: []},
            %{id: 402, name: "Done", lane: :done, owner: :ai, count: 0, cards: []}
          ]
        )

      assert html =~ ~s(id="stage-strip-4")

      count_text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-strip-4 .stage-count")
        |> LazyHTML.text()
        |> String.trim()

      assert count_text == "0"
    end

    test "collapsed: false renders the full column exactly as before" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          owner: :human,
          stage_id: 7,
          collapsed: false
        )

      assert html =~ ~s(id="stage-col-1")
      refute html =~ "stage-strip"
      assert html =~ "No cards yet"
    end

    test "an empty collapsed sub-lane renders the 34px strip; a non-collapsed one renders expanded" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          count: 1,
          board_key: "RLY",
          cards: [
            {"cards-1", %{title: "Main work", tag: nil, ref_number: 1, status: :queued, progress: nil, owners: []}}
          ],
          sublanes: [
            %{id: 401, name: "Review", lane: :review, owner: :human, count: 0, cards: [], collapsed: true},
            %{id: 402, name: "Done", lane: :done, owner: :ai, count: 0, cards: []}
          ]
        )

      # collapsed Review lane: 34px strip (mockup lines ~1028–1037)
      assert html =~ ~s(id="sublane-401-strip")
      assert html =~ "flex:0 0 34px"
      assert html =~ "width:6px;height:6px;border-radius:50%"
      assert html =~ "opacity:0.6"
      assert html =~ "writing-mode:vertical-rl"
      # lane colour + the same left divider as an expanded lane
      assert html =~ "oklch(0.52 0.12 65)"
      assert html =~ "border-left:1px solid oklch(0.90 0.04 75)"
      # drop target + click-to-expand contract
      assert html =~ ~s(data-stage-id="401")
      assert html =~ ~s(phx-value-stage-id="401")
      refute html =~ ~s(id="sublane-401-cards")

      # Done lane was not marked collapsed: renders expanded as before
      assert html =~ ~s(id="sublane-402-cards")
      refute html =~ ~s(id="sublane-402-strip")

      # stage width: 240 (main) + 34 (strip) + 178 (expanded) = 452
      assert html =~ "width:452px"
    end
  end

  describe "status_badge/1" do
    test "renders each status with its colour token and label" do
      for {status, class, label} <- [
            {:queued, "badge-ghost", "queued"},
            {:working, "badge-secondary", "working"},
            {:needs_input, "badge-warning", "NEEDS INPUT"},
            {:in_review, "badge-primary", "in review"},
            {:done, "badge-success", "done"}
          ] do
        html = render_component(&CoreComponents.status_badge/1, status: status)

        assert html =~ class
        assert html =~ label
        assert html =~ ~s(data-status="#{status}")
      end
    end

    test "working includes the progress percentage when present" do
      html = render_component(&CoreComponents.status_badge/1, status: :working, progress: 61)

      assert html =~ "working·61%"
    end

    test "working without progress shows no percentage" do
      html = render_component(&CoreComponents.status_badge/1, status: :working)

      refute html =~ "%"
    end
  end

  describe "board_card/1 baton treatments" do
    test "renders neutral without active owner or status" do
      html = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RLY-1", title: "T")

      assert html =~ "border-l-base-300"
      refute html =~ "card-owners"
      refute html =~ "card-status"
      refute html =~ "card-mismatch"
    end

    test "human active renders the blue border and owner avatar" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c2",
          ref: "RLY-2",
          title: "T",
          active_owner: :human,
          stage_owner: :human,
          status: :queued,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        )

      assert html =~ "border-l-primary"
      assert html =~ ~s(data-active-owner="human")
      assert html =~ "card-owners"
      assert html =~ ~s(data-actor-type="user")
      refute html =~ "card-mismatch"
    end

    test "AI active renders the violet border, AI avatar, and working progress" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c3",
          ref: "RLY-3",
          title: "T",
          active_owner: :ai,
          stage_owner: :ai,
          status: :working,
          progress: 61,
          owners: [%{actor_type: :agent}]
        )

      assert html =~ "border-l-secondary"
      assert html =~ ~s(data-active-owner="ai")
      assert html =~ "card-owners"
      assert html =~ ~s(data-actor-type="agent")
      assert html =~ "working · 61%"
      refute html =~ "card-mismatch"
    end

    test "a human-active card in an AI stage warns it is meant for agents" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c4",
          ref: "RLY-4",
          title: "T",
          active_owner: :human,
          stage_owner: :ai,
          status: :queued
        )

      assert html =~ "border-l-error"
      assert html =~ "card-mismatch"
      assert html =~ "This stage is meant to be used by agents"
    end

    test "an AI-active card in a human stage warns it is meant for humans" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c5",
          ref: "RLY-5",
          title: "T",
          active_owner: :ai,
          stage_owner: :human,
          status: :queued
        )

      assert html =~ "border-l-error"
      assert html =~ "This stage is meant for humans"
    end

    test "no mismatch without an active owner, even in an AI stage" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c6",
          ref: "RLY-6",
          title: "T",
          stage_owner: :ai
        )

      refute html =~ "card-mismatch"
      assert html =~ "border-l-base-300"
    end
  end

  describe "editable_text/1" do
    test "read state renders the value, the affordance, the pencil, and the edit hook" do
      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-title",
          value: "Draft the spec",
          edit_event: "edit_title",
          save_event: "save_card_title",
          cancel_event: "cancel_title"
        )

      assert html =~ ~s(id="et-title-display")
      assert html =~ "Draft the spec"
      assert html =~ ~s(phx-click="edit_title")
      assert html =~ ~s(role="button")
      assert html =~ ~s(tabindex="0")
      assert html =~ "cursor-text"
      assert html =~ "hover:bg-base-200"
      assert html =~ "hero-pencil-square"
      assert html =~ ~s(phx-hook="InlineEdit")
      assert html =~ ~s(data-inline-role="display")
      refute html =~ ~s(id="et-title-form")
    end

    test "read state shows the placeholder when the value is blank" do
      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-empty",
          value: "",
          placeholder: "Add a description…",
          edit_event: "edit_description",
          save_event: "save_card_description",
          cancel_event: "cancel_description"
        )

      assert html =~ "Add a description…"
      assert html =~ "text-base-content/50"
    end

    test "read state renders markdown when markdown is set" do
      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-desc",
          value: "Line one\n\nLine two",
          markdown: true,
          edit_event: "edit_description",
          save_event: "save_card_description",
          cancel_event: "cancel_description"
        )

      assert html =~ ~s(id="et-desc-view")
      assert html =~ ~s(class="md")
      # Relay.Markdown.to_html/1 turns the blank line into two <p> paragraphs
      # (rendered raw, mirroring the existing drawer description view).
      assert html =~ "<p>"
      assert html =~ "Line one"
      assert html =~ "Line two"
    end

    test "edit state renders the pre-filled input, the hook wiring, and Save/Cancel" do
      form = to_form(%{"title" => "Draft the spec"}, as: :card)

      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-title",
          editing: true,
          form: form,
          field: :title,
          edit_event: "edit_title",
          save_event: "save_card_title",
          cancel_event: "cancel_title"
        )

      assert html =~ ~s(id="et-title-form")
      assert html =~ ~s(phx-submit="save_card_title")
      assert html =~ ~s(phx-click-away="cancel_title")
      assert html =~ ~s(id="et-title-input")
      assert html =~ ~s(name="card[title]")
      assert html =~ "Draft the spec"
      assert html =~ ~s(phx-hook="InlineEdit")
      assert html =~ ~s(data-cancel-id="et-title-cancel")
      assert html =~ ~s(id="et-title-save")
      assert html =~ ~s(id="et-title-cancel")
      assert html =~ ~s(phx-click="cancel_title")
      refute html =~ ~s(id="et-title-display")
    end

    test "multiline edit state renders a textarea with the given rows" do
      form = to_form(%{"description" => "Body"}, as: :card)

      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-desc",
          editing: true,
          multiline: true,
          rows: "12",
          form: form,
          field: :description,
          edit_event: "edit_description",
          save_event: "save_card_description",
          cancel_event: "cancel_description"
        )

      assert html =~ ~s(<textarea)
      assert html =~ ~s(id="et-desc-input")
      assert html =~ ~s(rows="12")
    end

    test "edit_attrs are spread onto the read display for parameterised fields (stages)" do
      html =
        render_component(&CoreComponents.editable_text/1,
          id: "et-stage",
          value: "Code",
          edit_event: "edit_stage",
          save_event: "save_stage",
          cancel_event: "cancel_stage",
          edit_attrs: %{"phx-value-stage-id" => 3, "phx-value-field" => "name"}
        )

      assert html =~ ~s(phx-value-stage-id="3")
      assert html =~ ~s(phx-value-field="name")
    end
  end
end
