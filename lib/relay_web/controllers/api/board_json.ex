defmodule RelayWeb.Api.BoardJSON do
  alias RelayWeb.Api.CardJSON

  def show(%{board: board, stages: stages, cards: cards}) do
    %{
      board: %{id: board.id, name: board.name, key: board.key},
      stages: Enum.map(stages, &CardJSON.stage/1),
      cards: Enum.map(cards, &CardJSON.data(board, &1))
    }
  end
end
