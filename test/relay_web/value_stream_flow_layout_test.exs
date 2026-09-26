defmodule RelayWeb.ValueStreamFlowLayoutTest do
  use ExUnit.Case, async: true

  alias Relay.Flows.DefaultLibrary
  alias RelayWeb.ValueStreamFlowLayout, as: FL
  alias Schemas.Flow.Edge

  @code_line ~w(branch implement spec_review quality_review sync precommit browser final_review smoke acceptance resync reverify rebrowser merge deploy post)

  defp library_flow(key) do
    attrs = Enum.find(DefaultLibrary.all(), &(&1.key == key))

    %Schemas.Flow{board_id: 1}
    |> Schemas.Flow.changeset(attrs)
    |> Ecto.Changeset.apply_action!(:build)
  end

  defp code, do: FL.layout(library_flow("code"))

  defp row(key, attrs) do
    Map.merge(
      %{
        node_key: key,
        runs: 1,
        work_total: nil,
        rework_total: nil,
        wait_total: nil,
        cost_total: nil,
        rewind_total: nil,
        verdict_split: %{}
      },
      Map.new(attrs)
    )
  end

  defp stream do
    %{
      runs: 2,
      nodes: [
        row("implement", runs: 4, work_total: 1_200, rework_total: 0, wait_total: 120, cost_total: Decimal.new("2.00")),
        row("precommit", runs: 3, work_total: 480, rework_total: 240, verdict_split: %{succeeded: 2, failed: 1}),
        row("final_fix", runs: 1, work_total: 0, rework_total: 360, rewind_total: 240, cost_total: Decimal.new("0.90"))
      ],
      sends: [
        %{from: "precommit", to: "final_fix", returns_to: "precommit", laps: 1, to_secs: 360, rewind_secs: 240, secs: 600}
      ],
      foreach: %{copies: 4, clean_copies: 3},
      first_pass_runs: 1,
      done_runs: 2,
      parked_runs: 1,
      queue_wait: %{mean_secs: 150, jobs: 2}
    }
  end

  describe "layout/1 on the default Code flow — the artboard's topology, derived" do
    test "the line is the succeeded walk, foreach_exhausted preferred; boxes W 150 × H 138 from x 76, gap 48, y 340" do
      layout = code()

      assert layout.line == @code_line
      assert layout.node_count == 21
      assert layout.edge_count == 44

      for {key, i} <- Enum.with_index(@code_line) do
        assert layout.pos[key] == %{x: 76 + i * 198, y: 340, w: 150, h: 138}
      end

      assert layout.geometry.line_end == 76 + 15 * 198 + 150
      assert layout.geometry.mid_y == 409
      assert layout.geometry.t_y0 == 530
      assert layout.geometry.t_y1 == 588
      assert layout.geometry.term_x == layout.geometry.line_end + 58
      assert length(FL.connectors(layout)) == 15
    end

    test "the five fixes sit above the line at the mean slot of the nodes that fail into them" do
      layout = code()

      assert layout.fixes == ~w(fix_findings sync_fix final_fix resync_fix github_fix)

      assert Map.take(layout.slots, layout.fixes) == %{
               "fix_findings" => 2.5,
               "sync_fix" => 4.0,
               "final_fix" => 7.0,
               "resync_fix" => 11.0,
               "github_fix" => 14.0
             }

      assert layout.pos["final_fix"] == %{x: 76 + 7.0 * 198 + 7.0, y: 188, w: 136, h: 92}
      assert Enum.all?(layout.nodes, &(&1.fix? == &1.key in layout.fixes))
      assert Enum.find(layout.nodes, &(&1.key == "precommit")).type == "gate"
    end

    test "exactly two verify blocks: sync/precommit/browser and its byte-identical repeat" do
      assert [first, second] = code().verify_blocks

      assert %{id: "vs-verify-1", keys: ~w(sync precommit browser), label: "VERIFY BLOCK ①"} = first

      assert %{
               id: "vs-verify-2",
               keys: ~w(resync reverify rebrowser),
               label: "VERIFY BLOCK ② — byte-identical run commands"
             } = second

      sync_x = 76 + 4 * 198
      assert %{x: x, y: 324, h: 170, label_x: lx, label_y: 508} = first
      assert x == sync_x - 14
      assert lx == sync_x - 10
      assert first.w == 2 * 198 + 150 + 28
    end

    test "the foreach loop runs quality_review → implement; 8 nodes can park" do
      layout = code()

      assert %{from: "quality_review", to: "implement", label: "foreach_remaining · next sub-task · planned, not waste"} =
               layout.foreach_loop

      assert Enum.sort(layout.parkable) ==
               Enum.sort(~w(implement fix_findings sync_fix final_fix resync_fix github_fix post branch))
    end

    test "only final_fix → precommit is a REWIND" do
      layout = code()

      assert for(%{rewind: true} = r <- layout.reentries, do: {r.fix, r.to}) == [{"final_fix", "precommit"}]

      assert Enum.sort(for r <- layout.reentries, do: {r.fix, r.to}) ==
               Enum.sort([
                 {"fix_findings", "spec_review"},
                 {"sync_fix", "precommit"},
                 {"final_fix", "precommit"},
                 {"resync_fix", "reverify"},
                 {"github_fix", "resync"}
               ])

      refute FL.rewind?(layout, "github_fix", "resync")
      refute FL.rewind?(layout, "nope", "precommit")
    end
  end

  describe "layout/1 degrades cleanly" do
    test "a flow with no fixes, no foreach and no repeats draws none of them" do
      flow = %Schemas.Flow{
        board_id: 1,
        key: "tiny",
        isolation: :shared_clean,
        nodes: [
          %Schemas.Flow.Node{key: "a", type: :agent, run: "/a"},
          %Schemas.Flow.Node{key: "b", type: :shell, run: "true"},
          %Schemas.Flow.Node{key: "orphan", type: :shell, run: "echo"}
        ],
        edges: [
          %Edge{from: "start", to: "a"},
          %Edge{from: "a", to: "b", on: :succeeded},
          %Edge{from: "b", to: "done", on: :succeeded}
        ]
      }

      layout = FL.layout(flow)

      assert layout.line == ~w(a b orphan)
      assert layout.fixes == []
      assert layout.verify_blocks == []
      assert layout.foreach_loop == nil
      assert layout.parkable == []
      assert layout.reentries == []
      assert FL.arcs(layout, []) == []
    end

    test "the default Spec flow is one box" do
      layout = FL.layout(library_flow("spec"))
      assert layout.line == ["brainstorm"]
      assert layout.verify_blocks == []
      assert layout.foreach_loop == nil
    end
  end

  describe "arcs/2 — sized by minutes, labelled by laps" do
    test "check → fix, the merge → resync line send, the REWIND and a short re-entry" do
      sends = [
        %{
          from: "acceptance",
          to: "final_fix",
          returns_to: "precommit",
          laps: 2,
          to_secs: 600,
          rewind_secs: 900,
          secs: 1_500
        },
        %{
          from: "spec_review",
          to: "fix_findings",
          returns_to: "spec_review",
          laps: 3,
          to_secs: 300,
          rewind_secs: 0,
          secs: 300
        },
        %{from: "merge", to: "resync", returns_to: "merge", laps: 1, to_secs: 60, rewind_secs: 0, secs: 60},
        %{from: "smoke", to: "gone_node", returns_to: nil, laps: 4, to_secs: 1, rewind_secs: 0, secs: 1}
      ]

      arcs = Map.new(FL.arcs(code(), sends), &{&1.id, &1})

      assert arcs |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(vs-send-acceptance-final_fix vs-send-spec_review-fix_findings vs-send-merge-resync
                            vs-return-final_fix-precommit vs-return-fix_findings-spec_review))

      assert %{kind: :send, label: "×2", width: 15.0} = arcs["vs-send-acceptance-final_fix"]
      assert %{kind: :send, label: "merge failed · ×1 → resync", width: 2.5} = arcs["vs-send-merge-resync"]

      assert %{kind: :return, rewind: true, size: 11.5, label: "⟲ REWIND to precommit · 2 laps re-run every node between"} =
               arcs["vs-return-final_fix-precommit"]

      assert %{kind: :return, rewind: false, label: "→ spec_review · ×3", width: 4.6} =
               arcs["vs-return-fix_findings-spec_review"]

      assert arcs["vs-send-acceptance-final_fix"].arrow =~ ","
      assert arcs["vs-send-acceptance-final_fix"].d =~ ~r/^M1933\.0,340 C/
    end

    test "one lap reads singular" do
      sends = [%{from: "smoke", to: "final_fix", returns_to: "precommit", laps: 1, to_secs: 1, rewind_secs: 0, secs: 1}]
      assert [_send, %{label: "⟲ REWIND to precommit · 1 lap re-run every node between"}] = FL.arcs(code(), sends)
    end
  end

  describe "per-run presentation" do
    test "node boxes: visits, rows by role and the check's pass strip" do
      boxes = Map.new(FL.node_boxes(code(), stream()), &{&1.key, &1})

      assert %{visits: "×2.00", visits_hot: true, pass_pct: nil, role: :do} = boxes["implement"]

      assert Enum.map(boxes["implement"].rows, &{&1.k, &1.v}) == [
               {"Work", "10.0m"},
               {"Wait", "1.0m"},
               {"$ / run", "$1.00"}
             ]

      assert %{visits: "×1.50", visits_hot: true, pass_pct: 67} = boxes["precommit"]
      assert Enum.map(boxes["precommit"].rows, &{&1.k, &1.v}) == [{"Work", "4.0m"}, {"Pass", "67%"}, {"$ / run", "—"}]
      assert Enum.at(boxes["precommit"].rows, 1).tone == :error

      assert %{visits: "×0.50", visits_hot: false, pass_pct: nil} = boxes["final_fix"]
      assert Enum.map(boxes["final_fix"].rows, &{&1.k, &1.v}) == [{"Rework", "3.0m"}, {"Laps", "1"}, {"$ / lap", "$0.90"}]

      assert %{visits: "", pass_pct: nil} = boxes["spec_review"]
      assert Enum.map(boxes["spec_review"].rows, & &1.v) == ["—", "—", "—"]
    end

    test "ladder items: one rung per line node, a fix's rework folded into the check that sends it most" do
      items = FL.ladder_items(code(), stream())

      assert length(items) == 16
      assert %{wait: 60.0, work: 600.0, rework: +0.0, color: "success"} = Enum.at(items, 1)
      assert %{wait: +0.0, work: 240.0, rework: 300.0, color: "info", x: 1066, w: 150} = Enum.at(items, 5)
    end

    test "summary and bands: value-add, checking, rework and wait per run" do
      s = FL.summary(code(), stream())

      assert %{value_add: 600.0, checking: 240.0, rework: 300.0, wait: 60.0, process: 840.0, wall: 1_200.0} = s
      assert s.rewind_fixes == ["final_fix"]
      assert s.rewind_cost == 300.0
      assert s.first_pass_run == 0.5
      assert s.first_pass_task == 0.75
      assert Decimal.equal?(s.spend, "1.45")
      assert Decimal.equal?(s.rework_spend, "0.45")

      assert [process, wall] = FL.bands(s)
      assert %{id: "vs-band-process", k: "PROCESS TIME", total: "14.0m"} = process
      assert Enum.map(process.segments, & &1.label) == ["value-add 10.0m", "checking 4.0m"]
      assert %{id: "vs-band-wall", k: "RUN WALL-CLOCK", total: "20.0m"} = wall
      assert Enum.map(wall.segments, & &1.key) == [:value_add, :checking, :rework, :wait]
      assert Enum.map(wall.segments, & &1.label) == ["10.0m", "4.0m", "rework 5.0m", "wait 1.0m"]
    end

    test "queue, terminals and the explainer" do
      layout = code()

      assert FL.queue(:exclusive, %{mean_secs: 150, jobs: 2}) == %{
               lead: "queued for the",
               slot: "exclusive slot",
               value: "2.5m"
             }

      assert FL.queue(:shared_clean, %{mean_secs: nil, jobs: 0}) == %{
               lead: "queued for a",
               slot: "shared slot",
               value: "—"
             }

      assert FL.terminals(layout, stream(), "Review") == %{
               done_label: "done → Review",
               done_sub: "2 of 2 runs · 100%",
               park_sub: "1 run · the baton passes to a human",
               park_note: "8 of the 21 nodes can park here",
               feeder_x: 76 + 40
             }

      assert FL.terminals(layout, %{stream() | parked_runs: 3}, nil).done_label == "done"
      assert FL.explainer(layout, :exclusive) == "21 nodes · 44 edges · exclusive isolation"
    end

    test "fmt_minutes reads N.Nm under an hour, Hh MMm above" do
      assert FL.fmt_minutes(nil) == "—"
      assert FL.fmt_minutes(90) == "1.5m"
      assert FL.fmt_minutes(3_600) == "1h 00m"
      assert FL.fmt_minutes(8_040) == "2h 14m"
    end
  end
end
