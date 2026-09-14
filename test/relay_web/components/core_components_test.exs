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
      # 24px circle with a 2px separation ring per the mockup (lines ~114-124)
      assert html =~ "width:24px;height:24px"
      assert html =~ "box-shadow:0 0 0 2px var(--color-base-100)"
      # avatar fill is the one identity-color formula (RE237: oklch() held at fixed perceptual
      # lightness so every hue stays legible under the fixed neutral-content ink — see
      # CoreComponents.identity_color_for_hue/1). `Relay Board.dc.html` line ~1590.
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
      assert html =~ "background:var(--color-base-300)"
      assert html =~ "color:color-mix(in oklab, var(--color-base-content) 70%, transparent)"
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

    test "a stopped card's log strip shows the failure detail, not the fallback phrase" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "card-3",
          ref: "RLY-5",
          title: "Dead run",
          status: :failed,
          health: :stopped,
          log_text: "mix precommit failed: 3 tests, 1 failure"
        )

      assert html =~ "mix precommit failed: 3 tests, 1 failure"
      refute html =~ "the agent stopped"
    end

    test "the ref stays at the bottom left when a run face is present (RE321)" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "card-run",
          ref: "RE321",
          title: "CSV export of the board",
          status: :working,
          active_owner: :ai,
          owners: [%{actor_type: :agent}],
          run:
            {:run,
             %{
               status: :running,
               node_index: 2,
               node_count: 4,
               current_node: "implement",
               flow_key: "code",
               flow_version: 3,
               attempts: 2
             }}
        )

      assert html =~ ~s(id="card-RE321-run-face")
      assert html |> meta_row_ref() |> LazyHTML.text() |> String.trim() == "RE321"
    end

    test "the ref stays at the bottom left on queued, parked, needs_input, in_review, and Done cards (RE321)" do
      variants = [
        %{status: :ready, run: {:queued, %{key: "code"}}},
        %{
          status: :needs_input,
          question: "Full text?",
          run: {:run, %{status: :parked, current_node: "brainstorm", flow_key: "spec", flow_version: 2, attempts: 1}}
        },
        %{status: :needs_input, question: "Which locales first?", active_owner: :ai, owners: [%{actor_type: :agent}]},
        %{status: :in_review},
        %{status: :ready, stage_type: :done, done: true, owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}]}
      ]

      for extra <- variants do
        html =
          render_component(
            &CoreComponents.board_card/1,
            Map.merge(%{id: "card-state", ref: "RE7", title: "Every state"}, extra)
          )

        assert html |> meta_row_ref() |> LazyHTML.text() |> String.trim() == "RE7",
               "expected the ref first in the meta row for #{inspect(extra)}"
      end
    end

    test "the busiest meta row wraps inside the card and never truncates the ref (RE321)" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "card-busy",
          ref: "RE321",
          title: "Every meta-row item at once",
          tag: "a-very-long-free-text-tag-name",
          status: :ready,
          category: :unstarted,
          vote_count: 12,
          blocked_count: 3,
          active_owner: :ai,
          owners: [%{actor_type: :user, user: %{name: "Dana Kim"}}, %{actor_type: :agent}]
        )

      doc = LazyHTML.from_fragment(html)
      style = fn selector -> doc |> LazyHTML.query(selector) |> LazyHTML.attribute("style") end

      [meta] = style.("article.board-card > .card-meta:last-child")
      assert meta =~ "display:flex"
      assert meta =~ "flex-wrap:wrap"
      assert meta =~ "gap:6px 7px"

      [ref] = style.(".card-meta > .card-ref:first-child")
      assert ref =~ "flex:0 0 auto"
      assert ref =~ "white-space:nowrap"
      refute ref =~ "overflow:hidden"
      refute ref =~ "text-overflow"

      [tag] = style.(".card-meta > .card-tag")
      assert tag =~ "min-width:0"
      assert tag =~ "max-width:100%"
      assert tag =~ "overflow:hidden"
      assert tag =~ "text-overflow:ellipsis"
      assert tag =~ "white-space:nowrap"

      [chip] = style.(".card-meta > .card-blocked-chip")
      assert chip =~ "white-space:nowrap"
      assert chip =~ "flex:0 0 auto"

      assert doc |> LazyHTML.query(".card-meta > .card-votes") |> Enum.count() == 1
      # A flex:1 spacer keeps its zero basis on the current line, so a wrapped
      # avatar cluster would land at the left. margin-left:auto on the cluster
      # itself right-aligns it on whichever line it ends up on.
      [owners] = style.(".card-meta > .card-owners")
      assert owners =~ "margin-left:auto"
      assert doc |> LazyHTML.query(~s(.card-meta > span[style="flex:1;"])) |> Enum.count() == 0
    end

    defp meta_row_ref(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("article.board-card > .card-meta:last-child > .card-ref:first-child")
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
      assert html =~ "RLY1"
      assert html =~ "#infra"
      assert html =~ ~s(id="cards-2")
      assert html =~ "RLY2"
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
      assert html =~ "border:1px dashed var(--color-field-border)"
      assert html =~ "background:var(--color-field-hover)"
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

    test "the stage name is the collapse control on every expanded stage (RLY-145)" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 7,
          count: 2
        )

      assert html =~ ~s(id="stage-col-1-name")
      assert html =~ ~s(phx-click="collapse_stage")
      assert html =~ ~s(phx-value-stage-id="7")
      assert html =~ ~s(aria-label="Collapse stage Backlog")
      assert html =~ "cursor:pointer"
    end

    test "the RLY-111 chevron collapse button never renders (RLY-145)" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-5",
          name: "Code",
          type: :work,
          stage_id: 5,
          count: 2
        )

      refute html =~ ~s(id="stage-col-5-collapse")
      refute html =~ "hero-chevron-left"
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
      assert html =~ "color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content))"
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
      assert ai =~ "background:var(--color-primary)"
      assert human =~ "background:var(--color-primary)"
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
      assert html =~ "color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"
      assert html =~ "border-left:1px solid color-mix(in oklab, var(--color-warning) 35%, var(--color-base-100))"
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
            {:queued, "badge-ghost", "queued"},
            {:in_review, "badge-primary", "in review"}
          ] do
        html = render_component(&CoreComponents.status_badge/1, status: status)

        assert html =~ class
        assert html =~ label
        assert html =~ ~s(data-status="#{status}")
      end
    end

    # The badge re-states a closed set the schema owns. When it drifted, opening
    # any scheduler-queued card raised FunctionClauseError and took the whole
    # card drawer down — so drive the vocabulary from its source, not a copy.
    test "renders every status the card schema allows" do
      for status <- Schemas.Card.statuses() do
        html = render_component(&CoreComponents.status_badge/1, status: status)

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

    test "a failed card renders the error badge and reads FAILED" do
      html = render_component(&CoreComponents.status_badge/1, status: :failed)

      assert html =~ "badge-error"
      assert html =~ "FAILED"
      assert html =~ ~s(data-status="failed")
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

    test "failed paints the rose/error accent, no answer composer chips" do
      html =
        render_component(&CoreComponents.board_card/1, %{
          id: "c",
          ref: "RLY-5",
          title: "T",
          status: :failed
        })

      assert html =~ "border-l-error"
      refute html =~ "card-needs-input"
      refute html =~ "card-review-chip"
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
          board_slug: "test-board",
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

    defp drawer_note(overrides \\ %{}) do
      struct(
        %Schemas.Comment{
          id: 1,
          actor_type: :user,
          user: %Schemas.User{id: 1, name: "Ada Lovelace", email: "ada@example.com"},
          kind: :comment,
          body: "Took the fixture generation offline.",
          inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        },
        overrides
      )
    end

    defp notes_attrs(notes, extra \\ %{}) do
      streamed = Enum.map(notes, &{"timeline-comment-#{&1.id}", &1})

      drawer_attrs(
        %{},
        Map.merge(%{conversation: streamed, note_count: length(streamed)}, extra)
      )
    end

    test "the Notes header carries the accent bar, eyebrow, count and READ BY EVERY AGENT chip" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([drawer_note()]))

      assert html =~ ~s(id="card-drawer-notes")
      # accent bar: 3px x 13px, primary (artboard: oklch(0.55 0.1 255), shipped as the token)
      assert html =~ "h-[13px] w-[3px] shrink-0 rounded-sm bg-primary"
      assert html =~ "Notes"
      refute html =~ "Conversation"
      # count label: mono 10px at 45% (artboard line 208)
      assert html =~ ~s(id="card-drawer-note-count")
      assert html =~ "font-mono text-[10px] text-base-content/45"
      assert html =~ "1 note"
      # chip: mono 9.5px/600, 0.04em, 4px radius, 2px/7px padding, success tint (artboard line 210)
      assert html =~
               "rounded bg-success/10 px-[7px] py-[2px] font-mono text-[9.5px] font-semibold tracking-[0.04em] text-success"

      assert html =~ "READ BY EVERY AGENT"
    end

    test "the count label pluralises" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          notes_attrs([drawer_note(), drawer_note(%{id: 2})])
        )

      assert html =~ "2 notes"
    end

    test "the list and the composer sit inside one bordered box" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([drawer_note()]))

      # artboard line 211: 1px border, 8px radius, 13px/14px padding, 13px column gap
      assert html =~
               "flex flex-col gap-[13px] rounded-lg border border-base-300 bg-base-100 px-[14px] py-[13px]"
    end

    test "a note is a 22px role-tinted avatar, a 12px name, a relative time and bubble-free prose" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([drawer_note()]))

      # 22px avatar (was 28), human => primary tint
      assert html =~ "width:22px;height:22px"
      assert html =~ "background:var(--color-primary)"
      # row geometry from artboard line 213
      assert html =~ "timeline-entry flex items-start gap-[10px]"
      # 12px semibold name (was 13px)
      assert html =~ ~s(<span class="timeline-author text-[12px] font-semibold">)
      # relative time, mono 10px at 45%, with the absolute time one hover away
      assert html =~ "2h ago"
      assert html =~ ~s(class="timeline-time font-mono text-[10px] text-base-content/45")
      assert html =~ ~s(title=")
      # prose body: no bubble, no padding — .md already supplies 13px/20.15px/85%
      assert html =~ ~s(class="timeline-comment-body md")
      refute html =~ "bg-base-200/60"
    end

    test "an agent note is violet-tinted" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          notes_attrs([drawer_note(%{actor_type: :agent, user: nil})])
        )

      assert html =~ "background:var(--color-secondary)"
      assert html =~ "Relay AI"
    end

    test "a question note keeps its amber chip and amber body box" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          notes_attrs([drawer_note(%{kind: :question, body: "Which colour?"})])
        )

      assert html =~ "QUESTION"
      assert html =~ "color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"

      assert html =~
               "border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));"

      assert html =~ "timeline-comment-body md rounded-lg px-3 py-2"
    end

    test "with no notes the list reads No notes yet" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([]))

      assert html =~ "No notes yet"
      refute html =~ "No comments yet"
      assert html =~ "0 notes"
    end

    test "the composer is the artboard's bordered row with an inline Add note button" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([]))

      # artboard line 228: 7px radius, 7px/8px/7px/11px padding, 8px gap
      assert html =~
               "flex items-start gap-2 rounded-[7px] border border-base-300 bg-base-100 py-[7px] pl-[11px] pr-2"

      assert html =~ ~s(id="card-drawer-comment-input")
      assert html =~ ~s(phx-hook="SubmitOnCmdEnter")
      assert html =~ ~s(rows="2")
      assert html =~ "What you did, what you found, what’s left…"
      assert html =~ "text-[12.5px]"
      # artboard line 229: 27px tall, 6px radius, 11.5px/600 label
      assert html =~ "h-[27px] shrink-0 rounded-md border border-base-300 px-3 text-[11.5px] font-semibold"
      assert html =~ "Add note"
      refute html =~ "Write a comment…"
    end

    test "the caption under the box states what a note is" do
      html = render_component(&CoreComponents.card_drawer/1, notes_attrs([]))

      assert html =~ "font-mono text-[10.5px] leading-[1.5] text-base-content/50"
      assert html =~ "Notes are card content, not chat — they go into every agent’s context."
      # D5: the artboard's second sentence is Talk demo copy, out of scope here
      refute html =~ "open Talk"
    end

    test "an archived card renders no composer" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          notes_attrs([drawer_note()], %{archived: true})
        )

      refute html =~ "Add note"
      refute html =~ ~s(id="card-drawer-comment-form")
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

      # Properties rail: full-width top-border below 720px; side panel + own scroll at drawer:.
      # RE282 — 224px wide, 20px/18px padding, 18px row gap (Relay Card Detail v5.dc.html rail).
      assert html =~ ~s(id="card-drawer-rail")

      assert html =~
               "flex w-full shrink-0 flex-col gap-[18px] border-t border-base-300 bg-base-200/30 px-[18px] py-5 text-sm drawer:w-[224px] drawer:overflow-y-auto drawer:border-l drawer:border-t-0"

      refute html =~ "drawer:w-[220px]"

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
      assert html =~ "border-success bg-success text-success-content"
      assert html =~ "text-base-content/55 line-through"
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

    test "the header ⋯ overflow menu matches the v5 artboard and carries only a danger Archive" do
      attrs = drawer_attrs(%{}, %{overflow_open: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Relay Card Detail v5.dc.html line ~73 — 28×28 bordered square, 17px dots.
      assert html =~ ~s(id="card-drawer-overflow")
      assert html =~ "flex size-7 items-center justify-center rounded-[7px] border border-base-300 bg-base-100 p-0"
      assert html =~ "hero-ellipsis-horizontal size-[17px]"

      # line ~75 — top:33px;right:0;z-index:22;width:190px;radius 9px;padding 6px;gap 1px.
      assert html =~ ~s(id="card-drawer-overflow-menu")

      assert html =~
               "absolute right-0 top-[33px] z-[22] flex w-[190px] flex-col gap-px rounded-[9px] border border-base-300 bg-base-100 p-1.5"

      assert html =~ "box-shadow:0 8px 28px color-mix(in oklab, var(--color-neutral) 16%, transparent);"

      # line ~700 menuItems — 6px 9px, radius 6px, 12.5px/500, danger red, real hover.
      assert html =~ ~s(id="archive-card-button")
      assert html =~ "rounded-md px-[9px] py-1.5 text-left text-[12.5px] font-medium text-error hover:bg-base-300/50"

      # Decided in review: no Duplicate, no Copy link.
      refute html =~ "Duplicate"
      refute html =~ "Copy link"
    end

    test "an archived card renders no ⋯ overflow button at all" do
      attrs = drawer_attrs(%{}, %{archived: true, overflow_open: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      refute html =~ ~s(id="card-drawer-overflow")
      refute html =~ ~s(id="archive-card-button")
    end

    test "the header stage chip is a nowrap trigger with the v5 artboard's geometry and its owner tint" do
      attrs =
        drawer_attrs(%{}, %{
          stages: [
            %{id: 1, name: "Plan", current?: false},
            %{id: 2, name: "Code", current?: true}
          ]
        })

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # Relay Card Detail v5.dc.html line ~46 — height:20px;padding:0 7px 0 9px;radius 4px;
      # border:none;12px/500;gap 5px, plus an 11px chevron. white-space:nowrap is RE281's
      # change-23 rule: a chip never wraps inside a fixed-height pill.
      assert html =~ ~s(id="card-drawer-stage-chip")

      assert html =~
               "drawer-stage-chip badge badge-sm h-5 gap-[5px] whitespace-nowrap rounded-[4px] border-none py-0 pl-[9px] pr-[7px] text-[12px] font-medium badge-secondary"

      assert html =~ "hero-chevron-down size-[11px]"
    end

    test "the stage popover matches the v5 artboard and marks the current stage inert" do
      attrs =
        drawer_attrs(%{}, %{
          stage_menu_open: true,
          stages: [
            %{id: 1, name: "Plan", current?: false},
            %{id: 2, name: "Code", current?: true}
          ]
        })

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      # line ~48 — top:26px;left:0;z-index:24;width:214px;radius 9px;padding 6px;gap 5px.
      assert html =~
               "absolute left-0 top-[26px] z-[24] flex w-[214px] flex-col gap-[5px] rounded-[9px] border border-base-300 bg-base-100 p-1.5"

      assert html =~ "box-shadow:0 8px 28px color-mix(in oklab, var(--color-neutral) 16%, transparent);"

      # line ~49 — mono 9.5px/600, .6px tracking, uppercase eyebrow.
      assert html =~ "px-1 pt-[3px] font-mono text-[9.5px] font-semibold uppercase tracking-[0.6px] text-base-content/50"

      # line ~50 — the filter input.
      assert html =~ ~s(id="card-drawer-stage-filter")
      assert html =~ ~s(placeholder="Filter stages…")

      # RE306 round 2 — the menu must take the caret with it. Without this the menu opened with
      # focus still on the chip <button>, so everything typed at "Filter stages…" went to the
      # window instead and the `t` in it switched the drawer to Talk.
      [filter_tag] = Regex.run(~r/<input[^>]*id="card-drawer-stage-filter"[^>]*>/, html)
      assert filter_tag =~ ~s(phx-mounted="[[&quot;focus&quot;,{}]]")
      assert html =~ "w-full rounded-md border border-base-300 bg-base-200/40 px-[9px] py-1.5 text-[12px] outline-none"

      # line ~51 — max-height:230px;overflow-y:auto;gap:1px.
      assert html =~ "flex max-h-[230px] flex-col gap-px overflow-y-auto"

      # line ~692 — non-current row: 12.5px/500, muted ink, 6px grey dot, real hover.
      assert html =~
               ~s(<button type="button" id="card-drawer-move-to-1")

      assert html =~
               "flex w-full items-center gap-2 rounded-md px-[9px] py-1.5 text-left text-[12.5px] font-medium text-base-content/80 hover:bg-base-300/50"

      assert html =~ ~s(<span class="size-[6px] flex-none rounded-[2px] bg-base-300">)

      # line ~692-694 — current row: weight 600, full ink, violet dot, mono violet `current`
      # tag pinned right, and NOT a button so it cannot be re-selected.
      assert html =~ ~s(<span id="card-drawer-move-to-2")
      refute html =~ ~s(<button type="button" id="card-drawer-move-to-2")
      assert html =~ ~s(<span class="size-[6px] flex-none rounded-[2px] bg-secondary">)
      assert html =~ "ml-auto flex-none font-mono text-[10px] text-secondary"
      assert html =~ "current"
    end

    test "an archived card's chip is a plain span with no chevron and no popover" do
      attrs =
        drawer_attrs(%{}, %{
          archived: true,
          stage_menu_open: true,
          stages: [
            %{id: 1, name: "Plan", current?: false},
            %{id: 2, name: "Code", current?: true}
          ]
        })

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(<span id="card-drawer-stage-chip")
      refute html =~ ~s(<button type="button" id="card-drawer-stage-chip")
      refute html =~ "hero-chevron-down size-[11px]"
      refute html =~ ~s(id="card-drawer-stage-menu")
    end

    test "the popover shows a single inert No stages match row when the filter matches nothing" do
      attrs =
        drawer_attrs(%{}, %{
          stage_menu_open: true,
          stage_filter: "zzzz",
          stages: [
            %{id: 1, name: "Plan", current?: false},
            %{id: 2, name: "Code", current?: true}
          ]
        })

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(id="card-drawer-stage-none")
      assert html =~ "No stages match"
      refute html =~ ~s(id="card-drawer-move-to-1")
      refute html =~ ~s(id="card-drawer-move-to-2")
    end

    # RE282 — the rail's section labels, top to bottom. Every row is a direct-child
    # `.rail-section` whose first child is the section_label span.
    defp rail_labels(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#card-drawer-rail > .rail-section > span:first-child")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    defp rail_text(html) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query("#card-drawer-rail") |> LazyHTML.text()
    end

    defp rail_flow do
      %Schemas.Flow{
        key: "spec",
        edges: [
          %{from: "start", on: nil, to: "spec"},
          %{from: "spec", on: :succeeded, to: "implement"},
          %{from: "implement", on: :succeeded, to: "review"},
          %{from: "review", on: :succeeded, to: "done"}
        ]
      }
    end

    test "RE282: rail rows follow the artboard order" do
      attrs =
        drawer_attrs(
          %{tag: "search", branch: "re282-rail"},
          %{
            run_flow: rail_flow(),
            dependents: [%{ref: "RLY-9", title: "Downstream"}]
          }
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert rail_labels(html) ==
               ["Status", "Blocked by", "Blocks", "Owners", "Tags", "Updated", "Flow", "Links"]
    end

    test "RE282: every rail row label uses the section_label recipe" do
      attrs = drawer_attrs(%{branch: "re282-rail"}, %{run_flow: rail_flow()})
      html = render_component(&CoreComponents.card_drawer/1, attrs)

      classes =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#card-drawer-rail > .rail-section > span:first-child")
        |> LazyHTML.attribute("class")

      assert classes != []

      for class <- classes do
        assert class =~ "font-mono text-[10px] font-semibold uppercase tracking-[0.06em]"
        assert class =~ "text-base-content/60"
      end
    end

    test "RE282: Updated replaces Dates, formatted Mon DD · HH:MM, and Created is gone" do
      attrs =
        drawer_attrs(
          %{inserted_at: ~U[2026-07-01 08:00:00Z], updated_at: ~U[2026-08-04 09:12:00Z]},
          %{}
        )

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      updated =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#card-drawer-rail .rail-updated")

      assert LazyHTML.text(updated) =~ "Aug 04 · 09:12"
      assert updated |> LazyHTML.attribute("class") |> List.first() =~ "font-mono"
      refute html =~ "rail-dates"
      refute rail_text(html) =~ "Created"
      refute rail_text(html) =~ "Dates"
    end

    test "RE282: Flow row shows the latest run's flow happy path as plain mono text" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_attrs(%{}, %{run_flow: rail_flow()}))

      flow = html |> LazyHTML.from_fragment() |> LazyHTML.query("#card-drawer-rail .rail-flow")

      assert flow |> LazyHTML.text() |> String.trim() == "spec → implement → review"
      assert flow |> LazyHTML.attribute("class") |> List.first() =~ "font-mono"
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query("#card-drawer-rail .rail-flow a") |> Enum.to_list() == []
    end

    test "RE282: Flow row falls back to the queued flow" do
      queued = %Schemas.Flow{
        key: "code",
        edges: [
          %{from: "start", on: nil, to: "implement"},
          %{from: "implement", on: :succeeded, to: "review"},
          %{from: "review", on: :succeeded, to: "done"}
        ]
      }

      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{run_flow: false, queued_flow: queued})
        )

      assert rail_text(html) =~ "implement → review"
      assert "Flow" in rail_labels(html)
    end

    test "RE282: Flow row is hidden with no run flow and no queued flow" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{run_flow: false, queued_flow: nil})
        )

      refute html =~ "rail-flow"
      refute "Flow" in rail_labels(html)
    end

    test "RE282: Flow row is hidden when the flow has no start edge (empty happy path)" do
      no_start = %Schemas.Flow{key: "broken", edges: [%{from: "a", on: :succeeded, to: "done"}]}
      html = render_component(&CoreComponents.card_drawer/1, drawer_attrs(%{}, %{run_flow: no_start}))

      refute html =~ "rail-flow"
      refute "Flow" in rail_labels(html)
    end

    test "RE282 change 23: Reassign toggle and picker rows are token-classed with a real hover" do
      member = %{
        user_id: 7,
        user: %Schemas.User{id: 7, name: "Ada Lovelace", email: "ada@example.com", avatar_url: nil}
      }

      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{reassign_open: true, members: [member]})
        )

      doc = LazyHTML.from_fragment(html)

      for selector <- [
            "#card-drawer-reassign-toggle",
            "#card-drawer-assign-user-7",
            "#card-drawer-assign-ai"
          ] do
        node = LazyHTML.query(doc, selector)
        assert node |> LazyHTML.attribute("class") |> List.first() =~ "hover:bg-base-200"
        assert LazyHTML.attribute(node, "style") == []
      end

      picker = LazyHTML.query(doc, "#card-drawer-reassign-picker")
      assert picker |> LazyHTML.attribute("class") |> List.first() =~ "border-base-300"
      assert LazyHTML.attribute(picker, "style") == []
    end

    test "RE282: non-interactive rail values carry no hover" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_attrs(%{}, %{run_flow: rail_flow()}))
      doc = LazyHTML.from_fragment(html)

      for selector <- [
            "#card-drawer-rail .rail-status",
            "#card-drawer-rail .rail-updated",
            "#card-drawer-rail .rail-flow"
          ] do
        class = doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> List.first()
        refute class =~ "hover:"
      end
    end

    defp unused_toggle_text(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#card-drawer-unused-toggle")
      |> LazyHTML.text()
      |> String.trim()
    end

    defp present?(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list() != []
    end

    test "RE282: both public fields empty collapse behind a dashed `2 unused fields` row" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{vote_count: 0, public_description: nil})
        )

      assert unused_toggle_text(html) == "2 unused fields"
      refute present?(html, "#card-drawer-public-support")
      refute present?(html, "#card-drawer-public-description")
      refute present?(html, "#card-drawer-unused-public-support")
      refute present?(html, "#add-public-desc")
      refute "Public support" in rail_labels(html)

      # Artboard: mono 11px/600, muted ink, 1px dashed border, 7px radius, 7px/9px padding, left-aligned,
      # full rail width — plus a real hover (change 23).
      class =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#card-drawer-unused-toggle")
        |> LazyHTML.attribute("class")
        |> List.first()

      for token <-
            ~w(w-full border border-dashed border-base-300 rounded-[7px] px-[9px] py-[7px] text-left font-mono text-[11px] font-semibold text-base-content/55 hover:bg-base-200) do
        assert class =~ token
      end
    end

    test "RE282: expanded, the unused fields show their hints and the toggle reads Hide unused fields" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{vote_count: 0, public_description: nil, unused_fields_open: true})
        )

      assert unused_toggle_text(html) == "Hide unused fields"

      doc = LazyHTML.from_fragment(html)
      support = LazyHTML.query(doc, "#card-drawer-unused-public-support")
      description = LazyHTML.query(doc, "#card-drawer-unused-public-description")

      assert LazyHTML.text(support) =~ "Public support"
      assert LazyHTML.text(support) =~ "no supporters yet"
      assert LazyHTML.text(description) =~ "Public description"
      assert LazyHTML.text(description) =~ "not written"

      add = LazyHTML.query(doc, "#card-drawer-unused-public-description #add-public-desc")
      assert LazyHTML.text(add) =~ "+ Add a public description"
      assert add |> LazyHTML.attribute("class") |> List.first() =~ "hover:bg-base-200"

      # the expanded fields sit ABOVE the button (artboard order)
      {support_at, _} = :binary.match(html, "card-drawer-unused-public-support")
      {toggle_at, _} = :binary.match(html, "card-drawer-unused-toggle")
      assert support_at < toggle_at
    end

    test "RE282: a written description renders as a normal section and the count drops to 1" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{vote_count: 0, public_description: "Ship the mobile app"})
        )

      assert unused_toggle_text(html) == "1 unused field"
      assert List.last(rail_labels(html)) == "Public description"

      section =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#card-drawer-public-description")

      assert LazyHTML.text(section) =~ "Ship the mobile app"
      refute present?(html, "#card-drawer-unused-public-description")
    end

    test "RE282: both public fields filled render in place with no unused row" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{vote_count: 2, supporters: [], public_description: "Ship it"})
        )

      refute present?(html, "#card-drawer-unused-fields")
      refute present?(html, "#card-drawer-unused-toggle")
      assert Enum.take(rail_labels(html), -2) == ["Public support", "Public description"]
    end

    test "RE282: an open description editor stays visible outside the collapsed group" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{
            vote_count: 0,
            public_description: nil,
            editing_public_desc: true,
            public_desc_form: to_form(%{"public_description" => ""})
          })
        )

      assert present?(html, "#card-drawer-public-description #public-desc-form")
      assert unused_toggle_text(html) == "1 unused field"
    end

    test "RE282: the public fields use section_label and carry no inline styles" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          drawer_attrs(%{}, %{
            vote_count: 1,
            supporters: [],
            public_description: nil,
            editing_public_desc: true,
            public_desc_form: to_form(%{"public_description" => ""})
          })
        )

      refute html =~ "PUBLIC SUPPORT"
      refute html =~ "PUBLIC DESCRIPTION"

      doc = LazyHTML.from_fragment(html)

      for selector <- [
            "#card-drawer-public-description [style]",
            "#card-drawer-public-description[style]",
            "#card-drawer-unused-fields [style]"
          ] do
        assert doc |> LazyHTML.query(selector) |> Enum.to_list() == []
      end

      label =
        doc
        |> LazyHTML.query("#card-drawer-public-support > span:first-child")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert label =~ "font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60"
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
    # RE282 change 21 — the one micro-label recipe (Relay Card Detail v5.dc.html rail labels:
    # JetBrains Mono 10px / 600 / letter-spacing 0.6px / uppercase / ink at 0.6 alpha).
    test "renders the one micro-label recipe with the /60 muted token" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.section_label>Owners</CoreComponents.section_label>
        """)

      assert html =~ "Owners"
      assert html =~ "font-mono text-[10px] font-semibold uppercase tracking-[0.06em]"
      assert html =~ "text-base-content/60"
      refute html =~ "text-base-content/65"
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

  describe "rail_unused_fields/3 (RE282)" do
    test "both public fields empty are both unused, support first" do
      assert CoreComponents.rail_unused_fields(0, nil, false) == [:public_support, :public_description]
    end

    test "supporters make public support used" do
      assert CoreComponents.rail_unused_fields(3, nil, false) == [:public_description]
    end

    test "a written description is used" do
      assert CoreComponents.rail_unused_fields(0, "Ship it", false) == [:public_support]
    end

    test "an open description editor counts as in use" do
      assert CoreComponents.rail_unused_fields(0, nil, true) == [:public_support]
    end

    test "both filled leaves nothing unused" do
      assert CoreComponents.rail_unused_fields(2, "Ship it", false) == []
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
        board_slug: "test-board",
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

  describe "card_drawer/1 blocked strip (RE279)" do
    defp blocked_drawer(card_overrides, extra) do
      render_component(
        &CoreComponents.card_drawer/1,
        drawer_attrs(
          Map.merge(
            %{status: :needs_input, blocked_since: DateTime.add(DateTime.utc_now(), -47 * 60, :second)},
            card_overrides
          ),
          Map.merge(%{answer_form: to_form(%{"body" => ""}, as: :answer)}, extra)
        )
      )
    end

    defp batch_questions do
      [
        %{"prompt" => "Which **timezone**?", "options" => ["Billing", "Viewer"], "allow_text" => true},
        %{"prompt" => "Any `size` limit?", "options" => ["None", "10 MB"], "allow_text" => true},
        %{"prompt" => "Archived cards too?", "options" => ["Yes", "No"], "allow_text" => false}
      ]
    end

    test "a needs_input card renders the strip between the header and the tab bar" do
      html = blocked_drawer(%{}, %{question: "Use **UTC** or the `viewer` tz?"})

      {header_end, _} = :binary.match(html, "</header>")
      {strip_at, _} = :binary.match(html, ~s(id="card-drawer-blocked-strip"))
      {nav_at, _} = :binary.match(html, ~s(id="card-drawer-tabs"))
      assert header_end < strip_at
      assert strip_at < nav_at

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-eyebrow") |> LazyHTML.text() |> String.trim() ==
               "NEEDS YOUR ANSWER"

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-question") |> LazyHTML.attribute("title") ==
               ["Use UTC or the viewer tz?"]

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-wait") |> LazyHTML.text() |> String.trim() == "47m"
    end

    test "the Detail answer panel has no waiting readout — the strip is the only wait display" do
      refute blocked_drawer(%{}, %{question: "Which bucket?"}) =~ ~s(id="needs-input-waiting")
    end

    test "no strip for a card that is not blocked, or for an archived blocked card" do
      ready = render_component(&CoreComponents.card_drawer/1, drawer_attrs(%{}, %{}))
      refute ready =~ ~s(id="card-drawer-blocked-strip")

      refute blocked_drawer(%{}, %{archived: true}) =~ ~s(id="card-drawer-blocked-strip")
    end

    test "embed mode keeps the strip" do
      assert blocked_drawer(%{}, %{embed: true}) =~ ~s(id="card-drawer-blocked-strip")
    end

    test "a structured batch: the strip shows the current step's prompt as plain text and an N/M counter" do
      doc =
        %{}
        |> blocked_drawer(%{answer_questions: batch_questions(), answer_step: 1})
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-question") |> LazyHTML.text() |> String.trim() ==
               "Any size limit?"

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-counter") |> LazyHTML.text() |> String.trim() == "2/3"
    end

    test "a single structured question shows no counter" do
      html = blocked_drawer(%{}, %{answer_questions: [%{"prompt" => "Only one?", "options" => [], "allow_text" => true}]})

      assert html =~ ~s(title="Only one?")
      refute html =~ ~s(id="card-drawer-blocked-strip-counter")
    end

    test "while the body loads the strip shows a skeleton line instead of the question" do
      html = render_component(&CoreComponents.card_drawer/1, loading_drawer_assigns())

      assert html =~ ~s(id="card-drawer-blocked-strip-question-skeleton")
      refute html =~ ~s(id="card-drawer-blocked-strip-question")
    end
  end

  # RE279 — the persistent needs-you strip. Every class/token below is pinned to
  # docs/designs/Relay Card Detail v5.dc.html, "persistent needs-you strip" (lines ~88–102),
  # with the artboard's oklch literals mapped to daisyUI warning tokens.
  describe "blocked_strip/1 (RE279)" do
    defp blocked_strip_html(extra \\ %{}) do
      base = %{eyebrow: "SPEC ASKED AND EXITED", question: "Which scope should board search cover?"}
      html = render_component(&CoreComponents.blocked_strip/1, Map.merge(base, extra))
      {html, LazyHTML.from_fragment(html)}
    end

    defp strip_classes(doc, selector) do
      doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> Enum.flat_map(&String.split/1)
    end

    defp strip_style(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("style") |> Enum.join()

    defp strip_text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    defp assert_classes(doc, selector, expected) do
      actual = strip_classes(doc, selector)
      for class <- expected, do: assert(class in actual, "#{selector} is missing class #{class}")
    end

    test "matches the artboard's row, accent bar, text column, wait column and Answer button" do
      {_html, doc} = blocked_strip_html(%{blocked_since: DateTime.add(DateTime.utc_now(), -47 * 60, :second)})

      assert_classes(doc, "#card-drawer-blocked-strip", ~w(flex flex-none items-center gap-[14px] px-5 py-3))
      root_style = strip_style(doc, "#card-drawer-blocked-strip")
      assert root_style =~ "background:color-mix(in oklab, var(--color-warning) 8%, var(--color-base-100))"
      assert root_style =~ "border-top:1px solid color-mix(in oklab, var(--color-warning) 30%, var(--color-base-100))"
      assert root_style =~ "border-bottom:1px solid color-mix(in oklab, var(--color-warning) 30%, var(--color-base-100))"

      assert_classes(doc, "#card-drawer-blocked-strip-accent", ~w(w-[3px] flex-none self-stretch rounded-[2px]))
      assert strip_style(doc, "#card-drawer-blocked-strip-accent") =~ "background:var(--color-warning)"

      assert_classes(doc, "#card-drawer-blocked-strip-text", ~w(flex min-w-0 flex-1 flex-col gap-0.5))

      assert_classes(
        doc,
        "#card-drawer-blocked-strip-eyebrow",
        ~w(font-mono text-[10px] font-semibold uppercase tracking-[0.6px])
      )

      assert strip_style(doc, "#card-drawer-blocked-strip-eyebrow") =~
               "color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"

      assert_classes(doc, "#card-drawer-blocked-strip-question", ~w(truncate text-[13.5px] font-semibold leading-[1.4]))

      assert strip_style(doc, "#card-drawer-blocked-strip-question") =~
               "color:color-mix(in oklab, var(--color-warning) 15%, var(--color-base-content))"

      assert_classes(doc, "#card-drawer-blocked-strip-meta", ~w(flex flex-none flex-col items-end))

      assert_classes(
        doc,
        "#card-drawer-blocked-strip-wait",
        ~w(font-mono text-[21px] font-semibold leading-none tracking-[-0.02em] tabular-nums)
      )

      assert_classes(
        doc,
        "#card-drawer-blocked-strip-wait-label",
        ~w(font-mono text-[9.5px] font-semibold tracking-[0.5px] mt-0.5)
      )

      assert_classes(
        doc,
        "#card-drawer-blocked-answer",
        ~w(h-[30px] flex-none whitespace-nowrap rounded-[7px] border-none px-[13px] text-[12px] font-semibold text-warning-content)
      )

      assert strip_style(doc, "#card-drawer-blocked-answer") =~ "background:var(--color-warning)"
    end

    test "renders the eyebrow, the one-line question with its full text as title, and Answer" do
      {_html, doc} = blocked_strip_html()

      assert strip_text(doc, "#card-drawer-blocked-strip-eyebrow") == "SPEC ASKED AND EXITED"
      assert strip_text(doc, "#card-drawer-blocked-strip-question") == "Which scope should board search cover?"

      assert doc |> LazyHTML.query("#card-drawer-blocked-strip-question") |> LazyHTML.attribute("title") ==
               ["Which scope should board search cover?"]

      assert strip_text(doc, "#card-drawer-blocked-answer") == "Answer"
      assert doc |> LazyHTML.query("#card-drawer-blocked-answer") |> LazyHTML.attribute("phx-click") == ["answer_jump"]
      assert [hook] = doc |> LazyHTML.query("#card-drawer-blocked-strip") |> LazyHTML.attribute("phx-hook")
      assert hook =~ "BlockedStrip"
    end

    test "shows the compact wait since blocked_since above 'waiting on you', clamped at zero" do
      now = DateTime.utc_now()

      for {seconds_ago, expected} <- [{47 * 60, "47m"}, {3 * 3600 + 120, "3h"}, {2 * 86_400 + 60, "2d"}, {-120, "0m"}] do
        {_html, doc} = blocked_strip_html(%{blocked_since: DateTime.add(now, -seconds_ago, :second)})
        assert strip_text(doc, "#card-drawer-blocked-strip-wait") == expected
        assert strip_text(doc, "#card-drawer-blocked-strip-wait-label") == "waiting on you"
      end
    end

    test "omits the wait value and its sub-label when blocked_since is nil" do
      {html, _doc} = blocked_strip_html(%{blocked_since: nil})

      refute html =~ ~s(id="card-drawer-blocked-strip-wait")
      refute html =~ ~s(id="card-drawer-blocked-strip-wait-label")
      refute html =~ "waiting on you"
      refute html =~ ~s(id="card-drawer-blocked-strip-meta")
    end

    test "shows the N/M counter only for a batch of more than one question" do
      {_html, doc} = blocked_strip_html(%{step: 2, step_count: 3})
      assert strip_text(doc, "#card-drawer-blocked-strip-counter") == "2/3"
      assert_classes(doc, "#card-drawer-blocked-strip-counter", ~w(font-mono tabular-nums))

      {single, _doc} = blocked_strip_html(%{step: 1, step_count: 1})
      refute single =~ ~s(id="card-drawer-blocked-strip-counter")
    end

    test "the counter still renders when there is no blocked_since" do
      {_html, doc} = blocked_strip_html(%{step: 1, step_count: 3, blocked_since: nil})
      assert strip_text(doc, "#card-drawer-blocked-strip-counter") == "1/3"
    end

    test "shows a one-line skeleton in place of the question while loading" do
      {html, doc} = blocked_strip_html(%{loading?: true})

      assert "skeleton" in strip_classes(doc, "#card-drawer-blocked-strip-question-skeleton")
      refute html =~ ~s(id="card-drawer-blocked-strip-question")
    end

    test "a nil question renders no question line" do
      {html, _doc} = blocked_strip_html(%{question: nil})
      refute html =~ ~s(id="card-drawer-blocked-strip-question")
    end
  end

  describe "blocked_strip_eyebrow/3 (RE279)" do
    test "a parked question names the node that asked and exited" do
      assert CoreComponents.blocked_strip_eyebrow(true, :question, "spec") == "SPEC ASKED AND EXITED"
    end

    test "a parked escalation names the node that failed" do
      assert CoreComponents.blocked_strip_eyebrow(true, :escalation, "spec") == "SPEC FAILED — YOUR CALL"
    end

    test "no parked run, or no node key, reads NEEDS YOUR ANSWER" do
      assert CoreComponents.blocked_strip_eyebrow(false, :question, nil) == "NEEDS YOUR ANSWER"
      assert CoreComponents.blocked_strip_eyebrow(false, :question, "spec") == "NEEDS YOUR ANSWER"
      assert CoreComponents.blocked_strip_eyebrow(true, :question, nil) == "NEEDS YOUR ANSWER"
      assert CoreComponents.blocked_strip_eyebrow(true, :escalation, nil) == "NEEDS YOUR ANSWER"
    end

    test "the node key is upcased as-is, with no other rewriting" do
      assert CoreComponents.blocked_strip_eyebrow(true, :question, "quality_review") ==
               "QUALITY_REVIEW ASKED AND EXITED"
    end
  end

  describe "needs_input_panel/1" do
    defp panel(extra) do
      base = %{
        card: %{blocked_since: nil},
        question: nil,
        answer_questions: nil,
        answer_step: 0,
        answer_values: %{},
        answer_form: to_form(%{"body" => ""}, as: :answer),
        body_loading: false
      }

      render_component(&CoreComponents.needs_input_panel/1, Map.merge(base, extra))
    end

    test "a question park keeps today's label, markdown question and placeholder, with no Retry" do
      html = panel(%{question: "Billing timezone or the viewer's?"})

      assert html =~ "RELAY AI NEEDS YOUR INPUT"
      assert html =~ ~s(id="needs-input-question")
      assert html =~ "Billing timezone"
      assert html =~ "Type your answer"
      assert html =~ ~s(id="needs-input-send")
      refute html =~ ~s(id="needs-input-retry")
      refute html =~ "NODE FAILED"
    end

    test "an escalation park names the node, shows the failure output and offers Retry" do
      detail = "✗ commit guard: the working tree is dirty\n  M lib/relay/exports.ex"

      html =
        panel(%{
          park_kind: :escalation,
          node: "implement",
          attempt: 3,
          question: detail,
          failure_detail: detail
        })

      assert html =~ "NODE FAILED · YOUR CALL"
      assert html =~ "implement"
      assert html =~ "3 attempts"

      # the failure text the old :stopped banner threw away, in the dark <pre> the :failed
      # banner already uses
      assert html =~ ~s(id="needs-input-failure-detail")
      assert html =~ "M lib/relay/exports.ex"
      assert html =~ "background:var(--color-neutral)"

      # answering is the primary action; Retry sits beside it
      assert html =~ ~s(id="needs-input-send")
      assert html =~ "Tell the agent what to do differently"
      assert html =~ ~s(id="needs-input-retry")
      assert html =~ "Retry implement"

      # the markdown question block is suppressed — the <pre> carries that same text
      refute html =~ ~s(id="needs-input-question")
      refute html =~ "AGENT STOPPED"
    end

    test "a single attempt reads singular" do
      html = panel(%{park_kind: :escalation, node: "branch", attempt: 1, failure_detail: "boom"})

      assert html =~ "1 attempt"
      refute html =~ "1 attempts"
    end

    test "an escalation park with no captured failure detail renders no empty pre" do
      html = panel(%{park_kind: :escalation, node: "post", attempt: 2})

      assert html =~ "NODE FAILED · YOUR CALL"
      refute html =~ ~s(id="needs-input-failure-detail")
    end

    # RE253: an A9 (`:partial`) park is an escalation whose ONLY copy of the failure text is the
    # question — `RunDetail.last_failure_detail/1` keeps `:failed` executions only, so the <pre>
    # is empty. Suppressing the question there left the human with no explanation at all.
    test "an escalation park with no <pre> still shows the failure text as the question" do
      detail = "implement reported partial: 2 of 5 tasks left unimplemented"

      html = panel(%{park_kind: :escalation, node: "implement", attempt: 1, question: detail})

      refute html =~ ~s(id="needs-input-failure-detail")
      assert html =~ ~s(id="needs-input-question")
      assert html =~ "2 of 5 tasks left unimplemented"
    end

    test "renders once, with every DOM id under needs-input- (RE279)" do
      html = panel(%{park_kind: :escalation, node: "implement", attempt: 2, failure_detail: "boom"})

      for suffix <- ~w(panel escalation failure-detail form answer send retry) do
        assert html =~ ~s(id="needs-input-#{suffix}"), "missing needs-input-#{suffix}"
      end

      refute html =~ "run-needs-input"
    end

    test "the RLY-71 stepper branch keeps its needs-input ids" do
      html =
        panel(%{
          answer_questions: [
            %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true}
          ]
        })

      for suffix <- ~w(stepper progress question option-0 text-form text send) do
        assert html =~ ~s(id="needs-input-#{suffix}"), "missing needs-input-#{suffix}"
      end

      assert html =~ "Question 1 of 1"
    end

    test "carries the RE310 advance control last, only when available (RE279)" do
      html =
        panel(%{
          park_kind: :escalation,
          node: "impl",
          attempt: 1,
          failure_detail: "already committed",
          advance_available?: true
        })

      assert html =~ ~s(id="needs-input-advance")
      assert html =~ ~s(id="run-advance")
      assert html =~ "Task already done — continue"

      # last in DOM order, so the strip's Answer focuses an answer control, never this
      {send_at, _} = :binary.match(html, ~s(id="needs-input-send"))
      {advance_at, _} = :binary.match(html, ~s(id="run-advance"))
      assert send_at < advance_at

      refute panel(%{}) =~ ~s(id="run-advance")
      refute panel(%{}) =~ ~s(id="needs-input-advance")
    end
  end

  # RLY-148 — the collapsed log strip, full artboard fidelity. Every value below is
  # pinned to docs/designs/Relay Card Activity.dc.html §02; the light theme's
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

      assert html =~ "color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100))"
      assert html =~ "animation:relaypulse 1.4s ease-in-out infinite"
      assert html =~ "var(--color-secondary)"
      assert html =~ "color-mix(in oklab, var(--color-secondary) 60%, var(--color-base-content))"
    end

    # RLY-148 (supersedes the 2026-07-16 rejection): stale is §02's amber treatment —
    # amber tint box, still amber dot, amber mono text — no gray anywhere.
    test "stale is amber — tint box, still amber dot, amber text" do
      html = strip(:stale)

      assert html =~ ~s(data-health="stale")
      assert html =~ "background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100))"
      assert html =~ "border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100))"
      assert html =~ "background:var(--color-warning)"
      assert html =~ "color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content))"
      assert html =~ "color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"
      refute html =~ "animation:relaypulse"
      refute html =~ "oklch("
    end

    # RLY-148 card chrome (§02): a dead agent recolors the shell — amber border+shadow
    # and amber accent on stale; rose border+shadow and rose accent on stopped.
    test "stale card chrome: amber-tinted border, shadow, and accent" do
      html = strip(:stale)

      assert html =~ "border-l-warning"
      assert html =~ "border:1px solid color-mix(in oklab, var(--color-warning) 45%, var(--color-base-100))"
      assert html =~ "box-shadow:0 1px 3px color-mix(in oklab, var(--color-warning) 12%, transparent)"
      assert html =~ "border-left:3px solid var(--color-warning)"
    end

    test "stopped card chrome: rose border, shadow, and accent" do
      html = strip(:stopped, log_text: "agent stopped")

      assert html =~ "border-l-error"
      assert html =~ "border:1px solid color-mix(in oklab, var(--color-error) 35%, var(--color-base-100))"
      assert html =~ "box-shadow:0 1px 3px color-mix(in oklab, var(--color-error) 12%, transparent)"
      assert html =~ "border-left:3px solid var(--color-error)"
    end

    test "live and none keep the quiet status-keyed shell" do
      for health <- [:none, :live] do
        html = strip(health)

        assert html =~ "border:1px solid var(--color-base-300)"
        assert html =~ "box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 5%, transparent)"
        assert html =~ "border-l-secondary"
      end
    end

    test "stopped keeps the rose strip and ! disc" do
      html = strip(:stopped, log_text: "agent stopped")

      assert html =~ ~s(data-health="stopped")
      assert html =~ "var(--color-error)"
      assert html =~ "color-mix(in oklab, var(--color-error) 10%, var(--color-base-100))"
      assert html =~ "agent stopped"
      refute html =~ "animation:relaypulse"
    end

    # RLY-148 (supersedes Q6→C): the artboard's §02 Retry pill on the stopped strip.
    test "stopped shows the artboard's Retry chip on the strip" do
      html = strip(:stopped, log_text: "agent stopped")

      assert html =~ ~s(id="card-RLY-3-retry")
      assert html =~ ~s(phx-click="retry_card")
      assert html =~ ~s(phx-value-ref="RLY-3")
      assert html =~ "border:1px solid color-mix(in oklab, var(--color-error) 40%, var(--color-base-100))"
      assert html =~ "color:color-mix(in oklab, var(--color-error) 65%, var(--color-base-content))"
    end

    test "live and stale strips show no Retry" do
      refute strip(:live) =~ "Retry"
      refute strip(:stale) =~ "Retry"
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

  describe "board_card/1 run affordances" do
    defp run_card(run, extra \\ %{}) do
      render_component(
        &CoreComponents.board_card/1,
        Map.merge(
          %{id: "c", ref: "RLY-9", title: "CSV export of the board", status: :working, run: run},
          extra
        )
      )
    end

    test "an active run replaces the legacy strip, progress bar, and working label" do
      html =
        run_card(
          {:run,
           %{
             status: :running,
             node_index: 2,
             node_count: 4,
             current_node: "implement",
             flow_key: "code",
             flow_version: 3,
             attempts: 2
           }},
          %{health: :live, log_text: "old strip", log_at: DateTime.utc_now(), progress: 61}
        )

      assert html =~ ~s(id="card-RLY-9-run-face")
      assert html =~ "node 2 of 4"
      refute html =~ "card-RLY-9-log-strip"
      refute html =~ "old strip"
      refute html =~ ~s(class="card-status")
      assert html =~ "border-l-secondary"
    end

    test "a parked run replaces the needs-you chip with PARKED · NEEDS YOU" do
      html =
        run_card(
          {:run, %{status: :parked, current_node: "brainstorm", flow_key: "spec", flow_version: 2, attempts: 1}},
          %{status: :needs_input, question: "Full text?"}
        )

      assert html =~ "PARKED · NEEDS YOU"
      refute html =~ "card-needs-input"
      refute html =~ "card-question-preview"
      assert html =~ "border-l-warning"
    end

    test "failed, queued, done, and cancelled paint their accents" do
      failed =
        run_card(
          {:run,
           %{
             status: :failed,
             current_node: nil,
             last_node: "quality_review",
             flow_key: "code",
             flow_version: 3,
             attempts: 3
           }}
        )

      queued = run_card({:queued, %{key: "code"}}, %{status: :ready})

      done =
        run_card(
          {:run,
           %{status: :done, duration_s: 581, cost: Decimal.new("0.38"), flow_key: "code", flow_version: 3, attempts: 4}},
          %{status: :ready}
        )

      cancelled =
        run_card(
          {:run,
           %{
             status: :cancelled,
             current_node: nil,
             last_node: "implement",
             flow_key: "code",
             flow_version: 3,
             attempts: 1
           }}
        )

      assert failed =~ "RUN FAILED"
      assert failed =~ "border-l-error"
      assert queued =~ "QUEUED · CODE FLOW"
      assert queued =~ "border-l-base-300"
      assert done =~ "Completed · 9:41"
      refute done =~ "merged"
      assert done =~ "border-l-success"
      assert cancelled =~ "CANCELLED"
      refute cancelled =~ "CLAIMED"
    end

    test "a done run on an in_review card shows the blue review treatment" do
      html =
        run_card(
          {:run, %{status: :done, duration_s: 581, cost: nil, flow_key: "code", flow_version: 3, attempts: 4}},
          %{status: :in_review}
        )

      assert html =~ "READY FOR YOUR REVIEW"
      assert html =~ "border-l-primary"
    end

    test "without a run the legacy strip logic is untouched" do
      html = run_card(nil, %{health: :live, log_text: "uploaded 24/40 posts", log_at: DateTime.utc_now()})

      assert html =~ "card-RLY-9-log-strip"
      assert html =~ "uploaded 24/40 posts"
      refute html =~ "run-face"
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
      assert html =~ "color:var(--color-neutral-content)"
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
      # round(22 * 0.36) = 8px mark with the 1.5px border, as the card cluster draws it
      assert html =~ "width:8px;height:8px;border-radius:50%;border:1.5px solid var(--color-secondary-content)"
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

    test "identity_color/1 is the one definition of a person's hue, and avatar/1 uses it" do
      html = render_component(&CoreComponents.avatar/1, name: "Dana Kim", email: "dana@acme.co")

      assert CoreComponents.identity_color("dana@acme.co") ==
               "oklch(0.62 0.13 #{CoreComponents.identity_hue("dana@acme.co")})"

      assert html =~ "background:#{CoreComponents.identity_color("dana@acme.co")}"
    end

    # RE237: the L/C pair is load-bearing (a fixed `--color-neutral-content` ink has to stay
    # legible on every hue), so it gets exactly ONE home — `identity_color_for_hue/1`. Before
    # this, `identity_color/1`, the story-map owner chip and the /boards accent each re-typed
    # it, and the accent had drifted to a third pair (0.62 0.15).
    test "identity_color_for_hue/1 is the single home of the identity L/C pair" do
      assert CoreComponents.identity_color_for_hue(123) == "oklch(0.62 0.13 123)"

      for module <- [
            "lib/relay_web/components/core_components.ex",
            "lib/relay_web/components/story_map_components.ex",
            "lib/relay_web/live/boards_live.ex"
          ] do
        occurrences =
          module |> File.read!() |> then(&Regex.scan(~r/"oklch\(0\.62 0\.1\d /, &1)) |> length()

        expected = if module =~ "core_components", do: 1, else: 0

        assert occurrences == expected,
               "#{module} re-types the identity fill — call identity_color_for_hue/1 instead"
      end
    end

    test "title overrides the name/email tooltip without touching the initials" do
      html =
        render_component(&CoreComponents.avatar/1,
          name: "Dana",
          email: "dana@acme.co",
          title: "Dana (you)"
        )

      assert html =~ ~s(title="Dana \(you\)")
      # The initials still come from the NAME, not the overridden title.
      assert html =~ ">D<"
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

  describe "image_lightbox/1" do
    test "renders a native dialog with a daisyUI modal backdrop and an empty img" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      assert html =~ ~s(<dialog)
      assert html =~ ~s(id="image-lightbox")
      # daisyUI modal primitives — the backdrop <form method="dialog"> is what
      # gives click-outside-to-close for free.
      assert html =~ "modal"
      assert html =~ "modal-backdrop"
      assert html =~ ~s(method="dialog")
      # the JS swaps this element's src in; it must start empty so a stale
      # image never flashes before the first open.
      assert html =~ ~s(id="image-lightbox-img")
      assert html =~ ~s(src="")
    end

    test "the dialog is labelled for assistive tech and has a close control" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      assert html =~ ~s(aria-label="Close")
    end

    defp lightbox_query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp lightbox_count(html, selector), do: html |> lightbox_query(selector) |> Enum.count()

    test "renders the RE322 carousel chrome with the stable ids assets/js/image_lightbox.js drives" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      for id <-
            ~w(image-lightbox-img image-lightbox-prev image-lightbox-next image-lightbox-caption image-lightbox-counter) do
        assert lightbox_count(html, "dialog#image-lightbox ##{id}") == 1, "missing ##{id} inside the dialog"
      end
    end

    test "Previous/Next are labelled daisyUI circle buttons with hero chevrons" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      assert lightbox_count(
               html,
               ~s(button#image-lightbox-prev.btn.btn-circle[type="button"][aria-label="Previous image"] .hero-chevron-left)
             ) == 1

      assert lightbox_count(
               html,
               ~s(button#image-lightbox-next.btn.btn-circle[type="button"][aria-label="Next image"] .hero-chevron-right)
             ) == 1
    end

    test "a freshly rendered viewer is a single-image viewer: nav, counter and caption start hidden" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      for id <- ~w(image-lightbox-prev image-lightbox-next image-lightbox-counter image-lightbox-caption) do
        assert lightbox_count(html, "##{id}[hidden]") == 1, "##{id} should start hidden"
      end
    end

    # Artboard decision: no mockup — the design system. Translucent theme-token surfaces so the
    # chrome stays readable over any screenshot and flips with data-theme (theme_tokens_test.exs
    # separately forbids literals).
    test "the buttons, caption and counter sit on translucent theme-token surfaces" do
      html = render_component(&CoreComponents.image_lightbox/1, [])

      [prev_class] = html |> lightbox_query("#image-lightbox-prev") |> LazyHTML.attribute("class")
      [caption_class] = html |> lightbox_query("#image-lightbox-caption") |> LazyHTML.attribute("class")
      [counter_class] = html |> lightbox_query("#image-lightbox-counter") |> LazyHTML.attribute("class")

      assert prev_class =~ "bg-base-100/80"
      assert prev_class =~ "text-base-content"
      assert caption_class =~ "bg-base-100/85"
      assert caption_class =~ "text-base-content"
      assert counter_class =~ "bg-base-200/85"
      assert counter_class =~ "text-base-content/70"
    end
  end

  describe "image_lightbox_viewer/1" do
    test "with a counter and caption it shows the nav, the counter and the caption" do
      html =
        render_component(&CoreComponents.image_lightbox_viewer/1,
          id: "v",
          src: "/images/logo_light_128.png",
          alt: "shot",
          caption: "Review drawer",
          counter: "2 / 5"
        )

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(~s(#v-img[src="/images/logo_light_128.png"][alt="shot"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("[hidden]") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#v-counter") |> LazyHTML.text() |> String.trim() == "2 / 5"
      assert doc |> LazyHTML.query("#v-caption") |> LazyHTML.text() |> String.trim() == "Review drawer"
    end

    test "a captioned lone image shows the caption but no nav or counter" do
      html = render_component(&CoreComponents.image_lightbox_viewer/1, id: "v", src: "/x.png", caption: "solo")
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#v-caption[hidden]") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#v-prev[hidden]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#v-next[hidden]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#v-counter[hidden]") |> Enum.count() == 1
    end
  end

  describe "card_drawer/1 ai_result changes rendering" do
    # Regression (TH8 prod crash loop): an agent wrote `ai_result["changes"]` as a list of
    # structured maps (%{"change"=>_, "file"=>_, "lines"=>_}) instead of plain strings. The
    # drawer rendered each with `{change}`, and HEEx cannot interpolate a Map (no
    # Phoenix.HTML.Safe impl) → Protocol.UndefinedError on every mount → crash loop.
    defp drawer_assigns(ai_result) do
      %{
        id: "test-drawer",
        ref: "RLY-9",
        board_slug: "b",
        card: %{
          title: "Card",
          description: "d",
          acceptance_criteria: nil,
          spec: nil,
          tag: nil,
          status: :working,
          progress: nil,
          blocked_since: nil,
          branch: nil,
          plan: nil,
          pr_url: nil,
          rejection: nil,
          sub_tasks: [],
          ai_result: ai_result,
          owners: [],
          inserted_at: ~U[2026-07-01 09:00:00Z],
          updated_at: ~U[2026-07-06 15:30:00Z]
        },
        stage_name: "Code",
        stage_owner: :ai,
        active_owner: :ai,
        current_user_id: 1,
        health: :live,
        close_patch: "/x",
        title_form: to_form(%{"title" => "Card"}, as: :card),
        status_form: to_form(%{"status" => "working"}, as: :card),
        stages: [%{id: 4, name: "Code"}],
        conversation: [],
        activity: [],
        comment_form: to_form(%{"body" => ""}, as: :comment)
      }
    end

    # RE316: Changes and Screenshots sit behind Show more, so tests of their rendering expand.
    defp expanded_drawer_assigns(ai_result), do: Map.put(drawer_assigns(ai_result), :expanded_ai_result, true)

    test "renders structured (map) changes without crashing" do
      ai_result = %{
        "summary" => "did the thing",
        "changes" => [%{"change" => "rewrote the query", "file" => "lib/foo.ex", "lines" => "10-20"}]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ "rewrote the query"
    end

    test "still renders plain string changes" do
      ai_result = %{"summary" => "s", "changes" => ["fixed the login bug"]}

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ "fixed the login bug"
    end
  end

  # RE316 collapses Changes and Screenshots behind Show more, so these regressions render the
  # drawer expanded — the shapes they guard are only read once the detail is on screen.
  describe "card_drawer/1 ai_result screens rendering" do
    # Regression (TH95 prod crash loop): the smoke node wrote `ai_result["screens"]` as a list of
    # bare screenshot *paths* instead of the documented `%{"url"=>_, "caption"=>_}` maps. The
    # drawer indexed each entry with `screen["url"]` → FunctionClauseError in Access.get/3 on a
    # binary → the LiveView died on every mount → the browser reconnected forever.
    test "renders bare-string screens without crashing" do
      ai_result = %{
        "summary" => "s",
        "screens" => ["/Users/jeremy/src/throughway/tmp/smoke/12-state3a-review.png"]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ ~s(id="ai-result-screens")
      # A local filesystem path is not fetchable by the browser, so it captions the placeholder
      # rather than becoming a broken <img src>.
      assert html =~ "12-state3a-review.png"
      refute html =~ ~s(src="/Users/jeremy)
    end

    test "a bare string that is a real URL still renders as the image" do
      ai_result = %{"summary" => "s", "screens" => ["https://example.com/shot.png"]}

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ ~s(src="https://example.com/shot.png")
    end

    test "still renders documented map screens" do
      ai_result = %{
        "summary" => "s",
        "screens" => [%{"url" => "https://example.com/a.png", "caption" => "The drawer"}]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ ~s(src="https://example.com/a.png")
      assert html =~ "The drawer"
    end

    test "a root-relative url this app serves still renders as the image" do
      ai_result = %{"summary" => "s", "screens" => [%{"url" => "/images/logo_light_128.png"}]}

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ ~s(src="/images/logo_light_128.png")
    end

    test "a map screen whose url is not a usable image src falls back to the placeholder" do
      ai_result = %{"summary" => "s", "screens" => [%{"url" => "tmp/smoke/a.png"}]}

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      refute html =~ ~s(src="tmp/smoke/a.png")
      assert html =~ "a.png"
    end

    # RE322 — `relay attach` returns `/attachments/<uuid>`, which agents write into `screens`. It is
    # a router route, not a static path, so the TH95 fetchability check drew every uploaded
    # screenshot as the placeholder.
    test "an uploaded attachment url renders as the image, in both the map and bare-string shapes" do
      uuid = "0b9f3c5e-8a1d-4e2f-9c7b-3d6a1e5f2b40"

      ai_result = %{
        "summary" => "s",
        "screens" => [%{"url" => "/attachments/#{uuid}", "caption" => "Shot"}, "/attachments/#{uuid}"]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      imgs = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s(#ai-result-screens img[src="/attachments/#{uuid}"]))
      assert Enum.count(imgs) == 2
    end

    test "paths that only look like attachments, and agent-local paths, still fall back to the placeholder" do
      ai_result = %{
        "summary" => "s",
        "screens" => [
          "/attachments",
          %{"url" => "/attachments/"},
          "/Users/me/tmp/smoke/12-review.png",
          %{"url" => "tmp/smoke/a.png"}
        ]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#ai-result-screens figure") |> Enum.count() == 4
      assert doc |> LazyHTML.query("#ai-result-screens img") |> Enum.count() == 0
      assert html =~ "12-review.png"
      assert html =~ "a.png"
    end

    # RE322 D3 — the carousel captions a screenshot with its figcaption; the <img> mirrors it so the
    # JS never walks the figure. Blank (not absent) when there is no caption: the img's `alt` falls
    # back to a generic "Screenshot", which must not become the viewer's caption.
    test "a screenshot img carries its caption as data-caption, blank when it has none" do
      ai_result = %{
        "summary" => "s",
        "screens" => [%{"url" => "https://example.com/a.png", "caption" => "The drawer"}, "https://example.com/b.png"]
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))
      doc = LazyHTML.from_fragment(html)

      assert doc
             |> LazyHTML.query(~s(#ai-result-screens img[src="https://example.com/a.png"][data-caption="The drawer"]))
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s(#ai-result-screens img[src="https://example.com/b.png"][data-caption=""]))
             |> Enum.count() == 1
    end
  end

  describe "card_drawer/1 ai_result shape tolerance" do
    # `ai_result` is a free-form blob written by an agent over the API, and a drawer crash takes
    # the whole board down for that user (TH8, TH95). No shape a caller can put in the blob may
    # raise during render.
    test "scalar values where lists are documented do not crash the drawer" do
      ai_result = %{
        "summary" => %{"text" => "a map, not a string"},
        "changes" => "one change, not a list",
        "screens" => "one screen, not a list",
        "deploy_url" => %{"href" => "nope"}
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      assert html =~ ~s(id="ai-result")
      assert html =~ "one change, not a list"
    end
  end

  describe "card_drawer/1 AI Result placement (RE316)" do
    test "renders no AI Result section when ai_result is nil" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(nil))

      refute html =~ ~s(id="ai-result")
      refute html =~ "AI Result"
    end

    test "renders no AI Result section (no empty violet box) when ai_result is an empty map" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(%{}))

      refute html =~ ~s(id="ai-result")
      refute html =~ "AI Result"
    end

    test "the AI Result section sits directly above Description" do
      html =
        render_component(&CoreComponents.card_drawer/1, drawer_assigns(%{"summary" => "Did the thing"}))

      {ai_result, _} = :binary.match(html, ~s(id="ai-result"))
      {description, _} = :binary.match(html, ~s(id="test-drawer-description"))
      {spec, _} = :binary.match(html, ~s(id="test-drawer-spec"))

      assert ai_result < description
      assert description < spec
    end

    test "the AI Result skeleton sits directly above the Description skeleton while loading" do
      html = render_component(&CoreComponents.card_drawer/1, loading_drawer_assigns())

      {ai_skeleton, _} = :binary.match(html, ~s(id="ai-result-skeleton"))
      {description_skeleton, _} = :binary.match(html, ~s(id="d-description-skeleton"))
      {plan_skeleton, _} = :binary.match(html, ~s(id="card-plan-skeleton"))

      assert ai_skeleton < description_skeleton
      assert description_skeleton < plan_skeleton
    end
  end

  describe "card_drawer/1 AI Result Show more (RE316)" do
    defp full_ai_result do
      %{
        "summary" => "Did the thing",
        "changes" => ["changed A"],
        "screens" => [%{"url" => "https://placehold.co/320x180", "caption" => "home"}],
        "deploy_url" => "https://example.com"
      }
    end

    defp ai_query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp ai_text(html, selector), do: html |> ai_query(selector) |> LazyHTML.text() |> String.trim()

    defp ai_count(html, selector), do: html |> ai_query(selector) |> Enum.count()

    test "collapsed (default) shows the full summary, the deploy link and Show more, but not changes or screens" do
      long_summary = String.duplicate("Did the thing. ", 40)
      ai_result = Map.put(full_ai_result(), "summary", long_summary)

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert ai_text(html, "#ai-result #ai-result-summary") == String.trim(long_summary)
      assert ai_count(html, "#ai-result #ai-result-deploy") == 1
      assert ai_text(html, "#ai-result #ai-result-show-more") == "Show more"
      assert ai_count(html, "#ai-result-show-more.commit-field-showmore") == 1
      assert ai_count(html, "#ai-result-show-more[phx-click=toggle_ai_result]") == 1
      assert ai_count(html, "#ai-result-changes") == 0
      assert ai_count(html, "#ai-result-screens") == 0
      assert ai_count(html, "#ai-result-changes-group") == 0
      assert ai_count(html, "#ai-result-screens-group") == 0
    end

    test "expanded shows a Changes label above the checklist and a Screenshots label above the thumbnails, inside the box" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          Map.put(drawer_assigns(full_ai_result()), :expanded_ai_result, true)
        )

      assert ai_text(html, "#ai-result #ai-result-changes-group > span") == "Changes"
      assert ai_count(html, "#ai-result-changes-group > span + ul#ai-result-changes") == 1
      assert ai_text(html, "#ai-result-changes") =~ "changed A"

      assert ai_text(html, "#ai-result #ai-result-screens-group > span") == "Screenshots"
      assert ai_count(html, "#ai-result-screens-group > span + div#ai-result-screens") == 1
      assert ai_text(html, "#ai-result-screens figcaption") == "home"
      assert ai_count(html, "#ai-result-screens img.cursor-zoom-in") == 1

      assert ai_count(html, "#ai-result #ai-result-summary") == 1
      assert ai_count(html, "#ai-result #ai-result-deploy") == 1
      assert ai_text(html, "#ai-result #ai-result-show-more") == "Show less"
    end

    test "expanded renders only the labels whose lists are non-empty" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          Map.put(
            drawer_assigns(%{"summary" => "s", "changes" => ["changed A"], "screens" => []}),
            :expanded_ai_result,
            true
          )
        )

      assert ai_count(html, "#ai-result-changes-group") == 1
      assert ai_count(html, "#ai-result-screens-group") == 0
      refute html =~ "Screenshots"
    end

    test "there is no Show more when there are no changes or screens to reveal" do
      for ai_result <- [
            %{"summary" => "Just a summary"},
            %{"summary" => "Just a summary", "changes" => [], "screens" => []}
          ] do
        html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

        assert ai_text(html, "#ai-result-summary") == "Just a summary"
        assert ai_count(html, "#ai-result-show-more") == 0
      end
    end

    test "with no summary but changes, the box still renders with just Show more" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(%{"changes" => ["changed A"]}))

      assert ai_count(html, "#ai-result") == 1
      assert ai_count(html, "#ai-result-summary") == 0
      assert ai_text(html, "#ai-result #ai-result-show-more") == "Show more"
    end
  end

  describe "RE237 shared theme controls" do
    test "modal_scrim renders the shared class and no inline color" do
      html = render_component(&CoreComponents.modal_scrim/1, %{})

      assert html =~ ~s(class="modal-scrim")
      refute html =~ "oklch("
    end

    test "modal_scrim merges an extra class and passes globals through" do
      html = render_component(&CoreComponents.modal_scrim/1, %{class: "z-40", "phx-click": "close"})

      assert html =~ "modal-scrim"
      assert html =~ "z-40"
      assert html =~ ~s(phx-click="close")
    end

    test "meta_label is the mono 10px data label at the base-content/55 ink tier" do
      html =
        render_component(&CoreComponents.meta_label/1, %{
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "RLY-1" end}]
        })

      assert html =~ "font-mono"
      assert html =~ "text-[10px]"
      # oklch(0.62 0.02 255) → P = round5((1 - 0.62) / 0.74 * 100) = 50, +5 on the alpha ink
      # branch (see app.css) → 55
      assert html =~ "text-base-content/55"
      assert html =~ "RLY-1"
      refute html =~ "ui-monospace"
    end

    test "meta_label's tone overrides the default ink tier" do
      html =
        render_component(&CoreComponents.meta_label/1, %{
          tone: "text-secondary",
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "AI" end}]
        })

      assert html =~ "text-secondary"
      refute html =~ "text-base-content/55"
    end

    test "page_heading keeps the artboard's 22px/600/-0.02em type at full ink" do
      html =
        render_component(&CoreComponents.page_heading/1, %{
          class: "mb-1.5",
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Stages" end}]
        })

      assert html =~ "<h1"
      assert html =~ "text-[22px]"
      assert html =~ "font-semibold"
      assert html =~ "tracking-[-0.02em]"
      assert html =~ "text-base-content"
      assert html =~ "mb-1.5"
      refute html =~ "oklch("
    end
  end

  describe "dependency_list/1 and the blocked chip (RE93)" do
    test "a blocked card face wears a ghost lock chip, pluralized, never amber" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c1",
          ref: "RE1",
          title: "Dependent",
          blocked_count: 3
        )

      assert html =~ "card-blocked-chip"
      assert html =~ "badge badge-ghost badge-sm"
      assert html =~ "hero-lock-closed"
      assert html =~ "Blocked by 3 cards"
      refute html =~ "badge-warning"
    end

    test "the chip reads in the singular for one blocker, and is absent at zero" do
      one = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RE1", title: "T", blocked_count: 1)
      assert one =~ "Blocked by 1 card"
      refute one =~ "Blocked by 1 cards"

      none = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RE1", title: "T")
      refute none =~ "card-blocked-chip"
    end

    test "the list ticks and strikes through a satisfied blocker and offers ✕ only when removable" do
      html =
        render_component(&CoreComponents.dependency_list/1,
          id: "blocked-by",
          cards: [
            %{ref: "RE2", title: "Waiting on this", satisfied?: false},
            %{ref: "RE3", title: "Already done", satisfied?: true}
          ],
          removable: true
        )

      assert html =~ "hero-check-circle"
      assert html =~ "text-success"
      assert html =~ "line-through"
      assert html =~ ~s(phx-value-ref="RE2")
      assert html =~ "hero-x-mark"
    end

    test "a read-only list has no remove control, and an empty one says so" do
      read_only =
        render_component(&CoreComponents.dependency_list/1,
          id: "blocks",
          cards: [%{ref: "RE2", title: "Later"}]
        )

      refute read_only =~ "remove_dependency"

      empty = render_component(&CoreComponents.dependency_list/1, id: "blocks", cards: [])
      assert empty =~ "None"
    end
  end
end
