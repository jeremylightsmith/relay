defmodule RelayWeb.ValueStreamFlowLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Relay.ValueStreamFixtures

  alias Relay.Cards
  alias Relay.Flows.DefaultLibrary

  @code_line ~w(branch implement spec_review quality_review sync precommit browser final_review smoke acceptance resync reverify rebrowser merge deploy post)
  @fixes ~w(fix_findings sync_fix final_fix resync_fix github_fix)

  setup :register_and_log_in_user

  setup %{user: user} do
    s = re_board()
    insert(:membership, board: s.board, user: user, email: user.email)
    code = library_graph!(s.board, "code")
    library_graph!(s.board, "spec")
    # recent enough that the 7d / 30d windows include it
    recent = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -2 * 86_400, :second)
    card = shipped(s, recent)
    code_run!(card, at(1_000, recent))
    %{s: s, code: code, card: card, ref: Cards.ref(s.board, card), recent: recent, slug: s.board.slug}
  end

  # The board's flow `key`, its graph replaced by the default library's (roles, isolation included).
  defp library_graph!(board, key) do
    attrs = Enum.find(DefaultLibrary.all(), &(&1.key == key))

    Schemas.Flow
    |> Relay.Repo.get_by!(board_id: board.id, key: key)
    |> Schemas.Flow.changeset(Map.take(attrs, [:nodes, :edges, :isolation]))
    |> Relay.Repo.update!()
  end

  # Next up@0 → Code@100 → Review@5000 → (approved) Done@6000.
  defp shipped(s, base) do
    card = card_in(s.done, base)
    walk(card, [{s.next_up, 0}, {s.code, 100}, {s.review, 5_000}, {s.done, 6_000}], base)
    decided(card, :approved, s.review, s.done, at(6_000, base))
    card
  end

  # One Code run from `t0`: every line node once; acceptance fails → final_fix → precommit …
  # acceptance again (the REWIND), then resync → post. branch waited 150s for a runner.
  defp code_run!(card, t0) do
    run = insert(:run, card: card, flow_key: "code", status: :done, started_at: t0, finished_at: at(1_100, t0))
    sub = insert(:sub_task, card: card)

    execs =
      for {node, from, to, opts} <- [
            {"branch", 0, 10, []},
            {"implement", 10, 110, [sub_task_id: sub.id]},
            {"spec_review", 110, 130, [sub_task_id: sub.id]},
            {"quality_review", 130, 160, [sub_task_id: sub.id]},
            {"sync", 160, 170, []},
            {"precommit", 170, 230, []},
            {"browser", 230, 290, []},
            {"final_review", 290, 350, []},
            {"smoke", 350, 410, []},
            {"acceptance", 410, 440, [outcome: :failed]},
            {"final_fix", 440, 500, []},
            {"precommit", 500, 560, [visit: 2]},
            {"browser", 560, 620, [visit: 2]},
            {"final_review", 620, 680, [visit: 2]},
            {"smoke", 680, 740, [visit: 2]},
            {"acceptance", 740, 770, [visit: 2]},
            {"resync", 770, 780, []},
            {"reverify", 780, 840, []},
            {"rebrowser", 840, 900, []},
            {"merge", 900, 910, []},
            {"deploy", 910, 1_000, []},
            {"post", 1_000, 1_020, []}
          ] do
        insert(:node_execution,
          run: run,
          node: node,
          visit: Keyword.get(opts, :visit, 1),
          outcome: Keyword.get(opts, :outcome, :succeeded),
          sub_task_id: Keyword.get(opts, :sub_task_id),
          started_at: at(from, t0),
          finished_at: at(to, t0)
        )
      end

    insert(:node_job, node_execution: hd(execs), inserted_at: at(-150, t0), updated_at: at(-150, t0), claimed_at: t0)
    run
  end

  defp texts(view, selector, within) do
    view
    |> element(within)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "drilling in" do
    test "a level-1 flow box opens its level-2 map; the box keeps a Flow metrics link", ctx do
      {:ok, level1, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream")

      assert has_element?(
               level1,
               "a#vs-box-#{ctx.s.code.id}-metrics[href='/board/#{ctx.slug}/flows/code/metrics']",
               "Flow metrics →"
             )

      {:ok, view, _html} =
        level1 |> element("#vs-box-#{ctx.s.code.id}") |> render_click() |> follow_redirect(ctx.conn)

      assert has_element?(view, "#vs-flow-eyebrow", "LEVEL 2 · INSIDE ONE BOX")
      assert has_element?(view, "#vs-flow-title", "Code flow · as-is")
      assert has_element?(view, "#vs-flow-explainer", "21 nodes · 44 edges · exclusive isolation")
      assert has_element?(view, "#board-view-tab-value-stream[aria-current='page']")
      assert has_element?(view, "#vs-back[href='/board/#{ctx.slug}/value-stream']", "← Card stream")
    end
  end

  describe "the Code flow map" do
    test "matches the artboard's topology, roles from node_roles/1", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code")

      assert texts(view, ".vs-node-key", "#vs-flow-map") == @code_line ++ @fixes
      roles = Schemas.Flow.node_roles(ctx.code)

      assert texts(view, ".vs-role", "#vs-flow-map") ==
               Enum.map(@code_line ++ @fixes, &(roles |> Map.fetch!(&1) |> Atom.to_string() |> String.upcase()))

      for fix <- @fixes, do: assert(has_element?(view, "#vs-node-#{fix}.vs-node-fix"))
      assert has_element?(view, "#vs-node-precommit .vs-pass-strip")
    end

    test "draws the structural overlays", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code")

      assert has_element?(view, "#vs-foreach-loop", "foreach_remaining · next sub-task")
      assert has_element?(view, "#vs-verify-1", "VERIFY BLOCK ①")
      assert has_element?(view, "#vs-verify-2", "VERIFY BLOCK ② — byte-identical run commands")
      assert has_element?(view, "#vs-queue", "exclusive slot")
      assert has_element?(view, "#vs-queue", "2.5m")
      assert has_element?(view, "#vs-term-done", "done → Review")
      assert has_element?(view, "#vs-term-done", "1 of 1 run · 100%")
      assert has_element?(view, "#vs-term-park", "⏸ needs_input")
      assert has_element?(view, "#vs-park-note", "8 of the 21 nodes can park here")
      assert has_element?(view, "#vs-band-rework")
      assert has_element?(view, "#vs-flow-ladder", "TIME — each rung sits under the node it measures")
      assert has_element?(view, "#vs-flow-ladder-footnote")
      assert has_element?(view, "#vs-flow-legend", "thickness = minutes")
    end

    test "the rewind is sized and labelled from the card's real run", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code?card=#{ctx.ref}&scope=card")

      assert has_element?(
               view,
               "#vs-return-final_fix-precommit",
               "⟲ REWIND to precommit · 1 lap re-run every node between"
             )

      assert has_element?(view, "#vs-send-acceptance-final_fix", "×1")
      # final_fix 60s of rework + the 270s of re-checks it forced, over one run
      assert has_element?(view, "#vs-tile-rewind-value", "5.5m")
      assert has_element?(view, "#vs-tile-rewind-sub", "final_fix + the re-checks it forces")
    end

    test "tiles and the run lead-time bands render", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code")

      assert texts(view, ".vs-tile > span:first-child", "#vs-tiles") ==
               ["RUN WALL-CLOCK", "FLOW EFFICIENCY", "REWORK", "REWIND COST", "ROLLED 1ST-PASS", "SPEND / RUN"]

      assert has_element?(view, "#vs-band-process", "PROCESS TIME")
      assert has_element?(view, "#vs-band-wall", "RUN WALL-CLOCK")
      assert has_element?(view, "#vs-band-wall-rework")
      assert has_element?(view, "#vs-tile-run-wall-sub", "of the card")
      assert has_element?(view, "#vs-tile-first-pass-value", "0% / 100%")
    end
  end

  describe "params" do
    test "Last N resolves level 1's done cards; the window control patches the URL", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code")

      assert has_element?(view, "#vs-window-last.btn-active")
      assert has_element?(view, "#vs-subject", "The 1 Code run of the last 1 done card")

      view |> element("#vs-window-30d") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.slug}/value-stream/code?window=30d")
      assert has_element?(view, "#vs-window-30d.btn-active")
      assert has_element?(view, "#vs-subject", "The 1 Code run in the last 30d")
    end

    test "card and scope round-trip, and the back link keeps them", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code?card=#{ctx.ref}")

      assert has_element?(view, "#vs-scope-card.btn-active")
      refute has_element?(view, "#vs-window")
      assert has_element?(view, "#vs-subject", ctx.ref)
      assert has_element?(view, "#vs-back[href='/board/#{ctx.slug}/value-stream?card=#{ctx.ref}&scope=card']")

      view |> element("#vs-scope-flow") |> render_click()
      assert_patch(view, ~p"/board/#{ctx.slug}/value-stream/code?card=#{ctx.ref}&scope=flow")
      assert has_element?(view, "#vs-window-last.btn-active")
    end

    test "a level-1 drill carries card, scope and window", ctx do
      {:ok, level1, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream?window=7d")

      assert has_element?(
               level1,
               "a#vs-box-#{ctx.s.code.id}-metrics[href='/board/#{ctx.slug}/flows/code/metrics?window=7d']"
             )

      assert {:error, {:live_redirect, %{to: to}}} =
               level1 |> element("#vs-box-#{ctx.s.code.id}") |> render_click()

      assert to == "/board/#{ctx.slug}/value-stream/code?window=7d"
    end
  end

  describe "any flow, unknown flows, empty populations" do
    test "the Spec flow drills and degrades cleanly — one box, no frames, no loop", ctx do
      run = insert(:run, card: ctx.card, flow_key: "spec", status: :done)

      insert(:node_execution,
        run: run,
        node: "brainstorm",
        started_at: at(200, ctx.recent),
        finished_at: at(260, ctx.recent)
      )

      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/spec")

      assert has_element?(view, "#vs-flow-title", "Spec flow · as-is")
      assert texts(view, ".vs-node-key", "#vs-flow-map") == ["brainstorm"]
      refute has_element?(view, ".vs-verify")
      refute has_element?(view, "#vs-foreach-loop")
    end

    test "an unknown flow key redirects to level 1 with a flash naming it", ctx do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/nope")

      assert to == "/board/#{ctx.slug}/value-stream"
      assert flash["error"] =~ "nope"
    end

    test "a window with no runs, and a card with none, say so instead of a map", ctx do
      other = re_board()
      insert(:membership, board: other.board, user: ctx.user, email: ctx.user.email)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{other.board.slug}/value-stream/code?window=7d")

      assert has_element?(view, "#vs-empty", "No runs of Code in this window yet.")
      refute has_element?(view, "#vs-flow-map")

      idle = card_in(ctx.s.code, ctx.recent)
      idle_ref = Cards.ref(ctx.s.board, idle)
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code?card=#{idle_ref}")
      assert has_element?(view, "#vs-empty", "#{idle_ref} has no Code runs yet.")
    end
  end

  describe "realtime" do
    test "a finished run updates the numbers without a reload; other run events are ignored", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/board/#{ctx.slug}/value-stream/code")
      assert has_element?(view, "#vs-subject", "The 1 Code run of the last 1 done card")

      code_run!(ctx.card, at(2_000, ctx.recent))
      Relay.Runs.broadcast_run_changed(ctx.s.board.id, ctx.card.id)

      assert render(view) =~ "The 2 Code runs of the last 1 done card"

      send(view.pid, {:run_started, nil})
      assert render(view) =~ "The 2 Code runs of the last 1 done card"
    end
  end
end
