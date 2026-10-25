defmodule RelayWeb.TemplatePickerComponents do
  @moduledoc """
  The **New board** template picker (RE442, card mockup "Picker — New board opens three
  template cards"): a modal of radio cards, one per `Relay.Boards.templates/0` entry, each
  showing the template's main-stage strip (type glyph + name, a ring on stages with a Review
  sub-lane, never a WIP limit), blurb, facts row and optional warning, over a footer whose
  primary button reads "Create <board name>" ("Create board" while the name is blank).

  **Identity row** (RE455, card mockup "A — name + card key, required, at the top of the New
  board picker"): above a "Start from" label and the cards, a **Board name** input (`name`,
  `maxlength` from `Schemas.Board.name_max_length/0`) and a 2-letter **Card key** input (`key`,
  the `CardKeyInput` hook upper-cases and filters it while typing) with its hint and, once the
  key is complete, a "Cards will be XX1, XX2, XX3…" preview. Both are required for every option:
  the primary button stays disabled until the name is non-blank and the key matches
  `Schemas.Board.key_format/0` (and, on the copy option, a source exists). An incomplete key —
  or a blank one once `show_required` is set — reads "Needs 2 letters"; a blank name with
  `show_required` reads "Required"; a server changeset message in `errors` replaces either hint.

  Selection is the caller's assign (`selected`): the radios' `checked` and the selected card's
  border both come from it, so what's shown and what's submitted can't disagree. Events, all
  handled by `RelayWeb.BoardsLive`:

    * `"select_template"` — the form's `phx-change`, `%{"template" => slug_or_copy, "name" =>
      name, "key" => key}` plus, while the copy card is selected, `"copy_query"` and `"copy_from"`
    * `"create_from_template"` — the form's `phx-submit`, the same fields
    * `"close_template_picker"` — Cancel, ✕, a scrim click or Escape; never emitted in first-run

  Under each card's `flex-1` spacer, a template with a seeded example board (`examples`, from
  `Relay.Boards.example_boards/0`) links to it at `/examples/<slug>` in a new window (RE444).
  The link sits inside the card's `<label>`, so clicking it follows the link without selecting
  the card.

  **The 4th option** (RE447, card mockup "Picker — 4th option: copy from a board I have access
  to"): a full-width card beneath the three, its `template` radio valued `copy_option/0`. While
  it is selected it reveals a search box (`copy_query`, filtering `copy_sources` by name or key,
  case-insensitively), one `copy_from` radio row per `Relay.Boards.copy_sources/1` board
  (`N stages · M flows`), an amber warning naming the first five `.claude/` files the chosen
  board's flows reference (`+N more` past that), and a button reading "Copy <board>" ("Copy a
  board" — and disabled — when there is no board to copy). Its outer element is a `<div>`, not a
  `<label>`, because each source row is a label; the left column is a
  `<label for="template-radio-copy">`, so clicks in the search box or on a row never touch the
  `template` radio.

  **First-run (RE470)** (card mockup "A — first-run picker over an empty Your boards, no way out
  but Create or Sign out"): with `first_run` set the picker titles itself "Make your first
  board", drops the copy card and the "or copy a board" wording, and has no way out but Create or
  Sign out — no ✕, no Cancel, no scrim click, no Escape. Its footer reads "Signed in as
  <`signed_in_as`> · Sign out" (a `DELETE /logout` link) left of Create.

  Story: `storybook/template_picker_components/template_picker.story.exs` — one variation per
  template selection, `:with_examples`, the copy variations `:copy_selected` and
  `:copy_no_boards`, the identity variations `:identity_empty`, `:identity_filled`,
  `:identity_incomplete` and `:copy_identity_required`, and `:first_run`.
  """

  use RelayWeb, :html

  alias Schemas.Board

  @copy_option "copy"

  @doc """
  The one `template` radio value that means "copy a board" (RE447) rather than a template slug.
  `RelayWeb.BoardsLive` compares the submitted value against it.
  """
  @spec copy_option() :: String.t()
  def copy_option, do: @copy_option

  # How many file names the copy warning lists before it says "+N more".
  @warning_file_names 5

  attr :templates, :list, required: true, doc: "`Relay.Boards.templates/0`, in picker order"
  attr :selected, :string, required: true, doc: "the selected template's slug, or `copy_option/0`"
  attr :id, :string, default: "template-picker"

  attr :copy_sources, :list,
    default: [],
    doc: "`Relay.Boards.copy_sources/1` rows — the boards the 4th option can copy"

  attr :copy_from, :string, default: nil, doc: "the selected copy source's slug"
  attr :copy_query, :string, default: "", doc: "the copy card's search text"

  attr :examples, :map,
    default: %{},
    doc: "`Relay.Boards.example_boards/0` — template slug => example board name; only these cards link to one"

  attr :name, :string, default: "", doc: "the Board name field's value"
  attr :key, :string, default: "", doc: "the Card key field's value"

  attr :show_required, :boolean,
    default: false,
    doc: "the user has interacted, so a blank name / incomplete key reads as an error"

  attr :errors, :map,
    default: %{},
    doc: "server changeset messages, `%{name: [String.t()], key: [String.t()]}`"

  attr :first_run, :boolean,
    default: false,
    doc: "first-run mode (RE470): no copy card and no way out but Create or Sign out"

  attr :signed_in_as, :string, default: nil, doc: "the signed-in user's email, for the first-run footer"

  def template_picker(assigns) do
    copy? = assigns.selected == @copy_option
    source = Enum.find(assigns.copy_sources, &(&1.slug == assigns.copy_from))
    name = assigns.name |> to_string() |> String.trim()
    key_complete? = Regex.match?(Board.key_format(), to_string(assigns.key))

    assigns =
      assign(assigns,
        form: to_form(%{"template" => assigns.selected}),
        copy?: copy?,
        source: source,
        key_complete?: key_complete?,
        name_hint: name_hint(name, assigns.show_required, assigns.errors),
        key_hint: key_hint(to_string(assigns.key), key_complete?, assigns.show_required, assigns.errors),
        create_label: create_label(copy?, source, name),
        create_disabled?: name == "" or not key_complete? or (copy? and is_nil(source)),
        # nil drops the attribute, so first-run renders no way to close the picker.
        close_event: if(!assigns.first_run, do: "close_template_picker"),
        close_key: if(!assigns.first_run, do: "escape")
      )

    ~H"""
    <div id={@id} phx-window-keydown={@close_event} phx-key={@close_key}>
      <.modal_scrim phx-click={@close_event} />
      <div class="fixed inset-x-0 top-0 z-[51] flex max-h-screen justify-center overflow-y-auto p-0 sm:p-6">
        <div
          id={"#{@id}-panel"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-title"}
          class="bg-base-200 w-full sm:max-w-[1080px] sm:rounded-[18px] shadow-xl flex flex-col border border-base-300 self-start shrink-0"
        >
          <div class="flex items-start gap-3 px-5 pt-5 pb-3">
            <div class="flex flex-col gap-1">
              <h2 id={"#{@id}-title"} class="font-semibold tracking-tight text-[20px]">
                {if @first_run, do: "Make your first board", else: "New board"}
              </h2>
              <p class="text-[13.5px] text-base-content/55 max-w-[640px]">
                Name it, pick its card key, then start from a template{if !@first_run,
                  do: " or copy a board"}. You get its stages and flows. Every prompt lives inside its flow, so it works in any repo with no
                <span class="font-mono">.claude/</span>
                setup.
              </p>
            </div>
            <span class="flex-1"></span>
            <button
              :if={!@first_run}
              type="button"
              id={"#{@id}-close"}
              phx-click="close_template_picker"
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close"
            >
              ✕
            </button>
          </div>

          <.form
            for={@form}
            id={"#{@id}-form"}
            phx-change="select_template"
            phx-submit="create_from_template"
          >
            <.identity_row
              id={@id}
              name={@name}
              key={@key}
              key_complete?={@key_complete?}
              name_hint={@name_hint}
              key_hint={@key_hint}
            />

            <div
              id={"#{@id}-start-from"}
              class="px-5 pb-2 text-[12px] font-semibold text-base-content/80"
            >
              Start from
            </div>

            <div
              id={"#{@id}-grid"}
              class={["grid gap-4 px-5 pb-4 grid-cols-1", md_columns(length(@templates)).grid]}
            >
              <.template_card
                :for={t <- @templates}
                template={t}
                selected?={t.slug == @selected}
                example={Map.get(@examples, t.slug)}
              />
              <.copy_card
                :if={!@first_run}
                span={md_columns(length(@templates)).span}
                selected?={@copy?}
                sources={@copy_sources}
                source={@source}
                query={@copy_query}
              />
            </div>

            <div class="flex flex-wrap items-center gap-3 px-5 py-4 border-t border-base-300 bg-base-100 sm:rounded-b-[18px]">
              <span :if={@first_run} class="text-[12px] text-base-content/55">
                Signed in as {@signed_in_as} ·
                <.link
                  href={~p"/logout"}
                  method="delete"
                  id={"#{@id}-sign-out"}
                  class="link link-hover"
                >
                  Sign out
                </.link>
              </span>
              <span class="flex-1"></span>
              <button
                :if={!@first_run}
                type="button"
                id={"#{@id}-cancel"}
                phx-click="close_template_picker"
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
              <.button
                type="submit"
                id={"#{@id}-create"}
                class="btn btn-primary btn-sm w-full sm:w-auto"
                pending="Creating…"
                disabled={@create_disabled?}
              >
                {@create_label}
              </.button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :key, :string, required: true
  attr :key_complete?, :boolean, required: true
  attr :name_hint, :any, required: true, doc: "nil, or `{:error, message}`"
  attr :key_hint, :any, required: true, doc: "`{:ok, message}` or `{:error, message}`"

  # Raw inputs (like the copy search box) so the mockup's label / hint markup is exact.
  defp identity_row(assigns) do
    ~H"""
    <div id={"#{@id}-identity"} class="flex flex-col sm:flex-row gap-4 px-5 pb-4">
      <label class="flex flex-col gap-1.5 flex-1 sm:max-w-[420px]">
        <span class="text-[12px] font-semibold text-base-content/80">Board name</span>
        <input
          type="text"
          id={"#{@id}-name"}
          name="name"
          value={@name}
          maxlength={Board.name_max_length()}
          placeholder="e.g. Acme Checkout"
          autocomplete="off"
          autofocus
          class={["input input-sm w-full bg-base-100", @name_hint && "input-error"]}
        />
        <span :if={@name_hint} id={"#{@id}-name-hint"} class="text-[11.5px] text-error">
          {elem(@name_hint, 1)}
        </span>
      </label>
      <label class="flex flex-col gap-1.5 w-full sm:w-[150px]">
        <span class="text-[12px] font-semibold text-base-content/80">Card key</span>
        <input
          type="text"
          id={"#{@id}-key"}
          name="key"
          value={@key}
          maxlength="2"
          placeholder="AC"
          autocomplete="off"
          autocapitalize="characters"
          phx-hook="CardKeyInput"
          class={[
            "input input-sm w-full bg-base-100 font-mono uppercase tracking-[0.15em]",
            match?({:error, _}, @key_hint) && "input-error"
          ]}
        />
        <span
          id={"#{@id}-key-hint"}
          class={[
            "text-[11.5px]",
            if(match?({:error, _}, @key_hint), do: "text-error", else: "text-base-content/50")
          ]}
        >
          {elem(@key_hint, 1)}
        </span>
      </label>
      <div
        :if={@key_complete?}
        id={"#{@id}-key-preview"}
        class="flex flex-col justify-end pb-1.5 text-[12px] text-base-content/55"
      >
        <span>
          Cards will be <span class="font-mono text-base-content/80">{@key}1, {@key}2, {@key}3…</span>
        </span>
      </div>
    </div>
    """
  end

  # A server message wins; otherwise a blank name only reads "Required" once the user has
  # interacted.
  defp name_hint(name, show_required?, errors) do
    case Map.get(errors, :name, []) do
      [message | _] -> {:error, message}
      [] -> if show_required? and name == "", do: {:error, "Required"}
    end
  end

  # A key is only ever incomplete (the hook and `Board.key_from_name/1` keep it to letters):
  # non-empty-but-short is an error at once, empty only once the user has interacted.
  defp key_hint(key, key_complete?, show_required?, errors) do
    case Map.get(errors, :key, []) do
      [message | _] -> {:error, message}
      [] when key_complete? -> {:ok, "2 letters · A–Z"}
      [] when key != "" or show_required? -> {:error, "Needs 2 letters"}
      [] -> {:ok, "2 letters · A–Z"}
    end
  end

  attr :template, :map, required: true
  attr :selected?, :boolean, required: true
  attr :example, :string, default: nil, doc: "the template's example board name, or nil when none is seeded"

  defp template_card(assigns) do
    ~H"""
    <label
      id={"template-card-#{@template.slug}"}
      class={[
        "flex flex-col gap-3 rounded-[14px] bg-base-100 p-4 cursor-pointer",
        if(@selected?, do: "border-2 border-primary", else: "border border-base-300 m-px")
      ]}
      style={
        @selected? &&
          "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));"
      }
    >
      <div class="flex items-start gap-3">
        <input
          type="radio"
          id={"template-radio-#{@template.slug}"}
          name="template"
          value={@template.slug}
          checked={@selected?}
          class="radio radio-primary radio-sm mt-0.5"
        />
        <div class="flex flex-col gap-0.5 min-w-0">
          <span class="font-semibold text-[15px]">{@template.name}</span>
          <span class="text-[13px] text-base-content/55">{@template.tagline}</span>
        </div>
      </div>

      <div
        id={"template-stages-#{@template.slug}"}
        class="flex flex-wrap items-center gap-x-1.5 gap-y-1.5 rounded-lg bg-base-200 px-2.5 py-2"
      >
        <%= for {stage, i} <- Enum.with_index(@template.stages) do %>
          <span :if={i > 0} class="template-arrow text-[10px] text-base-content/40" aria-hidden="true">
            →
          </span>
          <span class="flex items-center gap-1 font-mono text-[10.5px] whitespace-nowrap">
            <.stage_type_icon type={stage.type} size={8} />
            <span>{stage.name}</span>
            <span
              :if={:review in stage.sublanes}
              class="template-review-marker"
              title="has a Review sub-lane"
              style="width:6px;height:6px;border-radius:50%;border:1.5px solid var(--color-warning);display:inline-block;"
            >
            </span>
          </span>
        <% end %>
      </div>

      <p class="text-[12.5px] leading-[1.5] text-base-content/75">{@template.blurb}</p>

      <div id={"template-facts-#{@template.slug}"} class="flex flex-wrap gap-x-3 gap-y-1">
        <span class="font-mono text-[10.5px] text-base-content/55">
          {count_label(length(@template.stages), "stage")}
        </span>
        <span class="font-mono text-[10.5px] text-base-content/55">
          {count_label(length(@template.flows), "flow")}
        </span>
        <span
          class="font-mono text-[10.5px]"
          style="color:color-mix(in oklab, var(--color-success) 65%, var(--color-base-content));"
        >
          {count_label(skill_count(@template), "skill")}
        </span>
      </div>

      <div
        :if={@template.warning}
        id={"template-warning-#{@template.slug}"}
        class="flex items-start gap-2 rounded-lg px-2.5 py-2 text-[11.5px]"
        style="background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));"
      >
        <span aria-hidden="true">⚠</span>
        <span>{@template.warning}</span>
      </div>

      <span class="flex-1"></span>

      <a
        :if={@example}
        id={"template-example-#{@template.slug}"}
        href={~p"/examples/#{@template.slug}"}
        target="_blank"
        rel="noopener"
        title="Opens in a new window"
        class="link link-primary no-underline hover:underline text-[12.5px]"
      >
        See the public example: {@example}&nbsp;<.icon
          name="hero-arrow-top-right-on-square"
          class="size-3.5"
        /><span class="sr-only">(opens in a new window)</span>
      </a>
    </label>
    """
  end

  # Tailwind only ships classes it sees spelled out, so each column count is written in full.
  defp md_columns(2), do: %{grid: "md:grid-cols-2", span: "md:col-span-2"}
  defp md_columns(_count), do: %{grid: "md:grid-cols-3", span: "md:col-span-3"}

  attr :span, :string, required: true, doc: "the `md:col-span-*` class spanning the template row"
  attr :selected?, :boolean, required: true
  attr :sources, :list, required: true
  attr :source, :map, default: nil, doc: "the selected source row, or nil"
  attr :query, :string, required: true

  defp copy_card(assigns) do
    assigns = assign(assigns, :visible, filter_sources(assigns.sources, assigns.query))

    ~H"""
    <div
      id="template-card-copy"
      class={[
        @span,
        "flex flex-col md:flex-row gap-4 rounded-[14px] bg-base-100 p-4 cursor-pointer",
        if(@selected?, do: "border-2 border-primary", else: "border border-base-300 m-px")
      ]}
      style={
        @selected? &&
          "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100));"
      }
    >
      <label
        for="template-radio-copy"
        class="flex flex-col gap-2 md:w-[340px] flex-none cursor-pointer"
      >
        <div class="flex items-start gap-3">
          <input
            type="radio"
            id="template-radio-copy"
            name="template"
            value={copy_option()}
            checked={@selected?}
            class="radio radio-primary radio-sm mt-0.5"
          />
          <div class="flex flex-col gap-0.5 min-w-0">
            <span class="font-semibold text-[15px]">Copy from a board I have access to</span>
            <span class="text-[13px] text-base-content/55">
              Same stages and flows as one of your boards.
            </span>
          </div>
        </div>
        <p class="text-[12.5px] leading-[1.5] text-base-content/75">
          A plain copy: stages, flows and WIP limits, no cards. It doesn't remember where it came from and never picks up later changes.
        </p>
      </label>

      <%!-- Unselected, the rest of the card still selects it. --%>
      <label
        :if={!@selected?}
        for="template-radio-copy"
        class="hidden md:block flex-1 cursor-pointer"
        aria-hidden="true"
      >
      </label>

      <div :if={@selected?} class="flex-1 min-w-0 flex flex-col gap-1.5">
        <input
          type="text"
          id="template-copy-search"
          name="copy_query"
          value={@query}
          class="input input-sm w-full"
          placeholder="Search your boards…"
          autocomplete="off"
          phx-debounce="150"
        />
        <div id="template-copy-list" class="flex flex-col gap-1 max-h-[240px] overflow-y-auto">
          <.copy_source_row
            :for={s <- @visible}
            source={s}
            selected?={@source != nil and s.slug == @source.slug}
          />
          <p
            :if={@visible == []}
            id="template-copy-empty"
            class="px-2.5 py-2 text-[12.5px] text-base-content/55"
          >
            No boards match.
          </p>
        </div>

        <div
          :if={@source && @source.files != []}
          id="template-copy-warning"
          class="flex items-start gap-2 rounded-lg px-2.5 py-2 mt-1"
          style="background:color-mix(in oklab, var(--color-warning) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-warning) 40%, var(--color-base-100));font-size:12px"
        >
          <span
            aria-hidden="true"
            style="color:color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))"
          >
            ⚠
          </span>
          <span class="flex flex-col gap-1">
            <span>
              <b>{warning_headline(@source)}</b>
              They aren't copied. When you onboard, the LLM asks about each one: stub it, inline it into the flow, or drop the node.
            </span>
            <span
              id="template-copy-warning-files"
              class="font-mono text-[10.5px] text-base-content/55"
            >
              {warning_files(@source.files)}
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :selected?, :boolean, required: true

  defp copy_source_row(assigns) do
    ~H"""
    <label
      id={"copy-source-#{@source.slug}"}
      class={[
        "flex items-center gap-2.5 rounded-lg px-2.5 py-2 cursor-pointer",
        @selected? && "bg-base-200"
      ]}
      style={
        if @selected?,
          do: "border:1px solid color-mix(in oklab, var(--color-primary) 50%, var(--color-base-100))",
          else: "border:1px solid transparent"
      }
    >
      <input
        type="radio"
        id={"copy-source-radio-#{@source.slug}"}
        name="copy_from"
        value={@source.slug}
        checked={@selected?}
        class="radio radio-primary radio-xs"
      />
      <span class="flex flex-col min-w-0">
        <span class="text-[13px] font-semibold">
          {@source.name}
          <span class="font-mono text-[10.5px] text-base-content/55 font-normal">{@source.key}</span>
        </span>
        <span class="font-mono text-[10.5px] text-base-content/55">{source_facts(@source)}</span>
      </span>
    </label>
    """
  end

  defp create_label(true = _copy?, nil = _source, _name), do: "Copy a board"
  defp create_label(true, source, _name), do: "Copy #{source.name}"
  defp create_label(false, _source, "" = _name), do: "Create board"
  defp create_label(false, _source, name), do: "Create #{name}"

  defp filter_sources(sources, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        sources

      q ->
        Enum.filter(
          sources,
          &(String.contains?(String.downcase(&1.name), q) or String.contains?(String.downcase(&1.key), q))
        )
    end
  end

  defp source_facts(source), do: "#{count_label(source.stages, "stage")} · #{count_label(source.flows, "flow")}"

  defp warning_headline(%{name: name, files: [_]}),
    do: "#{name}'s flows name 1 file that lives in its repo, not on the board."

  defp warning_headline(%{name: name, files: files}),
    do: "#{name}'s flows name #{length(files)} files that live in its repo, not on the board."

  defp warning_files(files) do
    {shown, rest} = Enum.split(files, @warning_file_names)
    names = Enum.map(shown, & &1.name)
    names = if rest == [], do: names, else: names ++ ["+#{length(rest)} more"]
    Enum.join(names, " · ")
  end

  # A "skill" is a flow node bound to a `.claude/` agent; every template's prompts are inline,
  # so this derives to 0 — but it is derived, so a template that does bind one says so.
  defp skill_count(template) do
    template.flows
    |> Enum.flat_map(& &1.nodes)
    |> Enum.count(&(Map.get(&1, :agent) not in [nil, ""]))
  end

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(n, noun), do: "#{n} #{noun}s"
end
