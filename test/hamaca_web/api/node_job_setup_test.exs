defmodule HamacaWeb.Api.NodeJobSetupTest do
  @moduledoc """
  RE446: the node-job transport drives setup steps 6 and 7 — a heartbeat ticks step 6 on the
  key's board, a granted claim ticks step 7 — and a board with no checklist answers as before.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query

  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Setup
  alias Schemas.BoardSetupStep
  alias Schemas.Card

  defp runner_step, do: Setup.step_id(:runner)
  defp claim_step, do: Setup.step_id(:first_claim)

  # A board (from `template`, or none) and a conn authed with a fresh board key for it.
  defp board_conn(conn, template) do
    user = insert(:user)
    attrs = %{name: "Node Board", slug: unique_slug("node")}
    attrs = if template, do: Map.put(attrs, :template, template), else: attrs
    {:ok, board} = Hamaca.Boards.create_board(user, attrs)
    {:ok, %{token: token}} = Hamaca.ApiKeys.create_key(board, user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    {board, conn}
  end

  defp step(board, id),
    do:
      board |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.flat_map(&[&1 | &1.children]) |> Enum.find(&(&1.id == id))

  defp walk do
    parents = for %{parent: parent} <- Setup.steps(), parent, into: MapSet.new(), do: parent
    for %{id: id} <- tl(Setup.steps()), id not in parents, do: id
  end

  defp advance_to!(board, id) do
    for prior <- Enum.take_while(walk(), &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    board
  end

  defp setup_rows(board), do: Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board.id))

  # A queued, unpinned shared_clean agent job (harness_key nil → any runner may claim it).
  defp queued_job!(board) do
    stage = insert(:stage, board: board, category: :planning, position: 100)
    card = insert(:card, stage: stage)
    run = insert(:run, card: card)
    execution = insert(:node_execution, run: run, outcome: nil, finished_at: nil)

    job =
      insert(:node_job,
        node_execution: execution,
        state: :queued,
        runner_name: nil,
        claimed_at: nil,
        payload: %{"isolation" => "shared_clean", "vars" => %{"ref" => "RL-1"}},
        harness_key: nil
      )

    {card, job}
  end

  defp runner_body(name), do: %{"name" => name, "host" => name, "interval" => 30, "version" => Runs.min_runner_version()}

  defp heartbeat(conn, name \\ "jl-mbp") do
    post(
      conn,
      ~p"/api/node-jobs/heartbeat",
      Jason.encode!(%{
        "runner" => runner_body(name),
        "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
        "running" => [],
        "harnesses" => [%{"key" => "claude-code", "installed" => true, "signed_in" => true}]
      })
    )
  end

  defp claim(conn, name \\ "jl-mbp") do
    post(
      conn,
      ~p"/api/node-jobs/claim",
      Jason.encode!(%{
        "runner" => runner_body(name),
        "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
        "running" => []
      })
    )
  end

  # Scenario 13
  test "a heartbeat ticks step 6 with the runner's machine and sign-in", %{conn: conn} do
    {board, conn} = board_conn(conn, "bare-minimum")
    advance_to!(board, runner_step())

    assert conn |> heartbeat() |> json_response(200)

    six = step(board, runner_step())
    assert six.status == :done
    assert String.ends_with?(six.evidence, "jl-mbp · claude logged_in")
  end

  # Scenario 14
  test "a granted claim ticks step 7 naming the card and the runner", %{conn: conn} do
    {board, conn} = board_conn(conn, "bare-minimum")
    advance_to!(board, claim_step())
    {card, job} = queued_job!(board)

    body = conn |> claim() |> json_response(200)
    assert body["id"] == job.id

    seven = step(board, claim_step())
    assert seven.status == :done
    assert seven.evidence =~ Card.format_ref(board.key, card.ref_number)
    assert seven.evidence =~ "by jl-mbp"
  end

  # Scenario 15
  test "a heartbeat ticks only its own key's board", %{conn: conn} do
    {board_a, conn_a} = board_conn(conn, "bare-minimum")
    {board_b, _conn_b} = board_conn(conn, "bare-minimum")
    advance_to!(board_a, runner_step())
    advance_to!(board_b, runner_step())

    assert conn_a |> heartbeat() |> json_response(200)

    assert step(board_a, runner_step()).status == :done
    assert step(board_b, runner_step()).status == :active
  end

  # Scenario 16
  test "a board with no checklist answers heartbeat and claim as before", %{conn: conn} do
    {board, conn} = board_conn(conn, nil)
    {_card, job} = queued_job!(board)

    assert %{"revoked" => []} = conn |> heartbeat() |> json_response(200)
    assert %{"id" => id} = conn |> claim() |> json_response(200)
    assert id == job.id
    assert setup_rows(board) == []
  end

  # Scenario 17 (RE446): a connected machine's runner ticks the machine's step 6 only.
  test "a machine key's heartbeat ticks the machine's step 6, not the board's", %{conn: conn} do
    {board, _conn} = board_conn(conn, "bare-minimum")
    advance_to!(board, runner_step())
    {:ok, %{machine: machine, token: sam_token}} = Setup.connect_machine(board, insert(:user, name: "Sam"))

    for id <- ~w(3 4 5.1 5.6), do: {:ok, _} = Setup.advance(machine, id, :done, %{})
    board_before = Setup.checklist(board)

    sam_conn =
      conn
      |> put_req_header("authorization", "Bearer " <> sam_token)
      |> put_req_header("content-type", "application/json")

    assert sam_conn |> heartbeat("sam-linux") |> json_response(200)

    six = machine |> Setup.checklist() |> Map.fetch!(:steps) |> Enum.find(&(&1.id == runner_step()))
    assert six.status == :done
    assert Setup.checklist(board) == board_before
  end
end
