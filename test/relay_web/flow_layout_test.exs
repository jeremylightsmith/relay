defmodule RelayWeb.FlowLayoutTest do
  use ExUnit.Case, async: true

  alias RelayWeb.FlowLayout

  # atomized DefaultLibrary Code flow
  defp code_flow do
    flow = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
    {flow.nodes, flow.edges}
  end

  # invert the layout's centering to recover {row, col} from a top-left position.
  # These mirror the module's constants (@origin_x/@origin_y/@row_h/@col_w/@node_w).
  @origin_x 8
  @origin_y 44
  @row_h 124
  @col_w 270
  @node_w 150
  defp row({_x, y}), do: div(y - @origin_y, @row_h)

  defp col({x, _y}, type) do
    {w, _h} = FlowLayout.node_size(type)
    center = x + div(w, 2)
    div(center - @origin_x - div(@node_w, 2), @col_w)
  end

  defp overlap?({l1, h1}, {l2, h2}), do: l1 <= h2 and l2 <= h1

  describe "vertical spine placement" do
    test "spine nodes occupy consecutive rows in a single column, in spine order" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)

      # spine = branch → implement → ... following :succeeded edges, continuing
      # through quality_review's foreach_exhausted edge rather than looping back via its
      # foreach_remaining edge (RLY-192 inserts `sync` immediately before `precommit`, and
      # `resync`/`reverify` immediately before `merge`; their `sync_fix`/`resync_fix` partners
      # are off-spine, side-column nodes like `final_fix`).
      spine =
        ~w(branch implement spec_review quality_review sync precommit final_review smoke acceptance post resync reverify merge)

      types = Map.new(nodes, &{&1.key, &1.type})

      for {k, i} <- Enum.with_index(spine) do
        assert row(pos[k]) == i
        assert col(pos[k], types[k]) == 0
      end
    end

    test "a foreach head's double :succeeded edge still continues the spine forward" do
      nodes = [%{key: "head", type: :agent, foreach: "card.sub_tasks"}, %{key: "tail", type: :gate}]

      edges = [
        %{from: "start", to: "head", on: nil},
        %{from: "head", to: "head", on: :succeeded, when: :foreach_remaining},
        %{from: "head", to: "tail", on: :succeeded, when: :foreach_exhausted},
        %{from: "tail", to: "done", on: :succeeded}
      ]

      %{positions: pos} = FlowLayout.layout(nodes, edges)
      assert row(pos["head"]) == 0
      assert row(pos["tail"]) == 1
      assert col(pos["head"], :agent) == 0
      assert col(pos["tail"], :gate) == 0
    end
  end

  describe "side node placement" do
    test "a fix node lands in the side column on its partner's row" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)

      assert row(pos["final_fix"]) == row(pos["precommit"])
      assert col(pos["final_fix"], :agent) == 1
      assert row(pos["smoke_fix"]) == row(pos["smoke"])
      assert col(pos["smoke_fix"], :agent) == 1
      assert row(pos["acceptance_fix"]) == row(pos["acceptance"])
      assert col(pos["acceptance_fix"], :agent) == 1
    end

    test "two side nodes contending for one cell slide to distinct columns on the same row" do
      nodes = [%{key: "r", type: :agent}, %{key: "f1", type: :agent}, %{key: "f2", type: :agent}]

      edges = [
        %{from: "start", to: "r", on: nil},
        %{from: "r", to: "done", on: :succeeded},
        %{from: "r", to: "f1", on: :failed, max_loops: 2},
        %{from: "r", to: "f2", on: :failed, max_loops: 2}
      ]

      %{positions: pos} = FlowLayout.layout(nodes, edges)
      assert row(pos["f1"]) == row(pos["r"])
      assert row(pos["f2"]) == row(pos["r"])
      refute col(pos["f1"], :agent) == col(pos["f2"], :agent)
    end

    test "unreachable nodes park below everything, in the side column, deterministically" do
      nodes = [%{key: "a", type: :agent}, %{key: "b", type: :agent}, %{key: "orphan", type: :shell}]
      edges = [%{from: "start", to: "a", on: nil}, %{from: "a", to: "done", on: :succeeded}]

      %{positions: pos} = FlowLayout.layout(nodes, edges)
      assert row(pos["orphan"]) > row(pos["a"])
      assert col(pos["orphan"], :shell) == 1
    end

    # RLY-186 acceptance #3: the "failed · max N" / "succeeded" labels on the short spine↔fix
    # hops used to be centred in a ~35px gap between two opaque node boxes and were painted over
    # (only fragments like "…ed · m…" rendered). The side column must sit far enough from the
    # spine that the widest side label (~92px) fits fully inside the gap between the two boxes.
    test "each spine reviewer sits far enough from its fix node for the edge label to fit" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)
      types = Map.new(nodes, &{&1.key, &1.type})

      # widest side label ("failed · max 2") renders ~92px; require room with margin.
      label_room = 100

      for {reviewer, fix} <- [
            {"precommit", "final_fix"},
            {"smoke", "smoke_fix"},
            {"acceptance", "acceptance_fix"}
          ] do
        {rx, _ry} = pos[reviewer]
        {rw, _rh} = FlowLayout.node_size(types[reviewer])
        {fx, _fy} = pos[fix]
        gap = fx - (rx + rw)

        assert gap >= label_room,
               "#{reviewer}→#{fix} gap is #{gap}px, too tight for the edge label (need >= #{label_room})"
      end
    end
  end

  describe "back-edge lane assignment" do
    test "nested back-edges get distinct lanes, the longest jump outermost" do
      nodes = for i <- 0..3, do: %{key: "n#{i}", type: :agent}

      edges = [
        %{from: "start", to: "n0", on: nil},
        %{from: "n0", to: "n1", on: :succeeded},
        %{from: "n1", to: "n2", on: :succeeded},
        %{from: "n2", to: "n3", on: :succeeded},
        %{from: "n3", to: "done", on: :succeeded},
        %{from: "n2", to: "n1", on: :failed, max_loops: 2},
        %{from: "n3", to: "n1", on: :failed, max_loops: 2}
      ]

      %{routes: routes} = FlowLayout.layout(nodes, edges)
      short = routes[5]
      long = routes[6]

      assert short.kind == :gutter
      assert long.kind == :gutter
      assert short.lane == 0
      assert long.lane > short.lane
    end

    test "row-disjoint back-edges share a lane" do
      nodes = for i <- 0..4, do: %{key: "n#{i}", type: :agent}

      edges = [
        %{from: "start", to: "n0", on: nil},
        %{from: "n0", to: "n1", on: :succeeded},
        %{from: "n1", to: "n2", on: :succeeded},
        %{from: "n2", to: "n3", on: :succeeded},
        %{from: "n3", to: "n4", on: :succeeded},
        %{from: "n4", to: "done", on: :succeeded},
        %{from: "n2", to: "n1", on: :failed, max_loops: 2},
        %{from: "n4", to: "n3", on: :failed, max_loops: 2}
      ]

      %{routes: routes} = FlowLayout.layout(nodes, edges)
      assert routes[6].lane == 0
      assert routes[7].lane == 0
    end

    test "lane assignment is stable across repeated calls" do
      {nodes, edges} = code_flow()
      assert FlowLayout.layout(nodes, edges).routes == FlowLayout.layout(nodes, edges).routes
    end
  end

  describe "route kinds" do
    test "start/done edges classify as :enter/:exit; forward step is :drop; side loop is side_out/side_back" do
      {nodes, edges} = code_flow()
      %{routes: routes} = FlowLayout.layout(nodes, edges)
      idx = fn from, to -> Enum.find_index(edges, &(&1.from == from and &1.to == to)) end

      assert routes[idx.("start", "branch")].kind == :enter
      assert routes[idx.("merge", "done")].kind == :exit
      assert routes[idx.("branch", "implement")].kind == :drop
      assert routes[idx.("precommit", "final_fix")].kind == :side_out
      assert routes[idx.("final_fix", "precommit")].kind == :side_back
      assert routes[idx.("spec_review", "implement")].kind == :gutter
    end

    test "an edge to the needs_input park sentinel classifies as :exit, like done (RLY-194)" do
      {nodes, edges} = code_flow()
      %{routes: routes} = FlowLayout.layout(nodes, edges)
      idx = fn from, to -> Enum.find_index(edges, &(&1.from == from and &1.to == to)) end

      assert routes[idx.("implement", "needs_input")].kind == :exit
    end

    test "a bare start → done edge (a zero-node flow) classifies as :enter_exit" do
      %{routes: routes, positions: positions} =
        FlowLayout.layout([], [%{from: "start", to: "done", on: nil}])

      assert positions == %{}
      assert routes[0].kind == :enter_exit
    end
  end

  describe "the default Code flow lays out cleanly" do
    test "no two nodes share a grid cell" do
      {nodes, edges} = code_flow()
      %{positions: pos} = FlowLayout.layout(nodes, edges)
      cells = for %{key: k, type: t} <- nodes, do: {row(pos[k]), col(pos[k], t)}
      assert length(cells) == length(Enum.uniq(cells))
    end

    test "no two back-edges share both a lane and an overlapping row range" do
      {nodes, edges} = code_flow()
      %{positions: pos, routes: routes} = FlowLayout.layout(nodes, edges)

      gutters =
        for {e, i} <- Enum.with_index(edges), routes[i].kind == :gutter do
          fr = row(pos[e.from])
          tr = row(pos[e.to])
          {routes[i].lane, {min(fr, tr), max(fr, tr)}}
        end

      by_lane = Enum.group_by(gutters, &elem(&1, 0), &elem(&1, 1))

      for {_lane, ivs} <- by_lane do
        pairs = for {a, i} <- Enum.with_index(ivs), {b, j} <- Enum.with_index(ivs), i < j, do: {a, b}
        for {a, b} <- pairs, do: refute(overlap?(a, b))
      end
    end
  end
end
