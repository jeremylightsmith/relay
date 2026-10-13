defmodule RelayWeb.Admin.OnboardingLive do
  @moduledoc """
  Read-only progress table of every board created with guided setup at `/admin/onboarding`
  (RE448): one row per board from `Relay.Setup.list_for_admin/1`, newest first — owner,
  template, LLM, the current step, time on it, total time, the last evidence or error, and a
  "stuck" badge once a board sits on one step longer than `Relay.Setup.stuck_after/0`.

  Static snapshot at mount (no PubSub, no re-query): the filter chips (all and each of
  `Relay.Setup.admin_states/0`) narrow the loaded rows in memory, and `?board=<slug>` selects a
  row, opening a pane with that board's checklist rendered read-only by the wizard's own
  `RelayWeb.SetupComponents.setup_checklist/1`. A board's name links to `/board/:slug` only
  when the current superadmin is already a member, like `RelayWeb.Admin.BoardsLive`. Gated by
  the `:admin` live_session.
  """
  use RelayWeb, :live_view

  import RelayWeb.SetupComponents, only: [setup_checklist: 1]

  alias Relay.Boards
  alias Relay.Setup

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Onboarding")
     |> assign(:rows, Setup.list_for_admin(now))
     |> assign(:loaded_at, now)
     |> assign(:member_ids, Boards.member_board_ids(socket.assigns.current_scope.user))
     |> assign(:filter, :all)
     |> assign(:selected, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    slug = params["board"]
    {:noreply, assign(socket, :selected, Enum.find(socket.assigns.rows, &(&1.slug == slug)))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    case Enum.find(filters(), &(Atom.to_string(&1) == filter)) do
      nil -> {:noreply, socket}
      filter -> {:noreply, assign(socket, :filter, filter)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible: visible(assigns.rows, assigns.filter),
        chips: Enum.map(filters(), &{&1, count(assigns.rows, &1)})
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="mx-auto px-4 py-8" style="max-width:1280px">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm link link-hover text-base-content/55"
        >
          ← Admin
        </.link>
        <h1 class="mt-2 text-2xl font-semibold">Onboarding</h1>
        <p class="mt-1 text-sm text-base-content/55">
          One row per board created with the wizard, newest first. A snapshot as of page load; refresh for newer.
        </p>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <button
            :for={{filter, count} <- @chips}
            type="button"
            id={"onboarding-filter-#{filter}"}
            phx-click="filter"
            phx-value-filter={filter}
            class={[
              "badge badge-sm cursor-pointer",
              if(filter == @filter, do: "badge-primary", else: "badge-ghost")
            ]}
          >
            {filter_label(filter)} {count}
          </button>
          <span class="flex-1"></span>
          <span id="onboarding-loaded" class="font-mono text-xs text-base-content/40">
            loaded {Calendar.strftime(@loaded_at, "%H:%M")}
          </span>
        </div>

        <p :if={@rows == []} id="onboarding-empty" class="mt-6 text-sm text-base-content/55">
          No boards have been created with guided setup yet.
        </p>

        <div
          :if={@rows != []}
          class="mt-4 grid gap-5 items-start"
          style={@selected && "grid-template-columns:minmax(0,1fr) 380px"}
        >
          <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
            <table id="onboarding-table" class="table table-sm">
              <thead>
                <tr>
                  <th>Board</th>
                  <th>Owner</th>
                  <th>Template</th>
                  <th>LLM</th>
                  <th>Current step</th>
                  <th class="text-right">On step</th>
                  <th class="text-right">Total</th>
                  <th>Last evidence / error</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @visible}
                  id={"onboarding-row-#{row.board_id}"}
                  phx-click={JS.patch(~p"/admin/onboarding?#{[board: row.slug]}")}
                  class={[
                    "cursor-pointer",
                    @selected && @selected.board_id == row.board_id && "bg-base-200"
                  ]}
                >
                  <td>
                    <.link
                      :if={MapSet.member?(@member_ids, row.board_id)}
                      navigate={~p"/board/#{row.slug}"}
                      class="link link-hover font-medium"
                    >
                      {row.name}
                    </.link>
                    <span :if={!MapSet.member?(@member_ids, row.board_id)} class="font-medium">
                      {row.name}
                    </span>
                    <span
                      :if={row.stuck?}
                      id={"onboarding-row-#{row.board_id}-stuck"}
                      class="badge badge-sm badge-warning ml-1.5"
                    >
                      stuck
                    </span>
                  </td>
                  <td>
                    <span
                      id={"onboarding-row-#{row.board_id}-owner"}
                      class={[
                        "block truncate",
                        if(@selected, do: "max-w-[120px]", else: "max-w-[200px]")
                      ]}
                      title={row.owner_email}
                    >
                      {row.owner_email || "—"}
                    </span>
                  </td>
                  <td>{row.template || "—"}</td>
                  <td>{row.llm || "—"}</td>
                  <td>
                    <span
                      id={"onboarding-row-#{row.board_id}-step"}
                      class={[
                        "badge badge-sm badge-soft whitespace-nowrap justify-start",
                        if(@selected, do: "max-w-[140px]", else: "max-w-[260px]"),
                        step_badge(row)
                      ]}
                      title={"#{row.current.id} · #{row.current.title}"}
                    >
                      <span class="truncate">{row.current.id} · {row.current.title}</span>
                    </span>
                  </td>
                  <td
                    id={"onboarding-row-#{row.board_id}-on-step"}
                    class="text-right tabular-nums font-mono text-xs"
                  >
                    {duration(row.on_step)}
                  </td>
                  <td
                    id={"onboarding-row-#{row.board_id}-total"}
                    class="text-right tabular-nums font-mono text-xs"
                  >
                    {duration(row.total)}
                  </td>
                  <td
                    id={"onboarding-row-#{row.board_id}-last"}
                    class={[
                      "font-mono text-xs truncate text-base-content/55",
                      if(@selected, do: "max-w-[110px]", else: "max-w-[240px]")
                    ]}
                    title={last(row.last)}
                  >
                    {last(row.last)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@selected}
            id="onboarding-detail"
            class="rounded-box border border-base-300 bg-base-100 flex flex-col"
          >
            <div class="flex items-center gap-2 px-4 py-3 border-b border-base-300">
              <span class="font-bold text-[15px] whitespace-nowrap">{@selected.name}</span>
              <span :if={@selected.stuck?} class="badge badge-sm badge-warning">stuck</span>
              <span class="flex-1"></span>
              <span class="font-mono text-[11px] text-base-content/55">
                same checklist the wizard shows
              </span>
            </div>
            <div class="p-4">
              <.setup_checklist
                id="onboarding-checklist"
                checklist={@selected.checklist}
                mode={:read_only}
              />
            </div>
            <div
              id="onboarding-detail-footer"
              class="px-4 py-3 border-t border-base-300 font-mono text-[11px] text-base-content/55"
            >
              stuck = same step &gt; {duration(Setup.stuck_after())} ·
              <span class="text-base-content/40">Relay.Setup.stuck_after/0</span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filters, do: [:all | Setup.admin_states()]

  defp filter_label(filter), do: filter |> Atom.to_string() |> String.replace("_", " ")

  defp visible(rows, :all), do: rows
  defp visible(rows, state), do: Enum.filter(rows, &(&1.state == state))

  defp count(rows, filter), do: length(visible(rows, filter))

  defp step_badge(%{state: :done}), do: "badge-success"
  defp step_badge(%{current: %{status: :failed}}), do: "badge-error"
  defp step_badge(%{current: %{actor: :ai_terminal}}), do: "badge-secondary"
  defp step_badge(_row), do: "badge-primary"

  defp last(%{kind: :error, text: text}), do: "✕ " <> text
  defp last(%{kind: :evidence, text: text}), do: text
  defp last(nil), do: "—"

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour

  defp duration(nil), do: "—"
  defp duration(seconds) when seconds >= @day, do: units(div(seconds, @day), "d", div(rem(seconds, @day), @hour), "h")

  defp duration(seconds) when seconds >= @hour,
    do: units(div(seconds, @hour), "h", div(rem(seconds, @hour), @minute), "m")

  defp duration(seconds), do: "#{max(div(seconds, @minute), 0)}m"

  defp units(big, big_unit, 0, _small_unit), do: "#{big}#{big_unit}"
  defp units(big, big_unit, small, small_unit), do: "#{big}#{big_unit} #{small}#{small_unit}"
end
