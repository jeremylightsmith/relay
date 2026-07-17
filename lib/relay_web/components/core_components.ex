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
  alias Relay.Cards
  alias Schemas.Activity

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
  The stage-type glyph that replaces the owner dot: a 9px mark whose shape+color encodes the
  five stage types (queue/work/planning/review/done). See ADR 0003 / the Stage & Card Model
  mockup §02.
  """
  attr :type, :atom, values: [:queue, :work, :planning, :review, :done], required: true
  attr :size, :integer, default: 9

  def stage_type_icon(assigns) do
    ~H"""
    <span
      class="stage-type-icon"
      data-type={@type}
      aria-label={"#{@type} stage"}
      style={stage_type_icon_style(@type, @size)}
    >
    </span>
    """
  end

  defp stage_type_icon_style(:queue, s),
    do:
      "width:#{s}px;height:#{s}px;border-radius:3px;border:1.5px solid oklch(0.68 0.02 255);box-sizing:border-box;flex:0 0 auto;display:block;background:transparent;"

  defp stage_type_icon_style(:work, s),
    do: "width:#{s}px;height:#{s}px;border-radius:2px;background:var(--color-primary);flex:0 0 auto;display:block;"

  defp stage_type_icon_style(:planning, s),
    do:
      "width:#{s}px;height:#{s}px;background:var(--color-secondary);transform:rotate(45deg);flex:0 0 auto;display:block;"

  defp stage_type_icon_style(:review, s),
    do:
      "width:#{s}px;height:#{s}px;border-radius:50%;border:1.5px solid var(--color-warning);box-sizing:border-box;flex:0 0 auto;display:block;background:transparent;"

  defp stage_type_icon_style(:done, s),
    do: "width:#{s}px;height:#{s}px;border-radius:50%;background:var(--color-success);flex:0 0 auto;display:block;"

  @doc """
  Renders a card's status badge — the baton state at a glance.

  `working` appends the stored progress percentage when present
  (`working·61%`); `needs_input` renders the amber NEEDS INPUT treatment;
  `in_review` blue; `ready` neutral (Done is a derivation, not a status —
  see `Relay.Cards.done?/2` — and is rendered by callers, not this badge).

  ## Examples

      <.status_badge status={:working} progress={61} />
      <.status_badge status={:needs_input} />
  """
  attr :status, :atom,
    values: [:ready, :working, :needs_input, :in_review],
    required: true

  attr :progress, :integer, default: nil
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      class={["status-badge badge badge-sm font-medium", status_badge_class(@status), @class]}
      data-status={@status}
    >
      {status_badge_label(@status, @progress)}
    </span>
    """
  end

  defp status_badge_class(:ready), do: "badge-ghost"
  defp status_badge_class(:working), do: "badge-secondary"
  defp status_badge_class(:needs_input), do: "badge-warning"
  defp status_badge_class(:in_review), do: "badge-primary"

  defp status_badge_label(:working, progress) when is_integer(progress), do: "working·#{progress}%"
  defp status_badge_label(:ready, _progress), do: "ready"
  defp status_badge_label(:working, _progress), do: "working"
  defp status_badge_label(:needs_input, _progress), do: "NEEDS INPUT"
  defp status_badge_label(:in_review, _progress), do: "in review"

  @doc """
  The one avatar (RLY-90). A person renders their photo when we have one
  (`src`), white initials on a colored circle otherwise; the AI renders the
  violet dot mark and never a photo. Every people surface (top bar, card
  owner cluster, member stack, comment timeline, reassign picker, board
  settings) draws through this, so the same person looks the same everywhere.

  Takes primitives, not structs — storybook stories pass plain values, and
  invited members have no user row at all.

  `tint={:role}` fills with `--color-primary` (human=blue is load-bearing);
  `tint={:identity}` seeds a stable hue from the email, so one person keeps
  one color across surfaces.
  """
  attr :src, :string, default: nil, doc: "the avatar_url; ignored when actor={:ai}"
  attr :name, :string, default: nil, doc: "display name — title text + initials"
  attr :email, :string, default: nil, doc: "initials fallback + identity hue seed"
  attr :actor, :atom, values: [:human, :ai], default: :human
  attr :size, :integer, default: 24, doc: "circle diameter in px"
  attr :tint, :atom, values: [:role, :identity], default: :identity
  attr :ring, :string, default: nil, doc: "CSS ring color, or nil — the active-owner double shadow"
  attr :grayed, :boolean, default: false
  attr :class, :string, default: nil

  def avatar(%{actor: :ai} = assigns) do
    assigns = assign(assigns, :mark_size, round(assigns.size * 0.36))

    ~H"""
    <span
      class={@class}
      style={avatar_circle_style(@size, "var(--color-secondary)", @ring, @grayed)}
      title="Relay AI"
      data-avatar="ai"
    >
      <span style={"width:#{@mark_size}px;height:#{@mark_size}px;border-radius:50%;border:1.5px solid oklch(1 0 0);display:block"}>
      </span>
    </span>
    """
  end

  def avatar(%{src: src} = assigns) when is_binary(src) and src != "" do
    ~H"""
    <span
      class={@class}
      style={avatar_circle_style(@size, nil, @ring, @grayed) <> ";overflow:hidden"}
      title={@name || @email}
      data-avatar="photo"
    >
      <img
        src={@src}
        alt={@name || @email}
        referrerpolicy="no-referrer"
        style="width:100%;height:100%;object-fit:cover"
      />
    </span>
    """
  end

  def avatar(assigns) do
    fill = if assigns.tint == :role, do: "var(--color-primary)", else: avatar_fill(assigns.email)

    # Spread as dynamic attrs, and keep the child on the tag's own line: with
    # a bare-text child, mix format's HEEx formatter (unlike for element
    # children) hoists surrounding whitespace into literal text nodes the
    # moment the opening tag wraps onto multiple lines — which the `>DK<`
    # style tests below would otherwise fail on.
    assigns =
      assign(assigns,
        attrs: %{
          class: assigns.class,
          style: avatar_circle_style(assigns.size, fill, assigns.ring, assigns.grayed),
          title: assigns.name || assigns.email,
          "data-avatar": "initials"
        },
        initials: avatar_initials(assigns.name, assigns.email)
      )

    ~H"""
    <span {@attrs}>{@initials}</span>
    """
  end

  defp avatar_circle_style(size, fill, ring, grayed) do
    [
      "width:#{size}px",
      "height:#{size}px",
      "border-radius:50%",
      fill && "background:#{fill}",
      "color:oklch(1 0 0)",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "font-size:#{round(size * 0.42)}px",
      "font-weight:600",
      "flex:0 0 auto",
      "box-sizing:border-box",
      ring && "box-shadow:0 0 0 3.5px #{ring}, 0 0 0 2px var(--color-base-100)",
      grayed && "filter:grayscale(1)",
      grayed && "opacity:0.5"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(";")
  end

  # The one initials rule (RLY-90 [E4]), mirrored by the mobile app's
  # initialsFor/2: a name yields the first letters of its first two words;
  # with no name, the email's LOCAL PART split on [._\s-] (dana@acme.co → D,
  # dana.kim@acme.co → DK); both blank yields "?". Never crashes on nil.
  defp avatar_initials(name, email) do
    cond do
      filled?(name) -> take_initials(String.split(name, ~r/\s+/, trim: true))
      filled?(email) -> email |> String.split("@") |> List.first("") |> local_part_initials()
      true -> "?"
    end
  end

  defp filled?(value), do: is_binary(value) and String.trim(value) != ""

  defp local_part_initials(local), do: take_initials(String.split(local, ~r/[._\s-]+/, trim: true))

  defp take_initials(words) do
    case words |> Enum.take(2) |> Enum.map_join("", &String.first/1) |> String.upcase() do
      "" -> "?"
      initials -> initials
    end
  end

  # The identity fill (RLY-90 [E2]): one hue per email, everywhere — the same
  # oklch(0.62 0.13 h) formula the member stack and board settings already used.
  defp avatar_fill(email) do
    hue = rem(:erlang.phash2(email || ""), 360)
    "oklch(0.62 0.13 #{hue})"
  end

  @doc """
  Renders the owner avatar cluster for a card — the mockup's "who holds the
  baton" glance (`docs/designs/Relay Board.dc.html`, `buildCluster`). Human
  owners are ~22px initialed circles (blue); the AI owner is a violet circle
  with a small mark. The active owner is ringed; when the AI is active the
  human owners render smaller/grayed and overlap behind it. Nothing renders
  for an unowned card.
  """
  attr :owners, :list, default: [], doc: "the card's loaded owner rows (actor_type + optional :user)"

  attr :active_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "who holds the baton, derived by Relay.Cards.active_owner_type/1"

  attr :size, :integer, default: 22

  def owner_avatars(assigns) do
    assigns = assign(assigns, :avatars, build_cluster(assigns.owners, assigns.active_owner))

    ~H"""
    <div :if={@avatars != []} class="card-owners flex items-center" style="padding-left:2px;">
      <div :for={av <- @avatars} style={av.wrap} title={av.title} data-actor-type={av.actor_type}>
        <.avatar
          actor={av.actor}
          src={av.src}
          name={av.name}
          email={av.email}
          size={@size}
          tint={:role}
          ring={av.ring}
          grayed={av.grayed}
        />
      </div>
    </div>
    """
  end

  defp build_cluster(_owners, nil), do: []

  defp build_cluster(owners, active_owner) do
    ai_active = active_owner == :ai
    humans = Enum.filter(owners, &(&1.actor_type == :user))

    human_avatars =
      humans
      |> Enum.with_index()
      |> Enum.map(fn {owner, i} ->
        user = Map.get(owner, :user)

        %{
          actor: :human,
          src: user && Map.get(user, :avatar_url),
          name: user && Map.get(user, :name),
          email: user && Map.get(user, :email),
          title: user_name(user) || "Someone",
          actor_type: :user,
          ring: if(not ai_active and i == 0, do: "var(--color-primary)"),
          grayed: ai_active,
          wrap: cluster_wrap(i > 0)
        }
      end)

    ai_avatars =
      if ai_active do
        [
          %{
            actor: :ai,
            src: nil,
            name: nil,
            email: nil,
            title: "Relay AI",
            actor_type: :agent,
            ring: "var(--color-secondary)",
            grayed: false,
            wrap: cluster_wrap(humans != [])
          }
        ]
      else
        []
      end

    human_avatars ++ ai_avatars
  end

  # Overlap is the cluster's concern, not the avatar's: later circles tuck
  # -6px behind the previous one with a 2px base-100 separation ring.
  defp cluster_wrap(false), do: "display:flex;border-radius:50%;position:relative"

  defp cluster_wrap(true) do
    "display:flex;border-radius:50%;position:relative;margin-left:-6px;" <>
      "box-shadow:0 0 0 2px var(--color-base-100)"
  end

  defp user_name(nil), do: nil
  defp user_name(user), do: Map.get(user, :name) || Map.get(user, :email)

  @doc """
  The boards-home overlapping member avatar stack (RLY-32) — mockup
  "Relay Board.dc.html" lines ~114-124. Up to `limit` 24×24 colored-initials
  circles (2px white ring, -7px overlap), then a neutral +N overflow chip.
  Invited (user-less) members show email-derived initials. Renders nothing for
  an empty list.

  `members` items expose `:email` and an optional preloaded `:user`.
  """
  attr :members, :list, default: []
  attr :limit, :integer, default: 4
  attr :id, :string, default: nil

  def member_stack(assigns) do
    shown =
      assigns.members
      |> Enum.take(assigns.limit)
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> member_avatar_data(m, i) end)

    ov = length(assigns.members) - length(shown)
    assigns = assign(assigns, avatars: shown, ov: ov, ov_style: member_overflow_style())

    ~H"""
    <div :if={@members != []} id={@id} data-role="member-stack" class="flex items-center">
      <span :for={av <- @avatars} style={av.wrap} title={av.title}>
        <.avatar src={av.src} name={av.name} email={av.email} size={24} tint={:identity} />
      </span>
      <span :if={@ov > 0} data-role="member-overflow" style={@ov_style}>+{@ov}</span>
    </div>
    """
  end

  defp member_avatar_data(m, index) do
    user = Map.get(m, :user)

    %{
      src: user && Map.get(user, :avatar_url),
      name: user && Map.get(user, :name),
      email: member_email(m),
      title: user_name(user) || member_email(m),
      wrap: member_wrap(index)
    }
  end

  defp member_email(m), do: Map.get(m, :email) || ""

  # The stack's white separation ring + -7px tuck (mockup lines ~114-124).
  defp member_wrap(0), do: "display:flex;border-radius:50%;box-shadow:0 0 0 2px oklch(1 0 0)"
  defp member_wrap(_index), do: member_wrap(0) <> ";margin-left:-7px"

  defp member_overflow_style do
    "width:24px;height:24px;border-radius:50%;background:oklch(0.94 0.006 255);" <>
      "color:oklch(0.50 0.02 255);display:flex;align-items:center;justify-content:center;" <>
      "font-size:10px;font-weight:600;flex:0 0 auto;box-sizing:border-box;" <>
      "box-shadow:0 0 0 2px oklch(1 0 0);margin-left:-7px;"
  end

  @doc """
  Renders a single kanban card matching the hi-fi mockup
  (`docs/designs/Relay Board.dc.html`): title, an accent left border keyed to
  status (amber needs-you / violet working / quiet otherwise), an optional
  violet progress bar while working, the amber needs-you box, a mono status
  line + `#tag`, and the owner avatar cluster.

  Done is a pure derivation (RLY-48, `Relay.Cards.done?/2`), not a stored
  status: a `:ready` card at the board's terminal stage grays its title via
  `done`; a `:ready` card in a mid-board Done sub-lane shows the green
  `card-ready-chip` instead (via `stage_type`); a plain parked `:ready` card
  elsewhere renders quiet, with no chip.

  Ownership is provenance, not a stage "mismatch" (ADR 0004) — an owner may
  legitimately sit in any stage, so this component never flags one.

  Clicking the card emits a `"select_card"` event (with `phx-value-ref`)
  for the parent LiveView — `RelayWeb.BoardLive` answers with a patch to
  `?card=<ref>`, opening the card drawer.

  The card is natively draggable (draggable="true" + data-ref) — the
  board-level BoardDnD hook turns drops into "move_card" events.

  ## Examples

      <.board_card id="cards-1" ref="RLY-3" title="Ship MMF 03" tag="infra" />
      <.board_card
        id="cards-2"
        ref="RLY-4"
        title="Migrate the posts"
        active_owner={:ai}
        status={:working}
        progress={61}
      />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"
  attr :title, :string, required: true
  attr :tag, :string, default: nil

  attr :active_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "who holds the baton, derived from the owner list; nil when unowned"

  attr :status, :atom,
    values: [:ready, :working, :needs_input, :in_review, nil],
    default: nil

  attr :stage_type, :atom,
    values: [:queue, :work, :planning, :review, :done, nil],
    default: nil,
    doc: "the card's stage behavior type — distinguishes the three :ready renderings"

  attr :done, :boolean,
    default: false,
    doc: "derived Done: a :ready card at the board's terminal stage (Relay.Cards.done?/2)"

  attr :question, :string,
    default: nil,
    doc: "the latest needs_input question, echoed as a one-line preview on needs_input cards"

  attr :progress, :integer, default: nil

  attr :health, :atom,
    values: [:live, :stale, :stopped, :none],
    default: :none,
    doc: "RLY-112 derived agent health (Relay.Cards.health/1); :none renders no strip at all"

  attr :log_text, :string, default: nil, doc: "the newest entry's text, shown in the log strip"
  attr :log_at, :any, default: nil, doc: "the newest entry's inserted_at, shown as a relative time"

  attr :owners, :list, default: [], doc: "the card's loaded owner rows, for the avatar cluster"

  attr :lane, :atom,
    values: [:main, :review, :done, nil],
    default: :main,
    doc: "which sub-lane the card sits in — cosmetic only (stage_column also derives stage_type)"

  attr :category, :atom,
    values: [:unstarted, :planning, :in_progress, :complete, nil],
    default: nil,
    doc: "the stage's category — cosmetic only (accent is keyed on status, not category)"

  def board_card(assigns) do
    accent_class = card_accent_class(assigns)

    assigns =
      assigns
      |> assign(:accent_class, accent_class)
      |> assign(:accent_color, card_accent_color(accent_class))
      |> assign(:shell_style, card_shell_style(assigns))

    ~H"""
    <article
      id={@id}
      class={["board-card group", @accent_class]}
      style={"background:var(--color-base-100);#{@shell_style}border-left:3px solid #{@accent_color};border-radius:9px;padding:10px 11px;display:flex;flex-direction:column;gap:8px;cursor:pointer;"}
      role="button"
      tabindex="0"
      draggable="true"
      data-ref={@ref}
      data-status={@status}
      data-health={@health}
      data-done={to_string(@done)}
      data-active-owner={@active_owner}
      phx-click="select_card"
      phx-value-ref={@ref}
    >
      <span
        class="card-title"
        style={"font-size:12.5px;font-weight:500;line-height:1.35;letter-spacing:-0.01em;color:#{if(@done, do: "oklch(0.62 0.02 255)", else: "var(--color-base-content)")};"}
      >
        {@title}
      </span>
      <span class="card-ref sr-only">{@ref}</span>
      <div
        :if={@status == :working and @progress != nil}
        style="height:5px;border-radius:3px;background:oklch(0.93 0.02 292);overflow:hidden;"
      >
        <div style={"height:100%;width:#{@progress || 0}%;background:var(--color-secondary);border-radius:3px;"}>
        </div>
      </div>
      <div
        :if={@health != :none}
        id={"card-#{@ref}-log-strip"}
        class="card-log-strip"
        data-health={@health}
        style={"display:flex;align-items:center;gap:7px;border-radius:6px;padding:6px 8px;#{strip_box_style(@health)}"}
      >
        <span
          id={"card-#{@ref}-log-strip-dot"}
          class="card-log-strip-dot"
          data-health={@health}
          style={strip_dot_style(@health)}
        >
          {if @health == :stopped, do: "!"}
        </span>
        <span
          class="card-log-strip-text"
          style={"font-size:10.5px;font-family:var(--font-mono);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#{strip_text_color(@health)};"}
        >
          {@log_text}
        </span>
        <span
          class="card-log-strip-time"
          style={"font-size:10.5px;font-family:var(--font-mono);flex:0 0 auto;color:#{strip_time_color(@health)};"}
        >
          {relative_time(@log_at)}
        </span>
      </div>
      <div
        :if={@status == :needs_input}
        class="card-needs-input"
        style="display:flex;align-items:center;gap:6px;background:oklch(0.97 0.03 75);border:1px solid oklch(0.87 0.07 75);border-radius:6px;padding:6px 8px;"
      >
        <span style="width:6px;height:6px;border-radius:50%;background:var(--color-warning);flex:0 0 auto;">
        </span>
        <span style="font-size:10px;font-weight:600;letter-spacing:0.03em;color:oklch(0.52 0.11 65);font-family:var(--font-mono);">
          needs you
        </span>
      </div>
      <p
        :if={@status == :needs_input && @question}
        class="card-question-preview truncate"
        style="font-size:11px;line-height:1.3;color:oklch(0.50 0.04 65);margin:0;"
      >
        {@question}
      </p>
      <div style="display:flex;align-items:center;gap:7px;">
        <span
          :if={@status == :working and @health == :none}
          class="card-status"
          data-status={@status}
          style="font-size:11px;font-family:var(--font-mono);color:oklch(0.52 0.10 292);"
        >
          {if(@progress, do: "working · #{@progress}%", else: "working")}
        </span>
        <span
          :if={@status == :in_review}
          class="card-review-chip badge badge-sm badge-warning font-medium"
          style="font-size:10px;"
        >
          review
        </span>
        <span
          :if={@status == :ready && @stage_type == :done && !@done}
          class="card-ready-chip badge badge-sm badge-success font-medium"
          style="font-size:10px;"
        >
          ready
        </span>
        <span
          :if={@tag && @status != :working}
          class="card-tag"
          style="font-size:11px;color:oklch(0.60 0.02 255);font-family:var(--font-mono);"
        >
          #{@tag}
        </span>
        <span style="flex:1;"></span>
        <.owner_avatars owners={@owners} active_owner={@active_owner} />
      </div>
    </article>
    """
  end

  # RLY-48: the left-border accent is keyed on status. Amber for the two needs-you
  # states; violet for working; everything else (all :ready renderings, unowned) is
  # quiet base-300. The green "done" affordance moved off the border (there is no
  # :done status) — a terminal ready card grays instead (see the title style).
  #
  # The returned `border-l-*` string is a *semantic/test hook only* — it is NOT
  # what paints the border. The actual 3px accent colour is set inline in
  # board_card/1 via card_accent_color/1 (an inline `style` beats the class, so
  # the class carries no colour). Do not delete these classes as "unused": the
  # board/card tests select on them (e.g. `.border-l-warning`).
  # RLY-148 (supersedes the 2026-07-16 RLY-112 rejection): a dead agent DOES recolor
  # the card — health :stale/:stopped beats the status accent (artboard §02 card
  # chrome). Every other health state leaves the RLY-48 status accent as-is.
  defp card_accent_class(%{health: :stale}), do: "border-l-warning"
  defp card_accent_class(%{health: :stopped}), do: "border-l-error"
  defp card_accent_class(%{status: :needs_input}), do: "border-l-warning"
  defp card_accent_class(%{status: :in_review}), do: "border-l-warning"
  defp card_accent_class(%{status: :working}), do: "border-l-secondary"
  defp card_accent_class(_assigns), do: "border-l-base-300"

  defp card_accent_color("border-l-error"), do: "var(--color-error)"
  defp card_accent_color("border-l-warning"), do: "var(--color-warning)"
  defp card_accent_color("border-l-secondary"), do: "var(--color-secondary)"
  defp card_accent_color("border-l-base-300"), do: "var(--color-base-300)"

  # RLY-148: the card shell escalates with health (artboard §02) — amber-tinted
  # border + shadow when stale, rose when stopped, the quiet RLY-48 shell otherwise.
  defp card_shell_style(%{health: :stale}),
    do: "border:1px solid oklch(0.86 0.06 70);box-shadow:0 1px 3px oklch(0.6 0.08 70/0.12);"

  defp card_shell_style(%{health: :stopped}),
    do: "border:1px solid oklch(0.86 0.07 20);box-shadow:0 1px 3px oklch(0.6 0.1 15/0.12);"

  defp card_shell_style(_assigns),
    do: "border:1px solid var(--color-base-300);box-shadow:0 1px 2px oklch(0.55 0.03 255/0.05);"

  # RLY-148 — the collapsed log strip, full artboard fidelity. Every value is pinned to
  # docs/designs/Relay Card Activity.dc.html §02 (violet pulse / amber tint / rose white-!
  # disc); the light theme's --color-secondary/-warning/-error are byte-identical to the
  # artboard's violet/amber/rose. Supersedes the 2026-07-16 gray-stale rejection.
  defp strip_box_style(:live), do: "background:oklch(0.985 0.012 292);"
  defp strip_box_style(:stale), do: "background:oklch(0.97 0.03 75);border:1px solid oklch(0.88 0.06 75);"
  defp strip_box_style(:stopped), do: "background:oklch(0.97 0.03 20);border:1px solid oklch(0.88 0.06 20);"
  defp strip_box_style(_health), do: ""

  defp strip_dot_style(:live),
    do:
      "width:6px;height:6px;border-radius:50%;flex:0 0 auto;background:var(--color-secondary);animation:relaypulse 1.4s ease-in-out infinite;"

  defp strip_dot_style(:stale),
    do: "width:6px;height:6px;border-radius:50%;flex:0 0 auto;background:var(--color-warning);"

  defp strip_dot_style(:stopped),
    do:
      "width:14px;height:14px;border-radius:50%;flex:0 0 auto;background:var(--color-error);color:oklch(1 0 0);display:flex;align-items:center;justify-content:center;font-size:8px;font-weight:700;"

  defp strip_dot_style(_health), do: ""

  defp strip_text_color(:live), do: "oklch(0.44 0.08 292)"
  defp strip_text_color(:stale), do: "oklch(0.50 0.10 65)"
  defp strip_text_color(:stopped), do: "oklch(0.50 0.14 15)"
  defp strip_text_color(_health), do: "oklch(0.44 0.02 255)"

  defp strip_time_color(:live), do: "oklch(0.60 0.02 255)"
  defp strip_time_color(:stale), do: "oklch(0.52 0.11 65)"
  defp strip_time_color(:stopped), do: "oklch(0.50 0.14 15)"
  defp strip_time_color(_health), do: "oklch(0.60 0.02 255)"

  # RLY-148 §04 header chip — amber when stale; Retry joins it on stopped (Task 2).
  defp health_chip_color(:live), do: "var(--color-secondary)"
  defp health_chip_color(:stale), do: "var(--color-warning)"
  defp health_chip_color(:stopped), do: "var(--color-error)"
  defp health_chip_color(_health), do: "var(--color-base-300)"

  defp health_chip_label(:live), do: "Relay AI is live"
  defp health_chip_label(:stale), do: "Relay AI has gone quiet"
  defp health_chip_label(:stopped), do: "Relay AI stopped"
  defp health_chip_label(_health), do: ""

  # §04 dot colour by kind. The artboard paints the Approved decision green; the spec's
  # mapping (decision → amber) wins. :move never reaches here — it renders as a chip.
  # :failure and :decision are always genuine agent/system events, so they stay
  # kind-only. :action is kind/1's catch-all — it ALSO carries every legacy audit
  # row (:created, :commented, :status_changed, :owners_changed, :archived,
  # :unarchived), which a human can trigger. AGENTS.md reserves violet for AI and
  # blue for human, so within :action fall back to the row's actor: an agent's
  # runner line stays violet, a human's audit row goes blue.
  #
  # RESOLVED 2026-07-15 (Jeremy): actor-aware, not kind-only. This block previously
  # read `_action -> "var(--color-secondary)"`, which the implementer correctly
  # refused to ship — it would render a human's own :commented / :status_changed row
  # in the AI colour, contradicting the palette rule that encodes this product's core
  # idea (who holds the baton). The plan is the thing that was wrong. Two tests pin
  # the shipped behaviour: board_drawer_activity_test.exs:102 and :118.
  defp entry_dot_color(entry) do
    # Fully qualified on purpose: `Activity` in this module is `Schemas.Activity`.
    case Relay.Activity.kind(entry) do
      :failure -> "var(--color-error)"
      :decision -> "var(--color-warning)"
      _action -> if entry.actor_type == :agent, do: "var(--color-secondary)", else: "var(--color-primary)"
    end
  end

  # The artboard's compact relative time: now / 8m / 2h / 3d.
  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  # RLY-112: %{card_id => %{state:, entry:}} -> board_card/1's three log attrs. Deriving
  # the text here (rather than in BoardLive) keeps activity_phrase/1 — the shared fallback
  # for audit rows, which carry no `text` — private to this module.
  defp card_log_attrs(health_by_card, card_id) do
    case Map.get(health_by_card, card_id) do
      nil -> %{health: :none, log_text: nil, log_at: nil}
      %{state: :none} -> %{health: :none, log_text: nil, log_at: nil}
      %{state: state, entry: nil} -> %{health: state, log_text: nil, log_at: nil}
      %{state: state, entry: entry} -> %{health: state, log_text: entry_text(entry), log_at: entry.inserted_at}
    end
  end

  # A runner line renders its own text; an audit row has none, so it borrows the
  # drawer's sentence. One helper, shared by the strip and the timeline.
  defp entry_text(%Activity{text: text}) when is_binary(text) and text != "", do: text
  defp entry_text(%Activity{} = entry), do: activity_phrase(entry)

  defp sublane_width(%{collapsed: true}), do: 34
  defp sublane_width(_sub), do: 178

  defp lane_color(:review), do: "oklch(0.52 0.12 65)"
  defp lane_color(:done), do: "oklch(0.47 0.11 155)"
  defp lane_color(_ongoing), do: "oklch(0.52 0.02 255)"

  defp lane_tint(:review), do: "oklch(0.966 0.032 75)"
  defp lane_tint(:done), do: "oklch(0.964 0.03 155)"
  defp lane_tint(_ongoing), do: "transparent"

  defp lane_divider(:review), do: "oklch(0.90 0.04 75)"
  defp lane_divider(:done), do: "oklch(0.90 0.035 155)"
  defp lane_divider(_ongoing), do: "oklch(0.915 0.008 255)"

  # RLY-1 item 9 — WIP threshold: over → red, at → amber, else neutral. Effective
  # count is the stage's main lane plus its sub-lanes (@total_count); no limit → :none.
  defp wip_state(_count, nil), do: :none
  defp wip_state(count, limit) when count > limit, do: :over
  defp wip_state(count, limit) when count == limit, do: :at
  defp wip_state(_count, _limit), do: :under

  defp wip_border_color(:over), do: "var(--color-error)"
  defp wip_border_color(:at), do: "var(--color-warning)"
  defp wip_border_color(_state), do: "var(--color-base-300)"

  defp wip_chip_colors(:over), do: "background:oklch(0.96 0.03 15);color:oklch(0.55 0.16 15);"
  defp wip_chip_colors(:at), do: "background:oklch(0.97 0.05 75);color:oklch(0.52 0.13 65);"
  defp wip_chip_colors(_state), do: "background:oklch(0.96 0.006 255);color:oklch(0.48 0.02 255);"

  @doc """
  The drawer's mono-uppercase section label (main headings + rail labels).

  Renders the shared label treatment
  (`font-mono text-[10px] font-semibold uppercase tracking-[0.06em]`). Pass `accent`
  (a full text-color class such as `text-secondary`) to tint it — e.g. the violet
  AI Result heading — which replaces the default muted color.

  ## Examples

      <.section_label>Owners</.section_label>
      <.section_label accent="text-secondary">AI Result</.section_label>
  """
  attr :accent, :string,
    default: nil,
    doc: "a full text-color class (e.g. \"text-secondary\") used instead of the muted default"

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def section_label(assigns) do
    ~H"""
    <span class={[
      "font-mono text-[10px] font-semibold uppercase tracking-[0.06em]",
      @accent || "text-base-content/60",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
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

  Description renders reading/editing only. Spec and Plan render as collapsible
  boxed fields (accent bar + eyebrow label + Collapse/Expand/Add toggle): a faded
  collapsed preview with Show more by default, expanding to a full read; empty →
  a dashed "Add…" box. `branch` renders as a mono chip and `pr_url` as a
  "Review PR ↗" link chip in the properties rail; both are read-only (the runner
  sets them via the API).

  Events emitted (handled by the parent LiveView): `"save_card_title"`
  (form params `card[title]`) on title submit, `"edit_description"` when
  the description view is clicked, `"cancel_description"` on Cancel,
  `"save_card_description"` (form params `card[description]`) on save,
  `"toggle_spec"` / `"toggle_plan"` (flip the Spec/Plan expanded state),
  `"move_card"` (phx-value ref + stage_id, no index — the server appends
  to the target stage's bottom) when a "Move to…" target is picked,
  `"add_owner"` / `"remove_owner"` (phx-value
  `actor_type` + `user_id`) from the owners rail's controls,
  `"validate_comment"` / `"post_comment"` (form params `comment[body]`)
  from the timeline composer, and `"answer_input"` (form params
  `answer[body]`) from the needs-input panel's composer, and the MMF 15
  review-panel events: `"review_approve"`, `"review_open_reject"`,
  `"review_cancel_reject"`, and `"review_reject"` (form params `reject[note]` +
  `reject[to]`).

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
    doc:
      "a card exposing title, description, spec, tag, status, blocked_since, branch, plan, pr_url, a loaded owners list, inserted_at, and updated_at"

  attr :stage_name, :string, required: true
  attr :stage_owner, :atom, values: [:human, :ai], required: true

  attr :active_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "who holds the baton, derived from the card's owner list"

  attr :close_patch, :string, required: true, doc: "the patch target that closes the drawer"
  attr :title_form, :any, required: true, doc: "a Phoenix.HTML.Form for card[title]"
  attr :editing_title, :boolean, default: false
  attr :editing_description, :boolean, default: false

  attr :description_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for card[description]; required when editing_description"

  attr :editing_spec, :boolean, default: false
  attr :editing_plan, :boolean, default: false
  attr :expanded_spec, :boolean, default: false
  attr :expanded_plan, :boolean, default: false
  attr :spec_form, :any, default: nil, doc: "a Phoenix.HTML.Form for card[spec]"
  attr :plan_form, :any, default: nil, doc: "a Phoenix.HTML.Form for card[plan]"

  attr :editing_acceptance_criteria, :boolean, default: false
  attr :expanded_acceptance_criteria, :boolean, default: false

  attr :acceptance_criteria_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for card[acceptance_criteria]"

  attr :current_user_id, :integer,
    default: nil,
    doc: "the signed-in user's id, for the Add me owner control"

  attr :members, :list,
    default: [],
    doc: "resolved board memberships (:user preloaded) — reassign-picker assignables"

  attr :reassign_open, :boolean,
    default: false,
    doc: "whether the OWNERS reassign picker popover is open"

  attr :stages, :list,
    default: [],
    doc: "move targets: the board's other stages (each exposing id and name); [] hides the menu"

  attr :conversation, :any,
    required: true,
    doc: "the :conversation LiveView stream — the card's comments, oldest first"

  attr :activity, :any,
    required: true,
    doc: "the :activity LiveView stream — the card's activity-log entries, newest first"

  attr :health, :atom,
    values: [:live, :stale, :stopped, :none],
    default: :none,
    doc: "RLY-112 derived agent health, for the Activity section's header chip"

  attr :comment_form, :any, required: true, doc: "a Phoenix.HTML.Form for comment[body]"

  attr :question, :string,
    default: nil,
    doc: "the latest :needs_input question from the timeline; nil when a human blocked without one"

  attr :answer_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for answer[body]; required when the card's status is :needs_input"

  attr :answer_questions, :any,
    default: nil,
    doc:
      "RLY-71 structured needs-input questions (list of %{prompt, options, allow_text}); nil renders the single-textarea fallback"

  attr :answer_step, :integer, default: 0, doc: "RLY-71 stepper: 0-based current question index"

  attr :answer_values, :map,
    default: %{},
    doc: "RLY-71 stepper: %{integer => string} answer picked/typed per question index"

  attr :review_gate, :any,
    default: nil,
    doc:
      "MMF 15 gate info for an :in_review card on a review-type stage — %{approve_label, reject_target_name, can_reject}; nil when the card is not in a review-type stage"

  attr :reject_open, :boolean,
    default: false,
    doc: "whether the Request-changes note sub-panel is expanded in place"

  attr :reject_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for reject[note]; required when the card's status is :in_review"

  attr :reject_error, :string,
    default: nil,
    doc: "inline prompt shown when Send back was submitted with an empty note"

  attr :archived, :boolean,
    default: false,
    doc:
      "whether the open card itself is archived (RLY-4): shows the read-only archived banner + Restore and suppresses the edit/status/move affordances"

  attr :done, :boolean,
    default: false,
    doc: "derived Done (Relay.Cards.done?/2): shows a Done pill in the header; no banner below"

  attr :body_loading, :boolean,
    default: false,
    doc:
      "RLY-68 optimistic drawer: when true, the heavy sections (description/acceptance_criteria/spec/plan/ai_result/needs-input question/timeline) render daisyUI skeletons instead of their content; the async fill flips this false"

  attr :embed, :boolean,
    default: false,
    doc:
      "RLY-87: hosted inside the native shell — drops the web review buttons (the native action bar is the only actor) and the drawer's own dismissal affordances (scrim + close ✕), which the native back chevron owns. Keeps the review panel's label and hint: the context for the decision is the point of the screen."

  def card_drawer(assigns) do
    assigns =
      assigns
      |> assign(:sub_task_progress, Cards.sub_task_progress(assigns.card))
      |> assign(:working_progress, board_card_progress(assigns.card))
      |> assign(
        :stepper_question,
        if(is_list(assigns[:answer_questions]),
          do: Enum.at(assigns.answer_questions, assigns[:answer_step] || 0)
        )
      )

    ~H"""
    <div id={@id} class="drawer drawer-end" phx-window-keydown="close_drawer" phx-key="escape">
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="drawer-toggle"
        checked
        tabindex="-1"
        aria-hidden="true"
      />
      <div class="drawer-side z-40">
        <.link :if={!@embed} id={"#{@id}-scrim"} patch={@close_patch} class="drawer-overlay">
          <span class="sr-only">Close</span>
        </.link>
        <aside class="drawer-panel flex h-dvh w-full flex-col overflow-y-auto bg-base-100 shadow-xl drawer:overflow-hidden drawer:w-[min(760px,94vw)]">
          <header class="flex items-start gap-3 border-b border-base-300 p-5">
            <div class="flex min-w-0 flex-1 flex-col gap-1.5">
              <div class="flex items-center gap-2">
                <span class={[
                  "drawer-stage-chip badge badge-sm font-medium",
                  if(@stage_owner == :human, do: "badge-primary", else: "badge-secondary")
                ]}>
                  {@stage_name}
                </span>
                <span class="drawer-card-ref font-mono text-xs text-base-content/60">{@ref}</span>
                <span
                  :if={@done}
                  id="drawer-done-pill"
                  class="badge badge-success badge-sm font-medium"
                >
                  Done
                </span>
              </div>
              <.inline_field
                :if={!@archived}
                id={"#{@id}-title"}
                value={@card.title}
                editing={@editing_title}
                form={@title_form}
                field={:title}
                edit_event="edit_title"
                save_event="save_card_title"
                cancel_event="cancel_title"
                read_class="break-words px-1 text-lg font-semibold leading-[1.3]"
                input_class="text-lg font-semibold leading-[1.3]"
              />
              <h2
                :if={@archived}
                id={"#{@id}-title-archived"}
                class="whitespace-pre-wrap break-words px-1 text-lg font-semibold leading-[1.3]"
              >
                {@card.title}
              </h2>
            </div>
            <.link
              :if={!@embed}
              id={"#{@id}-close"}
              patch={@close_patch}
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Close card drawer"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </.link>
          </header>

          <div class="flex min-h-0 flex-none flex-col drawer:flex-1 drawer:flex-row drawer:overflow-hidden">
            <div
              id={"#{@id}-main"}
              class="flex min-w-0 flex-none flex-col gap-6 p-5 drawer:flex-1 drawer:overflow-y-auto"
            >
              <section
                :if={@archived}
                id="card-archived-banner"
                class="flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm"
                style="background:oklch(0.97 0.04 85);border:1px solid oklch(0.85 0.09 85);color:oklch(0.42 0.09 85);"
              >
                <.icon name="hero-archive-box" class="size-4" />
                <span class="flex-1">This card is archived.</span>
                <button
                  type="button"
                  id="restore-card-button"
                  phx-click="restore_card"
                  phx-value-ref={@ref}
                  class="btn btn-sm"
                >
                  Restore
                </button>
              </section>
              <section
                :if={@card.rejection}
                id="rejection-banner"
                class="flex flex-col gap-1.5 rounded-[10px] border border-warning/40 bg-warning/10 p-3.5"
              >
                <span class="font-mono text-[10px] font-semibold uppercase tracking-[0.05em] text-warning">
                  Changes requested — sent back to {@card.rejection.to_stage_name} by {@card.rejection.rejected_by}
                </span>
                <div class="md text-[13.5px] leading-normal text-base-content/80">
                  {Relay.Markdown.to_html(@card.rejection.note)}
                </div>
              </section>
              <section
                :if={@card.status == :working and !@archived}
                id="working-strip"
                class="flex items-center gap-2.5 rounded-[10px] px-4 py-3"
                style="background:oklch(0.97 0.03 292);border:1px solid oklch(0.90 0.05 292);"
              >
                <span
                  class="working-pulse"
                  style="width:7px;height:7px;border-radius:50%;background:oklch(0.56 0.16 292);animation:relaypulse 1.4s ease-in-out infinite;flex:0 0 auto;"
                >
                </span>
                <span class="text-[12.5px] font-semibold" style="color:oklch(0.48 0.12 292);">
                  Relay AI is working
                </span>
                <span
                  :if={@working_progress}
                  id="working-strip-pct"
                  class="font-mono text-[11px]"
                  style="color:oklch(0.52 0.10 292);"
                >
                  {@working_progress}%
                </span>
                <span style="flex:1;"></span>
                <div
                  class="h-[5px] w-24 overflow-hidden rounded-[3px]"
                  style="background:oklch(0.93 0.02 292);"
                >
                  <div
                    class="h-full rounded-[3px]"
                    style={"width:#{@working_progress || 0}%;background:var(--color-secondary);"}
                  >
                  </div>
                </div>
              </section>
              <section
                :if={@card.status == :needs_input and !@archived}
                id="needs-input-panel"
                class="flex flex-col gap-4 rounded-[10px] p-5"
                style="background:oklch(0.975 0.025 75);border:1px solid oklch(0.87 0.07 75);"
              >
                <div class="flex items-center justify-between">
                  <span
                    class="font-mono text-[10px] font-semibold tracking-[0.05em]"
                    style="color:oklch(0.52 0.11 65);"
                  >
                    RELAY AI NEEDS YOUR INPUT
                  </span>
                  <span
                    :if={@card.blocked_since}
                    id="needs-input-waiting"
                    class="font-mono text-[10px]"
                    style="color:oklch(0.52 0.11 65);"
                  >
                    {waiting_label(@card.blocked_since)}
                  </span>
                </div>
                <%!-- RLY-71 stepper: one structured question at a time --%>
                <div :if={@answer_questions} id="needs-input-stepper" class="flex flex-col gap-4">
                  <div
                    id="needs-input-progress"
                    class="font-mono text-[10px]"
                    style="color:oklch(0.52 0.11 65);"
                  >
                    Question {@answer_step + 1} of {length(@answer_questions)}
                  </div>
                  <div
                    id="needs-input-question"
                    class="md text-[13.5px] leading-normal break-words"
                    style="color:oklch(0.33 0.03 65);"
                  >
                    {Relay.Markdown.to_html(@stepper_question["prompt"])}
                  </div>
                  <div :if={@stepper_question["options"] != []} class="flex flex-col gap-2">
                    <%!-- phx-value-option, not phx-value-value: "value" collides with the
                    button's intrinsic DOM .value property (empty for a value-less <button>),
                    which wins over the phx-value-* attribute when a real browser serializes
                    the click — silently sending "" instead of the picked option. --%>
                    <button
                      :for={{option, index} <- Enum.with_index(@stepper_question["options"])}
                      type="button"
                      id={"needs-input-option-#{index}"}
                      phx-click="answer_select"
                      phx-value-index={@answer_step}
                      phx-value-option={option}
                      class={
                        [
                          "btn btn-sm justify-start rounded-[7px] font-normal",
                          # daisyUI's .btn is a fixed-height (`height: var(--size)`)
                          # nowrap flex row, which clips a long option. Real agent
                          # options are sentences, so let them grow to as many lines
                          # as they need while a short one keeps the compact height.
                          "h-auto min-h-8 whitespace-normal px-3 py-2 text-left leading-snug",
                          Map.get(@answer_values, @answer_step) == option &&
                            "needs-input-option-selected text-white"
                        ]
                      }
                      style={
                        if(Map.get(@answer_values, @answer_step) == option,
                          do: "background:oklch(0.70 0.13 65);border-color:oklch(0.70 0.13 65);",
                          else:
                            "background:transparent;border:1px solid oklch(0.87 0.07 75);color:oklch(0.33 0.03 65);"
                        )
                      }
                    >
                      {option}
                    </button>
                  </div>
                  <form
                    :if={@stepper_question["allow_text"]}
                    id="needs-input-text-form"
                    phx-change="answer_custom"
                  >
                    <input type="hidden" name="answer[index]" value={@answer_step} />
                    <textarea
                      id="needs-input-text"
                      name="answer[text]"
                      rows="3"
                      autocomplete="off"
                      placeholder={
                        if(@stepper_question["options"] == [],
                          do: "Type your answer…",
                          else: "Or type your own…"
                        )
                      }
                      class="w-full resize-none rounded-[7px] p-[9px] text-[13px] leading-[1.45] outline-none"
                      style="border:1px solid oklch(0.86 0.05 75);background:oklch(1 0 0);color:oklch(0.30 0.02 255);"
                    ><%= stepper_custom_text(
                      @answer_values,
                      @answer_step,
                      @stepper_question["options"]
                    ) %></textarea>
                  </form>
                  <div class="flex items-center justify-between">
                    <button
                      :if={@answer_step > 0}
                      id="needs-input-back"
                      type="button"
                      phx-click="answer_back"
                      class="btn btn-sm btn-ghost rounded-[7px]"
                    >
                      ← Back
                    </button>
                    <span :if={@answer_step == 0}></span>
                    <button
                      :if={@answer_step < length(@answer_questions) - 1}
                      id="needs-input-next"
                      type="button"
                      phx-click="answer_next"
                      disabled={not Map.has_key?(@answer_values, @answer_step)}
                      class="btn btn-sm rounded-[7px] border-none font-semibold text-white"
                      style="background:oklch(0.70 0.13 65);"
                    >
                      Next →
                    </button>
                    <button
                      :if={@answer_step == length(@answer_questions) - 1}
                      id="needs-input-send"
                      type="button"
                      phx-click="answer_submit"
                      disabled={not Map.has_key?(@answer_values, @answer_step)}
                      class="btn btn-sm rounded-[7px] border-none font-semibold text-white"
                      style="background:oklch(0.70 0.13 65);"
                    >
                      Send to AI →
                    </button>
                  </div>
                </div>
                <%!-- fallback: today's single-textarea composer for plain-string / human blocks --%>
                <div :if={is_nil(@answer_questions)}>
                  <div
                    :if={@body_loading}
                    id="needs-input-question-skeleton"
                    class="skeleton h-5 w-3/4 rounded"
                  >
                  </div>
                  <div
                    :if={!@body_loading and @question}
                    id="needs-input-question"
                    class="md text-[13.5px] leading-normal"
                    style="color:oklch(0.33 0.03 65);"
                  >
                    {Relay.Markdown.to_html(@question)}
                  </div>
                  <.form
                    for={@answer_form}
                    id="needs-input-form"
                    class="flex flex-col items-start gap-[11px]"
                    phx-submit="answer_input"
                  >
                    <div class="w-full">
                      <.boxed_field
                        id="needs-input-answer"
                        commit={:form}
                        multiline
                        rows="3"
                        form={@answer_form}
                        field={:body}
                        input_class="w-full"
                        placeholder="Type your answer — the AI picks up where it left off…"
                        phx-hook="SubmitOnCmdEnter"
                      />
                    </div>
                    <button
                      id="needs-input-send"
                      type="submit"
                      class="btn btn-sm rounded-[7px] border-none font-semibold text-white"
                      style="background:oklch(0.70 0.13 65);"
                    >
                      Send to AI →
                    </button>
                  </.form>
                </div>
              </section>
              <section
                :if={@card.status == :in_review and !@archived}
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
                <div :if={@review_gate && !@reject_open && !@embed} class="flex gap-2">
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
                    :if={@review_gate.can_reject}
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
                  :if={@review_gate && @reject_open && !@embed}
                  id="review-reject-panel"
                  class="flex flex-col gap-2 rounded-lg bg-white p-3"
                  style="border:1px solid oklch(0.90 0.02 255);"
                >
                  <div
                    class="flex items-center gap-2 rounded-lg px-3 py-2"
                    style="background:oklch(0.985 0.02 195);border:1px solid oklch(0.90 0.03 195);"
                  >
                    <span class="text-[13px] leading-none" style="color:oklch(0.44 0.11 195);">
                      ↩
                    </span>
                    <span class="text-[12.5px] leading-normal" style="color:oklch(0.38 0.04 210);">
                      Returns to
                      <b style="color:oklch(0.34 0.09 205);">{@review_gate.reject_target_name}</b>
                      — the reject target set on this stage.
                    </span>
                  </div>
                  <.form
                    for={@reject_form}
                    id="review-reject-form"
                    class="flex flex-col gap-2"
                    phx-submit="review_reject"
                  >
                    <.boxed_field
                      id="review-request-note"
                      commit={:form}
                      multiline
                      rows="3"
                      form={@reject_form}
                      field={:note}
                      placeholder="What needs to change? This note goes to the AI…"
                      phx-hook="SubmitOnCmdEnter"
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
                        style="background:oklch(0.62 0.14 65);"
                      >
                        Reject → {@review_gate.reject_target_name}
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
              <section id={"#{@id}-description"} class="space-y-2">
                <.section_label>Description</.section_label>
                <div
                  :if={@body_loading}
                  id={"#{@id}-description-skeleton"}
                  class="skeleton h-28 w-full rounded-lg"
                >
                </div>
                <.boxed_field
                  :if={!@body_loading and !@archived}
                  id={"#{@id}-description"}
                  value={@card.description}
                  editing={@editing_description}
                  form={@description_form}
                  field={:description}
                  edit_event="edit_description"
                  save_event="save_card_description"
                  cancel_event="cancel_description"
                  placeholder="Add a description…"
                  markdown
                  multiline
                  rows="12"
                />
                <div
                  :if={!@body_loading and @archived}
                  id={"#{@id}-description-archived"}
                  class="md min-h-16 p-1 text-sm leading-relaxed"
                >
                  {Relay.Markdown.to_html(@card.description || "_No description._")}
                </div>
              </section>

              <section
                :if={@body_loading}
                id={"#{@id}-acceptance-criteria-skeleton-section"}
                class="space-y-2"
              >
                <.section_label>Acceptance Criteria</.section_label>
                <div
                  id={"#{@id}-acceptance-criteria-skeleton"}
                  class="skeleton h-32 w-full rounded-lg"
                >
                </div>
              </section>
              <section
                :if={!@body_loading and !@archived}
                id={"#{@id}-acceptance-criteria"}
                class="space-y-2"
              >
                <.boxed_field
                  id={"#{@id}-acceptance-criteria"}
                  value={@card.acceptance_criteria}
                  editing={@editing_acceptance_criteria}
                  form={@acceptance_criteria_form}
                  field={:acceptance_criteria}
                  edit_event="edit_acceptance_criteria"
                  save_event="save_card_acceptance_criteria"
                  cancel_event="cancel_acceptance_criteria"
                  placeholder="Add acceptance criteria…"
                  label="Acceptance Criteria"
                  accent={:accent}
                  collapsible
                  expanded={@expanded_acceptance_criteria}
                  toggle_event="toggle_acceptance_criteria"
                  markdown
                  multiline
                  rows="12"
                />
              </section>
              <section
                :if={(!@body_loading and @archived) && @card.acceptance_criteria}
                id={"#{@id}-acceptance-criteria-archived"}
                class="space-y-2"
              >
                <.section_label>Acceptance Criteria</.section_label>
                <div id={"#{@id}-acceptance-criteria-view"} class="md text-sm leading-relaxed">
                  {Relay.Markdown.to_html(@card.acceptance_criteria)}
                </div>
              </section>

              <section :if={@body_loading} id={"#{@id}-spec-skeleton-section"} class="space-y-2">
                <.section_label>Spec</.section_label>
                <div id={"#{@id}-spec-skeleton"} class="skeleton h-32 w-full rounded-lg"></div>
              </section>
              <section :if={!@body_loading and !@archived} id={"#{@id}-spec"} class="space-y-2">
                <.boxed_field
                  id={"#{@id}-spec"}
                  value={@card.spec}
                  editing={@editing_spec}
                  form={@spec_form}
                  field={:spec}
                  edit_event="edit_spec"
                  save_event="save_card_spec"
                  cancel_event="cancel_spec"
                  placeholder="Add a spec…"
                  label="Spec"
                  accent={:primary}
                  collapsible
                  expanded={@expanded_spec}
                  toggle_event="toggle_spec"
                  markdown
                  multiline
                  rows="14"
                />
              </section>
              <section
                :if={(!@body_loading and @archived) && @card.spec}
                id={"#{@id}-spec-archived"}
                class="space-y-2"
              >
                <.section_label>Spec</.section_label>
                <div id={"#{@id}-spec-view"} class="md text-sm leading-relaxed">
                  {Relay.Markdown.to_html(@card.spec)}
                </div>
              </section>

              <section :if={@body_loading} id="card-plan-skeleton-section" class="space-y-2">
                <.section_label>Plan</.section_label>
                <div id="card-plan-skeleton" class="skeleton h-40 w-full rounded-lg"></div>
              </section>
              <section :if={!@body_loading and !@archived} id="card-plan" class="space-y-2">
                <.boxed_field
                  id="card-plan"
                  value={@card.plan}
                  editing={@editing_plan}
                  form={@plan_form}
                  field={:plan}
                  edit_event="edit_plan"
                  save_event="save_card_plan"
                  cancel_event="cancel_plan"
                  placeholder="Add a plan…"
                  label="Plan"
                  accent={:secondary}
                  collapsible
                  expanded={@expanded_plan}
                  toggle_event="toggle_plan"
                  markdown
                  multiline
                  rows="16"
                />
              </section>
              <section
                :if={(!@body_loading and @archived) && @card.plan}
                id="card-plan-archived"
                class="space-y-2"
              >
                <.section_label>Plan</.section_label>
                <div
                  id="card-plan-body"
                  class="md overflow-x-auto text-xs leading-relaxed text-base-content/80"
                >
                  {Relay.Markdown.to_html(@card.plan)}
                </div>
              </section>

              <section :if={@body_loading} id="ai-result-skeleton-section" class="space-y-2">
                <.section_label accent="text-secondary">AI Result</.section_label>
                <div id="ai-result-skeleton" class="skeleton h-24 w-full rounded-lg"></div>
              </section>
              <section :if={!@body_loading and @card.ai_result} id="ai-result" class="space-y-2">
                <.section_label accent="text-secondary">AI Result</.section_label>
                <div
                  class="space-y-3 rounded-[10px] border p-3.5"
                  style="border-color:oklch(0.88 0.05 295);background:oklch(0.985 0.01 295);"
                >
                  <div
                    :if={@card.ai_result["summary"]}
                    id="ai-result-summary"
                    class="md text-sm leading-relaxed"
                  >
                    {Relay.Markdown.to_html(@card.ai_result["summary"])}
                  </div>
                  <ul
                    :if={@card.ai_result["changes"] not in [nil, []]}
                    id="ai-result-changes"
                    class="space-y-1"
                  >
                    <li
                      :for={change <- @card.ai_result["changes"]}
                      class="flex items-start gap-2 text-sm"
                    >
                      <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
                      <span>{change}</span>
                    </li>
                  </ul>
                  <div
                    :if={@card.ai_result["screens"] not in [nil, []]}
                    id="ai-result-screens"
                    class="flex flex-wrap gap-2"
                  >
                    <figure :for={screen <- @card.ai_result["screens"]} class="w-32 space-y-1">
                      <img
                        :if={screen["url"]}
                        src={screen["url"]}
                        alt={screen["caption"] || "Screenshot"}
                        class="w-full rounded border border-base-300"
                      />
                      <div
                        :if={!screen["url"]}
                        class="aspect-video w-full rounded bg-gradient-to-br from-primary/30 to-secondary/30"
                      />
                      <figcaption
                        :if={screen["caption"]}
                        class="text-[11px] leading-tight text-base-content/60"
                      >
                        {screen["caption"]}
                      </figcaption>
                    </figure>
                  </div>
                  <a
                    :if={@card.ai_result["deploy_url"]}
                    id="ai-result-deploy"
                    href={@card.ai_result["deploy_url"]}
                    target="_blank"
                    rel="noopener"
                    class="inline-flex items-center gap-1 text-xs font-medium text-secondary"
                  >
                    View deployment ↗
                  </a>
                </div>
              </section>
              <section :if={@card.sub_tasks != []} id="sub-tasks" class="space-y-2">
                <div class="flex items-center gap-2">
                  <.section_label>Sub-tasks</.section_label>
                  <span id="sub-tasks-count" class="font-mono text-[10px] text-base-content/60">
                    {@sub_task_progress.done}/{@sub_task_progress.total}
                  </span>
                  <div class="h-1 max-w-[120px] flex-1 overflow-hidden rounded-full bg-base-300">
                    <div
                      class="h-full rounded-full bg-success transition-all"
                      style={"width:#{sub_task_pct(@sub_task_progress)}%"}
                    />
                  </div>
                </div>
                <ul class="space-y-1.5">
                  <li :for={st <- @card.sub_tasks} id={"sub-task-#{st.id}"}>
                    <button
                      type="button"
                      phx-click="toggle_sub_task"
                      phx-value-id={st.id}
                      aria-label={if(st.done, do: "Mark incomplete", else: "Mark complete")}
                      class="flex w-full items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-2 py-1.5 text-left transition-colors hover:border-base-content/20"
                    >
                      <span class={[
                        "flex size-4 shrink-0 items-center justify-center rounded border transition-colors",
                        if(st.done,
                          do: "border-success bg-success text-white",
                          else: "border-base-300"
                        )
                      ]}>
                        <.icon :if={st.done} name="hero-check" class="size-3" />
                      </span>
                      <span class={[
                        "text-sm leading-snug",
                        st.done && "text-base-content/50 line-through"
                      ]}>
                        {st.title}
                      </span>
                    </button>
                  </li>
                </ul>
              </section>
              <section class="space-y-3 border-t border-base-300 pt-4">
                <.section_label>Conversation</.section_label>
                <div
                  :if={@body_loading}
                  id={"#{@id}-conversation-loading"}
                  class="flex justify-center py-4"
                >
                  <span class="loading loading-spinner loading-sm text-base-content/40"></span>
                </div>
                <ol
                  :if={!@body_loading}
                  id={"#{@id}-conversation"}
                  phx-update="stream"
                  class="space-y-4"
                >
                  <li
                    id={"#{@id}-conversation-empty"}
                    class="hidden text-sm text-base-content/50 only:block"
                  >
                    No comments yet
                  </li>
                  <li
                    :for={{dom_id, comment} <- @conversation}
                    id={dom_id}
                    class="timeline-entry flex items-start gap-3"
                    data-actor-type={comment.actor_type}
                  >
                    <.avatar
                      class="timeline-avatar shrink-0"
                      size={28}
                      tint={:role}
                      actor={if(comment.actor_type == :agent, do: :ai, else: :human)}
                      src={comment.user && comment.user.avatar_url}
                      name={comment.user && comment.user.name}
                      email={comment.user && comment.user.email}
                    />
                    <div class="min-w-0 flex-1 space-y-1">
                      <div class="flex items-baseline gap-2">
                        <span class="timeline-author text-[13px] font-semibold">
                          {timeline_author(comment)}
                        </span>
                        <time class="timeline-time font-mono text-[11px] text-base-content/50">
                          {Calendar.strftime(comment.inserted_at, "%b %d, %H:%M")}
                        </time>
                        <span
                          :if={comment.kind in [:question, :changes_requested]}
                          class="font-mono"
                          style={"font-size:9.5px;font-weight:600;letter-spacing:0.04em;color:#{comment_tag_color(comment.kind)};background:oklch(0.96 0.03 75);padding:1px 6px;border-radius:4px;"}
                        >
                          {comment_tag_label(comment.kind)}
                        </span>
                      </div>
                      <div
                        class={[
                          "timeline-comment-body md rounded-lg px-3 py-2 text-sm leading-relaxed",
                          comment.kind not in [:question, :changes_requested] && "bg-base-200/60"
                        ]}
                        style={
                          comment.kind in [:question, :changes_requested] &&
                            "background:oklch(0.96 0.03 75);border:1px solid oklch(0.88 0.06 75);"
                        }
                      >
                        {Relay.Markdown.to_html(comment.body)}
                      </div>
                    </div>
                  </li>
                </ol>
                <.form
                  :if={!@archived}
                  for={@comment_form}
                  id={"#{@id}-comment-form"}
                  phx-change="validate_comment"
                  phx-submit="post_comment"
                >
                  <.boxed_field
                    id={"#{@id}-comment-input"}
                    commit={:form}
                    multiline
                    rows="2"
                    form={@comment_form}
                    field={:body}
                    placeholder="Write a comment…"
                    phx-hook="SubmitOnCmdEnter"
                  />
                  <.button variant="primary" class="btn btn-primary btn-sm">Comment</.button>
                </.form>
              </section>

              <section class="space-y-2 border-t border-base-300 pt-4">
                <.section_label>Activity</.section_label>
                <div
                  :if={@health != :none}
                  id={"#{@id}-activity-health-chip"}
                  class="activity-health-chip flex items-center gap-2"
                  style={"border-radius:7px;padding:7px 10px;#{strip_box_style(@health)}"}
                  data-health={@health}
                >
                  <span style={"width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:#{health_chip_color(@health)};#{if(@health == :live, do: "animation:relaypulse 1.4s ease-in-out infinite;")}"}>
                  </span>
                  <span
                    class="text-[11.5px]"
                    style={"font-family:var(--font-mono);color:#{strip_text_color(@health)};"}
                  >
                    {health_chip_label(@health)}
                  </span>
                </div>
                <div
                  :if={@body_loading}
                  id={"#{@id}-activity-loading"}
                  class="flex justify-center py-3"
                >
                  <span class="loading loading-spinner loading-sm text-base-content/40"></span>
                </div>
                <ol
                  :if={!@body_loading}
                  id={"#{@id}-activity"}
                  phx-update="stream"
                  class="relative space-y-1 pl-[18px]"
                >
                  <li
                    id={"#{@id}-activity-empty"}
                    class="hidden text-sm text-base-content/50 only:block"
                  >
                    No activity yet
                  </li>
                  <li
                    :for={{dom_id, entry} <- @activity}
                    id={dom_id}
                    class="activity-entry relative py-1"
                    data-kind={Relay.Activity.kind(entry)}
                    data-actor-type={entry.actor_type}
                  >
                    <%= if Relay.Activity.kind(entry) == :move do %>
                      <span
                        class="activity-move-chip inline-flex items-center gap-2"
                        style="background:oklch(0.965 0.006 255);border:1px solid oklch(0.90 0.006 255);border-radius:20px;padding:4px 12px;font-size:11.5px;font-family:var(--font-mono);color:oklch(0.50 0.02 255);"
                      >
                        moved
                        <span class="font-semibold" style="color:oklch(0.40 0.02 255);">
                          {entry.meta["from_stage"]} → {entry.meta["to_stage"]}
                        </span>
                        · {relative_time(entry.inserted_at)}
                      </span>
                    <% else %>
                      <span
                        class="activity-entry-dot absolute"
                        style={"left:-16.5px;top:7px;width:7px;height:7px;border-radius:50%;background:#{entry_dot_color(entry)};box-shadow:0 0 0 2.5px var(--color-base-100);"}
                      >
                      </span>
                      <div class="flex items-baseline gap-1.5">
                        <span class="timeline-activity-phrase min-w-0 text-[13px] leading-snug text-base-content/70">
                          {entry_text(entry)}
                        </span>
                        <time class="timeline-time ml-auto shrink-0 font-mono text-[11px] text-base-content/45">
                          {relative_time(entry.inserted_at)}
                        </time>
                      </div>
                    <% end %>
                  </li>
                </ol>
              </section>
            </div>

            <div
              id={"#{@id}-rail"}
              class="flex w-full shrink-0 flex-col gap-5 border-t border-base-300 bg-base-200/30 p-5 text-sm drawer:w-[220px] drawer:overflow-y-auto drawer:border-l drawer:border-t-0"
            >
              <%!-- STAGE: chip + Move to… + Archive --%>
              <div class="rail-section flex flex-col gap-2">
                <.section_label>Stage</.section_label>
                <div class="rail-stage flex flex-wrap items-center gap-2">
                  <span class={[
                    "badge badge-sm font-medium",
                    if(@stage_owner == :human, do: "badge-primary", else: "badge-secondary")
                  ]}>
                    {@stage_name}
                  </span>
                  <div :if={@stages != [] and !@archived} id={"#{@id}-move"} class="dropdown">
                    <div
                      tabindex="0"
                      role="button"
                      id={"#{@id}-move-button"}
                      class="btn btn-ghost btn-xs"
                    >
                      Move to… <.icon name="hero-chevron-down" class="size-3" />
                    </div>
                    <ul
                      tabindex="0"
                      class="dropdown-content menu z-50 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
                    >
                      <li :for={stage <- @stages}>
                        <button
                          type="button"
                          id={"#{@id}-move-to-#{stage.id}"}
                          phx-click="move_card"
                          phx-value-ref={@ref}
                          phx-value-stage_id={stage.id}
                        >
                          {stage.name}
                        </button>
                      </li>
                    </ul>
                  </div>
                  <button
                    :if={!@archived}
                    type="button"
                    id="archive-card-button"
                    phx-click="archive_card"
                    phx-value-ref={@ref}
                    data-confirm="Archive this card? You can restore it from Archived."
                    class="btn btn-ghost btn-xs text-base-content/60"
                  >
                    <.icon name="hero-archive-box" class="size-3.5" /> Archive
                  </button>
                </div>
              </div>

              <%!-- OWNERS: avatars + names, active owner ringed (ACTIVE WORKER merged here) --%>
              <div class="rail-section flex flex-col gap-2">
                <.section_label>Owners</.section_label>
                <div class="rail-owners space-y-2">
                  <div
                    :for={owner <- @card.owners}
                    class={[
                      "rail-owner flex items-center gap-2 rounded-md px-1.5 py-1",
                      active_owner?(owner, @active_owner) &&
                        if(owner.actor_type == :agent,
                          do: "rail-owner-active ring-2 ring-secondary/60",
                          else: "rail-owner-active ring-2 ring-primary/60"
                        )
                    ]}
                    data-actor-type={owner.actor_type}
                    data-active={to_string(active_owner?(owner, @active_owner))}
                  >
                    <span class="text-sm">{owner_name(owner)}</span>
                    <button
                      :if={!@archived and owner.actor_type == :agent}
                      type="button"
                      id={"#{@id}-take-over"}
                      class="rail-take-over btn btn-primary btn-xs"
                      phx-click="take_over"
                    >
                      Take over
                    </button>
                    <button
                      :if={!@archived}
                      type="button"
                      id={"#{@id}-remove-owner-#{owner_dom_suffix(owner)}"}
                      class="btn btn-ghost btn-xs btn-square"
                      phx-click="remove_owner"
                      phx-value-actor_type={owner.actor_type}
                      phx-value-user_id={owner.user_id}
                      aria-label={"Remove #{owner_name(owner)} as owner"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </div>
                  <span :if={@card.owners == []} class="text-base-content/50">None</span>
                  <button
                    :if={!@archived}
                    type="button"
                    id={"#{@id}-reassign-toggle"}
                    class="self-start"
                    phx-click="toggle_reassign"
                    style="background:transparent;border:none;color:oklch(0.50 0.13 250);font-size:12px;font-weight:600;padding:2px 0;cursor:pointer;"
                  >
                    {if @reassign_open, do: "Done", else: "Reassign"}
                  </button>
                  <div
                    :if={!@archived and @reassign_open}
                    id={"#{@id}-reassign-picker"}
                    style="display:flex;flex-direction:column;gap:4px;background:oklch(1 0 0);border:1px solid oklch(0.92 0.006 255);border-radius:9px;padding:7px;"
                  >
                    <button
                      :for={m <- reassignable_members(@members)}
                      type="button"
                      id={"#{@id}-assign-user-#{m.user_id}"}
                      phx-click="add_owner"
                      phx-value-actor_type="user"
                      phx-value-user_id={m.user_id}
                      style="display:flex;align-items:center;gap:8px;background:transparent;border:none;border-radius:7px;padding:5px 6px;cursor:pointer;text-align:left;"
                    >
                      <.avatar
                        size={22}
                        tint={:identity}
                        src={m.user && m.user.avatar_url}
                        name={m.user && m.user.name}
                        email={m.user && m.user.email}
                      />
                      <span style="font-size:12.5px;color:oklch(0.34 0.02 255);flex:1;">
                        {user_name(m.user)}
                      </span>
                      <span
                        :if={user_owner?(@card, m.user_id)}
                        style="font-size:11px;color:oklch(0.50 0.13 250);"
                      >
                        ✓
                      </span>
                    </button>
                    <button
                      type="button"
                      id={"#{@id}-assign-ai"}
                      phx-click="add_owner"
                      phx-value-actor_type="agent"
                      style="display:flex;align-items:center;gap:8px;background:transparent;border:none;border-radius:7px;padding:5px 6px;cursor:pointer;text-align:left;"
                    >
                      <.avatar size={22} actor={:ai} />
                      <span style="font-size:12.5px;color:oklch(0.34 0.02 255);flex:1;">
                        Relay AI
                      </span>
                      <span
                        :if={agent_owner?(@card)}
                        style="font-size:11px;color:oklch(0.50 0.13 250);"
                      >
                        ✓
                      </span>
                    </button>
                  </div>
                </div>
              </div>

              <div class="rail-section flex flex-col gap-2">
                <.section_label>Status</.section_label>
                <div class="rail-status">
                  <.status_badge status={@card.status} />
                </div>
              </div>

              <%!-- FLOW inserts here when flow-overrides lands — not built in this pass. --%>

              <%!-- LINKS: Branch chip + PR link under one label; nothing when both absent --%>
              <div :if={@card.branch || @card.pr_url} class="rail-section flex flex-col gap-2">
                <.section_label>Links</.section_label>
                <div class="rail-links flex flex-wrap items-center gap-2">
                  <span
                    :if={@card.branch}
                    id="card-branch"
                    class="badge badge-ghost badge-sm gap-1 font-mono"
                  >
                    <.icon name="hero-share" class="size-3" />
                    {@card.branch}
                  </span>
                  <.link
                    :if={@card.pr_url}
                    id="card-pr"
                    href={@card.pr_url}
                    target="_blank"
                    class="badge badge-ghost badge-sm gap-1 font-mono"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3" /> Review PR ↗
                  </.link>
                </div>
              </div>

              <%!-- TAGS --%>
              <div class="rail-section flex flex-col gap-2">
                <.section_label>Tags</.section_label>
                <div class="rail-tags">
                  <span :if={@card.tag} class="badge badge-ghost badge-sm">#{@card.tag}</span>
                  <span :if={!@card.tag} class="text-base-content/50">None</span>
                </div>
              </div>

              <%!-- DATES --%>
              <div class="rail-section flex flex-col gap-2">
                <.section_label>Dates</.section_label>
                <div class="rail-dates space-y-0.5 font-mono text-xs text-base-content/70">
                  <div>Created {Calendar.strftime(@card.inserted_at, "%b %d, %Y")}</div>
                  <div>Updated {Calendar.strftime(@card.updated_at, "%b %d, %Y")}</div>
                </div>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  # SUB-TASKS progress bar width; an empty list is 0% (never divides by zero).
  defp sub_task_pct(%{total: 0}), do: 0
  defp sub_task_pct(%{done: done, total: total}), do: round(done * 100 / total)

  # Working progress is derived from the card's sub-tasks (RLY-37): done/total as
  # a percentage, or nil when there are none — a working card with no checklist
  # shows no bar and a plain "working" label. Real cards always carry a loaded
  # sub_tasks list (card_preloads/0); the fallback clause tolerates bare test maps.
  defp board_card_progress(%{sub_tasks: sub_tasks}) when is_list(sub_tasks) do
    case Cards.sub_task_progress(%{sub_tasks: sub_tasks}) do
      %{total: 0} -> nil
      %{done: done, total: total} -> round(done * 100 / total)
    end
  end

  defp board_card_progress(_card), do: nil

  defp owner_name(%{actor_type: :agent}), do: "Relay AI"
  defp owner_name(%{actor_type: :user, user: user}), do: user.name || user.email

  # RLY-43: the active owner is the baton-holder — ringed inside OWNERS (the old
  # standalone ACTIVE WORKER row is gone). Agent owner is active when the baton is AI's;
  # a user owner when it's a human's.
  defp active_owner?(%{actor_type: :agent}, :ai), do: true
  defp active_owner?(%{actor_type: :user}, :human), do: true
  defp active_owner?(_owner, _active_owner), do: false

  defp agent_owner?(card), do: Enum.any?(card.owners, &(&1.actor_type == :agent))

  defp user_owner?(card, user_id) do
    Enum.any?(card.owners, &(&1.actor_type == :user and &1.user_id == user_id))
  end

  # RLY-32: only resolved members (with a user) can own a card; invited
  # (user-less) rows are skipped in the reassign picker.
  defp reassignable_members(members), do: Enum.filter(members, & &1.user_id)

  defp owner_dom_suffix(%{actor_type: :agent}), do: "agent"
  defp owner_dom_suffix(%{actor_type: :user, user_id: user_id}), do: "user-#{user_id}"

  defp timeline_author(%{actor_type: :agent}), do: "Relay AI"
  defp timeline_author(%{actor_type: :user, user: user}), do: user.name || user.email

  defp comment_tag_label(:question), do: "QUESTION"
  defp comment_tag_label(:changes_requested), do: "CHANGES REQUESTED"

  defp comment_tag_color(:question), do: "oklch(0.52 0.11 65)"
  defp comment_tag_color(:changes_requested), do: "oklch(0.55 0.13 65)"

  defp activity_phrase(%Activity{type: :created}), do: "created this card"

  defp activity_phrase(%Activity{type: :moved, meta: meta}), do: "moved #{meta["from_stage"]} → #{meta["to_stage"]}"

  defp activity_phrase(%Activity{type: :status_changed, meta: meta}), do: "set status to #{meta["to_status"]}"

  defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "added"} = meta}),
    do: "added #{meta["owner"]} as owner"

  defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "removed"} = meta}),
    do: "removed #{meta["owner"]} as owner"

  defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "set", "owners" => []}}),
    do: "cleared the owners"

  defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "set", "owners" => owners}}),
    do: "set owners to #{Enum.join(owners, ", ")}"

  defp activity_phrase(%Activity{type: :commented}), do: "commented"

  defp activity_phrase(%Activity{type: :approved, meta: %{"from_stage" => same, "to_stage" => same}}),
    do: "approved this card as done"

  defp activity_phrase(%Activity{type: :approved, meta: meta}), do: "approved #{meta["from_stage"]} → #{meta["to_stage"]}"

  defp activity_phrase(%Activity{type: :rejected, meta: meta}), do: "requested changes — sent back to #{meta["to_stage"]}"

  defp activity_phrase(%Activity{type: :needs_input}), do: "asked for input"

  defp activity_phrase(%Activity{type: :input_answered}), do: "answered the question"
  defp activity_phrase(%Activity{type: :archived}), do: "archived this card"
  defp activity_phrase(%Activity{type: :unarchived}), do: "restored this card"
  defp activity_phrase(%Activity{type: :action}), do: "agent activity"
  defp activity_phrase(%Activity{type: :failure}), do: "the agent stopped"

  # The one-line hint under READY FOR YOUR REVIEW (MMF 15): a gated stage
  # offers the approve/send-back pair; an ungated one has no drawer decision
  # button (RLY-37) — move it forward by drag or Move to… when ready.
  defp review_hint(nil), do: "Relay AI finished this. Drag it or use Move to… when you're ready."

  defp review_hint(_gate), do: "Relay AI finished this. Approve to move it forward, or send it back with a note."

  # The panel's aging hint ("waiting 3h"), derived from Card.blocked_since —
  # the mockup's small amber mono text beside the panel label.
  defp waiting_label(%DateTime{} = blocked_since) do
    minutes = max(DateTime.diff(DateTime.utc_now(), blocked_since, :minute), 0)

    cond do
      minutes < 60 -> "waiting #{minutes}m"
      minutes < 1440 -> "waiting #{div(minutes, 60)}h"
      true -> "waiting #{div(minutes, 1440)}d"
    end
  end

  # RLY-71 — the text-box value for the current step: the stored answer when it's a free-typed
  # custom string, blank when it's one of the presented options (or unanswered).
  defp stepper_custom_text(values, step, options) do
    case Map.get(values, step) do
      nil -> ""
      value -> if value in options, do: "", else: value
    end
  end

  @doc """
  Renders one stage as the mockup's rounded stage card
  (`docs/designs/Relay Board.dc.html`): a header (owner square swatch, name,
  count, and a `+` add button) above a row of side-by-side lanes. The main
  "In progress" lane is 240px; each Review/Done sub-lane is 178px, tinted
  (amber/green) and split off by a vertical divider. The stage card grows to
  fit its lanes.

  `cards` accepts a LiveView stream (preferred) or a list of
  `{dom_id, card}` tuples; each card needs `title`, `tag`, `ref_number`,
  `status`, a loaded `owners` list, and (for the derived working-progress
  bar/label) a loaded `sub_tasks` list. Each lane's `phx-update="stream"`
  list (`.stage-cards`) sits inside a `.stage-drop` zone carrying
  `data-stage-id` (the main stage id for the ongoing lane, each child stage
  id for the sub-lanes) — `.stage-drop` owns the DnD drop contract,
  `.stage-cards` is purely the stream list (RLY-116). The empty-state
  placeholder is CSS-hidden (`only:block`) once the lane has cards.

  The compose control emits events handled by the parent LiveView:
  `"compose"` (with `phx-value-stage-id`) to open the composer,
  `"create_card"` (form params `card[title]` plus hidden `stage_id`) on
  submit, and `"cancel_compose"` on Cancel, Escape, or click-away.

  When `collapsed` (MMF 12c), the stage renders instead as the mockup's 44px dashed
  vertical strip — owner swatch, rotated name, total count — which remains a
  `.stage-drop[data-stage-id]` drop zone and emits `"expand_stage"`
  (`phx-value-stage-id`) on click. The expanded header's stage name is itself the
  collapse control (RLY-145): clicking it emits `"collapse_stage"`
  (`phx-value-stage-id`), completing the strip's expand/collapse toggle on every stage.

  ## Examples

      <.stage_column id="stage-col-1" name="Backlog" type={:queue} stage_id={1} />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :type, :atom, values: [:queue, :work, :planning, :review, :done], required: true
  attr :ai_enabled, :boolean, default: false
  attr :count, :integer, default: nil, doc: "the number of cards in the main lane; count hidden when nil"

  attr :wip_limit, :integer,
    default: nil,
    doc: "the stage's optional WIP limit (MMF 11); the header chip is hidden when nil"

  attr :category, :atom,
    values: [:unstarted, :planning, :in_progress, :complete, nil],
    default: nil,
    doc: "the stage's category, forwarded to its cards for the green accent"

  attr :stage_id, :any, default: nil, doc: "the stage's database id, echoed back in compose events"
  attr :board_key, :string, default: "RLY", doc: "the board's ref prefix, e.g. RLY in RLY-3"
  attr :cards, :any, default: [], doc: "a LiveView stream or a list of {dom_id, card} tuples"
  attr :composing, :boolean, default: false
  attr :compose_form, :any, default: nil, doc: "a Phoenix.HTML.Form for card[title]; required when composing"

  attr :composable, :boolean,
    default: true,
    doc:
      "RLY-126 — false hides the header compose + (embed mode: the native New-card " <>
        "sheet is the single create path in the app)"

  attr :sublanes, :list,
    default: [],
    doc:
      "the stage's Review/Done child lanes, each a %{id, name, lane, owner, count, cards} " <>
        "with an optional collapsed: true to render the lane as its 34px strip (MMF 12c)"

  attr :collapsed, :boolean,
    default: false,
    doc: "render the whole stage as the mockup's 44px dashed strip (still a drop target)"

  attr :main_collapsed, :boolean,
    default: false,
    doc: "render the main 'In progress' lane as a 44px strip (RLY-1 item 3)"

  attr :read_only, :boolean, default: false, doc: "hide mutating affordances when true"

  attr :terminal, :boolean, default: false, doc: "true when this is the board's terminal (Done) stage"

  attr :revealed, :integer,
    default: nil,
    doc:
      "RLY-53 — how many terminal Done cards are shown; the 'Show N more' button appears " <>
        "when @count exceeds it. nil (non-terminal) hides the button."

  attr :page_size, :integer,
    default: 8,
    doc:
      "RLY-53 — the reveal batch size, capping the button's count " <>
        "(keep in sync with BoardLive @done_page_size)"

  attr :questions, :map, default: %{}, doc: "card_id => latest needs_input question, for previews"

  attr :health, :map,
    default: %{},
    doc: "RLY-112 card_id => %{state:, entry:}, from BoardLive's :health_by_card assign"

  def stage_column(assigns) do
    sublanes = Enum.map(assigns.sublanes, &Map.put_new(&1, :collapsed, false))
    total_count = (assigns.count || 0) + Enum.sum(Enum.map(sublanes, & &1.count))

    assigns =
      assigns
      |> assign(:sublanes, sublanes)
      |> assign(:labeled, sublanes != [])
      |> assign(:stage_width, 240 + Enum.sum(Enum.map(sublanes, &sublane_width/1)))
      |> assign(:total_count, total_count)
      |> assign(:wip_state, wip_state(total_count, assigns.wip_limit))
      |> assign(:compose_cta, if(assigns.ai_enabled, do: "Hand to AI", else: "Add"))
      |> assign(
        :compose_placeholder,
        if(assigns.ai_enabled,
          do: "Describe work to hand to the AI…",
          else: "Add work to #{assigns.name}…"
        )
      )

    ~H"""
    <%= if @collapsed do %>
      <section
        id={"stage-strip-#{@stage_id}"}
        class="stage-column stage-strip stage-drop"
        data-stage-id={@stage_id}
        phx-click="expand_stage"
        phx-value-stage-id={@stage_id}
        aria-label={"Expand stage #{@name}"}
        style="flex:0 0 auto;width:44px;display:flex;flex-direction:column;align-items:center;gap:10px;padding:12px 0;border-radius:11px;background:oklch(0.965 0.004 255);border:1px dashed oklch(0.90 0.006 255);cursor:pointer;box-sizing:border-box;"
      >
        <.stage_type_icon type={@type} />
        <h3
          class="stage-strip-name"
          style="writing-mode:vertical-rl;transform:rotate(180deg);font-size:12px;font-weight:600;letter-spacing:0.01em;color:oklch(0.52 0.02 255);white-space:nowrap;"
        >
          {@name}
        </h3>
        <span
          class="stage-count"
          style="font-size:10px;font-family:var(--font-mono);color:oklch(0.65 0.02 255);"
        >
          {@total_count}
        </span>
      </section>
    <% else %>
      <section
        id={@id}
        class="stage-column"
        data-stage-id={@stage_id}
        data-wip={@wip_state}
        style={"flex:0 0 auto;width:#{@stage_width}px;display:flex;flex-direction:column;height:100%;background:var(--color-base-100);border:1px solid #{wip_border_color(@wip_state)};border-radius:14px;overflow:hidden;box-shadow:0 1px 3px oklch(0.5 0.02 255/0.06);"}
      >
        <header style="display:flex;align-items:center;gap:8px;padding:15px 15px 12px 15px;flex:0 0 auto;border-bottom:1px solid var(--color-base-300);">
          <.stage_type_icon type={@type} />
          <h3
            id={"#{@id}-name"}
            class="stage-name"
            phx-click="collapse_stage"
            phx-value-stage-id={@stage_id}
            aria-label={"Collapse stage #{@name}"}
            style="font-size:13px;font-weight:600;letter-spacing:-0.01em;color:var(--color-base-content);cursor:pointer;"
          >
            {@name}
          </h3>
          <span
            :if={@ai_enabled and @category != :complete}
            id={"#{@id}-ai-listening"}
            title="Relay AI is listening on this stage"
            style="display:inline-flex;align-items:center;gap:4px;font-size:9px;font-weight:600;letter-spacing:0.06em;font-family:var(--font-mono);background:oklch(0.95 0.03 292);color:oklch(0.46 0.14 292);padding:2px 6px;border-radius:5px;flex:0 0 auto;"
          >
            <span style="width:10px;height:10px;border-radius:50%;background:oklch(0.56 0.16 292);display:flex;align-items:center;justify-content:center;flex:0 0 auto;">
              <span style="width:4px;height:4px;border-radius:50%;border:1px solid oklch(1 0 0);"></span>
            </span>AI
          </span>
          <span
            :if={@count}
            class="stage-count"
            style="font-size:10.5px;font-family:var(--font-mono);color:oklch(0.68 0.02 255);"
          >
            {@count}
          </span>
          <span
            :if={@wip_limit}
            class="stage-wip"
            data-over={@total_count > @wip_limit}
            data-wip={@wip_state}
            style={"font-size:11px;font-weight:600;font-family:var(--font-mono);padding:2px 7px;border-radius:5px;flex:0 0 auto;#{wip_chip_colors(@wip_state)}"}
          >
            wip {@total_count}/{@wip_limit}
          </span>
          <span style="flex:1;"></span>
          <button
            :if={@composable and !@composing and !@read_only}
            type="button"
            id={"#{@id}-new-card"}
            class="stage-compose"
            phx-click="compose"
            phx-value-stage-id={@stage_id}
            title="Add work"
            aria-label="New card"
            style="min-width:44px;min-height:44px;border-radius:6px;border:1px solid var(--color-base-300);background:var(--color-base-100);color:oklch(0.45 0.02 255);font-size:15px;line-height:1;display:flex;align-items:center;justify-content:center;padding:0;flex:0 0 auto;"
          >
            +
          </button>
        </header>
        <div class="stage-lanes" style="display:flex;gap:0;flex:1;min-height:0;">
          <%!-- main / ongoing lane (RLY-1 item 3: collapsible; item 7: full-height drop zone) --%>
          <%= if @main_collapsed do %>
            <div
              id={"#{@id}-main-strip"}
              class="main-lane-strip stage-drop"
              data-stage-id={@stage_id}
              phx-click="toggle_collapse"
              phx-value-stage-id={@stage_id}
              aria-label="Expand In progress lane"
              style="flex:0 0 44px;width:44px;display:flex;flex-direction:column;align-items:center;gap:10px;padding:12px 0;box-sizing:border-box;cursor:pointer;border-right:1px solid var(--color-base-300);"
            >
              <span style={"writing-mode:vertical-rl;transform:rotate(180deg);font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(:ongoing)};white-space:nowrap;"}>
                In progress
              </span>
              <span style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(:ongoing)};opacity:0.7;flex:0 0 auto;"}>
                {@count}
              </span>
            </div>
          <% else %>
            <div
              class="stage-main-lane"
              style="flex:0 0 240px;width:240px;min-width:0;display:flex;flex-direction:column;box-sizing:border-box;"
            >
              <div
                :if={@labeled}
                id={"#{@id}-main-lane-header"}
                phx-click="toggle_collapse"
                phx-value-stage-id={@stage_id}
                aria-label="Collapse In progress lane"
                style="display:flex;align-items:center;gap:6px;padding:11px 15px 7px 15px;flex:0 0 auto;cursor:pointer;"
              >
                <span style={"font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(:ongoing)};"}>
                  In progress
                </span>
                <span style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(:ongoing)};opacity:0.7;"}>
                  {@count}
                </span>
              </div>
              <div
                id={"#{@id}-scroll"}
                style={"flex:1;min-height:0;overflow-y:auto;overflow-x:hidden;display:flex;flex-direction:column;gap:8px;padding:#{if(@labeled, do: "0", else: "13px")} 13px 13px 15px;"}
              >
                <div
                  :if={@composing}
                  id={"#{@id}-composer"}
                  phx-click-away="cancel_compose"
                  style="background:oklch(1 0 0);border:1px solid oklch(0.60 0.14 250);border-radius:9px;padding:9px;box-shadow:0 2px 8px oklch(0.55 0.05 255/0.10);"
                >
                  <.form
                    for={@compose_form}
                    id={"#{@id}-compose-form"}
                    phx-change="validate_card"
                    phx-submit="create_card"
                    class="flex flex-col gap-2"
                  >
                    <input type="hidden" name="stage_id" value={@stage_id} />
                    <textarea
                      id={"#{@id}-compose-title"}
                      name="card[title]"
                      rows="2"
                      placeholder={@compose_placeholder}
                      autofocus
                      autocomplete="off"
                      phx-hook="SubmitOnEnter"
                      phx-keydown="cancel_compose"
                      phx-key="escape"
                      class="w-full resize-none border-none bg-transparent p-0 text-[13px] leading-[1.4] text-base-content outline-none focus:outline-none"
                    >{Phoenix.HTML.Form.normalize_value("textarea", @compose_form[:title].value)}</textarea>
                    <div class="flex items-center gap-1.5">
                      <button
                        type="submit"
                        id={"#{@id}-compose-submit"}
                        class="btn btn-xs min-h-[44px] border-none font-semibold text-white"
                        style="background:oklch(0.60 0.14 250);"
                      >
                        {@compose_cta}
                      </button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs min-h-[44px]"
                        style="color:oklch(0.55 0.02 255);"
                        phx-click="cancel_compose"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                </div>
                <div
                  id={"#{@id}-drop"}
                  class="stage-drop"
                  data-stage-id={@stage_id}
                  style="flex:1 1 auto;min-height:100%;display:flex;flex-direction:column;gap:8px;"
                >
                  <div
                    id={"#{@id}-cards"}
                    phx-update={is_struct(@cards, Phoenix.LiveView.LiveStream) && "stream"}
                    class="stage-cards"
                    style="flex:0 0 auto;display:flex;flex-direction:column;gap:8px;"
                  >
                    <div
                      id={"#{@id}-empty"}
                      class="stage-empty hidden only:block"
                      style="border:1px dashed var(--color-base-300);border-radius:8px;padding:18px 8px;text-align:center;font-size:11px;font-family:var(--font-mono);color:oklch(0.68 0.02 255);"
                    >
                      No cards yet
                    </div>
                    <.board_card
                      :for={{dom_id, card} <- @cards}
                      {card_log_attrs(@health, card.id)}
                      id={dom_id}
                      title={card.title}
                      tag={card.tag}
                      ref={"#{@board_key}-#{card.ref_number}"}
                      status={card.status}
                      stage_type={@type}
                      done={@terminal and card.status == :ready}
                      question={Map.get(@questions, card.id)}
                      progress={board_card_progress(card)}
                      owners={card.owners}
                      active_owner={Cards.active_owner_type(card)}
                      lane={:main}
                      category={@category}
                    />
                  </div>
                  <%!--
                    RLY-116 — the .stage-drop wrapper owns the droppable region: it keeps the
                    min-height:100% stretch so a column's empty space stays a drop target
                    (RLY-1), while the .stage-cards list above is natural-height so this
                    button flows directly after the last card (reversing RLY-53's pinned
                    footer). The button must stay OUTSIDE the -cards div: that is a
                    phx-update="stream" container and may only hold stream items.
                  --%>
                  <button
                    :if={(@terminal and @revealed) && @count > @revealed}
                    type="button"
                    id={"#{@id}-show-more-done"}
                    phx-click="show_more_done"
                    phx-value-stage-id={@stage_id}
                    class="stage-show-more"
                    style="flex:0 0 auto;padding:8px 10px;border:1px solid var(--color-base-300);border-radius:8px;background:var(--color-base-100);color:oklch(0.52 0.02 255);font-size:11px;font-weight:600;letter-spacing:0.01em;text-align:center;cursor:pointer;"
                  >
                    Show
                    <span style="font-family:var(--font-mono);">
                      {min(@page_size, @count - @revealed)}
                    </span>
                    more
                  </button>
                </div>
              </div>
            </div>
          <% end %>
          <%!-- Review / Done sub-lanes, side by side; empty ones collapse to 34px strips --%>
          <%= for sub <- @sublanes do %>
            <div
              :if={sub.collapsed}
              id={"sublane-#{sub.id}-strip"}
              class="sublane-strip stage-drop"
              data-stage-id={sub.id}
              phx-click="toggle_collapse"
              phx-value-stage-id={sub.id}
              aria-label={"Expand #{sub.name} lane"}
              style={"flex:0 0 34px;width:34px;display:flex;flex-direction:column;align-items:center;gap:9px;padding:12px 0;box-sizing:border-box;background:#{lane_tint(sub.lane)};border-left:1px solid #{lane_divider(sub.lane)};cursor:pointer;"}
            >
              <span
                class="sublane-strip-dot"
                style={"width:6px;height:6px;border-radius:50%;background:#{lane_color(sub.lane)};opacity:0.6;flex:0 0 auto;"}
              >
              </span>
              <span
                class="sublane-strip-name"
                style={"writing-mode:vertical-rl;transform:rotate(180deg);font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(sub.lane)};white-space:nowrap;"}
              >
                {sub.name}
              </span>
              <span
                class="sublane-strip-count"
                style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(sub.lane)};opacity:0.7;flex:0 0 auto;"}
              >
                {sub.count}
              </span>
            </div>
            <div
              :if={!sub.collapsed}
              id={"sublane-#{sub.id}"}
              class="sublane"
              style={"flex:0 0 178px;width:178px;min-width:0;display:flex;flex-direction:column;box-sizing:border-box;background:#{lane_tint(sub.lane)};border-left:1px solid #{lane_divider(sub.lane)};"}
            >
              <div
                id={"sublane-#{sub.id}-header"}
                phx-click="toggle_collapse"
                phx-value-stage-id={sub.id}
                aria-label={"Collapse #{sub.name} lane"}
                style="display:flex;align-items:center;gap:6px;padding:11px 13px 7px 13px;flex:0 0 auto;cursor:pointer;"
              >
                <span style={"font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(sub.lane)};"}>
                  {sub.name}
                </span>
                <span style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(sub.lane)};opacity:0.7;"}>
                  {sub.count}
                </span>
              </div>
              <div
                id={"sublane-#{sub.id}-cards"}
                phx-update="stream"
                data-stage-id={sub.id}
                class="stage-cards stage-drop"
                style="flex:1;min-height:0;overflow-y:auto;overflow-x:hidden;display:flex;flex-direction:column;gap:8px;padding:0 13px 13px 13px;"
              >
                <div
                  id={"sublane-#{sub.id}-empty"}
                  class="stage-empty hidden only:block"
                  style="border:1px dashed var(--color-base-300);border-radius:8px;padding:14px 8px;text-align:center;font-size:11px;font-family:var(--font-mono);color:oklch(0.70 0.02 255);"
                >
                  Empty
                </div>
                <.board_card
                  :for={{dom_id, card} <- sub.cards}
                  {card_log_attrs(@health, card.id)}
                  id={dom_id}
                  title={card.title}
                  tag={card.tag}
                  ref={"#{@board_key}-#{card.ref_number}"}
                  status={card.status}
                  stage_type={sub.lane}
                  done={false}
                  question={Map.get(@questions, card.id)}
                  progress={board_card_progress(card)}
                  owners={card.owners}
                  active_owner={Cards.active_owner_type(card)}
                  lane={sub.lane}
                  category={@category}
                />
              </div>
            </div>
          <% end %>
        </div>
      </section>
    <% end %>
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

  defp field_blank?(nil), do: true
  defp field_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp field_blank?(_), do: false

  attr :id, :string, required: true
  attr :cancel_event, :string, required: true
  attr :hint, :string, default: "Enter · Esc"
  attr :hidden, :boolean, default: false

  defp commit_pill(assigns) do
    ~H"""
    <div id={"#{@id}-pill"} class={["commit-pill", @hidden && "hidden"]}>
      <button type="submit" id={"#{@id}-save"} class="commit-pill-save" aria-label="Save">
        <.icon name="hero-check" class="size-3.5" />
      </button>
      <button
        type="button"
        id={"#{@id}-cancel"}
        class="commit-pill-cancel"
        phx-click={@cancel_event}
        aria-label="Cancel"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
      <span class="commit-pill-hint">{@hint}</span>
    </div>
    """
  end

  @doc """
  A plain-text field for primary content that *is* the thing (card title, stage
  name). Reads as text with a quiet hover tint; editing swaps in a single-line
  input with the blue focus ring and a floating ✓/✕ commit pill (Enter saves,
  Esc reverts). The parent LiveView owns `editing` and `form`; the `CommitField`
  JS hook owns focus/caret-at-end and the keyboard chord.
  """
  attr :id, :string, required: true
  attr :editing, :boolean, default: false
  attr :value, :string, default: nil
  attr :placeholder, :string, default: "Untitled"
  attr :form, :any, default: nil
  attr :field, :atom, default: nil
  attr :edit_event, :string, required: true
  attr :save_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :edit_attrs, :map, default: %{}
  attr :read_class, :any, default: nil
  attr :input_class, :any, default: nil
  slot :hidden

  def inline_field(assigns) do
    ~H"""
    <div id={@id} class="inline-field">
      <div
        :if={!@editing}
        id={"#{@id}-display"}
        role="button"
        tabindex="0"
        phx-click={@edit_event}
        phx-hook="CommitField"
        data-field-role="display"
        class={["inline-field-rest", @read_class]}
        {@edit_attrs}
      >
        <span :if={!field_blank?(@value)} class="whitespace-pre-wrap">{@value}</span>
        <span :if={field_blank?(@value)} class="font-normal italic text-base-content/50">
          {@placeholder}
        </span>
      </div>
      <.form
        :if={@editing}
        for={@form}
        id={"#{@id}-form"}
        phx-submit={@save_event}
        phx-click-away={@cancel_event}
        class="commit-field-form"
      >
        {render_slot(@hidden)}
        <.input
          field={@form[@field]}
          type="text"
          id={"#{@id}-input"}
          class={["commit-field-input", @input_class]}
          phx-hook="CommitField"
          data-field-role="edit"
          data-commit="enter"
          data-autofocus="true"
          data-cancel-id={"#{@id}-cancel"}
        />
        <.commit_pill id={@id} cancel_event={@cancel_event} hint="Enter · Esc" />
      </.form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :accent, :atom, default: nil
  attr :toggle?, :boolean, default: false
  attr :expanded, :boolean, default: false
  attr :value, :string, default: nil
  attr :toggle_event, :string, default: nil
  attr :edit_event, :string, default: nil

  defp field_header(assigns) do
    ~H"""
    <div class="commit-field-header">
      <span :if={@accent} class={["commit-field-accent", accent_bar_class(@accent)]}></span>
      <.section_label>{@label}</.section_label>
      <span class="flex-1"></span>
      <button
        :if={@toggle?}
        type="button"
        id={"#{@id}-toggle"}
        phx-click={if(field_blank?(@value), do: @edit_event, else: @toggle_event)}
        class="commit-field-toggle"
      >
        {toggle_label(@expanded, @value)}
      </button>
    </div>
    """
  end

  defp accent_bar_class(:primary), do: "bg-primary"
  defp accent_bar_class(:secondary), do: "bg-secondary"
  defp accent_bar_class(:accent), do: "bg-accent"

  defp toggle_label(true, _value), do: "Collapse"
  defp toggle_label(false, value), do: if(field_blank?(value), do: "Add", else: "Expand")

  @doc """
  A form field you fill in. Always visibly a box; single-line and multi-line share
  identical styling. `commit={:form}` renders only a styled input bound to
  `@form[@field]` (the parent form's button submits). `commit={:self}` owns its own
  commit via ⌘/Ctrl+Enter or ✓, reverting on Esc/✕: with `edit_event` set it is a
  server-toggled rest↔edit field (markdown renders at rest); without `edit_event` it
  is always editable and the pill appears once dirty (board name/slug).
  """
  attr :id, :string, required: true
  attr :commit, :atom, values: [:self, :form], default: :self
  attr :value, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :multiline, :boolean, default: false
  attr :markdown, :boolean, default: false
  attr :rows, :string, default: "6"
  attr :editing, :boolean, default: false
  attr :form, :any, default: nil
  attr :field, :atom, default: nil
  attr :edit_event, :string, default: nil
  attr :save_event, :string, default: nil
  attr :cancel_event, :string, default: nil
  attr :edit_attrs, :map, default: %{}
  attr :prefix, :string, default: nil
  attr :input_class, :any, default: nil
  attr :label, :string, default: nil, doc: "eyebrow header text; when set the field renders its own header row"

  attr :accent, :atom,
    values: [:primary, :secondary, :accent, nil],
    default: nil,
    doc: "left accent bar color"

  attr :collapsible, :boolean,
    default: false,
    doc: "collapse content into a faded preview by default"

  attr :expanded, :boolean,
    default: false,
    doc: "server-owned: show the full read instead of the preview"

  attr :toggle_event, :string,
    default: nil,
    doc: "event the header toggle / Show more fires to flip expanded"

  attr :rest, :global, include: ~w(autocomplete)
  slot :hidden

  def boxed_field(%{commit: :form} = assigns) do
    ~H"""
    <.input
      field={@form[@field]}
      type={if(@multiline, do: "textarea", else: "text")}
      id={@id}
      rows={@multiline && @rows}
      placeholder={@placeholder}
      class={["commit-field-input", @input_class]}
      {@rest}
    />
    """
  end

  def boxed_field(%{commit: :self, editing: true} = assigns) do
    ~H"""
    <div class="commit-field-section">
      <.field_header :if={@label} id={@id} label={@label} accent={@accent} toggle?={false} />
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-submit={@save_event}
        phx-click-away={@cancel_event}
        class="commit-field-form"
      >
        {render_slot(@hidden)}
        <.input
          field={@form[@field]}
          type={if(@multiline, do: "textarea", else: "text")}
          id={"#{@id}-input"}
          rows={@multiline && @rows}
          class={["commit-field-input", @markdown && "commit-field-mono", @input_class]}
          phx-hook="CommitField"
          data-field-role="edit"
          data-commit={if(@multiline, do: "cmd-enter", else: "enter")}
          data-autofocus="true"
          data-cancel-id={"#{@id}-cancel"}
        />
        <div class="commit-field-actions">
          <button type="submit" id={"#{@id}-save"} class="btn btn-sm btn-primary">Save</button>
          <button type="button" id={"#{@id}-cancel"} phx-click={@cancel_event} class="btn btn-sm">
            Cancel
          </button>
          <span class="commit-field-hint">
            Markdown supported · <span class="font-mono">⌘↵</span> saves · Esc cancels
          </span>
        </div>
      </.form>
    </div>
    """
  end

  def boxed_field(%{commit: :self, edit_event: edit_event} = assigns) when is_binary(edit_event) do
    ~H"""
    <div class="commit-field-section">
      <.field_header
        :if={@label}
        id={@id}
        label={@label}
        accent={@accent}
        toggle?={@collapsible}
        expanded={@expanded}
        value={@value}
        toggle_event={@toggle_event}
        edit_event={@edit_event}
      />
      <%!-- empty: dashed Add box --%>
      <div
        :if={field_blank?(@value)}
        id={"#{@id}-display"}
        role="button"
        tabindex="0"
        phx-click={@edit_event}
        phx-hook="CommitField"
        data-field-role="display"
        class="commit-field-rest"
        {@edit_attrs}
      >
        <div class="commit-field-placeholder">{@placeholder}</div>
      </div>
      <%!-- collapsed preview: collapsible + has content + not expanded --%>
      <div :if={!field_blank?(@value) && @collapsible && !@expanded} class="commit-field-preview-box">
        <div
          id={"#{@id}-display"}
          role="button"
          tabindex="0"
          phx-click={@edit_event}
          phx-hook="CommitField"
          data-field-role="display"
          class="commit-field-preview"
          {@edit_attrs}
        >
          <div :if={@markdown} id={"#{@id}-view"} class="md">{Relay.Markdown.to_html(@value)}</div>
          <div :if={!@markdown} id={"#{@id}-view"} class="whitespace-pre-wrap">{@value}</div>
        </div>
        <button
          type="button"
          id={"#{@id}-show-more"}
          phx-click={@toggle_event}
          class="commit-field-showmore"
        >
          Show more
        </button>
      </div>
      <%!-- full read: non-collapsible OR expanded, has content --%>
      <div
        :if={!field_blank?(@value) && (!@collapsible || @expanded)}
        id={"#{@id}-display"}
        role="button"
        tabindex="0"
        phx-click={@edit_event}
        phx-hook="CommitField"
        data-field-role="display"
        class="commit-field-rest"
        {@edit_attrs}
      >
        <div :if={@markdown} id={"#{@id}-view"} class="md">{Relay.Markdown.to_html(@value)}</div>
        <div :if={!@markdown} id={"#{@id}-view"} class="commit-field-input whitespace-pre-wrap">
          {@value}
        </div>
      </div>
    </div>
    """
  end

  def boxed_field(%{commit: :self} = assigns) do
    ~H"""
    <.form for={@form} id={"#{@id}-form"} phx-submit={@save_event} class="commit-field-form">
      <div :if={@prefix} class="commit-field-prefixed">
        <span class="commit-field-prefix font-mono">{@prefix}</span>
        <input
          type="text"
          id={"#{@id}-input"}
          name={@form[@field].name}
          value={Phoenix.HTML.Form.normalize_value("text", @form[@field].value)}
          phx-hook="CommitField"
          data-field-role="edit"
          data-commit="enter"
          data-dirty-pill="true"
          data-cancel-id={"#{@id}-cancel"}
          class={["commit-field-bare font-mono", @input_class]}
        />
      </div>
      <.input
        :if={!@prefix}
        field={@form[@field]}
        type={if(@multiline, do: "textarea", else: "text")}
        id={"#{@id}-input"}
        rows={@multiline && @rows}
        placeholder={@placeholder}
        class={["commit-field-input", @input_class]}
        phx-hook="CommitField"
        data-field-role="edit"
        data-commit={if(@multiline, do: "cmd-enter", else: "enter")}
        data-dirty-pill="true"
        data-cancel-id={"#{@id}-cancel"}
      />
      <p
        :for={msg <- Enum.map(@form[@field].errors, &translate_error/1)}
        :if={@prefix}
        id={"#{@id}-error"}
        class="mt-1 text-sm text-error"
      >
        {msg}
      </p>
      <.commit_pill
        id={@id}
        cancel_event={@cancel_event}
        hint={if(@multiline, do: "⌘↵ · Esc", else: "Enter · Esc")}
        hidden
      />
    </.form>
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
