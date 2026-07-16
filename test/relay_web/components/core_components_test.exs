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

  describe "member_stack/1" do
    test "renders one 24px ringed circle per member up to the limit" do
      members = [
        %{email: "ada@example.com", user: %{name: "Ada Lovelace"}},
        %{email: "guest@example.com", user: nil}
      ]

      html = render_component(&CoreComponents.member_stack/1, members: members)

      assert html =~ ~s(data-role="member-stack")
      # initials: "AL" for Ada Lovelace, "G" for the email-only invited member
      assert html =~ ">AL<"
      assert html =~ ">G<"
      # 24px circle with a 2px white ring per the mockup (lines ~114-124)
      assert html =~ "width:24px;height:24px"
      assert html =~ "box-shadow:0 0 0 2px oklch(1 0 0)"
      # avatar fill chroma matches the mockup's avatars builder
      # (`docs/designs/Relay Board.dc.html` line ~1590: `oklch(0.62 0.13 <hue>)`)
      assert html =~ "background:oklch(0.62 0.13 "
      refute html =~ ~s(data-role="member-overflow")
    end

    test "shows a +N overflow chip beyond the limit" do
      members = for i <- 1..6, do: %{email: "m#{i}@example.com", user: nil}

      html = render_component(&CoreComponents.member_stack/1, members: members, limit: 4)

      assert html =~ ~s(data-role="member-overflow")
      assert html =~ ">+2<"
      # overflow chip colors match the mockup's `moreStyle`
      # (`docs/designs/Relay Board.dc.html` line ~1596)
      assert html =~ "background:oklch(0.94 0.006 255)"
      assert html =~ "color:oklch(0.50 0.02 255)"
    end

    test "renders nothing for an empty list" do
      html = render_component(&CoreComponents.member_stack/1, members: [])
      refute html =~ ~s(data-role="member-stack")
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

    test "composer textarea matches the mockup's 13px font and its buttons are ≥44px tall" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      # 13px/1.4 borderless textarea per the mockup (Relay Board.dc.html ~L194-201)
      assert html =~ ~s(id="stage-col-1-compose-title")
      assert html =~ "text-[13px]"
      # Add / Cancel are comfortable tap targets
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
      assert html =~ "stage-drop"
      # the strip is a drop zone, not a stream list
      refute html =~ "stage-cards"
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

    test "collapsible renders a ghost collapse control in the expanded header (RLY-111)" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-5",
          name: "Code",
          type: :work,
          stage_id: 5,
          count: 2,
          collapsible: true
        )

      assert html =~ ~s(id="stage-col-5-collapse")
      assert html =~ ~s(phx-click="collapse_stage")
      assert html =~ ~s(phx-value-stage-id="5")
      assert html =~ ~s(aria-label="Collapse stage Code")
      assert html =~ "btn-ghost"
    end

    test "the collapse control does not render by default (RLY-111)" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7,
          count: 2
        )

      refute html =~ ~s(id="stage-col-1-collapse")
      refute html =~ ~s(phx-click="collapse_stage")
    end

    test "shows the violet AI-listening pill on an ai-enabled non-complete stage" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          type: :work,
          ai_enabled: true,
          category: :in_progress,
          stage_id: 4
        )

      assert html =~ ~s(id="stage-col-4-ai-listening")
      assert html =~ "Relay AI is listening on this stage"
      assert html =~ "oklch(0.46 0.14 292)"
    end

    test "hides the AI-listening pill on human and complete-category stages" do
      human =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          category: :unstarted,
          stage_id: 1
        )

      complete =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-8",
          name: "Done",
          type: :done,
          ai_enabled: true,
          category: :complete,
          stage_id: 8
        )

      refute human =~ "ai-listening"
      refute complete =~ "ai-listening"
    end

    test "the composer is owner-aware: AI stage hands to AI, human stage adds; both submit blue" do
      ai =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          type: :work,
          ai_enabled: true,
          category: :in_progress,
          stage_id: 4,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      human =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          category: :unstarted,
          stage_id: 1,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      assert ai =~ "Hand to AI"
      assert ai =~ "Describe work to hand to the AI"

      human_submit_text =
        human
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-1-compose-submit")
        |> LazyHTML.text()
        |> String.trim()

      assert human_submit_text == "Add"
      assert human =~ "Add work to Backlog"
      # Blue submit for both owners (decision 1).
      assert ai =~ "oklch(0.60 0.14 250)"
      assert human =~ "oklch(0.60 0.14 250)"
      # Enter-submit hook wired on the textarea.
      assert ai =~ ~s(phx-hook="SubmitOnEnter")
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
      assert html =~ ~s(class="sublane-strip stage-drop")
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
          status: :working,
          owners: [%{actor_type: :agent}]
        )

      assert html =~ ~s(data-status="working")
      assert html =~ "working"
      refute html =~ "working · "
      refute html =~ "height:5px;border-radius:3px;background:oklch(0.93 0.02 292)"
    end

    test "a human-active card in an AI stage shows no mismatch (the mover owns it)" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c4",
          ref: "RLY-4",
          title: "T",
          active_owner: :human,
          status: :ready
        )

      refute html =~ "card-mismatch"
      refute html =~ "border-l-error"
    end

    test "an AI-active card in a human stage shows no mismatch (no hand-back)" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c5",
          ref: "RLY-5",
          title: "T",
          active_owner: :ai,
          status: :ready
        )

      refute html =~ "card-mismatch"
      refute html =~ "border-l-error"
    end

    test "no mismatch without an active owner, even in an AI stage" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c6",
          ref: "RLY-6",
          title: "T"
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
          acceptance_criteria: nil,
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

    test "below 720px the whole drawer panel scrolls (header included); ≥720px keeps two columns" do
      attrs = drawer_attrs(%{status: :ready}, %{})
      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Panel IS the scroll container below 720px (header scrolls with content); at drawer: it
      # stops scrolling and hands scroll back to the two columns (pinned header restored).
      assert html =~
               "drawer-panel flex h-dvh w-full flex-col overflow-y-auto bg-base-100 shadow-xl drawer:overflow-hidden drawer:w-[min(760px,94vw)]"

      # Body wrapper: content-sized column below 720px (no own scroll); flex-1 two-column row at drawer:.
      assert html =~
               "flex min-h-0 flex-none flex-col drawer:flex-1 drawer:flex-row drawer:overflow-hidden"

      # Regression: the body no longer owns the scroll below 720px.
      refute html =~ "flex min-h-0 flex-1 flex-col overflow-y-auto drawer:flex-row drawer:overflow-hidden"

      # Main column: content-sized + no own scroll below 720px; flex-1 + own scroll at drawer: (UNCHANGED).
      assert html =~ ~s(id="card-drawer-main")

      assert html =~
               "flex min-w-0 flex-none flex-col gap-6 p-5 drawer:flex-1 drawer:overflow-y-auto"

      # Properties rail: full-width top-border below 720px; side panel + own scroll at drawer: (UNCHANGED).
      assert html =~ ~s(id="card-drawer-rail")

      assert html =~
               "flex w-full shrink-0 flex-col gap-5 border-t border-base-300 bg-base-200/30 p-5 text-sm drawer:w-[220px] drawer:overflow-y-auto drawer:border-l drawer:border-t-0"

      # Regression: the old lg/1024 stack point is fully gone from the drawer.
      refute html =~ "lg:flex-row"
      refute html =~ "lg:w-[220px]"
      refute html =~ "lg:w-[min(760px,94vw)]"
    end

    test "sub-tasks header puts label, count and a capped inline bar on one row" do
      attrs =
        drawer_attrs(
          %{sub_tasks: [%{id: 1, title: "a", done: true}, %{id: 2, title: "b", done: false}]},
          %{}
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Header is a single inline row: label · count · bar (no justify-between).
      assert html =~ ~s(<div class="flex items-center gap-2">)
      assert html =~ ~s(id="sub-tasks-count")
      # The progress bar is inline in that row: flex-1 but capped at 120px, 4px, green fill.
      assert html =~ "h-1 max-w-[120px] flex-1 overflow-hidden rounded-full bg-base-300"
      assert html =~ "h-full rounded-full bg-success"
      assert html =~ "width:50%"
    end

    test "each sub-task renders as a boxed, bordered, whole-row toggle button" do
      attrs = drawer_attrs(%{sub_tasks: [%{id: 1, title: "a", done: false}]}, %{})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # The row <li> keeps its stable id...
      assert html =~ ~s(id="sub-task-1")
      # ...and the whole boxed row is a full-width button carrying the toggle plumbing.
      assert html =~ ~s(phx-click="toggle_sub_task")
      assert html =~ ~s(phx-value-id="1")

      assert html =~
               "flex w-full items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-2 py-1.5 text-left"
    end

    test "a done sub-task shows a filled green check and struck-through muted label" do
      attrs =
        drawer_attrs(
          %{
            sub_tasks: [
              %{id: 1, title: "done one", done: true},
              %{id: 2, title: "open one", done: false}
            ]
          },
          %{}
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Done check box is filled green; done label is muted + struck through.
      assert html =~ "border-success bg-success text-white"
      assert html =~ "text-base-content/50 line-through"
      assert html =~ "hero-check"
    end

    test "no sub-tasks section when the card has none" do
      attrs = drawer_attrs(%{sub_tasks: []}, %{})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      refute html =~ ~s(id="sub-tasks")
    end

    test "the acceptance-criteria section renders before spec, labelled, on the teal accent bar" do
      attrs =
        drawer_attrs(
          %{acceptance_criteria: "### 1. It works\n1. Expect: **yes**", spec: "the spec"},
          %{}
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="card-drawer-acceptance-criteria")
      assert html =~ "Acceptance Criteria"
      # teal accent bar — distinct from spec's bg-primary and plan's bg-secondary
      assert html =~ ~s(class="commit-field-accent bg-accent")

      # DOM order: acceptance criteria sits above spec (the review-gate read order)
      {ac_idx, _} = :binary.match(html, ~s(id="card-drawer-acceptance-criteria"))
      {spec_idx, _} = :binary.match(html, ~s(id="card-drawer-spec"))
      assert ac_idx < spec_idx
    end

    test "acceptance criteria collapses to a preview with a Show more toggle" do
      attrs = drawer_attrs(%{acceptance_criteria: "### 1. It works\n1. Expect: **yes**"}, %{})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="card-drawer-acceptance-criteria-show-more")
      assert html =~ ~s(id="card-drawer-acceptance-criteria-view")
      assert html =~ "<strong>yes</strong>"
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

    test ":self markdown editing renders a mono textarea with Save/Cancel + hint" do
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
      refute html =~ "data-dirty-pill"
      refute html =~ "commit-pill"
      assert html =~ ~s(id="bf-desc-save")
      assert html =~ ~s(id="bf-desc-cancel")
      assert html =~ "Markdown supported"
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

  describe "boxed_field/1 editing commit affordance (RLY-58)" do
    defp edit_attrs do
      [
        id: "bf",
        commit: :self,
        markdown: true,
        multiline: true,
        editing: true,
        field: :description,
        form: Phoenix.Component.to_form(%{"description" => "raw source"}, as: :card),
        edit_event: "edit",
        save_event: "save",
        cancel_event: "cancel"
      ]
    end

    test "renders Save/Cancel buttons + markdown hint, not the floating pill" do
      html = render_component(&CoreComponents.boxed_field/1, edit_attrs())

      assert html =~ ~s(id="bf-save")
      assert html =~ ~s(type="submit")
      assert html =~ ~s(id="bf-cancel")
      assert html =~ ~s(phx-click="cancel")
      assert html =~ "btn btn-sm btn-primary"
      assert html =~ "Markdown supported"
      assert html =~ "commit-field-hint"
      refute html =~ "commit-pill"
    end

    test "the textarea keeps the hook wiring but drops the dirty-pill flag" do
      html = render_component(&CoreComponents.boxed_field/1, edit_attrs())

      assert html =~ ~s(id="bf-input")
      assert html =~ ~s(data-cancel-id="bf-cancel")
      assert html =~ ~s(data-commit="cmd-enter")
      refute html =~ "data-dirty-pill"
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

  describe ".md markdown stylesheet (RLY-58)" do
    @app_css File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    @storybook_css File.read!(Path.expand("../../../assets/css/storybook.css", __DIR__))

    test "app.css restyles .md to the design-system look" do
      # body ~13px / 1.55, slightly muted
      assert @app_css =~ ~r/\.md\s*\{[^}]*font-size:\s*13px/
      assert @app_css =~ ~r/\.md\s*\{[^}]*line-height:\s*1\.55/
      # disc bullets with a muted marker
      assert @app_css =~ ".md ul { list-style: disc; }"
      assert @app_css =~ ".md li::marker"
      # links use the primary token, underlined
      assert @app_css =~ ".md a { color: var(--color-primary); text-decoration: underline; }"
      # headings are a strong label, not oversized
      assert @app_css =~ ~r/\.md h1[^\n]*\{[^}]*font-weight:\s*700/
    end

    test "storybook.css mirrors the .md block (RLY-58 gap closed)" do
      assert @storybook_css =~ ".md ul { list-style: disc; }"
      assert @storybook_css =~ ".md a { color: var(--color-primary); text-decoration: underline; }"
      assert @storybook_css =~ ".md li::marker"
    end
  end

  describe "card_drawer/1 body_loading" do
    defp loading_drawer_assigns(overrides \\ %{}) do
      base = %{
        id: "d",
        ref: "RLY-68",
        card: %{
          title: "Optimistic drawer",
          description: nil,
          acceptance_criteria: nil,
          spec: nil,
          plan: nil,
          tag: "perf",
          status: :needs_input,
          blocked_since: ~U[2026-07-12 09:00:00Z],
          branch: nil,
          pr_url: nil,
          rejection: nil,
          sub_tasks: [],
          ai_result: nil,
          owners: [],
          inserted_at: ~U[2026-07-12 09:00:00Z],
          updated_at: ~U[2026-07-12 09:00:00Z]
        },
        stage_name: "Code",
        stage_owner: :ai,
        close_patch: "/board/x",
        title_form: Phoenix.Component.to_form(%{"title" => "Optimistic drawer"}, as: :card),
        answer_form: Phoenix.Component.to_form(%{"body" => ""}, as: :answer),
        conversation: [],
        activity: [],
        comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment),
        body_loading: true
      }

      Map.merge(base, overrides)
    end

    test "renders skeletons for the heavy sections while loading" do
      html = render_component(&CoreComponents.card_drawer/1, loading_drawer_assigns())

      assert html =~ ~s(id="d-description-skeleton")
      assert html =~ ~s(id="d-spec-skeleton")
      assert html =~ ~s(id="card-plan-skeleton")
      assert html =~ ~s(id="ai-result-skeleton")
      assert html =~ ~s(id="needs-input-question-skeleton")
      assert html =~ ~s(id="d-conversation-loading")
      assert html =~ ~s(id="d-activity-loading")
      assert html =~ "skeleton"
      # heavy content is suppressed while loading
      refute html =~ ~s(id="d-description-view")
      # the streamed <ol> is gated off during loading
      refute html =~ ~s(id="d-conversation")
    end

    test "renders the real sections and no skeletons when not loading" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          loading_drawer_assigns(%{
            body_loading: false,
            card: %{
              loading_drawer_assigns().card
              | description: "hello",
                status: :ready,
                blocked_since: nil
            }
          })
        )

      refute html =~ "skeleton"
      refute html =~ ~s(id="d-description-skeleton")
      assert html =~ ~s(id="d-description")
    end
  end

  # RLY-112 — the collapsed log strip. Every value below is pinned to
  # docs/designs/Relay Card Activity.dc.html §02 (lines ~87-128); the light theme's
  # --color-secondary/-warning/-error are byte-identical to the artboard's violet/amber/rose.
  # Module-level, and `log_at` is computed per call: a `@log_at DateTime.utc_now()`
  # module attribute would freeze at COMPILE time, so "now" would drift to "3d" once
  # the build is a few days old.
  defp strip(health, opts \\ []) do
    render_component(
      &CoreComponents.board_card/1,
      Keyword.merge(
        [
          id: "cards-1",
          ref: "RLY-3",
          title: "Migrate 40 blog posts",
          status: :working,
          active_owner: :ai,
          health: health,
          log_text: "uploaded 24/40 posts",
          log_at: DateTime.utc_now()
        ],
        opts
      )
    )
  end

  describe "board_card/1 log strip" do
    test "health :none renders no strip at all and keeps today's working label" do
      html = strip(:none)

      refute html =~ "card-RLY-3-log-strip"
      assert html =~ ~s(class="card-status")
      assert html =~ "working"
    end

    test "the strip replaces the working label when health is live" do
      html = strip(:live)

      assert html =~ ~s(id="card-RLY-3-log-strip")
      assert html =~ "uploaded 24/40 posts"
      refute html =~ ~s(class="card-status")
    end

    test "live is violet with a pulsing dot and a tinted box" do
      html = strip(:live)

      assert html =~ "oklch(0.985 0.012 292)"
      assert html =~ "animation:relaypulse 1.4s ease-in-out infinite"
      assert html =~ "var(--color-secondary)"
      assert html =~ "oklch(0.44 0.08 292)"
    end

    # 2026-07-16 rejection: age never recolors the card. Stale mutes the strip itself —
    # lighter-gray text, still gray dot — and touches nothing outside it.
    test "stale mutes the strip to gray — still dot, lighter-gray text, no amber anywhere" do
      html = strip(:stale)

      assert html =~ ~s(data-health="stale")
      assert html =~ "background:oklch(0.72 0.02 255)"
      assert html =~ "color:oklch(0.60 0.02 255)"
      refute html =~ "animation:relaypulse"
      refute html =~ "var(--color-warning)"
      refute html =~ "oklch(0.86 0.06 70)"
      refute html =~ "0 1px 3px oklch(0.6 0.08 70/0.12)"
    end

    # A failure is an event, not an age: the strip keeps §02's rose + white ! disc,
    # but the card shell stays as quiet as everyone else's.
    test "stopped keeps the rose strip and ! disc, but the card shell stays quiet" do
      html = strip(:stopped, log_text: "agent stopped")

      assert html =~ ~s(data-health="stopped")
      assert html =~ "var(--color-error)"
      assert html =~ "oklch(0.97 0.03 20)"
      assert html =~ "agent stopped"
      refute html =~ "animation:relaypulse"
      refute html =~ "oklch(0.86 0.07 20)"
      refute html =~ "0 1px 3px oklch(0.6 0.1 15/0.12)"
    end

    # Q6→C: the artboard draws a Retry pill on the stopped strip; it is out of scope.
    test "stopped renders NO Retry affordance" do
      refute strip(:stopped, log_text: "agent stopped") =~ "Retry"
    end

    test "the accent border stays status-keyed for every health state" do
      assert strip(:live) =~ "border-l-secondary"
      assert strip(:stale) =~ "border-l-secondary"
      assert strip(:stopped) =~ "border-l-secondary"
      refute strip(:stale) =~ "border-l-warning"
      refute strip(:stopped) =~ "border-l-error"
    end

    test "the card shell border and shadow are constant across health states" do
      for health <- [:none, :live, :stale, :stopped] do
        html = strip(health)

        assert html =~ "border:1px solid var(--color-base-300)"
        assert html =~ "box-shadow:0 1px 2px oklch(0.55 0.03 255/0.05)"
      end
    end

    test "the strip text ellipsizes and the time is mono and right-aligned" do
      html = strip(:live)

      assert html =~ "text-overflow:ellipsis"
      assert html =~ "white-space:nowrap"
      assert html =~ "font-family:var(--font-mono)"
    end

    test "the relative time reads now for a fresh line" do
      assert strip(:live) =~ "now"
    end

    test "the relative time compacts to m / h / d" do
      assert strip(:live, log_at: DateTime.add(DateTime.utc_now(), -8 * 60, :second)) =~ "8m"
      assert strip(:stale, log_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)) =~ "2h"
      assert strip(:stale, log_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)) =~ "3d"
    end

    # The artboard's §02 live card shows the bar AND the strip. The progress bar is
    # derived from sub-tasks and is very much alive — the strip replaces only the label.
    test "the progress bar survives alongside the strip" do
      html = strip(:live, progress: 62)

      assert html =~ "width:62%"
      assert html =~ ~s(id="card-RLY-3-log-strip")
    end
  end

  describe "avatar/1" do
    test "renders the photo when src is present" do
      html =
        render_component(&CoreComponents.avatar/1,
          src: "https://lh3.example.com/p.png",
          name: "Dana Kim",
          email: "dana@acme.co"
        )

      assert html =~ ~s(data-avatar="photo")
      assert html =~ ~s(src="https://lh3.example.com/p.png")
      assert html =~ ~s(referrerpolicy="no-referrer")
      assert html =~ ~s(alt="Dana Kim")
      refute html =~ ">DK<"
    end

    test "falls back to white initials on the tint fill when there is no photo" do
      html = render_component(&CoreComponents.avatar/1, name: "Dana Kim", email: "dana@acme.co")

      assert html =~ ~s(data-avatar="initials")
      assert html =~ ">DK<"
      assert html =~ "color:oklch(1 0 0)"
    end

    test "derives initials from the email local part when there is no name (the [E4] rule)" do
      assert render_component(&CoreComponents.avatar/1, email: "dana@acme.co") =~ ">D<"
      assert render_component(&CoreComponents.avatar/1, email: "dana.kim@acme.co") =~ ">DK<"
    end

    test "never crashes: nil or blank name and email render ?" do
      assert render_component(&CoreComponents.avatar/1, name: nil, email: nil) =~ ">?<"
      assert render_component(&CoreComponents.avatar/1, name: "   ", email: "") =~ ">?<"
    end

    test "the AI renders the violet dot mark and ignores src" do
      html =
        render_component(&CoreComponents.avatar/1,
          actor: :ai,
          src: "https://example.com/never.png",
          size: 22
        )

      assert html =~ ~s(data-avatar="ai")
      assert html =~ "background:var(--color-secondary)"
      # round(22 * 0.36) = 8px mark with the 1.5px white border, as the card cluster draws it
      assert html =~ "width:8px;height:8px;border-radius:50%;border:1.5px solid oklch(1 0 0)"
      refute html =~ "<img"
    end

    test "identity tint hashes the email — same email, same hue at any size" do
      a = render_component(&CoreComponents.avatar/1, email: "dana@acme.co", size: 24)
      b = render_component(&CoreComponents.avatar/1, email: "dana@acme.co", size: 34)

      [hue] = Regex.run(~r/background:oklch\(0\.62 0\.13 (\d+)\)/, a, capture: :all_but_first)
      assert b =~ "background:oklch(0.62 0.13 #{hue})"
    end

    test "role tint fills with the primary token" do
      html = render_component(&CoreComponents.avatar/1, name: "Dana Kim", tint: :role)
      assert html =~ "background:var(--color-primary)"
    end

    test "sizes the circle and text from the size attr" do
      html = render_component(&CoreComponents.avatar/1, name: "Dana Kim", size: 44)
      assert html =~ "width:44px;height:44px"
      assert html =~ "font-size:18px"
    end

    test "ring and grayed compose the existing owner-cluster treatments" do
      html =
        render_component(&CoreComponents.avatar/1,
          name: "Dana Kim",
          ring: "var(--color-primary)",
          grayed: true
        )

      assert html =~ "box-shadow:0 0 0 3.5px var(--color-primary), 0 0 0 2px var(--color-base-100)"
      assert html =~ "filter:grayscale(1)"
      assert html =~ "opacity:0.5"
    end
  end

  describe "avatar call sites (RLY-90)" do
    test "owner_avatars renders the owner's photo when they have one" do
      html =
        render_component(&CoreComponents.owner_avatars/1,
          active_owner: :human,
          owners: [
            %{
              actor_type: :user,
              user: %{name: "Dana Kim", email: "dana@acme.co", avatar_url: "https://lh3.example.com/p.png"}
            }
          ]
        )

      assert html =~ ~s(data-avatar="photo")
      assert html =~ ~s(src="https://lh3.example.com/p.png")
      # the baton ring survives the refactor
      assert html =~ "0 0 0 3.5px var(--color-primary)"
    end

    test "member_stack renders a member's photo and hashes invited rows on email" do
      members = [
        %{
          email: "dana@acme.co",
          user: %{name: "Dana Kim", email: "dana@acme.co", avatar_url: "https://lh3.example.com/p.png"}
        },
        %{email: "guest@example.com", user: nil}
      ]

      html = render_component(&CoreComponents.member_stack/1, members: members)

      assert html =~ ~s(data-avatar="photo")
      assert html =~ ">G<"
    end
  end
end
