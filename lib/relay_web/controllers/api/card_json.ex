defmodule RelayWeb.Api.CardJSON do
  @moduledoc "JSON representation of cards (shared across API controllers)."

  alias Relay.Cards

  @doc "The shared card shape. `board` supplies the ref + key. Heavy plan/spec live on show/1."
  def data(board, card) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      title: card.title,
      tag: card.tag,
      status: card.status,
      progress: card.progress,
      branch: card.branch,
      pr_url: card.pr_url,
      stage_id: card.stage_id,
      ai_result: card.ai_result,
      sub_task_progress: Cards.sub_task_progress(card),
      owners: Enum.map(card.owners, &owner/1),
      active_owner: Cards.active_owner_type(card),
      rejection: rejection(card.rejection)
    }
  end

  @doc "The shared stage shape. lane/parent_id/wip_limit let the CLI charge sub-lanes to their parent."
  def stage(stage) do
    %{
      id: stage.id,
      name: stage.name,
      category: stage.category,
      owner: stage.owner,
      position: stage.position,
      approval_gate: stage.approval_gate,
      reject_to_stage_id: stage.reject_to_stage_id,
      wip_limit: stage.wip_limit,
      lane: stage.lane,
      parent_id: stage.parent_id
    }
  end

  def index(%{board: board, cards: cards}) do
    %{data: Enum.map(cards, &data(board, &1))}
  end

  def show(%{board: board, card: card, timeline: timeline}) do
    %{
      data:
        board
        |> data(card)
        |> Map.put(:description, card.description)
        |> Map.put(:plan, card.plan)
        |> Map.put(:spec, card.spec)
        |> Map.put(:sub_tasks, Enum.map(card.sub_tasks, &sub_task/1))
        |> Map.put(:timeline, Enum.map(timeline, &entry/1))
    }
  end

  def comment(%{comment: comment}) do
    %{data: entry(comment)}
  end

  defp entry(%Schemas.Comment{} = c) do
    %{kind: "comment", body: c.body, author: author(c), inserted_at: c.inserted_at}
  end

  defp entry(%Schemas.Activity{} = a) do
    %{kind: "activity", type: a.type, meta: a.meta, author: author(a), inserted_at: a.inserted_at}
  end

  defp author(%{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}
  defp author(%{actor_type: :user, user: user}), do: %{type: "user", id: user.id, name: user.name || user.email}

  defp rejection(nil), do: nil

  defp rejection(%Schemas.CardRejection{} = r) do
    %{
      note: r.note,
      from_stage: r.from_stage_name,
      to_stage: r.to_stage_name,
      rejected_by: r.rejected_by,
      rejected_at: r.rejected_at
    }
  end

  defp sub_task(%Schemas.SubTask{} = st) do
    %{id: st.id, title: st.title, done: st.done, position: st.position}
  end

  defp owner(%Schemas.CardOwner{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}

  defp owner(%Schemas.CardOwner{actor_type: :user, user: user}) do
    %{type: "user", id: user.id, name: user.name || user.email}
  end
end
