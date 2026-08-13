defmodule RelayWeb.BoardRunnersLive do
  @moduledoc """
  Runners view (RLY-141) at `/board/:slug/runners` — the machine-centric instrument
  panel per `docs/designs/Relay Runners.dc.html`: one panel per connected runner
  (dot + FRESH/STALE/GONE/OUTDATED pill, capacity chips with used/total pips, WORKING NOW rows
  linking into the card drawer, dark streaming log tail), header summary chips, the at-risk
  note on a stale/gone runner with jobs, and the empty state naming the real
  `bin/relay execute` start command.

  RLY-191: `OUTDATED` is a top-level `display_state` (precedence
  `:gone > :stale > :outdated > :fresh`), replacing the FRESH pill/dot rather than sitting
  beside it (RLY-184's additive badge) — a refusing executor must not read as healthy. This is
  new design ground `docs/designs/Relay Runners.dc.html` does not cover (RLY-184 added the
  version surface beyond the artboard; RLY-191 promotes it to a fourth freshness state) — filed
  back to the Design project as a follow-up, not blocking here.

  RE307 adds a board-wide QUEUE section above the runner panels: every `queued` or `claimed`
  node job on the board from `Relay.Runs.list_queue/2`, both kinds (`:node` and `:talk`),
  claimed or not, in the order the server will hand them out. It renders on BOTH sides of the
  `@runners == []` branch on purpose — the moment a human most needs to see six jobs stacked up
  is the moment no runner is connected to work them. Like RLY-191's `OUTDATED` pill this is new
  design ground (`docs/designs/Relay Runners.dc.html` has no queue section), built from the
  artboard's existing vocabulary and filed back to the Design project as a follow-up, not
  blocking here.

  `Relay.Runs.stopped_work/2` on the 10s tick is deliberate and cheap: it returns `nil` after one
  aggregate (`queued_jobs_summary/1`) whenever nothing is queued, and only builds a scheduler
  snapshot when jobs are genuinely queued — i.e. exactly when the answer matters.

  Data comes from `Relay.Runs.list_executor_status/2` (the durable `executors` rows plus
  the board's active `node_jobs`) and `Relay.AgentLog` (feed lines, routed to the executor
  holding the line's ref; unclaimed and ref-less lines are dropped — the board's log sheet
  still shows everything). RLY-167 swapped the source off the old ETS presence table, which
  lost its only writer when RLY-139 deleted `relay watch`; because the roster is now a pure
  function of Postgres, the page also survives an app restart (`Relay.Runs.Capacity` is ETS
  and scheduler-only — a page backed by it would go blank on every deploy).

  A ~10s self-tick is the ONLY refresh mechanism and is load-bearing, not laziness: an
  executor going silent emits no event by definition, so freshness decay is observable only
  by polling. A 10s tick against a 15–30s beat is ample.

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
  alias Relay.Runs
  alias RelayWeb.RunComponents

  @tick_every to_timeout(second: 10)
  @log_cap 30

  # Artboard palette (Relay Runners.dc.html, renderVals constants). RE237: re-expressed as
  # theme tokens — each is exactly its role's light-theme value.
  @green "var(--color-success)"
  @amber "var(--color-warning)"
  @rose "var(--color-error)"
  @violet "var(--color-secondary)"

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
          class="btn btn-sm btn-primary font-semibold"
        >
          Back to board
        </.link>
      </:actions>
      <div
        id="runners-page"
        style="background:var(--color-base-200);min-height:calc(100vh - 74px);"
      >
        <div style="max-width:1120px;margin:0 auto;padding:30px 28px 72px 28px;">
          <%!-- QUEUE (RE307) — the board's pending + in-flight work, deliberately ABOVE the
                `@runners == []` branch so it renders whether or not a runner is connected.
                No artboard governs this section (see moduledoc); it reuses the page's own
                panel / row / pill vocabulary. --%>
          <div id="queue-section" style={queue_panel_style()}>
            <div style="display:flex;flex-direction:column;gap:8px;padding:15px 18px;">
              <span
                id="queue-label"
                class="font-mono"
                style="font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
              >
                QUEUE · {length(@queue)}
              </span>
              <RunComponents.stopped_work_banner
                :if={@stopped_work}
                id="queue-diagnosis"
                verdict={@stopped_work}
              />
              <%!-- Rows wear the artboard's job-row frame (`job_row_style/1`'s neutral `:fresh`
                    face — a board-wide queue has no runner freshness of its own); queued vs
                    claimed is carried by the dot and the pill. --%>
              <div :for={row <- @queue} id={"queue-job-#{row.job_id}"} style={job_row_style(:fresh)}>
                <span style={queue_dot_style(row.state)}></span>
                <span
                  class={["badge badge-sm font-mono font-bold", queue_pill_class(row.state)]}
                  style="font-size:9.5px;letter-spacing:0.06em;"
                >
                  {queue_pill_label(row.state)}
                </span>
                <span class="font-mono" style={chip_style()}>{kind_label(row.kind)}</span>
                <.link
                  navigate={~p"/board/#{@board.slug}?card=#{row.ref}"}
                  class="font-mono"
                  style="font-size:12px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"
                >
                  {row.ref}
                </.link>
                <span style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
                  {row.title}
                </span>
                <span class="font-mono" style={chip_style()}>{row.node_key}</span>
                <span
                  :if={row.flow_key}
                  id={"queue-job-#{row.job_id}-flow"}
                  class="font-mono"
                  style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                >
                  {row.flow_key}
                </span>
                <span
                  class="font-mono"
                  style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                >
                  {row.isolation || "—"}
                </span>
                <span
                  class="font-mono"
                  style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
                >
                  {elapsed_label(row.age_s)}
                </span>
                <span
                  :if={row.state == :claimed}
                  class="font-mono"
                  style="font-size:11px;white-space:nowrap;color:color-mix(in oklab, var(--color-secondary) 55%, var(--color-base-content));"
                >
                  → {row.executor_name}
                </span>
              </div>
              <div
                :if={@queue == []}
                id="queue-empty"
                style="font-size:12.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
              >
                Nothing queued or running.
              </div>
            </div>
          </div>
          <%= if @runners == [] do %>
            <%!-- Empty state — artboard lines ~139-157; command is bin/relay execute on
                 purpose (spec §6: npx relay-runner doesn't exist yet; RLY-139 retired the
                 legacy bin/relay watch board-runner this used to name). --%>
            <div
              id="runners-empty"
              style="display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:auto;padding:32px 0;text-align:center;"
            >
              <div style="width:56px;height:56px;border-radius:16px;background:var(--color-field-hover);border:1px solid var(--color-base-300);display:flex;align-items:center;justify-content:center;margin-bottom:20px;position:relative;">
                <div style="width:20px;height:20px;border-radius:50%;border:2px dashed color-mix(in oklab, var(--color-base-content) 40%, var(--color-base-100));">
                </div>
                <div style="position:absolute;bottom:-6px;right:-6px;width:20px;height:20px;border-radius:50%;background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-error) 25%, var(--color-base-100));display:flex;align-items:center;justify-content:center;font-size:11px;color:color-mix(in oklab, var(--color-error) 80%, var(--color-base-content));">
                  !
                </div>
              </div>
              <h2 style="font-size:21px;font-weight:600;letter-spacing:-0.02em;margin:0 0 8px 0;color:var(--color-base-content);">
                No runners connected
              </h2>
              <p style="font-size:14px;line-height:1.6;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin:0 0 26px 0;max-width:440px;">
                Cards will queue until a runner checks in. Start one on any dev machine:
              </p>
              <div style="display:flex;align-items:center;gap:10px;background:var(--color-neutral);border-radius:11px;padding:13px 15px;box-shadow:0 8px 24px color-mix(in oklab, var(--color-neutral) 12%, transparent);">
                <span
                  id="runner-start-command"
                  class="font-mono"
                  style="font-size:12.5px;color:color-mix(in oklab, var(--color-neutral-content) 85%, transparent);"
                >
                  <span style="color:var(--color-success);">$</span> bin/relay execute
                </span>
                <button
                  type="button"
                  id="copy-start-command"
                  phx-hook=".CopyCmd"
                  data-command="bin/relay execute"
                  class="font-mono"
                  style="background:color-mix(in oklab, var(--color-neutral-content) 15%, var(--color-neutral));border:1px solid color-mix(in oklab, var(--color-neutral-content) 25%, var(--color-neutral));color:color-mix(in oklab, var(--color-neutral-content) 80%, transparent);border-radius:7px;padding:6px 11px;font-size:11.5px;font-weight:600;"
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
                  style="display:inline-block;width:15px;height:15px;border-radius:50%;border:2px solid color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100));border-top-color:var(--color-primary);"
                >
                </span>
                <span
                  class="font-mono"
                  style="font-size:12.5px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
                >
                  Waiting for a heartbeat…
                </span>
              </div>
            </div>
          <% else %>
            <%!-- Page header + summary chips — artboard lines ~57-66. --%>
            <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin-bottom:6px;">
              <div>
                <h1 style="font-size:24px;font-weight:600;letter-spacing:-0.025em;margin:0 0 6px 0;color:var(--color-base-content);">
                  Runners
                </h1>
                <p style="font-size:14px;line-height:1.55;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);margin:0;max-width:600px;">
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
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:color-mix(in oklab, var(--color-success) 60%, var(--color-base-content));background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:var(--color-success);">
                  </span>
                  {@summary.fresh} online
                </span>
                <span
                  :if={@summary.stale > 0}
                  id="summary-stale"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:var(--color-warning);">
                  </span>
                  {@summary.stale} stale
                </span>
                <span
                  :if={@summary.gone > 0}
                  id="summary-gone"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));background:color-mix(in oklab, var(--color-error) 10%, var(--color-base-100));border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:var(--color-error);">
                  </span>
                  {@summary.gone} gone
                </span>
                <span
                  :if={@summary.outdated > 0}
                  id="summary-outdated"
                  class="font-mono"
                  style="display:flex;align-items:center;gap:6px;font-size:11.5px;color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content));background:color-mix(in oklab, var(--color-error) 10%, var(--color-base-100));border-radius:6px;padding:5px 10px;"
                >
                  <span style="width:7px;height:7px;border-radius:50%;background:var(--color-error);">
                  </span>
                  {@summary.outdated} outdated
                </span>
              </div>
            </div>

            <div style="display:flex;flex-direction:column;gap:16px;margin-top:24px;">
              <div
                :for={runner <- @runners}
                id={"runner-#{dom_id(runner)}"}
                style={panel_style(runner.display_state)}
              >
                <%!-- Panel header — artboard lines ~72-79. --%>
                <div style="display:flex;align-items:center;gap:12px;padding:14px 18px;border-bottom:1px solid var(--color-base-300);">
                  <span
                    class={["inline-block", runner.display_state == :fresh && "animate-pulse"]}
                    style={fresh_dot_style(runner.display_state)}
                  >
                  </span>
                  <span
                    class="font-mono"
                    style={"font-size:15px;font-weight:600;letter-spacing:-0.01em;color:#{name_color(runner.display_state)};"}
                  >
                    {runner.name}
                  </span>
                  <span
                    class={["badge badge-sm font-mono font-bold", pill_class(runner.display_state)]}
                    style="font-size:9.5px;letter-spacing:0.06em;"
                  >
                    {pill_label(runner.display_state)}
                  </span>
                  <span style="flex:1;"></span>
                  <span
                    id={"runner-#{dom_id(runner)}-version"}
                    class="font-mono"
                    style="font-size:11.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                  >
                    {version_label(runner)}
                  </span>
                  <span
                    class="font-mono"
                    style="font-size:11.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                  >
                    {runner.host}
                  </span>
                  <span
                    class="font-mono"
                    style="font-size:11.5px;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                  >
                    {last_seen_label(runner, @now)}
                  </span>
                </div>
                <div style={"display:flex;align-items:stretch;#{if runner.freshness != :fresh, do: "opacity:0.92;"}"}>
                  <div style="flex:1;min-width:0;padding:15px 18px;display:flex;flex-direction:column;gap:16px;">
                    <%!-- Capacity chips — artboard capChip, lines ~84-97 / 176-187. --%>
                    <div style="display:flex;flex-direction:column;gap:8px;">
                      <span
                        class="font-mono"
                        style="font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
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
                        style="font-size:9.5px;font-weight:600;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);"
                      >
                        {working_label(runner)}
                      </span>
                      <div
                        :for={job <- runner.jobs}
                        id={"runner-#{dom_id(runner)}-job-#{job.job_id}"}
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
                        <span style="font-size:12px;color:color-mix(in oklab, var(--color-base-content) 75%, transparent);flex:1;min-width:0;">
                          {job.title}
                        </span>
                        <span class="font-mono" style={chip_style()}>
                          {job.node_key}
                        </span>
                        <span
                          class="font-mono"
                          style="font-size:11px;color:color-mix(in oklab, var(--color-base-content) 65%, transparent);"
                        >
                          {elapsed_label(job.claimed_at, @now)}
                        </span>
                      </div>
                      <%!-- At-risk note (spec's copy correction: shared requeues, exclusive
                           parks) — artboard lines ~109-114. --%>
                      <div
                        :if={runner.freshness != :fresh and runner.jobs != []}
                        id={"runner-#{dom_id(runner)}-at-risk"}
                        style="display:flex;align-items:center;gap:8px;background:color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 35%, var(--color-base-100));border-radius:8px;padding:9px 11px;margin-top:2px;"
                      >
                        <span style="font-size:12px;color:color-mix(in oklab, var(--color-warning) 65%, var(--color-base-content));">
                          ⚠
                        </span>
                        <span style="font-size:12px;line-height:1.45;color:color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content));">
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
                    style={"flex:1.15;min-width:0;background:var(--color-neutral);display:flex;flex-direction:column;#{if runner.freshness != :fresh, do: "opacity:0.75;"}"}
                  >
                    <div style="display:flex;align-items:center;gap:7px;padding:9px 13px;border-bottom:1px solid color-mix(in oklab, var(--color-neutral-content) 15%, var(--color-neutral));">
                      <span
                        class={["inline-block", streaming?(runner) && "animate-pulse"]}
                        style={"width:7px;height:7px;border-radius:50%;background:#{log_dot_color(runner.freshness)};"}
                      >
                      </span>
                      <span
                        class="font-mono"
                        style="font-size:10px;font-weight:600;letter-spacing:0.06em;color:color-mix(in oklab, var(--color-neutral-content) 65%, transparent);"
                      >
                        {log_title(runner.freshness)}
                      </span>
                    </div>
                    <div
                      class="font-mono"
                      style="flex:1;padding:11px 13px;font-size:11px;line-height:1.7;overflow:hidden;"
                    >
                      <div
                        :for={entry <- Enum.reverse(Map.get(@logs, runner.name, []))}
                        style="white-space:pre-wrap;"
                      >
                        <span style="color:color-mix(in oklab, var(--color-neutral-content) 45%, transparent);">
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
                        style="display:inline-block;width:7px;height:13px;background:color-mix(in oklab, var(--color-success) 60%, var(--color-neutral-content));margin-left:2px;vertical-align:-2px;"
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

  # Re-derives everything time- and roster-dependent in one place: the executor list
  # (freshness-augmented by the context), the board-wide queue and its stopped-work verdict, the
  # summary counts, the ref → executor routing map, and drops log buffers for executors that fell
  # off the roster. One `now` for the whole pass, so the roster and the queue can never disagree
  # about the clock.
  defp assign_runners(socket) do
    now = DateTime.utc_now()
    board = socket.assigns.board
    runners = Runs.list_executor_status(board, now)

    counts = Enum.frequencies_by(runners, & &1.display_state)
    names = Enum.map(runners, & &1.name)

    socket
    |> assign(:now, now)
    |> assign(:runners, runners)
    |> assign(:queue, Runs.list_queue(board, now))
    |> assign(:stopped_work, Runs.stopped_work(board, now))
    |> assign(:summary, %{
      fresh: counts[:fresh] || 0,
      stale: counts[:stale] || 0,
      gone: counts[:gone] || 0,
      outdated: counts[:outdated] || 0
    })
    |> assign(:ref_owner, for(runner <- runners, job <- runner.jobs, into: %{}, do: {job.ref, runner.name}))
    |> update(:logs, &Map.take(&1, names))
  end

  # Executor names can contain dots ("mac.local"), which are legal in DOM ids but break
  # CSS #id selectors — sanitize for the id only; @logs stays keyed by the raw name.
  defp dom_id(%{name: name}), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  defp streaming?(runner), do: runner.freshness == :fresh and runner.jobs != []

  # `:outdated` shares :gone's rose border — a refusing executor must not read as healthy,
  # even though (unlike :gone) it is genuinely beating.
  defp panel_style(:outdated), do: panel_style(:gone)

  defp panel_style(freshness) do
    border =
      case freshness do
        :fresh -> "var(--color-base-300)"
        :stale -> "color-mix(in oklab, var(--color-warning) 35%, var(--color-base-100))"
        :gone -> "color-mix(in oklab, var(--color-error) 25%, var(--color-base-100))"
      end

    "background:var(--color-base-100);border:1px solid #{border};border-radius:13px;overflow:hidden;" <>
      "box-shadow:0 1px 3px color-mix(in oklab, var(--color-neutral) 5%, transparent);"
  end

  # The queue borrows the artboard's runner-panel frame (13px radius, base-300 border);
  # `:fresh` IS that neutral treatment — a board-wide queue has no freshness of its own.
  defp queue_panel_style, do: panel_style(:fresh) <> "margin-bottom:20px;"

  defp fresh_color(:fresh), do: @green
  defp fresh_color(:stale), do: @amber
  defp fresh_color(:gone), do: @rose
  # RLY-191: rose, matching :gone's hue — no glow (fresh_dot_style/1 only glows for :fresh).
  defp fresh_color(:outdated), do: @rose

  defp fresh_dot_style(freshness) do
    glow =
      if freshness == :fresh,
        do: "box-shadow:0 0 0 3px color-mix(in oklab, var(--color-success) 20%, transparent);",
        else: ""

    "width:10px;height:10px;border-radius:50%;background:#{fresh_color(freshness)};flex:0 0 auto;#{glow}"
  end

  defp pill_class(:fresh), do: "badge-success"
  defp pill_class(:stale), do: "badge-warning"
  defp pill_class(:gone), do: "badge-error"
  defp pill_class(:outdated), do: "badge-error"

  defp pill_label(:fresh), do: "FRESH"
  defp pill_label(:stale), do: "STALE"
  defp pill_label(:gone), do: "GONE"
  defp pill_label(:outdated), do: "OUTDATED"

  # `v1 · requires v2` when outdated, plain `v1` otherwise — the mismatch legible without
  # hovering. "unversioned" rather than a bare `v`: a runner reporting nothing predates
  # RLY-184, and naming that is more useful than an empty slot.
  defp version_label(%{version: nil, outdated: true}), do: "unversioned · requires v#{Runs.min_executor_version()}"

  defp version_label(%{version: version, outdated: true}), do: "v#{version} · requires v#{Runs.min_executor_version()}"

  defp version_label(%{version: nil}), do: "unversioned"
  defp version_label(%{version: version}), do: "v#{version}"

  defp name_color(:fresh), do: "var(--color-base-content)"
  # beating → the dark fresh-name colour, not the muted stale/gone one.
  defp name_color(:outdated), do: "var(--color-base-content)"
  defp name_color(_freshness), do: "color-mix(in oklab, var(--color-base-content) 70%, transparent)"

  defp ref_color(:gone), do: "color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))"
  defp ref_color(_freshness), do: "color-mix(in oklab, var(--color-base-content) 95%, transparent)"

  defp cap_chip_style(pool, freshness) do
    {border, bg, color, extra} =
      cond do
        freshness != :fresh ->
          {"var(--color-base-300)", "var(--color-base-200)",
           "color-mix(in oklab, var(--color-base-content) 55%, transparent)", "opacity:0.7;"}

        pool.used >= pool.total ->
          {"color-mix(in oklab, var(--color-warning) 35%, var(--color-base-100))",
           "color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100))",
           "color-mix(in oklab, var(--color-base-content) 85%, transparent)", ""}

        true ->
          {"color-mix(in oklab, var(--color-success) 25%, var(--color-base-100))",
           "color-mix(in oklab, var(--color-success) 5%, var(--color-base-100))",
           "color-mix(in oklab, var(--color-base-content) 85%, transparent)", ""}
      end

    "display:flex;align-items:center;gap:8px;border:1px solid #{border};background:#{bg};" <>
      "border-radius:8px;padding:7px 11px;color:#{color};#{extra}"
  end

  defp pips(%{total: total}), do: Enum.to_list(0..(total - 1)//1)

  defp pip_style(i, pool, freshness) do
    fill =
      cond do
        i >= pool.used -> "color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100))"
        freshness != :fresh -> "color-mix(in oklab, var(--color-base-content) 40%, var(--color-base-100))"
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
    "display:flex;align-items:center;gap:10px;border:1px solid var(--color-base-300);" <>
      "background:var(--color-base-200);border-radius:8px;padding:8px 11px;"
  end

  defp job_row_style(_freshness) do
    "display:flex;align-items:center;gap:10px;border:1px solid color-mix(in oklab, var(--color-error) 20%, var(--color-base-100));" <>
      "background:color-mix(in oklab, var(--color-error) 5%, var(--color-base-100));border-radius:8px;padding:8px 11px;"
  end

  defp job_dot_style(:fresh), do: "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{@violet};"
  defp job_dot_style(_freshness), do: "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{@rose};"

  # CLAIMED is violet: an AI is working it, which is exactly what violet means in this palette.
  # QUEUED is neutral and deliberately NOT amber — amber is Blocked, and a job queued for two
  # seconds on a healthy board is not blocked. The amber/error signal belongs to the diagnosis
  # banner, which fires only once work has genuinely stopped.
  defp queue_dot_style(:claimed), do: "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{@violet};"

  defp queue_dot_style(_queued),
    do:
      "width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:color-mix(in oklab, var(--color-base-content) 35%, var(--color-base-200));"

  defp queue_pill_class(:claimed), do: "badge-secondary"
  defp queue_pill_class(_queued), do: "badge-ghost"

  defp queue_pill_label(:claimed), do: "CLAIMED"
  defp queue_pill_label(_queued), do: "QUEUED"

  # Every row is tagged with its dispatcher (ADR 0009). A TALK row carries no flow key and no
  # isolation class, so without the tag it reads as a broken NODE row rather than a talk turn.
  defp kind_label(:talk), do: "TALK"
  defp kind_label(_node), do: "NODE"

  # The artboard's small mono chip — the node-key treatment on a job row (line ~104), shared by
  # the working-now rows and the queue rows so there is one chip, not two.
  defp chip_style do
    "font-size:9.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 70%, transparent);" <>
      "background:var(--color-field-hover);border-radius:4px;padding:2px 6px;white-space:nowrap;"
  end

  # The log tail is a fixed-dark "terminal" treatment (background var(--color-neutral) in
  # both themes) — the fresh dot and streaming cursor use a brightened success mix so they
  # still read against that dark band rather than the plain (darker) success token.
  defp log_dot_color(:fresh), do: "color-mix(in oklab, var(--color-success) 60%, var(--color-neutral-content))"
  defp log_dot_color(:stale), do: @amber
  defp log_dot_color(:gone), do: @rose

  defp log_title(:fresh), do: "LOG TAIL · streaming"
  defp log_title(:stale), do: "LOG TAIL · stalled"
  defp log_title(:gone), do: "LOG TAIL · stopped"

  # Same dark-terminal brightening as log_dot_color/1 — plain role tokens read too dark
  # against the fixed --color-neutral log background.
  defp log_color(:claude), do: "color-mix(in oklab, var(--color-secondary) 75%, var(--color-neutral-content))"
  defp log_color(:error), do: "color-mix(in oklab, var(--color-error) 85%, var(--color-neutral-content))"
  defp log_color(_kind), do: "color-mix(in oklab, var(--color-neutral-content) 75%, transparent)"

  defp last_seen_label(runner, now), do: "last beat " <> beat_age(runner, now) <> " ago"

  defp beat_age(runner, now) do
    seconds = max(DateTime.diff(now, runner.last_heartbeat), 0)
    "#{div(seconds, 60)}m #{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}s"
  end

  defp elapsed_label(nil, _now), do: "—"
  defp elapsed_label(started_at, now), do: elapsed_label(max(DateTime.diff(now, started_at), 0))

  defp elapsed_label(seconds) when is_integer(seconds) do
    if seconds >= 3600 do
      "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    else
      "#{div(seconds, 60)}:#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}"
    end
  end
end
