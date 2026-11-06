defmodule Hamaca.Runs.TrackTest do
  use Hamaca.DataCase, async: true

  import Hamaca.FanOutFixtures, only: [region_flow: 2]

  alias Hamaca.Flows
  alias Hamaca.Runs.Track
  alias Schemas.Flow.Edge
  alias Schemas.Flow.Node

  @after_keys ~w(sync precommit browser final_review smoke acceptance resync reverify rebrowser merge deploy post)
  # A run that reached smoke: the setup, the loop and the after zone up to smoke.
  @reached_smoke ~w(branch implement spec_review quality_review sync precommit browser final_review smoke)

  setup do
    user = insert(:user)
    {:ok, board} = Hamaca.Boards.create_board(user, %{name: unique_slug("track")})
    flow = Flows.get_flow(board, "code")
    %{board: board, flow: flow, zones: Track.zones(flow)}
  end

  describe "zones/1" do
    test "splits the seeded code flow's happy path into setup, loop and after (scenario 1)", %{zones: zones} do
      assert zones.setup == ["branch"]
      assert zones.loop == ["implement", "spec_review", "quality_review"]
      assert zones.after == @after_keys
      assert length(zones.after) == 12
      assert zones.foreach == "implement"
    end

    test "is nil for a flow with no foreach node (scenario 3)" do
      board = insert(:board)
      stage = insert(:stage, board: board, type: :work, category: :in_progress)
      assert Track.zones(region_flow(board, stage)) == nil

      mini_stage = insert(:stage, board: board, type: :work, category: :in_progress)

      {:ok, mini} =
        Flows.create_flow(board, %{
          key: "mini",
          isolation: :shared_clean,
          stage_id: mini_stage.id,
          nodes: [
            %{key: "a", type: :agent, run: "a"},
            %{key: "b", type: :agent, run: "b"},
            %{key: "fix", type: :agent, run: "fix"}
          ],
          edges: [
            %{from: "start", to: "a"},
            %{from: "a", to: "b", on: :succeeded},
            %{from: "b", to: "fix", on: :failed},
            %{from: "fix", to: "b", on: :succeeded},
            %{from: "b", to: "done", on: :succeeded}
          ]
        })

      assert Track.zones(mini) == nil
    end

    test "an off-path node fed from setup and after takes the latest zone (scenario 4)" do
      flow = %Schemas.Flow{
        nodes: [
          %Node{key: "s", type: :shell, run: "true"},
          %Node{key: "loop", type: :agent, run: "loop", foreach: "card.tasks"},
          %Node{key: "a", type: :shell, run: "true"},
          %Node{key: "fix", type: :agent, run: "fix"}
        ],
        edges: [
          %Edge{from: "start", to: "s"},
          %Edge{from: "s", to: "loop", on: :succeeded},
          %Edge{from: "loop", to: "loop", on: :succeeded, when: :foreach_remaining},
          %Edge{from: "loop", to: "a", on: :succeeded, when: :foreach_exhausted},
          %Edge{from: "s", to: "fix", on: :failed},
          %Edge{from: "a", to: "fix", on: :failed},
          %Edge{from: "fix", to: "a", on: :succeeded},
          %Edge{from: "a", to: "done", on: :succeeded}
        ]
      }

      zones = Track.zones(flow)

      assert zones.setup == ["s"]
      assert zones.loop == ["loop"]
      assert zones.after == ["a"]
      assert zones.off_path == %{"fix" => :after}
    end
  end

  describe "zone_of/2" do
    test "places each fix node in the zone that feeds it (scenario 2)", %{zones: zones} do
      assert Track.zone_of(zones, "fix_findings") == :loop

      for key <- ~w(final_fix sync_fix resync_fix github_fix) do
        assert Track.zone_of(zones, key) == :after, "#{key} should be :after"
      end

      assert Track.zone_of(zones, "nope") == nil
      assert Track.zone_of(zones, nil) == nil
    end
  end

  describe "build/4" do
    test "the first node is the setup zone (scenario 5)", %{zones: zones} do
      assert Track.build(zones, "branch", [], []) == %{
               zone: :setup,
               step: "branch",
               setup_total: 1,
               setup_reached: 1,
               after_total: 12,
               after_reached: 0,
               previous_node: nil
             }
    end

    test "the foreach head is building (scenario 6)", %{zones: zones} do
      track = Track.build(zones, "implement", ["branch", "implement"], ["implement", "branch"])

      assert %{zone: :loop, step: "building", previous_node: "branch"} = track
    end

    test "the loop's fix node is fixing review notes (scenario 7)", %{zones: zones} do
      track =
        Track.build(
          zones,
          "fix_findings",
          ["branch", "implement", "spec_review", "fix_findings"],
          ["fix_findings", "spec_review"]
        )

      assert %{zone: :loop, step: "fixing review notes", previous_node: "spec_review"} = track
    end

    test "a review after the loop's fix node is re-reviewing, otherwise reviewing (scenario 8)", %{zones: zones} do
      executed = ["branch", "implement", "spec_review", "fix_findings"]

      assert %{step: "re-reviewing", previous_node: "fix_findings"} =
               Track.build(zones, "spec_review", executed, ["fix_findings", "spec_review"])

      assert %{step: "re-reviewing", previous_node: "fix_findings"} =
               Track.build(zones, "spec_review", executed, ["spec_review", "fix_findings"])

      assert %{step: "reviewing", previous_node: "implement"} =
               Track.build(zones, "spec_review", executed, ["spec_review", "implement"])
    end

    test "an after-zone node names itself and counts its position (scenario 9)", %{zones: zones} do
      track =
        Track.build(
          zones,
          "precommit",
          ["branch", "implement", "spec_review", "quality_review", "sync", "precommit"],
          ["precommit", "sync"]
        )

      assert %{zone: :after, step: "precommit", after_reached: 2} = track
    end

    test "an after-zone fix node names what it fixes and never drains the bar (scenario 10)", %{zones: zones} do
      executed = @reached_smoke ++ ["final_fix"]

      assert %{zone: :after, step: "fixing smoke", after_reached: 5} =
               Track.build(zones, "final_fix", executed, ["final_fix", "smoke"])

      assert %{zone: :after, after_reached: 5} =
               Track.build(zones, "precommit", executed ++ ["precommit"], ["precommit", "final_fix"])
    end

    test "an after-zone fix node with no previous node is just fixing", %{zones: zones} do
      assert %{zone: :after, step: "fixing", previous_node: nil} = Track.build(zones, "final_fix", [], [])
    end

    test "a task added late goes back to building but keeps the after progress (scenario 11)", %{zones: zones} do
      assert %{zone: :loop, step: "building", after_reached: 5} =
               Track.build(zones, "implement", @reached_smoke, ["implement", "smoke"])
    end

    test "is nil with no zones or no current node (scenario 12)", %{zones: zones} do
      assert Track.build(nil, "implement", [], []) == nil
      assert Track.build(zones, nil, [], []) == nil
    end

    test "is nil for a current node outside every zone", %{zones: zones} do
      assert Track.build(zones, "nope", [], []) == nil
    end
  end

  describe "step_name/1" do
    test "humanizes a node key (scenario 13)" do
      assert Track.step_name("final_review") == "final review"
      assert Track.step_name("fly") == "fly"
      assert Track.step_name(nil) == ""
    end
  end

  describe "face/2" do
    # The RE board's Code flow: 13 after-zone steps, so the percentages are the mockup's own.
    defp track(zone, step, after_reached) do
      %{
        zone: zone,
        step: step,
        previous_node: nil,
        setup_total: 1,
        setup_reached: 1,
        after_total: 13,
        after_reached: after_reached
      }
    end

    defp face(track, tasks, current_node \\ "implement") do
      Track.face(%{track: track, flow_key: "code", current_node: current_node}, tasks)
    end

    defp task_states(cells), do: for({:task, state} <- cells, do: state)
    defp after_cell(cells), do: Enum.find_value(cells, fn {kind, value} -> kind == :after && value end)

    # Every bar: one striped/current cell, and never an `N/N tasks` label.
    defp assert_bar_invariants(%{cells: cells, label: label}) do
      active =
        Enum.count(cells, fn
          {:setup, :current} -> true
          {:task, :current} -> true
          {:after, %{striped?: true}} -> true
          _ -> false
        end)

      assert active == 1
      refute label =~ ~r/\d+\/\d+ tasks/
    end

    test "before the tasks: setup is current, every task pending (scenario 1)" do
      t = %{
        zone: :setup,
        step: "branch",
        setup_total: 1,
        setup_reached: 1,
        after_total: 13,
        after_reached: 0,
        previous_node: nil
      }

      face = Track.face(%{track: t, flow_key: "code", current_node: "branch"}, %{done: 0, total: 7})

      assert face.cells ==
               [{:setup, :current}] ++
                 List.duplicate({:task, :pending}, 7) ++
                 [{:after, %{fill_pct: 0.0, tail_pct: 7.7, striped?: false}}]

      assert face.label == "setup · branch · 7 tasks to go"
      assert_bar_invariants(face)
    end

    test "building task 3 of 7 (scenario 2)" do
      face = face(track(:loop, "building", 0), %{done: 2, total: 7})

      assert [{:setup, :done} | _] = face.cells
      assert task_states(face.cells) == [:done, :done, :current, :pending, :pending, :pending, :pending]
      assert after_cell(face.cells) == %{fill_pct: 0.0, tail_pct: 7.7, striped?: false}
      assert face.label == "task 3 of 7 · building"
      assert_bar_invariants(face)
    end

    test "fixing review notes keeps the task's cells (scenario 3)" do
      face = face(track(:loop, "fixing review notes", 0), %{done: 2, total: 7}, "fix_findings")

      assert [{:setup, :done} | _] = face.cells
      assert task_states(face.cells) == [:done, :done, :current, :pending, :pending, :pending, :pending]
      assert after_cell(face.cells) == %{fill_pct: 0.0, tail_pct: 7.7, striped?: false}
      assert face.label == "task 3 of 7 · fixing review notes"
      assert_bar_invariants(face)
    end

    test "re-reviewing (scenario 4)" do
      face = face(track(:loop, "re-reviewing", 0), %{done: 2, total: 7}, "spec_review")

      assert task_states(face.cells) == [:done, :done, :current, :pending, :pending, :pending, :pending]
      assert face.label == "task 3 of 7 · re-reviewing"
      assert_bar_invariants(face)
    end

    test "the last task (scenario 5)" do
      face = face(track(:loop, "building", 0), %{done: 6, total: 7})

      assert task_states(face.cells) == List.duplicate(:done, 6) ++ [:current]
      assert after_cell(face.cells) == %{fill_pct: 0.0, tail_pct: 7.7, striped?: false}
      assert face.label == "task 7 of 7 · building"
      assert_bar_invariants(face)
    end

    test "after the tasks, precommit: the after track is striped (scenario 6)" do
      face = face(track(:after, "precommit", 2), %{done: 7, total: 7}, "precommit")

      assert [{:setup, :done} | _] = face.cells
      assert task_states(face.cells) == List.duplicate(:done, 7)
      assert after_cell(face.cells) == %{fill_pct: 15.4, tail_pct: 7.7, striped?: true}
      assert face.label == "tasks done · precommit"
      assert_bar_invariants(face)
    end

    test "fixing smoke keeps the after fill reached (scenario 7)" do
      face = face(track(:after, "fixing smoke", 6), %{done: 7, total: 7}, "final_fix")

      assert %{fill_pct: 46.2, striped?: true} = after_cell(face.cells)
      assert after_cell(face.cells).fill_pct >= 15.4
      assert face.label == "tasks done · fixing smoke"
      assert_bar_invariants(face)
    end

    test "a task added after the tasks pauses the after track (scenario 8)" do
      face = face(track(:loop, "building", 6), %{done: 7, total: 8})

      assert task_states(face.cells) == List.duplicate(:done, 7) ++ [:current]
      assert after_cell(face.cells) == %{fill_pct: 46.2, tail_pct: 7.7, striped?: false}
      assert face.label == "task 8 of 8 · new · building"
      assert_bar_invariants(face)
    end

    test "back to the checks after the new task (scenario 9)" do
      face = face(track(:after, "precommit", 6), %{done: 8, total: 8}, "precommit")

      assert task_states(face.cells) == List.duplicate(:done, 8)
      assert %{fill_pct: 46.2, striped?: true} = after_cell(face.cells)
      assert face.label == "tasks done · precommit"
      assert_bar_invariants(face)
    end

    test "landing fills the after track to 100.0 on its last step (scenario 10)" do
      face = face(track(:after, "await ci", 12), %{done: 7, total: 7}, "await_ci")

      assert %{fill_pct: 92.3, striped?: true} = after_cell(face.cells)
      assert face.label == "tasks done · await ci"
      assert_bar_invariants(face)

      last = face(track(:after, "await ci", 13), %{done: 7, total: 7}, "await_ci")
      assert %{fill_pct: 100.0, striped?: true} = after_cell(last.cells)
      assert_bar_invariants(last)
    end

    test "no tasks or no track: no bar, the flow and node as the label (scenario 11)" do
      assert Track.face(%{track: nil, flow_key: "deploy", current_node: "fly"}, nil) ==
               %{cells: [], label: "deploy · fly"}

      assert Track.face(
               %{track: track(:loop, "building", 0), flow_key: "deploy", current_node: "fly"},
               %{done: 0, total: 0}
             ) == %{cells: [], label: "deploy · fly"}

      assert Track.face(%{flow_key: "deploy", current_node: "fly"}, %{done: 1, total: 3}) ==
               %{cells: [], label: "deploy · fly"}
    end

    test "a flow with an empty after zone gives an empty after track, not a crash" do
      face = face(%{track(:loop, "building", 0) | after_total: 0}, %{done: 0, total: 2})

      assert after_cell(face.cells) == %{fill_pct: 0.0, tail_pct: 0.0, striped?: false}
    end

    test "a done count past the total keeps the last task current (scenario 12)" do
      face = face(track(:loop, "reviewing", 0), %{done: 7, total: 7}, "quality_review")

      assert task_states(face.cells) == List.duplicate(:done, 6) ++ [:current]
      assert face.label == "task 7 of 7 · reviewing"
      assert_bar_invariants(face)
    end
  end
end
