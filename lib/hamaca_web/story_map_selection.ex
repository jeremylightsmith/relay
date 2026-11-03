defmodule HamacaWeb.StoryMapSelection do
  @moduledoc """
  RE502 — the story map's multi-select, as pure functions over card ids. No Ecto, no LiveView:
  `HamacaWeb.BoardLive` holds the selection (a `MapSet` of card ids, per socket, never persisted
  or broadcast) and asks here for every rule about it, so the rules are unit-testable without a
  socket and stay out of the LiveView.

  **The selection only ever holds what the human can see.** `visible_cards/5` is the map's
  filter pre-pass — the one definition, which `BoardLive`'s viewport also renders from — and
  `selectable_ids/1` narrows it to the cards that are placed on the map. `prune/2` intersects a
  selection with that set, so a card a filter hides, or another actor unmaps, drops out instead
  of being moved by a bulk action the human can no longer see.

  The select-all boxes are tri-state (`group_state/2`) and toggle as a unit (`toggle_group/2`):
  a group that is entirely selected is removed; anything less is filled in. `group_ids/3` reads
  a group's members straight out of the `HamacaWeb.StoryMapGrid` the page rendered, so a box can
  only ever select the cards drawn under it.

  `marks/2` and `order_by_map_position/4` serve the bulk menus: the first says where the
  selection is now, in `HamacaWeb.StagePickerComponents`' mark vocabulary; the second gives
  the selection a stable reading order — the order the map draws it in.

  `confirm_copy/3` and `confirm_modes/0` / `parse_confirm_mode/1` serve the batched live-run
  confirm (RLY-217's modal, for N cards): its singular/plural copy and its closed set of
  answers.

  No `use Boundary` — a pure web-layer helper inside the `HamacaWeb` boundary, like
  `HamacaWeb.StoryMapGrid`.
  """

  alias Hamaca.Boards
  alias HamacaWeb.StagePickerComponents
  alias HamacaWeb.StoryMapFilter
  alias HamacaWeb.StoryMapGrid

  @confirm_modes [:all, :others]

  @doc """
  The cards that pass the map's filters (RE259/RE276): the owner chips, Needs input and Hide
  complete. "Complete" is resolved here, from `stages`, through
  `Hamaca.Boards.top_level_done_stage_ids/1` — a finished top-level COLUMN, whatever the card's
  status; deliberately not `Hamaca.Cards.done?/2`, which drives the card face's strikethrough.
  """
  @spec visible_cards([Schemas.Card.t()], [Schemas.Stage.t()], list(), boolean(), boolean()) ::
          [Schemas.Card.t()]
  def visible_cards(cards, stages, owner_filter, needs_input?, hide_complete?) do
    hidden_stage_ids =
      if hide_complete?,
        do: MapSet.new(Boards.top_level_done_stage_ids(stages)),
        else: MapSet.new()

    StoryMapFilter.visible(cards, owner_filter, needs_input?, hidden_stage_ids)
  end

  @doc "The ids of the given (visible) cards that are placed on the map — the tray's are not selectable."
  @spec selectable_ids([Schemas.Card.t()]) :: MapSet.t(integer())
  def selectable_ids(cards) do
    for %{story_activity_id: activity_id, id: id} <- cards, not is_nil(activity_id), into: MapSet.new(), do: id
  end

  @doc "Adds `id` when absent, removes it when present."
  @spec toggle(MapSet.t(), integer()) :: MapSet.t()
  def toggle(selection, id) do
    if MapSet.member?(selection, id), do: MapSet.delete(selection, id), else: MapSet.put(selection, id)
  end

  @doc "A fully selected group is removed; anything less is added whole. An empty group is a no-op."
  @spec toggle_group(MapSet.t(), [integer()]) :: MapSet.t()
  def toggle_group(selection, ids) do
    case group_state(selection, ids) do
      :all -> MapSet.difference(selection, MapSet.new(ids))
      _none_or_some -> MapSet.union(selection, MapSet.new(ids))
    end
  end

  @doc "How much of a group is selected. An empty group is `:none`."
  @spec group_state(MapSet.t(), [integer()]) :: :none | :some | :all
  def group_state(_selection, []), do: :none

  def group_state(selection, ids) do
    case Enum.count(ids, &MapSet.member?(selection, &1)) do
      0 -> :none
      n when n == length(ids) -> :all
      _partial -> :some
    end
  end

  @doc """
  The card ids under one select-all box: every card in the grid's cells for that column key or
  lane key. A collapsed activity's cards are in no cell (`HamacaWeb.StoryMapGrid` counts them on
  its stub), so a lane box never selects cards it does not draw.
  """
  @spec group_ids(StoryMapGrid.t(), :column | :lane, String.t()) :: [integer()]
  def group_ids(%StoryMapGrid{cells: cells}, kind, key) do
    for {{column_key, lane_key}, cards} <- cells,
        group_key(kind, column_key, lane_key) == key,
        card <- cards,
        do: card.id
  end

  defp group_key(:column, column_key, _lane_key), do: column_key
  defp group_key(:lane, _column_key, lane_key), do: lane_key

  @doc "The selection with everything no longer selectable dropped."
  @spec prune(MapSet.t(), MapSet.t()) :: MapSet.t()
  def prune(selection, selectable), do: MapSet.intersection(selection, selectable)

  @doc """
  Where the given cards sit now, as picker marks: `:all` when every card shares one key, else
  `:some` on every key present. The keys are `stage_id`, `release_id` (nil is
  `HamacaWeb.StagePickerComponents.no_release_id/0`) and `story_step_id` (a step-less card adds
  no key).
  """
  @spec marks([Schemas.Card.t()], :stage | :release | :step) :: %{optional(term()) => :all | :some}
  def marks(cards, axis) do
    [all, some] = StagePickerComponents.mark_values()
    per_card = Enum.map(cards, &mark_key(&1, axis))
    keys = per_card |> Enum.concat() |> Enum.uniq()
    # `:all` only when EVERY card contributed that one key — a step-less card means the
    # selection is not all on that step.
    shared? = match?([_key], keys) and Enum.all?(per_card, &(&1 != []))

    Map.new(keys, &{&1, if(shared?, do: all, else: some)})
  end

  defp mark_key(card, :stage), do: [card.stage_id]
  defp mark_key(%{release_id: nil}, :release), do: [StagePickerComponents.no_release_id()]
  defp mark_key(card, :release), do: [card.release_id]
  defp mark_key(%{story_step_id: nil}, :step), do: []
  defp mark_key(card, :step), do: [card.story_step_id]

  @doc """
  The cards in the order the map draws them: release (nil last), then activity, then step
  within its activity (a step-less card after that activity's steps), then
  `story_map_position` (nil last), then `id`. A card's activity is derived from its step when
  the step is known, as `HamacaWeb.StoryMapGrid` does.

  Every "missing" index is `nil`, and Erlang term order puts every integer before an atom, so
  each nil-last rule needs no branch.
  """
  @spec order_by_map_position([Schemas.Card.t()], list(), list(), list()) :: [Schemas.Card.t()]
  def order_by_map_position(cards, activities, steps, releases) do
    release_index = index_by_id(releases)
    activity_index = index_by_id(activities)
    steps_by_id = Map.new(steps, &{&1.id, &1})

    step_index =
      steps
      |> Enum.group_by(& &1.story_activity_id)
      |> Enum.flat_map(fn {_activity_id, group} -> group |> Enum.with_index() |> Enum.map(fn {s, i} -> {s.id, i} end) end)
      |> Map.new()

    Enum.sort_by(cards, fn card ->
      step = card.story_step_id && Map.get(steps_by_id, card.story_step_id)
      activity_id = (step && step.story_activity_id) || card.story_activity_id

      {Map.get(release_index, card.release_id), Map.get(activity_index, activity_id),
       step && Map.get(step_index, step.id), card.story_map_position, card.id}
    end)
  end

  defp index_by_id(structs), do: structs |> Enum.with_index() |> Map.new(fn {s, i} -> {s.id, i} end)

  @doc """
  The batched live-run confirm's answers: `:all` cancels the stranding runs and moves every
  card; `:others` moves only the cards without a live run.
  """
  @spec confirm_modes() :: [:all | :others]
  def confirm_modes, do: @confirm_modes

  @doc """
  Parses a confirm mode off the wire — matched against `confirm_modes/0`, never
  `String.to_atom/1`.

      parse_confirm_mode("all") #=> {:ok, :all}
      parse_confirm_mode("x")   #=> :error
  """
  @spec parse_confirm_mode(term()) :: {:ok, :all | :others} | :error
  def parse_confirm_mode(mode) when is_binary(mode) do
    case Enum.find(@confirm_modes, &(Atom.to_string(&1) == mode)) do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  def parse_confirm_mode(_other), do: :error

  @doc """
  The batched live-run confirm's copy for `k` live runs among the `n` cards being moved to
  `target`. `others` is nil when every card is running (there are no others to move).

      confirm_copy(1, 3, "Backlog").title #=> "1 of 3 cards has a live run"
  """
  @spec confirm_copy(pos_integer(), pos_integer(), String.t()) :: %{
          title: String.t(),
          cancel_all: String.t(),
          others: String.t() | nil,
          consequence: String.t()
        }
  def confirm_copy(k, n, target) when k >= 1 and n >= k do
    %{
      title: "#{k} of #{n} #{plural(n, "card", "cards")} #{plural(k, "has a live run", "have live runs")}",
      cancel_all: "Cancel #{k} #{plural(k, "run", "runs")} & move all #{n}",
      others: if(n - k > 0, do: "Move the other #{n - k} only"),
      consequence: consequence(k, target)
    }
  end

  defp consequence(1, target), do: "Moving it to #{target} cancels that run and frees its runner slot."
  defp consequence(_k, target), do: "Moving them to #{target} cancels those runs and frees their runner slots."

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many
end
