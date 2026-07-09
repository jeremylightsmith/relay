# Plan: RLY-10 — Change the name of a board

## Goal

Let a board owner rename their board (name only) from a new **General** pane in
`/board/settings`, and have the board title (`#board-title`) update **live** — in the acting
session and, via the MMF 18 broadcast, in every other open session on that board.

## Architecture

This is a **web-layer-only** change. The domain layer is already on `main` (commit
`5b147f1 feat(boards): update_board/2 with name validation + {:board_updated} broadcast`):

- `Schemas.Board.changeset/2` already casts `:name`, trims it, and validates
  `required` + `length(min: 1, max: 80)` with `empty_values: []` (a blank submit fails
  instead of resetting to the "My board" default).
- `Relay.Boards.change_board/2` returns an unvalidated changeset for the form.
- `Relay.Boards.update_board/2` casts **only** `:name` (`Map.take(attrs, [:name, "name"])`,
  so `slug`/`key`/`owner_id` can never be touched), persists, and on success broadcasts
  `{:board_updated, board}` on `"board:<id>"`.
- `Relay.Events` already documents the `{:board_updated, board}` event (board carried with
  **stages not preloaded**).

So NO schema, migration, or context change is needed. Two remaining pieces, one per task:

1. **`RelayWeb.BoardSettingsLive`** — add a **General** nav item + pane with a `Board name`
   form that saves via `Boards.update_board/2` (save-on-submit), flashes success, and shows
   validation errors. Default section stays **Stages** (unchanged); General is an explicit
   `?section=general` nav item placed above Stages.
2. **`RelayWeb.BoardLive`** — handle the `{:board_updated, board}` broadcast in
   `handle_info/2`. The LiveView already subscribes to `Relay.Events` in `mount/3` and
   already renders `<h1 id="board-title">{@board.name}</h1>`; it just doesn't handle this
   event yet. The broadcast board has stages unloaded, so merge only the name onto the
   already-loaded `@board` (which the drawer relies on for `@board.stages`).

## Tech

- Elixir / Phoenix LiveView 1.8, Ecto, `Phoenix.LiveViewTest`.
- Forms via `to_form/1` + `<.form for={@form}>` + the imported `<.input>` component.
- Realtime via `Relay.Events` (Phoenix.PubSub, topic `"board:<board_id>"`).

## Global Constraints (from AGENTS.md — apply to every task)

- `mix precommit` is REQUIRED and must pass before work is done — it runs compile
  (warnings-as-errors), `mix format` (Styler), `mix credo --strict`, `mix sobelow`,
  `mix deps.audit`, and the full test suite (warnings-as-errors).
- Context boundaries: `RelayWeb` may only call the domain through `Relay`'s exported
  contexts (`Relay.Boards`, `Relay.Events`); contexts never reach into the web layer.
- LiveView/HEEx rules: begin templates with `<Layouts.app flash={@flash} ...>`; always use
  `<.form for={@form} id="...">` driven by a `to_form/2` assign and the `<.input>` component
  — never access a changeset in the template; give key elements unique DOM IDs; use the
  `<.icon>` component for icons.
- Ecto: fields set programmatically (`owner_id`, `slug`, `key`) must never be cast from
  user input.
- Tests: `use RelayWeb.ConnCase, async: true`; log in with the `register_and_log_in_user`
  setup; assert with `has_element?/2` / `element/2` against DOM IDs, never raw HTML strings.
- Styler sorts `alias` blocks alphabetically — keep them sorted.

---

## Task 1: General settings pane with a Board name editor

Add a **General** nav item + pane to `BoardSettingsLive`. The pane holds a single `Board name`
field saved on submit through `Boards.update_board/2`, flashing success and surfacing the
changeset's validation error on a blank name. Default section stays Stages.

### Files

- Modify: `lib/relay_web/live/board_settings_live.ex`
- Create (test): `test/relay_web/live/board_settings_general_test.exs`

### Interfaces

**Consumes** (already on `main`, do not modify):
- `Relay.Boards.change_board(%Schemas.Board{}, attrs \\ %{}) :: Ecto.Changeset.t()` — unvalidated changeset for the form.
- `Relay.Boards.update_board(%Schemas.Board{}, attrs) :: {:ok, %Schemas.Board{}} | {:error, Ecto.Changeset.t()}` — casts `:name` only (`Map.take(attrs, [:name, "name"])`), persists, broadcasts `{:board_updated, board}`. Blank name → `{:error, changeset}` with error `"can't be blank"` on `:name`.
- `Relay.Boards.get_or_create_default_board(%Schemas.User{}) :: %Schemas.Board{}` — used in tests to read the persisted board.

**Produces** (relied on by Task 2's cross-session test):
- Settings General pane at `~p"/board/settings?section=general"` with:
  - nav link `#settings-nav-general`, pane `#general-pane`,
  - `<.form>` `#general-form` with `phx-submit="save_general"`, input `#board-name-input` bound to `@general_form[:name]`, and a submit `button` reading "Save".
  - `save_general` persists via `update_board/2`, so an open `BoardLive` receives `{:board_updated, board}`.

### Steps

- [x] **Write the failing test file** `test/relay_web/live/board_settings_general_test.exs`:

```elixir
defmodule RelayWeb.BoardSettingsGeneralTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "General pane" do
    setup :register_and_log_in_user

    test "the rail links to General and its pane shows the Board name field + Save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board/settings?section=general")

      assert has_element?(view, "#settings-nav-general")
      assert has_element?(view, "#general-pane")
      assert has_element?(view, "#board-name-input")
      assert has_element?(view, "#general-form button", "Save")
    end

    test "the Board name field is pre-filled with the current name", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/settings?section=general")

      assert view |> element("#board-name-input") |> render() =~ board.name
    end

    test "saving a new name persists it, flashes success, and reflects it in the field", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board/settings?section=general")

      html =
        view
        |> form("#general-form", board: %{name: "Launch board"})
        |> render_submit()

      assert html =~ "Board name saved."
      assert Boards.get_or_create_default_board(user).name == "Launch board"
      assert view |> element("#board-name-input") |> render() =~ "Launch board"
    end

    test "saving a blank name shows a validation error and leaves the name unchanged", %{conn: conn, user: user} do
      original = Boards.get_or_create_default_board(user).name

      {:ok, view, _html} = live(conn, ~p"/board/settings?section=general")

      html =
        view
        |> form("#general-form", board: %{name: "   "})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Boards.get_or_create_default_board(user).name == original
    end

    test "renaming never changes the board slug or key", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/settings?section=general")

      view |> form("#general-form", board: %{name: "Renamed"}) |> render_submit()

      updated = Boards.get_or_create_default_board(user)
      assert updated.slug == board.slug
      assert updated.key == board.key
    end
  end
end
```

- [x] **Run it, expect failure:** `mix test test/relay_web/live/board_settings_general_test.exs`
  (fails — no `#settings-nav-general`, no `general` section, no `save_general` handler).

- [x] **Add the `:general` section clause.** In `lib/relay_web/live/board_settings_live.ex`,
  update the private `section/1` head (currently `section(%{"section" => "keys"})` then the
  fallback) to add a `general` clause above the `keys` clause:

```elixir
  defp section(%{"section" => "general"}), do: :general
  defp section(%{"section" => "keys"}), do: :keys
  defp section(_params), do: :stages
```

- [x] **Assign the form in `mount/3`.** In the `mount/3` assign pipeline (which currently ends
  `|> assign(:lane_nonce, %{}) |> refresh_stages()`), add the `general_form` assign before
  `refresh_stages/1`:

```elixir
     |> assign(:lane_nonce, %{})
     |> assign(:general_form, to_form(Boards.change_board(board)))
     |> refresh_stages()}
```

- [x] **Add the General nav link** to the left rail, immediately **above** the existing Stages
  link (`#settings-nav-stages`), so the rail reads General → Stages → API keys:

```heex
          <.link
            patch={~p"/board/settings?section=general"}
            id="settings-nav-general"
            style={nav_style(@section == :general)}
          >
            General
          </.link>
```

- [x] **Add the General pane** inside the content pane, immediately before the
  `<section :if={@section == :stages} id="stages-pane">` block:

```heex
            <section :if={@section == :general} id="general-pane">
              <h1 style="font-size:22px;font-weight:600;letter-spacing:-0.02em;margin:0 0 6px 0;color:oklch(0.26 0.02 255);">
                General
              </h1>
              <p style="font-size:14px;line-height:1.55;color:oklch(0.50 0.02 255);margin:0 0 18px 0;max-width:560px;">
                The board's display name, shown in its header.
              </p>
              <.form
                for={@general_form}
                id="general-form"
                phx-submit="save_general"
                style="display:flex;flex-direction:column;gap:12px;max-width:420px;"
              >
                <.input field={@general_form[:name]} id="board-name-input" type="text" label="Board name" />
                <div>
                  <button type="submit" id="save-general" class="btn btn-primary btn-sm">Save</button>
                </div>
              </.form>
            </section>
```

- [x] **Add the `save_general` handler.** Place it with the other `handle_event/3` clauses
  (e.g. just after `handle_event("revoke_key", ...)`):

```elixir
  def handle_event("save_general", %{"board" => board_params}, socket) do
    case Boards.update_board(socket.assigns.board, board_params) do
      {:ok, board} ->
        {:noreply,
         socket
         |> assign(:board, board)
         |> assign(:general_form, to_form(Boards.change_board(board)))
         |> put_flash(:info, "Board name saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :general_form, to_form(changeset))}
    end
  end
```

- [x] **Run it, expect pass:** `mix test test/relay_web/live/board_settings_general_test.exs`
  (5 tests pass). Then run the neighbouring settings suites to confirm no regression:
  `mix test test/relay_web/live/board_settings_live_test.exs test/relay_web/live/board_settings_stages_test.exs`.

- [x] **Commit:** `feat(settings): General pane with a Board name editor (RLY-10)`

### Deliverable

A working General pane at `/board/settings?section=general`: the field is pre-filled with the
current name, Save persists a valid name and flashes success, a blank name is rejected inline,
and `slug`/`key` are never touched. Independently testable via the new test file.

---

## Task 2: Board title updates live on `{:board_updated}`

Make `BoardLive` react to the `{:board_updated, board}` broadcast so `#board-title` retitles
without a reload — in the acting session and in any other open session (including a rename
driven from the settings General pane built in Task 1).

### Files

- Modify: `lib/relay_web/live/board_live.ex`
- Modify (test): `test/relay_web/live/board_live_realtime_test.exs`

### Interfaces

**Consumes:**
- `Relay.Boards.update_board/2` → broadcasts `{:board_updated, %Schemas.Board{}}` (stages **not** preloaded).
- `RelayWeb.BoardSettingsLive` General pane / `#general-form` from Task 1 (cross-session test).
- `BoardLive` already: subscribes via `Events.subscribe(board.id)` in `mount/3`; renders `<h1 id="board-title">{@board.name}</h1>`; keeps stage data in `@stage_groups`/streams but the open drawer reads `@board.stages`.

**Produces:**
- `handle_info({:board_updated, %Schemas.Board{} = board}, socket)` clause that re-titles by merging only `name` onto the loaded `@board` (preserving preloaded `stages`) and updating `@page_title`.

### Steps

- [ ] **Write the failing tests.** Append two tests inside the existing
  `describe "two sessions on the same board"` block in
  `test/relay_web/live/board_live_realtime_test.exs` (its `setup` already provides
  `%{board: board, backlog: backlog, spec: spec}`). The second test also uses
  `~p"/board/settings?section=general"`, so it exercises Task 1 end-to-end:

```elixir
    test "a board rename elsewhere retitles the board live in another session",
         %{conn: conn, board: board} do
      {:ok, view_b, _html} = live(conn, ~p"/board")

      {:ok, _board} = Boards.update_board(board, %{"name" => "Relayboard HQ"})

      assert has_element?(view_b, "#board-title", "Relayboard HQ")
    end

    test "a rename from the settings General pane retitles an open board session",
         %{conn: conn} do
      {:ok, view_settings, _html} = live(conn, ~p"/board/settings?section=general")
      {:ok, view_board, _html} = live(conn, ~p"/board")

      view_settings |> form("#general-form", board: %{name: "From settings"}) |> render_submit()

      assert has_element?(view_board, "#board-title", "From settings")
    end
```

- [ ] **Run them, expect failure:** `mix test test/relay_web/live/board_live_realtime_test.exs`
  (the new tests fail — `BoardLive` ignores `{:board_updated, _}`, so `#board-title` keeps the
  old name).

- [ ] **Alias `Schemas.Board`.** In `lib/relay_web/live/board_live.ex` the alias block has
  `alias Schemas.Card` / `alias Schemas.Stage` but no `Board`. Add it in sorted position
  (before `Schemas.Card`) so Styler is satisfied:

```elixir
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage
```

- [ ] **Add the `handle_info/2` clause.** Place it with the other `{:...}` broadcast handlers
  (e.g. right after the `handle_info({:stages_changed, _board_id}, socket)` clause). Merge
  only `name` onto the loaded board so the drawer's `@board.stages` (still preloaded) is
  never replaced by an unloaded association:

```elixir
  # RLY-10 — a board rename (this or another session): retitle live. The
  # broadcast board carries no preloaded stages, so merge just the name onto
  # the already-loaded @board (the open drawer reads @board.stages).
  def handle_info({:board_updated, %Board{} = board}, socket) do
    updated = %{socket.assigns.board | name: board.name}

    {:noreply,
     socket
     |> assign(:board, updated)
     |> assign(:page_title, board.name)}
  end
```

- [ ] **Run them, expect pass:** `mix test test/relay_web/live/board_live_realtime_test.exs`
  (both new tests pass, existing ones stay green).

- [ ] **Commit:** `feat(board): retitle live on {:board_updated} broadcast (RLY-10)`

### Deliverable

Renaming a board — from the acting session's settings pane or from any other open session —
updates `#board-title` on every open `/board` live, with no reload. Fulfils the spec's
two-session acceptance criterion.

---

## Final verification

- [ ] Run the full suite for the touched surface:
  `mix test test/relay_web/live/board_settings_general_test.exs test/relay_web/live/board_live_realtime_test.exs test/relay_web/live/board_settings_live_test.exs`
- [ ] Run `mix precommit` and fix any failure before considering the work done.

## Spec coverage map

- General pane in `/board/settings`, name field + Save, persists → **Task 1**.
- Blank/invalid name rejected with a message; `slug`/`key` never touched → **Task 1** (tests
  4 & 5) + domain `update_board/2` already on `main`.
- `#board-title` reflects the new name live in the acting session → **Task 1** save handler
  re-assigns `@board`, and the acting `/board` session receives `{:board_updated}` → **Task 2**.
- `#board-title` updates live in other open sessions without reload (MMF 18) → **Task 2**.
- Existing Stages + API keys panes unchanged → **Task 1** keeps default section Stages and
  only adds a nav item + pane (regression-checked against the existing settings suites).

## Out of scope (do not implement)

Board URL slug editing, the Danger zone / archive, inline rename from the board header,
multiple boards, and any board-name history/audit — all deferred to the rest of MMF 19.
