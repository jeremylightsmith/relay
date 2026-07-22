defmodule RelayWeb.PublicBoardLive do
  @moduledoc """
  The public, read-only roadmap (RLY-69): `/board/:slug/public`. Renders for
  signed-out visitors and signed-in users alike — mounted under the router's
  `:public` `live_session`, which uses `{RelayWeb.Auth, :mount_current_scope}`
  (assigns `current_scope`, nil when signed out) rather than
  `:require_authenticated`.

  Non-done cards (`Stage.public_categories/0`: unstarted, planning, in_progress)
  are shown collapsed into three category columns, sorted by vote count (ties
  broken by recency). Voting requires sign-in: a signed-out click opens the
  sign-in modal instead of casting a vote; the modal's "Continue with Google"
  link carries `return_to` back to this board (RLY-69's OAuth `return_to` —
  see `RelayWeb.AuthController`), so signing in returns the visitor here. A
  pending vote is **not** replayed across the OAuth round trip (YAGNI, per the
  card's decisions) — the visitor returns signed in and clicks vote again.

  The sign-in modal's title varies by why it opened (`@signin_reason`): a
  vote-triggered open shows "Sign in to vote"; the header's Sign in button
  (`Layouts.public_board`'s `phx-click="open_signin"`) opens it with the
  "browse" reason and shows "Sign in to Relay" instead — the header never
  navigates straight to OAuth, so a signed-out visitor always sees the modal
  copy first.

  Supporters (the card detail modal's SUPPORTERS block) are private to
  signed-in visitors: signed out sees only the total count ("N people support
  this. Sign in to see who."), matching `Relay.Votes.supporters/2`'s contract.

  Real-time: subscribes to the board's full `Relay.Events` topic and recomputes
  the columns (and any open detail modal) on votes and card lifecycle events
  (`{:vote_changed, _}`, `{:card_upserted, _}`, `{:card_moved, _, _}`,
  `{:card_archived, _}`) — coarse on purpose (see `Relay.Events`'s moduledoc). A
  catch-all absorbs the topic's other events (timeline/log appends, stage/board
  config), which don't affect the public roadmap; without it an unmatched message
  would crash the LiveView.

  Posting (RLY-225): the "＋ Post an idea" button (shown only when the board has
  a `public_intake_stage_id`) opens a composer modal for signed-in visitors, or
  the sign-in modal with the `:post` reason for signed-out ones. Submitting
  calls `Relay.Cards.post_public_idea/3`, which creates the card and applies the
  poster's first vote; the resulting `{:card_upserted, card}` broadcast is
  already handled by this module's existing card-lifecycle clause, so every
  open public board (including the poster's own) picks up the new idea via the
  normal column reload. A pending post is **not** replayed across the OAuth
  round trip (YAGNI, matching the vote flow) — a signed-out visitor returns
  signed in and clicks "Post an idea" again.
  """

  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Votes
  alias Schemas.Board
  alias Schemas.Stage

  @supporters_preview 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public_board
      flash={@flash}
      current_scope={@current_scope}
      board_name={@board.name}
      public_path={@public_path}
    >
      <p class="text-sm text-base-content/60">
        This is our public roadmap. Upvote the ideas you want most.
      </p>
      <div class="mt-1 flex items-center justify-between">
        <p class="text-xs text-base-content/40">
          {length(@cards)} {if(length(@cards) == 1, do: "idea", else: "ideas")} · sorted by {if(
            @sort_by == :new,
            do: "newest",
            else: "votes"
          )}
        </p>
        <div class="flex items-center gap-3">
          <div class="join">
            <button
              type="button"
              id="public-sort-votes"
              phx-click="set_sort"
              phx-value-sort="votes"
              class={["btn btn-xs join-item", @sort_by == :votes && "btn-active"]}
            >
              Top
            </button>
            <button
              type="button"
              id="public-sort-new"
              phx-click="set_sort"
              phx-value-sort="new"
              class={["btn btn-xs join-item", @sort_by == :new && "btn-active"]}
            >
              New
            </button>
          </div>
          <button
            :if={@board.public_intake_stage_id}
            type="button"
            id="open-composer"
            phx-click="open_composer"
            class="btn btn-primary btn-sm rounded-lg gap-1.5"
          >
            <span aria-hidden="true">＋</span>Post an idea
          </button>
        </div>
      </div>

      <div class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div
          :for={column <- columns(@cards, @sort_by, @vote_counts)}
          id={"public-column-#{column.key}"}
        >
          <div class="mb-2 flex items-center gap-2">
            <span class={["h-2.5 w-2.5 rounded-full", category_dot_class(column.key)]}></span>
            <h2 class="text-sm font-semibold">{column.label}</h2>
            <span data-column-count class="text-xs text-base-content/40">{column.count}</span>
          </div>

          <div class="flex flex-col gap-2">
            <div
              :for={card <- column.cards}
              id={"public-card-#{card.id}"}
              class={[
                "rounded-[11px] border border-base-300 bg-base-100 p-3",
                card.id == @new_card_id && "pb-new"
              ]}
            >
              <div
                id={"public-card-open-#{card.id}"}
                phx-click="open_card"
                phx-value-id={card.id}
                class="cursor-pointer"
              >
                <p class="text-sm font-medium">{card.title}</p>
                <p :if={card.public_description} class="mt-1 text-xs text-base-content/60">
                  {card.public_description}
                </p>
                <div class="mt-2 flex items-center gap-2">
                  <span class="text-[11px] text-base-content/40">
                    {relative_age(card.inserted_at)}
                  </span>
                  <span
                    :if={MapSet.member?(@voted_ids, card.id)}
                    class="text-[10px] font-semibold"
                    style="color:oklch(0.60 0.14 250);"
                  >
                    YOU VOTED
                  </span>
                  <span
                    :if={own_card?(@current_user, card)}
                    class="your-idea-badge font-mono text-[9.5px] font-semibold tracking-wider text-secondary uppercase"
                  >
                    YOUR IDEA
                  </span>
                </div>
              </div>
              <.support_badge
                id={"public-vote-#{card.id}"}
                count={Map.get(@vote_counts, card.id, 0)}
                voted={MapSet.member?(@voted_ids, card.id)}
                phx-click="vote"
                phx-value-id={card.id}
                data-vote-count={Map.get(@vote_counts, card.id, 0)}
                class="mt-2"
              />

              <%= if own_card?(@current_user, card) && is_nil(card.public_description) do %>
                <%= if @editing_desc_id == card.id do %>
                  <.form
                    for={to_form(%{"description" => ""}, as: :desc)}
                    id={"desc-form-#{card.id}"}
                    phx-submit="save_desc"
                    class="mt-2"
                  >
                    <input type="hidden" name="card-id" value={card.id} />
                    <textarea
                      id={"desc-editor-#{card.id}"}
                      name="desc[description]"
                      placeholder="Describe this idea for the public — one or two lines."
                      class="textarea textarea-bordered w-full min-h-[62px] text-xs"
                    ></textarea>
                    <div class="mt-2 flex gap-2">
                      <button type="submit" class="btn btn-primary btn-xs">Save</button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        phx-click="cancel_add_desc"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                <% else %>
                  <button
                    id={"add-desc-#{card.id}"}
                    type="button"
                    phx-click="start_add_desc"
                    phx-value-card-id={card.id}
                    class="mt-2 inline-flex items-center gap-1.5 text-xs font-semibold text-secondary"
                  >
                    ＋ Add a public description
                  </button>
                <% end %>
              <% end %>
            </div>

            <p :if={column.cards == []} class="text-xs text-base-content/40">Nothing here yet.</p>
          </div>
        </div>
      </div>

      <div
        :if={@open_card_id}
        id="public-card-modal"
        class="modal modal-open"
        role="dialog"
        aria-label="Card detail"
      >
        <% card = find_card(@cards, @open_card_id) %>
        <div class="modal-box max-w-lg">
          <div class="flex items-center justify-between">
            <span class="flex items-center gap-2 text-xs uppercase tracking-wider text-base-content/50">
              <span class={["h-2.5 w-2.5 rounded-full", category_dot_class(card.stage.category)]}>
              </span>
              {category_label(card.stage.category)}
            </span>
            <button
              type="button"
              id="public-card-modal-close"
              phx-click="close_card"
              class="btn btn-sm btn-circle btn-ghost"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <h3 class="mt-2 text-lg font-semibold">{card.title}</h3>
          <p class="mt-2 text-sm text-base-content/70">
            {card.public_description || "No public description yet."}
          </p>

          <div id="public-supporters" class="mt-4">
            <p class="text-xs uppercase tracking-wider text-base-content/50">
              Supporters · {@open_card_supporters_total}
            </p>
            <%= if @current_scope do %>
              <ul class="mt-2 flex flex-col gap-2">
                <li :for={supporter <- @open_card_supporters} class="flex items-center gap-2 text-sm">
                  <.avatar
                    size={24}
                    tint={:identity}
                    src={supporter.avatar_url}
                    name={supporter.name}
                    email={supporter.email}
                  />
                  <span data-supporter-name>{supporter.name || supporter.email}</span>
                  <span
                    :if={supporter.id == @current_scope.user.id}
                    data-supporter-you
                    class="text-[10px] font-semibold"
                    style="color:oklch(0.60 0.14 250);"
                  >
                    YOU
                  </span>
                </li>
              </ul>
              <p
                :if={@open_card_supporters_total > length(@open_card_supporters)}
                class="mt-2 text-xs text-base-content/40"
              >
                Show all {@open_card_supporters_total} supporters →
              </p>
            <% else %>
              <p class="mt-2 text-sm text-base-content/60">
                {@open_card_supporters_total} people support this. Sign in to see who.
              </p>
            <% end %>
          </div>

          <.support_badge
            id={"public-vote-modal-#{card.id}"}
            count={Map.get(@vote_counts, card.id, 0)}
            voted={MapSet.member?(@voted_ids, card.id)}
            size={:lg}
            phx-click="vote"
            phx-value-id={card.id}
            class="mt-4"
          />
        </div>
        <label class="modal-backdrop" phx-click="close_card">Close</label>
      </div>

      <div
        :if={@sign_in_open}
        id="public-signin-modal"
        class="modal modal-open"
        role="dialog"
        aria-label={signin_title(@signin_reason)}
      >
        <div class="modal-box max-w-sm text-center">
          <h3 class="text-lg font-semibold">{signin_title(@signin_reason)}</h3>
          <p class="mt-2 text-sm text-base-content/60">
            Sign in so your vote sticks — you can change it any time.
          </p>
          <.link
            href={~p"/auth/google?return_to=#{@public_path}"}
            id="public-signin-google"
            class="btn btn-primary mt-4 w-full"
          >
            Continue with Google
          </.link>
          <p class="mt-3 text-xs text-base-content/40">No account needed to browse — only to vote.</p>
          <button
            type="button"
            id="public-signin-close"
            phx-click="close_signin"
            class="btn btn-sm btn-ghost mt-2"
          >
            Cancel
          </button>
        </div>
        <label class="modal-backdrop" phx-click="close_signin">Close</label>
      </div>

      <div
        :if={@composer_open}
        id="public-idea-composer-modal"
        class="modal modal-open"
        role="dialog"
        aria-label="Post an idea"
        phx-window-keydown="close_composer"
        phx-key="escape"
      >
        <div class="modal-box max-w-[460px] p-0 overflow-hidden">
          <div class="border-b border-base-200 px-6 pt-5 pb-4">
            <div class="text-lg font-semibold tracking-tight">Post an idea</div>
            <div class="mt-1 text-sm text-base-content/60">
              It lands in Unstarted with your first vote on it.
            </div>
          </div>

          <.form
            for={@composer_form}
            id="public-idea-composer"
            phx-submit="submit_idea"
            class="px-6 pt-4 pb-6"
          >
            <div class="mb-1.5 font-mono text-[9.5px] font-semibold tracking-wider text-base-content/60">
              YOUR IDEA
            </div>
            <.input
              field={@composer_form[:title]}
              type="text"
              placeholder="One line — what should we build?"
              class="input input-bordered w-full"
            />

            <div class="mt-4 mb-1.5 font-mono text-[9.5px] font-semibold tracking-wider text-base-content/60">
              PUBLIC DESCRIPTION <span class="font-normal text-base-content/50">· optional</span>
            </div>
            <.input
              field={@composer_form[:public_description]}
              type="textarea"
              placeholder="Add context so others understand and vote for it."
              class="textarea textarea-bordered w-full min-h-[86px]"
            />

            <button type="submit" class="btn btn-primary mt-4 w-full">{@composer_cta}</button>

            <div
              :if={is_nil(@current_user)}
              class="mt-2.5 text-center text-[11px] text-base-content/60"
            >
              You'll sign in first, so we can credit your idea.
            </div>
          </.form>
        </div>
        <label class="modal-backdrop" phx-click="close_composer">Close</label>
      </div>
    </Layouts.public_board>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Boards.get_public_board(slug) do
      {:ok, board} ->
        if connected?(socket), do: Events.subscribe(board.id)

        current_user = current_user(socket)

        socket =
          socket
          |> assign(:board, board)
          |> assign(:public_path, ~p"/board/#{board.slug}/public")
          |> assign(:page_title, "#{board.name} · Public roadmap")
          |> assign(:sort_by, :votes)
          |> assign(:open_card_id, nil)
          |> assign(:open_card_supporters, [])
          |> assign(:open_card_supporters_total, 0)
          |> assign(:sign_in_open, false)
          |> assign(:signin_reason, :vote)
          |> assign(:current_user, current_user)
          |> assign(:composer_open, false)
          |> assign(:new_card_id, nil)
          |> assign(:composer_cta, composer_cta(current_user))
          |> assign(:composer_form, blank_composer_form())
          |> assign(:editing_desc_id, nil)
          |> assign_cards()

        {:ok, socket}

      :error ->
        raise Ecto.NoResultsError, queryable: Board
    end
  end

  @impl true
  def handle_event("open_card", %{"id" => id}, socket) do
    card_id = String.to_integer(id)
    card = find_card(socket.assigns.cards, card_id)

    {supporters, total} =
      load_supporters(card, socket.assigns.current_scope, socket.assigns.vote_counts)

    {:noreply,
     socket
     |> assign(:open_card_id, card_id)
     |> assign(:open_card_supporters, supporters)
     |> assign(:open_card_supporters_total, total)}
  end

  def handle_event("close_card", _params, socket) do
    {:noreply, assign(socket, :open_card_id, nil)}
  end

  def handle_event("vote", %{"id" => id}, socket) do
    case socket.assigns.current_scope do
      nil ->
        {:noreply, open_signin(socket, :vote)}

      %{user: user} ->
        card = find_card(socket.assigns.cards, String.to_integer(id))
        {:ok, _added_or_removed} = Votes.toggle_vote(user, card)
        {:noreply, assign_cards(socket)}
    end
  end

  # The header's Sign in button (`Layouts.public_board`) — opens the modal with
  # the "browse" reason ("Sign in to Relay") instead of navigating straight to
  # OAuth, so a signed-out visitor always sees the modal copy first.
  def handle_event("open_signin", _params, socket) do
    {:noreply, open_signin(socket, :browse)}
  end

  def handle_event("close_signin", _params, socket) do
    {:noreply, assign(socket, :sign_in_open, false)}
  end

  def handle_event("set_sort", %{"sort" => sort}, socket) do
    {:noreply, assign(socket, :sort_by, if(sort == "new", do: :new, else: :votes))}
  end

  # Signed-in opens the composer; signed-out is routed to the sign-in modal
  # with the `:post` reason ("Sign in to post") instead — posting is
  # sign-in-gated (RLY-225).
  def handle_event("open_composer", _params, socket) do
    case current_user(socket) do
      nil ->
        {:noreply, open_signin(socket, :post)}

      _user ->
        {:noreply,
         socket
         |> assign(:composer_open, true)
         |> assign(:composer_form, blank_composer_form())}
    end
  end

  def handle_event("close_composer", _params, socket) do
    {:noreply, assign(socket, :composer_open, false)}
  end

  # The four `post_public_idea/3` outcomes (RLY-225): success closes the
  # composer and marks the new card for the rise/flash entrance treatment (the
  # `{:card_upserted, card}` broadcast it fires reconciles every other open
  # public board via the existing clause below); a rate limit or missing
  # intake stage surfaces a friendly flash with the composer left open and the
  # entered text intact; an invalid changeset re-renders the form with errors.
  def handle_event("submit_idea", %{"idea" => idea_params}, socket) do
    case current_user(socket) do
      nil ->
        {:noreply, open_signin(socket, :post)}

      user ->
        case Cards.post_public_idea(socket.assigns.board, user, idea_params) do
          {:ok, card} ->
            {:noreply,
             socket
             |> assign(:composer_open, false)
             |> assign(:new_card_id, card.id)
             |> assign_cards()}

          {:error, :rate_limited} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "You're posting a lot right now — take a short break and try again."
             )}

          {:error, :no_intake_stage} ->
            {:noreply, put_flash(socket, :error, "This board isn't accepting public ideas right now.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :composer_form, to_form(changeset, as: :idea, action: :validate))}
        end
    end
  end

  # The inline "＋ Add a public description" affordance (RLY-225 Task 3) —
  # poster-only, authorized against the already-loaded board-scoped `cards`
  # assign (never a bare `Repo.get`, so a foreign id can't be targeted).
  def handle_event("start_add_desc", %{"card-id" => id}, socket) do
    card_id = String.to_integer(id)

    if own_editable_card?(socket, card_id) do
      {:noreply, assign(socket, :editing_desc_id, card_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_add_desc", _params, socket) do
    {:noreply, assign(socket, :editing_desc_id, nil)}
  end

  def handle_event("save_desc", %{"card-id" => id, "desc" => %{"description" => text}}, socket) do
    card_id = String.to_integer(id)

    with true <- own_editable_card?(socket, card_id),
         card = find_card(socket.assigns.cards, card_id),
         {:ok, _updated} <- Cards.set_public_description(card, text) do
      {:noreply,
       socket
       |> assign(:editing_desc_id, nil)
       |> assign_cards()}
    else
      _ -> {:noreply, socket}
    end
  end

  # PublicBoardLive subscribes to the FULL `board:<id>` topic (see
  # `Relay.Events`), so it must tolerate every event on it — an unmatched
  # `handle_info` crashes the LiveView. Card lifecycle events and votes refresh
  # the columns (the roadmap reflects added/moved/removed cards live); the modal
  # is reconciled so it never renders a card that left the public set. Everything
  # else on the topic (timeline/log appends, stage/board config) doesn't affect
  # the public roadmap and is absorbed by the catch-all below.
  @impl true
  def handle_info({:vote_changed, _card_id}, socket) do
    {:noreply, socket |> assign_cards() |> refresh_open_card()}
  end

  def handle_info({:card_upserted, _card}, socket) do
    {:noreply, socket |> assign_cards() |> refresh_open_card()}
  end

  def handle_info({:card_moved, _card, _from_stage_id}, socket) do
    {:noreply, socket |> assign_cards() |> refresh_open_card()}
  end

  def handle_info({:card_archived, _card}, socket) do
    {:noreply, socket |> assign_cards() |> refresh_open_card()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Reloads the board's public cards + vote counts + this visitor's voted-card
  # set — the one source of truth `columns/3` derives the rendered layout from.
  # Refetched wholesale on every vote and `{:vote_changed, _}` broadcast rather
  # than patched in place: `Relay.Events` is coarse by design (see its
  # moduledoc), and a public board is small enough that this is cheap.
  defp assign_cards(socket) do
    cards = Boards.list_public_cards(socket.assigns.board)
    card_ids = Enum.map(cards, & &1.id)
    counts = Votes.counts_for_cards(card_ids)

    voted_ids =
      case socket.assigns.current_scope do
        nil -> MapSet.new()
        %{user: user} -> Votes.voted_card_ids(user, card_ids)
      end

    socket
    |> assign(:cards, cards)
    |> assign(:vote_counts, counts)
    |> assign(:voted_ids, voted_ids)
  end

  defp find_card(cards, id), do: Enum.find(cards, &(&1.id == id))

  # True when `card` was posted by the signed-in `user` — the single source of
  # truth the YOUR IDEA badge and the inline description editor's affordance
  # both read (RLY-225 Task 3).
  defp own_card?(nil, _card), do: false
  defp own_card?(user, card), do: card.posted_by_user_id == user.id

  # Authorization for the inline description editor's events: a card the
  # signed-in user posted, resolved from the already board-scoped `cards`
  # assign so a forged `card-id` for another board/user's card is never found.
  defp own_editable_card?(socket, card_id) do
    user = socket.assigns.current_user
    card = find_card(socket.assigns.cards, card_id)
    user != nil && card != nil && own_card?(user, card)
  end

  # Opens the sign-in modal for `reason` — shared by the vote gate, the
  # header's Sign in button, and the post-an-idea gate (RLY-225), so the
  # modal's title always reflects why it opened.
  defp open_signin(socket, reason) do
    socket |> assign(:sign_in_open, true) |> assign(:signin_reason, reason)
  end

  # The signed-in user, derived from the mounted `current_scope` (nil when
  # signed out) — the single source of truth the composer gate and the
  # YOUR IDEA badge both read.
  defp current_user(socket), do: socket.assigns.current_scope && socket.assigns.current_scope.user

  defp composer_cta(nil), do: "Sign in & post →"
  defp composer_cta(_user), do: "Post idea →"

  defp blank_composer_form, do: to_form(%{"title" => "", "public_description" => ""}, as: :idea)

  # Loads the detail modal's supporter block: signed-out visitors see only the
  # count (the `vote_counts` total, per `Relay.Votes.supporters/2`'s gating);
  # signed-in visitors get the preview list with their own row moved first.
  defp load_supporters(card, nil, vote_counts), do: {[], Map.get(vote_counts, card.id, 0)}

  defp load_supporters(card, scope, _vote_counts) do
    {fetched, total} = Votes.supporters(card, @supporters_preview)
    {you_first(fetched, scope.user.id), total}
  end

  # Keeps an open detail modal consistent after the card set is refreshed: drop
  # it if its card left the public set (render/1 would crash finding it nil),
  # otherwise recompute its supporter block so an open modal reflects live vote
  # and lifecycle changes rather than going stale until reopened (RLY-69 review).
  defp refresh_open_card(%{assigns: %{open_card_id: nil}} = socket), do: socket

  defp refresh_open_card(%{assigns: %{open_card_id: card_id}} = socket) do
    case find_card(socket.assigns.cards, card_id) do
      nil ->
        socket
        |> assign(:open_card_id, nil)
        |> assign(:open_card_supporters, [])
        |> assign(:open_card_supporters_total, 0)

      card ->
        {supporters, total} =
          load_supporters(card, socket.assigns.current_scope, socket.assigns.vote_counts)

        socket
        |> assign(:open_card_supporters, supporters)
        |> assign(:open_card_supporters_total, total)
    end
  end

  # The sign-in modal's title varies by why it opened (RLY-69 spec review):
  # vote-triggered opens read "Sign in to vote"; the post-an-idea gate
  # (RLY-225) reads "Sign in to post"; every other entry point (the header's
  # Sign in button) reads "Sign in to Relay".
  defp signin_title(:vote), do: "Sign in to vote"
  defp signin_title(:post), do: "Sign in to post"
  defp signin_title(:browse), do: "Sign in to Relay"

  # Moves the signed-in viewer's own supporter entry (if present on this preview
  # page) to the front — the detail modal's "you first" ordering (RLY-69 spec
  # review). Leaves the rest of `Votes.supporters/2`'s recency order untouched.
  defp you_first(supporters, viewer_id) do
    Enum.sort_by(supporters, &(&1.id != viewer_id))
  end

  # Groups `cards` (stage preloaded) into the three public columns, each sorted
  # by vote count desc (ties broken by `cards`' own order — newest-first, since
  # `Boards.list_public_cards/1` orders that way) or by recency when `sort_by`
  # is `:new`. `Enum.sort_by/2` is a stable sort, so votes-desc naturally keeps
  # the newest-first tiebreak without a secondary key.
  defp columns(cards, sort_by, vote_counts) do
    for category <- Stage.public_categories() do
      cat_cards =
        cards
        |> Enum.filter(&(&1.stage.category == category))
        |> sort_cards(sort_by, vote_counts)

      %{key: category, label: category_label(category), cards: cat_cards, count: length(cat_cards)}
    end
  end

  defp sort_cards(cards, :new, _vote_counts), do: cards
  defp sort_cards(cards, :votes, vote_counts), do: Enum.sort_by(cards, &(-Map.get(vote_counts, &1.id, 0)))

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:planning), do: "Planning"
  defp category_label(:in_progress), do: "In progress"

  defp category_dot_class(:unstarted), do: "border-2 border-base-content/30"
  defp category_dot_class(:planning), do: "bg-secondary/70"
  defp category_dot_class(:in_progress), do: "bg-primary/70"

  # The artboard's compact relative age, in day/week/month buckets — coarser
  # than `RelayWeb.CoreComponents`'s now/m/h/d (built for recent runner
  # activity); public ideas commonly sit for weeks or months.
  defp relative_age(%DateTime{} = at) do
    days = DateTime.utc_now() |> DateTime.diff(at, :second) |> div(86_400)

    cond do
      days < 1 -> "today"
      days < 14 -> "#{days}d"
      days < 60 -> "#{div(days, 7)}w"
      true -> "#{div(days, 30)}mo"
    end
  end
end
