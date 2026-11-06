defmodule Storybook.RunComponents.RunFace do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &HamacaWeb.RunComponents.run_face/1
  def render_source, do: :function

  # RE513: the moments of card mockup "A — setup · one notch per task · after the tasks" — a
  # setup notch, one notch per task and the after track — then the running face's amber
  # treatments: stalled (inferred from silence) and rate limited (RE320 — reported by the
  # runner, so it outranks stalled).
  @seven %{done: 2, total: 7}

  # RE440: the card mockup's two face cards — an open fan-out region, then one with a branch
  # held back by max_parallel. No track, so the branch segment stands alone.
  @fan_out_open {:run,
                 %{
                   status: :running,
                   current_node: "fan_reviews",
                   flow_key: "code",
                   track: nil,
                   branches: %{
                     total: 3,
                     ended: 1,
                     running: 2,
                     queued: 0,
                     parked: 0,
                     succeeded: 1,
                     failed: 0,
                     bars: [:succeeded, :running, :running]
                   }
                 }}

  @fan_out_queued {:run,
                   %{
                     status: :running,
                     current_node: "fan_reviews",
                     flow_key: "code",
                     track: nil,
                     branches: %{
                       total: 3,
                       ended: 0,
                       running: 2,
                       queued: 1,
                       parked: 0,
                       succeeded: 0,
                       failed: 0,
                       bars: [:running, :running, :queued]
                     }
                   }}

  def variations do
    building = code_run("implement", track(:loop, "building", "branch"))

    [
      moment(:setup, code_run("branch", track(:setup, "branch", nil)), %{done: 0, total: 7}),
      moment(:building, building, @seven),
      moment(:fixing_review_notes, code_run("fix_findings", track(:loop, "fixing review notes", "spec_review")), @seven),
      moment(:re_reviewing, code_run("spec_review", track(:loop, "re-reviewing", "fix_findings")), @seven),
      moment(:last_task, building, %{done: 6, total: 7}),
      moment(:after_tasks, code_run("precommit", track(:after, "precommit", "implement", after_reached: 2)), %{
        done: 7,
        total: 7
      }),
      moment(:after_fix, code_run("final_fix", track(:after, "fixing smoke", "smoke", after_reached: 6)), %{
        done: 7,
        total: 7
      }),
      moment(:new_task, code_run("implement", track(:loop, "building", "spec_review", after_reached: 6)), %{
        done: 7,
        total: 8
      }),
      moment(:landing, code_run("await_ci", track(:after, "await ci", "ship", after_reached: 12)), %{done: 7, total: 7}),
      moment(:no_tasks, {:run, %{status: :running, current_node: "fly", flow_key: "deploy", track: nil}}, nil),
      %Variation{id: :stalled, attributes: %{ref: "RLY-21", run: building, tasks: @seven, stalled?: true}},
      %Variation{
        id: :rate_limited,
        attributes: %{
          ref: "RLY-22",
          run: building,
          tasks: @seven,
          rate_limited: %{resumes_at: ~U[2026-09-14 15:40:00Z]}
        }
      },
      %Variation{id: :fan_out_open, attributes: %{ref: "RLY-23", run: @fan_out_open}},
      %Variation{id: :fan_out_queued, attributes: %{ref: "RLY-24", run: @fan_out_queued}}
    ]
  end

  defp moment(id, run, tasks), do: %Variation{id: id, attributes: %{ref: "RLY-20", run: run, tasks: tasks}}

  defp code_run(current_node, track),
    do: {:run, %{status: :running, current_node: current_node, flow_key: "code", track: track}}

  # A Code-flow track: one setup node, thirteen after it. Setup is reached once the loop starts.
  defp track(zone, step, previous_node, overrides \\ []) do
    Map.merge(
      %{
        zone: zone,
        step: step,
        previous_node: previous_node,
        setup_total: 1,
        setup_reached: 1,
        after_total: 13,
        after_reached: 0
      },
      Map.new(overrides)
    )
  end
end
