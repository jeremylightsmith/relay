defmodule RelayWeb.RunComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
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
      assert html =~ "box-shadow:0 0 0 2px color-mix(in oklab, var(--color-secondary) 25%, transparent)"
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
      assert html =~ "background:var(--color-neutral)"
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

    test "RE426: mobile tweaks — type tag hides below sm, attempt chip and duration never wrap" do
      flow = %Schemas.Flow{nodes: [%Schemas.Flow.Node{key: "implement", type: :agent, run: "x"}], edges: []}

      html =
        render_component(&RunComponents.run_node_timeline/1,
          detail: detail(%{}, [ne("implement", 1, :failed, %{detail: "no"}), ne("implement", 2, nil)], flow)
        )

      doc = LazyHTML.from_fragment(html)
      tag_class = doc |> LazyHTML.query(".run-type-tag") |> LazyHTML.attribute("class") |> hd()
      assert tag_class =~ "hidden"
      assert tag_class =~ "sm:inline"

      assert doc |> LazyHTML.query(".run-attempt-chip") |> LazyHTML.attribute("style") |> hd() =~
               "white-space:nowrap"

      duration_styles =
        doc
        |> LazyHTML.query(".run-timeline-row span")
        |> Enum.filter(&(&1 |> LazyHTML.text() |> String.trim() == "0:42"))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "style"))

      assert duration_styles != []
      assert Enum.all?(duration_styles, &(&1 =~ "white-space:nowrap"))
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
      assert html =~ "color-mix(in oklab, var(--color-error) 5%, var(--color-base-100))"
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

    # RE394 — the banner's Retry shows a client-side pressed face; the banner is its group.
    for {variant, banner} <- [failed: ".run-banner-failed", circuit: ".run-banner-circuit"] do
      test "#{variant} banner's Retry carries a Retrying… face inside an action group" do
        doc =
          (&RunComponents.run_state_banner/1)
          |> render_component(
            variant: unquote(variant),
            card: nil,
            detail: detail(%{status: :failed}, [ne("fixit", 1, :failed, %{detail: "boom"})])
          )
          |> LazyHTML.from_fragment()

        assert "action-group" in classes_of(doc, unquote(banner))
        assert doc |> LazyHTML.query("#run-retry") |> LazyHTML.attribute("phx-click") == ["retry_run"]
        assert ~w(btn btn-sm btn-primary pending-action) -- classes_of(doc, "#run-retry") == []
        assert text_at(doc, "#run-retry .pending-idle") == "Retry"
        assert text_at(doc, "#run-retry .pending-face") == "Retrying…"
      end
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

  describe "stopped_work_banner/1" do
    test "renders the verdict's own sentence, never a re-derived one" do
      html =
        render_component(&RunComponents.stopped_work_banner/1,
          id: "stopped-work-banner",
          verdict: %{
            reason: :no_runner,
            detail: "No jobs claimed in 3m · no runner is connected to run this board's work."
          }
        )

      assert html =~ ~s(id="stopped-work-banner")
      # split around the apostrophe: HEEx escapes it to `&#39;` in the rendered output
      assert html =~ "no runner is connected to run this board"
      assert html =~ "work."
      assert html =~ "hero-exclamation-triangle"
    end

    test "an outdated roster is the warning tint; everything else is the error tint" do
      outdated =
        render_component(&RunComponents.stopped_work_banner/1,
          id: "b1",
          verdict: %{reason: :runner_outdated, detail: "running v0, requires v9."}
        )

      gone =
        render_component(&RunComponents.stopped_work_banner/1,
          id: "b2",
          verdict: %{reason: :runner_gone, detail: "no runner is connected."}
        )

      assert outdated =~ "var(--color-warning)"
      refute outdated =~ "var(--color-error)"
      assert gone =~ "var(--color-error)"
      refute gone =~ "var(--color-warning)"
    end

    test "layout margins are the caller's, not the component's" do
      html =
        render_component(&RunComponents.stopped_work_banner/1,
          id: "b3",
          class: "mx-4 mb-2 mt-2 sm:mx-5",
          verdict: %{reason: :no_runner, detail: "nothing is running."}
        )

      assert html =~ "mx-4"
      assert html =~ "sm:mx-5"
    end

    test "RE320: a rate-limited roster shares the outdated roster's warning tint" do
      html =
        render_component(&RunComponents.stopped_work_banner/1,
          id: "b3",
          verdict: %{reason: :runner_rate_limited, detail: "every connected runner is paused at its Claude usage limit."}
        )

      assert html =~ "var(--color-warning)"
      refute html =~ "var(--color-error)"
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
      assert html =~ "color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100))"
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

  describe "advance_button/1 (RE279: public, rendered by the Detail needs-input panel)" do
    test "renders #run-advance only when available" do
      html = render_component(&RunComponents.advance_button/1, available?: true)
      assert html =~ ~s(id="run-advance")
      assert html =~ ~s(phx-click="advance_run")
      assert html =~ "Task already done — continue"

      refute render_component(&RunComponents.advance_button/1, available?: false) =~ "run-advance"
    end

    test "#run-advance carries a Continuing… pressed face (RE394)" do
      doc =
        (&RunComponents.advance_button/1)
        |> render_component(available?: true)
        |> LazyHTML.from_fragment()

      assert text_at(doc, "#run-advance .pending-face") == "Continuing…"
      assert render_component(&RunComponents.advance_button/1, available?: false) =~ ~r/\A\s*\z/
    end

    test "run_state_banner no longer has a :parked variant" do
      assert_raise FunctionClauseError, fn ->
        render_component(&RunComponents.run_state_banner/1, variant: :parked, detail: detail(%{status: :parked}, []))
      end
    end
  end

  describe "run_face/1 rate limited (RE320)" do
    @running {:run, %{status: :running, node_index: 2, node_count: 4, current_node: "implement", flow_key: "code"}}

    test "renders the amber rate-limited note, which outranks stalled" do
      html =
        render_component(&RunComponents.run_face/1,
          run: @running,
          ref: "RLY-20",
          stalled?: true,
          rate_limited: %{resumes_at: ~U[2026-09-14 15:40:00Z]}
        )

      assert html =~ ~s(data-rate-limited="true")
      assert html =~ ~s(data-stalled="false")
      assert html =~ ~s(id="card-RLY-20-rate-limited")
      assert html =~ "Rate limited · resumes 3:40 PM UTC"
      assert html =~ "var(--color-warning)"
      refute html =~ "Quiet for a while"
    end

    test "without a rate limit the face is unchanged" do
      html = render_component(&RunComponents.run_face/1, run: @running, ref: "RLY-21")

      assert html =~ ~s(data-rate-limited="false")
      refute html =~ "Rate limited"
      refute html =~ "var(--color-warning)"
    end
  end

  describe "rate_limit_note/1 (RE320)" do
    test "a configured limit names the window, usage, max and resume time" do
      html =
        render_component(&RunComponents.rate_limit_note/1,
          id: "note",
          rate_limit: %{
            window: "five_hour",
            utilization: 0.95,
            max: 0.9,
            reason: "limit",
            resets_at: ~U[2026-09-14 15:40:00Z]
          }
        )

      assert html =~ ~s(id="note")
      assert html =~ "five_hour 95% / 90% · resumes 3:40 PM UTC"
      assert html =~ "var(--color-warning)"
    end

    test "a refusal says Claude refused" do
      html =
        render_component(&RunComponents.rate_limit_note/1,
          id: "note",
          rate_limit: %{
            window: "five_hour",
            utilization: nil,
            max: nil,
            reason: "rejected",
            resets_at: ~U[2026-09-14 15:40:00Z]
          }
        )

      assert html =~ "Claude refused (five_hour) · resumes 3:40 PM UTC"
    end
  end

  defp classes_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> List.first() |> String.split()
  end

  defp text_at(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  describe "run_list/1" do
    @now ~U[2026-10-08 12:00:00Z]

    defp stage(name), do: %{stage: %{name: name}}

    defp ago_s(seconds), do: DateTime.add(@now, -seconds, :second)

    defp three_entries do
      [
        %{
          detail: detail(%{status: :running, flow: stage("Code"), started_at: ago_s(291)}, [ne("implement", 1, nil)]),
          number: 3
        },
        %{
          detail:
            detail(%{status: :failed, flow: stage("Code"), finished_at: ago_s(7200)}, [
              ne("implement", 1, :failed, %{detail: "boom"})
            ]),
          number: 2
        },
        %{
          detail:
            detail(%{status: :done, flow: stage("Spec"), flow_key: "spec", finished_at: ago_s(86_400)}, [
              ne("brainstorm", 1, :succeeded)
            ]),
          number: 1
        }
      ]
    end

    defp render_list(entries, extra \\ []) do
      html = render_component(&RunComponents.run_list/1, [entries: entries, now: @now] ++ extra)
      {html, LazyHTML.from_fragment(html)}
    end

    defp texts(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))
    defp attrs(doc, selector, attr), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
    defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

    defp single(status, nes \\ [ne("implement", 1, :succeeded)], attrs \\ %{}) do
      finished = if status in Schemas.Run.terminal_statuses(), do: ago_s(60)
      [%{detail: detail(Map.merge(%{status: status, finished_at: finished}, attrs), nes), number: 1}]
    end

    test "1: label counts entries, one details per entry in order, only the head open" do
      {_html, doc} = render_list(three_entries())

      assert doc |> texts("#run-list") |> hd() =~ "RUNS · 3"
      assert attrs(doc, "details.run-entry", "id") == ["run-entry-3", "run-entry-2", "run-entry-1"]
      assert attrs(doc, "details.run-entry[open]", "id") == ["run-entry-3"]
      assert texts(doc, ".run-entry-title") == ["Run #3", "Run #2", "Run #1"]
    end

    test "2: neutral stage chip names the run's work stage, uppercased" do
      {_html, doc} = render_list(three_entries())

      assert texts(doc, ".run-entry-stage") == ["CODE", "CODE", "SPEC"]

      for style <- attrs(doc, ".run-entry-stage", "style") do
        assert style =~ "background:var(--color-base-200)"
        refute style =~ "--color-secondary"
        refute style =~ "--color-error"
        refute style =~ "--color-success"
      end
    end

    test "3: stage chip falls back to the flow key when the stage is gone" do
      {_html, doc} = render_list([%{detail: detail(%{flow_key: "design"}, []), number: 1}])

      assert texts(doc, ".run-entry-stage") == ["DESIGN"]
    end

    test "4: exactly one LATEST tag, on the head" do
      {_html, doc} = render_list(three_entries())

      assert count(doc, ".run-entry-latest") == 1
      assert texts(doc, "#run-entry-3 .run-entry-latest") == ["LATEST"]
    end

    test "5: status chips read RunStatus labels; only the running one pulses" do
      {_html, doc} = render_list(three_entries())

      assert texts(doc, ".run-entry-status") == ["Running", "Run failed", "Completed"]
      assert LazyHTML.to_html(LazyHTML.query(doc, "#run-entry-3 .run-entry-status")) =~ "animation:relaypulse"
      refute LazyHTML.to_html(LazyHTML.query(doc, "#run-entry-2 .run-entry-status")) =~ "animation:relaypulse"
      refute LazyHTML.to_html(LazyHTML.query(doc, "#run-entry-1 .run-entry-status")) =~ "animation:relaypulse"
    end

    test "6: the head is tinted by status, earlier entries are untinted" do
      {_html, doc} = render_list(three_entries())

      [head] = attrs(doc, "#run-entry-3", "style")
      assert head =~ "color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100))"
      assert head =~ "color-mix(in oklab, var(--color-secondary) 4%, var(--color-base-100))"

      for id <- ["#run-entry-2", "#run-entry-1"] do
        [style] = attrs(doc, id, "style")
        assert style =~ "border:1px solid var(--color-base-300)"
        assert style =~ "background:var(--color-base-100)"
        refute style =~ "35%"
      end
    end

    test "7: parked, done and failed heads take their role's tint" do
      for {status, token} <- [parked: "warning", done: "success", failed: "error"] do
        entries = [%{detail: detail(%{status: status, finished_at: ago_s(60)}, []), number: 2}]
        {_html, doc} = render_list(entries)
        [style] = attrs(doc, "#run-entry-2", "style")
        assert style =~ "var(--color-#{token}) 35%"
      end
    end

    test "8: running latest meta is elapsed clock and cost" do
      nes = [
        ne("branch", 1, :succeeded, %{cost: Decimal.new("2.21")}),
        ne("implement", 1, nil, %{cost: Decimal.new("2.21")})
      ]

      {_html, doc} = render_list(single(:running, nes, %{started_at: ago_s(291)}))

      assert texts(doc, ".run-entry-meta") == ["elapsed 4:51 · $4.42"]
    end

    test "9: a nil cost drops out of the meta" do
      {_html, doc} = render_list(single(:running, [ne("implement", 1, nil)], %{started_at: ago_s(291)}))

      assert texts(doc, ".run-entry-meta") == ["elapsed 4:51"]
    end

    test "10: done latest meta is finished-ago and total duration" do
      nes = [ne("implement", 1, :succeeded, %{duration_s: 300}), ne("merge", 1, :succeeded, %{duration_s: 91})]
      {_html, doc} = render_list(single(:done, nes, %{finished_at: ago_s(240)}))

      assert texts(doc, ".run-entry-meta") == ["finished 4m ago · 6:31"]
    end

    test "11: an earlier entry's meta is duration, cost and finished-ago" do
      earlier =
        detail(%{status: :done, finished_at: ago_s(7200)}, [
          ne("implement", 1, :succeeded, %{duration_s: 400, cost: Decimal.new("1.00")}),
          ne("merge", 1, :succeeded, %{duration_s: 200, cost: Decimal.new("0.37")})
        ])

      entries = [:running |> single() |> hd() |> Map.put(:number, 2), %{detail: earlier, number: 1}]
      {_html, doc} = render_list(entries)

      assert texts(doc, "#run-entry-1 .run-entry-meta") == ["10:00 · $1.37 · 2h ago"]
    end

    test "12: a done latest entry keeps its timeline and gets the stats row" do
      {_html, doc} = render_list(single(:done, [ne("implement", 1, :succeeded), ne("merge", 1, :succeeded)]))

      timeline = doc |> LazyHTML.query("#run-entry-1 .run-node-timeline") |> LazyHTML.text()
      assert timeline =~ "implement"
      assert timeline =~ "merge"

      stats = doc |> LazyHTML.query("#run-entry-1 .run-entry-stats") |> LazyHTML.text()
      for label <- ["DURATION", "NODES", "ATTEMPTS", "COST"], do: assert(stats =~ label)
    end

    test "13: a parked latest entry keeps its timeline and has no stats row" do
      {_html, doc} = render_list(single(:parked, [ne("brainstorm", 1, :needs_input)], %{current_node: "brainstorm"}))

      assert doc |> LazyHTML.query("#run-entry-1 .run-node-timeline") |> LazyHTML.text() =~ "brainstorm"
      assert count(doc, "#run-entry-1 .run-entry-stats") == 0
    end

    test "14: a running latest entry has a timeline and no stats row" do
      {_html, doc} = render_list(single(:running, [ne("implement", 1, nil)]))

      assert count(doc, "#run-entry-1 .run-node-timeline") == 1
      assert count(doc, "#run-entry-1 .run-entry-stats") == 0
    end

    test "15: earlier entries carry the stats row and the timeline" do
      {_html, doc} = render_list(three_entries())

      for id <- ["#run-entry-2", "#run-entry-1"] do
        assert count(doc, "#{id} .run-entry-stats") == 1
        assert count(doc, "#{id} .run-node-timeline") == 1
      end
    end

    test "16: the latest_body slot renders at the top of the head only" do
      assigns = %{entries: three_entries(), now: @now}

      html =
        rendered_to_string(~H"""
        <RunComponents.run_list entries={@entries} now={@now}>
          <:latest_body><span id="slot-probe">probe</span></:latest_body>
        </RunComponents.run_list>
        """)

      doc = LazyHTML.from_fragment(html)
      assert count(doc, "#run-entry-3 #slot-probe") == 1
      assert count(doc, "#run-entry-2 #slot-probe") == 0
      assert count(doc, "#run-entry-1 #slot-probe") == 0

      head_html = doc |> LazyHTML.query("#run-entry-3") |> LazyHTML.to_html()
      {probe_at, _} = :binary.match(head_html, "slot-probe")
      {timeline_at, _} = :binary.match(head_html, "run-node-timeline")
      assert probe_at < timeline_at
    end

    test "17: vX shows only when the run has a flow version" do
      entries = [
        %{detail: detail(%{flow_version: 3}, []), number: 2},
        %{detail: detail(%{status: :done, flow_version: nil, finished_at: ago_s(60)}, []), number: 1}
      ]

      {html, doc} = render_list(entries)

      assert texts(doc, "#run-entry-2 .run-entry-version") == ["v3"]
      assert count(doc, "#run-entry-1 .run-entry-version") == 0
      refute html =~ "vnil"
    end

    test "18: every entry ignores client-side open toggles across patches" do
      {_html, doc} = render_list(three_entries())

      mounted = attrs(doc, "details.run-entry", "phx-mounted")
      assert length(mounted) == 3

      for js <- mounted do
        assert js =~ "ignore_attrs"
        assert js =~ "open"
      end
    end

    test "19: a single run is the open latest entry" do
      {_html, doc} = render_list(single(:running, [ne("implement", 1, nil)]))

      assert doc |> texts("#run-list") |> hd() =~ "RUNS · 1"
      assert attrs(doc, "details.run-entry[open]", "id") == ["run-entry-1"]
      assert count(doc, "#run-entry-1 .run-entry-latest") == 1
    end

    test "20: a cancelled head keeps the primary wash" do
      {_html, doc} = render_list(single(:cancelled))

      assert texts(doc, ".run-entry-status") == ["Cancelled"]
      [style] = attrs(doc, "#run-entry-1", "style")
      assert style =~ "color-mix(in oklab, var(--color-primary) 20%, var(--color-base-100))"
    end
  end
end
