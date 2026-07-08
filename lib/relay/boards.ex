defmodule Relay.Boards do
  @moduledoc """
  The Boards context: boards and their stages (the workflow pipeline).
  Cards arrive in MMF 03 (`Relay.Cards`).
  """

  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
  alias Schemas.Board
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
