defmodule HamacaWeb.StagePickerComponents do
  @moduledoc """
  The ONE stage picker (RE502, card mockup "A — one stage picker; substages nested on indented
  rows"): a popover panel of rows under a mono heading, with an optional filter box. The card
  drawer's Move-to menu, the flow editor's trigger-stage chooser and the story map's bulk
  Stage / Release / Step menus all render it, so they cannot drift apart.

  Every caller hands it **rows** built by one of the builders here — `stage_rows/2`,
  `release_rows/1`, `step_rows/2` — each a map of the shape

      %{id: integer() | String.t(), kind: :row | :header, label: String.t(),
        display_name: String.t(), depth: 0 | 1, owner: :ai | :human | nil}

  A `:row` is selectable; a `:header` (the story map's activity names) is an inert label. A
  `depth: 1` row is a sub-lane drawn nested under its parent with a guide line, labelled by
  its lane word ("Review") while its `display_name` ("Design · Review") is what the filter
  matches and what a filtered (flattened) list shows.

  **Marks** (`marks`, `%{row_id => :all | :some}`, from `mark_values/0`) say where the thing
  being moved already is: ✓ (`:all`) on a row everything is already on — rendered inert, so
  picking it does nothing — and – (`:some`) on a row only part of a selection is on. There is
  never a count.

  Not imported app-wide: call it by its full alias.
  """
  use HamacaWeb, :html

  alias Hamaca.Boards
  alias Schemas.Release
  alias Schemas.Stage
  alias Schemas.StoryActivity
  alias Schemas.StoryStep

  @mark_values [:all, :some]
  @no_release_id "none"

  @doc "The closed set of row marks: `:all` (✓, inert) and `:some` (–). A missing row id means no mark."
  @spec mark_values() :: [:all | :some]
  def mark_values, do: @mark_values

  @doc "The row id of the release picker's \"(No release)\" row."
  @spec no_release_id() :: String.t()
  def no_release_id, do: @no_release_id

  # ---- row builders ----

  @doc """
  Picker rows for `stages`, which must be in board (hierarchical) order — a parent, then its
  sub-lanes. A top-level stage is owned by `:ai` iff its id is in `ai_stage_ids` (the keys of
  `Hamaca.Flows.stage_flows/1`); a sub-lane is a nested `depth: 1` row with no owner, labelled
  by its lane word. Parents resolve from `stages` itself, never the database.
  """
  @spec stage_rows([Stage.t()], MapSet.t(integer())) :: [map()]
  def stage_rows(stages, ai_stage_ids) do
    by_id = Map.new(stages, &{&1.id, &1})
    Enum.map(stages, &stage_row(&1, by_id, ai_stage_ids))
  end

  defp stage_row(%Stage{parent_id: nil} = stage, _by_id, ai_stage_ids) do
    owner = if MapSet.member?(ai_stage_ids, stage.id), do: :ai, else: :human
    row(stage.id, stage.name, stage.name, 0, owner)
  end

  defp stage_row(%Stage{} = stage, by_id, _ai_stage_ids) do
    parent = Map.fetch!(by_id, stage.parent_id)
    row(stage.id, Stage.lane_word(stage.type), Boards.stage_display_name(stage, parent), 1, nil)
  end

  @doc "Picker rows for `releases` in the given order, then a final \"(No release)\" row (`no_release_id/0`)."
  @spec release_rows([Release.t()]) :: [map()]
  def release_rows(releases) do
    Enum.map(releases, &row(&1.id, &1.name, &1.name, 0, nil)) ++
      [row(@no_release_id, "(No release)", "(No release)", 0, nil)]
  end

  @doc """
  Picker rows for the story map's steps: for each activity (in the given order) that has
  steps, a `:header` row (`id: "act-<activity_id>"`), then its steps in position order. An
  activity with no steps emits nothing.
  """
  @spec step_rows([StoryActivity.t()], [StoryStep.t()]) :: [map()]
  def step_rows(activities, steps) do
    by_activity = Enum.group_by(steps, & &1.story_activity_id)

    Enum.flat_map(activities, fn activity ->
      case by_activity |> Map.get(activity.id, []) |> Enum.sort_by(& &1.position) do
        [] ->
          []

        activity_steps ->
          [header("act-#{activity.id}", activity.name) | Enum.map(activity_steps, &row(&1.id, &1.name, &1.name, 0, nil))]
      end
    end)
  end

  defp row(id, label, display_name, depth, owner) do
    %{id: id, kind: :row, label: label, display_name: display_name, depth: depth, owner: owner}
  end

  defp header(id, label) do
    %{id: id, kind: :header, label: label, display_name: label, depth: 0, owner: nil}
  end

  @doc """
  Narrows `rows` to the ones whose `display_name` contains `query` (trimmed, case-insensitive).
  A blank query returns `rows` unchanged. A kept row is flattened — `label: display_name,
  depth: 0` — so a matching sub-lane reads "Design · Review" rather than an indented "Review".
  A `:header` survives only when at least one row under it (up to the next header) does.
  """
  @spec filter_rows([map()], String.t() | nil) :: [map()]
  def filter_rows(rows, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" -> rows
      needle -> rows |> chunk_by_header() |> Enum.flat_map(&filter_chunk(&1, needle))
    end
  end

  # Split into [header | rows] groups; rows before any header form a header-less group.
  defp chunk_by_header(rows) do
    Enum.chunk_while(
      rows,
      [],
      fn
        %{kind: :header} = h, [] -> {:cont, [h]}
        %{kind: :header} = h, acc -> {:cont, Enum.reverse(acc), [h]}
        r, acc -> {:cont, [r | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp filter_chunk([%{kind: :header} = h | rows], needle) do
    case filter_chunk(rows, needle) do
      [] -> []
      kept -> [h | kept]
    end
  end

  defp filter_chunk(rows, needle) do
    for %{kind: :row} = r <- rows, String.contains?(String.downcase(r.display_name), needle) do
      %{r | label: r.display_name, depth: 0}
    end
  end

  # ---- components ----

  attr :id, :string, required: true, doc: "the panel root id; row DOM ids are \"<id>-<row.id>\""
  attr :heading, :string, required: true, doc: ~s(the mono eyebrow, e.g. "MOVE TO" or "STAGE")
  attr :rows, :list, required: true, doc: "row maps from stage_rows/2, release_rows/1 or step_rows/2"
  attr :marks, :map, default: %{}, doc: "%{row_id => :all | :some} — see mark_values/0"
  attr :event, :string, required: true, doc: "the phx-click of every selectable row"
  attr :value_name, :string, default: "stage_id", doc: "each row sends phx-value-<value_name>={row.id}"
  attr :row_attrs, :map, default: %{}, doc: ~s(extra attributes on every row button, e.g. %{"phx-value-ref" => ref})
  attr :filter, :string, default: nil, doc: "the filter box's text; nil renders no filter box"
  attr :filter_event, :string, default: nil, doc: "the filter form's phx-change / phx-submit (param q)"
  attr :filter_placeholder, :string, default: "Filter stages…"
  attr :pending, :boolean, default: false, doc: "RE394 — give clickable rows a Moving… pressed face"
  attr :class, :string, default: "", doc: "the caller's positioning / max-height classes"

  @doc "The picker panel: heading, optional filter box, then the (filtered) rows and headers."
  def stage_picker(assigns) do
    assigns = assign(assigns, :visible_rows, filter_rows(assigns.rows, assigns.filter))

    ~H"""
    <div
      id={@id}
      class={[
        "bg-base-100 border border-base-300 rounded-box shadow-lg w-64 p-1.5 overflow-y-auto",
        @class
      ]}
    >
      <div class="px-1.5 pt-1 pb-1.5 font-mono text-[9.5px] font-semibold tracking-wider text-base-content/55">
        {@heading}
      </div>
      <form
        :if={@filter != nil}
        id={"#{@id}-filter-form"}
        phx-change={@filter_event}
        phx-submit={@filter_event}
      >
        <input
          type="text"
          id={"#{@id}-filter"}
          name="q"
          value={@filter}
          autocomplete="off"
          phx-mounted={JS.focus()}
          placeholder={@filter_placeholder}
          class="input input-xs w-full mb-1.5"
        />
      </form>
      <div class="flex flex-col gap-px">
        <span
          :if={@visible_rows == []}
          id={"#{@id}-none"}
          class="px-1.5 py-[5px] text-[12.5px] font-medium text-base-content/50"
        >
          No stages match
        </span>
        <%= for row <- @visible_rows do %>
          <.picker_header :if={row.kind == :header} label={row.label} />
          <.picker_row
            :if={row.kind == :row}
            id={"#{@id}-#{row.id}"}
            label={row.label}
            mark={Map.get(@marks, row.id)}
            owner={row.owner}
            depth={row.depth}
            event={@event}
            pending={@pending}
            {Map.merge(%{"phx-value-#{@value_name}" => row.id}, @row_attrs)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :mark, :atom, default: nil, values: [nil | @mark_values]
  attr :owner, :atom, default: nil, values: [nil, :ai, :human]
  attr :depth, :integer, default: 0, values: [0, 1]
  attr :event, :string, default: nil, doc: "nil — or an :all mark — renders an inert, non-clickable row"
  attr :pending, :boolean, default: false
  attr :rest, :global, doc: "the phx-value-* attributes"

  @doc "One picker row: a button, or an inert div when it has no event or carries the ✓ (:all) mark."
  def picker_row(assigns) do
    assigns = assign(assigns, :inert?, assigns.event == nil or assigns.mark == :all)

    ~H"""
    <div :if={@inert?} id={@id} class={row_class(@depth, @mark)}>
      <.row_body label={@label} mark={@mark} owner={@owner} depth={@depth} />
    </div>
    <button
      :if={!@inert?}
      type="button"
      id={@id}
      phx-click={@event}
      class={[row_class(@depth, @mark), @pending && "pending-action"]}
      {@rest}
    >
      <.row_body label={@label} mark={@mark} owner={@owner} depth={@depth} />
      <%!-- RE394 — the pressed row's face; hidden until LiveView marks the row loading. --%>
      <span
        :if={@pending}
        class="pending-face ml-auto flex flex-none items-center gap-1 font-mono text-[10px] text-base-content/65"
        aria-hidden="true"
      >
        <span class="loading loading-spinner loading-xs"></span> Moving…
      </span>
    </button>
    """
  end

  attr :label, :string, required: true

  @doc "An inert act header between groups of step rows."
  def picker_header(assigns) do
    ~H"""
    <div class="px-1.5 pt-2 pb-0.5 font-mono text-[9.5px] font-semibold tracking-wider text-base-content/45 uppercase">
      {@label}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :mark, :atom, required: true
  attr :owner, :atom, required: true
  attr :depth, :integer, required: true

  defp row_body(assigns) do
    ~H"""
    <span :if={@mark == :some} class="w-3.5 flex-none flex justify-center">
      <span class="w-2 h-[2px] rounded bg-primary"></span>
    </span>
    <span :if={@mark != :some} class="w-3.5 flex-none">
      <.icon :if={@mark == :all} name="hero-check" class="size-3.5 text-primary" />
    </span>
    <%= if @depth == 1 do %>
      <span class="ml-[3px] self-stretch -my-[5px] w-px bg-base-300"></span>
      <span class="text-base-content/35 font-mono text-[10px] -ml-1">─</span>
    <% else %>
      <span :if={@owner} class={["size-[7px] flex-none rounded-[2px]", owner_class(@owner)]}></span>
    <% end %>
    <span class="truncate">{@label}</span>
    """
  end

  @row_base "flex w-full items-center gap-2 rounded-md px-1.5 py-[5px] text-left hover:bg-base-200"

  defp row_class(0, nil), do: [@row_base, "text-[12.5px] font-medium text-base-content/85"]
  defp row_class(0, _mark), do: [@row_base, "text-[12.5px] font-semibold text-base-content"]
  defp row_class(1, nil), do: [@row_base, "text-[11.5px] text-base-content/65"]
  defp row_class(1, _mark), do: [@row_base, "text-[11.5px] font-semibold text-base-content"]

  defp owner_class(:ai), do: "bg-secondary"
  defp owner_class(:human), do: "bg-primary/45"
end
