defmodule RelayWeb.FreeBoardComponents do
  @moduledoc """
  RE471 — choosing which board stays editable on Free.

    * `free_board_dialog/1` — the one-time "Which board stays editable?" dialog `BoardsLive`
      opens after a drop to Free (card mockup "Over limit — one-time 'Which board stays
      editable?' dialog"). One radio row per counted board; the form sends
      `select_free_board` on change and `keep_free_board` on submit (both
      `%{"board_id" => "<id>"}`); ✕, Escape and the backdrop send `close_free_board_dialog`.
    * `make_editable_confirm/1` — the "Make <board> editable?" confirm the read-only banner and
      Billing open before switching the editable board.
  """
  use RelayWeb, :html

  alias RelayWeb.CoreComponents
  alias RelayWeb.TimeAgo

  @close_event "close_free_board_dialog"

  attr :id, :string, default: "free-board-dialog"

  attr :boards, :list,
    required: true,
    doc: "`Relay.Billing.free_status/2`'s `boards`: `%{id, slug, name, editable?, active_at}`, editable first"

  attr :selected, :integer, required: true, doc: "the id of the board whose radio is checked"
  attr :editable_id, :integer, required: true, doc: "the id of today's editable board"
  attr :upgrade_price, :string, required: true, doc: ~s(the monthly price the upgrade button quotes, e.g. "$20")

  attr :upgrade_href, :string,
    default: nil,
    doc: "where Upgrade instead links; nil (embedded in the app, which sells nothing) drops the button"

  def free_board_dialog(assigns) do
    assigns =
      assign(assigns,
        close_event: @close_event,
        selected_name: board_name(assigns.boards, assigns.selected),
        editable_name: board_name(assigns.boards, assigns.editable_id)
      )

    ~H"""
    <div
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@close_event}
      phx-key="escape"
    >
      <div class="modal-box relative w-full max-w-[480px] rounded-[18px] border border-base-300 bg-base-100 p-5 shadow-xl">
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click={@close_event}
          class="btn btn-ghost btn-sm btn-circle absolute right-3 top-3"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
        <h2 id={"#{@id}-title"} class="text-[20px] font-semibold tracking-tight">
          Which board stays editable?
        </h2>
        <p class="mt-1 text-[13.5px] text-base-content/65">
          You're on Free now, which includes one board. The others become read-only, and nothing is deleted. Upgrade any time to unlock them all.
        </p>
        <.form
          for={to_form(%{"board_id" => to_string(@selected)})}
          id={"#{@id}-form"}
          phx-change="select_free_board"
          phx-submit="keep_free_board"
        >
          <div class="mt-4 flex flex-col gap-2">
            <label
              :for={board <- @boards}
              id={"#{@id}-option-#{board.id}"}
              class={[
                "flex cursor-pointer items-center gap-3 rounded-[12px] px-3 py-2.5",
                if(board.id == @selected,
                  do: "border-2 border-primary",
                  else: "m-px border border-base-300"
                )
              ]}
              {ring(board.id == @selected)}
            >
              <input
                type="radio"
                name="board_id"
                value={board.id}
                checked={board.id == @selected}
                class="radio radio-primary radio-sm"
              />
              <span class="size-[12px] rounded-[4px]" style={"background:#{board_color(board.slug)};"}>
              </span>
              <span class="flex-1">
                <span class="block text-sm font-semibold">{board.name}</span>
                <span class="block font-mono text-[10.5px] text-base-content/55">
                  {sub_line(board, @editable_id)}
                </span>
              </span>
            </label>
          </div>
          <div class="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:items-center">
            <a
              :if={@upgrade_href}
              id={"#{@id}-upgrade"}
              href={@upgrade_href}
              class="btn btn-ghost btn-sm"
            >
              Upgrade instead · {@upgrade_price}/mo
            </a>
            <span class="flex-1"></span>
            <button type="submit" id={"#{@id}-keep"} class="btn btn-primary btn-sm">
              Keep {@selected_name} editable
            </button>
          </div>
        </.form>
        <p id={"#{@id}-footnote"} class="mt-3 text-[11.5px] text-base-content/50">
          Closing this keeps {@editable_name} editable. You can switch any time, from Billing or from a read-only board's banner.
        </p>
      </div>
      <label class="modal-backdrop" phx-click={@close_event}>Close</label>
    </div>
    """
  end

  attr :id, :string, default: "make-editable-confirm"
  attr :board_id, :integer, required: true, doc: "the board to make editable"
  attr :board_name, :string, required: true
  attr :editable_name, :string, required: true, doc: "today's editable board, which becomes read-only"
  attr :confirm_event, :string, default: "confirm_make_editable", doc: ~s(sent with `%{"board-id" => "<id>"}`)
  attr :cancel_event, :string, default: "cancel_make_editable", doc: "sent by Cancel, the backdrop and Escape"

  def make_editable_confirm(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@cancel_event}
      phx-key="escape"
    >
      <div class="modal-box max-w-md">
        <h3 id={"#{@id}-title"} class="text-lg font-semibold">Make {@board_name} editable?</h3>
        <p class="mt-3 text-sm text-base-content/80">
          {@editable_name} becomes read-only. Nothing is deleted.
        </p>
        <div class="modal-action action-group">
          <button type="button" id={"#{@id}-cancel"} phx-click={@cancel_event} class="btn btn-ghost">
            Cancel
          </button>
          <.button
            type="button"
            id={"#{@id}-submit"}
            phx-click={@confirm_event}
            phx-value-board-id={@board_id}
            class="btn btn-primary"
            pending="Switching…"
          >
            Make editable
          </.button>
        </div>
      </div>
      <label class="modal-backdrop" phx-click={@cancel_event}>Close</label>
    </div>
    """
  end

  @doc """
  The flash when `Relay.Billing.choose_free_board/2` refuses a board (`{:error, :not_counted}`),
  shared by the read-only banner and Billing.
  """
  @spec not_counted_message() :: String.t()
  def not_counted_message, do: "That board can't be your editable board."

  # The selected row's ring. Spread as an attribute map: `style={nil}` would still render `style=""`.
  defp ring(true = _selected?),
    do: %{style: "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));"}

  defp ring(false = _selected?), do: %{}

  defp board_name(boards, id) do
    case Enum.find(boards, &(&1.id == id)) do
      nil -> ""
      board -> board.name
    end
  end

  defp sub_line(%{id: id, active_at: at}, id), do: "most active · updated #{TimeAgo.ago(at)}"
  defp sub_line(%{active_at: at}, _editable_id), do: "updated #{TimeAgo.ago(at)}"

  # A board's identity colour, as the `/boards` tiles and Billing draw it.
  defp board_color(slug), do: slug |> CoreComponents.identity_hue() |> CoreComponents.identity_color_for_hue()
end
