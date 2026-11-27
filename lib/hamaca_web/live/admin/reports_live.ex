defmodule HamacaWeb.Admin.ReportsLive do
  @moduledoc """
  The superadmin's moderation queue at `/admin/reports` (RE510, Apple Guideline 1.2).

  **Open** (the default) lists one row per item with open reports (`Hamaca.Moderation.list_open/0`):
  reason, kind, board, a due-in countdown against `Moderation.response_sla_hours/0` (warning-styled
  within `Moderation.due_soon_hours/0`), the excerpt, poster, reporters, notes and hidden status,
  with **Dismiss**, **Hide content** and **Suspend <poster>**. **Resolved** (`?tab=resolved`; any
  other value means Open) lists the resolved batches (`list_resolved/0`), each with **Undo**.

  A suspension also force-disconnects the poster's open LiveView sockets
  (`HamacaWeb.Auth.disconnect_user/1`). Plain assigns, no stream and no PubSub: both lists are
  reloaded after every action, and new reports show up on refresh. Gated by the `:admin`
  live_session.
  """
  use HamacaWeb, :live_view

  alias Hamaca.Boards
  alias Hamaca.Moderation
  alias HamacaWeb.Auth
  alias HamacaWeb.TimeAgo
  alias Schemas.ContentReport

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Reports")
     |> assign(:member_ids, Boards.member_board_ids(socket.assigns.current_scope.user))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:tab, tab_param(params["tab"])) |> refresh()}
  end

  # Matched by pattern, never turned into an atom.
  defp tab_param("resolved"), do: :resolved
  defp tab_param(_value), do: :open

  @impl true
  def handle_event(action, %{"kind" => kind, "id" => id}, socket) when action in ~w(dismiss hide suspend) do
    case target(kind, id) do
      {:ok, target} -> {:noreply, socket |> act(action, target) |> refresh()}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("undo", %{"report-id" => report_id}, socket) do
    with {:ok, id} <- integer(report_id),
         :ok <- Moderation.undo(admin(socket), id) do
      {:noreply, refresh(socket)}
    else
      :error -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket |> put_flash(:error, "That action was already undone.") |> refresh()}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp act(socket, "dismiss", target), do: socket |> admin() |> Moderation.dismiss(target) |> flash_result(socket)
  defp act(socket, "hide", target), do: socket |> admin() |> Moderation.hide(target) |> flash_result(socket)

  defp act(socket, "suspend", target) do
    case Moderation.suspend(admin(socket), target) do
      {:ok, user} ->
        Auth.disconnect_user(user)
        socket

      error ->
        flash_result(error, socket)
    end
  end

  defp flash_result({:ok, _}, socket), do: socket
  defp flash_result({:error, reason}, socket), do: put_flash(socket, :error, error_message(reason))

  defp error_message(:cannot_suspend_superadmin), do: "Superadmins can't be suspended."
  defp error_message(:no_poster), do: "This item has no poster to suspend."
  defp error_message(:no_open_reports), do: "That report was already resolved."

  defp target("card", id), do: with({:ok, int} <- integer(id), do: {:ok, {:card, int}})
  defp target("comment", id), do: with({:ok, int} <- integer(id), do: {:ok, {:comment, int}})
  defp target(_kind, _id), do: :error

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp integer(_value), do: :error

  defp admin(socket), do: socket.assigns.current_scope.user

  defp refresh(socket) do
    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:open_count, Moderation.open_count())
    |> assign(:rows, rows(socket.assigns.tab))
  end

  defp rows(:open), do: Moderation.list_open()
  defp rows(:resolved), do: Moderation.list_resolved()

  @doc """
  The countdown to `due_at` as of `now`: `"due in <h>h"` until the deadline, `"overdue <h>h"`
  after, the hours rounded up.
  """
  @spec due_label(DateTime.t(), DateTime.t()) :: String.t()
  def due_label(%DateTime{} = due_at, %DateTime{} = now) do
    case DateTime.diff(due_at, now, :second) do
      left when left >= 0 -> "due in #{hours_up(left)}h"
      over -> "overdue #{hours_up(-over)}h"
    end
  end

  defp hours_up(seconds), do: div(seconds + 3599, 3600)

  @doc ~s(The time from `from` to `to`, floored: `"<n>m"` under an hour, `"<n>h"` under a day, else `"<n>d"`.)
  @spec elapsed_label(DateTime.t(), DateTime.t()) :: String.t()
  def elapsed_label(%DateTime{} = from, %DateTime{} = to) do
    seconds = max(DateTime.diff(to, from, :second), 0)

    cond do
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp due_soon?(row, now), do: DateTime.diff(row.due_at, now, :second) <= Moderation.due_soon_hours() * 3600

  defp reason_class(reason) when reason in [:harassment, :sexual_violent], do: "badge-warning"
  defp reason_class(_reason), do: "badge-ghost"

  defp kind_label(:card), do: "Public idea"
  defp kind_label(:comment), do: "Comment"

  defp board_label(%{kind: :card, board: board}), do: board.name
  defp board_label(%{kind: :comment, board: board, card_ref: ref}), do: "#{board.name} · #{ref}"

  # A non-member admin can't open the private board, so they read the whole comment here.
  defp quoted_text(%{kind: :comment, board: board, full_text: full_text}, member_ids) do
    if MapSet.member?(member_ids, board.id), do: nil, else: full_text
  end

  defp quoted_text(_row, _member_ids), do: nil

  defp context_path(%{kind: :card, board: board, target_id: id}, _member_ids),
    do: ~p"/board/#{board.slug}/public?idea=#{id}"

  defp context_path(%{kind: :comment, board: board, card_ref: ref}, member_ids) do
    if MapSet.member?(member_ids, board.id), do: ~p"/board/#{board.slug}?card=#{ref}"
  end

  defp status_label(%{status: :reporter_only}), do: "Hidden for reporter only"
  defp status_label(%{status: :auto_hidden, report_count: n}), do: "Auto-hidden for everyone (#{n} reports)"
  defp status_label(%{status: :admin_hidden}), do: "Hidden by admin"

  defp person(nil), do: "—"
  defp person(user), do: user.name || user.email

  defp poster_label(nil), do: "—"
  defp poster_label(user), do: "#{person(user)} · #{user.email}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="admin-reports-page" class="mx-auto max-w-5xl px-4 py-8">
        <nav class="flex items-center gap-2 text-sm">
          <span class="font-semibold">{Hamaca.Brand.name()}</span>
          <span class="text-base-content/40">/</span>
          <.link navigate={~p"/admin"} class="link text-base-content/65">Admin</.link>
          <span class="text-base-content/40">/</span>
          <span class="font-semibold">Reports</span>
        </nav>

        <div class="mt-2 flex flex-wrap items-end gap-3">
          <div>
            <h1 class="text-2xl font-semibold">Reports</h1>
            <p class="mt-1 text-sm text-base-content/65">
              Respond within {Moderation.response_sla_hours()} hours. Every new report also emails the operator.
            </p>
          </div>
          <span class="flex-1"></span>
          <div class="join">
            <.link
              id="reports-tab-open"
              patch={~p"/admin/reports"}
              class={["btn btn-sm join-item", @tab == :open && "btn-active"]}
            >
              Open
              <span id="reports-open-count" class="badge badge-warning badge-sm">{@open_count}</span>
            </.link>
            <.link
              id="reports-tab-resolved"
              patch={~p"/admin/reports?#{[tab: "resolved"]}"}
              class={["btn btn-sm join-item", @tab == :resolved && "btn-active"]}
            >
              Resolved
            </.link>
          </div>
        </div>

        <div :if={@tab == :open} class="mt-6 space-y-3">
          <div
            :if={@rows == []}
            id="admin-reports-empty"
            class="rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center text-sm text-base-content/55"
          >
            No open reports. Nice.
          </div>
          <.open_row :for={row <- @rows} row={row} now={@now} member_ids={@member_ids} />
        </div>

        <div :if={@tab == :resolved} class="mt-6 space-y-2">
          <div
            :if={@rows == []}
            id="admin-reports-empty"
            class="rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center text-sm text-base-content/55"
          >
            Nothing resolved yet.
          </div>
          <.resolved_row :for={row <- @rows} row={row} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :now, DateTime, required: true
  attr :member_ids, MapSet, required: true

  defp open_row(assigns) do
    assigns =
      assigns
      |> assign(:id, "report-row-#{assigns.row.key}")
      |> assign(:soon?, due_soon?(assigns.row, assigns.now))
      |> assign(:quoted, quoted_text(assigns.row, assigns.member_ids) || assigns.row.excerpt)
      |> assign(:context, context_path(assigns.row, assigns.member_ids))

    ~H"""
    <article
      id={@id}
      class={[
        "rounded-box border bg-base-100 p-4",
        if(@soon?, do: "border-warning/50", else: "border-base-300")
      ]}
    >
      <div class="flex flex-wrap items-center gap-2 text-xs">
        <span class={["badge badge-sm", reason_class(@row.latest_reason)]}>
          {ContentReport.reason_label(@row.latest_reason)}
        </span>
        <span class="badge badge-ghost badge-sm">{kind_label(@row.kind)}</span>
        <span class="text-base-content/55">{board_label(@row)}</span>
        <span class="ml-auto">
          <span
            id={"#{@id}-due"}
            class={if(@soon?, do: "font-semibold text-warning", else: "text-base-content/55")}
          >
            {due_label(@row.due_at, @now)}
          </span>
          <span class="text-base-content/45">
            · reported {TimeAgo.ago(@now, @row.first_reported_at)}<span :if={@row.report_count > 1}> · {@row.report_count} reports</span>
          </span>
        </span>
      </div>

      <blockquote class="mt-3 rounded-lg border-l-4 border-base-300 bg-base-200/60 px-3 py-2 text-sm">
        “{@quoted}”
      </blockquote>

      <dl class="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-xs sm:grid-cols-3">
        <div>
          <dt class="text-base-content/50">Posted by</dt>
          <dd class="font-medium">{poster_label(@row.poster)}</dd>
        </div>
        <div>
          <dt class="text-base-content/50">Reported by</dt>
          <dd class="font-medium">{Enum.map_join(@row.reporters, ", ", &person/1)}</dd>
        </div>
        <div>
          <dt class="text-base-content/50">Status</dt>
          <dd id={"#{@id}-status"} class="font-medium">{status_label(@row)}</dd>
        </div>
      </dl>

      <p :for={note <- @row.notes} class="mt-2 text-xs text-base-content/70">
        <span class="text-base-content/50">Note from {person(note.reporter)}:</span> {note.note}
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-2">
        <a
          :if={@context}
          id={"#{@id}-context"}
          href={@context}
          target="_blank"
          rel="noopener"
          class="btn btn-ghost btn-sm"
        >
          View in context ↗
        </a>
        <span class="flex-1"></span>
        <button
          id={"#{@id}-dismiss"}
          type="button"
          class="btn btn-sm"
          phx-click="dismiss"
          phx-value-kind={@row.kind}
          phx-value-id={@row.target_id}
        >
          Dismiss
        </button>
        <button
          id={"#{@id}-hide"}
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="hide"
          phx-value-kind={@row.kind}
          phx-value-id={@row.target_id}
        >
          Hide content
        </button>
        <button
          :if={@row.poster}
          id={"#{@id}-suspend"}
          type="button"
          class="btn btn-sm btn-error btn-outline"
          phx-click="suspend"
          phx-value-kind={@row.kind}
          phx-value-id={@row.target_id}
        >
          Suspend {person(@row.poster)}
        </button>
      </div>
    </article>
    """
  end

  attr :row, :map, required: true

  defp resolved_row(assigns) do
    assigns = assign(assigns, :id, "report-row-#{assigns.row.key}")

    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3 text-sm"
    >
      <span class="badge badge-ghost badge-sm">{ContentReport.reason_label(@row.latest_reason)}</span>
      <span class="flex-1 truncate text-base-content/70">“{@row.excerpt}” on {@row.board.name}</span>
      <span class="text-xs text-base-content/55">
        {ContentReport.resolution_label(@row.resolution)} by {person(@row.resolved_by)} · {elapsed_label(
          @row.first_reported_at,
          @row.resolved_at
        )} after report
      </span>
      <button
        id={"#{@id}-undo"}
        type="button"
        class="btn btn-ghost btn-xs"
        phx-click="undo"
        phx-value-report-id={@row.undo_report_id}
      >
        Undo
      </button>
    </div>
    """
  end
end
