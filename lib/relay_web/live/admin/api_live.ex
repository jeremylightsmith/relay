defmodule RelayWeb.Admin.ApiLive do
  @moduledoc """
  Live table of the last 200 inbound API requests (in-memory; cleared on
  restart). Debug view at `/admin/api`, gated to any authenticated user.

  Subscribes to `RelayWeb.ApiLog`'s `"api_log"` topic and appends new entries
  to a LiveView stream; each row expands (client-side, via `JS.toggle`) to show
  the sanitized params.
  """
  use RelayWeb, :live_view

  alias RelayWeb.ApiLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ApiLog.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "API requests")
     |> stream(:requests, ApiLog.list())}
  end

  @impl true
  def handle_info({:api_log, entry}, socket) do
    {:noreply, stream_insert(socket, :requests, entry, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl px-4 py-8">
        <h1 class="text-2xl font-semibold">API requests</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Live view of the last 200 inbound API requests. In-memory only — cleared on restart.
        </p>

        <div
          id="requests"
          phx-update="stream"
          class="mt-6 overflow-hidden rounded-box border border-base-200 divide-y divide-base-200"
        >
          <div
            id="requests-empty"
            class="hidden only:block p-8 text-center text-sm text-base-content/60"
          >
            No API requests recorded yet.
          </div>

          <div :for={{dom_id, e} <- @streams.requests} id={dom_id}>
            <button
              type="button"
              phx-click={JS.toggle(to: "##{dom_id}-params")}
              class="grid w-full grid-cols-[7rem_3.5rem_1fr_auto_5rem] items-center gap-3 px-4 py-2 text-left text-sm hover:bg-base-200/60"
            >
              <span class="font-mono text-xs text-base-content/60">
                {Calendar.strftime(e.at, "%H:%M:%S")}
              </span>
              <span class="font-mono font-semibold">{e.method}</span>
              <span class="truncate font-mono">{e.path}</span>
              <span class={["badge badge-sm", status_class(e.status)]}>{e.status || "—"}</span>
              <span class="text-right font-mono text-xs text-base-content/60">{e.duration_ms}ms</span>
            </button>

            <dl
              id={"#{dom_id}-params"}
              class="hidden grid grid-cols-[6rem_1fr] gap-x-4 gap-y-1 bg-base-200/40 px-4 py-3 text-xs"
            >
              <dt class="text-base-content/60">Board</dt>
              <dd class="font-mono">{board_label(e.board)}</dd>
              <dt class="text-base-content/60">Query</dt>
              <dd class="font-mono break-all">{blank(e.query)}</dd>
              <dt class="text-base-content/60">Remote IP</dt>
              <dd class="font-mono">{blank(e.remote_ip)}</dd>
              <dt class="text-base-content/60">Params</dt>
              <dd><pre class="whitespace-pre-wrap break-all font-mono">{e.params}</pre></dd>
            </dl>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_class(status) when is_integer(status) and status >= 500, do: "badge-error"
  defp status_class(status) when is_integer(status) and status >= 400, do: "badge-warning"
  defp status_class(status) when is_integer(status) and status >= 200, do: "badge-success"
  defp status_class(_), do: "badge-ghost"

  defp board_label(%{name: name, key: key}), do: "#{name} (#{key})"
  defp board_label(_), do: "—"

  defp blank(v) when v in [nil, ""], do: "—"
  defp blank(v), do: v
end
