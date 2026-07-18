defmodule RelayWeb.BoardRunnersLive do
  @moduledoc """
  Runners view (RLY-141) at `/board/:slug/runners` — the machine-centric instrument
  panel per `docs/designs/Relay Runners.dc.html`: one panel per connected runner
  (freshness dot + FRESH/STALE/GONE pill, capacity chips with used/total pips,
  WORKING NOW rows linking into the card drawer, dark streaming log tail), header
  summary chips, the at-risk note on a stale/gone runner with jobs, and the empty
  state naming the real `bin/relay execute` start command.

  Data comes from `Relay.RunnerPresence` (beats) and `Relay.AgentLog` (feed lines,
  routed to the runner whose *latest beat* claimed the line's ref; unclaimed and
  ref-less lines are dropped — the board's log sheet still shows everything). A ~10s
  self-tick re-derives freshness/uptime/elapsed and refetches the list: a dead
  runner emits no events, so the tick is what flips it STALE → GONE with no reload,
  and what reflects prunes.

  Log tails are a bounded per-runner ring buffer in assigns (last 30 lines per
  runner), NOT a LiveView stream — a deliberate, documented deviation from the
  streams-for-collections default: the lines render grouped inside per-runner panels
  and are hard-capped, so the stream machinery buys nothing and the cap bounds
  memory. Runner panels are likewise re-derived wholesale from ETS on every event —
  a board has a handful of runners, not thousands.
  """

  use RelayWeb, :live_view

  alias Relay.AgentLog
  alias Relay.Boards
  alias Relay.RunnerPresence

  @tick_every to_timeout(second: 10)
  @log_cap 30

  # Artboard palette (Relay Runners.dc.html, renderVals constants).
  @green "oklch(0.60 0.13 155)"
  @amber "oklch(0.70 0.13 65)"
  @rose "oklch(0.62 0.16 22)"
  @violet "oklch(0.56 0.16 292)"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide crumb>
      <:title>
        <span id="runners-title">Runners</span>
      </:title>
      <:actions>
        <.link
          navigate={~p"/board/#{@board.slug}"}
          id="runners-back"
          class="btn btn-sm border-none font-semibold text-white"
          style="background:oklch(0.60 0.14 250);"
        >
          Back to board
        </.link>
      </:actions>
      <div id="runners-page" style="background:oklch(0.955 0.008 255);min-height:calc(100vh - 74px);">
        <div style="max-width:1120px;margin:0 auto;padding:30px 28px 72px 28px;">
          <%= if @runners == [] do %>
            <%!-- Empty state — artboard lines ~139-157; command is bin/relay execute on
                 purpose (spec §6: npx relay-runner doesn't exist yet; RLY-139 retired the
                 legacy bin/relay watch board-runner this used to name). --%>
            <div
              id="runners-empty"
              style="display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:62vh;text-align:center;"
            >
              <div style="width:56px;height:56px;border-radius:16px;background:oklch(0.97 0.004 255);border:1px solid oklch(0.92 0.006 255);display:flex;align-items:center;justify-content:center;margin-bottom:20px;position:relative;">
                <div style="width:20px;height:20px;border-radius:50%;border:2px dashed oklch(0.72 0.02 255);">
                </div>
                <div style="position:absolute;bottom:-6px;right:-6px;width:20px;height:20px;border-radius:50%;background:oklch(0.98 0.03 22);border:1px solid oklch(0.90 0.05 22);display:flex;align-items:center;justify-content:center;font-size:11px;color:oklch(0.55 0.16 22);">
                  !
                </div>
              </div>
              <h2 style="font-size:21px;font-weight:600;letter-spacing:-0.02em;margin:0 0 8px 0;color:oklch(0.26 0.02 255);">
                No runners connected
              </h2>
              <p style="font-size:14px;line-height:1.6;color:oklch(0.50 0.02 255);margin:0 0 26px 0;max-width:440px;">
                Cards will queue until a runner checks in. Start one on any dev machine:
              </p>
              <div style="display:flex;align-items:center;gap:10px;background:oklch(0.20 0.02 255);border-radius:11px;padding:13px 15px;box-shadow:0 8px 24px oklch(0.4 0.03 255/0.12);">
                <span
                  id="runner-start-command"
                  class="font-mono"
                  style="font-size:12.5px;color:oklch(0.85 0.02 255);"
                >
                  <span style="color:oklch(0.60 0.10 155);">$</span> bin/relay execute
                </span>
                <button
                  type="button"
                  id="copy-start-command"
                  phx-hook=".CopyCmd"
                  data-command="bin/relay execute"
                  class="font-mono"
                  style="background:oklch(0.30 0.02 255);border:1px solid oklch(0.40 0.02 255);color:oklch(0.82 0.02 255);border-radius:7px;padding:6px 11px;font-size:11.5px;font-weight:600;"
                >
                  Copy
                </button>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCmd">
                  export default {
                    mounted() {
                      this.el.addEventListener("click", () => {
                        navigator.clipboard.writeText(this.el.dataset.command)
                        const label = this.el.dataset.label || this.el.textContent.trim()
                        this.el.dataset.label = label
                        this.el.textContent = "Copied ✓"
                        clearTimeout(this._t)
                        this._t = setTimeout(() => { this.el.textContent = label }, 1600)
                      })
                    }
                  }
                </script>
              </div>
              <div style="display:flex;align-items:center;gap:9px;margin-top:22px;">
                <span
                  class="animate-spin"
                  style="display:inline-block;width:15px;height:15px;border-radius:50%;border:2px solid oklch(0.85 0.02 255);border-top-color:oklch(0.60 0.14 250);"
                >
                </span>
                <span class="font-mono" style="font-size:12.5px;color:oklch(0.56 0.02 255);">
                  Waiting for a heartbeat…
                </span>
              </div>
            </div>
          <% else %>
            <%!-- Page header + summary chips — artboard lines ~57-66. --%>
            <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin-bottom:6px;">
              <div>
                <h1 style="font-size:24px;font-weight:600;letter-spacing:-0.025em;margin:0 0 6px 0;color:oklch(0.24 0.02 255);">
                  Runners
                </h1>
                <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0;max-width:600px;">
                  Runners are the machines that work this board's cards. Relay hands each card to
                  a runner with a free slot in the right pool. This is the instrument you open
                  when nothing is running.
                </p>
              </div>
              <div id="runners-summary" style="display:flex;gap:8px;flex:0 0 auto;padding-top:4px;">
                <span
                  :if={@summary.fresh > 0}
                  id="summary-fresh"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:oklch(0.46 0.10 155);background:oklch(0.97 0.03 155);border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:oklch(0.60 0.13 155);">
                  </span>
                  {@summary.fresh} online
                </span>
                <span
                  :if={@summary.stale > 0}
                  id="summary-stale"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:oklch(0.50 0.10 65);background:oklch(0.98 0.03 75);border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:oklch(0.70 0.13 65);">
                  </span>
                  {@summary.stale} stale
                </span>
                <span
                  :if={@summary.gone > 0}
                  id="summary-gone"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:oklch(0.52 0.16 22);background:oklch(0.97 0.03 22);border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:oklch(0.62 0.16 22);">
                  </span>
                  {@summary.gone} gone
                </span>
              </div>
            </div>

            <div style="display:flex;flex-direction:column;gap:16px;margin-top:24px;">
              <div
                :for={runner <- @runners}
                id={"runner-#{dom_id(runner)}"}
                style={panel_style(runner.freshness)}
              >
                <%!-- Panel header — artboard lines ~72-79. --%>
                <div style="display:flex;align-items:center;gap:12px;padding:14px 18px;border-bottom:1px solid oklch(0.94 0.005 255);">
                  <span
                    class={["inline-block", runner.freshness == :fresh && "animate-pulse"]}
                    style={fresh_dot_style(runner.freshness)}
                  >
                  </span>
                  <span
                    class="font-mono"
                    style={"font-size:15px;font-weight:600;letter-spacing:-0.01em;color:#{name_color(runner.freshness)};"}
                  >
                    {runner.host}
                  </span>
                  <span
                    class={["badge badge-sm font-mono font-bold", pill_class(runner.freshness)]}
                    style="font-size:9.5px;letter-spacing:0.06em;"
                  >
                    {pill_label(runner.freshness)}
                  </span>
                  <span style="flex:1;"></span>
                  <span class="font-mono" style="font-size:11.5px;color:oklch(0.58 0.02 255);">
                    {runner.runner_id}
                  </span>
                  <span class="font-mono" style="font-size:11.5px;color:oklch(0.58 0.02 255);">
                    {uptime_label(runner, @now)}
                  </span>
                </div>
                <div style={"display:flex;align-items:stretch;#{if runner.freshness != :fresh, do: "opacity:0.92;"}"}>
                  <div style="flex:1;min-width:0;padding:15px 18px;display:flex;flex-direction:column;gap:16px;">
                    <%!-- Capacity chips — artboard capChip, lines ~84-97 / 176-187. --%>
                    <div style="display:flex;flex-direction:column;gap:8px;">
                      <span
                        class="font-mono"
                        style="font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:oklch(0.60 0.02 255);"
                      >
                        CAPACITY
                      </span>
                      <div style="display:flex;gap:8px;flex-wrap:wrap;">
                        <div
                          :for={pool <- runner.pools}
                          id={"runner-#{dom_id(runner)}-pool-#{pool.name}"}
                          style={cap_chip_style(pool, runner.freshness)}
                        >
                          <span class="font-mono" style="font-size:11px;font-weight:600;">
                            {pool.name}
                          </span>
                          <span style="display:flex;gap:3px;">
                            <span :for={i <- pips(pool)} style={pip_style(i, pool, runner.freshness)}>
                            </span>
                          </span>
                          <span class="font-mono" style="font-size:11px;">
                            {pool.used}/{pool.total}
                          </span>
                        </div>
                      </div>
                    </div>
                    <%!-- Working-now list — artboard lines ~98-115. --%>
                    <div style="display:flex;flex-direction:column;gap:8px;">
                      <span
                        class="font-mono"
                        style="font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:oklch(0.60 0.02 255);"
                      >
                        {working_label(runner)}
                      </span>
                      <div
                        :for={job <- runner.jobs}
                        id={"runner-#{dom_id(runner)}-job-#{job.ref}"}
                        style={job_row_style(runner.freshness)}
                      >
                        <span
                          class={["inline-block", runner.freshness == :fresh && "animate-pulse"]}
                          style={job_dot_style(runner.freshness)}
                        >
                        </span>
                        <.link
                          navigate={~p"/board/#{@board.slug}?card=#{job.ref}"}
                          class="font-mono"
                          style={"font-size:12px;font-weight:600;color:#{ref_color(runner.freshness)};"}
                        >
                          {job.ref}
                        </.link>
                        <span style="font-size:12px;color:oklch(0.46 0.02 255);flex:1;min-width:0;">
                          {job.stage}
                        </span>
                        <span
                          :if={job.pool}
                          class="font-mono"
                          style="font-size:9.5px;font-weight:600;color:oklch(0.50 0.02 255);background:oklch(0.96 0.004 255);border-radius:4px;padding:2px 6px;white-space:nowrap;"
                        >
                          {job.pool}
                        </span>
                        <span class="font-mono" style="font-size:11px;color:oklch(0.52 0.02 255);">
                          {elapsed_label(job.started_at, @now)}
                        </span>
                      </div>
                      <%!-- At-risk note (spec's copy correction: shared requeues, exclusive
                           parks) — artboard lines ~109-114. --%>
                      <div
                        :if={runner.freshness != :fresh and runner.jobs != []}
                        id={"runner-#{dom_id(runner)}-at-risk"}
                        style="display:flex;align-items:center;gap:8px;background:oklch(0.98 0.03 75);border:1px solid oklch(0.90 0.05 75);border-radius:8px;padding:9px 11px;margin-top:2px;"
                      >
                        <span style="font-size:12px;color:oklch(0.55 0.13 65);">⚠</span>
                        <span style="font-size:12px;line-height:1.45;color:oklch(0.48 0.10 65);">
                          No heartbeat for <b class="font-mono">{beat_age(runner, @now)}</b>
                          — going stale. Jobs in shared pools are requeued to another runner;
                          exclusive runs park until it returns (affinity).
                        </span>
                      </div>
                    </div>
                  </div>
                  <%!-- Log tail — artboard lines ~118-131, dark terminal treatment. --%>
                  <div
                    id={"runner-#{dom_id(runner)}-log"}
                    style={"flex:1.15;min-width:0;background:oklch(0.19 0.02 255);display:flex;flex-direction:column;#{if runner.freshness != :fresh, do: "opacity:0.75;"}"}
                  >
                    <div style="display:flex;align-items:center;gap:7px;padding:9px 13px;border-bottom:1px solid oklch(0.30 0.02 255);">
                      <span
                        class={["inline-block", streaming?(runner) && "animate-pulse"]}
                        style={"width:7px;height:7px;border-radius:50%;background:#{log_dot_color(runner.freshness)};"}
                      >
                      </span>
                      <span
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.06em;color:oklch(0.70 0.02 255);"
                      >
                        {log_title(runner.freshness)}
                      </span>
                    </div>
                    <div
                      class="font-mono"
                      style="flex:1;padding:11px 13px;font-size:11px;line-height:1.7;overflow:hidden;"
                    >
                      <div
                        :for={entry <- Enum.reverse(Map.get(@logs, runner.runner_id, []))}
                        style="white-space:pre-wrap;"
                      >
                        <span style="color:oklch(0.55 0.02 255);">
                          {Calendar.strftime(entry.ts, "%H:%M:%S")}
                        </span>
                        <span style={"color:#{log_color(entry.kind)};"}>
                          [{entry.ref}] {entry.text}
                        </span>
                      </div>
                      <span
                        :if={streaming?(runner)}
                        id={"runner-#{dom_id(runner)}-cursor"}
                        class="animate-pulse"
                        style="display:inline-block;width:7px;height:13px;background:oklch(0.75 0.14 155);margin-left:2px;vertical-align:-2px;"
                      >
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    board = Boards.get_board!(socket.assigns.current_scope.user, slug)

    if connected?(socket) do
      RunnerPresence.subscribe(board.id)
      AgentLog.subscribe(board.id)
      Process.send_after(self(), :tick, @tick_every)
    end

    {:ok,
     socket
     |> assign(:page_title, "Runners")
     |> assign(:board, board)
     |> assign(:logs, %{})
     |> assign_runners()}
  end

  @impl true
  def handle_info({:runner_beat, _runner}, socket), do: {:noreply, assign_runners(socket)}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_every)
    {:noreply, assign_runners(socket)}
  end

  def handle_info({:agent_log, %{ref: nil}}, socket), do: {:noreply, socket}

  def handle_info({:agent_log, entry}, socket) do
    case socket.assigns.ref_owner[entry.ref] do
      nil ->
        {:noreply, socket}

      runner_id ->
        {:noreply,
         update(socket, :logs, fn logs ->
           Map.update(logs, runner_id, [entry], &Enum.take([entry | &1], @log_cap))
         end)}
    end
  end

  # Re-derives everything time- and presence-dependent in one place: the runner
  # list (freshness-augmented), the summary counts, the ref → runner routing map,
  # and drops log buffers for pruned runners. Cheap by construction — a board has
  # a handful of runners.
  defp assign_runners(socket) do
    now = DateTime.utc_now()

    runners =
      socket.assigns.board.id
      |> RunnerPresence.list()
      |> Enum.map(&Map.put(&1, :freshness, RunnerPresence.freshness(&1, now)))

    counts = Enum.frequencies_by(runners, & &1.freshness)
    ids = Enum.map(runners, & &1.runner_id)

    socket
    |> assign(:now, now)
    |> assign(:runners, runners)
    |> assign(:summary, %{fresh: counts[:fresh] || 0, stale: counts[:stale] || 0, gone: counts[:gone] || 0})
    |> assign(:ref_owner, for(runner <- runners, ref <- runner.refs, into: %{}, do: {ref, runner.runner_id}))
    |> update(:logs, &Map.take(&1, ids))
  end

  # Hostnames can contain dots ("mbp.local"), which are legal in DOM ids but break
  # CSS #id selectors — sanitize for the id only; @logs stays keyed by the raw id.
  defp dom_id(%{runner_id: runner_id}), do: String.replace(runner_id, ~r/[^A-Za-z0-9_-]/, "-")

  defp streaming?(runner), do: runner.freshness == :fresh and runner.jobs != []

  defp panel_style(freshness) do
    border =
      case freshness do
        :fresh -> "oklch(0.92 0.006 255)"
        :stale -> "oklch(0.90 0.05 75)"
        :gone -> "oklch(0.90 0.03 22)"
      end

    "background:oklch(1 0 0);border:1px solid #{border};border-radius:13px;overflow:hidden;" <>
      "box-shadow:0 1px 3px oklch(0.55 0.03 255/0.05);"
  end

  defp fresh_color(:fresh), do: @green
  defp fresh_color(:stale), do: @amber
  defp fresh_color(:gone), do: @rose

  defp fresh_dot_style(freshness) do
    glow = if freshness == :fresh, do: "box-shadow:0 0 0 3px oklch(0.60 0.13 155 / 0.2);", else: ""
    "width:10px;height:10px;border-radius:50%;background:#{fresh_color(freshness)};flex:0 0 auto;#{glow}"
  end

  defp pill_class(:fresh), do: "badge-success"
  defp pill_class(:stale), do: "badge-warning"
  defp pill_class(:gone), do: "badge-error"

  defp pill_label(:fresh), do: "FRESH"
  defp pill_label(:stale), do: "STALE"
  defp pill_label(:gone), do: "GONE"

  defp name_color(:fresh), do: "oklch(0.24 0.02 255)"
  defp name_color(_freshness), do: "oklch(0.50 0.02 255)"

  defp ref_color(:gone), do: "oklch(0.52 0.12 22)"
  defp ref_color(_freshness), do: "oklch(0.30 0.02 255)"

  defp cap_chip_style(pool, freshness) do
    {border, bg, color, extra} =
      cond do
        freshness != :fresh ->
          {"oklch(0.92 0.006 255)", "oklch(0.98 0.003 255)", "oklch(0.58 0.02 255)", "opacity:0.7;"}

        pool.used >= pool.total ->
          {"oklch(0.89 0.05 65)", "oklch(0.99 0.02 75)", "oklch(0.38 0.02 255)", ""}

        true ->
          {"oklch(0.90 0.04 155)", "oklch(0.99 0.015 155)", "oklch(0.38 0.02 255)", ""}
      end

    "display:flex;align-items:center;gap:8px;border:1px solid #{border};background:#{bg};" <>
      "border-radius:8px;padding:7px 11px;color:#{color};#{extra}"
  end

  defp pips(%{total: total}), do: Enum.to_list(0..(total - 1)//1)

  defp pip_style(i, pool, freshness) do
    fill =
      cond do
        i >= pool.used -> "oklch(0.90 0.01 255)"
        freshness != :fresh -> "oklch(0.72 0.02 255)"
        pool.used >= pool.total -> @amber
        true -> @green
      end

    "width:8px;height:8px;border-radius:2px;background:#{fill};"
  end

  defp working_label(%{freshness: :fresh} = runner), do: "WORKING NOW · #{length(runner.jobs)}"
  defp working_label(%{jobs: []}), do: "WORKING NOW · 0"
  defp working_label(%{freshness: :stale}), do: "AT-RISK JOB"
  defp working_label(%{freshness: :gone}), do: "ORPHANED JOB"

  defp job_row_style(:fresh) do
    "display:flex;align-items:center;gap:10px;border:1px solid oklch(0.94 0.005 255);" <>
      "background:oklch(0.994 0.002 255);border-radius:8px;padding:8px 11px;"
  end

  defp job_row_style(_freshness) do
    "display:flex;align-items:center;gap:10px;border:1px solid oklch(0.92 0.03 22);" <>
      "background:oklch(0.99 0.01 22);border-radius:8px;padding:8px 11px;"
  end

  defp job_dot_style(:fresh), do: "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{@violet};"
  defp job_dot_style(_freshness), do: "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{@rose};"

  defp log_dot_color(:fresh), do: "oklch(0.75 0.14 155)"
  defp log_dot_color(:stale), do: @amber
  defp log_dot_color(:gone), do: @rose

  defp log_title(:fresh), do: "LOG TAIL · streaming"
  defp log_title(:stale), do: "LOG TAIL · stalled"
  defp log_title(:gone), do: "LOG TAIL · stopped"

  defp log_color(:claude), do: "oklch(0.66 0.12 292)"
  defp log_color(:error), do: "oklch(0.68 0.14 22)"
  defp log_color(_kind), do: "oklch(0.78 0.02 255)"

  defp uptime_label(%{freshness: :fresh} = runner, now),
    do: "up " <> duration_label(DateTime.diff(now, runner.started_at))

  defp uptime_label(runner, now), do: "last beat " <> beat_age(runner, now) <> " ago"

  defp beat_age(runner, now) do
    seconds = max(DateTime.diff(now, runner.last_beat_at), 0)
    "#{div(seconds, 60)}m #{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}s"
  end

  defp duration_label(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"

  defp duration_label(seconds) when seconds >= 3600, do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp duration_label(seconds), do: "#{div(max(seconds, 0), 60)}m"

  defp elapsed_label(nil, _now), do: "—"

  defp elapsed_label(started_at, now) do
    seconds = max(DateTime.diff(now, started_at), 0)

    if seconds >= 3600 do
      "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    else
      "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
    end
  end
end
