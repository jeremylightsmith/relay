defmodule RelayWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: RelayWeb.Gettext

  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders the Human/AI owner pill — who holds the baton for a stage.

  Human maps to the primary (blue) theme token, AI to the secondary
  (violet) one, per the daisyUI theme in `assets/css/app.css`.

  ## Examples

      <.owner_pill owner={:human} />
      <.owner_pill owner={:ai} />
  """
  attr :owner, :atom, values: [:human, :ai], required: true
  attr :class, :any, default: nil

  def owner_pill(assigns) do
    ~H"""
    <span
      class={[
        "owner-pill badge badge-sm font-medium",
        if(@owner == :human, do: "badge-primary", else: "badge-secondary"),
        @class
      ]}
      data-owner={@owner}
    >
      {if @owner == :human, do: "Human", else: "AI"}
    </span>
    """
  end

  @doc """
  Renders a single kanban card: its title, optional #tag, and its
  board-scoped ref (e.g. RLY-3).

  Clicking the card emits a `"select_card"` event (with `phx-value-ref`)
  for the parent LiveView — `RelayWeb.BoardLive` answers with a patch to
  `?card=<ref>`, opening the card drawer.

  ## Examples

      <.board_card id="cards-1" ref="RLY-3" title="Ship MMF 03" tag="infra" />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"
  attr :title, :string, required: true
  attr :tag, :string, default: nil

  def board_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="board-card card cursor-pointer bg-base-100 shadow-sm transition-shadow hover:shadow-md"
      role="button"
      tabindex="0"
      phx-click="select_card"
      phx-value-ref={@ref}
    >
      <div class="card-body gap-2 p-3">
        <p class="card-title text-sm font-medium leading-snug">{@title}</p>
        <div class="flex items-center justify-between gap-2">
          <span :if={@tag} class="card-tag badge badge-ghost badge-sm">#{@tag}</span>
          <span class="card-ref ml-auto font-mono text-xs text-base-content/60">{@ref}</span>
        </div>
      </div>
    </article>
    """
  end

  @doc """
  Renders the card detail drawer (daisyUI `drawer drawer-end`): a scrim
  plus a right-side panel with the card's stage chip (stage name in the
  Human/AI owner color), its ref, an editable title, the plain-text
  description (whitespace-preserved view or a textarea editor), and a
  properties rail (stage, tags, dates).

  Render it only while a card is selected. The ✕ button and the scrim
  are `patch` links to `close_patch`, so closing is a URL change the
  parent LiveView handles in `handle_params/3`.

  Events emitted (handled by the parent LiveView): `"save_card_title"`
  (form params `card[title]`) on title submit, `"edit_description"` when
  the description view is clicked, `"cancel_description"` on Cancel, and
  `"save_card_description"` (form params `card[description]`) on save.

  ## Examples

      <.card_drawer
        id="card-drawer"
        ref="RLY-3"
        card={@selected_card}
        stage_name="Spec"
        stage_owner={:human}
        close_patch={~p"/board"}
        title_form={@title_form}
      />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"

  attr :card, :any,
    required: true,
    doc: "a card exposing title, description, tag, inserted_at, and updated_at"

  attr :stage_name, :string, required: true
  attr :stage_owner, :atom, values: [:human, :ai], required: true
  attr :close_patch, :string, required: true, doc: "the patch target that closes the drawer"
  attr :title_form, :any, required: true, doc: "a Phoenix.HTML.Form for card[title]"
  attr :editing_description, :boolean, default: false

  attr :description_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for card[description]; required when editing_description"

  def card_drawer(assigns) do
    ~H"""
    <div id={@id} class="drawer drawer-end">
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="drawer-toggle"
        checked
        tabindex="-1"
        aria-hidden="true"
      />
      <div class="drawer-side z-40">
        <.link id={"#{@id}-scrim"} patch={@close_patch} class="drawer-overlay">
          <span class="sr-only">Close</span>
        </.link>
        <aside class="flex min-h-full w-full max-w-md flex-col gap-6 bg-base-100 p-5 shadow-xl">
          <header class="space-y-3">
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "drawer-stage-chip badge badge-sm font-medium",
                  if(@stage_owner == :human, do: "badge-primary", else: "badge-secondary")
                ]}>
                  {@stage_name}
                </span>
                <span class="drawer-card-ref font-mono text-xs text-base-content/60">{@ref}</span>
              </div>
              <.link
                id={"#{@id}-close"}
                patch={@close_patch}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Close card drawer"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </.link>
            </div>
            <.form for={@title_form} id={"#{@id}-title-form"} phx-submit="save_card_title">
              <.input
                field={@title_form[:title]}
                type="text"
                id={"#{@id}-title-input"}
                class="input input-ghost w-full px-1 text-lg font-semibold"
                autocomplete="off"
              />
            </.form>
          </header>
          <section class="space-y-2">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Description
            </h4>
            <div
              :if={!@editing_description}
              id={"#{@id}-description-edit"}
              role="button"
              tabindex="0"
              phx-click="edit_description"
              class="min-h-16 cursor-text rounded-lg p-1 hover:bg-base-200"
            >
              <p
                :if={@card.description}
                id={"#{@id}-description-view"}
                class="whitespace-pre-wrap text-sm leading-relaxed"
                phx-no-format
              >{@card.description}</p>
              <p :if={!@card.description} class="text-sm italic text-base-content/50">
                Add a description…
              </p>
            </div>
            <.form
              :if={@editing_description}
              for={@description_form}
              id={"#{@id}-description-form"}
              phx-submit="save_card_description"
            >
              <.input
                field={@description_form[:description]}
                type="textarea"
                id={"#{@id}-description-input"}
                rows="6"
                autofocus
              />
              <div class="flex items-center gap-2">
                <.button variant="primary" class="btn btn-primary btn-sm">Save</.button>
                <button
                  type="button"
                  id={"#{@id}-description-cancel"}
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel_description"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </section>
          <dl
            id={"#{@id}-rail"}
            class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-3 border-t border-base-300 pt-4 text-sm"
          >
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Stage
            </dt>
            <dd class="rail-stage">{@stage_name}</dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Tags
            </dt>
            <dd class="rail-tags">
              <span :if={@card.tag} class="badge badge-ghost badge-sm">#{@card.tag}</span>
              <span :if={!@card.tag} class="text-base-content/50">None</span>
            </dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Dates
            </dt>
            <dd class="rail-dates space-y-0.5">
              <div>Created {Calendar.strftime(@card.inserted_at, "%b %d, %Y")}</div>
              <div>Updated {Calendar.strftime(@card.updated_at, "%b %d, %Y")}</div>
            </dd>
          </dl>
        </aside>
      </div>
    </div>
    """
  end

  @doc """
  Renders one stage column of the board: header (stage name + Human/AI
  owner pill), the stage's cards in the order given, and the "+ New card"
  compose control.

  `cards` accepts a LiveView stream (preferred) or a list of
  `{dom_id, card}` tuples; each card needs `title`, `tag`, and
  `ref_number` fields. The dashed empty-state placeholder lives inside
  the card container and is CSS-hidden (`only:block`) as soon as the
  stage has cards.

  The compose control emits events handled by the parent LiveView:
  `"compose"` (with `phx-value-stage-id`) to open the composer,
  `"create_card"` (form params `card[title]` plus hidden `stage_id`) on
  submit, and `"cancel_compose"` on Cancel, Escape, or click-away.

  ## Examples

      <.stage_column id="stage-col-1" name="Backlog" owner={:human} stage_id={1} />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :owner, :atom, values: [:human, :ai], required: true
  attr :stage_id, :any, default: nil, doc: "the stage's database id, echoed back in compose events"
  attr :board_key, :string, default: "RLY", doc: "the board's ref prefix, e.g. RLY in RLY-3"
  attr :cards, :any, default: [], doc: "a LiveView stream or a list of {dom_id, card} tuples"
  attr :composing, :boolean, default: false
  attr :compose_form, :any, default: nil, doc: "a Phoenix.HTML.Form for card[title]; required when composing"

  def stage_column(assigns) do
    ~H"""
    <section
      id={@id}
      class="stage-column flex w-60 shrink-0 flex-col gap-3 rounded-box bg-base-200 p-3"
    >
      <header class="flex items-center justify-between gap-2">
        <h3 class="text-sm font-semibold">{@name}</h3>
        <.owner_pill owner={@owner} />
      </header>
      <div
        id={"#{@id}-cards"}
        phx-update={is_struct(@cards, Phoenix.LiveView.LiveStream) && "stream"}
        class="flex flex-col gap-2"
      >
        <div
          id={"#{@id}-empty"}
          class="stage-empty hidden only:block rounded-lg border border-dashed border-base-content/20 px-3 py-6 text-center text-xs text-base-content/50"
        >
          No cards yet
        </div>
        <.board_card
          :for={{dom_id, card} <- @cards}
          id={dom_id}
          title={card.title}
          tag={card.tag}
          ref={"#{@board_key}-#{card.ref_number}"}
        />
      </div>
      <div :if={@composing} id={"#{@id}-composer"} phx-click-away="cancel_compose">
        <.form
          for={@compose_form}
          id={"#{@id}-compose-form"}
          phx-change="validate_card"
          phx-submit="create_card"
        >
          <input type="hidden" name="stage_id" value={@stage_id} />
          <.input
            field={@compose_form[:title]}
            type="text"
            placeholder="Card title"
            autofocus
            autocomplete="off"
            phx-keydown="cancel_compose"
            phx-key="escape"
          />
          <div class="flex items-center gap-2">
            <.button variant="primary" class="btn btn-primary btn-sm">Add card</.button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_compose">
              Cancel
            </button>
          </div>
        </.form>
      </div>
      <button
        :if={!@composing}
        type="button"
        id={"#{@id}-new-card"}
        class="stage-compose btn btn-ghost btn-sm justify-start text-base-content/60"
        phx-click="compose"
        phx-value-stage-id={@stage_id}
      >
        <.icon name="hero-plus" class="size-4" /> New card
      </button>
    </section>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(RelayWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RelayWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
