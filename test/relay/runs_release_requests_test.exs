defmodule Relay.RunsReleaseRequestsTest do
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Runner

  setup do
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "RE337 release board"})
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    %{user: user, board: board, stage: stage}
  end

  defp held(ref, state), do: %{"ref" => ref, "state" => state}

  defp parked_card(stage) do
    card = insert(:card, stage: stage, title: "Parked on a human")
    run = insert(:run, card: card, status: :parked, parked_reason: :needs_input)
    %{card: card, run: run}
  end

  defp beat(board, name, held) do
    {:ok, runner} =
      Runs.upsert_runner(board, %{
        "name" => name,
        "capacity" => %{"exclusive" => 1},
        "held" => held
      })

    runner
  end

  defp timeline_texts(card) do
    Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, select: a.text)
  end

  describe "Schemas.Runner release vocabulary" do
    test "only bound is idle; bound and talk keep a request pending" do
      assert Runner.idle_holding?("bound")
      refute Runner.idle_holding?("running")
      refute Runner.idle_holding?("talk")
      refute Runner.idle_holding?("retained")

      assert Runner.release_request_pending?("bound")
      assert Runner.release_request_pending?("talk")
      refute Runner.release_request_pending?("running")
      refute Runner.release_request_pending?("retained")
    end

    test "the remove disposition is cancelled, never failed (failed would retain the tree)" do
      assert Runner.release_remove_status() == :cancelled
    end

    test "release eligibility per holding state" do
      assert Runner.release_eligibility("bound") == :enabled
      assert Runner.release_eligibility("running") == {:disabled, "a job is running in this worktree"}
      assert Runner.release_eligibility("talk") == {:disabled, "a talk session is attached"}
      assert Runner.release_eligibility("retained") == :hidden
    end

    test "every holding state has an eligibility" do
      for state <- Runner.holding_states(), do: assert(Runner.release_eligibility(state))
    end
  end

  describe "request_worktree_release/4" do
    test "accepts a bound holding, records it once, and logs the card timeline", %{board: board, stage: stage, user: user} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])

      assert {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref, actor: {:user, user.id})
      assert %Runner{release_requests: [^ref]} = Repo.get_by!(Runner, board_id: board.id, name: "mac-a")
      assert "worktree released on runner mac-a" in timeline_texts(card)
    end

    test "is idempotent: a second request neither duplicates the ref nor logs again", %{board: board, stage: stage} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])

      assert {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref)
      assert {:ok, :already_requested} = Runs.request_worktree_release(board, "mac-a", ref)

      assert %Runner{release_requests: [^ref]} = Repo.get_by!(Runner, board_id: board.id, name: "mac-a")
      assert Enum.count(timeline_texts(card), &(&1 == "worktree released on runner mac-a")) == 1
    end

    test "refuses a running, talk, retained or absent holding and records nothing", %{board: board, stage: stage} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)

      for state <- ["running", "talk", "retained"] do
        beat(board, "mac-a", [held(ref, state)])
        assert {:error, :not_idle} = Runs.request_worktree_release(board, "mac-a", ref)
      end

      beat(board, "mac-a", [])
      assert {:error, :not_idle} = Runs.request_worktree_release(board, "mac-a", ref)

      assert %Runner{release_requests: []} = Repo.get_by!(Runner, board_id: board.id, name: "mac-a")
      refute "worktree released on runner mac-a" in timeline_texts(card)
    end

    test "an unknown runner is refused", %{board: board} do
      assert {:error, :runner_not_found} = Runs.request_worktree_release(board, "nobody", "RLY1")
    end
  end

  describe "upsert_runner/2 prunes release requests" do
    setup %{board: board, stage: stage} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])
      {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref)
      %{ref: ref}
    end

    test "keeps the request while the ref is still bound", %{board: board, ref: ref} do
      assert %Runner{release_requests: [^ref]} = beat(board, "mac-a", [held(ref, "bound")])
    end

    test "keeps the request under a talk turn (the runner defers teardown)", %{board: board, ref: ref} do
      assert %Runner{release_requests: [^ref]} = beat(board, "mac-a", [held(ref, "talk")])
    end

    test "clears it once the runner stops reporting the ref (the tree is gone)", %{board: board} do
      assert %Runner{release_requests: []} = beat(board, "mac-a", [])
    end

    test "clears it when the run resumed first (running), so it can never tear down live work",
         %{board: board, ref: ref} do
      assert %Runner{release_requests: []} = beat(board, "mac-a", [held(ref, "running")])
    end

    test "a claim-style upsert (no held key) leaves requests untouched", %{board: board, ref: ref} do
      {:ok, runner} = Runs.upsert_runner(board, %{"name" => "mac-a"})
      assert runner.release_requests == [ref]
    end
  end

  describe "release_held/3 (the heartbeat reply)" do
    test "adds a remove entry for a pending request whose ref is bound this beat", %{board: board, stage: stage} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])
      {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref)

      runner = beat(board, "mac-a", [held(ref, "bound")])

      assert Runs.release_held(board, runner, [held(ref, "bound")]) == [%{ref: ref, status: :cancelled}]
    end

    test "never sends a pending request whose ref is talk this beat", %{board: board, stage: stage} do
      %{card: card} = parked_card(stage)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])
      {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref)

      runner = beat(board, "mac-a", [held(ref, "talk")])

      assert Runs.release_held(board, runner, [held(ref, "talk")]) == []
    end

    test "with no requests it is exactly releasable_held/2", %{board: board, stage: stage} do
      card = insert(:card, stage: stage)
      insert(:run, card: card, status: :cancelled)
      ref = Relay.Cards.ref(board, card)
      runner = beat(board, "mac-a", [held(ref, "bound")])

      assert Runs.release_held(board, runner, [held(ref, "bound")]) ==
               Runs.releasable_held(board, [held(ref, "bound")])
    end

    test "a ref already derived-releasable keeps its derived status (failed stays retained)",
         %{board: board, stage: stage} do
      card = insert(:card, stage: stage)
      insert(:run, card: card, status: :failed)
      ref = Relay.Cards.ref(board, card)
      beat(board, "mac-a", [held(ref, "bound")])
      {:ok, :requested} = Runs.request_worktree_release(board, "mac-a", ref)
      runner = beat(board, "mac-a", [held(ref, "bound")])

      assert Runs.release_held(board, runner, [held(ref, "bound")]) == [%{ref: ref, status: :failed}]
    end
  end
end
