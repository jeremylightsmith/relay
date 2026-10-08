defmodule RelayWeb.Api.BoardJSON do
  alias Relay.Cards
  alias Relay.Flows
  alias RelayWeb.Api.CardJSON

  def show(%{board: board, stages: stages, cards: cards}) do
    ai_stage_ids = Flows.ai_stage_ids(board)

    %{
      board: %{id: board.id, name: board.name, key: board.key},
      stages: Enum.map(stages, &CardJSON.stage(&1, stages, ai_stage_ids)),
      cards: Enum.map(cards, &CardJSON.data(board, &1, stages, ai_stage_ids)),
      needs_you: Cards.needs_you_rollup(board)
    }
  end
end
