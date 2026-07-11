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
    test "renders the name, type icon, empty state, and compose button when empty" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7
        )

      assert html =~ ~s(id="stage-col-1")
      assert html =~ "Backlog"
      assert html =~ "stage-type-icon"
      assert html =~ ~s(data-type="queue")
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
          type: :work,
          ai_enabled: true,
          stage_id: 4,
          board_key: "RLY",
          cards: [
            {"cards-1",
             %{id: 1, title: "First card", tag: "infra", ref_number: 1, status: :ready, sub_tasks: [], owners: []}},
            {"cards-2",
             %{
               id: 2,
               title: "Second card",
               tag: nil,
               ref_number: 2,
               status: :working,
               sub_tasks: [
                 %{done: true},
                 %{done: true},
                 %{done: false},
                 %{done: false},
                 %{done: false}
               ],
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
          type: :queue,
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

    test "compose + button has a ≥44px tap target with a visually small glyph" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7
        )

      assert html =~ ~s(id="stage-col-1-new-card")
      # ≥44×44px hit area (mobile tap target); glyph stays 15px
      assert html =~ "min-width:44px"
      assert html =~ "min-height:44px"
      assert html =~ "font-size:15px"
    end

    test "composer input is ≥16px (no iOS zoom) and its buttons are ≥44px tall" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      # 16px input font prevents iOS auto-zoom on focus
      assert html =~ ~s(class="commit-field-input text-base")
      # Add card / Cancel are comfortable tap targets
      assert html =~ "min-h-[44px]"
    end

    test "collapsed renders the mockup's 44px dashed strip instead of the column" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-6",
          name: "Deploy",
          type: :work,
          ai_enabled: true,
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
      # 9px work-type icon (blue square)
      assert html =~ "stage-type-icon"
      assert html =~ ~s(data-type="work")
      assert html =~ "width:9px;height:9px;border-radius:2px"
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
          type: :work,
          ai_enabled: true,
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
          type: :queue,
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
          type: :work,
          ai_enabled: true,
          stage_id: 4,
          count: 1,
          board_key: "RLY",
          cards: [
            {"cards-1", %{id: 1, title: "Main work", tag: nil, ref_number: 1, status: :ready, sub_tasks: [], owners: []}}
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
            {:ready, "badge-ghost", "ready"},
            {:working, "badge-secondary", "working"},
            {:needs_input, "badge-warning", "NEEDS INPUT"},
            {:in_review, "badge-primary", "in review"}
          ] do
        html = render_component(&CoreComponents.status_badge/1, status: status)

        assert html =~ class
        assert html =~ label
        assert html =~ ~s(data-status="#{status}")
      end
    end

    test "working appends progress when present" do
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

    test "a ready, human-active card is quiet — no owner accent" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c2",
          ref: "RLY-2",
          title: "T",
          active_owner: :human,
          stage_owner: :human,
          status: :ready,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]
        )

      assert html =~ "border-l-base-300"
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

    test "a working card with no progress shows a plain label and no bar" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c9",
          ref: "RLY-9",
          title: "T",
          active_owner: :ai,
          stage_owner: :ai,
          status: :working,
          owners: [%{actor_type: :agent}]
        )

      assert html =~ ~s(data-status="working")
      assert html =~ "working"
      refute html =~ "working · "
      refute html =~ "height:5px;border-radius:3px;background:oklch(0.93 0.02 292)"
    end

    test "a human-active card in an AI stage warns it is meant for agents" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c4",
          ref: "RLY-4",
          title: "T",
          active_owner: :human,
          stage_owner: :ai,
          status: :ready
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
          status: :ready
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

    test "in_review paints amber and shows the review chip" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-1",
          title: "T",
          status: :in_review
        })

      assert html =~ "border-l-warning"
      assert html =~ "card-review-chip"
      assert html =~ "review"
    end

    test "needs_input paints amber, shows the needs-you chip and the question preview" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-2",
          title: "T",
          status: :needs_input,
          question: "Which locales ship first?"
        })

      assert html =~ "border-l-warning"
      assert html =~ "card-needs-input"
      assert html =~ "card-question-preview"
      assert html =~ "Which locales ship first?"
    end

    test "ready in a Done sub-lane shows the green ready chip" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-3",
          title: "T",
          status: :ready,
          stage_type: :done,
          done: false
        })

      assert html =~ "card-ready-chip"
      refute html =~ "border-l-warning"
    end

    test "ready at the terminal stage renders grayed Done, no chip" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-4",
          title: "T",
          status: :ready,
          stage_type: :done,
          done: true
        })

      assert html =~ ~s(data-done="true")
      refute html =~ "card-ready-chip"
      refute html =~ "card-review-chip"
    end

    test "a plain parked ready card is quiet — no chip, no amber" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-5",
          title: "T",
          status: :ready,
          stage_type: :queue
        })

      refute html =~ "border-l-warning"
      refute html =~ "card-ready-chip"
      refute html =~ "card-review-chip"
    end
  end

  describe "card_drawer/1" do
    defp drawer_card(overrides) do
      Map.merge(
        %{
          title: "T",
          status: :ready,
          blocked_since: nil,
          rejection: nil,
          sub_tasks: [],
          tag: nil,
          description: nil,
          spec: nil,
          plan: nil,
          pr_url: nil,
          branch: nil,
          ai_result: nil,
          owners: [],
          inserted_at: ~U[2026-07-01 00:00:00Z],
          updated_at: ~U[2026-07-01 00:00:00Z]
        },
        overrides
      )
    end

    defp drawer_attrs(card_overrides, extra) do
      card = drawer_card(card_overrides)

      Map.merge(
        %{
          id: "card-drawer",
          ref: "RLY-1",
          card: card,
          stage_name: "Code",
          stage_owner: :ai,
          close_patch: "/board",
          title_form: to_form(%{"title" => card.title}, as: :card),
          comment_form: to_form(%{"body" => ""}, as: :comment),
          conversation: [],
          activity: []
        },
        extra
      )
    end

    test "working shows the pulsing strip with sub-task-derived progress" do
      attrs =
        drawer_attrs(
          %{
            status: :working,
            sub_tasks: [
              %{id: 1, title: "a", done: true},
              %{id: 2, title: "b", done: false}
            ]
          },
          %{}
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="working-strip")
      assert html =~ "Relay AI is working"
      assert html =~ ~s(id="working-strip-pct")
      assert html =~ "50%"
    end

    test "working with no sub-tasks shows the strip but no percentage" do
      attrs = drawer_attrs(%{status: :working}, %{})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="working-strip")
      refute html =~ ~s(id="working-strip-pct")
    end

    test "no working strip when not working" do
      attrs = drawer_attrs(%{status: :ready}, %{})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      refute html =~ ~s(id="working-strip")
    end

    test "done shows the header Done pill" do
      attrs = drawer_attrs(%{status: :ready}, %{done: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="drawer-done-pill")
      assert html =~ "Done"
    end

    test "not done shows no Done pill" do
      attrs = drawer_attrs(%{status: :ready}, %{done: false})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      refute html =~ ~s(id="drawer-done-pill")
    end

    test "below 720px the drawer body is a single scroll container; ≥720px keeps two columns" do
      attrs = drawer_attrs(%{status: :ready}, %{})
      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Panel: full-screen below 720px (w-full h-dvh); desktop width only at drawer: (720px)
      assert html =~
               "drawer-panel flex h-dvh w-full flex-col bg-base-100 shadow-xl drawer:w-[min(760px,94vw)]"

      # Body wrapper: single scroll container below 720px; hands scroll back to children at drawer:
      assert html =~
               "flex min-h-0 flex-1 flex-col overflow-y-auto drawer:flex-row drawer:overflow-hidden"

      # Main column: content-sized + no own scroll below 720px; flex-1 + own scroll at drawer:
      assert html =~
               ~s(id="card-drawer-main")

      assert html =~
               "flex min-w-0 flex-none flex-col gap-6 p-5 drawer:flex-1 drawer:overflow-y-auto"

      # Properties rail: full-width top-border below 720px; side panel + own scroll at drawer:
      assert html =~ ~s(id="card-drawer-rail")

      assert html =~
               "flex w-full shrink-0 flex-col gap-5 border-t border-base-300 bg-base-200/30 p-5 text-sm drawer:w-[220px] drawer:overflow-y-auto drawer:border-l drawer:border-t-0"

      # Regression: the old lg/1024 stack point is fully gone from the drawer.
      refute html =~ "lg:flex-row"
      refute html =~ "lg:w-[220px]"
      refute html =~ "lg:w-[min(760px,94vw)]"
    end
  end

  describe "inline_field/1" do
    test "rest state renders the value with no pencil icon and no form" do
      html =
        render_component(&CoreComponents.inline_field/1,
          id: "if-title",
          value: "Draft the onboarding spec",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert html =~ ~s(id="if-title-display")
      assert html =~ "Draft the onboarding spec"
      refute html =~ "hero-pencil-square"
      refute html =~ ~s(id="if-title-form")
    end

    test "blank value shows the placeholder" do
      html =
        render_component(&CoreComponents.inline_field/1,
          id: "if-title",
          value: "",
          placeholder: "Untitled",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert html =~ "Untitled"
    end

    test "editing state renders a single-line input, the pill, and Enter hint" do
      html =
        render_component(&CoreComponents.inline_field/1,
          id: "if-title",
          editing: true,
          field: :title,
          form: Phoenix.Component.to_form(%{"title" => "Draft"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert html =~ ~s(id="if-title-form")
      assert html =~ ~s(<input)
      assert html =~ ~s(data-commit="enter")
      assert html =~ ~s(id="if-title-save")
      assert html =~ ~s(id="if-title-cancel")
      assert html =~ "Enter · Esc"
    end
  end

  describe "boxed_field/1" do
    test ":form mode renders only a styled bound input" do
      html =
        render_component(&CoreComponents.boxed_field/1,
          id: "bf-comment-input",
          commit: :form,
          multiline: true,
          field: :body,
          form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment),
          placeholder: "Write a comment…"
        )

      assert html =~ ~s(id="bf-comment-input")
      assert html =~ "commit-field-input"
      assert html =~ "Write a comment…"
      refute html =~ "commit-pill"
    end

    test ":self markdown rest renders markdown, blank shows dashed placeholder" do
      filled =
        render_component(&CoreComponents.boxed_field/1,
          id: "bf-desc",
          markdown: true,
          multiline: true,
          value: "# Hi",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert filled =~ ~s(id="bf-desc-view")
      assert filled =~ ~s(class="md")

      blank =
        render_component(&CoreComponents.boxed_field/1,
          id: "bf-desc",
          markdown: true,
          multiline: true,
          value: "",
          placeholder: "Add a description…",
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert blank =~ "commit-field-placeholder"
      assert blank =~ "Add a description…"
    end

    test ":self markdown editing renders a mono textarea with a dirty-gated pill" do
      html =
        render_component(&CoreComponents.boxed_field/1,
          id: "bf-desc",
          markdown: true,
          multiline: true,
          editing: true,
          field: :description,
          form: Phoenix.Component.to_form(%{"description" => "raw"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )

      assert html =~ ~s(id="bf-desc-input")
      assert html =~ ~s(<textarea)
      assert html =~ "commit-field-mono"
      assert html =~ ~s(data-commit="cmd-enter")
      assert html =~ ~s(data-dirty-pill="true")
      assert html =~ ~s(class="commit-pill hidden")
      assert html =~ "⌘↵ · Esc"
    end

    test ":self always-editable with a prefix renders the prefixed box" do
      html =
        render_component(&CoreComponents.boxed_field/1,
          id: "bf-slug",
          field: :slug,
          form: Phoenix.Component.to_form(%{"slug" => "my-board"}, as: :board),
          prefix: "relay.app/",
          save_event: "save_board_slug",
          cancel_event: "cancel_board_slug"
        )

      assert html =~ "relay.app/"
      assert html =~ "commit-field-prefixed"
      assert html =~ ~s(id="bf-slug-input")
    end
  end

  describe "section_label/1" do
    test "renders a mono uppercase label with the default muted token" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.section_label>Owners</CoreComponents.section_label>
        """)

      assert html =~ "Owners"
      assert html =~ "font-mono"
      assert html =~ "uppercase"
      assert html =~ "text-base-content/60"
    end

    test "an accent class replaces the default muted token" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.section_label accent="text-secondary">AI Result</CoreComponents.section_label>
        """)

      assert html =~ "AI Result"
      assert html =~ "text-secondary"
      refute html =~ "text-base-content/60"
    end
  end
end
