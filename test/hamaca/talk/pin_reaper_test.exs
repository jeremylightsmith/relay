defmodule Hamaca.Talk.PinReaperTest do
  @moduledoc "RE493 — the Talk pin sweep's 30s clock: one `:sweep` releases a queued turn off a gone runner."
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Talk
  alias Hamaca.Talk.PinReaper
  alias Schemas.TalkEvent

  test "one sweep releases a queued talk turn pinned to a gone runner" do
    board = insert(:board)
    card = insert(:card, board: board, stage: insert(:stage, board: board))
    author = insert(:user)

    {:ok, turn} = Talk.post_message(card, author, "hello")
    session = Talk.session_for_card(card)

    Repo.update_all(from(j in Schemas.NodeJob, where: j.id == ^turn.node_job_id), set: [runner_name: "ghost-runner"])

    Repo.update_all(from(s in Schemas.TalkSession, where: s.id == ^session.id),
      set: [pinned_runner_name: "ghost-runner", claude_session_id: "sess-abc"]
    )

    # Long interval → the timer stays dormant; we trigger exactly one sweep. Sandbox access comes
    # from `callers:`, the same seam `RunnerReaper` uses.
    pid =
      start_supervised!(
        {PinReaper,
         interval_ms: to_timeout(hour: 1), name: :"pin_reaper_#{System.unique_integer([:positive])}", callers: [self()]}
      )

    send(pid, :sweep)
    # Returns only once :sweep is fully handled — and only if the process survived it.
    assert %{interval: _} = :sys.get_state(pid)

    assert Runs.get_job(turn.node_job_id).runner_name == nil

    assert [%TalkEvent{kind: :error, client_seq: -1}] =
             Repo.all(from(e in TalkEvent, where: e.talk_turn_id == ^turn.id and e.kind == :error))
  end
end
