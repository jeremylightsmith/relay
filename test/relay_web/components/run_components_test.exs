defmodule RelayWeb.RunComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Relay.Runs
  alias RelayWeb.RunComponents

  # `run/1` mirrors the shape RelayWeb.RunComponents actually reads: either
  # Relay.Runs' per-card summary map (has :flow_version, currently always nil
  # pending RLY-152) or a raw %Schemas.Run{} (no :flow_version key at all —
  # the version chip degrades gracefully when it's absent).
  defp run(attrs) do
    Map.merge(
      %{
        status: :running,
        flow_key: "code",
        flow_version: 3,
        current_node: "implement",
        started_at: DateTime.add(DateTime.utc_now(), -291, :second),
        finished_at: nil
      },
      attrs
    )
  end

  # `Schemas.NodeExecution` has no stored duration column (only
  # started_at/finished_at) and the node field is `:node_key`, not `:node` —
  # this helper mirrors test/support/factory.ex's `:duration_s` convenience.
  # `:id` is needed by `Relay.Runs.last_node/2` to order terminal runs.
  defp ne(node_key, attempt, outcome, attrs \\ %{}) do
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
    started_at = DateTime.utc_now()
    finished_at = duration_s && DateTime.add(started_at, duration_s, :second)

    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        node_key: node_key,
        attempt: attempt,
        outcome: outcome,
        detail: nil,
        cost: nil,
        started_at: started_at,
        finished_at: finished_at
      },
      attrs
    )
  end

  # Builds a %Relay.Runs.RunDetail{} the way the drawer does: a run (+ node
  # executions) and its flow (or nil).
  defp detail(run_attrs, nes, flow \\ nil), do: Runs.run_detail(Map.put(run(run_attrs), :node_executions, nes), flow)

  describe "run_duration/1 and run_cost/1" do
    test "formats per the artboard, dash for missing" do
      assert RunComponents.run_duration(nil) == "—"
      assert RunComponents.run_duration(8) == "0:08"
      assert RunComponents.run_duration(160) == "2:40"
      assert RunComponents.run_duration(4020) == "1h 7m"
      assert RunComponents.run_cost(nil) == "—"
      assert RunComponents.run_cost(Decimal.new("0.9")) == "$0.90"
    end
  end

  describe "run_status_strip/1" do
    test "running: violet wrap, pulsing baton dot, running vN chip" do
      html =
        render_component(&RunComponents.run_status_strip/1, detail: detail(%{}, []), baton: "BATON · FLOW")

      assert html =~ "oklch(0.985 0.018 292)"
      assert html =~ "animation:relaypulse"
      assert html =~ "BATON · FLOW"
      assert html =~ "running v3"
    end

    test "parked and failed use the artboard copy" do
      parked =
        render_component(&RunComponents.run_status_strip/1,
          detail: detail(%{status: :parked}, []),
          baton: "BATON · YOU"
        )

      failed =
        render_component(&RunComponents.run_status_strip/1,
          detail: detail(%{status: :failed, finished_at: DateTime.utc_now()}, []),
          baton: "BATON · STOPPED"
        )

      assert parked =~ "Parked — waiting on your answer"
      assert parked =~ "oklch(0.985 0.022 75)"
      assert failed =~ "Run failed"
      refute failed =~ "circuit breaker"
      assert failed =~ "was on v3"
    end

    test "gracefully omits the version number when flow_version is absent" do
      html =
        render_component(&RunComponents.run_status_strip/1,
          detail: detail(%{flow_version: nil}, []),
          baton: "BATON · FLOW"
        )

      assert html =~ "running"
      refute html =~ "vnil"
    end
  end

  describe "run_mini_graph/1" do
    test "colors done/active/pending segments and shows task progress" do
      html =
        render_component(&RunComponents.run_mini_graph/1,
          path: ["branch", "implement", "spec_review", "quality_review"],
          run: run(%{current_node: "implement"}),
          task_progress: %{done: 1, total: 4}
        )

      assert html =~ "FLOW · CODE · task 2 of 4"
      assert html =~ "height:9px"
      assert html =~ "var(--color-success)"
      assert html =~ "box-shadow:0 0 0 2px oklch(0.56 0.16 292/0.25)"
      assert html =~ "opacity:0.5"
    end
  end

  describe "run_node_timeline/1" do
    test "renders duration, dash cost, attempt chips, and the expanded failure" do
      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail:
            detail(%{}, [
              ne("branch", 1, :succeeded, %{duration_s: 8, cost: Decimal.new("0.00")}),
              ne("quality_review", 1, :failed, %{duration_s: 48, detail: "assert on CSV bytes"}),
              ne("implement", 2, nil, %{duration_s: nil})
            ])
        )

      assert html =~ "0:08"
      assert html =~ "—"
      assert html =~ "OUTCOME: FAILED"
      assert html =~ "background:oklch(0.20 0.02 255)"
      assert html =~ "assert on CSV bytes"
      assert html =~ "attempt 2"
    end

    test "review-failed loop renders the loop chip but NEVER a session-resumed chip" do
      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail:
            detail(%{}, [
              ne("implement", 1, :succeeded),
              ne("quality_review", 1, :failed, %{detail: "no"}),
              ne("implement", 2, nil)
            ])
        )

      assert html =~ "quality_review failed → implement · attempt 2"
      refute html =~ "session resumed"
    end

    test "needs-input re-entry is the only state that says session resumed" do
      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail:
            detail(%{flow_key: "spec", current_node: "brainstorm"}, [
              ne("brainstorm", 1, :needs_input),
              ne("brainstorm", 2, nil)
            ])
        )

      assert html =~ "session resumed"
    end

    test "a cancelled run renders nil-outcome rows with the cancelled glyph" do
      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail: detail(%{status: :cancelled}, [ne("implement", 1, nil, %{duration_s: 72})])
        )

      assert html =~ "⊘"
      refute html =~ "animation:relayring"
    end

    test "a running node execution with no timestamps computes no duration" do
      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail: detail(%{}, [ne("implement", 1, :succeeded, %{started_at: nil, finished_at: nil})])
        )

      assert html =~ "—"
    end
  end

  describe "run_state_banner/1" do
    test "circuit variant names the tripped node with the stat row" do
      html =
        render_component(&RunComponents.run_state_banner/1,
          variant: :circuit,
          card: nil,
          detail:
            detail(%{status: :failed}, [
              ne("quality_review", 1, :failed, %{detail: "same finding", cost: Decimal.new("0.76")}),
              ne("quality_review", 2, :failed, %{detail: "same finding", cost: Decimal.new("0.76")}),
              ne("quality_review", 3, :failed, %{detail: "same finding", cost: Decimal.new("0.76")})
            ])
        )

      assert html =~ "CIRCUIT BREAKER TRIPPED"
      assert html =~ "quality_review"
      assert html =~ "3 · stopped"
      assert html =~ "$2.28"
      assert html =~ "oklch(0.975 0.025 22)"
    end

    test "failed variant states the reason without inventing a circuit breaker" do
      html =
        render_component(&RunComponents.run_state_banner/1,
          variant: :failed,
          detail:
            detail(
              %{
                status: :failed,
                failure_detail:
                  "The flow has nowhere to go after `fixit` reported `failed`. (no_route_for_outcome: fixit → failed)"
              },
              [ne("fixit", 1, :failed, %{detail: "Could not fix the failing spec.", cost: Decimal.new("0.41")})]
            )
        )

      assert html =~ "RUN FAILED"
      refute html =~ "CIRCUIT BREAKER"
      # the English sentence from runs.failure_detail — surfaced nowhere before
      assert html =~ "The flow has nowhere to go after"
      assert html =~ "fixit"
      assert html =~ "Could not fix the failing spec."
      assert html =~ "1 · stopped"
      assert html =~ "$0.41"
    end

    test "failed variant falls back to a plain sentence when failure_detail is absent" do
      html =
        render_component(&RunComponents.run_state_banner/1,
          variant: :failed,
          detail: detail(%{status: :failed, failure_detail: nil}, [ne("fixit", 1, :failed)])
        )

      assert html =~ "RUN FAILED"
      refute html =~ "CIRCUIT BREAKER"
    end

    test "parked variant frames the slot in amber with the paused-node row" do
      assigns = %{detail: detail(%{status: :parked, flow_key: "spec", current_node: "brainstorm"}, [])}

      html =
        rendered_to_string(~H"""
        <RunComponents.run_state_banner variant={:parked} detail={@detail}>
          <div id="embedded-stepper">stepper goes here</div>
        </RunComponents.run_state_banner>
        """)

      assert html =~ "RELAY AI NEEDS YOUR INPUT"
      assert html =~ "paused at brainstorm"
      assert html =~ "attempt 1"
      assert html =~ ~s(id="embedded-stepper")
      assert html =~ "oklch(0.975 0.025 75)"
    end

    test "parked variant's attempt count reflects the paused node's actual attempt, not always 1" do
      assigns = %{
        detail:
          detail(%{status: :parked, flow_key: "spec", current_node: "brainstorm"}, [
            ne("brainstorm", 1, :failed, %{detail: "first try"}),
            ne("brainstorm", 2, :failed, %{detail: "second try"}),
            ne("brainstorm", 3, :needs_input, %{detail: nil})
          ])
      }

      html =
        rendered_to_string(~H"""
        <RunComponents.run_state_banner variant={:parked} detail={@detail}>
          <div id="embedded-stepper">stepper goes here</div>
        </RunComponents.run_state_banner>
        """)

      assert html =~ "paused at brainstorm"
      assert html =~ "attempt 3"
      refute html =~ "attempt 1"
    end

    test "reentry and revoked variants carry their copy" do
      rejection = %{
        note: "stream it",
        rejected_by: "Dana",
        from_stage_name: "Review",
        rejected_at: DateTime.utc_now()
      }

      reentry =
        render_component(&RunComponents.run_state_banner/1,
          variant: :reentry,
          card: %{rejection: rejection, branch: nil}
        )

      revoked =
        render_component(&RunComponents.run_state_banner/1,
          variant: :revoked,
          detail: detail(%{status: :cancelled, current_node: "implement"}, []),
          card: %{branch: "relay/RLY-150", rejection: nil},
          claimer: "Jeremy"
        )

      assert reentry =~ "RE-ENTRY · CHANGES REQUESTED BY DANA"
      assert reentry =~ "the run reads this note before implement"
      assert revoked =~ "CLAIMED BY A HUMAN"
      assert revoked =~ "relay/RLY-150"
      refute revoked =~ "Resume run"
    end
  end

  describe "run_history/1" do
    test "prior runs collapse to DURATION · NODES · ATTEMPTS · COST" do
      html =
        render_component(&RunComponents.run_history/1,
          runs: [
            %{
              detail:
                detail(%{status: :done, flow_version: 3, finished_at: DateTime.utc_now()}, [
                  ne("implement", 1, :succeeded)
                ]),
              number: 3
            }
          ]
        )

      assert html =~ "PRIOR RUNS · 1"
      assert html =~ "Run #3 · v3"
      assert html =~ "ATTEMPTS"
    end

    test "omits the dangling '· v' when flow_version is nil (RLY-152 pending)" do
      html =
        render_component(&RunComponents.run_history/1,
          runs: [
            %{
              detail:
                detail(%{status: :done, flow_version: nil, finished_at: DateTime.utc_now()}, [
                  ne("implement", 1, :succeeded)
                ]),
              number: 2
            }
          ]
        )

      assert html =~ "Run #2"
      refute html =~ "Run #2 · v"
    end
  end

  describe "run_face/1" do
    test "running: segment bar + node x of y" do
      html =
        render_component(&RunComponents.run_face/1,
          ref: "RLY-1",
          run:
            {:run,
             %{
               status: :running,
               node_index: 2,
               node_count: 4,
               current_node: "implement",
               flow_key: "code",
               flow_version: 3,
               attempts: 2
             }}
        )

      assert html =~ ~s(id="card-RLY-1-run-face")
      assert html =~ "node 2 of 4"
      assert html =~ "height:5px"
      assert html =~ "oklch(0.90 0.02 292)"
    end

    test "parked, failed, queued, done, cancelled badges" do
      parked =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run: {:run, %{status: :parked, current_node: "brainstorm", flow_key: "spec", flow_version: 2, attempts: 1}}
        )

      failed =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run:
            {:run,
             %{
               status: :failed,
               current_node: nil,
               last_node: "quality_review",
               flow_key: "code",
               flow_version: 3,
               attempts: 3
             }}
        )

      queued = render_component(&RunComponents.run_face/1, ref: "R", run: {:queued, %{key: "code"}})

      done =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run:
            {:run,
             %{status: :done, duration_s: 581, cost: Decimal.new("0.38"), flow_key: "code", flow_version: 3, attempts: 4}}
        )

      cancelled =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run:
            {:run,
             %{
               status: :cancelled,
               current_node: nil,
               last_node: "implement",
               flow_key: "code",
               flow_version: 3,
               attempts: 1
             }}
        )

      assert parked =~ "PARKED · NEEDS YOU"
      assert failed =~ "RUN FAILED"
      assert failed =~ "stuck at quality_review"
      assert queued =~ "QUEUED · CODE FLOW"
      assert queued =~ "picks up next"
      assert done =~ "Completed · 9:41"
      refute done =~ "merged"
      assert done =~ "$0.38"
      assert cancelled =~ "CANCELLED"
      refute cancelled =~ "CLAIMED"
      assert cancelled =~ "stopped at implement · resumable"
    end

    test "the failed badge's circuit breaker claim reads the domain flag, not attempts" do
      breaker =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run:
            {:run,
             %{
               status: :failed,
               current_node: nil,
               last_node: "quality_review",
               flow_key: "code",
               flow_version: 3,
               attempts: 3,
               breaker_tripped?: true
             }}
        )

      plain =
        render_component(&RunComponents.run_face/1,
          ref: "R",
          run:
            {:run,
             %{
               status: :failed,
               current_node: nil,
               last_node: "quality_review",
               flow_key: "code",
               flow_version: 3,
               attempts: 3,
               breaker_tripped?: false
             }}
        )

      assert breaker =~ "CIRCUIT BREAKER"
      refute plain =~ "CIRCUIT BREAKER"
    end
  end
end
