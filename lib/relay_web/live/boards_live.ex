defmodule RelayWeb.BoardsLive do
  @moduledoc """
  The "Your boards" home (`/boards`): a grid of the user's active boards
  plus a "New board" tile — the switcher entry point (MMF 19). Each card
  navigates to `/board/<slug>`; the board you arrived from (`?from=<slug>`)
  gets a CURRENT badge. Tiles come starred-first, then A–Z (RE395); each
  tile's star button (`toggle_star`) sets the user's personal star and
  reorders the grid in place without navigating. "New board" opens the template picker
  (RE442, `RelayWeb.TemplatePickerComponents`; `?template=<slug>` opens it preselected), whose
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
  Loads fresh on navigate (no realtime — out of scope).
  """

  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Members
  alias RelayWeb.CoreComponents
  alias RelayWeb.TemplatePickerComponents
  alias RelayWeb.TimeAgo
  alias Schemas.Board

  @copy_refused "That board isn't available to copy. Pick another."

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
          <div class="flex items-center gap-4 pt-2 font-mono text-[11px] text-base-content/65">
            <span class="flex items-center gap-1.5">
              <span style="width:8px;height:8px;border-radius:2px;background:var(--color-secondary);"></span>AI
            </span>
            <span class="flex items-center gap-1.5">
              <span style="width:8px;height:8px;border-radius:2px;background:var(--color-primary);"></span>HUMAN
            </span>
          </div>
        </div>
        <p class="mb-7 mt-1 hidden max-w-[560px] text-sm leading-relaxed text-base-content/70 drawer:block">
          Each board is a shared workspace where you and Relay AI pass work between each other.
        </p>

        <div
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
            class="relative flex flex-col overflow-hidden rounded-[12px] border border-base-300 bg-base-100 transition hover:-translate-y-0.5 drawer:rounded-[14px] drawer:border-[var(--color-field-border)]"
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
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    boards = load_boards(user)
    templates = Boards.offered_templates()
    copy_sources = Boards.copy_sources(user)

    {:ok,
     socket
     |> assign(:page_title, "Your boards")
     |> assign(:boards, boards)
     |> assign(:from, nil)
     |> assign(:templates, templates)
     |> assign(:examples, Boards.example_boards())
     |> assign(:picker_open?, false)
     |> assign(:picker_template, hd(templates).slug)
     |> assign(:copy_sources, copy_sources)
     |> assign(:picker_copy_from, copy_sources |> List.first(%{}) |> Map.get(:slug))
     |> assign(:picker_copy_query, "")
     |> reset_identity()}
  end

  # RE442: `?template=<slug>` deep-links straight into the picker with that template selected;
  # a slug that names no template leaves the picker as it was.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :from, params["from"])

    socket =
      if known_template?(socket, params["template"]),
        do: assign(socket, picker_open?: true, picker_template: params["template"]),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_template_picker", _params, socket) do
    {:noreply, socket |> assign(:picker_open?, true) |> reset_identity()}
  end

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
    slug = params["template"] || socket.assigns.picker_template
    name = params["name"] || socket.assigns.picker_name
    key = params["key"] || socket.assigns.picker_key

    socket = assign(socket, picker_name: name, picker_key: key, picker_touched?: true)
    identity = %{name: name, key: key}

    if slug == TemplatePickerComponents.copy_option(),
      do: create_board(socket, Map.put(identity, :copy_from, params["copy_from"] || socket.assigns.picker_copy_from)),
      else: create_board(socket, Map.put(identity, :template, slug))
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

    {:noreply, assign(socket, :boards, load_boards(user))}
  end

  defp reset_identity(socket) do
    assign(socket,
      picker_name: "",
      picker_key: "",
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

    case Boards.create_board(user, attrs) do
      # RE443: a new board opens on the board itself, where its setup wizard lives.
      {:ok, board} ->
        {:noreply, push_navigate(socket, to: ~p"/board/#{board.slug}")}

      {:error, :unknown_template} ->
        {:noreply, put_flash(socket, :error, "That template no longer exists. Pick another.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, @copy_refused)}

      # RE455: name/key messages show inline under their fields; anything else (in practice
      # nothing — the slug always derives) flashes. The picker stays open either way.
      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
          |> Map.take([:name, :key])

        socket = assign(socket, :picker_errors, errors)

        if errors == %{},
          do: {:noreply, put_flash(socket, :error, "Couldn't create that board. Check the name and key.")},
          else: {:noreply, socket}
    end
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
