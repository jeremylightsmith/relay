defmodule RelayWeb.StoryMapFilter do
  @moduledoc """
  The story map's filter bar model (RE259): who owns what, and which cards pass.

  A pure module beside `RelayWeb.StoryMapGrid` and shaped the same way — no Ecto, no
  LiveView, no side effects — so every rule the artboard
  (`docs/designs/Relay Story Map.dc.html`, `pass/1` line ~358 and `ownerChips` line ~540)
  encodes is unit-testable without mounting anything.

  **It owns the owner-key wire format exactly once**, the way `StoryMapGrid` owns the
  column keys: `"agent"` for the single Relay AI actor, `"u:<user_id>"` for a person. Those
  strings are what live in the shared view's `"owner_filter"` list and what a click sends
  back, so they are defined and parsed here and nowhere else. `parse_owner_key/1` never
  calls `String.to_atom/1` — this is client input, and a forged value is `:error` (a silent
  no-op at the call site), mirroring `RelayWeb.StoryMapComponents.parse_zoom/1`. Piping
  `parse_owner_key/1` into `owner_key/1` **normalizes** a key, so `"u:007"` can only ever
  be stored as `"u:7"`.

  **The chip set is the union of two things**: every owner of a card on this map, and every
  currently-selected key. The union is what keeps a selection clearable at its own chip
  after the last card it owned moved away or was reassigned — without it a selected chip
  can vanish while still filtering, leaving an empty map and no obvious way back. Chips are
  derived from the cards the page already loaded, so they cost no extra query, and they are
  drawn by `RelayWeb.CoreComponents.avatar/1` so a person looks the same here as everywhere
  else on the board (and the AI is the standard violet mark).

  **Owner and Needs-input compose with AND**, and an empty selection means "every owner"
  (the artboard's `pass/1`). A card passes the owner test when **any** of its owners is
  selected — Relay cards can have several owners, unlike the artboard's single `c.owner`.
  "Needs input" is `Relay.Cards.needs_input?/1`, the one definition of that fact.

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.StoryMapGrid` and `RelayWeb.FlowLayout`.
  """

  alias Relay.Cards

  @doc """
  The wire key for one owner. Takes a loaded `Schemas.CardOwner` row, or the parsed shape
  `parse_owner_key/1` returns — so `parse_owner_key/1 |> owner_key/1` normalizes a key
  arriving off the wire before it is written to the shared view.
  """
  def owner_key(%{actor_type: :agent}), do: "agent"
  def owner_key(%{actor_type: :user, user_id: user_id}), do: "u:#{user_id}"
  def owner_key(:agent), do: "agent"
  def owner_key({:user, user_id}), do: "u:#{user_id}"

  @doc """
  Parses an owner key off the wire. Explicit clauses, never `String.to_atom/1`.

      parse_owner_key("agent") #=> {:ok, :agent}
      parse_owner_key("u:3")   #=> {:ok, {:user, 3}}
      parse_owner_key("u:abc") #=> :error
  """
  def parse_owner_key("agent"), do: {:ok, :agent}

  def parse_owner_key("u:" <> id) do
    case Integer.parse(id) do
      {user_id, ""} when user_id > 0 -> {:ok, {:user, user_id}}
      _other -> :error
    end
  end

  def parse_owner_key(_other), do: :error

  @doc """
  The DOM id of one owner chip. `:` is not legal in a CSS selector, so the key's colon
  becomes a dash — the same rule `RelayWeb.StoryMapGrid.cell_dom_id/2` follows, written
  once here because this module owns the key format.
  """
  def chip_dom_id(key), do: "story-map-owner-chip-" <> String.replace(key, ":", "-")

  @doc """
  The filter bar's chip list: every owner of a card in `cards`, union every key in
  `selected_keys`. People first by display name, the Relay AI chip last.
  """
  def chips(cards, selected_keys) do
    selected = MapSet.new(selected_keys)
    owners = Enum.flat_map(cards, & &1.owners)
    present = MapSet.new(owners, &owner_key/1)

    owners
    |> Enum.map(&chip(&1, selected))
    |> Enum.concat(orphan_chips(selected, present))
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(&{chip_rank(&1), String.downcase(&1.name)})
  end

  @doc """
  The cards that pass both filters. An empty `selected_keys` means every owner; `true` for
  `needs_input?` keeps only `Relay.Cards.needs_input?/1` cards. The two compose with AND.
  """
  def visible(cards, selected_keys, needs_input?) do
    selected = MapSet.new(selected_keys)

    Enum.filter(cards, fn card ->
      owner_pass?(card, selected) and (not needs_input? or Cards.needs_input?(card))
    end)
  end

  @doc """
  Whether any filter is on — what drives the `Clear` link and the `N of M` count label.
  Deliberately **not** affected by collapse or focus (the artboard's `filterActive`, line
  ~535): `Clear` clears filters, and focus is exited at its own chip.
  """
  def active?(selected_keys, needs_input?), do: selected_keys != [] or needs_input?

  # An empty selection short-circuits BEFORE touching `card.owners`, so the unfiltered
  # render never depends on the association being loaded.
  defp owner_pass?(card, selected) do
    MapSet.size(selected) == 0 or
      Enum.any?(card.owners, &MapSet.member?(selected, owner_key(&1)))
  end

  defp chip(%{actor_type: :agent}, selected), do: ai_chip(MapSet.member?(selected, "agent"))

  defp chip(%{actor_type: :user, user_id: user_id} = owner, selected) do
    user = Map.get(owner, :user)
    key = owner_key({:user, user_id})

    %{
      key: key,
      actor: :human,
      name: display_name(user),
      email: user && Map.get(user, :email),
      avatar_url: user && Map.get(user, :avatar_url),
      selected?: MapSet.member?(selected, key)
    }
  end

  # A selected key whose last owning card moved away or was reassigned. It keeps its chip so
  # the selection stays clearable; the person's name is gone with their card, so it takes
  # the app's existing "Someone" fallback (`CoreComponents.build_cluster/2`).
  defp orphan_chips(selected, present) do
    selected
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.flat_map(&orphan_chip/1)
  end

  defp orphan_chip(key) do
    case parse_owner_key(key) do
      {:ok, :agent} ->
        [ai_chip(true)]

      {:ok, {:user, _user_id} = parsed} ->
        [
          %{
            key: owner_key(parsed),
            actor: :human,
            name: "Someone",
            email: nil,
            avatar_url: nil,
            selected?: true
          }
        ]

      :error ->
        []
    end
  end

  defp ai_chip(selected?) do
    %{key: "agent", actor: :ai, name: "Relay AI", email: nil, avatar_url: nil, selected?: selected?}
  end

  # `Map.get/2` rather than `owner.user`: an unloaded association is a struct without the
  # field, which `Map.get/2` answers `nil` for — the same shape
  # `CoreComponents.build_cluster/2` already relies on.
  defp display_name(user) do
    (user && Map.get(user, :name)) || (user && Map.get(user, :email)) || "Someone"
  end

  defp chip_rank(%{actor: :ai}), do: 1
  defp chip_rank(_chip), do: 0
end
