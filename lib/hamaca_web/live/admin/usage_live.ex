defmodule HamacaWeb.Admin.UsageLive do
  @moduledoc """
  The superadmin Usage tab at `/admin/users/usage` (RE475; card mockups "Usage tab — people
  (blue) + their agents (violet)" and "User panel — visits, time, agent runs, shipped"): who uses
  Hamaca, how often, and how much agent work runs on their boards. People are blue (`primary`),
  their agents violet (`secondary`).

  Four tiles and a daily people/agents chart (`HamacaWeb.AdminComponents.stacked_bars/1`) from
  `Hamaca.Usage.overview/2`, then every non-synthetic user by last seen from
  `Hamaca.Usage.user_rows/1`, each with a 14-day `HamacaWeb.AdminComponents.usage_strip/1`.
  Superadmins are listed with a `you · not counted` badge and left out of the tiles and the chart.

  `?range=` (`Hamaca.Usage.ranges/0`, anything else is `Hamaca.Usage.default_range/0`) drives the
  chart only; the tiles and columns keep their fixed windows. `?user=<id>` opens `#usage-panel`
  from `Hamaca.Usage.user_detail/2`; an unparsable or unknown id opens nothing. The search box
  filters the loaded rows by name or email in memory.

  A snapshot, read as of mount's `now`: rows once on mount, the overview when the range changes,
  the detail when a panel opens. Nothing subscribes or updates live.
  """
  use HamacaWeb, :live_view

  import HamacaWeb.AdminComponents, only: [stacked_bars: 1, usage_strip: 1, user_tabs: 1]

  alias Hamaca.Usage

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Usage")
     |> assign(:now, now)
     |> assign(:rows, Usage.user_rows(now))
     |> assign(:query, "")
     |> assign(:search_form, to_form(%{"q" => ""}))
     |> assign(:range, nil)
     |> assign(:overview, nil)
     |> assign(:detail, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = params |> Map.get("range") |> range_param()
    user_id = params |> Map.get("user") |> user_id_param()

    {:noreply,
     socket
     |> load_overview(range)
     |> assign(:detail, user_id && Usage.user_detail(user_id, socket.assigns.now))
     |> stream_rows()}
  end

  @impl true
  def handle_event("range", %{"range" => range}, socket) do
    {:noreply, push_patch(socket, to: usage_path(range_param(range), socket.assigns.detail))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:search_form, to_form(%{"q" => query}))
     |> stream_rows()}
  end

  defp load_overview(%{assigns: %{range: range}} = socket, range), do: socket

  defp load_overview(socket, range) do
    socket
    |> assign(:range, range)
    |> assign(:range_form, to_form(%{"range" => Integer.to_string(range)}))
    |> assign(:overview, Usage.overview(range, socket.assigns.now))
  end

  # Re-streams the loaded rows matching the search, so the open row's highlight and the rows'
  # range-carrying patch links follow every param change. Never re-reads.
  defp stream_rows(socket) do
    rows = Enum.filter(socket.assigns.rows, &matches?(&1, socket.assigns.query))
    stream(socket, :users, rows, dom_id: &"usage-user-#{&1.id}", reset: true)
  end

  defp matches?(row, query) do
    case query |> String.trim() |> String.downcase() do
      "" -> true
      needle -> Enum.any?([row.name, row.email], &(&1 && String.contains?(String.downcase(&1), needle)))
    end
  end

  defp usage_path(range, %{id: user_id}), do: ~p"/admin/users/usage?#{[range: range, user: user_id]}"
  defp usage_path(range, nil), do: ~p"/admin/users/usage?#{[range: range]}"

  defp range_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {range, ""} -> if range in Usage.ranges(), do: range, else: Usage.default_range()
      _not_a_range -> Usage.default_range()
    end
  end

  defp range_param(_value), do: Usage.default_range()

  defp user_id_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _not_an_id -> nil
    end
  end

  defp user_id_param(_value), do: nil

  @doc false
  # The ONE place the Usage tab's duration copy lives: `—`, `Nm` (at least 1m), or `Nh Mm`.
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(0), do: "—"
  def format_duration(seconds) when seconds < 3600, do: "#{max(div(seconds, 60), 1)}m"
  def format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  @doc false
  # The ONE place the Usage tab's "last seen" copy lives.
  @spec relative_time(DateTime.t() | nil, DateTime.t()) :: String.t()
  def relative_time(nil, _now), do: "—"

  def relative_time(%DateTime{} = at, %DateTime{} = now) do
    seconds = DateTime.diff(now, at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      div(seconds, 86_400) == 1 -> "1 day ago"
      true -> "#{div(seconds, 86_400)} days ago"
    end
  end

  @doc false
  # The ONE place the Active today tile's comparison copy lives: today vs the same weekday a week ago.
  @spec today_delta(non_neg_integer(), non_neg_integer(), Date.t()) :: String.t()
  def today_delta(today, last_week, %Date{} = today_date) do
    weekday = Calendar.strftime(today_date, "%a")

    case today - last_week do
      0 -> "same as last #{weekday}"
      delta when delta > 0 -> "+#{delta} vs last #{weekday}"
      delta -> "#{delta} vs last #{weekday}"
    end
  end

  defp day_label(date), do: Calendar.strftime(date, "%-d %b")

  defp visits_per_day(nil), do: "—"
  defp visits_per_day(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp last_place(%{last_board_name: board, last_card_ref: nil}), do: board
  defp last_place(%{last_board_name: board, last_card_ref: ref}), do: "#{board} · #{ref}"

  defp boards_label(1), do: "1 board"
  defp boards_label(count), do: "#{count} boards"

  defp visit_refs(%{card_refs: [_ | _] = refs}), do: Enum.map_join(refs, " ", &"· #{&1}")
  defp visit_refs(%{board_name: board}) when is_binary(board), do: "· Board"
  defp visit_refs(_visit), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="mx-auto max-w-6xl px-4 py-8">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm text-base-content/65 link link-hover"
        >
          ← Admin
        </.link>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold">Usage</h1>
          <span class="flex-1"></span>
          <.user_tabs active={:usage} />
          <.form for={@range_form} id="usage-range-form" phx-change="range">
            <select id="usage-range" name="range" class="select select-sm w-36">
              <option
                :for={range <- Usage.ranges()}
                value={range}
                selected={range == @range}
              >
                Last {range} days
              </option>
            </select>
          </.form>
        </div>
        <p class="mt-1 text-sm text-base-content/65">
          People, and the agents working their boards · you're listed but not counted · demo accounts are left out
        </p>

        <div class="mt-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.tile
            id="usage-tile-active-today"
            label="Active today"
            value={@overview.active_today}
            sub={
              today_delta(@overview.active_today, @overview.active_last_week, DateTime.to_date(@now))
            }
          />
          <.tile
            id="usage-tile-this-week"
            label="This week"
            value={@overview.this_week}
            sub={"of #{@overview.counted_users} users"}
          />
          <.tile
            id="usage-tile-agent-runs"
            label="Agent runs · 7d"
            value={@overview.agent_runs_7d}
            value_class="text-secondary"
            sub={"on #{@overview.agent_run_owners_7d} users' boards"}
          />
          <.tile
            id="usage-tile-median-visit"
            label="Median visit"
            value={format_duration(@overview.median_visit_seconds_7d || 0)}
            sub={"#{visits_per_day(@overview.visits_per_active_day_7d)} visits / active day"}
          />
        </div>

        <section id="usage-chart" class="mt-4 rounded-box border border-base-300 bg-base-100 p-5">
          <div class="flex flex-wrap items-center gap-3">
            <h2 class="font-semibold">Daily active users · and their agents</h2>
            <div class="flex items-center gap-3 text-xs text-base-content/65">
              <span class="flex items-center gap-1">
                <span class="size-2.5 rounded-sm bg-primary"></span>People
              </span>
              <span class="flex items-center gap-1">
                <span class="size-2.5 rounded-sm bg-secondary"></span>Their agents
              </span>
            </div>
            <span class="flex-1"></span>
            <span class="font-mono text-xs text-base-content/65">
              {day_label(hd(@overview.series).date)} – {day_label(List.last(@overview.series).date)}
            </span>
          </div>
          <.stacked_bars series={@overview.series} id="usage-chart" />
          <div class="mt-1 flex justify-between font-mono text-[11px] text-base-content/45">
            <span>{day_label(hd(@overview.series).date)}</span>
            <span>
              {day_label(Enum.at(@overview.series, div(length(@overview.series) - 1, 2)).date)}
            </span>
            <span>{day_label(List.last(@overview.series).date)}</span>
          </div>
        </section>

        <div class="mt-8 flex flex-wrap items-center gap-3">
          <h2 class="font-semibold">
            Users <span class="font-normal text-base-content/65">· by last seen</span>
          </h2>
          <span class="flex-1"></span>
          <.form
            for={@search_form}
            id="usage-search"
            phx-change="search"
            phx-submit="search"
            class="w-full sm:w-64"
          >
            <label class="input input-sm w-full sm:w-64">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
              <input
                type="search"
                name={@search_form[:q].name}
                value={@search_form[:q].value}
                placeholder="Search users…"
                phx-debounce="200"
              />
            </label>
          </.form>
        </div>

        <div class="mt-3 overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table id="usage-users-table" class="table table-sm">
            <thead>
              <tr>
                <th>User</th>
                <th>Last seen</th>
                <th>Last 14 days</th>
                <th class="text-right">Visits · 7d</th>
                <th class="text-right">Time · 7d</th>
                <th class="text-right">Runs · 7d</th>
                <th class="text-right">Shipped · 7d</th>
              </tr>
            </thead>
            <tbody id="usage-users" phx-update="stream">
              <tr
                :for={{dom_id, row} <- @streams.users}
                id={dom_id}
                phx-click={JS.patch(usage_path(@range, row))}
                class={[
                  "cursor-pointer hover:bg-base-200",
                  @detail && @detail.id == row.id && "bg-base-200"
                ]}
              >
                <td>
                  <div class="font-medium whitespace-nowrap">
                    {row.name || row.email}
                    <span
                      :if={!row.counted?}
                      id={"#{dom_id}-not-counted"}
                      class="badge badge-xs badge-ghost"
                      title="Not counted in totals or the chart"
                    >
                      you · not counted
                    </span>
                  </div>
                  <div class="text-xs text-base-content/65">{row.email}</div>
                </td>
                <td id={"#{dom_id}-last-seen"} class="whitespace-nowrap">
                  <span :if={!row.last_seen_at} class="text-base-content/45">—</span>
                  <div :if={row.last_seen_at}>{relative_time(row.last_seen_at, @now)}</div>
                  <div
                    :if={row.last_seen_at && row.last_board_name}
                    class="font-mono text-xs text-base-content/65 truncate max-w-40"
                  >
                    {last_place(row)}
                  </div>
                </td>
                <td id={"#{dom_id}-strip"}><.usage_strip days={row.strip} size={:sm} /></td>
                <.count_cell id={"#{dom_id}-visits"} value={row.visits_7d} />
                <.count_cell
                  id={"#{dom_id}-time"}
                  value={row.seconds_7d}
                  shown={format_duration(row.seconds_7d)}
                  class="whitespace-nowrap"
                />
                <.count_cell id={"#{dom_id}-runs"} value={row.runs_7d} agents />
                <.count_cell id={"#{dom_id}-shipped"} value={row.shipped_7d} />
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.usage_panel :if={@detail} detail={@detail} range={@range} />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :string, required: true
  attr :value_class, :string, default: nil

  defp tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100 px-4 py-3">
      <div class="text-xs font-semibold uppercase tracking-wide text-base-content/65">{@label}</div>
      <div class={["mt-1 text-3xl font-semibold tabular-nums", @value_class]}>{@value}</div>
      <div class="mt-1 font-mono text-xs text-base-content/65">{@sub}</div>
    </div>
    """
  end

  # A right-aligned figure: a muted `0` (or the `shown` copy, e.g. `—`) when zero; agent runs violet.
  attr :id, :string, required: true
  attr :value, :integer, required: true
  attr :shown, :string, default: nil
  attr :class, :string, default: nil
  attr :agents, :boolean, default: false

  defp count_cell(assigns) do
    assigns = assign(assigns, :shown, assigns.shown || Integer.to_string(assigns.value))

    ~H"""
    <td id={@id} class={["text-right tabular-nums", @class]}>
      <span :if={@value == 0} class="text-base-content/45">{@shown}</span>
      <span :if={@value != 0 && @agents} class="text-secondary font-medium">{@shown}</span>
      <%= if @value != 0 && !@agents do %>
        {@shown}
      <% end %>
    </td>
    """
  end

  # The `?user=<id>` side panel: header, the six stats, the 14-day strip, recent visits, billing.
  attr :detail, :map, required: true
  attr :range, :integer, required: true

  defp usage_panel(assigns) do
    ~H"""
    <aside
      id="usage-panel"
      class="fixed inset-y-0 right-0 z-40 flex w-full max-w-md flex-col border-l border-base-300 bg-base-100 shadow-xl"
    >
      <header class="flex items-start gap-3 border-b border-base-300 px-5 py-4">
        <div class="min-w-0 flex-1">
          <h2 class="truncate text-lg font-semibold">{@detail.name || @detail.email}</h2>
          <p class="truncate text-sm text-base-content/65">
            {@detail.email} · user since {Calendar.strftime(@detail.inserted_at, "%b %Y")} · {boards_label(
              @detail.board_count
            )}
          </p>
        </div>
        <.link
          id="usage-panel-close"
          patch={usage_path(@range, nil)}
          class="btn btn-ghost btn-sm btn-square"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.link>
      </header>

      <div class="flex-1 space-y-6 overflow-y-auto px-5 py-5">
        <dl id="usage-panel-stats" class="grid grid-cols-3 gap-3">
          <.stat id="usage-panel-active-days" label="Active days">
            {@detail.active_days_14}<span class="text-base-content/45 font-normal"> / {Usage.strip_days()}</span>
          </.stat>
          <.stat id="usage-panel-visits-7d" label="Visits · 7d">{@detail.visits_7d}</.stat>
          <.stat id="usage-panel-time" label="Time · 7d">
            {format_duration(@detail.seconds_7d)}
          </.stat>
          <.stat id="usage-panel-runs" label="Agent runs · 7d">
            <span class="text-secondary">{@detail.runs_7d}</span>
          </.stat>
          <.stat id="usage-panel-shipped" label="Shipped · 7d">{@detail.shipped_7d}</.stat>
          <.stat id="usage-panel-waiting" label="Waiting on them">{@detail.waiting}</.stat>
        </dl>

        <section>
          <.panel_title>Last {Usage.strip_days()} days</.panel_title>
          <.usage_strip days={@detail.strip} size={:lg} id="usage-panel-strip" />
          <div class="mt-2 flex gap-3 text-xs text-base-content/65">
            <span class="flex items-center gap-1">
              <span class="size-2.5 rounded-sm bg-primary"></span>Visited
            </span>
            <span class="flex items-center gap-1">
              <span class="size-2.5 rounded-sm bg-secondary"></span>Agents ran
            </span>
          </div>
        </section>

        <section>
          <.panel_title>Recent visits</.panel_title>
          <ul id="usage-panel-visits" class="divide-y divide-base-300 text-sm">
            <li
              :if={@detail.recent_visits == []}
              id="usage-panel-visits-empty"
              class="py-2 text-base-content/65"
            >
              No visits yet.
            </li>
            <li
              :for={visit <- @detail.recent_visits}
              id={"usage-visit-#{visit.id}"}
              class="flex items-center gap-2 py-2"
            >
              <span class="font-mono text-xs w-20">
                {Calendar.strftime(visit.started_at, "%a %-d %b")}
              </span>
              <span class="flex-1 truncate">
                {visit.board_name || "—"}
                <span :if={visit_refs(visit)} class="text-base-content/65">{visit_refs(visit)}</span>
              </span>
              <span class="font-mono text-xs">{format_duration(visit.seconds)}</span>
            </li>
          </ul>
        </section>

        <.link
          id="usage-panel-billing"
          navigate={~p"/admin/users?user=#{@detail.id}"}
          class="link link-hover text-sm text-base-content/65"
        >
          Billing for this user →
        </.link>
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 px-3 py-2">
      <dt class="text-xs text-base-content/65">{@label}</dt>
      <dd class="text-lg font-semibold tabular-nums">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  slot :inner_block, required: true

  defp panel_title(assigns) do
    ~H"""
    <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/65">
      {render_slot(@inner_block)}
    </h3>
    """
  end
end
