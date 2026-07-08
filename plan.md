# Plan — MMF 15: Review gate actions (drawer review panel)

**Spec:** `docs/superpowers/specs/2026-07-08-review-gate-actions-design.md`
**Mockup:** `docs/designs/Relay Board.dc.html` lines ~408–437 (grep `READY FOR YOUR REVIEW`)
**Branch model:** trunk-based on `main`.

## Goal

A card sitting in `:in_review` gets a green action panel in the card drawer: **Approve**
it forward, **Request changes** back with a note, **Mark done**, or **Pull** to claim the
baton. Every button is a thin wrapper over context transitions that already exist —
`Relay.Cards.approve/2` and `reject/3` (MMF 13), `set_status/3` (MMF 06), `add_owner/3`
(MMF 06). **Zero new context/API/schema surface**: this MMF is drawer markup, BoardLive
handlers/assigns, two missing timeline phrases, tests, and a storybook refresh.

## Architecture

- **Panel trigger = card status `:in_review`** (stage-agnostic, first-class status).
- **Gate-only actions:** Approve / Request-changes render only when the card's *governing
  stage* is an approval gate — the card's own stage when it's a main-lane stage, or the
  sub-lane's parent otherwise (exactly mirroring the private `fetch_gate/1` guard inside
  `Relay.Cards`, which returns `{:error, :not_gated}` off a gate). The UI derives gate-ness
  from the already-loaded `@board.stages` in `BoardLive`; it never adds a second code path.
- **Always-available actions:** Mark done (→ `:done`) and Pull (signed-in user becomes an
  owner; hidden when they already own the card) render for any `:in_review` card.
- **Actor is always the signed-in user:** `{:user, current_scope.user.id}` via BoardLive's
  existing `current_actor/1`.
- **Activity + realtime for free:** the context functions already log (`:approved`,
  `:rejected`, `:status_changed`, `:owners_changed`) and broadcast (MMF 18
  `card_moved`/`card_upserted`/`timeline_appended`); BoardLive already applies those echoes.
  The acting session refreshes synchronously through the existing `apply_move/3` +
  `refresh_card/2` helpers so tests see the result in the post-event render.
- **Mutually exclusive panels by construction:** the MMF 14 needs-input panel keys on
  `status == :needs_input`, this one on `status == :in_review` — one status, one panel.

## Tech

Phoenix 1.8 LiveView, HEEx, Tailwind v4 + daisyUI, ExMachina factories,
`Phoenix.LiveViewTest`. No migrations, no new deps.

## Global constraints (copied from project rules — verbatim requirements)

- `mix precommit` is REQUIRED and must pass before a task is done: compile with warnings
  as errors, `mix format` (Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`,
  full test suite (warnings as errors). Never finish with a failing `mix precommit`.
- Boundaries enforced by `boundary`: `RelayWeb` may only call `Relay`'s exported contexts
  (`Relay.Cards`, `Relay.Boards`, `Relay.Activity` — all already consumed by `BoardLive`).
  Do NOT add context logic for this MMF.
- HEEx: class attrs with multiple conditional values use **list syntax** `class={[...]}`;
  `{...}` for attribute interpolation; `<%= %>` only in tag bodies; `<.icon>` for icons;
  forms built with `to_form/2` and rendered with `<.form for={@form}>` + `<.input>`.
- Overriding `<.input>`'s `class` means no default classes are inherited — the custom
  classes must fully style the input (the MMF 14 needs-input textarea is the precedent).
- Predicate functions end in `?` (never `is_` prefix).
- Inline oklch values must match the mockup: panel bg `oklch(0.975 0.02 155)`, border
  `oklch(0.88 0.05 155)`, label `oklch(0.46 0.10 155)`, Approve/Mark-done green
  `oklch(0.60 0.13 155)`, Send-back amber `oklch(0.70 0.13 65)`, Pull blue
  `oklch(0.60 0.14 250)`.
- LiveView tests assert against element IDs, not raw HTML.
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass.

## Reference facts for the executor (read once, trust throughout)

- Default board pipeline (seeded by `Boards.get_or_create_default_board/1`, positions
  1–7): Backlog(human) · Spec(human) · Plan(ai) · Code(ai) · Review(human) · Deploy(ai) ·
  Done(human). Board key `RLY`; the first created card is `RLY-1`. Stage column card
  containers have DOM id `#stage-col-<position>-cards`.
- `Cards.approve(card, actor)` → moves to the next **main** stage (arriving `:working` for
  an AI-meant stage, `:queued` for human-meant); at the last main stage it sets `:done` in
  place; `{:error, :not_gated}` when the governing stage has no `approval_gate`.
- `Cards.reject(card, note, actor)` → moves to the gate's `reject_to_stage_id` (or the
  gate itself when nil), posts `note` as a comment, logs `:rejected`; same
  `{:error, :not_gated}` guard.
- `Cards.set_status(card, %{status: :done}, actor)` → logs `:status_changed`.
- `Cards.add_owner(card, {:user, id}, actor)` → adds owner, logs `:owners_changed`
  (`"added <name> as owner"`); adding an existing owner is an ok no-op.
- `Boards.next_main_stage(main_stage)` → next main stage by position, or nil at the end.
- `Boards.update_stage(stage, %{approval_gate: true, reject_to_stage_id: id})` configures
  a gate (used in tests only).
- `Schemas.Activity` timeline entries expose `type`, `meta`, `actor_type`, `user_id`.
  `activity_phrase/1` in `core_components.ex` currently has **no clauses for `:approved`
  / `:rejected`** — rendering a timeline containing them would crash; Task 1 adds them.
- `register_and_log_in_user` (ConnCase) inserts a factory user named `"Test User"`.
- BoardLive already has: `current_actor/1`, `find_stage_by_id/2`, `apply_move/3`,
  `refresh_card/2`, `apply_owner_change/2`, `assign_selected_card/2`,
  `refresh_selected_after_move/2`; the drawer component is
  `RelayWeb.CoreComponents.card_drawer/1` with private helpers `user_owner?/2`,
  `waiting_label/1`, `activity_phrase/1`.

---

### Task 1: Drawer review-gate action panel — component, handlers, tests

**Files**
- Create: `test/relay_web/live/board_live_review_test.exs`
- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1` attrs + markup,
  `review_hint/1`, `activity_phrase/1` clauses for `:approved`/`:rejected`)
- Modify: `lib/relay_web/live/board_live.ex` (render attrs, six `handle_event` clauses,
  review assigns/helpers)

**Interfaces**

*Consumes (existing — do not modify):*
- `Relay.Cards.approve(card, actor)` → `{:ok, card} | {:error, :not_gated} | {:error, changeset}`
- `Relay.Cards.reject(card, note, actor)` → same shape, `note` a binary
- `Relay.Cards.set_status(card, %{status: :done}, actor)` → `{:ok, card} | {:error, changeset}`
- `Relay.Cards.add_owner(card, {:user, id}, actor)` → `{:ok, card} | {:error, changeset}`
- `Relay.Boards.next_main_stage(stage)` → `%Schemas.Stage{} | nil`
- BoardLive privates: `current_actor/1`, `find_stage_by_id/2`, `apply_move/3`,
  `refresh_card/2`, `apply_owner_change/2`

*Produces (Task 2 and tests rely on these exact names):*
- `card_drawer/1` attrs: `review_gate` (`nil` or `%{approve_label: String.t(), reject_to_name: String.t()}`),
  `reject_open` (boolean, default false), `reject_form` (form for `reject[note]`),
  `reject_error` (`String.t() | nil`)
- LiveView events: `"review_approve"`, `"review_open_reject"`, `"review_cancel_reject"`,
  `"review_reject"` (params `%{"reject" => %{"note" => note}}`), `"review_mark_done"`,
  `"review_pull"`
- DOM ids: `#review-panel`, `#review-approve`, `#review-request-changes`,
  `#review-reject-panel`, `#review-reject-form`, `#review-request-note`,
  `#review-note-error`, `#review-send-back`, `#review-cancel-reject`, `#review-actions`,
  `#review-mark-done`, `#review-pull`
- BoardLive privates: `assign_review/2`, `review_gate_info/2`, `refresh_after_review/3`,
  `empty_reject_form/0`

**Steps**

- [x] Write the failing LiveView test file `test/relay_web/live/board_live_review_test.exs`
  (full file, modeled on `board_live_needs_input_test.exs`):

```elixir
defmodule RelayWeb.BoardLiveReviewTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Comment

  setup :register_and_log_in_user

  # Default pipeline (positions 1-7): Backlog | Spec | Plan | Code(:ai) |
  # Review(:human) | Deploy(:ai) | Done. Review becomes an approval gate
  # whose reject target is Code; Code stays ungated.
  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    review = Enum.find(board.stages, &(&1.name == "Review"))
    deploy = Enum.find(board.stages, &(&1.name == "Deploy"))
    {:ok, review} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})
    %{board: board, code: code, review: review, deploy: deploy}
  end

  defp in_review_card(stage, title \\ "Review me") do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    card
  end

  test "no review panel renders for a card that is not in review", %{conn: conn, review: review} do
    {:ok, _card} = Cards.create_card(review, %{title: "Still queued"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#card-drawer")
    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
  end

  test "an in_review card on a gated stage shows the full green panel", %{conn: conn, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    assert has_element?(view, "#review-approve", "Approve → Deploy")
    assert has_element?(view, "#review-request-changes", "Request changes")
    assert has_element?(view, "#review-mark-done", "Mark done")
    assert has_element?(view, "#review-pull", "Pull")
    refute has_element?(view, "#review-request-note")
  end

  test "an in_review card on a non-gated stage shows only Mark done and Pull", %{conn: conn, code: code} do
    in_review_card(code)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
    refute has_element?(view, "#review-approve")
    refute has_element?(view, "#review-request-changes")
    assert has_element?(view, "#review-mark-done")
    assert has_element?(view, "#review-pull")
  end

  test "Approve advances the card to the next main stage and logs :approved",
       %{conn: conn, user: user, board: board, review: review, deploy: deploy} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-approve") |> render_click()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == deploy.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
    assert has_element?(view, "#stage-col-#{deploy.position}-cards .board-card", "Review me")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "approved")

    entry = reloaded |> Activity.list_timeline() |> Enum.find(&match?(%Schemas.Activity{type: :approved}, &1))
    assert entry.actor_type == :user
    assert entry.user_id == user.id
  end

  test "Request changes expands in place, names the target, and routes back with the note",
       %{conn: conn, user: user, board: board, code: code, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()

    assert has_element?(view, "#review-reject-panel", "Code")
    assert has_element?(view, "#review-request-note")
    refute has_element?(view, "#review-approve")

    view
    |> form("#review-reject-form", reject: %{note: "Tighten the error handling"})
    |> render_submit()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.stage_id == code.id
    assert reloaded.status == :working

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-timeline .timeline-comment-body", "Tighten the error handling")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "requested changes")

    timeline = Activity.list_timeline(reloaded)
    note = Enum.find(timeline, &match?(%Comment{body: "Tighten the error handling"}, &1))
    assert note.actor_type == :user
    assert note.user_id == user.id
    assert Enum.any?(timeline, &match?(%Schemas.Activity{type: :rejected}, &1))
  end

  test "Send back with an empty note is a no-op with an inline prompt",
       %{conn: conn, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()
    view |> form("#review-reject-form", reject: %{note: "   "}) |> render_submit()

    assert has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-note-error")
    assert Cards.get_card_by_ref(board, "RLY-1").status == :in_review
  end

  test "Cancel collapses the note sub-panel back to the button row", %{conn: conn, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-request-changes") |> render_click()
    assert has_element?(view, "#review-reject-panel")

    view |> element("#review-cancel-reject") |> render_click()

    refute has_element?(view, "#review-reject-panel")
    assert has_element?(view, "#review-approve")
  end

  test "Mark done sets :done, logs the status change, and removes the panel",
       %{conn: conn, user: user, board: board, code: code} do
    in_review_card(code)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#review-mark-done") |> render_click()

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert reloaded.status == :done

    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "set status to done")

    entry =
      reloaded
      |> Activity.list_timeline()
      |> Enum.find(&match?(%Schemas.Activity{type: :status_changed, meta: %{"to_status" => "done"}}, &1))

    assert entry.actor_type == :user
    assert entry.user_id == user.id
  end

  test "Pull adds the signed-in user as an owner and hides the button",
       %{conn: conn, user: user, board: board, review: review} do
    in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    assert has_element?(view, "#review-pull")

    view |> element("#review-pull") |> render_click()

    refute has_element?(view, "#review-pull")
    assert has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer-rail .rail-owner", "Test User")
    assert has_element?(view, "#card-drawer-rail .rail-active-worker", "Test User")
    assert has_element?(view, "#card-drawer-timeline .timeline-activity-phrase", "added Test User as owner")

    reloaded = Cards.get_card_by_ref(board, "RLY-1")
    assert Enum.any?(reloaded.owners, &(&1.actor_type == :user and &1.user_id == user.id))
  end
end
```

- [x] Run `mix test test/relay_web/live/board_live_review_test.exs` — expect **failures**
  (missing `#review-panel`, unknown events). The first test ("no review panel…") may pass;
  every interaction test must fail.

- [x] Implement the drawer side in `lib/relay_web/components/core_components.ex`.

  (a) Add four attrs to `card_drawer/1`, immediately after the existing
  `attr :answer_form, ...` declaration:

```elixir
  attr :review_gate, :any,
    default: nil,
    doc:
      "MMF 15 gate info for an :in_review card on a gated stage — %{approve_label: label, reject_to_name: name}; nil when the governing stage is not an approval gate (hides Approve/Request changes)"

  attr :reject_open, :boolean,
    default: false,
    doc: "whether the Request-changes note sub-panel is expanded in place"

  attr :reject_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for reject[note]; required when the card's status is :in_review"

  attr :reject_error, :string,
    default: nil,
    doc: "inline prompt shown when Send back was submitted with an empty note"
```

  (b) Insert the review panel markup between the needs-input `</section>` (the section
  with `id="needs-input-panel"`) and the Description `<section class="space-y-2">`.
  Colors are the mockup's exact oklch values (`Relay Board.dc.html` lines ~408–437):

```heex
          <section
            :if={@card.status == :in_review}
            id="review-panel"
            class="flex flex-col gap-3 rounded-[10px] p-3.5"
            style="background:oklch(0.975 0.02 155);border:1px solid oklch(0.88 0.05 155);"
          >
            <span
              class="font-mono text-[10px] font-semibold tracking-[0.05em]"
              style="color:oklch(0.46 0.10 155);"
            >
              READY FOR YOUR REVIEW
            </span>
            <p class="text-[13px] leading-normal" style="color:oklch(0.36 0.03 155);">
              {review_hint(@review_gate)}
            </p>
            <div :if={@review_gate && !@reject_open} class="flex gap-2">
              <button
                id="review-approve"
                type="button"
                phx-click="review_approve"
                class="btn btn-sm flex-1 rounded-lg border-none font-semibold text-white"
                style="background:oklch(0.60 0.13 155);"
              >
                {@review_gate.approve_label}
              </button>
              <button
                id="review-request-changes"
                type="button"
                phx-click="review_open_reject"
                class="btn btn-sm flex-1 rounded-lg bg-white font-semibold"
                style="border:1px solid oklch(0.88 0.01 255);color:oklch(0.38 0.02 255);"
              >
                Request changes
              </button>
            </div>
            <div
              :if={@review_gate && @reject_open}
              id="review-reject-panel"
              class="flex flex-col gap-2 rounded-lg bg-white p-3"
              style="border:1px solid oklch(0.90 0.02 255);"
            >
              <p class="text-xs" style="color:oklch(0.42 0.02 255);">
                Sending back to
                <b style="color:oklch(0.30 0.02 255);">{@review_gate.reject_to_name}</b>
                for the AI to address.
              </p>
              <.form
                for={@reject_form}
                id="review-reject-form"
                class="flex flex-col gap-2"
                phx-submit="review_reject"
              >
                <.input
                  field={@reject_form[:note]}
                  type="textarea"
                  id="review-request-note"
                  rows="3"
                  placeholder="What needs to change? This note goes to the AI…"
                  class="w-full resize-none rounded-[7px] p-[9px] text-[13px] leading-snug"
                  style="border:1px solid oklch(0.90 0.006 255);color:oklch(0.30 0.02 255);background:oklch(0.99 0.002 255);"
                />
                <p
                  :if={@reject_error}
                  id="review-note-error"
                  class="text-xs text-error"
                >
                  {@reject_error}
                </p>
                <div class="flex items-center gap-2">
                  <button
                    id="review-send-back"
                    type="submit"
                    class="btn btn-sm rounded-[7px] border-none font-semibold text-white"
                    style="background:oklch(0.70 0.13 65);"
                  >
                    Send back →
                  </button>
                  <button
                    id="review-cancel-reject"
                    type="button"
                    phx-click="review_cancel_reject"
                    class="btn btn-ghost btn-sm text-xs"
                    style="color:oklch(0.55 0.02 255);"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </div>
          </section>
          <div :if={@card.status == :in_review} id="review-actions" class="flex flex-wrap gap-2">
            <button
              id="review-mark-done"
              type="button"
              phx-click="review_mark_done"
              class="btn btn-sm rounded-[9px] border-none font-semibold text-white"
              style="background:oklch(0.60 0.13 155);"
            >
              Mark done
            </button>
            <button
              :if={@current_user_id && !user_owner?(@card, @current_user_id)}
              id="review-pull"
              type="button"
              phx-click="review_pull"
              class="btn btn-sm rounded-[9px] border-none font-semibold text-white"
              style="background:oklch(0.60 0.14 250);"
            >
              Pull — take this card
            </button>
          </div>
```

  (c) Add the hint helper next to `waiting_label/1`:

```elixir
  # The one-line hint under READY FOR YOUR REVIEW (MMF 15): a gated stage
  # offers the approve/send-back pair; an ungated one only the standalone
  # Mark done / Pull actions.
  defp review_hint(nil), do: "Relay AI finished this. Mark it done, or pull the card to take it over."

  defp review_hint(_gate), do: "Relay AI finished this. Approve to move it forward, or send it back with a note."
```

  (d) Add the two missing timeline phrases, after the
  `activity_phrase(%Activity{type: :commented})` clause (keep all `activity_phrase/1`
  clauses adjacent). Without these, a timeline containing an MMF 13 `:approved`/`:rejected`
  entry crashes the drawer with a `FunctionClauseError`:

```elixir
  defp activity_phrase(%Activity{type: :approved, meta: %{"from_stage" => same, "to_stage" => same}}),
    do: "approved this card as done"

  defp activity_phrase(%Activity{type: :approved, meta: meta}),
    do: "approved #{meta["from_stage"]} → #{meta["to_stage"]}"

  defp activity_phrase(%Activity{type: :rejected, meta: meta}),
    do: "requested changes — sent back to #{meta["to_stage"]}"
```

  (e) Extend the `card_drawer/1` @doc "Events emitted" paragraph: after the
  `"answer_input"` sentence, add:

```text
  and the MMF 15 review-panel events: `"review_approve"`, `"review_open_reject"`,
  `"review_cancel_reject"`, `"review_reject"` (form params `reject[note]`),
  `"review_mark_done"`, and `"review_pull"`.
```

- [x] Implement the LiveView side in `lib/relay_web/live/board_live.ex`.

  (a) In `render/1`, pass the new attrs — add these four lines to the `<.card_drawer`
  call, after `answer_form={@answer_form}`:

```heex
        review_gate={@review_gate}
        reject_open={@reject_open}
        reject_form={@reject_form}
        reject_error={@reject_error}
```

  (b) Add the event handlers immediately after the
  `def handle_event("answer_input", _params, socket), do: {:noreply, socket}` clause
  (before the first `handle_info/2`):

```elixir
  # MMF 15 — the drawer's green review panel: the four human review actions,
  # each a thin wrapper over an existing context transition (Cards.approve/
  # reject from MMF 13, set_status/add_owner from MMF 06), attributed to the
  # signed-in user. Approve/reject move the card, so the acting session
  # re-streams the source and target columns synchronously; MMF 18 echoes
  # keep every other session in sync.
  def handle_event("review_approve", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    case Cards.approve(card, current_actor(socket)) do
      {:ok, updated} -> {:noreply, refresh_after_review(socket, card, updated)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("review_approve", _params, socket), do: {:noreply, socket}

  def handle_event("review_open_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: true, reject_form: empty_reject_form(), reject_error: nil)}
  end

  def handle_event("review_cancel_reject", _params, socket) do
    {:noreply, assign(socket, reject_open: false, reject_error: nil)}
  end

  def handle_event(
        "review_reject",
        %{"reject" => %{"note" => note}},
        %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket
      ) do
    if String.trim(note) == "" do
      {:noreply,
       assign(socket,
         reject_form: to_form(%{"note" => note}, as: :reject),
         reject_error: "Add a note — the AI needs to know what to change."
       )}
    else
      case Cards.reject(card, note, current_actor(socket)) do
        {:ok, updated} -> {:noreply, refresh_after_review(socket, card, updated)}
        {:error, _reason} -> {:noreply, socket}
      end
    end
  end

  def handle_event("review_reject", _params, socket), do: {:noreply, socket}

  def handle_event("review_mark_done", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    case Cards.set_status(card, %{status: :done}, current_actor(socket)) do
      {:ok, updated} -> {:noreply, refresh_card(socket, updated)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("review_mark_done", _params, socket), do: {:noreply, socket}

  def handle_event("review_pull", _params, %{assigns: %{selected_card: %Card{status: :in_review} = card}} = socket) do
    actor = current_actor(socket)
    apply_owner_change(socket, Cards.add_owner(card, actor, actor))
  end

  def handle_event("review_pull", _params, socket), do: {:noreply, socket}
```

  (c) Add the private helpers (place them next to `refresh_card/2`):

```elixir
  # Approve/reject moved the card: re-stream the source and target stage
  # columns (and counts) exactly like any move, then refresh the drawer to
  # the updated card — status form, review panel, and timeline included.
  defp refresh_after_review(socket, %Card{} = before, %Card{} = updated) do
    socket
    |> apply_move(before.stage_id, updated)
    |> refresh_card(updated)
  end

  # MMF 15 — the drawer's review-panel assigns. Recomputed on every drawer
  # refresh so the panel appears/disappears as the status changes and the
  # note sub-panel collapses after a transition.
  defp assign_review(socket, %Card{status: :in_review} = card) do
    assign(socket,
      review_gate: review_gate_info(socket, card),
      reject_open: false,
      reject_form: empty_reject_form(),
      reject_error: nil
    )
  end

  defp assign_review(socket, _card) do
    assign(socket, review_gate: nil, reject_open: false, reject_form: empty_reject_form(), reject_error: nil)
  end

  # Gate info for the review panel, or nil when the governing stage (the
  # card's own main-lane stage, or the sub-lane's parent) is not an
  # approval gate — mirroring Cards.approve/reject's :not_gated guard so
  # Approve/Request-changes only render where the transition can succeed.
  defp review_gate_info(socket, %Card{} = card) do
    stage = find_stage_by_id(socket, card.stage_id)
    gate = if stage.lane == :main, do: stage, else: find_stage_by_id(socket, stage.parent_id)

    if gate && gate.approval_gate do
      %{approve_label: approve_label(gate), reject_to_name: reject_to_name(socket, gate)}
    end
  end

  # Mirrors Cards.approve/2 routing: next main stage by position, or done
  # in place at the board's last main stage (mockup: "Approve → Deploy").
  defp approve_label(gate) do
    case Boards.next_main_stage(gate) do
      nil -> "Approve → Done"
      %Stage{name: name} -> "Approve → #{name}"
    end
  end

  # Mirrors Cards.reject/3 routing: the gate's configured target, or the
  # gate's own main lane when unset.
  defp reject_to_name(_socket, %Stage{reject_to_stage_id: nil} = gate), do: gate.name
  defp reject_to_name(socket, %Stage{reject_to_stage_id: target_id}), do: find_stage_by_id(socket, target_id).name

  defp empty_reject_form, do: to_form(%{"note" => ""}, as: :reject)
```

  (d) Wire `assign_review/2` into every drawer-refresh path:

  - Replace `refresh_card/2` with (only change: the `assign_review` line):

```elixir
  defp refresh_card(socket, %Card{} = card) do
    timeline = Activity.list_timeline(card)

    socket
    |> assign(:selected_card, card)
    |> assign(:status_form, status_form(card))
    |> assign(:question, latest_question(card, timeline))
    |> assign(:answer_form, empty_answer_form())
    |> assign_review(card)
    |> stream(:timeline, timeline, reset: true)
    |> stream_insert(stream_name(card.stage_id), card)
  end
```

  - Replace `refresh_selected_after_move/2` with (a move can change gate-ness for an open
    `:in_review` card):

```elixir
  defp refresh_selected_after_move(socket, %Card{} = moved) do
    moved_id = moved.id

    case socket.assigns.selected_card do
      %Card{id: ^moved_id} ->
        socket
        |> assign(:selected_card, moved)
        |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))
        |> assign_review(moved)
        |> stream(:timeline, Activity.list_timeline(moved), reset: true)

      _ ->
        socket
    end
  end
```

  - In `assign_selected_card/2`: in the `%Card{}` branch add `|> assign_review(card)`
    right after `|> assign(:answer_form, empty_answer_form())`; in the `nil` branch extend
    the keyword list with `review_gate: nil, reject_open: false, reject_form: nil,
    reject_error: nil` (after `answer_form: nil`).

- [x] Run `mix test test/relay_web/live/board_live_review_test.exs` — expect **all pass**.
- [x] Run the neighbouring drawer suites to catch regressions:
  `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_needs_input_test.exs test/relay_web/live/board_live_realtime_test.exs`.
- [x] Run `mix precommit` — must be fully green (fix formatting/credo findings inline).
- [x] Commit with message:
  `feat(board): drawer review-gate action panel — approve, request changes, mark done, pull (MMF 15)`

**Deliverable:** an `:in_review` card's drawer shows the mockup's green
READY FOR YOUR REVIEW panel; Approve/Request-changes appear only on gated stages and drive
`Cards.approve/reject`; Mark done and Pull always appear and drive
`Cards.set_status`/`add_owner`; every action is attributed to the signed-in user, logged,
and reflected live on the board — proven by
`mix test test/relay_web/live/board_live_review_test.exs`.

---

### Task 2: Cross-panel regression tests, realtime coverage, storybook refresh

**Files**
- Modify: `test/relay_web/live/board_live_review_test.exs` (append two tests)
- Modify: `storybook/core_components/card_drawer.story.exs` (two `:in_review` variations)

**Interfaces**

*Consumes (produced by Task 1 — exact names):* `card_drawer/1` attrs `review_gate`
(`%{approve_label: ..., reject_to_name: ...}`), `reject_open`, `reject_form`,
`reject_error`; DOM ids `#review-panel`, `#review-actions`, `#review-approve`; also
`Relay.Cards.approve/2` and `Relay.Cards.request_input/3` (MMF 14, for the exclusivity
test), and the existing `#needs-input-panel` id.

*Produces:* nothing new — regression coverage + storybook variations
`:in_review_gated` and `:in_review_request_changes` at
`/storybook/core_components/card_drawer`.

**Steps**

- [x] Append two regression tests to `test/relay_web/live/board_live_review_test.exs`
  (inside the module, after the Pull test). These lock in behavior Task 1 should already
  satisfy — if either fails, fix the implementation, not the test:

```elixir
  test "the review and needs-input panels are mutually exclusive by status",
       %{conn: conn, review: review} do
    card = in_review_card(review)

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    assert has_element?(view, "#review-panel")
    refute has_element?(view, "#needs-input-panel")

    {:ok, _blocked} = Cards.request_input(card, "Which palette?")

    refute has_element?(view, "#review-panel")
    refute has_element?(view, "#review-actions")
    assert has_element?(view, "#needs-input-panel", "Which palette?")
  end

  test "review transitions from elsewhere update an open drawer live (MMF 18)",
       %{conn: conn, review: review} do
    {:ok, card} = Cards.create_card(review, %{title: "Live review"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    refute has_element?(view, "#review-panel")

    {:ok, card} = Cards.set_status(card, %{status: :in_review})
    assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")

    {:ok, _approved} = Cards.approve(card)
    refute has_element?(view, "#review-panel")
    assert has_element?(view, "#card-drawer .drawer-stage-chip", "Deploy")
  end
```

- [x] Run `mix test test/relay_web/live/board_live_review_test.exs` — expect **all pass**
  (fix the Task 1 implementation if not; do not weaken the assertions).

- [x] Refresh the storybook story: in
  `storybook/core_components/card_drawer.story.exs`, append two variations to the
  `variations/0` list, after the `:needs_input` variation. `current_user_id: 2` keeps the
  Pull button visible (the story card's owners are user 1 + the agent):

```elixir
      %Variation{
        id: :in_review_gated,
        attributes: %{
          id: "story-drawer-4",
          ref: "RLY-10",
          card: %{story_card() | status: :in_review, progress: nil},
          stage_name: "Review",
          stage_owner: :human,
          active_owner: :ai,
          current_user_id: 2,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "in_review", "progress" => nil}, as: :card),
          review_gate: %{approve_label: "Approve → Deploy", reject_to_name: "Code"},
          reject_form: Phoenix.Component.to_form(%{"note" => ""}, as: :reject),
          timeline: story_timeline(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      },
      %Variation{
        id: :in_review_request_changes,
        attributes: %{
          id: "story-drawer-5",
          ref: "RLY-11",
          card: %{story_card() | status: :in_review, progress: nil},
          stage_name: "Review",
          stage_owner: :human,
          active_owner: :ai,
          current_user_id: 2,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "in_review", "progress" => nil}, as: :card),
          review_gate: %{approve_label: "Approve → Deploy", reject_to_name: "Code"},
          reject_open: true,
          reject_form: Phoenix.Component.to_form(%{"note" => ""}, as: :reject),
          timeline: story_timeline(),
          comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
        }
      }
```

- [x] Verify the story compiles: `mix compile --warnings-as-errors`. If a dev server is
  easy to run, spot-check `/storybook/core_components/card_drawer` renders both new
  variations.
- [x] Run `mix precommit` — must be fully green.
- [x] Commit with message:
  `chore(board): review-panel regression tests + card_drawer storybook in_review variations (MMF 15)`
- [x] In the final report, tell the user the refreshed storybook page:
  `/storybook/core_components/card_drawer` (new variations: `in_review_gated`,
  `in_review_request_changes`).

**Deliverable:** the review panel provably co-exists with the MMF 14 needs-input panel
(one status → one panel), remote/API review transitions update an open drawer live, and
the `card_drawer` storybook documents the gated review panel in both collapsed and
request-changes states — proven by the full review test file and a green `mix precommit`.

---

## Acceptance criteria → task map (spec checklist)

- A card in `in_review` shows the review panel; approve/request-changes only on gated
  stages, mark-done/pull always → **Task 1** (panel visibility + gated/non-gated tests).
- Approve advances per the gate config; request-changes routes back per the gate config
  with the note attached to the timeline → **Task 1** (approve + request-changes tests).
- Empty note is a no-op with an inline prompt → **Task 1** (empty-note test).
- Mark done sets `done`; Pull adds the signed-in user as owner (hidden once they own it);
  each action logged with the acting user → **Task 1** (mark-done + pull tests assert
  `actor_type == :user` and `user_id`).
- All actions reuse MMF 13/06/09 context transitions — no UI-only logic fork → **Task 1**
  (handlers call `Cards.approve/reject/set_status/add_owner` only; `review_gate_info`
  derives display data, never performs transitions).
- Panel/board update live in other sessions (MMF 18) → **Task 2** (realtime test).
- Mockup fidelity (green oklch panel, expanding note sub-panel, standalone Mark done /
  Pull buttons per lines ~408–437) → **Task 1** markup + **Task 2** storybook variations.
