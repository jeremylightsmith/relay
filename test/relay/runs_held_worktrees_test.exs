defmodule Relay.RunsHeldWorktreesTest do
  use Relay.DataCase, async: true

  alias Relay.Runs

  setup do
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "RE337 holdings board"})
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    %{board: board, stage: stage, now: DateTime.truncate(DateTime.utc_now(), :second)}
  end

  defp held(ref, state), do: %{"ref" => ref, "state" => state}
  defp ago(now, s), do: DateTime.add(now, -s, :second)

  # A card whose active run parked `age_s` ago on needs-input (its last node finished then).
  defp parked_card(stage, now, age_s, title \\ "Parked on a human") do
    card = insert(:card, stage: stage, title: title)
    run = insert(:run, card: card, status: :parked, parked_reason: :needs_input)
    insert(:node_execution, run: run, started_at: ago(now, age_s + 60), finished_at: ago(now, age_s))
    %{card: card, run: run}
  end

  defp running_card(stage, now) do
    card = insert(:card, stage: stage, title: "Working")
    run = insert(:run, card: card, status: :running)
    insert(:node_execution, run: run, started_at: ago(now, 30), finished_at: nil)
    %{card: card, run: run}
  end

  # A queued, unclaimed exclusive node-job on a running run, inserted `age_s` ago.
  defp queued_exclusive(stage, now, age_s) do
    card = insert(:card, stage: stage, title: "Waiting for a slot")
    run = insert(:run, card: card, status: :running)
    ne = insert(:node_execution, run: run, inserted_at: ago(now, age_s))

    insert(:node_job,
      node_execution: ne,
      state: :queued,
      runner_name: nil,
      claimed_at: nil,
      inserted_at: ago(now, age_s),
      payload: %{"isolation" => "exclusive"}
    )

    card
  end

  defp holdings(board, now, name) do
    board |> Runs.list_runner_status(now) |> Enum.find(&(&1.name == name)) |> Map.fetch!(:holdings)
  end

  describe "list_runner_status/2 holdings" do
    test "a bound holding carries its card, parked run, age and actions", %{board: board, stage: stage, now: now} do
      %{card: card, run: run} = parked_card(stage, now, 2 * 86_400)
      ref = Relay.Cards.ref(board, card)
      insert(:runner, board: board, name: "mac-a", held: [held(ref, "bound")])

      assert [h] = holdings(board, now, "mac-a")
      assert h.ref == ref
      assert h.title == "Parked on a human"
      assert h.state == "bound"
      assert h.run == %{id: run.id, status: :parked, parked_reason: :needs_input}
      assert h.held_s == 2 * 86_400
      assert h.release_requested == false
      assert h.release == :enabled
      assert h.cancellable == true
    end

    test "a pending request reads :releasing", %{board: board, stage: stage, now: now} do
      %{card: card} = parked_card(stage, now, 60)
      ref = Relay.Cards.ref(board, card)
      insert(:runner, board: board, name: "mac-a", held: [held(ref, "bound")], release_requests: [ref])

      assert [%{release_requested: true, release: :releasing}] = holdings(board, now, "mac-a")
    end

    test "running / talk are disabled with a reason; retained is hidden and not cancellable",
         %{board: board, stage: stage, now: now} do
      %{card: running} = running_card(stage, now)
      talk = insert(:card, stage: stage, title: "Talking")
      retained = insert(:card, stage: stage, title: "Failed earlier")
      insert(:run, card: retained, status: :failed)

      insert(:runner,
        board: board,
        name: "mac-a",
        held: [
          held(Relay.Cards.ref(board, running), "running"),
          held(Relay.Cards.ref(board, talk), "talk"),
          held(Relay.Cards.ref(board, retained), "retained")
        ]
      )

      by_state = board |> holdings(now, "mac-a") |> Map.new(&{&1.state, &1})

      assert by_state["running"].release == {:disabled, "a job is running in this worktree"}
      assert by_state["running"].cancellable
      assert by_state["talk"].release == {:disabled, "a talk session is attached"}
      refute by_state["talk"].cancellable
      assert by_state["retained"].release == :hidden
      refute by_state["retained"].cancellable
      assert by_state["retained"].run == nil
    end

    test "bound holdings come first, oldest first", %{board: board, stage: stage, now: now} do
      %{card: young} = parked_card(stage, now, 600, "young")
      %{card: old} = parked_card(stage, now, 7200, "old")
      %{card: working} = running_card(stage, now)

      insert(:runner,
        board: board,
        name: "mac-a",
        held: [
          held(Relay.Cards.ref(board, working), "running"),
          held(Relay.Cards.ref(board, young), "bound"),
          held(Relay.Cards.ref(board, old), "bound")
        ]
      )

      assert ["old", "young", "Working"] == board |> holdings(now, "mac-a") |> Enum.map(& &1.title)
    end

    test "an unknown ref still renders, with no title and no run", %{board: board, now: now} do
      insert(:runner, board: board, name: "mac-a", held: [held("RLY999999", "bound")])

      assert [%{ref: "RLY999999", title: nil, run: nil, cancellable: false}] = holdings(board, now, "mac-a")
    end

    test "a runner holding nothing has no holdings", %{board: board, now: now} do
      insert(:runner, board: board, name: "mac-a", held: [])
      assert holdings(board, now, "mac-a") == []
    end
  end

  describe "starvation/2" do
    test "fires when a queued exclusive job waited past grace and every held slot is bound",
         %{board: board, stage: stage, now: now} do
      %{card: a} = parked_card(stage, now, 3600, "Card A")
      ref_a = Relay.Cards.ref(board, a)
      b = queued_exclusive(stage, now, 600)

      insert(:runner, board: board, name: "mac-a", capacity: %{"exclusive" => 1}, held: [held(ref_a, "bound")])

      assert %{waiting: [waiting], holders: [holder]} = Runs.starvation(board, now)
      assert waiting.ref == Relay.Cards.ref(board, b)
      assert waiting.queued_s == 600
      assert holder.runner == "mac-a"
      assert holder.ref == ref_a
      assert holder.title == "Card A"
      assert holder.run_status == :parked
      assert holder.parked_reason == :needs_input
      assert holder.held_s == 3600
    end

    test "no verdict inside the awaiting-slot grace window", %{board: board, stage: stage, now: now} do
      %{card: a} = parked_card(stage, now, 3600)
      queued_exclusive(stage, now, 60)

      insert(:runner,
        board: board,
        name: "mac-a",
        capacity: %{"exclusive" => 1},
        held: [held(Relay.Cards.ref(board, a), "bound")]
      )

      assert Runs.starvation(board, now) == nil
    end

    test "no verdict while a runner has a free exclusive slot", %{board: board, stage: stage, now: now} do
      %{card: a} = parked_card(stage, now, 3600)
      queued_exclusive(stage, now, 600)

      insert(:runner,
        board: board,
        name: "mac-a",
        capacity: %{"exclusive" => 2},
        held: [held(Relay.Cards.ref(board, a), "bound")]
      )

      assert Runs.starvation(board, now) == nil
    end

    test "no verdict in the mixed case — a running holding will free a slot on its own",
         %{board: board, stage: stage, now: now} do
      %{card: a} = parked_card(stage, now, 3600)
      %{card: w} = running_card(stage, now)
      queued_exclusive(stage, now, 600)

      insert(:runner,
        board: board,
        name: "mac-a",
        capacity: %{"exclusive" => 2},
        held: [held(Relay.Cards.ref(board, a), "bound"), held(Relay.Cards.ref(board, w), "running")]
      )

      assert Runs.starvation(board, now) == nil
    end

    test "no verdict when nothing exclusive is queued", %{board: board, stage: stage, now: now} do
      %{card: a} = parked_card(stage, now, 3600)

      insert(:runner,
        board: board,
        name: "mac-a",
        capacity: %{"exclusive" => 1},
        held: [held(Relay.Cards.ref(board, a), "bound")]
      )

      assert Runs.starvation(board, now) == nil
    end

    test "no verdict when no connected runner advertises exclusive capacity", %{board: board, stage: stage, now: now} do
      queued_exclusive(stage, now, 600)
      insert(:runner, board: board, name: "mac-a", capacity: %{"shared_clean" => 2}, held: [])

      assert Runs.starvation(board, now) == nil
    end
  end
end
