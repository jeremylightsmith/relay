defmodule Relay.Boards do
  @moduledoc """
  The Boards context: boards and their stages (the workflow pipeline).
  Cards arrive in MMF 03 (`Relay.Cards`).
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage
  alias Schemas.User

  @seed_stages [
    {"Backlog", :human, :unstarted},
    {"Spec", :human, :unstarted},
    {"Plan", :ai, :in_progress},
    {"Code", :ai, :in_progress},
    {"Review", :human, :in_progress},
    {"Deploy", :ai, :in_progress},
    {"Done", :human, :complete}
  ]

  @doc """
  Returns the user's board with `stages` preloaded in `position` order,
  creating the board (unique slug derived from the user) and seeding the
  default 7-stage pipeline on first call. Idempotent per user.
  """
  def get_or_create_default_board(%User{} = user) do
    board = Repo.get_by(Board, owner_id: user.id) || create_default_board!(user)
    Repo.preload(board, stages: from(s in Stage, order_by: s.position))
  end

  @doc "Returns the board's stages in position order."
  def list_stages(%Board{id: board_id}) do
    Repo.all(from s in Stage, where: s.board_id == ^board_id, order_by: s.position)
  end

  @doc "Returns the stage with `id` on `board`, or nil (board-scoped lookup)."
  def get_stage(%Board{id: board_id}, id) do
    Repo.get_by(Stage, id: id, board_id: board_id)
  end

  @doc """
  Enables a `:review` or `:done` sub-lane on `parent` (a main stage),
  creating the child stage with the predictable owner (review → :human,
  done → the parent's owner). Idempotent — returns the existing child if
  the lane is already enabled.
  """
  def enable_lane(%Stage{lane: :main} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      %Stage{} = existing ->
        {:ok, existing}

      nil ->
        %Stage{board_id: parent.board_id, parent_id: parent.id, lane: lane}
        |> Stage.changeset(%{
          name: "#{parent.name}:#{lane_word(lane)}",
          position: next_position(parent.board_id),
          category: parent.category,
          owner: lane_owner(lane, parent)
        })
        |> Repo.insert()
    end
  end

  @doc """
  Disables `parent`'s `lane` sub-lane. Returns `{:ok, :disabled}` when the
  (empty) child is removed, `{:ok, :not_enabled}` when there is nothing to
  remove, or `{:error, :not_empty}` when the lane still holds cards.
  """
  def disable_lane(%Stage{} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      nil ->
        {:ok, :not_enabled}

      %Stage{} = child ->
        if Repo.exists?(from c in Card, where: c.stage_id == ^child.id) do
          {:error, :not_empty}
        else
          {:ok, _} = Repo.delete(child)
          {:ok, :disabled}
        end
    end
  end

  @doc "The stage's `:review`/`:done` children, ordered Review then Done."
  def sublanes(%Stage{} = parent) do
    Repo.all(
      from s in Stage,
        where: s.parent_id == ^parent.id,
        order_by: fragment("array_position(ARRAY['review','done'], ?)", s.lane)
    )
  end

  defp get_sublane(%Stage{} = parent, lane) do
    Repo.get_by(Stage, parent_id: parent.id, lane: lane)
  end

  defp lane_owner(:review, _parent), do: :human
  defp lane_owner(:done, %Stage{owner: owner}), do: owner

  defp lane_word(:review), do: "Review"
  defp lane_word(:done), do: "Done"

  defp next_position(board_id) do
    (Repo.one(from s in Stage, where: s.board_id == ^board_id, select: max(s.position)) || 0) + 1
  end

  defp create_default_board!(user) do
    {:ok, board} =
      Repo.transaction(fn ->
        board =
          %Board{owner_id: user.id}
          |> Board.changeset(%{slug: unique_slug(user)})
          |> Repo.insert!()

        @seed_stages
        |> Enum.with_index(1)
        |> Enum.each(fn {{name, owner, category}, position} ->
          %Stage{board_id: board.id}
          |> Stage.changeset(%{name: name, position: position, category: category, owner: owner})
          |> Repo.insert!()
        end)

        board
      end)

    board
  end

  defp unique_slug(user) do
    base = slug_base(user)

    if slug_taken?(base), do: suffixed_slug(base, 2), else: base
  end

  defp suffixed_slug(base, n) do
    candidate = "#{base}-#{n}"

    if slug_taken?(candidate), do: suffixed_slug(base, n + 1), else: candidate
  end

  defp slug_taken?(slug), do: Repo.exists?(from(b in Board, where: b.slug == ^slug))

  defp slug_base(user) do
    source = user.name || user.email |> String.split("@") |> hd()

    case source |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "board"
      base -> base
    end
  end
end
