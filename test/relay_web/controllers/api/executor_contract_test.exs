defmodule RelayWeb.Api.ExecutorContractTest do
  @moduledoc """
  The server↔executor contract (RLY-176).

  This test is the ONLY writer of `test/fixtures/executor_contract.json`. It drives the real
  `/api/node-jobs/*` routes, captures what they actually send and accept, and asserts the
  committed fixture still matches. `bin/test_relay.py` builds every job dict from that same
  file, so a field renamed here breaks the Python suite on the next run — which is the whole
  point: before this existed, both suites were green against their own imagination of the
  other (RLY-163/165/166/170/175).

  No payload literal is typed into this file. Regenerate with:

      RELAY_WRITE_CONTRACT_FIXTURE=1 mix test test/relay_web/controllers/api/executor_contract_test.exs

  which rewrites the fixture AND still fails, so a regenerated fixture cannot slip through
  unreviewed in the same run.
  """
  use RelayWeb.ConnCase, async: false

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher

  @fixture_path "test/fixtures/executor_contract.json"

  setup do
    FakeDispatcher.register(self())
    start_supervised!(Relay.Runs.Supervisor)
    :ok
  end

  test "the committed fixture matches what /api/node-jobs/* actually sends and accepts" do
    user = insert(:user)

    shared = board_with_flow(user, "Contract A", "CTA", :shared_clean, agent_node())
    exclusive = board_with_flow(user, "Contract B", "CTB", :exclusive, shell_node())

    # The heartbeat MUST run before anything is claimed: RLY-170's orphan recovery reads the
    # absence of a job from `running` as "this executor restarted and lost it" and requeues it,
    # which would yank the job out from under the claims below.
    heartbeat_request = %{
      "executor" => executor_ident(),
      "capacity" => %{"shared_clean" => 1, "exclusive" => 1},
      # RLY-182: optional, send-on-change. Present here so the fixture records the key
      # and its shape for bin/test_relay.py to build against.
      "capabilities" => %{"agents" => ["plan-implementer"], "skills" => ["write-plan"]},
      "running" => [],
      "bound_runs" => []
    }

    heartbeat_response =
      shared.conn
      |> post(~p"/api/node-jobs/heartbeat", Jason.encode!(heartbeat_request))
      |> json_response(200)

    # 1. shared_clean_agent — the Spec/Plan shape. Its `vars` carry `branch` because
    #    build_payload sets it unconditionally; the mere existence of this case is what would
    #    have caught the RLY-166 guard.
    {run, shared_clean_agent} = claim_one(shared, %{"shared_clean" => 1})

    # 2. The outcome the executor POSTs, at the real controller. `needs_input` parks the run,
    #    which is also how we reach the resumed case below.
    outcome_request = %{
      "outcome" => "needs_input",
      "detail" => "asked the human",
      "git_sha" => "0000000000000000000000000000000000000000",
      "session_id" => "sess-fixture"
    }

    outcome_response =
      shared.conn
      |> post(~p"/api/node-jobs/#{shared_clean_agent["id"]}/outcome", Jason.encode!(outcome_request))
      |> json_response(200)

    # 3. resumed_agent — re-entry populates resume_session, the one field no fresh claim shows.
    # `run` is the struct captured at claim time, before the needs_input outcome parked it —
    # resume_run/2 requires status: :parked, so it must be reloaded first.
    {:ok, _run} = run.id |> Runs.get_run!() |> Runs.resume_run(resume_session: "sess-fixture")
    assert_receive {:node_started, _run, _execution}, 2_000
    resumed_agent = claim(shared, %{"shared_clean" => 1})

    # 4. exclusive_shell — the Code shape.
    {_run, exclusive_shell} = claim_one(exclusive, %{"exclusive" => 1})

    document = %{
      "version" => 2,
      "vocabulary" => %{
        "run_states" => %{
          "active" => stringify(Schemas.Run.active_statuses()),
          "terminal" => stringify(Schemas.Run.terminal_statuses())
        },
        "outcomes" => stringify(Schemas.NodeExecution.outcomes()),
        "isolation" => stringify(Schemas.Flow.isolation_classes()),
        "node_types" => %{"runnable" => stringify(Schemas.Flow.Node.runnable_types())}
      },
      "claim_request" => normalize(claim_body(%{"shared_clean" => 1})),
      "claim" => %{
        "shared_clean_agent" => normalize(shared_clean_agent),
        "exclusive_shell" => normalize(exclusive_shell),
        "resumed_agent" => normalize(resumed_agent)
      },
      "outcome" => %{
        "request" => normalize(outcome_request),
        "response" => normalize(outcome_response)
      },
      "heartbeat" => %{
        "request" => normalize(heartbeat_request),
        "response" => normalize(heartbeat_response)
      }
    }

    assert_matches_fixture!(document)
  end

  # One place builds the `executor` dict for both claim and heartbeat, mirroring bin/relay's
  # executor_ident (RLY-184). The version tracks the server's own minimum so the fixture always
  # depicts a CURRENT executor — a literal would start 409ing the moment the minimum moves.
  defp executor_ident do
    %{"name" => "fixture", "host" => "fixture-host", "interval" => 30, "version" => Runs.min_executor_version()}
  end

  defp claim_body(capacity), do: %{"executor" => executor_ident(), "capacity" => capacity}

  defp stringify(atoms), do: Enum.map(atoms, &Atom.to_string/1)

  defp agent_node do
    %{key: "work", type: :agent, run: "/write-plan {ref}", agent: "plan-implementer"}
  end

  defp shell_node do
    %{key: "work", type: :shell, run: "mix precommit"}
  end

  # One board per flow. Flows are unique-per-`pulls_from_stage_id` only while enabled, and the
  # board seeds its own default flows — a second board is cheaper and more deterministic than
  # hunting for a free stage on the first.
  defp board_with_flow(user, name, key, isolation, node) do
    {:ok, board} = Relay.Boards.create_board(user, %{name: name, key: key})
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
    :ok = Runs.subscribe(board.id)

    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "contract",
        isolation: isolation,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: plan.id,
        nodes: [node],
        edges: [
          %{from: "start", to: "work"},
          %{from: "work", to: "done", on: :succeeded},
          %{from: "work", to: "done", on: :failed},
          %{from: "work", to: "done", on: :partial}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{board: board, flow: flow, conn: conn, next_up: next_up}
  end

  defp claim_one(ctx, capacity) do
    {:ok, card} = Relay.Cards.create_card(ctx.next_up, %{title: "Contract card"})
    {:ok, run} = Runs.start_run(card, ctx.flow)
    {run, claim(ctx, capacity)}
  end

  defp claim(ctx, capacity) do
    ctx.conn |> post(~p"/api/node-jobs/claim", Jason.encode!(claim_body(capacity))) |> json_response(200)
  end

  # UUIDs would make the file churn on every run. Everything else — including
  # derived-but-deterministic values like `branch` — is written literally.
  @placeholders %{
    "id" => "<node-job-id>",
    "run_id" => "<run-id>",
    "resume_session" => "<session-id>",
    "session_id" => "<session-id>"
  }

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      case {Map.fetch(@placeholders, k), v} do
        {{:ok, _token}, nil} -> {k, nil}
        {{:ok, token}, _value} -> {k, token}
        {:error, _value} -> {k, normalize(v)}
      end
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  defp assert_matches_fixture!(document) do
    if System.get_env("RELAY_WRITE_CONTRACT_FIXTURE") == "1" do
      File.write!(@fixture_path, encode(document))

      flunk("""
      Rewrote #{@fixture_path} from the live routes. Review the diff, then re-run WITHOUT
      RELAY_WRITE_CONTRACT_FIXTURE=1. Failing on purpose so a regenerated fixture is never
      green in the same run that generated it.
      """)
    end

    committed = @fixture_path |> File.read!() |> Jason.decode!()

    assert committed == document, """
    #{@fixture_path} no longer matches what /api/node-jobs/* actually sends.

    bin/test_relay.py builds every job dict from that file, so this is the seam guard, not a
    snapshot nit. If the change is intended, regenerate and review the diff:

        RELAY_WRITE_CONTRACT_FIXTURE=1 mix test test/relay_web/controllers/api/executor_contract_test.exs
    """
  end

  # Stable key order so the committed file is diffable.
  defp encode(document), do: document |> ordered() |> Jason.encode!() |> Jason.Formatter.pretty_print()

  defp ordered(map) when is_map(map) do
    values = map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
    %Jason.OrderedObject{values: values}
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
