defmodule RelayWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias RelayWeb.CardMedia
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

  describe "copy_button/1 (RE324)" do
    test "renders an icon button carrying the exact text to copy and an accessible name" do
      html =
        render_component(&CoreComponents.copy_button/1,
          id: "copy-x",
          text: "re-324-a/very#long-branch",
          label: "Copy branch name"
        )

      button = html |> LazyHTML.from_fragment() |> LazyHTML.query("button#copy-x")

      assert Enum.count(button) == 1
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "data-copy-text") == ["re-324-a/very#long-branch"]
      assert LazyHTML.attribute(button, "aria-label") == ["Copy branch name"]
      assert LazyHTML.attribute(button, "title") == ["Copy branch name"]
      assert [hook] = LazyHTML.attribute(button, "phx-hook")
      assert hook =~ "CopyButton"
    end

    test "shows a clipboard icon at rest and a success check in the copied state" do
      html = render_component(&CoreComponents.copy_button/1, id: "copy-y", text: "x")
      doc = LazyHTML.from_fragment(html)

      assert [class] = doc |> LazyHTML.query("button#copy-y") |> LazyHTML.attribute("class")
      assert class =~ "btn btn-ghost btn-xs btn-square"
      assert class =~ "group"
      assert class =~ "data-[copied=true]:text-success"

      assert doc |> LazyHTML.query(".copy-button-idle .hero-clipboard-document") |> Enum.count() == 1
      assert doc |> LazyHTML.query(".copy-button-done.hidden .hero-check") |> Enum.count() == 1
      assert [done] = doc |> LazyHTML.query(".copy-button-done") |> LazyHTML.attribute("class")
      assert done =~ "group-data-[copied=true]:inline-flex"
    end

    test "defaults its accessible name to Copy" do
      html = render_component(&CoreComponents.copy_button/1, id: "copy-z", text: "x")
      assert html =~ ~s(aria-label="Copy")
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

  describe "board_card/1 open highlight (RE389)" do
    test "open: true renders a bare data-open on the article" do
      html = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RL3", title: "T", open: true)

      assert [_article] =
               html |> LazyHTML.from_fragment() |> LazyHTML.query("article.board-card[data-open]") |> Enum.to_list()
    end

    test "open omitted renders no data-open" do
      html = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RL3", title: "T")

      refute html =~ "data-open"
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

    # RE409 — the chip is the link to the stage's flow (card mockup "AI chip is the flow link —
    # shown iff a flow works in the stage").
    test "an enabled flow renders the chip as a link to the flow editor" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          type: :work,
          flow: %{key: "code", enabled: true},
          board_slug: "acme",
          category: :in_progress,
          stage_id: 4
        )

      chip = chip(html, "stage-col-4-ai-listening")
      assert LazyHTML.tag(chip) == ["a"]
      assert LazyHTML.attribute(chip, "href") == ["/board/acme/flows/code"]
      assert LazyHTML.attribute(chip, "data-tip") == ["Edit the code flow →"]
      assert LazyHTML.attribute(chip, "data-flow-key") == ["code"]
      assert LazyHTML.attribute(chip, "data-flow-enabled") == ["true"]
      assert LazyHTML.to_html(chip) =~ "hero-arrow-up-right-mini"
      assert html =~ "color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content))"
    end

    test "a disabled flow renders the dashed, struck-through chip that still links" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Plan",
          type: :planning,
          flow: %{key: "plan", enabled: false},
          board_slug: "acme",
          category: :planning,
          stage_id: 4
        )

      chip = chip(html, "stage-col-4-ai-listening")
      assert LazyHTML.tag(chip) == ["a"]
      assert LazyHTML.attribute(chip, "href") == ["/board/acme/flows/plan"]
      assert LazyHTML.attribute(chip, "data-flow-enabled") == ["false"]
      assert LazyHTML.attribute(chip, "data-tip") == ["The plan flow is off — edit to turn it on →"]
      assert LazyHTML.to_html(chip) =~ "dashed"
      assert LazyHTML.to_html(chip) =~ "line-through"
    end

    test "read-only with an enabled flow renders a plain label, not a link" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Spec",
          type: :planning,
          flow: %{key: "spec", enabled: true},
          read_only: true,
          category: :planning,
          stage_id: 3
        )

      chip = chip(html, "stage-col-3-ai-listening")
      assert LazyHTML.tag(chip) == ["span"]
      assert LazyHTML.attribute(chip, "href") == []
      assert LazyHTML.attribute(chip, "title") == ["Relay AI works this stage"]
      refute LazyHTML.to_html(chip) =~ "hero-arrow-up-right-mini"
      refute html =~ "<a "
    end

    test "read-only with a disabled flow renders no chip" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Plan",
          type: :planning,
          flow: %{key: "plan", enabled: false},
          read_only: true,
          category: :planning,
          stage_id: 3
        )

      refute html =~ "stage-col-3-ai-listening"
    end

    test "a collapsed strip carries the chip as a dot-only link" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-6",
          name: "Code",
          type: :work,
          flow: %{key: "code", enabled: true},
          board_slug: "acme",
          stage_id: 6,
          count: 0,
          collapsed: true
        )

      link =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-strip-6 a[href='/board/acme/flows/code'][data-flow-key='code']")

      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "id") == ["stage-col-6-ai-listening"]
      assert LazyHTML.attribute(link, "title") == ["Edit the code flow →"]
      refute LazyHTML.text(link) =~ "AI"
    end

    test "no flow renders no chip" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          category: :unstarted,
          stage_id: 1
        )

      refute html =~ "ai-listening"
    end

    test "the pager chip is padded for touch and carries no tooltip" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Spec",
          type: :planning,
          flow: %{key: "spec", enabled: true},
          board_slug: "acme",
          category: :planning,
          stage_id: 3,
          pager: true
        )

      chip = chip(html, "stage-col-3-ai-listening")
      assert LazyHTML.attribute(chip, "data-tip") == []
      [class] = LazyHTML.attribute(chip, "class")
      refute class =~ "tooltip"
      [style] = LazyHTML.attribute(chip, "style")
      assert style =~ "padding:6px 9px"
    end

    test "a complete-category stage hides the chip even with a flow" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-8",
          name: "Done",
          type: :done,
          flow: %{key: "x", enabled: true},
          board_slug: "acme",
          category: :complete,
          stage_id: 8
        )

      refute html =~ "ai-listening"
    end

    test "the compose CTA hands to AI for any flow, enabled or not, and adds without one" do
      render = fn flow ->
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          type: :work,
          flow: flow,
          board_slug: "acme",
          category: :in_progress,
          stage_id: 4,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )
      end

      submit = fn html ->
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-4-compose-submit")
        |> LazyHTML.text()
        |> String.trim()
      end

      assert submit.(render.(nil)) == "Add"
      assert submit.(render.(%{key: "code", enabled: true})) == "Hand to AI"
      assert submit.(render.(%{key: "code", enabled: false})) == "Hand to AI"
    end

    test "the composer is owner-aware: AI stage hands to AI, human stage adds; both submit blue" do
      ai =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          type: :work,
          flow: %{key: "code", enabled: true},
          board_slug: "acme",
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

  describe "flow_chip/1" do
    test "the settings variant links to the editor and names the flow" do
      html =
        render_component(&CoreComponents.flow_chip/1,
          id: "stage-9-ai-flow",
          variant: :settings,
          flow: %{key: "design", enabled: true},
          board_slug: "acme"
        )

      chip = html |> LazyHTML.from_fragment() |> LazyHTML.query("#stage-9-ai-flow")
      assert LazyHTML.tag(chip) == ["a"]
      assert LazyHTML.attribute(chip, "href") == ["/board/acme/flows/design"]
      assert LazyHTML.text(chip) =~ "design flow"
      assert LazyHTML.attribute(chip, "data-tip") == []
    end

    # RE432: a flow paused by a broken board shape turns its chip amber.
    test "11. a paused header chip reads \"AI paused\" in amber" do
      chip = fn paused ->
        html =
          render_component(&CoreComponents.flow_chip/1,
            id: "c",
            variant: :header,
            flow: %{key: "deploy", enabled: true},
            board_slug: "acme",
            paused: paused
          )

        html |> LazyHTML.from_fragment() |> LazyHTML.query("#c")
      end

      paused = chip.(true)
      assert paused |> LazyHTML.text() |> String.trim() == "AI paused"
      assert LazyHTML.attribute(paused, "data-flow-paused") == ["true"]
      assert [style] = LazyHTML.attribute(paused, "style")
      assert style =~ "var(--color-warning)"
      assert LazyHTML.attribute(paused, "aria-label") == ["Flow paused — see the banner"]

      healthy = chip.(false)
      assert healthy |> LazyHTML.text() |> String.trim() == "AI"
      assert LazyHTML.attribute(healthy, "data-flow-paused") == ["false"]
    end

    test "11. a paused settings chip keeps its label; a read-only paused chip is amber too" do
      settings =
        render_component(&CoreComponents.flow_chip/1,
          id: "c",
          variant: :settings,
          flow: %{key: "deploy", enabled: true},
          board_slug: "acme",
          paused: true
        )

      assert settings |> LazyHTML.from_fragment() |> LazyHTML.query("#c") |> LazyHTML.text() =~ "deploy flow"

      read_only_html =
        render_component(&CoreComponents.flow_chip/1,
          id: "c",
          flow: %{key: "deploy", enabled: true},
          read_only: true,
          paused: true
        )

      read_only = read_only_html |> LazyHTML.from_fragment() |> LazyHTML.query("#c")

      assert read_only |> LazyHTML.text() |> String.trim() == "AI paused"
      assert LazyHTML.attribute(read_only, "data-flow-paused") == ["true"]
      assert [style] = LazyHTML.attribute(read_only, "style")
      assert style =~ "var(--color-warning)"
      refute style =~ "var(--color-secondary) 10%"
    end
  end

  describe "compact_card_row/1 (RE377)" do
    test "renders one 44px line: dot · mono ref · truncating title, tappable to open the card" do
      html =
        render_component(&CoreComponents.compact_card_row/1,
          id: "stage_cards_7-1",
          ref: "RE376",
          title: "Retrieve a card's HTML mockups from the API",
          status: :ready,
          done: true
        )

      assert html =~ ~s(id="stage_cards_7-1")
      assert html =~ "compact-card-row"
      # mockup B row: flex min-h-11 items-center gap-2.5 border-b border-base-300 px-3
      assert html =~ "min-h-11"
      assert html =~ "gap-2.5"
      assert html =~ "border-b border-base-300"
      assert html =~ ~s(phx-click="select_card")
      assert html =~ ~s(phx-value-ref="RE376")
      # dot: size-1.5 rounded-full, Done → bg-success
      assert html =~ "compact-card-row-dot size-1.5 flex-none rounded-full bg-success"
      # ref: w-12 mono 10px
      assert html =~ "compact-card-row-ref w-12 flex-none font-mono text-[10px] text-base-content/50"
      assert html =~ "RE376"
      # title: truncates on one line
      assert html =~ "compact-card-row-title min-w-0 flex-1 truncate text-[13px]"
      assert html =~ "Retrieve a card&#39;s HTML mockups from the API"
      refute html =~ ~s(draggable="true")
    end

    test "the dot follows status first, then the baton holder" do
      dot = fn attrs ->
        html =
          render_component(
            &CoreComponents.compact_card_row/1,
            Keyword.merge([id: "r", ref: "RE1", title: "T"], attrs)
          )

        [_, class] = Regex.run(~r/compact-card-row-dot size-1\.5 flex-none rounded-full ([\w-]+)/, html)
        class
      end

      assert dot.(status: :failed) == "bg-error"
      assert dot.(status: :needs_input) == "bg-warning"
      assert dot.(status: :in_review) == "bg-warning"
      assert dot.(status: :working) == "bg-secondary"
      assert dot.(status: :ready, active_owner: :ai) == "bg-secondary"
      assert dot.(status: :ready, active_owner: :human) == "bg-primary"
      assert dot.(status: :ready) == "bg-base-300"
      # a status with no dot of its own falls through to the baton holder
      assert dot.(status: :queued, active_owner: :ai) == "bg-secondary"
      assert dot.(status: :queued, active_owner: :human) == "bg-primary"
    end
  end

  describe "stage_column/1 in pager mode (RE377)" do
    @compact_cards [
      {"stage_cards_9-1",
       %{id: 1, title: "First compact", tag: nil, ref_number: 1, status: :ready, sub_tasks: [], owners: []}},
      {"stage_cards_9-2",
       %{id: 2, title: "Second compact", tag: nil, ref_number: 2, status: :working, sub_tasks: [], owners: []}}
    ]

    test "collapsed + pager renders the compact page (mockup B), not the strip" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Done",
          type: :done,
          stage_id: 9,
          board_key: "RE",
          count: 2,
          collapsed: true,
          pager: true,
          cards: @compact_cards
        )

      refute html =~ "stage-strip"
      assert html =~ ~s(id="stage-col-3")
      assert html =~ "stage-column stage-compact"
      assert html =~ ~s(data-stage-id="9")
      assert html =~ ~s(data-collapsed="true")

      # header: name · count · dashed collapsed badge · Show cards (≥44px)
      assert html =~ ~s(id="stage-col-3-compact-header")
      assert html =~ "flex flex-none items-center gap-2 px-3 pb-2 pt-2.5"
      assert html =~ "text-[13px] font-semibold"
      assert html =~ "font-mono text-[10.5px] text-base-content/45"

      assert html =~
               "badge badge-ghost badge-sm gap-1 border-dashed border-base-content/25 font-mono text-[9.5px] text-base-content/60"

      assert html =~ ~s(id="stage-col-3-collapsed-badge")
      assert html =~ ~s(id="stage-col-3-show-cards")
      assert html =~ ~s(phx-click="expand_stage")
      assert html =~ "btn btn-ghost btn-sm min-h-11 px-2 text-[12px] text-primary"
      assert html =~ "Show cards"

      # one bordered rounded list with a row per card
      assert html =~ ~s(id="stage-col-3-list")
      assert html =~ "rounded-[10px]"
      assert html =~ ~s(id="stage-col-3-rows")
      assert html =~ ~s(id="stage_cards_9-1")
      assert html =~ "RE1"
      assert html =~ "First compact"
      assert html =~ "RE2"

      # not a compose target, no full faces, no empty state
      refute html =~ ~s(id="stage-col-3-new-card")
      refute html =~ "board-card"
      refute html =~ ~s(id="stage-col-3-compact-empty")
    end

    test "a collapsed terminal stage with more cards than revealed shows the 'N more' button" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Done",
          type: :done,
          stage_id: 9,
          board_key: "RE",
          count: 42,
          terminal: true,
          revealed: 9,
          collapsed: true,
          pager: true,
          cards: @compact_cards
        )

      assert html =~ ~s(id="stage-col-3-rows-more")
      assert html =~ ~s(phx-click="show_more_done")
      assert html =~ "btn btn-ghost btn-sm mx-3 my-2 flex-none font-mono text-[11px] text-base-content/65"
      assert html =~ ~r/33\s*more/
    end

    test "a non-terminal collapsed stage shows no 'N more' button" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Code",
          type: :work,
          stage_id: 9,
          count: 2,
          collapsed: true,
          pager: true,
          cards: @compact_cards
        )

      refute html =~ "-rows-more"
    end

    test "an empty collapsed stage in pager mode shows the empty note" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          type: :queue,
          stage_id: 1,
          count: 0,
          collapsed: true,
          pager: true
        )

      assert html =~ ~s(id="stage-col-1-compact-empty")
      assert html =~ "No cards yet"
    end

    test "sub-lane cards are listed as rows too, in their own stream lists" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-5",
          name: "Code",
          type: :work,
          stage_id: 4,
          count: 0,
          collapsed: true,
          pager: true,
          sublanes: [
            %{
              id: 41,
              name: "Review",
              lane: :review,
              owner: :human,
              count: 1,
              cards: [
                {"stage_cards_41-7",
                 %{id: 7, title: "In review row", tag: nil, ref_number: 7, status: :in_review, sub_tasks: [], owners: []}}
              ]
            }
          ]
        )

      assert html =~ ~s(id="stage-col-5-rows-41")
      assert html =~ "In review row"
      refute html =~ ~s(id="stage-col-5-compact-empty")
    end

    test "collapsed without pager is still the desktop strip" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-3",
          name: "Done",
          type: :done,
          stage_id: 9,
          count: 2,
          collapsed: true,
          cards: @compact_cards
        )

      assert html =~ ~s(id="stage-strip-9")
      refute html =~ "stage-compact"
      refute html =~ "compact-card-row"
    end

    test "an expanded stage shows Show as list only in pager mode" do
      base = [id: "stage-col-3", name: "Done", type: :done, stage_id: 9, count: 2, cards: @compact_cards]

      pager_html = render_component(&CoreComponents.stage_column/1, Keyword.put(base, :pager, true))
      assert pager_html =~ ~s(id="stage-col-3-show-as-list")
      assert pager_html =~ ~s(phx-click="collapse_stage")
      assert pager_html =~ "Show as list"
      assert pager_html =~ "board-card"
      refute pager_html =~ "collapsed-badge"

      desktop_html = render_component(&CoreComponents.stage_column/1, base)
      refute desktop_html =~ "show-as-list"
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

      # artboard line 228: 7px radius, 7px/8px/7px/11px padding, 8px gap — RE427 splits it into
      # the image control's box and the row inside it (the pending thumbnails go under the row)
      assert html =~ "relative rounded-[7px] border border-base-300 bg-base-100 py-[7px] pl-[11px] pr-2"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#card-drawer-note-images > div.flex.items-start.gap-2 > #card-drawer-comment-input")
             |> Enum.count() == 1

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

    test "plan and tasks are one Plan section: header count + bar, then the task rows (RE356)" do
      attrs =
        drawer_attrs(
          %{plan: "Short header.", sub_tasks: [%{id: 1, title: "a", done: true}, %{id: 2, title: "b", done: false}]},
          %{}
        )

      doc = (&CoreComponents.card_drawer/1) |> render_component(attrs) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#card-plan .commit-field-accent.bg-secondary") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#card-plan-count") |> LazyHTML.text() =~ "1/2"
      assert doc |> LazyHTML.query("#card-plan #card-plan-view") |> LazyHTML.text() =~ "Short header."
      assert doc |> LazyHTML.query("#card-plan #card-plan-tasks #sub-task-1") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#card-plan #card-plan-tasks #sub-task-2") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#sub-tasks") |> Enum.count() == 0
    end

    test "the plan header's progress bar keeps the capped inline 4px green bar" do
      attrs = drawer_attrs(%{sub_tasks: [%{id: 1, title: "a", done: true}, %{id: 2, title: "b", done: false}]}, %{})
      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ "h-1 max-w-[120px] flex-1 overflow-hidden rounded-full bg-base-300"
      assert html =~ "h-full rounded-full bg-success"
      assert html =~ "width:50%"
    end

    test "no plan and no tasks shows the dashed empty-state copy and no task list" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_attrs(%{sub_tasks: [], plan: nil}, %{}))

      assert html =~ "No plan yet — the Plan stage writes a short header and its tasks together."
      assert html =~ "commit-field-placeholder"
      refute html =~ ~s(id="card-plan-tasks")
      refute html =~ ~s(id="card-plan-count")
    end

    test "an archived card renders the plan read-only in #card-plan-body, tasks still listed" do
      attrs =
        drawer_attrs(
          %{plan: "Archived **plan**", sub_tasks: [%{id: 1, title: "a", done: false}]},
          %{archived: true}
        )

      doc = (&CoreComponents.card_drawer/1) |> render_component(attrs) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#card-plan #card-plan-body.md strong") |> LazyHTML.text() == "plan"
      assert doc |> LazyHTML.query("#card-plan-display") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#card-plan #sub-task-1") |> Enum.count() == 1
    end

    test "the drawer forwards open/full/in-flight state to the task rows" do
      tasks = [%{id: 1, title: "a", done: false, body: "Open body"}, %{id: 2, title: "b", done: false, body: "x"}]

      attrs =
        drawer_attrs(%{sub_tasks: tasks}, %{open_task_id: 1, task_full?: false, in_flight_task_id: 2})

      doc = (&CoreComponents.card_drawer/1) |> render_component(attrs) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#sub-task-1-body") |> LazyHTML.text() =~ "Open body"
      assert doc |> LazyHTML.query("#sub-task-2[data-in-flight=true] #sub-task-2-agent-here") |> Enum.count() == 1
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

    # RE335 D5 — the board's Archive is unguarded but now cancels the card's active run, so the
    # native confirm says so. Only the copy changes; no new dialog.
    test "Archive's confirm keeps the plain copy when the card has no active run" do
      attrs = drawer_attrs(%{}, %{overflow_open: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~ ~s(data-confirm="Archive this card? You can restore it from Archived.")
      refute html =~ "Its active run will be cancelled."
    end

    test "Archive's confirm warns the active run will be cancelled when there is one" do
      attrs = drawer_attrs(%{}, %{overflow_open: true, active_run?: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      assert html =~
               ~s(data-confirm="Archive this card? Its active run will be cancelled. You can restore the card from Archived.")
    end

    test "an archived card renders no ⋯ overflow button at all" do
      attrs = drawer_attrs(%{}, %{archived: true, overflow_open: true})

      html = render_component(&CoreComponents.card_drawer/1, attrs)

      refute html =~ ~s(id="card-drawer-overflow")
      refute html =~ ~s(id="archive-card-button")
    end

    # RE394 — the drawer's one-off server actions show the shared pressed face in their group.
    defp drawer_doc(card_overrides, extra) do
      (&CoreComponents.card_drawer/1)
      |> render_component(drawer_attrs(card_overrides, extra))
      |> LazyHTML.from_fragment()
    end

    test "Archive in the ⋯ menu presses to Archiving…; the menu is the action group (RE394)" do
      doc = drawer_doc(%{}, %{overflow_open: true})

      assert "action-group" in btn_classes(doc, "#card-drawer-overflow-menu")
      assert "pending-action" in btn_classes(doc, "#archive-card-button")
      assert attr_of(doc, "#archive-card-button", "role") == ["menuitem"]
      assert attr_of(doc, "#archive-card-button", "phx-click") == ["archive_card"]
      assert text_of(doc, "#archive-card-button .pending-idle") == "Archive"
      assert text_of(doc, "#archive-card-button .pending-face") == "Archiving…"
    end

    test "an archived card's Restore presses to Restoring… (RE394)" do
      doc = drawer_doc(%{}, %{archived: true})

      assert "action-group" in btn_classes(doc, "#card-archived-banner")
      assert text_of(doc, "#restore-card-button .pending-idle") == "Restore"
      assert text_of(doc, "#restore-card-button .pending-face") == "Restoring…"
    end

    test "Add note presses to Adding…; the comment form is the action group (RE394)" do
      doc = drawer_doc(%{}, %{})
      submit = "#card-drawer-comment-form button[type=submit]"

      assert "action-group" in btn_classes(doc, "#card-drawer-comment-form")
      assert "pending-action" in btn_classes(doc, submit)
      assert text_of(doc, "#{submit} .pending-idle") == "Add note"
      assert text_of(doc, "#{submit} .pending-face") == "Adding…"
    end

    test "Take over presses to Taking over… beside the owner's ✕ (RE394)" do
      doc = drawer_doc(%{owners: [%{actor_type: :agent, user_id: nil}]}, %{active_owner: :ai})

      assert "action-group" in btn_classes(doc, ".rail-owner")
      assert text_of(doc, "#card-drawer-take-over .pending-idle") == "Take over"
      assert text_of(doc, "#card-drawer-take-over .pending-face") == "Taking over…"
      refute "pending-action" in btn_classes(doc, "#card-drawer-remove-owner-agent")
    end

    test "the public description's Save presses to Saving…; Cancel stays idle (RE394)" do
      doc =
        drawer_doc(%{}, %{
          vote_count: 0,
          public_description: nil,
          editing_public_desc: true,
          public_desc_form: to_form(%{"public_description" => ""})
        })

      assert "action-group" in btn_classes(doc, "#public-desc-form")
      save = "#public-desc-form button[type=submit]"
      assert btn_classes(doc, save) == ~w(btn btn-primary btn-xs pending-action)
      assert text_of(doc, "#{save} .pending-idle") == "Save"
      assert text_of(doc, "#{save} .pending-face") == "Saving…"
      refute "pending-action" in btn_classes(doc, "#public-desc-form button[phx-click=cancel_public_desc]")
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

    test "the Move-to rows carry a Moving… pressed face inside an action group (RE394)" do
      attrs =
        drawer_attrs(%{}, %{
          stage_menu_open: true,
          stages: [
            %{id: 1, name: "Plan", current?: false},
            %{id: 2, name: "Code", current?: true}
          ]
        })

      doc = LazyHTML.from_fragment(render_component(&CoreComponents.card_drawer/1, attrs))

      assert "action-group" in btn_classes(doc, "#card-drawer-stage-menu")
      assert count(doc, "button#card-drawer-move-to-1") == 1
      assert "pending-action" in btn_classes(doc, "#card-drawer-move-to-1")
      assert doc |> LazyHTML.query("#card-drawer-move-to-1") |> LazyHTML.attribute("phx-click") == ["move_card"]
      assert text_of(doc, "#card-drawer-move-to-1 .pending-face") == "Moving…"

      assert doc |> LazyHTML.query("#card-drawer-move-to-1 .pending-face") |> LazyHTML.attribute("aria-hidden") == [
               "true"
             ]

      assert "ml-auto" in btn_classes(doc, "#card-drawer-move-to-1 .pending-face")
      assert count(doc, "#card-drawer-move-to-1 .pending-face .loading.loading-spinner.loading-xs") == 1

      assert count(doc, "#card-drawer-move-to-2 .pending-face") == 0
      assert text_of(doc, "#card-drawer-move-to-2") =~ "current"
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

    test "RE393: section_label carries the stable section-label class hook" do
      html =
        render_component(&CoreComponents.section_label/1, %{
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Flow" end}]
        })

      assert [class] = html |> LazyHTML.from_fragment() |> LazyHTML.query("span") |> LazyHTML.attribute("class")
      assert "section-label" in String.split(class)
      assert class =~ "font-mono text-[10px] font-semibold uppercase tracking-[0.06em]"
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

  describe "plan_tasks/1 (RE356 — Relay Card Detail v5 · Running fine · DE4)" do
    @fence String.duplicate("`", 3)

    defp long_body, do: Enum.map_join(1..20, "\n", &"line #{&1}")

    defp code_body, do: "Intro.\n\n#{@fence}elixir\nx = 1\n#{@fence}\n\n#{@fence}\ny\n#{@fence}\n"

    defp tasks do
      [
        %{id: 1, title: "Done one", done: true, body: "Shipped."},
        %{id: 2, title: "Long one", done: false, body: long_body()},
        %{id: 3, title: "Code one", done: false, body: code_body()},
        %{id: 4, title: "Body-less", done: false, body: nil}
      ]
    end

    defp render_plan(extra \\ %{}) do
      attrs = Map.merge(%{plan: "Header text", tasks: tasks(), progress: %{done: 1, total: 4}}, extra)
      (&CoreComponents.plan_tasks/1) |> render_component(attrs) |> LazyHTML.from_fragment()
    end

    defp q(doc, selector), do: LazyHTML.query(doc, selector)
    defp count(doc, selector), do: doc |> q(selector) |> Enum.count()
    defp classes(doc, selector), do: doc |> q(selector) |> LazyHTML.attribute("class") |> List.first("")

    test "collapsed rows show the derived meta and a down chevron; a body-less row has neither" do
      doc = render_plan()

      assert doc |> q("#sub-task-2-meta") |> LazyHTML.text() == "20 lines"
      assert doc |> q("#sub-task-3-meta") |> LazyHTML.text() == "9 lines · 2 code blocks"
      assert doc |> q("#sub-task-1-meta") |> LazyHTML.text() == "1 line"
      assert count(doc, "#sub-task-2-toggle .hero-chevron-down") == 1
      assert count(doc, "#sub-task-4-meta") == 0
      assert count(doc, "#sub-task-4 .hero-chevron-down") == 0
      assert count(doc, "button#sub-task-4-toggle") == 0
      assert count(doc, "div#sub-task-4-toggle") == 1
      assert count(doc, "[id$='-body']") == 0
    end

    test "the meta line's classes match the artboard" do
      assert classes(render_plan(), "#sub-task-2-meta") =~
               "shrink-0 whitespace-nowrap font-mono text-[10px] text-base-content/50"
    end

    test "a row is a bordered box whose head holds two sibling buttons: checkbox and disclosure" do
      doc = render_plan()

      assert classes(doc, "#sub-task-2") =~ "rounded-lg border border-base-300 bg-base-200"
      assert classes(doc, "#sub-task-2-head") =~ "flex items-center gap-2 rounded-lg px-2 py-1.5"

      assert doc |> q("#sub-task-2-head > button#sub-task-2-check") |> LazyHTML.attribute("phx-click") == [
               "toggle_sub_task"
             ]

      assert doc |> q("#sub-task-2-check") |> LazyHTML.attribute("phx-value-id") == ["2"]

      assert doc |> q("#sub-task-2-head > button#sub-task-2-toggle") |> LazyHTML.attribute("phx-click") == [
               "toggle_task_open"
             ]

      assert doc |> q("#sub-task-2-toggle") |> LazyHTML.attribute("phx-value-id") == ["2"]
      assert doc |> q("#sub-task-2-toggle") |> LazyHTML.attribute("aria-expanded") == ["false"]
      assert count(doc, "button button") == 0
    end

    test "a done task has the green filled check and a muted struck-through title" do
      doc = render_plan()

      assert classes(doc, "#sub-task-1-check") =~ "border-success bg-success text-success-content"
      assert count(doc, "#sub-task-1-check .hero-check") == 1
      assert classes(doc, "#sub-task-1-toggle > span:first-child") =~ "text-base-content/55 line-through"
      assert count(doc, "#sub-task-2-check .hero-check") == 0
    end

    test "the open row renders its markdown body under a sticky opaque head, chevron up" do
      doc = render_plan(%{open_task_id: 3})

      assert classes(doc, "#sub-task-3-body") =~ "task-body md py-3 pr-3.5 pl-8"
      assert doc |> q("#sub-task-3-body") |> LazyHTML.attribute("phx-hook") == ["CodeBlockCopy"]
      assert count(doc, "#sub-task-3-body pre code.language-elixir") == 1
      assert classes(doc, "#sub-task-3-head") =~ "sticky top-0 drawer:-top-5 z-[2] border-b border-base-300 bg-base-100"
      assert count(doc, "#sub-task-3-toggle .hero-chevron-up") == 1
      assert doc |> q("#sub-task-3") |> LazyHTML.attribute("data-open") == ["true"]
      assert doc |> q("#sub-task-3-toggle") |> LazyHTML.attribute("aria-expanded") == ["true"]
      # one open at a time: every other row is collapsed
      assert count(doc, "[id$='-body']") == 1
      refute classes(doc, "#sub-task-2-head") =~ "sticky"
    end

    test "a short open body has no clamp and no Show all toggle" do
      doc = render_plan(%{open_task_id: 3})

      refute classes(doc, "#sub-task-3-body") =~ "task-body-clamped"
      assert count(doc, "#sub-task-3-full") == 0
    end

    test "a >16-line open body is clamped behind Show all N lines" do
      doc = render_plan(%{open_task_id: 2})

      assert classes(doc, "#sub-task-2-body") =~ "task-body-clamped"
      assert doc |> q("#sub-task-2-full") |> LazyHTML.text() =~ "Show all 20 lines"
      assert doc |> q("#sub-task-2-full") |> LazyHTML.attribute("phx-click") == ["toggle_task_full"]
      assert classes(doc, "#sub-task-2-full") =~ "flex items-center gap-1 text-xs font-semibold text-primary"
      assert count(doc, "#sub-task-2-full .hero-chevron-down") == 1
    end

    test "a released clamp shows the full body and a Collapse toggle" do
      doc = render_plan(%{open_task_id: 2, task_full?: true})

      refute classes(doc, "#sub-task-2-body") =~ "task-body-clamped"
      assert doc |> q("#sub-task-2-full") |> LazyHTML.text() =~ "Collapse"
      assert count(doc, "#sub-task-2-full .hero-chevron-up") == 1
    end

    test "the in-flight row is tinted violet and carries the AGENT IS HERE chip" do
      doc = render_plan(%{in_flight_task_id: 3})

      assert classes(doc, "#sub-task-3") =~ "border-secondary/40 bg-secondary/5"
      assert doc |> q("#sub-task-3") |> LazyHTML.attribute("data-in-flight") == ["true"]
      assert doc |> q("#sub-task-3-agent-here") |> LazyHTML.text() == "AGENT IS HERE"

      assert classes(doc, "#sub-task-3-agent-here") =~
               "shrink-0 rounded bg-secondary/10 px-1.5 py-0.5 font-mono text-[9.5px] font-semibold tracking-[0.04em] text-secondary"

      assert count(doc, "#sub-task-2-agent-here") == 0
      refute classes(doc, "#sub-task-2") =~ "bg-secondary/5"
    end

    test "opening a body-less task renders nothing to open" do
      doc = render_plan(%{open_task_id: 4})

      assert count(doc, "#sub-task-4-body") == 0
      assert doc |> q("#sub-task-4") |> LazyHTML.attribute("data-open") == ["false"]
    end

    test "plan text with no tasks shows just the header — no count, no list" do
      doc = render_plan(%{tasks: [], progress: %{done: 0, total: 0}})

      assert doc |> q("#card-plan-view") |> LazyHTML.text() =~ "Header text"
      assert count(doc, "#card-plan-count") == 0
      assert count(doc, "#card-plan-tasks") == 0
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

    test "editing: the pill's ✓ is a pending action inside an action group (RE394)" do
      doc =
        (&CoreComponents.inline_field/1)
        |> render_component(
          id: "card-drawer-title",
          editing: true,
          field: :title,
          form: Phoenix.Component.to_form(%{"title" => "Draft"}, as: :card),
          edit_event: "edit",
          save_event: "save",
          cancel_event: "cancel"
        )
        |> LazyHTML.from_fragment()

      assert "pending-action" in btn_classes(doc, "#card-drawer-title-save")
      assert "action-group" in btn_classes(doc, "#card-drawer-title-pill")
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

    test ":self always-editable renders the :hidden slot inside its form" do
      assigns = %{form: Phoenix.Component.to_form(%{"name" => "Laptop"}, as: :api_key)}

      html =
        rendered_to_string(~H"""
        <CoreComponents.boxed_field
          id="bf-key-name"
          form={@form}
          field={:name}
          save_event="rename_key"
          cancel_event="cancel_rename_key"
        >
          <:hidden><input type="hidden" name="key_id" value="42" /></:hidden>
        </CoreComponents.boxed_field>
        """)

      form = html |> LazyHTML.from_fragment() |> LazyHTML.query("#bf-key-name-form")
      assert form |> LazyHTML.query("input[type=hidden][name=key_id][value='42']") |> Enum.count() == 1
      assert form |> LazyHTML.query("#bf-key-name-input[value='Laptop']") |> Enum.count() == 1
    end
  end

  # RE394 — the commit pill's ✓ shows a spinner-only pressed face; its hint swaps to Saving….
  describe "boxed_field/1 commit pill pressed face (RE394)" do
    defp pill_doc(extra \\ []) do
      (&CoreComponents.boxed_field/1)
      |> render_component(
        Keyword.merge(
          [
            id: "board-name",
            commit: :self,
            value: "Relay",
            field: :name,
            form: Phoenix.Component.to_form(%{"name" => "Relay"}, as: :board),
            save_event: "save_board_name",
            cancel_event: "cancel_board_name"
          ],
          extra
        )
      )
      |> LazyHTML.from_fragment()
    end

    test "the pill is a hidden action group; ✓ is a spinner-only pending submit; hint swaps to Saving…" do
      doc = pill_doc()

      assert btn_classes(doc, "#board-name-pill") == ~w(commit-pill action-group hidden)
      assert attr_of(doc, "#board-name-save", "type") == ["submit"]
      assert attr_of(doc, "#board-name-save", "aria-label") == ["Save"]
      assert btn_classes(doc, "#board-name-save") == ~w(commit-pill-save pending-action)
      assert count(doc, "#board-name-save .pending-stack .pending-idle span.hero-check") == 1
      assert count(doc, "#board-name-save .pending-face .loading.loading-spinner.loading-xs") == 1
      assert text_of(doc, "#board-name-save .pending-face") == ""
      assert attr_of(doc, "#board-name-save .pending-face", "aria-hidden") == ["true"]
      refute "pending-action" in btn_classes(doc, "#board-name-cancel")

      assert "pending-status" in btn_classes(doc, "#board-name-pill .commit-pill-hint")
      assert text_of(doc, "#board-name-pill .commit-pill-hint .pending-idle") == "Enter · Esc"
      assert text_of(doc, "#board-name-pill .commit-pill-hint .pending-face") == "Saving…"
    end

    test "a multiline field's hint idles on ⌘↵ · Esc and presses to Saving…" do
      doc = pill_doc(multiline: true)

      assert text_of(doc, "#board-name-pill .commit-pill-hint .pending-idle") == "⌘↵ · Esc"
      assert text_of(doc, "#board-name-pill .commit-pill-hint .pending-face") == "Saving…"
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

    test "Save is a Saving… pending submit; the actions row is the action group (RE394)" do
      doc =
        (&CoreComponents.boxed_field/1)
        |> render_component(Keyword.put(edit_attrs(), :id, "card-drawer-description"))
        |> LazyHTML.from_fragment()

      assert "action-group" in btn_classes(doc, ".commit-field-actions")
      save = "#card-drawer-description-save"
      assert doc |> LazyHTML.query(save) |> LazyHTML.attribute("type") == ["submit"]
      assert btn_classes(doc, save) == ~w(btn btn-sm btn-primary pending-action)
      assert text_of(doc, "#{save} .pending-idle") == "Save"
      assert text_of(doc, "#{save} .pending-face") == "Saving…"
      refute "pending-action" in btn_classes(doc, "#card-drawer-description-cancel")
    end
  end

  # RE362 — clicking away from a markdown editor used to cancel it (RLY-49) and throw the typed
  # text away. The editor now only closes on Save, Cancel or Esc, reports keystrokes so the
  # LiveView can keep a draft, and can show a "restored" note with a Discard.
  describe "boxed_field/1 drafts (RE362)" do
    defp draft_attrs(extra \\ []) do
      Keyword.merge(
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
        ],
        extra
      )
    end

    test "the editing form never cancels on click-away" do
      html = render_component(&CoreComponents.boxed_field/1, draft_attrs())

      refute html =~ "phx-click-away"
      # Cancel stays wired to the button (and Esc, via data-cancel-id).
      assert html =~ ~s(id="bf-cancel")
      assert html =~ ~s(phx-click="cancel")
      assert html =~ ~s(data-cancel-id="bf-cancel")
    end

    test "inline_field still cancels on click-away" do
      html =
        render_component(&CoreComponents.inline_field/1,
          id: "if",
          editing: true,
          value: "Title",
          field: :title,
          form: Phoenix.Component.to_form(%{"title" => "Title"}, as: :card),
          edit_event: "edit_title",
          save_event: "save_title",
          cancel_event: "cancel_title"
        )

      assert html =~ ~s(phx-click-away="cancel_title")
    end

    test "no change_event renders no phx-change and no debounce" do
      html = render_component(&CoreComponents.boxed_field/1, draft_attrs())

      refute html =~ "phx-change"
      refute html =~ "phx-debounce"
    end

    test "change_event wires phx-change on the form and debounces the textarea" do
      html = render_component(&CoreComponents.boxed_field/1, draft_attrs(change_event: "draft_field"))

      assert html =~ ~s(phx-change="draft_field")
      assert html =~ ~s(phx-debounce="300")
    end

    test "the restored note is absent by default" do
      html = render_component(&CoreComponents.boxed_field/1, draft_attrs(discard_event: "discard_draft"))

      refute html =~ "bf-draft-restored"
      refute html =~ "Unsaved draft restored"
      refute html =~ ~s(id="bf-discard")
    end

    test "draft_restored shows a hint-styled note whose Discard names the field" do
      html =
        render_component(
          &CoreComponents.boxed_field/1,
          draft_attrs(draft_restored: true, discard_event: "discard_draft")
        )

      assert html =~ ~s(id="bf-draft-restored")
      assert html =~ "Unsaved draft restored"
      assert html =~ ~s(id="bf-discard")
      assert html =~ ~s(phx-click="discard_draft")
      assert html =~ ~s(phx-value-field="description")

      [note] = Regex.run(~r/<span[^>]*id="bf-draft-restored"[^>]*>/, html)
      assert note =~ "commit-field-hint"
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
      # links use the primary token, underlined (one-line/ellipsized rule is RE324's own test:
      # test/relay_web/markdown_link_css_test.exs)
      assert @app_css =~ ~r/\.md a \{[^}]*color:\s*var\(--color-primary\)/
      assert @app_css =~ ~r/\.md a \{[^}]*text-decoration:\s*underline/
      # headings are a strong label, not oversized
      assert @app_css =~ ~r/\.md h1[^\n]*\{[^}]*font-weight:\s*700/
    end

    test "storybook.css mirrors the .md block (RLY-58 gap closed)" do
      assert @storybook_css =~ ".md ul { list-style: disc; }"
      assert @storybook_css =~ ~r/\.md a \{[^}]*color:\s*var\(--color-primary\)/
      assert @storybook_css =~ ~r/\.md a \{[^}]*text-decoration:\s*underline/
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

    test "an infrastructure park says the node could not run (RE308)" do
      assert CoreComponents.blocked_strip_eyebrow(true, :infrastructure, "implement") ==
               "IMPLEMENT COULD NOT RUN"

      assert CoreComponents.blocked_strip_eyebrow(true, :infrastructure, nil) == "NEEDS YOUR ANSWER"
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

    # RE394 — every server-bound action in the panel shows a client-side pressed face.
    defp panel_doc(extra), do: extra |> panel() |> LazyHTML.from_fragment()
    defp attr_at(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

    test "the escalation fallback's Send and Retry carry pressed faces inside an action group (RE394)" do
      doc = panel_doc(%{park_kind: :escalation, node: "implement", answer_questions: nil})

      assert "action-group" in btn_classes(doc, "#needs-input-panel")
      assert attr_at(doc, "#needs-input-send", "type") == ["submit"]
      assert text_of(doc, "#needs-input-send .pending-face") == "Sending…"
      assert attr_at(doc, "#needs-input-retry", "type") == ["button"]
      assert attr_at(doc, "#needs-input-retry", "phx-click") == ["retry_run"]
      assert text_of(doc, "#needs-input-retry .pending-idle") == "Retry implement"
      assert text_of(doc, "#needs-input-retry .pending-face") == "Retrying…"
    end

    test "the infrastructure Retry carries a Retrying… face (RE394)" do
      doc = panel_doc(%{park_kind: :infrastructure, node: "implement"})

      assert text_of(doc, "#needs-input-retry .pending-face") == "Retrying…"
      assert attr_at(doc, "#needs-input-retry", "phx-click") == ["retry_run"]
    end

    test "the stepper's last-step Send carries a Sending… face; options do not (RE394)" do
      doc =
        panel_doc(%{
          answer_questions: [%{"prompt" => "Pick", "options" => ["A"]}],
          answer_step: 0,
          answer_values: %{0 => "A"}
        })

      assert attr_at(doc, "#needs-input-send", "type") == ["button"]
      assert attr_at(doc, "#needs-input-send", "phx-click") == ["answer_submit"]
      assert text_of(doc, "#needs-input-send .pending-face") == "Sending…"
      refute "pending-action" in btn_classes(doc, "#needs-input-option-0")
    end

    test "the advance control inside the panel carries a Continuing… face (RE394)" do
      doc = panel_doc(%{advance_available?: true})

      assert text_of(doc, "#needs-input-panel #run-advance .pending-face") == "Continuing…"
    end

    test "an infrastructure park shows the cause and Retry — no answer box, no attempt count (RE308)" do
      detail = "agent could not run: Failed to authenticate: OAuth session expired and could not be refreshed"

      html =
        panel(%{
          park_kind: :infrastructure,
          node: "quality_review",
          attempt: 3,
          question: detail,
          failure_detail: detail
        })

      assert html =~ "AGENT COULD NOT RUN"
      assert html =~ ~s(id="needs-input-infrastructure")
      assert html =~ "Agent could not run"
      assert html =~ "quality_review"

      # the cause, in the same dark <pre> the escalation face uses
      assert html =~ ~s(id="needs-input-failure-detail")
      assert html =~ "OAuth session expired"
      assert html =~ "background:var(--color-neutral)"

      # Retry is the only action — the fix is outside the card
      assert html =~ ~s(id="needs-input-retry")
      assert html =~ "Retry quality_review"
      refute html =~ ~s(id="needs-input-form")
      refute html =~ ~s(id="needs-input-answer")
      refute html =~ "<textarea"

      # no retry was spent, so no "N attempts" readout; no duplicate markdown question
      refute html =~ "attempt"
      refute html =~ ~s(id="needs-input-question")
      refute html =~ "NODE FAILED"
    end

    test "an infrastructure park with no captured detail falls back to the question text" do
      html = panel(%{park_kind: :infrastructure, node: "implement", question: "agent could not run: usage limit"})

      assert html =~ ~s(id="needs-input-failure-detail")
      assert html =~ "usage limit"
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
    test "the stopped strip's Retry chip shows a Retrying… pressed face (RE394)" do
      doc = LazyHTML.from_fragment(strip(:stopped, log_text: "agent stopped"))

      classes = btn_classes(doc, "#card-RLY-3-retry")
      assert "card-retry-chip" in classes
      assert "pending-action" in classes
      assert doc |> LazyHTML.query("#card-RLY-3-retry") |> LazyHTML.attribute("type") == ["button"]
      assert doc |> LazyHTML.query("#card-RLY-3-retry") |> LazyHTML.attribute("phx-click") == ["retry_card"]
      assert doc |> LazyHTML.query("#card-RLY-3-retry") |> LazyHTML.attribute("phx-value-ref") == ["RLY-3"]
      assert text_of(doc, "#card-RLY-3-retry .pending-idle") == "Retry"
      assert text_of(doc, "#card-RLY-3-retry .pending-face") == "Retrying…"
    end

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

    # RE316 / RE401: only Changes sit behind Show more, so tests of their rendering expand.
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

  # RE401 — Screenshots lead the AI Result box and are always visible, so these regressions
  # render the drawer collapsed (the default); no Show more click is needed to see the tiles.
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

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert html =~ ~s(id="ai-result-screens")
      # A local filesystem path is not fetchable by the browser, so it captions the placeholder
      # rather than becoming a broken <img src>.
      assert html =~ "12-state3a-review.png"
      refute html =~ ~s(src="/Users/jeremy)
    end

    test "a bare string that is a real URL still renders as the image" do
      ai_result = %{"summary" => "s", "screens" => ["https://example.com/shot.png"]}

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert html =~ ~s(src="https://example.com/shot.png")
    end

    test "still renders documented map screens" do
      ai_result = %{
        "summary" => "s",
        "screens" => [%{"url" => "https://example.com/a.png", "caption" => "The drawer"}]
      }

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert html =~ ~s(src="https://example.com/a.png")
      assert html =~ "The drawer"
    end

    test "a root-relative url this app serves still renders as the image" do
      ai_result = %{"summary" => "s", "screens" => [%{"url" => "/images/logo_light_128.png"}]}

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert html =~ ~s(src="/images/logo_light_128.png")
    end

    test "a map screen whose url is not a usable image src falls back to the placeholder" do
      ai_result = %{"summary" => "s", "screens" => [%{"url" => "tmp/smoke/a.png"}]}

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

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

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

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

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#ai-result-screen-tiles > span.border-dashed") |> Enum.count() == 4
      assert doc |> LazyHTML.query("#ai-result-screens a") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#ai-result-screens img") |> Enum.count() == 0
      assert html =~ "12-review.png"
      assert html =~ "a.png"
    end

    # RE390 — screenshots are the same 80px tiles as mockups, patching to the same-tab viewer
    # (`?screenshot=<n>`); they no longer join the RE322 lightbox.
    test "screens render as 80px tiles patching to screenshot_href; unfetchable paths are dashed placeholders" do
      ai_result = %{
        "summary" => "s",
        "screens" => [%{"url" => "/images/logo_light_128.png", "caption" => "home"}, "tmp/smoke/12-review.png"]
      }

      html =
        render_component(
          &CoreComponents.card_drawer/1,
          Map.put(drawer_assigns(ai_result), :screenshot_href, &"/board/b?card=RE1&screenshot=#{&1}")
        )

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#ai-result-screens-header > .section-label") |> LazyHTML.text() |> String.trim() ==
               "Screenshots"

      link = LazyHTML.query(doc, "a#ai-result-screen-0-open")
      assert LazyHTML.attribute(link, "href") == ["/board/b?card=RE1&screenshot=1"]
      assert LazyHTML.attribute(link, "data-phx-link") == ["patch"]
      assert LazyHTML.attribute(link, "title") == ["home"]
      [class] = LazyHTML.attribute(link, "class")
      assert class =~ "size-20"
      assert link |> LazyHTML.query("img.object-top") |> Enum.count() == 1

      placeholder = LazyHTML.query(doc, "span#ai-result-screen-1")
      assert LazyHTML.attribute(placeholder, "title") == ["12-review.png"]
      assert doc |> LazyHTML.query("a#ai-result-screen-1-open") |> Enum.count() == 0

      assert doc |> LazyHTML.query("#ai-result-screens-group figure") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#ai-result-screens-group figcaption") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#ai-result-screens-group .cursor-zoom-in") |> Enum.count() == 0
    end

    test "a screen whose attachment is HTML renders as a live miniature iframe, not an img" do
      ai_result = %{"summary" => "s", "screens" => ["/attachments/h1"]}

      html =
        render_component(
          &CoreComponents.card_drawer/1,
          Map.put(drawer_assigns(ai_result), :attachment_types, %{"h1" => "text/html"})
        )

      tile = html |> LazyHTML.from_fragment() |> LazyHTML.query("a#ai-result-screen-0-open")
      assert tile |> LazyHTML.query("iframe") |> LazyHTML.attribute("sandbox") == ["allow-scripts"]
      assert tile |> LazyHTML.query("img") |> Enum.count() == 0
    end
  end

  describe "card_drawer/1 Mockups by content type (RE390)" do
    defp mockup_drawer_tile(types) do
      card = Map.put(%{drawer_assigns(nil).card | ai_result: nil}, :mockups, [%{"url" => "/attachments/a1"}])

      (&CoreComponents.card_drawer/1)
      |> render_component(Map.put(%{drawer_assigns(nil) | card: card, id: "card-drawer"}, :attachment_types, types))
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#card-drawer-mockup-0-open")
    end

    test "an image mockup tile holds an img cropped to the top, and no iframe" do
      tile = mockup_drawer_tile(%{"a1" => "image/png"})

      assert tile |> LazyHTML.query("img.object-top") |> Enum.count() == 1
      assert tile |> LazyHTML.query("iframe") |> Enum.count() == 0
    end

    test "an HTML mockup tile keeps its live miniature iframe" do
      tile = mockup_drawer_tile(%{"a1" => "text/html"})

      assert tile |> LazyHTML.query("iframe") |> Enum.count() == 1
      assert tile |> LazyHTML.query("img") |> Enum.count() == 0
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
        "screens" => "one screen, not a list"
      }

      html = render_component(&CoreComponents.card_drawer/1, expanded_drawer_assigns(ai_result))

      # RE327 — the non-binary summary makes `ai_result_renderable?/1` fall through to
      # `changes`, which coerces to a one-element list, so the box still renders.
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
        "screens" => [%{"url" => "https://placehold.co/320x180", "caption" => "home"}]
      }
    end

    defp ai_query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp ai_text(html, selector), do: html |> ai_query(selector) |> LazyHTML.text() |> String.trim()

    defp ai_count(html, selector), do: html |> ai_query(selector) |> Enum.count()

    defp ai_offset(html, id) do
      {offset, _} = :binary.match(html, ~s(id="#{id}"))
      offset
    end

    test "collapsed (default) shows the screenshots, the full summary and Show more, but not changes" do
      long_summary = String.duplicate("Did the thing. ", 40)
      ai_result = Map.put(full_ai_result(), "summary", long_summary)

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

      assert ai_text(html, "#ai-result #ai-result-summary") == String.trim(long_summary)
      assert ai_text(html, "#ai-result #ai-result-show-more") == "Show more"
      assert ai_count(html, "#ai-result-show-more.commit-field-showmore") == 1
      assert ai_count(html, "#ai-result-show-more[phx-click=toggle_ai_result]") == 1
      assert ai_count(html, "#ai-result #ai-result-screens-group") == 1
      assert ai_count(html, ~s(a#ai-result-screen-0-open[title="home"])) == 1
      assert ai_count(html, "#ai-result-changes") == 0
      assert ai_count(html, "#ai-result-changes-group") == 0
    end

    test "collapsed, the screenshots group is the first child of the violet box, above the summary" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(full_ai_result()))

      assert ai_offset(html, "ai-result-screens-group") < ai_offset(html, "ai-result-summary")
      assert ai_count(html, "#ai-result > div > div:first-child#ai-result-screens-group") == 1
    end

    test "the screenshots header carries the label and a count of every tile, placeholders included" do
      ai_result = %{
        "summary" => "s",
        "screens" => [
          %{"url" => "/images/logo_light_128.png", "caption" => "a"},
          %{"url" => "/images/logo_dark_128.png", "caption" => "b"},
          "tmp/smoke/04-dark.png"
        ]
      }

      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))
      doc = LazyHTML.from_fragment(html)

      assert ai_text(html, "#ai-result-screens-header > .section-label") == "Screenshots"
      assert ai_text(html, "#ai-result-screens-count") == "3"

      [header_class] = doc |> LazyHTML.query("#ai-result-screens-header") |> LazyHTML.attribute("class")

      assert MapSet.subset?(
               MapSet.new(~w(flex items-baseline justify-between)),
               MapSet.new(String.split(header_class))
             )

      [count_class] = doc |> LazyHTML.query("#ai-result-screens-count") |> LazyHTML.attribute("class")
      assert "text-[11px]" in String.split(count_class)
      assert "text-base-content/55" in String.split(count_class)

      tiles = LazyHTML.query(doc, "#ai-result-screen-tiles > *")
      assert Enum.map(tiles, &(&1 |> LazyHTML.tag() |> hd())) == ["a", "a", "span"]
      assert ai_count(html, "#ai-result-screen-tiles > span.border-dashed:nth-child(3)") == 1
      assert doc |> LazyHTML.query("span#ai-result-screen-2") |> LazyHTML.attribute("title") == ["04-dark.png"]
    end

    test "expanded shows the screenshots once, then the summary, then the labelled Changes and Show less" do
      html =
        render_component(
          &CoreComponents.card_drawer/1,
          Map.put(drawer_assigns(full_ai_result()), :expanded_ai_result, true)
        )

      assert ai_count(html, "#ai-result-screens-group") == 1
      assert ai_text(html, "#ai-result #ai-result-changes-group > span") == "Changes"
      assert ai_count(html, "#ai-result-changes-group > span + ul#ai-result-changes") == 1
      assert ai_text(html, "#ai-result-changes") =~ "changed A"

      assert ai_text(html, "#ai-result #ai-result-screens-header > .section-label") == "Screenshots"
      assert ai_count(html, "#ai-result-screens-header + section#ai-result-screens") == 1
      assert ai_count(html, ~s(#ai-result-screens a#ai-result-screen-0-open[title="home"])) == 1
      assert ai_count(html, "#ai-result-screens .cursor-zoom-in") == 0

      assert ai_offset(html, "ai-result-screens-group") < ai_offset(html, "ai-result-summary")
      assert ai_offset(html, "ai-result-summary") < ai_offset(html, "ai-result-changes-group")
      assert ai_offset(html, "ai-result-changes-group") < ai_offset(html, "ai-result-show-more")
      assert ai_text(html, "#ai-result #ai-result-show-more") == "Show less"
    end

    test "screens with no changes show the screenshots and summary but no Show more" do
      screens = [%{"url" => "https://placehold.co/320x180", "caption" => "home"}]

      for ai_result <- [
            %{"summary" => "s", "screens" => screens},
            %{"summary" => "s", "changes" => [], "screens" => screens}
          ] do
        html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

        assert ai_count(html, "#ai-result-screens-group") == 1
        assert ai_text(html, "#ai-result-summary") == "s"
        assert ai_count(html, "#ai-result-show-more") == 0
      end
    end

    test "renders only the groups whose lists are non-empty, collapsed or expanded" do
      for expanded <- [false, true] do
        html =
          render_component(
            &CoreComponents.card_drawer/1,
            Map.put(
              drawer_assigns(%{"summary" => "s", "changes" => ["changed A"], "screens" => []}),
              :expanded_ai_result,
              expanded
            )
          )

        assert ai_count(html, "#ai-result-changes-group") == if(expanded, do: 1, else: 0)
        assert ai_count(html, "#ai-result-screens-group") == 0
        refute html =~ "Screenshots"
        assert ai_text(html, "#ai-result-show-more") == if(expanded, do: "Show less", else: "Show more")
      end
    end

    test "there is no Show more when there are no changes to reveal" do
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

  describe "card_drawer/1 AI Result deployment link removal (RE327)" do
    # Relay has no preview-deployment story, so the box must never draw a link to one — not for
    # any blob, however populated. The id selector is the durable pin: the element is gone.
    test "no deploy link renders, collapsed or expanded, for a fully populated result" do
      for expanded <- [false, true] do
        html =
          render_component(
            &CoreComponents.card_drawer/1,
            Map.put(drawer_assigns(full_ai_result()), :expanded_ai_result, expanded)
          )

        assert ai_count(html, "#ai-result") == 1
        assert ai_count(html, "#ai-result-deploy") == 0
      end
    end

    # RE327 — the realistic legacy blob holds only the removed link's key, but acceptance
    # criterion 6 greps `test/` for that literal and expects zero hits. The guard never looks
    # at the key name, so any unrenderable key exercises the same path. Do NOT reintroduce the
    # literal here.
    test "a blob with nothing renderable draws no empty violet box" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(%{"legacy_key" => "https://example.com"}))

      refute html =~ ~s(id="ai-result")
      refute html =~ "AI Result"
      assert ai_count(html, "#ai-result-deploy") == 0
    end

    test "a summary-only result still renders the box (the guard does not over-fire)" do
      html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(%{"summary" => "Did the thing"}))

      assert ai_count(html, "#ai-result") == 1
      assert ai_text(html, "#ai-result-summary") == "Did the thing"
    end

    test "a changes-only and a screens-only result each still render the box" do
      for ai_result <- [
            %{"changes" => ["changed A"]},
            %{"screens" => [%{"url" => "https://placehold.co/320x180", "caption" => "home"}]}
          ] do
        html = render_component(&CoreComponents.card_drawer/1, drawer_assigns(ai_result))

        assert ai_count(html, "#ai-result") == 1
      end
    end

    # An unrenderable blob that is nevertheless non-blank must not draw the box, but it also
    # must not change what `writes` enforcement thinks (RE244): those are different questions.
    test "a non-blank but unrenderable blob is still non-blank for the writes contract" do
      refute Relay.Cards.ai_result_blank?(%{"legacy_key" => "https://example.com"})
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

  defp crumbs_doc(crumbs) do
    html = render_component(&CoreComponents.breadcrumbs/1, crumbs: crumbs)
    LazyHTML.from_fragment(html)
  end

  defp crumb_class(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> hd()
  end

  describe "breadcrumbs/1 (RE334)" do
    @deep_trail [
      %{label: "Boards", to: "/boards", id: "top-bar-crumb-boards", icon: "hero-squares-2x2"},
      %{label: "Payments", to: "/board/payments", id: "top-bar-crumb-board"},
      %{label: "Settings", to: "/board/payments/settings", id: "top-bar-crumb-settings"},
      %{label: "Stages", to: "/board/payments/settings?section=stages", id: "top-bar-crumb-stages"}
    ]

    test "renders nothing for an empty trail" do
      html = render_component(&CoreComponents.breadcrumbs/1, crumbs: [])
      assert String.trim(html) == ""
    end

    test "renders every crumb as a navigate link, each followed by a / separator" do
      doc = crumbs_doc(@deep_trail)

      assert doc |> LazyHTML.query("nav#top-bar-crumb[aria-label=Breadcrumb]") |> Enum.count() == 1

      for %{id: id, to: to, label: label} <- @deep_trail do
        link = LazyHTML.query(doc, "a##{id}")
        assert LazyHTML.attribute(link, "href") == [to]
        assert LazyHTML.attribute(link, "title") == [label]
        assert LazyHTML.text(link) =~ label
      end

      assert doc |> LazyHTML.query("[data-crumb-separator]") |> Enum.count() == length(@deep_trail)
    end

    test "the root crumb keeps the shipped Boards look — squares icon, 13px semibold /70" do
      doc = crumbs_doc(@deep_trail)

      assert doc |> LazyHTML.query("a#top-bar-crumb-boards .hero-squares-2x2") |> Enum.count() == 1
      assert doc |> LazyHTML.query("a#top-bar-crumb-board [class*='hero-']") |> Enum.count() == 0

      class = crumb_class(doc, "a#top-bar-crumb-boards")
      assert class =~ "text-[13px]"
      assert class =~ "font-semibold"
      assert class =~ "text-base-content/70"
      assert class =~ "rounded-[7px]"
    end

    test "every crumb truncates at a capped width with its full label in title=" do
      doc = crumbs_doc(@deep_trail)

      for %{id: id} <- @deep_trail do
        assert crumb_class(doc, "a##{id}") =~ "max-w-[160px]"
        assert doc |> LazyHTML.query("a##{id} span.truncate") |> Enum.count() == 1
      end
    end

    test "below md only the root, an ellipsis and the immediate parent show" do
      doc = crumbs_doc(@deep_trail)

      refute crumb_class(doc, "#top-bar-crumb-boards-segment") =~ "hidden"
      assert crumb_class(doc, "#top-bar-crumb-board-segment") =~ "hidden md:flex"
      assert crumb_class(doc, "#top-bar-crumb-settings-segment") =~ "hidden md:flex"
      refute crumb_class(doc, "#top-bar-crumb-stages-segment") =~ "hidden"
      assert crumb_class(doc, "#top-bar-crumb-ellipsis") =~ "md:hidden"
    end

    test "a two-crumb trail collapses nothing and renders no ellipsis" do
      doc = crumbs_doc(Enum.take(@deep_trail, 2))

      refute crumb_class(doc, "#top-bar-crumb-board-segment") =~ "hidden"
      assert doc |> LazyHTML.query("#top-bar-crumb-ellipsis") |> Enum.count() == 0
    end

    test "a crumb carrying patch: true renders a patch link; the rest still navigate (RE380)" do
      doc =
        crumbs_doc([
          %{id: "c-root", label: "Boards", to: "/boards"},
          %{id: "c-card", label: "Notif", to: "/x?card=1", patch: true}
        ])

      assert doc |> LazyHTML.query(~s(a#c-card[data-phx-link="patch"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s(a#c-root[data-phx-link="redirect"])) |> Enum.count() == 1
    end
  end

  describe "mockup_preview/1 same-tab tile (RE380)" do
    defp tile_doc(extra) do
      base = %{id: "t", src: "/attachments/x", view_href: "/board/b?card=RE1&mockup=x", caption: "Loaded"}

      (&CoreComponents.mockup_preview/1)
      |> render_component(Map.merge(base, extra))
      |> LazyHTML.from_fragment()
    end

    defp tile_attr(doc, attr), do: doc |> LazyHTML.query("a#t-open") |> LazyHTML.attribute(attr)

    test "is a same-tab patch link with no target or rel, and no current treatment by default" do
      doc = tile_doc(%{})

      assert tile_attr(doc, "href") == ["/board/b?card=RE1&mockup=x"]
      assert tile_attr(doc, "data-phx-link") == ["patch"]
      assert tile_attr(doc, "target") == []
      assert tile_attr(doc, "rel") == []
      assert tile_attr(doc, "aria-label") == ["Open mockup: Loaded"]
      assert tile_attr(doc, "aria-current") == []

      [class] = tile_attr(doc, "class")
      refute class =~ "ring-offset-2"
      refute class =~ "opacity-80"
    end

    test "current: true rings the tile and marks it aria-current" do
      doc = tile_doc(%{current: true})

      assert tile_attr(doc, "aria-current") == ["true"]
      [class] = tile_attr(doc, "class")
      assert class =~ "ring-2 ring-primary ring-offset-2 ring-offset-base-100"
    end

    test "current: false dims the tile and leaves aria-current off" do
      doc = tile_doc(%{current: false})

      assert tile_attr(doc, "aria-current") == []
      [class] = tile_attr(doc, "class")
      assert class =~ "opacity-80"
      assert class =~ "hover:ring-2 hover:ring-primary"
    end

    test "replace: true makes the patch replace the history entry" do
      assert tile_attr(tile_doc(%{replace: true}), "data-phx-link-state") == ["replace"]
    end

    test "kind: :image renders an img cropped to the top instead of the iframe" do
      doc = tile_doc(%{kind: :image})

      img = LazyHTML.query(doc, "a#t-open img#t-image")
      assert LazyHTML.attribute(img, "src") == ["/attachments/x"]
      [class] = LazyHTML.attribute(img, "class")
      assert class =~ "object-cover object-top"
      assert doc |> LazyHTML.query("iframe") |> Enum.count() == 0
    end

    test "the default kind keeps the iframe miniature and no img" do
      doc = tile_doc(%{})

      assert doc |> LazyHTML.query("a#t-open iframe#t-frame") |> Enum.count() == 1
      assert doc |> LazyHTML.query("img") |> Enum.count() == 0
    end

    test "noun names the tile when there is no caption" do
      doc = tile_doc(%{noun: "Screenshot", caption: nil})

      assert tile_attr(doc, "aria-label") == ["Open screenshot: Screenshot"]
      assert tile_attr(doc, "title") == ["Screenshot"]
    end
  end

  describe "media_placeholder/1 (RE390)" do
    test "a dashed 80px span titled and captioned, never a link" do
      doc =
        (&CoreComponents.media_placeholder/1)
        |> render_component(id: "p", caption: "12-review.png")
        |> LazyHTML.from_fragment()

      span = LazyHTML.query(doc, ~s(span#p[title="12-review.png"]))
      [class] = LazyHTML.attribute(span, "class")
      assert "size-20" in String.split(class)
      assert "border-dashed" in String.split(class)
      assert span |> LazyHTML.text() |> String.trim() == "12-review.png"
      assert doc |> LazyHTML.query("a") |> Enum.count() == 0
    end
  end

  describe "card_mockups_section/1 (RE380, RE390)" do
    @section_items [
      %{key: "m-a", src: "/attachments/m-a", caption: "A", kind: :html},
      %{key: "m-b", src: "/attachments/m-b", caption: "B", kind: :image},
      %{key: "m-c", src: "/attachments/m-c", caption: nil, kind: :html}
    ]

    defp section_doc(current, extra \\ []) do
      (&CoreComponents.card_mockups_section/1)
      |> render_component(
        Keyword.merge(
          [id: "s", tile_id: "t", items: @section_items, current: current, item_href: &"/v/#{&1}"],
          extra
        )
      )
      |> LazyHTML.from_fragment()
    end

    test "with a current item: tiles link through item_href, drawn by kind, one is current, and the section ends at the tiles" do
      doc = section_doc("m-b")

      for {%{key: key}, n} <- Enum.with_index(@section_items) do
        assert doc |> LazyHTML.query("a#t-#{n}-open") |> LazyHTML.attribute("href") == ["/v/#{key}"]
      end

      assert count(doc, "a#t-0-open iframe") == 1
      assert count(doc, "a#t-1-open img") == 1
      assert count(doc, "a#t-1-open iframe") == 0

      assert count(doc, ~s(a[aria-current="true"])) == 1
      assert count(doc, ~s(a#t-1-open[aria-current="true"])) == 1

      assert count(doc, "#s-viewing") == 0
      assert count(doc, "#s-keys") == 0
      assert count(doc, "#s kbd") == 0
      assert count(doc, "#s #t-tiles.flex.flex-wrap.gap-3") == 1
    end

    test "with no current item (the drawer): no Viewing line, no key hint, the gap-2 row" do
      doc = section_doc(nil)

      assert count(doc, "#s-viewing") == 0
      assert count(doc, "#s-keys") == 0
      assert count(doc, "#t-tiles.flex.flex-wrap.gap-2") == 1
      assert count(doc, ~s(a[aria-current])) == 0
      assert doc |> LazyHTML.query("#s > span") |> LazyHTML.text() |> String.trim() == "Mockups"
    end

    test "show_label: false drops the label row; a placeholder renders in place as a non-link span" do
      items = [
        %{key: 1, src: "/images/a.png", caption: "A", kind: :image},
        %{key: nil, src: nil, caption: "b.png", kind: :placeholder},
        %{key: 2, src: "/images/c.png", caption: "C", kind: :image}
      ]

      doc = section_doc(nil, items: items, label: "Screenshots", noun: "Screenshot", show_label: false)

      refute LazyHTML.text(doc) =~ "Screenshots"
      assert count(doc, "#t-tiles > :nth-child(1)#t-0-open") == 1
      assert count(doc, ~s(#t-tiles > span#t-1[title="b.png"])) == 1
      assert count(doc, "#t-tiles > :nth-child(3)#t-2-open") == 1
      assert count(doc, "a#t-1-open") == 0
      assert doc |> LazyHTML.query("a#t-2-open") |> LazyHTML.attribute("href") == ["/v/2"]
    end
  end

  describe "card_review_panel/1 (RE380)" do
    @gate %{approve_label: "Approve → Done", reject_target_name: "Code", can_reject: true}

    defp review_doc(extra) do
      base = %{
        review_gate: @gate,
        reject_open: false,
        reject_form: to_form(%{"note" => ""}, as: :reject),
        reject_error: nil
      }

      (&CoreComponents.card_review_panel/1)
      |> render_component(Map.merge(base, extra))
      |> LazyHTML.from_fragment()
    end

    defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
    defp attr_of(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

    test "the drawer mode labels Approve with the gate's label; compact says just Approve" do
      doc = review_doc(%{compact: false})
      assert text(doc, "#review-approve .pending-idle") == "Approve → Done"
      assert count(doc, "#review-request-changes") == 1

      assert text(review_doc(%{compact: true}), "#review-approve .pending-idle") == "Approve"
    end

    # RE394 — the gate's actions show a client-side pressed face; the group goes inert.
    test "Approve carries the pressed face inside an action group; Request changes does not" do
      doc = review_doc(%{compact: false})

      assert "action-group" in btn_classes(doc, "#review-panel")
      assert "pending-action" in btn_classes(doc, "#review-approve")
      assert attr_of(doc, "#review-approve", "phx-click") == ["review_approve"]
      assert text(doc, "#review-approve .pending-idle") == "Approve → Done"
      assert text(doc, "#review-approve .pending-face") == "Approving…"
      assert count(doc, "#review-approve .pending-face .loading.loading-spinner.loading-xs") == 1
      refute "pending-action" in btn_classes(doc, "#review-request-changes")
    end

    test "compact Approve says Approve idle and Approving… pressed" do
      doc = review_doc(%{compact: true})

      assert text(doc, "#review-approve .pending-idle") == "Approve"
      assert text(doc, "#review-approve .pending-face") == "Approving…"
    end

    test "Reject → X submits with a Sending back… face; Cancel stays plain; the form sits in the group" do
      doc = review_doc(%{reject_open: true})

      assert attr_of(doc, "#review-send-back", "type") == ["submit"]
      assert "pending-action" in btn_classes(doc, "#review-send-back")
      assert text(doc, "#review-send-back .pending-idle") == "Reject → Code"
      assert text(doc, "#review-send-back .pending-face") == "Sending back…"
      refute "pending-action" in btn_classes(doc, "#review-cancel-reject")
      assert count(doc, "#review-panel.action-group #review-reject-form") == 1
    end

    test "compact with the note open: short hint, 8-row note, quote button, stays-put line, phx-change" do
      doc =
        review_doc(%{
          compact: true,
          reject_open: true,
          quote_caption: "B — two panes",
          reject_form: to_form(%{"note" => "hi"}, as: :reject)
        })

      hint = text(doc, "#review-reject-panel")
      assert hint =~ "Returns to"
      assert hint =~ "Code"
      refute hint =~ "the reject target set on this stage"

      assert attr_of(doc, "#review-request-note", "rows") == ["8"]
      assert text(doc, "#review-request-note") == "hi"

      assert text(doc, "#review-quote-caption") == "+ Quote “B — two panes”"
      assert attr_of(doc, "#review-quote-caption", "data-quote") == ["“B — two panes”"]
      assert [hook] = attr_of(doc, "#review-quote-caption", "phx-hook")
      assert hook =~ "QuoteCaption"

      assert text(doc, "#review-note-stays") == "Your note stays put while you switch mockups."
      assert attr_of(doc, "#review-reject-form", "phx-change") == ["review_reject_change"]
    end

    test "the drawer mode with the note open keeps the 3-row note and the long hint, and no compact extras" do
      doc = review_doc(%{compact: false, reject_open: true})

      assert count(doc, "#review-quote-caption") == 0
      assert count(doc, "#review-note-stays") == 0
      assert attr_of(doc, "#review-request-note", "rows") == ["3"]
      assert doc |> LazyHTML.query("#review-reject-panel") |> LazyHTML.text() =~ " — the reject target set on this stage."
      assert attr_of(doc, "#review-reject-form", "phx-change") == ["review_reject_change"]
    end
  end

  describe "card_gate_panel/1 (RE380)" do
    defp gate_doc(card, extra) do
      base = %{
        card: card,
        archived: false,
        runs: [],
        run_flow: nil,
        advance_available?: false,
        question: nil,
        answer_questions: nil,
        answer_step: 0,
        answer_values: %{},
        answer_form: to_form(%{"body" => ""}, as: :answer),
        body_loading: false,
        review_gate: nil,
        reject_open: false,
        reject_form: to_form(%{"note" => ""}, as: :reject),
        reject_error: nil
      }

      (&CoreComponents.card_gate_panel/1)
      |> render_component(Map.merge(base, extra))
      |> LazyHTML.from_fragment()
    end

    test "a needs_input card shows the question stepper and no review panel" do
      doc =
        gate_doc(%{status: :needs_input, blocked_since: nil}, %{
          answer_questions: [%{"prompt" => "Which?", "options" => ["A", "B"], "allow_text" => true}]
        })

      assert doc |> LazyHTML.query("#needs-input-panel") |> LazyHTML.text() =~ "Which?"
      assert count(doc, "#review-panel") == 0
    end

    test "an in_review card with a gate shows the review panel and no question panel" do
      doc =
        gate_doc(%{status: :in_review, blocked_since: nil}, %{
          review_gate: %{approve_label: "Approve → Done", reject_target_name: "Code", can_reject: true}
        })

      assert count(doc, "#review-panel") == 1
      assert count(doc, "#needs-input-panel") == 0
    end
  end

  describe "card_drawer/1 hidden (RE380)" do
    defp hidden_drawer_doc(hidden) do
      (&CoreComponents.card_drawer/1)
      |> render_component(
        drawer_attrs(%{status: :in_review}, %{
          hidden: hidden,
          card_nav_enabled: true,
          reject_form: to_form(%{"note" => ""}, as: :reject)
        })
      )
      |> LazyHTML.from_fragment()
    end

    test "a hidden drawer is display:none, binds no window keys and renders no gate panel" do
      doc = hidden_drawer_doc(true)

      [class] = doc |> LazyHTML.query("#card-drawer") |> LazyHTML.attribute("class")
      assert "hidden" in String.split(class)
      assert count(doc, "#card-drawer[phx-window-keydown]") == 0
      assert count(doc, "#review-panel") == 0
      assert count(doc, "#card-drawer-tabs[phx-window-keydown]") == 0
      assert count(doc, "[phx-window-keydown]") == 0
    end

    test "a visible drawer keeps its Esc binding and its review panel" do
      doc = hidden_drawer_doc(false)

      assert count(doc, ~s(#card-drawer[phx-window-keydown="close_drawer"])) == 1
      assert count(doc, "#review-panel") == 1
    end
  end

  describe "card_drawer/1 native_nav (RE400)" do
    defp nav_drawer_doc(native_nav) do
      (&CoreComponents.card_drawer/1)
      |> render_component(
        drawer_attrs(%{status: :in_review}, %{
          card_nav_enabled: true,
          native_nav: native_nav,
          prev_ref: "RLY-0",
          next_ref: "RLY-2",
          reject_form: to_form(%{"note" => ""}, as: :reject)
        })
      )
      |> LazyHTML.from_fragment()
    end

    test "native mode: the flags decide disabled and no arrow keys are bound" do
      doc = nav_drawer_doc(%{prev?: true, next?: false})

      assert count(doc, "#card-drawer-next[disabled]") == 1
      assert count(doc, "#card-drawer-prev:not([disabled])") == 1
      assert count(doc, ~s([phx-window-keydown="prev_card"])) == 0
      assert count(doc, ~s([phx-window-keydown="next_card"])) == 0
      assert count(doc, "#card-drawer-panel[phx-hook]") == 0
      assert [hook] = doc |> LazyHTML.query("#card-drawer-prev") |> LazyHTML.attribute("phx-hook")
      assert String.ends_with?(hook, "NativeCardNav")
    end

    test "web mode (native_nav nil) keeps the server-driven chevrons" do
      doc = nav_drawer_doc(nil)

      assert count(doc, ~s(#card-drawer-prev[phx-click="prev_card"])) == 1
      assert count(doc, ~s(#card-drawer-next[phx-click="next_card"])) == 1
      assert count(doc, ~s([phx-hook$="NativeCardNav"])) == 0
    end
  end

  describe "mockup_viewer_bar/1 (RE380)" do
    defp bar_doc(index) do
      (&CoreComponents.mockup_viewer_bar/1)
      |> render_component(caption: "B — two panes", index: index, total: 3, back_patch: "/board/b?card=RE1")
      |> LazyHTML.from_fragment()
    end

    test "a middle mockup: back link, caption, count, both arrows enabled" do
      doc = bar_doc(2)

      assert count(doc, ~s(#mockup-viewer-bar-back[aria-label="Back to card"][href="/board/b?card=RE1"])) == 1
      assert text(doc, "#mockup-viewer-bar-caption") == "B — two panes"
      assert text(doc, "#mockup-viewer-bar-count") == "2 / 3"
      assert count(doc, "#mockup-viewer-bar-prev[disabled]") == 0
      assert count(doc, "#mockup-viewer-bar-next[disabled]") == 0
    end

    test "the last mockup disables next; the first disables prev" do
      assert count(bar_doc(3), "#mockup-viewer-bar-next[disabled]") == 1
      assert count(bar_doc(1), "#mockup-viewer-bar-prev[disabled]") == 1
    end

    test "the arrows name the mockup by default" do
      assert attr_of(bar_doc(2), "#mockup-viewer-bar-prev", "aria-label") == ["Previous mockup"]
      assert attr_of(bar_doc(2), "#mockup-viewer-bar-next", "aria-label") == ["Next mockup"]
    end
  end

  describe "note_image_row/1 (RE427)" do
    defp note_image(name), do: %Schemas.Attachment{id: Ecto.UUID.generate(), filename: name}

    defp row_doc(images) do
      (&CoreComponents.note_image_row/1)
      |> render_component(id: "note-1-images", images: images, image_href: &"?image=#{&1}")
      |> LazyHTML.from_fragment()
    end

    test "one patch link per image, each a 108px thumbnail in a wrapping row" do
      [a, b] = images = [note_image("overflow.png"), note_image("phone.png")]
      doc = row_doc(images)

      row = doc |> classes("#note-1-images") |> String.split()
      for c <- ~w(mt-1.5 flex flex-wrap gap-2), do: assert(c in row, "row lacks #{c}: #{inspect(row)}")

      assert count(doc, "#note-1-images > a") == 2
      assert attr_of(doc, "#note-1-images-#{a.id}", "aria-label") == ["Open overflow.png"]
      assert attr_of(doc, "#note-1-images-#{b.id}", "href") == ["?image=#{b.id}"]
      assert attr_of(doc, "#note-1-images-#{a.id}", "data-phx-link") == ["patch"]

      for {image, index} <- Enum.with_index(images) do
        img = "#note-1-images-#{image.id} img"
        assert attr_of(doc, img, "src") == ["/attachments/#{image.id}"]
        assert attr_of(doc, img, "alt") == [Enum.at(~w(overflow.png phone.png), index)]

        thumb = doc |> classes(img) |> String.split()

        for c <- ~w(h-[108px] w-auto max-w-[240px] rounded-md border border-base-300 bg-base-200 object-cover),
            do: assert(c in thumb, "thumbnail lacks #{c}: #{inspect(thumb)}")
      end
    end

    test "renders nothing without images" do
      assert (&CoreComponents.note_image_row/1)
             |> render_component(id: "note-1-images", images: [], image_href: &"?image=#{&1}")
             |> String.trim() == ""
    end
  end

  describe "image_attach_hint/1 (RE427)" do
    defp hint_doc(attrs) do
      (&CoreComponents.image_attach_hint/1)
      |> render_component(Map.merge(%{id: "h"}, attrs))
      |> LazyHTML.from_fragment()
    end

    test "each error renders as a p.text-error before the hints" do
      doc = hint_doc(%{errors: ["a", "b"]})

      ps = LazyHTML.query(doc, "#h > p")
      assert ps |> Enum.take(2) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["a", "b"]
      assert doc |> LazyHTML.query("#h-error-0.text-error.text-xs") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#h-error-1.text-error.text-xs") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#h > p.text-error") |> Enum.count() == 2
    end

    test "the desktop hint is built from the source policy functions" do
      doc = hint_doc(%{errors: []})
      desktop = doc |> LazyHTML.query("#h p.hidden.drawer\\:block") |> LazyHTML.text()

      assert desktop =~ "up to #{Schemas.Comment.max_images()} images"
      assert desktop =~ Enum.join(Schemas.Attachment.image_type_names(), ", ")
      assert desktop =~ "#{div(Schemas.Attachment.max_bytes(), 1_048_576)} MB each"

      assert doc |> LazyHTML.query("#h p.drawer\\:hidden") |> LazyHTML.text() |> String.trim() ==
               "Attach images from the web app."
    end

    test "disabled (embed) renders only the phone hint, always shown" do
      doc = hint_doc(%{errors: [], enabled: false})

      refute LazyHTML.to_html(doc) =~ "Paste, drop"
      assert doc |> LazyHTML.query("#h p") |> LazyHTML.text() |> String.trim() == "Attach images from the web app."
      assert doc |> LazyHTML.query("#h p.drawer\\:hidden") |> Enum.count() == 0
    end
  end

  describe "note_origin_tag/1 (RE428)" do
    @origin_tag_classes "rounded bg-base-200 px-1.5 py-px font-mono text-[9.5px] font-semibold tracking-[0.04em] text-base-content/60"

    defp origin_doc(attrs) do
      (&CoreComponents.note_origin_tag/1) |> render_component(Map.merge(%{id: "t"}, attrs)) |> LazyHTML.from_fragment()
    end

    test "an answer note's tag names its question" do
      doc = origin_doc(%{origin: :answer, question: 2})

      assert count(doc, "span#t") == 1
      assert doc |> LazyHTML.query("span#t") |> LazyHTML.text() |> String.trim() == "FROM ANSWER · Q2"
      assert classes(doc, "span#t") == @origin_tag_classes
    end

    test "a rejection note's tag" do
      doc = origin_doc(%{origin: :rejection, question: nil})

      assert doc |> LazyHTML.query("span#t") |> LazyHTML.text() |> String.trim() == "FROM REJECTION"
      assert classes(doc, "span#t") == @origin_tag_classes
    end

    test "an ordinary note renders nothing" do
      assert (&CoreComponents.note_origin_tag/1) |> render_component(id: "t", origin: nil) |> String.trim() == ""
    end
  end

  describe "image_attach_box/1 link_target and image_attach_button/1 label (RE428)" do
    defp story_upload do
      %Phoenix.LiveView.UploadConfig{
        name: :reject_images,
        ref: "phx-test-reject-images",
        accept: Enum.join(Schemas.Attachment.image_types(), ","),
        max_entries: Schemas.Comment.max_images(),
        max_file_size: Schemas.Attachment.max_bytes(),
        auto_upload?: true,
        entries: []
      }
    end

    defp box_doc(attrs) do
      assigns = Map.merge(%{upload: story_upload()}, attrs)

      ~H"""
      <CoreComponents.image_attach_box id="box" upload={@upload} {Map.take(assigns, [:link_target])}>
        <textarea id="note"></textarea>
      </CoreComponents.image_attach_box>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    test "a linked box names its textarea in data-link-target" do
      assert attr_of(box_doc(%{link_target: "review-request-note"}), "#box", "data-link-target") == [
               "review-request-note"
             ]
    end

    test "an unlinked box (the Notes composer) has no data-link-target" do
      assert attr_of(box_doc(%{}), "#box", "data-link-target") == []
    end

    test "a labelled 📎 shows its text and stays hidden below drawer:" do
      doc =
        (&CoreComponents.image_attach_button/1)
        |> render_component(id: "attach", upload: story_upload(), label: "Attach images")
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#attach > span:not(.sr-only)") |> LazyHTML.text() |> String.trim() ==
               "Attach images"

      cls = doc |> classes("#attach") |> String.split()
      for c <- ~w(hidden drawer:inline-flex), do: assert(c in cls, "button lacks #{c}: #{inspect(cls)}")
    end

    test "an unlabelled 📎 is RE427's icon button with sr-only text" do
      doc =
        (&CoreComponents.image_attach_button/1)
        |> render_component(id: "attach", upload: story_upload())
        |> LazyHTML.from_fragment()

      assert count(doc, "#attach .hero-paper-clip") == 1
      assert doc |> LazyHTML.query("#attach > span.sr-only") |> LazyHTML.text() |> String.trim() == "Attach images"
      assert count(doc, "#attach > span:not(.sr-only):not(.hero-paper-clip)") == 0
      assert "w-[27px]" in (doc |> classes("#attach") |> String.split())
    end
  end

  describe "mockup_viewer_header/1 count_noun (RE427)" do
    test "the count reads '<noun> n of N' and no noun label renders" do
      doc =
        (&CoreComponents.mockup_viewer_header/1)
        |> render_component(%{caption: "drawer.png", index: 2, total: 4, count_noun: "Image"})
        |> LazyHTML.from_fragment()

      assert text(doc, "#mockup-viewer-header-count") == "Image 2 of 4"
      assert count(doc, "#mockup-viewer-header-noun") == 0
    end
  end

  describe "card_mockup_viewer/1 images section (RE427)" do
    defp images_viewer_doc(attrs) do
      items = [
        %{key: "i1", src: "/attachments/i1", caption: "overflow.png", kind: :image, byline: "From a note by J · 1m ago"},
        %{key: "i2", src: "/attachments/i2", caption: "drawer.png", kind: :image, byline: "From a note by J · just now"}
      ]

      (&CoreComponents.card_mockup_viewer/1)
      |> render_component(
        Map.merge(
          %{
            ref: "RE1",
            card: %{title: "T"},
            stage_name: "Review",
            stage_owner: :human,
            items: items,
            current_key: "i2",
            back_patch: "/",
            item_href: &"?image=#{&1}",
            label: "Images · 2",
            noun: "Image"
          },
          attrs
        )
      )
      |> LazyHTML.from_fragment()
    end

    test "show_captions puts each filename under its tile, the current one highlighted" do
      doc = images_viewer_doc(%{show_captions: true, count_noun: "Image", byline: "From a note by J · just now"})

      captions = LazyHTML.query(doc, "#mockup-viewer-mockup-tiles .font-mono.text-\\[10px\\]")
      assert Enum.map(captions, &(&1 |> LazyHTML.text() |> String.trim())) == ["overflow.png", "drawer.png"]

      current = doc |> classes("#mockup-viewer-mockup-tiles .text-primary") |> String.split()
      for c <- ~w(truncate font-mono text-[10px] text-primary font-semibold), do: assert(c in current)

      assert text(doc, "#mockup-viewer-byline") == "From a note by J · just now"
      byline = doc |> classes("#mockup-viewer-byline") |> String.split()
      for c <- ~w(mt-3 text-[11px] leading-[1.45] text-base-content/50), do: assert(c in byline)
      assert text(doc, "#mockup-viewer-header-count") == "Image 2 of 2"
    end

    test "without the new attrs no captions or byline render" do
      doc = images_viewer_doc(%{})

      assert count(doc, "#mockup-viewer-byline") == 0
      assert count(doc, "#mockup-viewer-mockup-tiles .font-mono") == 0
    end
  end

  describe "mockup_viewer_header/1 (RE392)" do
    defp header_doc(attrs) do
      (&CoreComponents.mockup_viewer_header/1)
      |> render_component(Map.merge(%{caption: "B — two panes", index: 2, total: 3}, attrs))
      |> LazyHTML.from_fragment()
    end

    defp class_list(doc, selector), do: doc |> classes(selector) |> String.split()

    test "a label: the noun, the caption, n of m and the key hint" do
      doc = header_doc(%{})

      assert count(doc, "header#mockup-viewer-header") == 1
      assert text(doc, "#mockup-viewer-header-noun") == "Mockup"
      assert text(doc, "#mockup-viewer-header-caption") == "B — two panes"
      assert text(doc, "#mockup-viewer-header-count") == "2 of 3"

      keys = doc |> text("#mockup-viewer-header-keys") |> String.split() |> Enum.join(" ")
      assert keys == "← → switch · Esc back to card"
      assert count(doc, "#mockup-viewer-header-keys kbd.kbd.kbd-xs") == 3
    end

    test "the noun swaps for screenshots" do
      doc = header_doc(%{noun: "Screenshot", caption: "Board", index: 1, total: 2})

      assert text(doc, "#mockup-viewer-header-noun") == "Screenshot"
      assert text(doc, "#mockup-viewer-header-count") == "1 of 2"
    end

    test "matches the card mockup's classes and lays out as flex without a class" do
      doc = header_doc(%{})

      header = class_list(doc, "#mockup-viewer-header")

      for c <- ~w(flex min-h-11 items-center border-b border-base-300 bg-base-100 px-4 py-2),
          do: assert(c in header, "header lacks #{c}: #{inspect(header)}")

      caption = class_list(doc, "#mockup-viewer-header-caption")
      for c <- ~w(truncate text-sm font-semibold), do: assert(c in caption)

      count_classes = class_list(doc, "#mockup-viewer-header-count")
      for c <- ~w(shrink-0 font-mono text-xs text-base-content/55), do: assert(c in count_classes)

      noun = class_list(doc, "#mockup-viewer-header-noun")
      for c <- ~w(font-mono text-[10px] uppercase text-base-content/60 shrink-0), do: assert(c in noun)

      assert "shrink-0" in class_list(doc, "#mockup-viewer-header-keys")
    end

    test "is never a switcher: no buttons, links or clicks" do
      doc = header_doc(%{})

      assert count(doc, "#mockup-viewer-header button") == 0
      assert count(doc, "#mockup-viewer-header a") == 0
      assert count(doc, "#mockup-viewer-header [phx-click]") == 0
    end

    test "every part's id derives from the id" do
      doc = header_doc(%{id: "h2"})

      for sel <- ~w(header#h2 #h2-noun #h2-caption #h2-count #h2-keys),
          do: assert(count(doc, sel) == 1, "missing #{sel}")
    end
  end

  describe "card_mockup_viewer/1 (RE380)" do
    test "sheet, framed mockup, key guard and key bindings — and no banner" do
      first = "11111111-aaaa"

      items =
        CardMedia.mockup_items(
          [
            %{"url" => "/attachments/#{first}", "caption" => "Empty"},
            %{"url" => "/attachments/22222222-bbbb", "caption" => "Loaded"}
          ],
          %{first => "text/html", "22222222-bbbb" => "text/html"}
        )

      assigns = %{items: items, first: first}

      html =
        rendered_to_string(~H"""
        <CoreComponents.card_mockup_viewer
          ref="RE9"
          card={%{title: "Notif"}}
          stage_name="Design · Review"
          stage_owner={:human}
          items={@items}
          current_key={@first}
          back_patch="/board/b?card=RE9"
          item_href={&"/v/#{&1}"}
        >
          <:gate>
            <p id="gate-probe">g</p>
          </:gate>
        </CoreComponents.card_mockup_viewer>
        """)

      doc = LazyHTML.from_fragment(html)

      sheet = LazyHTML.query(doc, "#mockup-viewer-sheet")
      assert Enum.count(sheet) == 1
      assert sheet |> LazyHTML.query("#mockup-viewer-back") |> LazyHTML.text() =~ "Back to card"

      assert sheet |> LazyHTML.query("#mockup-viewer-stage-chip.badge-primary") |> LazyHTML.text() =~
               "Design · Review"

      assert text(sheet, "#mockup-viewer-card-title") == "Notif"
      assert Enum.count(LazyHTML.query(sheet, "#gate-probe")) == 1

      sheet_html = LazyHTML.to_html(sheet)

      positions =
        Enum.map(
          [
            ~s(id="mockup-viewer-back"),
            ~s(id="mockup-viewer-stage-chip"),
            ">RE9<",
            ~s(id="mockup-viewer-card-title"),
            ~s(id="gate-probe")
          ],
          fn needle -> sheet_html |> :binary.match(needle) |> elem(0) end
        )

      assert positions == Enum.sort(positions)

      frame = LazyHTML.query(doc, "iframe#mockup-viewer-frame")
      assert LazyHTML.attribute(frame, "sandbox") == [RelayWeb.mockup_sandbox()]
      assert LazyHTML.attribute(frame, "src") == [RelayWeb.attachment_path(first)]
      assert LazyHTML.attribute(frame, "title") == ["Mockup: Empty (RE9)"]

      assert attr_of(doc, "#mockup-viewer", "phx-hook") == ["ArrowKeyGuard"]
      assert attr_of(doc, "#mockup-viewer", "data-guard-keys") == ["ArrowLeft,ArrowRight,Escape"]

      assert count(doc, ~s(#mockup-viewer-key-prev[phx-key="ArrowLeft"][phx-window-keydown="mockup_prev"])) == 1
      assert count(doc, ~s(#mockup-viewer-key-next[phx-key="ArrowRight"][phx-window-keydown="mockup_next"])) == 1
      assert count(doc, ~s(#mockup-viewer-key-back[phx-key="Escape"][phx-window-keydown="mockup_back"])) == 1

      assert count(doc, "#mockup-viewer-banner") == 0
    end

    test "the desktop header is main's first child; the phone bar is unchanged (RE392)" do
      first = "11111111-aaaa"

      items =
        CardMedia.mockup_items(
          [
            %{"url" => "/attachments/#{first}", "caption" => "Empty"},
            %{"url" => "/attachments/22222222-bbbb", "caption" => "Loaded"}
          ],
          %{first => "text/html", "22222222-bbbb" => "text/html"}
        )

      assigns = %{items: items, first: first}

      doc =
        ~H"""
        <CoreComponents.card_mockup_viewer
          ref="RE9"
          card={%{title: "Notif"}}
          stage_name="Design · Review"
          stage_owner={:human}
          items={@items}
          current_key={@first}
          back_patch="/board/b?card=RE9"
          item_href={&"/v/#{&1}"}
        />
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert count(doc, "#mockup-viewer-main > header#mockup-viewer-header:first-child") == 1

      main_html = doc |> LazyHTML.query("#mockup-viewer-main") |> LazyHTML.to_html()

      {header_at, _} = :binary.match(main_html, ~s(id="mockup-viewer-header"))
      {frame_at, _} = :binary.match(main_html, ~s(id="mockup-viewer-frame-box-))
      assert header_at < frame_at

      header = doc |> classes("#mockup-viewer-header") |> String.split()
      assert "hidden" in header
      assert "drawer:flex" in header

      assert text(doc, "#mockup-viewer-header-caption") == "Empty"
      assert text(doc, "#mockup-viewer-header-count") == "1 of 2"
      assert text(doc, "#mockup-viewer-header-noun") == "Mockup"

      assert "drawer:hidden" in (doc |> classes("#mockup-viewer-bar") |> String.split())
      assert text(doc, "#mockup-viewer-bar-caption") == "Empty"
      assert text(doc, "#mockup-viewer-bar-count") == "1 / 2"
    end
  end

  describe "card_mockup_viewer/1 screenshots (RE390)" do
    @viewer_items [
      %{key: 1, src: "/images/a.png", caption: "Board", kind: :image},
      %{key: 2, src: "/attachments/h", caption: nil, kind: :html}
    ]

    defp screenshot_viewer_doc(current_key) do
      assigns = %{items: @viewer_items, current_key: current_key}

      ~H"""
      <CoreComponents.card_mockup_viewer
        ref="RE9"
        card={%{title: "Notif"}}
        stage_name="Code"
        stage_owner={:ai}
        items={@items}
        current_key={@current_key}
        back_patch="/board/b?card=RE9"
        item_href={&"/v/#{&1}"}
        label="Screenshots"
        noun="Screenshot"
      />
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    test "an image item is shown at natural size in a scrolling frame, under the Screenshots label" do
      doc = screenshot_viewer_doc(1)

      [box_class] = attr_of(doc, "#mockup-viewer-frame-box-1", "class")
      assert "overflow-auto" in String.split(box_class)

      img = LazyHTML.query(doc, ~s(#mockup-viewer-frame-box-1 img#mockup-viewer-image[src="/images/a.png"]))
      [img_class] = LazyHTML.attribute(img, "class")
      assert "max-w-none" in String.split(img_class)
      assert count(doc, "iframe#mockup-viewer-frame") == 0

      assert text(doc, "#mockup-viewer-sheet #mockup-viewer-mockups > span") == "Screenshots"

      assert text(doc, "#mockup-viewer-header-caption") == "Board"
      assert text(doc, "#mockup-viewer-header-count") == "1 of 2"
      assert count(doc, "#mockup-viewer-mockups-viewing") == 0
      assert attr_of(doc, "#mockup-viewer-bar-prev", "aria-label") == ["Previous screenshot"]
    end

    test "an HTML item is framed in the sandboxed iframe, titled with the noun" do
      doc = screenshot_viewer_doc(2)

      [box_class] = attr_of(doc, "#mockup-viewer-frame-box-2", "class")
      assert "overflow-hidden" in String.split(box_class)

      frame = LazyHTML.query(doc, ~s(#mockup-viewer-frame-box-2 iframe#mockup-viewer-frame[sandbox="allow-scripts"]))
      assert LazyHTML.attribute(frame, "title") == ["Screenshot: Screenshot (RE9)"]
      assert LazyHTML.attribute(frame, "src") == ["/attachments/h"]
    end

    test "the desktop header names the screenshot, falling back to the noun (RE392)" do
      doc = screenshot_viewer_doc(2)

      assert text(doc, "#mockup-viewer-header-noun") == "Screenshot"
      assert text(doc, "#mockup-viewer-header-caption") == "Screenshot"
      assert text(doc, "#mockup-viewer-header-count") == "2 of 2"
    end
  end

  describe "mobile_nav_bar/1 (RE393)" do
    defp nav_doc(attrs) do
      (&CoreComponents.mobile_nav_bar/1)
      |> render_component(Map.merge(%{id: "nb"}, attrs))
      |> LazyHTML.from_fragment()
    end

    defp nb_text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
    defp nb_attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
    defp nb_count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

    test "back_bridge renders a NativeBack button with the chevron and label; a truncating title" do
      doc = nav_doc(%{title: "RL9001", back_label: "Board", back_bridge: true})

      assert nb_count(doc, "header#nb") == 1
      assert nb_count(doc, "button#nb-back[type=button]") == 1
      assert [hook] = nb_attr(doc, "#nb-back", "phx-hook")
      assert String.ends_with?(hook, "NativeBack")
      assert nb_count(doc, "#nb-back span.hero-chevron-left") == 1
      assert nb_text(doc, "#nb-back") == "Board"

      assert nb_text(doc, "#nb-title") == "RL9001"
      assert [title_class] = nb_attr(doc, "#nb-title", "class")
      assert "truncate" in String.split(title_class)
    end

    test "back_patch renders a patch link with no hook" do
      doc = nav_doc(%{title: "Fonts", back_label: "Card", back_patch: "/cards/RL1?board=b"})

      assert nb_count(doc, "a#nb-back") == 1
      assert nb_attr(doc, "#nb-back", "data-phx-link") == ["patch"]
      assert nb_attr(doc, "#nb-back", "href") == ["/cards/RL1?board=b"]
      assert nb_count(doc, "#nb-back[phx-hook]") == 0
      assert nb_text(doc, "#nb-back") == "Card"
    end

    test "no back_label (or a nil/blank one) reads Back" do
      assert nb_text(nav_doc(%{title: "T", back_bridge: true}), "#nb-back") == "Back"
      assert nb_text(nav_doc(%{title: "T", back_bridge: true, back_label: nil}), "#nb-back") == "Back"
      assert nb_text(nav_doc(%{title: "T", back_bridge: true, back_label: "  "}), "#nb-back") == "Back"
    end
  end

  describe "segmented_control/1 (RE393)" do
    test "text segments: pass-through attrs, data-active, the active one on base-100" do
      assigns = %{}

      doc =
        ~H"""
        <CoreComponents.segmented_control id="sc">
          <:option id="s-a" label="Detail" active phx-click="drawer_tab" phx-value-tab="detail" />
          <:option id="s-b" label="Run" active={false} phx-click="drawer_tab" phx-value-tab="run" />
          <:option id="s-c" label="Activity" phx-click="drawer_tab" phx-value-tab="activity" />
        </CoreComponents.segmented_control>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert nb_count(doc, "button#s-a[type=button]") == 1
      assert nb_attr(doc, "#s-a", "data-active") == ["true"]
      assert nb_attr(doc, "#s-a", "phx-click") == ["drawer_tab"]
      assert nb_attr(doc, "#s-a", "phx-value-tab") == ["detail"]
      assert nb_text(doc, "#s-a") == "Detail"
      assert nb_attr(doc, "#s-b", "data-active") == ["false"]
      assert nb_attr(doc, "#s-c", "data-active") == ["false"]

      assert [active_class] = nb_attr(doc, "#s-a", "class")
      assert "bg-base-100" in String.split(active_class)
      assert [inactive_class] = nb_attr(doc, "#s-b", "class")
      refute "bg-base-100" in String.split(inactive_class)
    end

    test "icon segments: a labelled group, aria-labelled buttons, icons and no visible text" do
      assigns = %{}

      doc =
        ~H"""
        <CoreComponents.segmented_control id="rw" variant={:icon} aria_label="Render width">
          <:option id="rw-phone" icon="hero-device-phone-mobile" label="Phone width" active />
          <:option id="rw-desktop" icon="hero-computer-desktop" label="Desktop, fit to width" />
        </CoreComponents.segmented_control>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert nb_attr(doc, "#rw", "role") == ["group"]
      assert nb_attr(doc, "#rw", "aria-label") == ["Render width"]
      assert nb_attr(doc, "#rw-phone", "aria-label") == ["Phone width"]
      assert nb_attr(doc, "#rw-desktop", "aria-label") == ["Desktop, fit to width"]
      assert nb_count(doc, "#rw-phone span.hero-device-phone-mobile") == 1
      assert nb_count(doc, "#rw-desktop span.hero-computer-desktop") == 1
      assert nb_text(doc, "#rw") == ""

      [group] = nb_attr(doc, "#rw", "class")
      assert "rounded-[9px]" in String.split(group)
      [phone] = nb_attr(doc, "#rw-phone", "class")
      [desktop] = nb_attr(doc, "#rw-desktop", "class")

      for c <- ~w(h-[38px] w-[38px] rounded-[7px] bg-base-100 text-base-content shadow-xs),
          do: assert(c in String.split(phone), c)

      assert "text-base-content/55" in String.split(desktop)
      refute "bg-base-100" in String.split(desktop)
      assert nb_count(doc, "#rw-phone span.size-5") == 1
    end
  end

  describe "mockup_viewer_pager/1 (RE393)" do
    defp pager_doc(attrs) do
      (&CoreComponents.mockup_viewer_pager/1)
      |> render_component(Map.merge(%{id: "pg"}, attrs))
      |> LazyHTML.from_fragment()
    end

    defp pg_attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
    defp pg_count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
    defp pg_text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    test "1. the first of two: prev disabled, next live, two dots, 1 of 2" do
      doc = pager_doc(%{index: 1, total: 2})

      assert pg_count(doc, "button#pg-prev[type=button][disabled]") == 1
      assert pg_attr(doc, "#pg-prev", "phx-click") == ["mockup_prev"]
      assert pg_attr(doc, "#pg-prev", "aria-label") == ["Previous mockup"]
      assert pg_count(doc, "button#pg-next[type=button]") == 1
      assert pg_count(doc, "#pg-next[disabled]") == 0
      assert pg_attr(doc, "#pg-next", "phx-click") == ["mockup_next"]
      assert pg_attr(doc, "#pg-next", "aria-label") == ["Next mockup"]

      assert [first, second] = doc |> LazyHTML.query("#pg-dots > *") |> LazyHTML.attribute("class")
      assert "bg-base-content" in String.split(first)
      assert "bg-base-content/25" in String.split(second)
      refute "bg-base-content" in String.split(second)
      assert pg_text(doc, "#pg-count") == "1 of 2"
    end

    test "2. the last of three names the noun and disables next" do
      doc = pager_doc(%{index: 3, total: 3, noun: "Screenshot"})

      assert pg_count(doc, "#pg-next[disabled]") == 1
      assert pg_attr(doc, "#pg-next", "aria-label") == ["Next screenshot"]
      assert pg_count(doc, "#pg-prev[disabled]") == 0
      assert pg_attr(doc, "#pg-prev", "aria-label") == ["Previous screenshot"]
      assert pg_text(doc, "#pg-count") == "3 of 3"
    end

    test "the card mockup's row, chevron, dot and count classes" do
      doc = pager_doc(%{index: 1, total: 2})
      cls = fn selector -> doc |> pg_attr(selector, "class") |> List.first("") |> String.split() end

      for c <- ~w(flex h-[48px] items-center justify-between border-t border-base-300 bg-base-100 px-2),
          do: assert(c in cls.("#pg"), c)

      assert "size-11" in cls.("#pg-prev")
      assert "text-base-content/25" in cls.("#pg-prev")
      assert "text-primary" in cls.("#pg-next")
      assert pg_count(doc, "#pg-prev span.hero-chevron-left.size-6") == 1
      assert pg_count(doc, "#pg-next span.hero-chevron-right.size-6") == 1
      assert "gap-2" in cls.("#pg-dots")
      assert doc |> LazyHTML.query("#pg-dots > .size-\\[7px\\].rounded-full") |> Enum.count() == 2

      for c <- ~w[ml-1.5 font-mono text-(length:--m-meta) text-base-content/60], do: assert(c in cls.("#pg-count"), c)
    end
  end

  describe "mockup_viewer_zoom/1 (RE393)" do
    defp zoom_doc(attrs) do
      (&CoreComponents.mockup_viewer_zoom/1)
      |> render_component(attrs)
      |> LazyHTML.from_fragment()
    end

    test "11. a Zoom group: − disabled, Fit, + live, 44px icon targets, no phx-click" do
      doc = zoom_doc(%{id: "z"})

      assert pg_count(doc, ~s(div#z[role=group][aria-label=Zoom])) == 1
      assert pg_count(doc, ~s(#z button#z-out[type=button][disabled][aria-label="Zoom out"])) == 1
      assert pg_count(doc, ~s(#z button#z-reset[type=button][aria-label="Reset zoom to fit"])) == 1
      assert pg_text(doc, "#z-reset") == "Fit"
      assert pg_count(doc, ~s(#z button#z-in[type=button][aria-label="Zoom in"])) == 1
      assert pg_count(doc, "#z-in[disabled]") == 0

      cls = fn selector -> doc |> pg_attr(selector, "class") |> List.first("") |> String.split() end
      assert "size-11" in cls.("#z-out")
      assert "size-11" in cls.("#z-in")
      assert "h-11" in cls.("#z-reset")
      assert "min-w-14" in cls.("#z-reset")
      assert pg_count(doc, "#z-out span.hero-minus") == 1
      assert pg_count(doc, "#z-in span.hero-plus") == 1

      assert pg_count(doc, "[phx-click]") == 0
    end
  end

  describe "card_mockup_viewer/1 embedded zoom (RE393)" do
    defp embed_viewer_doc(items, current_key) do
      assigns = %{items: items, current_key: current_key}

      ~H"""
      <CoreComponents.card_mockup_viewer
        ref="RE9"
        card={%{title: "Notif"}}
        stage_name="Review"
        stage_owner={:human}
        items={@items}
        current_key={@current_key}
        back_patch="/cards/RE9?board=b&embed=1"
        item_href={&"/v/#{&1}"}
        embed
      />
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    @zoom_items [
      %{key: 1, src: "/images/a.png", caption: "Board", kind: :image},
      %{key: 2, src: "/attachments/h", caption: "Empty", kind: :html}
    ]

    test "12. an HTML item gets the zoom wrap, data-zoom, a sizer around the frame and no native hook" do
      doc = embed_viewer_doc(@zoom_items, 2)

      assert pg_count(doc, ~s(#mockup-viewer-zoom-wrap[phx-update=ignore] #mockup-viewer-zoom)) == 1

      assert pg_attr(doc, "#mockup-viewer-frame-box-2", "data-zoom") == ["1"]
      box = doc |> pg_attr("#mockup-viewer-frame-box-2", "class") |> List.first("") |> String.split()
      assert "overflow-x-auto" in box
      assert "overflow-y-hidden" in box
      refute "overflow-hidden" in box

      assert pg_count(
               doc,
               "#mockup-viewer-frame-box-2 > #mockup-viewer-frame-sizer[data-zoom-sizer] > iframe#mockup-viewer-frame"
             ) ==
               1

      # RE400 — the viewer no longer signals the native shell.
      assert pg_count(doc, "#mockup-viewer-native") == 0
    end

    test "RE405 1. an embedded image item fits with the zoom control, no sizer, iframe or width toggle" do
      doc = embed_viewer_doc(@zoom_items, 1)

      assert pg_count(doc, ~s(#mockup-viewer-zoom-wrap[phx-update=ignore] #mockup-viewer-zoom)) == 1
      assert pg_attr(doc, "#mockup-viewer-frame-box-1", "data-kind") == ["image"]
      assert pg_attr(doc, "#mockup-viewer-frame-box-1", "data-zoom") == ["1"]
      assert pg_count(doc, "#mockup-viewer-frame-box-1[data-render]") == 0

      box = doc |> pg_attr("#mockup-viewer-frame-box-1", "class") |> List.first("") |> String.split()
      assert "overflow-auto" in box
      refute "overflow-x-auto" in box
      refute "overflow-y-hidden" in box

      assert pg_count(doc, "#mockup-viewer-frame-sizer") == 0
      # The sheet's tile for the HTML item is a miniature iframe; the frame box has none.
      assert pg_count(doc, "#mockup-viewer-frame-box-1 iframe") == 0
      assert pg_count(doc, "#mockup-viewer-frame") == 0
      assert pg_count(doc, "img#mockup-viewer-image") == 1
      assert pg_count(doc, "#mockup-viewer-width") == 0
      assert pg_count(doc, "#mockup-viewer-native") == 0
    end

    test "RE405 2. an embedded HTML item is marked data-kind=html with the phone render" do
      doc = embed_viewer_doc(@zoom_items, 2)

      assert pg_attr(doc, "#mockup-viewer-frame-box-2", "data-kind") == ["html"]
      assert pg_attr(doc, "#mockup-viewer-frame-box-2", "data-render") == ["phone"]
      assert pg_attr(doc, "#mockup-viewer-frame-box-2", "data-zoom") == ["1"]
      assert pg_count(doc, ~s(#mockup-viewer-zoom-wrap[phx-update=ignore] #mockup-viewer-zoom)) == 1
      assert pg_count(doc, "#mockup-viewer-width") == 1
    end

    test "RE405 3. a non-embedded image item keeps natural size: data-kind, no zoom" do
      assigns = %{items: @zoom_items}

      doc =
        ~H"""
        <CoreComponents.card_mockup_viewer
          ref="RE9"
          card={%{title: "Notif"}}
          stage_name="Review"
          stage_owner={:human}
          items={@items}
          current_key={1}
          back_patch="/cards/RE9?board=b"
          item_href={&"/v/#{&1}"}
        />
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert pg_attr(doc, "#mockup-viewer-frame-box-1", "data-kind") == ["image"]
      assert pg_count(doc, "[data-zoom]") == 0
      assert pg_count(doc, "#mockup-viewer-zoom-wrap") == 0
      box = doc |> pg_attr("#mockup-viewer-frame-box-1", "class") |> List.first("") |> String.split()
      assert "overflow-auto" in box
    end
  end

  describe "card_review_panel/1 embed copy (RE393)" do
    @embed_gate %{approve_label: "Approve", reject_target_name: "Spec", can_reject: true}

    defp hint_html(gate, embed) do
      render_component(&CoreComponents.card_review_panel/1,
        review_gate: gate,
        reject_open: false,
        reject_form: to_form(%{"note" => ""}, as: :reject),
        embed: embed
      )
    end

    test "embed with a gate points at the native bar below" do
      html = hint_html(@embed_gate, true)

      assert html =~ "Relay AI finished this. Approve or reject below."
      refute html =~ "Approve to move it forward"
    end

    test "non-embed with a gate keeps today's copy" do
      assert hint_html(@embed_gate, false) =~
               "Relay AI finished this. Approve to move it forward, or send it back with a note."
    end

    test "embed with no gate keeps the drag / Move to copy" do
      assert hint_html(nil, true) =~
               "Relay AI finished this. Drag it or use Move to… when you&#39;re ready."
    end
  end

  describe "button/1 pending (RE394)" do
    defp button_doc(html), do: LazyHTML.from_fragment(html)

    defp btn_classes(doc, selector) do
      doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> List.first() |> String.split()
    end

    defp text_of(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

    test "without pending the button renders exactly as before" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button phx-click="go">Send!</CoreComponents.button>
        """)

      doc = button_doc(html)
      assert btn_classes(doc, "button") == ~w(btn btn-primary btn-soft)
      assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("phx-click") == ["go"]
      assert text_of(doc, "button") == "Send!"
      refute html =~ "pending-"
      refute html =~ "<span"
    end

    test "pending appends pending-action to a caller class and stacks the idle and pressed faces" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button
          class="btn btn-sm flex-1"
          style="background:var(--color-success);"
          phx-click="review_approve"
          pending="Approving…"
        >
          Approve → Spec
        </CoreComponents.button>
        """)

      doc = button_doc(html)
      assert btn_classes(doc, "button") == ~w(btn btn-sm flex-1 pending-action)
      assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("style") == ["background:var(--color-success);"]
      assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("phx-click") == ["review_approve"]
      assert doc |> LazyHTML.query("button > *") |> Enum.count() == 1
      assert text_of(doc, "button > .pending-stack > .pending-idle") == "Approve → Spec"

      face = LazyHTML.query(doc, "button > .pending-stack > .pending-face")
      assert LazyHTML.attribute(face, "aria-hidden") == ["true"]
      assert face |> LazyHTML.query("span.loading.loading-spinner.loading-xs") |> Enum.count() == 1
      assert face |> LazyHTML.text() |> String.trim() == "Approving…"

      assert doc |> LazyHTML.query("button > .pending-stack > :nth-child(1).pending-idle") |> Enum.count() == 1
      assert doc |> LazyHTML.query("button > .pending-stack > :nth-child(2).pending-face") |> Enum.count() == 1
    end

    test "pending on a primary submit keeps the variant classes and adds pending-action" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary" type="submit" pending="Saving…">
          Save
        </CoreComponents.button>
        """)

      doc = button_doc(html)
      assert btn_classes(doc, "button") == ~w(btn btn-primary pending-action)
      assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("type") == ["submit"]
      assert text_of(doc, ".pending-face") == "Saving…"
    end

    test "pending is ignored on a link variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button navigate="/" pending="Going…">Home</CoreComponents.button>
        """)

      doc = button_doc(html)
      assert doc |> LazyHTML.query("a") |> LazyHTML.attribute("href") == ["/"]
      assert text_of(doc, "a") == "Home"
      refute html =~ "pending-"
    end
  end

  describe "action_group/1 (RE394)" do
    test "wraps its slot in a div marked action-group plus the caller's classes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.action_group id="g1" class="flex gap-2">
          <button>A</button>
        </CoreComponents.action_group>
        """)

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("div#g1") |> LazyHTML.attribute("class") == ["action-group flex gap-2"]
      assert doc |> LazyHTML.query("div#g1 > button") |> LazyHTML.text() == "A"
    end
  end

  describe "notification_toast/1 (RE399)" do
    defp toast(attrs) do
      (&CoreComponents.notification_toast/1) |> render_component(attrs) |> LazyHTML.from_fragment()
    end

    defp classes(node), do: node |> LazyHTML.attribute("class") |> hd() |> String.split()

    test "a needs_input toast carries the warning accent, the badge and every text slot" do
      doc =
        toast(
          kind: :needs_input,
          card_ref: "RE391",
          title: "Question from the AI",
          card_title: "update landing page"
        )

      root = LazyHTML.query(doc, "div.browser-notify-toast")
      assert Enum.count(root) == 1
      assert LazyHTML.attribute(root, "role") == ["alert"]
      assert LazyHTML.attribute(root, "data-kind") == ["needs_input"]

      for class <- ~w(border-l-4 border-l-warning bg-base-100 rounded-box) do
        assert class in classes(root), "expected #{class} on the toast root"
      end

      badge = LazyHTML.query(doc, ".status-badge.badge-warning")
      assert Enum.count(badge) == 1
      assert LazyHTML.text(badge) =~ "NEEDS INPUT"

      assert doc |> LazyHTML.query(~s([data-field="card_ref"])) |> LazyHTML.text() == "RE391"
      assert doc |> LazyHTML.query(~s([data-field="title"])) |> LazyHTML.text() == "Question from the AI"
      assert doc |> LazyHTML.query(~s([data-field="card_title"])) |> LazyHTML.text() == "update landing page"
      assert doc |> LazyHTML.query(~s([data-action="open"])) |> LazyHTML.text() =~ "Open card"
      assert doc |> LazyHTML.query(~s([data-action="close"][aria-label="close"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query(~s([data-field="board_name"])) |> Enum.count() == 0
    end

    test "an in_review toast carries the primary accent and the eye" do
      doc =
        toast(
          kind: :in_review,
          card_ref: "MK42",
          title: "Ready for your review",
          card_title: "Pricing table copy pass"
        )

      root = LazyHTML.query(doc, "div.browser-notify-toast")
      assert "border-l-primary" in classes(root)
      refute "border-l-warning" in classes(root)
      assert doc |> LazyHTML.query(".hero-eye") |> Enum.count() == 1

      badge = LazyHTML.query(doc, ".status-badge.badge-primary")
      assert LazyHTML.text(badge) =~ "in review"

      assert doc |> LazyHTML.query(~s([data-field="board_name"])) |> Enum.count() == 0
    end

    test "accepts the kind as a string, as the JS payload carries it" do
      doc = toast(kind: "in_review", card_ref: "", title: "", card_title: "")
      assert doc |> LazyHTML.query("div.browser-notify-toast") |> LazyHTML.attribute("data-kind") == ["in_review"]
    end
  end

  describe "notification_settings/1 (RE399)" do
    defp settings(state) do
      (&CoreComponents.notification_settings/1) |> render_component(state: state) |> LazyHTML.from_fragment()
    end

    for state <- [:denied, :unsupported] do
      test "a forced #{state} state renders only the blocked row, with the re-allow hint and Sound" do
        doc = settings(unquote(state))

        assert doc |> LazyHTML.query("li[data-notify-state]") |> Enum.count() == 1
        blocked = LazyHTML.query(doc, ~s(li[data-notify-state="blocked"].menu-disabled))
        assert Enum.count(blocked) == 1
        text = LazyHTML.text(blocked)
        assert text =~ "Blocked in browser settings"
        assert text =~ "To allow: click"
        assert text =~ "then reload."
        assert blocked |> LazyHTML.query(".hero-lock-closed-micro") |> Enum.count() == 1
        assert doc |> LazyHTML.query("li#notify-sound-row input#notify-sound-toggle") |> Enum.count() == 1
      end
    end

    test "a forced granted state renders only the granted row reading On" do
      doc = settings(:granted)

      assert doc |> LazyHTML.query("li[data-notify-state]") |> Enum.count() == 1
      granted = LazyHTML.query(doc, ~s(li[data-notify-state="granted"]))
      assert LazyHTML.text(granted) =~ "On"
      assert granted |> LazyHTML.query(".text-success") |> Enum.count() >= 1
    end

    test "a forced default state renders only the default row with the Enable button" do
      doc = settings(:default)

      assert doc |> LazyHTML.query("li[data-notify-state]") |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s(li[data-notify-state="default"] button#notify-enable.btn.btn-primary.btn-xs))
             |> LazyHTML.text() =~ "Enable"
    end
  end

  defp chip(html, id) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}")
  end
end
