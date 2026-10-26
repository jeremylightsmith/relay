defmodule HamacaWeb.BoardsLive do
  @moduledoc """
  The "Your boards" home (`/boards`): a grid of the user's active boards
  plus a "New board" tile — the switcher entry point (MMF 19). Each card
  navigates to `/board/<slug>`; the board you arrived from (`?from=<slug>`)
  gets a CURRENT badge. Tiles come starred-first, then A–Z (RE395); each
  tile's star button (`toggle_star`) sets the user's personal star and
  reorders the grid in place without navigating. "New board" opens the template picker
  (RE442, `HamacaWeb.TemplatePickerComponents`; `?template=<slug>` opens it preselected), whose
  submit creates a board from the chosen template and opens the board, where its setup wizard
  (RE443) waits. The picker's 4th option (RE447) copies instead: it lists
  `Boards.copy_sources/1` (loaded once at mount), and its submit creates a plain copy of the
  chosen board (`Boards.create_board/2`'s `copy_from`); a board the user can't copy flashes the
  same refusal as an unknown one.

  RE455: both paths create the board under the **Board name** and **Card key** typed at the top
  of the picker. The key follows the name (`Schemas.Board.key_from_name/1`, no fallback) until
  the user edits the key — clearing it doesn't turn derivation back on — and every typed key is
  sanitized with the same function. A name or key `Boards.create_board/2` rejects keeps the
  picker open with the changeset's messages inline. Opening or closing the picker resets them.
  Loads fresh on navigate; the one live update is billing (RE469, below).

  RE470: a user with **zero active boards** (`first_run?`, derived from `@boards` alone and
  recomputed wherever it reloads) gets the picker in first-run mode — forced open, titled "Make
  your first board", no ✕ / Cancel / Escape / copy card, and a "Signed in as · Sign out" footer;
  `close_template_picker` is a no-op. Its name is prefilled "<first name>'s board"
  (`first_name/1`) with the key derived from it, and re-opening resets to that prefill. Behind it
  a "No boards yet" tile (`#boards-empty`) replaces the grid; below the `drawer` breakpoint the
  picker is hidden and `#first-run-mobile` asks the user to create the board on a computer.


  RE469 — the Free limit: a Free owner (`Hamaca.Billing.free_status/2`, nil otherwise) sees a quiet
  plan line beside the heading (`#boards-plan-line`, linking to `/account/billing`; hidden when
  embedded — the app sells nothing) and a READ-ONLY label on each of their own boards that is
  read-only on Free. At the limit (`not Hamaca.Billing.can_add_board?/1`, `@picker_at_limit?`) the
  picker's footer sells the upgrade instead of creating, and `create_from_template` refuses
  server-side. Both re-derive on `{:billing_changed, user_id}` from the viewer's billing topic.

  RE471 — once per drop to Free, an over-limit owner (`Hamaca.Billing.free_board_prompt?/2`,
  computed on mount, never in first-run) gets `HamacaWeb.FreeBoardComponents.free_board_dialog/1`
  (`#free-board-dialog`, `@free_board_dialog`), the editable board preselected; it never stacks
  over the picker. `select_free_board` moves the selection, `keep_free_board` stores the pick
  (`Hamaca.Billing.choose_free_board/2`; an id outside `@free_status.boards` flashes a refusal)
  and marks the prompt shown, `close_free_board_dialog` (✕, Escape, backdrop) only marks it
  shown. A `{:billing_changed, _}` that makes the prompt false (answered elsewhere) closes it.

  RE472 — Upgrade and create: at the limit the footer's **Upgrade and create →**
  (`upgrade_and_create`) validates the typed board exactly as Create does
  (`Boards.validate_new_board/2`; errors show the same way), then upgrades in place on a $0 next
  charge and creates, or sends the owner to the setup Checkout carrying the board in a signed
  `HamacaWeb.PendingBoard` token (`/boards?pending=<token>`). The return (`&setup=<id>`, connected
  mount only) completes the setup, then opens a board the token already created (a replay), else
  creates and opens it — "Upgraded. <name> is ready." — if the owner can now add one, else
  reopens the picker prefilled under the Billing page's setup flash. A bad token creates nothing.
  `?pending=` alone (a cancelled Checkout) reopens the picker prefilled. Embedded, the app sells
  nothing: no button, and the event is refused.
  """

  use HamacaWeb, :live_view

  alias Hamaca.Billing
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Members
  alias HamacaWeb.BillingLive
  alias HamacaWeb.CoreComponents
  alias HamacaWeb.FreeBoardComponents
  alias HamacaWeb.PendingBoard
  alias HamacaWeb.TemplatePickerComponents
  alias HamacaWeb.TimeAgo
  alias Schemas.Board

  @copy_refused "That board isn't available to copy. Pick another."
  @create_refused "Free includes one board. Upgrade for unlimited boards."
  @free_board_refused "That board can't be your editable board."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide embed={@embed}>
      <:title>
        <span id="boards-title">Your boards</span>
      </:title>
      <:actions>
        <.button
          type="button"
          id="top-bar-new-board"
          phx-click="open_template_picker"
          class="btn btn-sm btn-primary font-semibold"
        >
          <span class="text-[15px] leading-none">+</span> New board
        </.button>
      </:actions>
      <div id="boards-home" class="mx-auto max-w-[1120px] drawer:px-7 drawer:py-9">
        <%!-- RLY-95 · BOARDS-00 — phone-width title bar: 22px/600/-0.03em "Boards" on
              white over a hairline border (Relay Mobile.dc.html lines ~371–393). The
              mockup's search icon is deliberately skipped (Later polish). --%>
        <div
          id="boards-title-mobile"
          class="border-b border-base-300 bg-base-100 px-[18px] pb-3 pt-[6px] drawer:hidden"
        >
          <span
            class="text-[22px] font-semibold"
            style="letter-spacing:-0.03em;color:var(--color-base-content);"
          >
            Boards
          </span>
        </div>

        <div id="boards-desktop-header" class="hidden items-start justify-between gap-5 drawer:flex">
          <h1 class="m-0 text-[27px] font-semibold tracking-tight text-base-content">
            Your boards
          </h1>
          <div class="flex items-center gap-4">
            <.link
              :if={@free_status && not @embed}
              id="boards-plan-line"
              navigate={~p"/account/billing"}
              class="flex items-center gap-2 pt-2 font-mono text-[11px] text-base-content/65 no-underline hover:text-base-content"
            >
              <span class="badge badge-soft badge-neutral badge-sm font-sans">Free</span>
              <span>{plan_line(@free_status)}<span class="link link-primary">Upgrade</span></span>
            </.link>
            <div class="flex items-center gap-4 pt-2 font-mono text-[11px] text-base-content/65">
              <span class="flex items-center gap-1.5">
                <span style="width:8px;height:8px;border-radius:2px;background:var(--color-secondary);"></span>AI
              </span>
              <span class="flex items-center gap-1.5">
                <span style="width:8px;height:8px;border-radius:2px;background:var(--color-primary);"></span>HUMAN
              </span>
            </div>
          </div>
        </div>
        <p class="mb-7 mt-1 hidden max-w-[560px] text-sm leading-relaxed text-base-content/70 drawer:block">
          Each board is a shared workspace where you and {Hamaca.Brand.agent_name()} pass work between each other.
        </p>

        <%!-- RE470 · mockup A: the first-run picker sits over this tile (≥720px only). --%>
        <div
          :if={@boards == []}
          id="boards-empty"
          class="hidden min-h-[220px] flex-col items-center justify-center gap-2 rounded-[14px] border border-dashed border-base-content/20 text-center drawer:flex"
        >
          <span class="text-[15px] font-semibold">No boards yet</span>
          <span class="text-[13px] text-base-content/60">Your first board will show up here.</span>
        </div>

        <%!-- RE470 · mockup B: phones get no picker, just this screen. --%>
        <div
          :if={@first_run?}
          id="first-run-mobile"
          class="mx-auto flex max-w-[420px] flex-col items-center gap-4 px-6 pt-16 pb-10 text-center drawer:hidden"
        >
          <span class="flex size-[44px] items-center justify-center rounded-[12px] border-[1.5px] border-base-content/25 text-[22px] text-base-content/55">
            +
          </span>
          <h2 class="text-[19px] font-semibold tracking-tight">
            Create your first board on a computer
          </h2>
          <p class="max-w-[300px] text-[13.5px] leading-relaxed text-base-content/65">
            Picking a template and connecting your repo happen on a computer. Sign in there with this account, and your board will show up here once it's made.
          </p>
          <div class="mt-2 w-full max-w-[320px] rounded-[12px] border border-base-300 bg-base-200 px-4 py-3 text-left">
            <div class="text-[12px] font-semibold text-base-content/80">On your computer</div>
            <ol class="mt-1.5 list-decimal pl-4 text-[12.5px] leading-[1.6] text-base-content/70">
              <li>Sign in with this Google account</li>
              <li>Name your board and pick a template</li>
              <li>Follow the setup steps on the board</li>
            </ol>
          </div>
          <span class="mt-4 text-[12px] text-base-content/50">
            Signed in as {@current_scope.user.email}
          </span>
        </div>

        <div
          :if={@boards != []}
          class="flex flex-col gap-2.5 p-3 drawer:grid drawer:gap-4 drawer:p-0"
          style="grid-template-columns:repeat(auto-fill,minmax(324px,1fr));"
        >
          <%!-- RE395: the tile is a `relative` container, not an <a>, so the star button can be a
                SIBLING of the link (interactive content inside <a> is invalid and would navigate).
                The link wraps the name text and stretches over the whole tile with an
                `after:absolute after:inset-0` overlay; the star sits above it (`relative z-20`). --%>
          <div
            :for={b <- @boards}
            id={"board-card-#{b.slug}"}
            class={[
              "relative flex flex-col overflow-hidden rounded-[12px] border border-base-300 bg-base-100 transition hover:-translate-y-0.5 drawer:rounded-[14px] drawer:border-[var(--color-field-border)]",
              read_only?(b, @free_status) && "opacity-75"
            ]}
          >
            <div class="hidden drawer:block" style={"height:3px;background:#{accent(b.slug)};"}></div>
            <div class="flex flex-col gap-2 p-3 drawer:gap-2.5 drawer:p-4">
              <div class="flex items-center gap-2 drawer:gap-2.5">
                <span
                  class="flex size-[18px] flex-none items-center justify-center rounded-[6px] drawer:size-[22px] drawer:rounded-[7px]"
                  style={"background:#{accent(b.slug)};"}
                >
                  <%!-- neutral-content, not base-100: `accent/1` is a fixed lightness in both
                        themes, so ink drawn on it must not invert either (same treatment as
                        CoreComponents.identity_color/1's avatar text). --%>
                  <span class="hidden size-[7px] rounded-full bg-neutral-content drawer:block"></span>
                </span>
                <.link
                  navigate={~p"/board/#{b.slug}"}
                  class="text-[14px] font-semibold tracking-[-0.015em] text-base-content no-underline after:absolute after:inset-0 after:z-10 drawer:text-[15.5px] drawer:tracking-tight"
                >
                  {b.name}
                </.link>
                <span class="flex-1"></span>
                <span
                  :if={read_only?(b, @free_status)}
                  id={"board-card-#{b.slug}-read-only"}
                  class="flex items-center gap-1 font-mono text-[10px] font-semibold tracking-wide text-base-content/55"
                >
                  <.icon name="hero-lock-closed" class="size-3" /> READ-ONLY
                </span>
                <span
                  :if={b.slug == @from}
                  id={"board-card-#{b.slug}-current"}
                  class="rounded-[5px] px-1.5 py-0.5 font-mono text-[10px] font-semibold tracking-wide"
                  style="background:color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));color:color-mix(in oklab, var(--color-primary) 60%, var(--color-base-content));"
                >
                  CURRENT
                </span>
                <%!-- BOARDS-00 amber badge — phone width only. Two-type count when
                      embedded so it always agrees with the Needs-you tab (ADR 0005);
                      the web three-type sum otherwise. Keys off embed, not width. --%>
                <span
                  :if={badge_count(b, @embed) > 0}
                  id={"board-needs-you-mobile-#{b.slug}"}
                  class="rounded-[5px] border px-1.5 py-0.5 font-mono text-[8.5px] font-semibold drawer:hidden"
                  style="color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content));background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border-color:color-mix(in oklab, var(--color-warning) 45%, var(--color-base-100));"
                >
                  {badge_count(b, @embed)} NEEDS YOU
                </span>
                <button
                  type="button"
                  id={"board-star-#{b.slug}"}
                  phx-click="toggle_star"
                  phx-value-slug={b.slug}
                  aria-pressed={to_string(b.starred?)}
                  aria-label={star_label(b.starred?)}
                  title={star_label(b.starred?)}
                  class={[
                    "btn btn-ghost btn-square btn-sm -my-1.5 -mr-1.5 relative z-20",
                    if(b.starred?,
                      do: "text-base-content",
                      else: "text-base-content/40 hover:text-base-content"
                    )
                  ]}
                >
                  <.icon :if={b.starred?} name="hero-star-solid" class="size-[18px]" />
                  <.icon :if={!b.starred?} name="hero-star" class="size-[18px]" />
                </button>
              </div>
              <span
                id={"board-meta-mobile-#{b.slug}"}
                class="font-mono text-[10.5px] text-base-content/55 drawer:hidden"
              >
                {mobile_meta_label(b)}
              </span>
              <span class="hidden items-center gap-2 font-mono text-[11.5px] text-base-content/55 drawer:flex">
                {board_meta_summary(b)}
                <span
                  :if={badge_count(b, @embed) > 0}
                  id={"board-needs-you-#{b.slug}"}
                  class="badge badge-warning badge-sm font-medium"
                >
                  {badge_count(b, @embed)} need you
                </span>
              </span>
              <div
                id={"board-card-foot-#{b.slug}"}
                class="mt-[3px] hidden items-center justify-between drawer:flex"
              >
                <.member_stack id={"board-members-#{b.slug}"} members={b.members} />
                <span class="font-mono text-[10.5px] text-base-content/55">
                  Updated {TimeAgo.ago(b.updated_at)}
                </span>
              </div>
            </div>
          </div>

          <.button
            id="new-board-button"
            type="button"
            phx-click="open_template_picker"
            class="hidden min-h-[220px] flex-col items-center justify-center gap-2.5 rounded-[14px] border border-dashed border-base-content/20 bg-transparent text-base-content/65 drawer:flex"
          >
            <span class="flex size-[34px] items-center justify-center rounded-[9px] border-[1.5px] text-xl leading-none">
              +
            </span>
            <span class="text-[13px] font-semibold">New board</span>
          </.button>
        </div>
      </div>

      <.first_run_picker first_run?={@first_run?}>
        <TemplatePickerComponents.template_picker
          :if={@picker_open?}
          templates={@templates}
          selected={@picker_template}
          examples={@examples}
          copy_sources={@copy_sources}
          copy_from={@picker_copy_from}
          copy_query={@picker_copy_query}
          name={@picker_name}
          key={@picker_key}
          show_required={@picker_touched?}
          errors={@picker_errors}
          first_run={@first_run?}
          signed_in_as={@current_scope.user.email}
          upgrade_required={@picker_at_limit?}
          upgrade_price={Billing.format_dollars(Billing.price_cents())}
          upgrade_create={not @embed}
        />
      </.first_run_picker>

      <%!-- RE471: never stacked over the picker — `?template=` can open it while this is up. --%>
      <FreeBoardComponents.free_board_dialog
        :if={@free_board_dialog && not @picker_open?}
        boards={@free_status.boards}
        selected={@free_board_dialog.selected}
        editable_id={@free_status.editable_board_id}
        upgrade_price={Billing.format_dollars(Billing.price_cents())}
        upgrade_href={if(@embed, do: nil, else: ~p"/account/billing")}
      />
    </Layouts.app>
    """
  end

  attr :first_run?, :boolean, required: true
  slot :inner_block, required: true

  # RE470: in first-run the picker sits in a `hidden drawer:block` wrapper, which hides the fixed
  # panel below the drawer breakpoint where #first-run-mobile stands in (a fixed child of a
  # `display:none` parent doesn't render). Keep it outside #boards-home. Otherwise no wrapper.
  defp first_run_picker(%{first_run?: true} = assigns) do
    ~H"""
    <div id="first-run-picker" class="hidden drawer:block">{render_slot(@inner_block)}</div>
    """
  end

  defp first_run_picker(assigns), do: ~H"{render_slot(@inner_block)}"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    boards = load_boards(user)
    templates = Boards.offered_templates()
    copy_sources = Boards.copy_sources(user)

    if connected?(socket) and Billing.enabled?(), do: Billing.subscribe(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Your boards")
     |> assign_boards(boards)
     |> assign_free_limit()
     |> assign(:from, nil)
     |> assign(:templates, templates)
     |> assign(:examples, Boards.example_boards())
     |> assign(:picker_open?, false)
     |> assign(:picker_template, hd(templates).slug)
     |> assign(:copy_sources, copy_sources)
     |> assign(:picker_copy_from, copy_sources |> List.first(%{}) |> Map.get(:slug))
     |> assign(:picker_copy_query, "")
     |> open_first_run_or_reset()
     |> open_free_board_dialog()}
  end

  # RE442: `?template=<slug>` deep-links straight into the picker with that template selected;
  # a slug that names no template leaves the picker as it was. RE472: `?pending=<token>` (with
  # `setup=<id>` after Checkout, without it when the owner backed out) is the Upgrade-and-create
  # return — handled on the connected mount only (the dead render would complete the setup twice
  # and race the connected mount's create), then patched away.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :from, params["from"])

    socket =
      if known_template?(socket, params["template"]),
        do: assign(socket, picker_open?: true, picker_template: params["template"]),
        else: socket

    case params do
      %{"pending" => token} when is_binary(token) ->
        if connected?(socket), do: pending_return(socket, token, params["setup"]), else: {:noreply, socket}

      _no_pending ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_template_picker", _params, socket) do
    {:noreply, socket |> assign(:picker_open?, true) |> open_first_run_or_reset()}
  end

  # RE470: first-run has no way out but Create or Sign out — a forged close changes nothing.
  def handle_event("close_template_picker", _params, %{assigns: %{first_run?: true}} = socket), do: {:noreply, socket}

  def handle_event("close_template_picker", _params, socket) do
    {:noreply, socket |> assign(:picker_open?, false) |> reset_identity()}
  end

  # RE447: the copy card's change also carries its search text and chosen source; a
  # `copy_from` that isn't one of @copy_sources keeps the previous choice. An unknown template
  # slug is ignored, but RE455's name and key always update.
  def handle_event("select_template", params, socket) do
    slug = params["template"]

    socket =
      if known_template?(socket, slug) or slug == TemplatePickerComponents.copy_option() do
        socket
        |> assign(:picker_template, slug)
        |> assign(:picker_copy_query, params["copy_query"] || socket.assigns.picker_copy_query)
        |> assign(:picker_copy_from, copy_source_or(socket, params["copy_from"]))
      else
        socket
      end

    {:noreply, update_identity(socket, params)}
  end

  # The submitted radio wins; a submit without one falls back to the selected assign — for
  # the template and, when copying, for the source. An unknown slug (a stale or hand-edited
  # form) flashes and leaves the picker open. A copy source isn't pre-filtered here: the
  # domain's membership check refuses a board the user isn't in exactly as it refuses one
  # that doesn't exist, so both read the same flash.
  # RE455: the typed name and key travel as typed; `Schemas.Board.changeset/2` is the authority.
  def handle_event("create_from_template", params, socket) do
    {socket, attrs} = picker_submission(socket, params)
    create_board(socket, attrs)
  end

  # RE472 — at the Free limit: validate exactly as Create does, then upgrade in place on a $0 next
  # charge, or send the owner through the setup Checkout carrying the board in a signed token.
  # Embedded, the app sells nothing: the footer has no button and a forged event is refused.
  def handle_event("upgrade_and_create", params, socket) do
    {socket, attrs} = picker_submission(socket, params)
    upgrade_and_create(socket, attrs)
  end

  # RE395: sets the negation of the tile's current star (set_starred/3 sets, it doesn't
  # toggle). A slug no longer in @boards, or a membership lost under the view
  # ({:error, :not_found}), just reloads — silently. The order comes from the summaries.
  def handle_event("toggle_star", %{"slug" => slug}, socket) do
    user = socket.assigns.current_scope.user

    case Enum.find(socket.assigns.boards, &(&1.slug == slug)) do
      nil -> :ok
      board -> Boards.set_starred(user, slug, !board.starred?)
    end

    {:noreply, assign_boards(socket, load_boards(user))}
  end

  # RE471 — the one-time dialog. A change moves the selection to a board in the list (anything
  # else is ignored); keep stores it as the pick and marks the prompt shown; close only marks it
  # shown, so the computed default stays editable and no pick is written.
  def handle_event("select_free_board", params, %{assigns: %{free_board_dialog: %{}}} = socket) do
    case listed_free_board(socket, params["board_id"]) do
      nil -> {:noreply, socket}
      board_id -> {:noreply, assign(socket, :free_board_dialog, %{selected: board_id})}
    end
  end

  def handle_event("select_free_board", _params, socket), do: {:noreply, socket}

  def handle_event("keep_free_board", params, socket) do
    user = socket.assigns.current_scope.user

    with board_id when is_integer(board_id) <- listed_free_board(socket, params["board_id"]),
         {:ok, _account} <- Billing.choose_free_board(user, board_id) do
      {:ok, _account} = Billing.mark_free_board_prompted(user)
      {:noreply, socket |> assign(:free_board_dialog, nil) |> reload_billing_view()}
    else
      _refused -> {:noreply, put_flash(socket, :error, @free_board_refused)}
    end
  end

  def handle_event("close_free_board_dialog", _params, socket) do
    {:ok, _account} = Billing.mark_free_board_prompted(socket.assigns.current_scope.user)
    {:noreply, assign(socket, :free_board_dialog, nil)}
  end

  # RE469 — the viewer's standing changed (upgraded, dropped to Free, archived or restored a
  # board): re-derive the tiles, the plan line and the picker's footer in place. RE471: an open
  # dialog closes once `free_board_prompt?/2` turns false (answered elsewhere, or no longer Free).
  @impl true
  def handle_info({:billing_changed, _user_id}, socket) do
    {:noreply, socket |> reload_billing_view() |> recheck_free_board_dialog()}
  end

  defp reload_billing_view(socket) do
    socket
    |> assign(:boards, load_boards(socket.assigns.current_scope.user))
    |> assign_free_limit()
  end

  # Computed once, on mount: only for an owner `free_board_prompt?/2` says to ask (which already
  # excludes members, paying and comped owners, and an owner within the limit), never in
  # first-run, the editable board preselected.
  defp open_free_board_dialog(%{assigns: %{first_run?: true}} = socket), do: assign(socket, :free_board_dialog, nil)

  defp open_free_board_dialog(socket) do
    dialog =
      if Billing.free_board_prompt?(socket.assigns.current_scope.user, Date.utc_today()),
        do: %{selected: socket.assigns.free_status.editable_board_id}

    assign(socket, :free_board_dialog, dialog)
  end

  defp recheck_free_board_dialog(%{assigns: %{free_board_dialog: %{selected: selected}}} = socket) do
    cond do
      not Billing.free_board_prompt?(socket.assigns.current_scope.user, Date.utc_today()) ->
        assign(socket, :free_board_dialog, nil)

      listed_free_board(socket, to_string(selected)) ->
        socket

      true ->
        assign(socket, :free_board_dialog, %{selected: socket.assigns.free_status.editable_board_id})
    end
  end

  defp recheck_free_board_dialog(socket), do: socket

  # The id when it parses and names one of the viewer's counted boards (`@free_status.boards`),
  # else nil.
  defp listed_free_board(%{assigns: %{free_status: %{boards: boards}}}, raw) when is_binary(raw) do
    with {id, ""} <- Integer.parse(raw),
         true <- Enum.any?(boards, &(&1.id == id)) do
      id
    else
      _not_listed -> nil
    end
  end

  defp listed_free_board(_socket, _raw), do: nil

  defp assign_free_limit(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      free_status: Billing.free_status(user, Date.utc_today()),
      picker_at_limit?: not Billing.can_add_board?(user)
    )
  end

  # "1 of 1 boards · " at or under the limit; "3 boards · 1 editable · " over it.
  defp plan_line(%{over_limit?: true, boards: boards, limit: limit}),
    do: "#{length(boards)} boards · #{limit} editable · "

  defp plan_line(%{boards: boards, limit: limit}), do: "#{length(boards)} of #{limit} boards · "

  # Only the viewer's OWN boards are labelled, from their own `free_status` (no lookup per tile).
  defp read_only?(_board_row, nil = _free_status), do: false

  defp read_only?(board_row, free_status),
    do: Enum.any?(free_status.boards, &(&1.id == board_row.board.id and not &1.editable?))

  @doc """
  The name a first-run board is prefilled with (RE470): the first whitespace-separated word of
  the user's name; with no name, the email's local part cut at its first `.`, `+` or `_`. Case is
  kept as typed.
  """
  @spec first_name(Schemas.User.t()) :: String.t()
  def first_name(%Schemas.User{name: name, email: email}) do
    case String.split(name || "") do
      [first | _] -> first
      [] -> email |> String.split("@") |> hd() |> String.split([".", "+", "_"]) |> hd()
    end
  end

  # RE470: first-run is derived from the boards alone — never from a URL param.
  defp assign_boards(socket, boards), do: assign(socket, boards: boards, first_run?: boards == [])

  # First-run forces the picker open with the "<first name>'s board" prefill; otherwise the
  # identity row just resets to blank.
  defp open_first_run_or_reset(%{assigns: %{first_run?: true}} = socket) do
    name = "#{first_name(socket.assigns.current_scope.user)}'s board"
    socket |> assign(:picker_open?, true) |> reset_identity(name)
  end

  defp open_first_run_or_reset(socket), do: reset_identity(socket)

  defp reset_identity(socket, name \\ "") do
    assign(socket,
      picker_name: name,
      picker_key: Board.key_from_name(name),
      picker_key_touched?: false,
      picker_touched?: false,
      picker_errors: %{}
    )
  end

  # RE455: a change aimed at the key marks it touched (derivation stays off from then on, even
  # once it's cleared); until then the key follows the name. Either way it's sanitized to its
  # letters with the one `Board.key_from_name/1` the domain derives with. LiveView never patches
  # the focused input, so the `CardKeyInput` hook filters while typing.
  defp update_identity(socket, params) do
    name = params["name"] || socket.assigns.picker_name
    key_touched? = socket.assigns.picker_key_touched? or params["_target"] == ["key"]

    key =
      if key_touched?,
        do: Board.key_from_name(params["key"] || socket.assigns.picker_key),
        else: Board.key_from_name(name)

    assign(socket,
      picker_name: name,
      picker_key: key,
      picker_key_touched?: key_touched?,
      picker_touched?: true,
      picker_errors: %{}
    )
  end

  # The picker's submission as `Boards.create_board/2` attrs: the submitted radio wins, else the
  # selected assign — for the template and, when copying, for the source; the typed name and key
  # travel as typed.
  defp picker_submission(socket, params) do
    slug = params["template"] || socket.assigns.picker_template
    name = params["name"] || socket.assigns.picker_name
    key = params["key"] || socket.assigns.picker_key

    socket = assign(socket, picker_name: name, picker_key: key, picker_touched?: true)
    identity = %{name: name, key: key}

    if slug == TemplatePickerComponents.copy_option(),
      do: {socket, Map.put(identity, :copy_from, params["copy_from"] || socket.assigns.picker_copy_from)},
      else: {socket, Map.put(identity, :template, slug)}
  end

  defp known_template?(socket, slug), do: Enum.any?(socket.assigns.templates, &(&1.slug == slug))

  defp copy_source_or(socket, slug) do
    if Enum.any?(socket.assigns.copy_sources, &(&1.slug == slug)),
      do: slug,
      else: socket.assigns.picker_copy_from
  end

  # No source at all (nothing to copy) must not fall through to `create_board/2`'s
  # no-template default board.
  defp create_board(socket, %{copy_from: nil}), do: {:noreply, put_flash(socket, :error, @copy_refused)}

  defp create_board(socket, attrs) do
    user = socket.assigns.current_scope.user

    # RE469 — checked here, never inside `Boards.create_board/2` (sign-up's default board and the
    # example seeds must stay unaffected). A refusal keeps the picker open and inserts nothing.
    if Billing.can_add_board?(user),
      do: do_create_board(socket, user, attrs),
      else: {:noreply, put_flash(socket, :error, @create_refused)}
  end

  defp do_create_board(socket, user, attrs) do
    case Boards.create_board(user, attrs) do
      # RE443: a new board opens on the board itself, where its setup wizard lives.
      {:ok, board} -> {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}")}
      {:error, reason} -> {:noreply, put_create_error(socket, reason)}
    end
  end

  # How the picker reports a board `Boards.create_board/2` (or its validate-only twin) refused:
  # the template or copy source gone flashes; RE455's name/key messages show inline under their
  # fields, anything else (in practice nothing — the slug always derives) flashes. The picker stays
  # open either way.
  defp put_create_error(socket, :unknown_template),
    do: put_flash(socket, :error, "That template no longer exists. Pick another.")

  defp put_create_error(socket, :not_found), do: put_flash(socket, :error, @copy_refused)

  defp put_create_error(socket, %Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
      |> Map.take([:name, :key])

    socket = assign(socket, :picker_errors, errors)

    if errors == %{},
      do: put_flash(socket, :error, "Couldn't create that board. Check the name and key."),
      else: socket
  end

  defp upgrade_and_create(%{assigns: %{embed: true}} = socket, _attrs),
    do: {:noreply, put_flash(socket, :error, @create_refused)}

  defp upgrade_and_create(socket, %{copy_from: nil}), do: {:noreply, put_flash(socket, :error, @copy_refused)}

  defp upgrade_and_create(socket, attrs) do
    user = socket.assigns.current_scope.user

    case Boards.validate_new_board(user, attrs) do
      {:error, reason} ->
        {:noreply, put_create_error(socket, reason)}

      # The standing changed under the page (paid elsewhere, a board archived): plain Create.
      :ok ->
        if Billing.can_add_board?(user),
          do: do_create_board(socket, user, attrs),
          else: upgrade_then_create(socket, user, attrs)
    end
  end

  defp upgrade_then_create(socket, user, attrs) do
    case Billing.upgrade_without_card(user, Date.utc_today()) do
      {:ok, :paid} ->
        create_upgraded(socket, user, attrs)

      {:error, :checkout_required} ->
        return_url = url(~p"/boards?pending=#{PendingBoard.sign(user, attrs)}")

        case Billing.setup_checkout_url(user, return_url) do
          {:ok, checkout_url} -> {:noreply, redirect(socket, external: checkout_url)}
          {:error, _reason} -> {:noreply, put_flash(socket, :error, BillingLive.checkout_failed_message())}
        end
    end
  end

  defp create_upgraded(socket, user, attrs) do
    {_created_or_refused, socket} = create_upgraded_board(socket, user, attrs)
    {:noreply, socket}
  end

  # The owner just upgraded: create the board and open it with the one success flash. A refusal
  # (template removed, copy source gone, a changeset) stays on the picker like Create's.
  defp create_upgraded_board(socket, user, attrs) do
    case Boards.create_board(user, attrs) do
      {:ok, board} ->
        {:ok,
         socket
         |> put_flash(:info, "Upgraded. #{board.name} is ready.")
         |> push_navigate(to: ~p"/board/#{board.slug}")}

      {:error, reason} ->
        {:error, put_create_error(socket, reason)}
    end
  end

  # The owner backed out of Checkout (Stripe's cancel_url): reopen what they'd typed, no flash.
  defp pending_return(socket, token, nil = _setup_id) do
    socket =
      case PendingBoard.verify(token, socket.assigns.current_scope.user) do
        {:ok, pending} -> prefill_picker(socket, pending)
        {:error, _reason} -> socket
      end

    {:noreply, push_patch(socket, to: ~p"/boards")}
  end

  # Back from Checkout: complete the setup, then create the board only if the owner can now add
  # one — checked after the replay rule, since the first return already made them unlimited.
  defp pending_return(socket, token, setup_id) do
    user = socket.assigns.current_scope.user
    outcome = Billing.complete_setup(setup_id, user.id, Date.utc_today())
    socket = assign_free_limit(socket)

    with {:ok, pending} <- PendingBoard.verify(token, user),
         nil <- Boards.get_created_board(user, pending, DateTime.from_unix!(pending.issued_at)) do
      if Billing.can_add_board?(user),
        do: create_pending(socket, user, pending),
        else:
          {:noreply,
           socket |> BillingLive.put_setup_flash(outcome) |> prefill_picker(pending) |> push_patch(to: ~p"/boards")}
    else
      %Board{} = board ->
        {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}")}

      {:error, _tampered_expired_or_wrong_user} ->
        socket = socket |> BillingLive.put_setup_flash(outcome) |> assign(:picker_open?, true) |> reset_identity()
        {:noreply, push_patch(socket, to: ~p"/boards")}
    end
  end

  # A refused create stays on the prefilled picker, with the Checkout query patched away.
  defp create_pending(socket, user, pending) do
    case socket |> prefill_picker(pending) |> create_upgraded_board(user, pending_attrs(pending)) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, push_patch(socket, to: ~p"/boards")}
    end
  end

  defp pending_attrs(%{template: nil} = pending), do: Map.take(pending, [:name, :key, :copy_from])
  defp pending_attrs(pending), do: Map.take(pending, [:name, :key, :template])

  # Reopens the picker on the pending board: its name, its (already typed) key, and its template
  # — or the copy option on its source — wherever they still exist.
  defp prefill_picker(socket, pending) do
    template =
      cond do
        known_template?(socket, pending.template) -> pending.template
        pending.copy_from -> TemplatePickerComponents.copy_option()
        true -> socket.assigns.picker_template
      end

    socket
    |> assign(:picker_open?, true)
    |> reset_identity(pending.name)
    |> assign(
      picker_key: pending.key,
      picker_key_touched?: true,
      picker_template: template,
      picker_copy_from: copy_source_or(socket, pending.copy_from)
    )
  end

  # RE376: the summary facts come from the one domain definition the native switcher
  # (GET /api/all/boards) also reads; only the member stack is web-specific.
  defp load_boards(user) do
    for summary <- Cards.list_board_summaries(user) do
      Map.put(summary, :members, Members.list_members(summary.board))
    end
  end

  # Which needs-you flavor the badge shows (decision 5 / ADR 0005): embedded, the
  # two-type count that matches the Needs-you tab; on the web, the three-type sum.
  # RLY-148 adds `agent_stalled` to BOTH flavors — a dead agent needs a human wherever
  # the badge renders (the mobile Needs-you tab/feed deliberately stays status-based;
  # revisit with RLY-137).
  defp badge_count(board_row, true = _embed), do: board_row.needs_you_two_type
  defp badge_count(board_row, false = _embed), do: board_row.needs_you_count

  # BOARDS-00's phone-width meta line. Built as one string so the template can't
  # introduce whitespace inside it (the tests assert the exact text).
  defp mobile_meta_label(b) do
    activity = if b.ai_active?, do: "AI active", else: "idle"
    "#{b.stage_count} stages · #{b.card_count} cards · #{activity}"
  end

  defp star_label(true = _starred?), do: "Unstar board"
  defp star_label(false = _starred?), do: "Star board"

  defp board_meta_summary(b), do: "#{b.slug} · #{b.card_count} cards"

  # Cosmetic per-board accent from a stable hash of the slug. RE237: an identity fill like any
  # other — the hue is per-board and arbitrary, so there is no brand role to map it onto, and
  # both halves of that (the hash → hue, and the hue → colour) belong to `CoreComponents`. It
  # used to re-type `rem(:erlang.phash2(x), 360)` and a third L/C pair of its own.
  defp accent(slug), do: slug |> CoreComponents.identity_hue() |> CoreComponents.identity_color_for_hue()
end
