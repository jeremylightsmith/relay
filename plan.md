# RLY-3 — Card `spec` field + markdown rendering for description / spec / plan

## Goal
Give cards a dedicated **`spec`** field (separate from the brief `description`), point the
SPEC-stage agent / pipeline config / `bin/relay` at it, and render `description`, `spec`, and
`plan` as **markdown → sanitized HTML** in the card drawer (with `spec` collapsed by default,
mirroring `plan`).

## Architecture
- **Data**: new nullable `:text` column `spec` on `cards`, cast exactly like `description`/`plan`.
- **API/CLI**: `PATCH /api/cards/:ref` accepts `spec`; it appears in both index + show JSON;
  `bin/relay spec REF TEXT` writes it (parallel to the existing `plan` command).
- **Pipeline**: `relay_config.json` SPEC stage writes the spec via `relay spec` (not `describe`);
  PLAN stage reads the `spec` field.
- **Rendering**: a new domain helper `Relay.Markdown.to_html/1` (MDEx with sanitize enabled)
  returns a `Phoenix.HTML.safe` value; the drawer interpolates it directly (no `raw/1`).
- **UI**: description/spec/plan render inside a `.card-markdown` container styled by hand-written,
  theme-aware CSS (daisyUI has no prose primitive and the Tailwind typography plugin is not
  vendored — a small scoped CSS block keeps the build tooling unchanged and reads in light + dark).

## Tech
Elixir / Phoenix 1.8 / LiveView, Ecto + Postgres, MDEx (promoted to a first-class dep),
daisyUI + Tailwind v4, `bin/relay` (Python CLI), `relay_config.json` (runner pipeline).

## Global Constraints (from AGENTS.md — copied verbatim, apply to every task)
- Running `mix precommit` is REQUIRED on every development cycle and must pass before work is
  considered done. It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings as
  errors). Fix any failure before finishing — never commit work with a failing `mix precommit`.
- Context boundaries are enforced by `boundary` (wired into the compiler). The web layer
  (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may not
  reach into the web layer. Each context is its own sub-boundary declared in `lib/relay.ex` —
  when you add a context, give it `use Boundary` and add it to `Relay`'s `exports`.
- Never use map access syntax on structs; use `Ecto.Changeset.get_field/2` for changesets.
- Fields set programmatically (e.g. `board_id`) must not be in `cast` calls; `spec` is
  user/agent-supplied so it *is* cast.
- HEEx: interpolate values in tag bodies with `{...}`; never call `<.flash_group>` outside
  `layouts.ex`; class lists use `[...]` syntax.
- Storybook is the home for reusable components; mirror any theme/CSS change into
  `assets/css/storybook.css`.
- Never use `@apply` in raw CSS.

---

## Task 1: Data + API + CLI + pipeline — carry `spec` end-to-end

Adds the `spec` column, casts it, exposes it over the REST API and `bin/relay`, and repoints the
pipeline prompts. One coherent vertical slice: after this task a card can carry a `spec` through
DB → API → CLI, and the SPEC/PLAN agents use it.

**Files**
- Modify: `lib/schemas/card.ex`
- Create: `priv/repo/migrations/<timestamp>_add_spec_to_cards.exs` (via `mix ecto.gen.migration`)
- Modify: `lib/relay_web/controllers/api/card_controller.ex`
- Modify: `lib/relay_web/controllers/api/card_json.ex`
- Modify: `bin/relay`
- Modify: `relay_config.json`
- Test: `test/schemas/card_test.exs` (add cases)
- Test: `test/relay_web/api/card_controller_test.exs` (add cases)

**Interfaces**
- Consumes (existing): `Cards.update_card/2 :: (%Schemas.Card{}, map) -> {:ok, %Schemas.Card{}} | {:error, changeset}`;
  `Cards.ref/2`; `Card.changeset/2`.
- Produces:
  - `Schemas.Card` struct gains field `spec :: String.t() | nil`, cast by `Card.changeset/2`.
  - `RelayWeb.Api.CardJSON.data/2` map gains key `spec: card.spec` (present on index + show).
  - `bin/relay`: `set_spec(ref, text)` and the `spec REF TEXT` subcommand.

### Steps

- [x] **Failing schema test.** In `test/schemas/card_test.exs`, inside `describe "changeset/2"`,
  add:
  ```elixir
  test "casts spec and treats it as optional (nullable)" do
    changeset = Card.changeset(%Card{}, %{title: "T", spec: "## Design\n\nDetails"})

    assert changeset.valid?
    assert get_field(changeset, :spec) == "## Design\n\nDetails"

    without = Card.changeset(%Card{}, %{title: "T"})
    assert without.valid?
    assert get_field(without, :spec) == nil
  end
  ```
- [x] Run `mix test test/schemas/card_test.exs` — expect failure (`spec` is not yet a field/cast;
  `get_field` returns `nil` for the set case, or a `KeyError`/no-cast so the `== "## Design…"`
  assertion fails).
- [x] **Migration.** Run `mix ecto.gen.migration add_spec_to_cards`, then overwrite the generated
  file body so it reads exactly:
  ```elixir
  defmodule Relay.Repo.Migrations.AddSpecToCards do
    use Ecto.Migration

    def change do
      alter table(:cards) do
        add :spec, :text
      end
    end
  end
  ```
- [x] Run `mix ecto.migrate` (updates the dev DB + `priv/repo/structure.sql`/schema).
- [x] **Schema field + cast + moduledoc.** In `lib/schemas/card.ex`:
  - Add the field right after `field :description, :string`:
    ```elixir
    field :spec, :string
    ```
  - Add `:spec` to the `cast/2` list in `changeset/2` (after `:description`):
    ```elixir
    |> cast(attrs, [:title, :description, :spec, :tag, :branch, :plan, :pr_url])
    ```
  - Update the moduledoc: after the `branch`/`plan` sentence add
    `` `spec` (RLY-3) carries the design spec authored at the SPEC stage — nullable, cast like `description`/`plan`. ``
    and add `:spec` to the changeset `@doc` field list.
- [x] Run `mix test test/schemas/card_test.exs` — expect pass.

- [x] **Failing API test.** In `test/relay_web/api/card_controller_test.exs`, add:
  ```elixir
  test "PATCH sets spec and GET /api/cards/:ref returns it",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Spec card")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{spec: "## Design\n\nThe spec body"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["spec"] == "## Design\n\nThe spec body"

    fetched = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert fetched["spec"] == "## Design\n\nThe spec body"
  end

  test "GET /api/cards index includes spec", %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage, title: "Spec card")
    {:ok, _card} = Cards.update_card(card, %{spec: "the spec"})

    [card_json] = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data")
    assert card_json["spec"] == "the spec"
  end
  ```
- [x] Run `mix test test/relay_web/api/card_controller_test.exs` — expect failure (`spec` not in
  the allow-list, so PATCH ignores it; and `spec` not in `data/2`, so JSON has no `"spec"` key).
- [x] **Allow `spec` in the API.** In `lib/relay_web/controllers/api/card_controller.ex`,
  `update_fields/2`, add `"spec"` to the `Map.take/2` list:
  ```elixir
  case Map.take(params, ["title", "description", "spec", "tag", "branch", "plan", "pr_url"]) do
  ```
- [x] **Expose `spec` in JSON.** In `lib/relay_web/controllers/api/card_json.ex`, `data/2`, add
  `spec: card.spec` right after the `plan:` line:
  ```elixir
  plan: card.plan,
  spec: card.spec,
  pr_url: card.pr_url,
  ```
- [x] Run `mix test test/relay_web/api/card_controller_test.exs` — expect pass.

- [x] **`bin/relay` writer + subcommand.** In `bin/relay`:
  - After `set_description(...)` add:
    ```python
    def set_spec(ref, text):
        return api("PATCH", f"/api/cards/{ref}", {"spec": text})["data"]
    ```
  - In `build_parser`, register the subcommand right after the `describe` line:
    ```python
    add("spec", _simple(lambda a: set_spec(a.ref, read_arg(a.text))), "ref", "text", json_flag=True)
    ```
  - In `print_card`, print the spec after the description, before the timeline loop:
    ```python
    print(c.get("description") or "(no description)")
    if c.get("spec"):
        print("\n--- spec ---")
        print(c["spec"])
    for e in c.get("timeline") or []:
    ```
- [x] Verify the CLI parses: `python3 bin/relay spec --help` (should show `ref text` usage and
  exit 0). *(No Elixir test harness exists for the Python CLI; the API test above proves the
  `spec` field round-trips, which is all the CLI relies on.)*

- [x] **Pipeline prompts.** In `relay_config.json`:
  - `_comment`: change `spec=description` to `spec=spec field`
    (in `State travels on the card: spec=description, plan=plan field, …`).
  - SPEC stage action: change
    `set it as the card's description: \`{relay} describe {ref} @<that file>\``
    to
    `set it as the card's spec: \`{relay} spec {ref} @<that file>\``.
  - PLAN stage action: change `its description is the approved spec` to
    `` its `spec` field is the approved spec ``.
- [x] Validate JSON stays parseable: `python3 -c "import json; json.load(open('relay_config.json'))"`.

- [x] **Deliverable:** a card carries `spec` through DB, API (index + show), and `bin/relay`; the
  SPEC/PLAN pipeline prompts reference `spec`. Run `mix precommit` — expect green.
- [x] Commit: `git commit -am "feat(cards): spec field across schema, API, CLI, and pipeline (RLY-3)"`

---

## Task 2: `Relay.Markdown` helper + MDEx dep

A self-contained domain module that renders card markdown to sanitized HTML. Own module boundary,
so it is isolated and independently testable.

**Files**
- Modify: `mix.exs` (promote `:mdex` to a first-class dep)
- Modify: `lib/relay.ex` (export `Markdown`)
- Create: `lib/relay/markdown.ex`
- Test: `test/relay/markdown_test.exs`

**Interfaces**
- Consumes: MDEx (`MDEx.to_html!/2`, `MDEx.Document.default_sanitize_options/0`).
- Produces: `Relay.Markdown.to_html/1 :: (String.t() | nil) -> Phoenix.HTML.safe()`
  (returns a `{:safe, iodata}` tuple; `nil -> {:safe, ""}`). Sanitized, so safe to interpolate
  in HEEx with `{...}` and no `raw/1`.

### Steps

- [ ] **Promote MDEx to a first-class dep.** In `mix.exs` `deps/0`, add after
  `{:bandit, "~> 1.5"},`:
  ```elixir

      # --- Markdown rendering for card long-form fields (RLY-3) ---
      {:mdex, "~> 0.13"},
  ```
  (Version `~> 0.13` matches the already-locked `0.13.3` pulled transitively via
  `phoenix_storybook`, so no lock churn.)
- [ ] Run `mix deps.get` — confirm no new download / lock change beyond adding the top-level entry.

- [ ] **Failing helper test.** Create `test/relay/markdown_test.exs`:
  ```elixir
  defmodule Relay.MarkdownTest do
    use ExUnit.Case, async: true

    alias Relay.Markdown

    describe "to_html/1" do
      test "renders bold markdown to a <strong> element" do
        {:safe, html} = Markdown.to_html("**bold**")
        assert html =~ "<strong>bold</strong>"
      end

      test "renders a heading and a list" do
        {:safe, html} = Markdown.to_html("# Title\n\n- one\n- two")
        assert html =~ "<h1>Title</h1>"
        assert html =~ "<li>one</li>"
      end

      test "nil renders to an empty safe string" do
        assert Markdown.to_html(nil) == {:safe, ""}
      end

      test "always returns a Phoenix.HTML safe value" do
        assert {:safe, _} = Markdown.to_html("plain text")
      end

      test "strips a raw <script> tag and its content (XSS guard)" do
        {:safe, html} = Markdown.to_html("hello <script>alert('xss')</script> world")
        refute html =~ "<script"
        refute html =~ "alert('xss')"
        assert html =~ "hello"
      end
    end
  end
  ```
- [ ] Run `mix test test/relay/markdown_test.exs` — expect failure (`Relay.Markdown` undefined).

- [ ] **Implement the module.** Create `lib/relay/markdown.ex`:
  ```elixir
  defmodule Relay.Markdown do
    @moduledoc """
    Renders card long-form markdown (`description`, `spec`, `plan`) to sanitized
    HTML for display in the card drawer.

    MDEx renders the markdown with raw-HTML pass-through (`unsafe: true`) and then
    runs its HTML sanitizer (`MDEx.Document.default_sanitize_options/0`), so any
    agent- or human-authored markdown has dangerous tags (e.g. `<script>`) and
    their content stripped before it reaches the page. The result is wrapped as a
    `Phoenix.HTML.safe` value for direct `{...}` interpolation in HEEx — templates
    never call `raw/1` on it.
    """

    use Boundary, deps: []

    @doc """
    Render markdown to a sanitized `Phoenix.HTML.safe` value. `nil` renders to an
    empty (safe) string.
    """
    @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
    def to_html(nil), do: {:safe, ""}

    def to_html(markdown) when is_binary(markdown) do
      html =
        MDEx.to_html!(markdown,
          render: [unsafe: true],
          sanitize: MDEx.Document.default_sanitize_options()
        )

      {:safe, html}
    end
  end
  ```
  *(Building the `{:safe, html}` tuple directly — instead of `Phoenix.HTML.raw/1` — keeps
  `mix sobelow` clean: there is no `raw/1` call to flag, and the HTML is already sanitized.)*
- [ ] **Export the boundary.** In `lib/relay.ex`, add `Markdown` to the `exports` list:
  ```elixir
  exports: [Repo, Mailer, Accounts, Activity, ApiKeys, Boards, Cards, Events, Markdown]
  ```
- [ ] Run `mix test test/relay/markdown_test.exs` — expect pass.
- [ ] **Deliverable:** `Relay.Markdown.to_html/1` renders sanitized markdown and is reachable from
  the web layer. Run `mix precommit` — expect green.
- [ ] Commit: `git commit -am "feat(markdown): Relay.Markdown sanitized renderer + MDEx dep (RLY-3)"`

---

## Task 3: Drawer UI — render markdown + add the Spec section

Renders description/spec/plan as sanitized HTML in the card drawer, adds a collapsed **Spec**
section between Description and Plan, and adds theme-aware markdown CSS. Updates the existing drawer
tests whose assertions assumed raw/`<pre>` rendering.

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1`)
- Modify: `assets/css/app.css` (add `.card-markdown` block)
- Modify: `assets/css/storybook.css` (mirror the same block)
- Test: `test/relay_web/live/board_live_test.exs` (update description + plan tests, add spec tests)
- Test: `test/relay_web/live/board_live_realtime_test.exs` (update plan assertion)

**Interfaces**
- Consumes: `Relay.Markdown.to_html/1` (Task 2); `@card.spec` field (Task 1).
- Produces: drawer DOM — `#card-drawer-description-view.card-markdown`,
  `details#card-spec` with `#card-spec-body.card-markdown`, and `#card-plan-body.card-markdown`.

### Steps

- [ ] **Update the existing description tests to expect rendered markdown.** In
  `test/relay_web/live/board_live_test.exs`:
  - Replace the test `"saving the description persists and renders it whitespace-preserved"`
    (currently asserts `.whitespace-pre-wrap` and `=~ "Line one\n\nLine two"`) with:
    ```elixir
    test "saving the description persists and renders it as markdown",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-description-edit") |> render_click()

      view
      |> form("#card-drawer-description-form", card: %{description: "para one\n\n**bold** two"})
      |> render_submit()

      refute has_element?(view, "#card-drawer-description-form")
      assert has_element?(view, "#card-drawer-description-view.card-markdown")

      rendered = view |> element("#card-drawer-description-view") |> render()
      assert rendered =~ "<p>para one</p>"
      assert rendered =~ "<strong>bold</strong>"

      # the edit path keeps the raw markdown source
      assert Repo.get!(Card, card.id).description == "para one\n\n**bold** two"
    end
    ```
  - In the test `"a saved description survives a fresh deep-link visit"`, change the fixture text
    to a single line and update the assertions:
    ```elixir
    test "a saved description survives a fresh deep-link visit", %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{description: "Persisted text"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-description-view.card-markdown")
      assert view |> element("#card-drawer-description-view") |> render() =~ "Persisted text"
    end
    ```
- [ ] **Update the existing plan test.** In the `"drawer plan and branch"` describe of
  `test/relay_web/live/board_live_test.exs`, replace the body of
  `"a card with a plan renders the Plan section collapsed by default"` assertions with:
  ```elixir
      {:ok, _card} = Cards.update_card(card, %{plan: "## Task 1\n\n- [ ] do the thing"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "details#card-plan .collapse-title", "Plan")
      assert has_element?(view, "details#card-plan #card-plan-body.card-markdown", "do the thing")
      # markdown renders as HTML, not raw source
      assert view |> element("#card-plan-body") |> render() =~ "<h2>Task 1</h2>"
      refute has_element?(view, "details#card-plan[open]")
  ```
  Also add spec coverage in this same describe:
  ```elixir
    test "a card with a spec renders the Spec section collapsed by default",
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.update_card(card, %{spec: "## Design\n\n**Key** decision"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "details#card-spec .collapse-title", "Spec")
      assert has_element?(view, "details#card-spec #card-spec-body.card-markdown")

      rendered = view |> element("#card-spec-body") |> render()
      assert rendered =~ "<h2>Design</h2>"
      assert rendered =~ "<strong>Key</strong>"
      # collapsed by default: no open attribute
      refute has_element?(view, "details#card-spec[open]")
    end

    test "a card with no spec renders no Spec section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      refute has_element?(view, "#card-spec")
    end
  ```
- [ ] **Update the realtime plan assertion.** In `test/relay_web/live/board_live_realtime_test.exs`,
  in `"an API branch/plan update refreshes another session's open drawer"`, replace:
  ```elixir
      assert has_element?(view, "details#card-plan pre#card-plan-body", "Step 1: do it")
  ```
  with:
  ```elixir
      assert has_element?(view, "details#card-plan #card-plan-body.card-markdown", "Step 1: do it")
  ```
- [ ] Run `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs`
  — expect failure (the drawer still emits `<pre>`/`whitespace-pre-wrap`, has no `#card-spec`, and
  does not render markdown HTML).

- [ ] **Render markdown in the description view.** In `lib/relay_web/components/core_components.ex`,
  inside `card_drawer/1`, replace the description `<p>` (the `:if={@card.description}` element with
  id `#{@id}-description-view`) with:
  ```heex
  <div
    :if={@card.description}
    id={"#{@id}-description-view"}
    class="card-markdown"
  >{Relay.Markdown.to_html(@card.description)}</div>
  ```
  (Leave the surrounding `#card-drawer-description-edit` click-to-edit wrapper, the
  `:if={!@card.description}` "Add a description…" placeholder, and the edit `<.form>` textarea
  unchanged — the textarea keeps binding the raw `@card.description`.)
- [ ] **Add the Spec section.** Immediately after the Description `</section>` and *before* the
  Plan `<details>`, insert:
  ```heex
  <details
    :if={@card.spec}
    id="card-spec"
    class="collapse collapse-arrow rounded-lg border border-base-300 bg-base-200/40"
  >
    <summary class="collapse-title min-h-0 py-3 font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60">
      Spec
    </summary>
    <div class="collapse-content">
      <div id="card-spec-body" class="card-markdown">{Relay.Markdown.to_html(@card.spec)}</div>
    </div>
  </details>
  ```
- [ ] **Render markdown in the Plan section.** Replace the Plan `<pre id="card-plan-body" …>` body
  with a rendered container (keep the surrounding `details#card-plan` and its summary as-is):
  ```heex
  <div class="collapse-content">
    <div id="card-plan-body" class="card-markdown">{Relay.Markdown.to_html(@card.plan)}</div>
  </div>
  ```
- [ ] **Add theme-aware markdown CSS.** Append to `assets/css/app.css`:
  ```css
  /* --- Rendered card markdown (description / spec / plan): MDEx → sanitized HTML.
     daisyUI has no prose primitive and the Tailwind typography plugin isn't vendored,
     so style the small tag set MDEx emits. Colors use daisyUI theme tokens, so it
     reads in light and dark. --- */
  .card-markdown {
    font-size: 0.8125rem;
    line-height: 1.6;
    color: var(--color-base-content);
    word-break: break-word;
  }
  .card-markdown > :first-child { margin-top: 0; }
  .card-markdown > :last-child { margin-bottom: 0; }
  .card-markdown h1,
  .card-markdown h2,
  .card-markdown h3,
  .card-markdown h4 {
    font-weight: 600;
    line-height: 1.3;
    margin: 1em 0 0.4em;
  }
  .card-markdown h1 { font-size: 1.15rem; }
  .card-markdown h2 { font-size: 1.05rem; }
  .card-markdown h3 { font-size: 0.95rem; }
  .card-markdown p { margin: 0.6em 0; }
  .card-markdown ul,
  .card-markdown ol { margin: 0.6em 0; padding-left: 1.4em; }
  .card-markdown ul { list-style: disc; }
  .card-markdown ol { list-style: decimal; }
  .card-markdown li { margin: 0.2em 0; }
  .card-markdown a { color: var(--color-primary); text-decoration: underline; }
  .card-markdown strong { font-weight: 600; }
  .card-markdown code {
    font-family: ui-monospace, "SFMono-Regular", Menlo, monospace;
    font-size: 0.85em;
    background: var(--color-base-200);
    padding: 0.1em 0.3em;
    border-radius: 0.25rem;
  }
  .card-markdown pre {
    background: var(--color-base-200);
    padding: 0.75rem;
    border-radius: var(--radius-field);
    overflow-x: auto;
    margin: 0.7em 0;
  }
  .card-markdown pre code { background: none; padding: 0; }
  .card-markdown blockquote {
    border-left: 3px solid var(--color-base-300);
    padding-left: 0.8em;
    margin: 0.7em 0;
    opacity: 0.85;
  }
  ```
- [ ] Mirror the exact same `.card-markdown { … }` CSS block into `assets/css/storybook.css`.
- [ ] Run `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs`
  — expect pass.
- [ ] **Deliverable:** the drawer renders description/spec/plan as sanitized markdown; a collapsed
  Spec section appears between Description and Plan when the card has a `spec`. Run `mix precommit`
  — expect green.
- [ ] Commit: `git commit -am "feat(drawer): render description/spec/plan markdown + Spec section (RLY-3)"`

---

## Spec coverage map
- Data layer (`spec` field, migration, cast, moduledoc) → **Task 1**.
- API + CLI (`update_fields` allow-list, `card_json` shape, `bin/relay spec` + `print_card`) → **Task 1**.
- Pipeline / prompts (`relay_config.json` SPEC/PLAN/_comment) → **Task 1**.
- `Relay.Markdown` helper (MDEx sanitize, `Phoenix.HTML.safe`, dep promotion, boundary export) → **Task 2**.
- UI (description prose, collapsed Spec section, plan prose, theme-aware CSS) → **Task 3**.
- Testing (schema, API, markdown helper incl. XSS guard, LiveView drawer) → distributed across
  Tasks 1–3 alongside each deliverable.

## Out of scope (per spec)
- In-UI editing of `spec`; backfilling existing `description` into `spec`; syntax highlighting in
  code fences.
