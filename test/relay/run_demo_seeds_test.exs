defmodule Relay.RunDemoSeedsTest do
  @moduledoc """
  RE253 — the demo board must actually seed the escalated-park state, because that is the state a
  human (and the acceptance pass) clicks on to check the escalation panel. Evaluating the script is
  the only honest check: a string match on the source would pass on a seed that no longer runs.
  """
  use Relay.DataCase, async: false

  import ExUnit.CaptureIO

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Runs
  alias Schemas.User

  # The script owns the board it seeds (owner = the hard-coded seed email), so re-read it the same
  # way: owner-scoped by slug. `capture_io` swallows the script's closing "Seeded run-demo board" line.
  setup do
    capture_io(fn -> Code.eval_file("priv/repo/run_demo_seeds.exs") end)
    owner = Relay.Repo.get_by!(User, email: "jeremy.lightsmith@gmail.com")
    %{board: Boards.get_board!(owner, "run-demo")}
  end

  defp seeded_card(board, title) do
    card = Enum.find(Cards.list_cards(board), &(&1.title == title))
    assert card, "the seed script should create a #{inspect(title)} card"
    card
  end

  test "the run-demo board seeds an escalation park the drawer can render", %{board: board} do
    card = seeded_card(board, "Export the board as CSV")
    assert card.status == :needs_input

    [run | _prior] = Runs.list_runs_for_card(card)
    assert run.status == :parked
    assert run.parked_reason == :needs_input
    assert run.current_node == "implement"
    assert Runs.park_kind(run) == :escalation

    detail = Runs.run_detail(run, nil)
    assert detail.parked_attempt == 3
    assert detail.last_failure_detail =~ "commit guard"
  end

  test "the structured-question park is still seeded, so both faces are demoable", %{board: board} do
    [run | _prior] = board |> seeded_card("Board search") |> Runs.list_runs_for_card()

    assert Runs.park_kind(run) == :question
  end
end
