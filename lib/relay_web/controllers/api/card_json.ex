defmodule RelayWeb.Api.CardJSON do
  @moduledoc "JSON representation of cards (shared across API controllers)."

  alias Relay.Cards

  @doc """
  The shared card shape. `board` supplies the ref + key; `stages` (the board's in-memory stage
  list) drives the derived `done`/`needs_you` facts. Heavy acceptance_criteria/plan/spec live on show/1.
  """
  def data(board, card, stages) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      title: card.title,
      tag: card.tag,
      status: card.status,
      done: Cards.done?(card, stages),
      needs_you: Cards.needs_you?(card, stages),
      branch: card.branch,
      pr_url: card.pr_url,
      stage_id: card.stage_id,
      sub_task_progress: Cards.sub_task_progress(card),
      owners: Enum.map(card.owners, &owner/1),
      active_owner: Cards.active_owner_type(card),
      rejection: rejection(card.rejection)
    }
  end

  @doc "The shared stage shape. type/ai_enabled drive behavior; parent_id/wip_limit let the CLI charge sub-lanes to their parent."
  def stage(stage) do
    %{
      id: stage.id,
      name: stage.name,
      category: stage.category,
      type: stage.type,
      ai_enabled: stage.ai_enabled,
      position: stage.position,
      wip_limit: stage.wip_limit,
      parent_id: stage.parent_id
    }
  end

  def index(%{board: board, stages: stages, cards: cards}) do
    %{data: Enum.map(cards, &data(board, &1, stages))}
  end

  @doc "The light single-card shape (RLY-98): data/3 alone, none of show/1's heavy fields."
  def summary(%{board: board, card: card, stages: stages}) do
    %{data: data(board, card, stages)}
  end

  def show(%{board: board, card: card, stages: stages, timeline: timeline}) do
    %{
      data:
        board
        |> data(card, stages)
        |> Map.put(:description, card.description)
        |> Map.put(:acceptance_criteria, card.acceptance_criteria)
        |> Map.put(:plan, card.plan)
        |> Map.put(:spec, card.spec)
        |> Map.put(:ai_result, card.ai_result)
        |> Map.put(:sub_tasks, Enum.map(card.sub_tasks, &sub_task/1))
        |> Map.put(:timeline, Enum.map(timeline, &entry/1))
    }
  end

  def comment(%{comment: comment}) do
    %{data: entry(comment)}
  end

  def attachment(%{attachment: attachment}) do
    %{
      data: %{
        id: attachment.id,
        url: "/attachments/#{attachment.id}",
        markdown: "![#{escape_markdown_text(attachment.filename)}](/attachments/#{attachment.id})"
      }
    }
  end

  # `filename` is accepted verbatim from the ingest body, so it can contain
  # markdown-special characters. Escape `[` and `]` (would prematurely open/close
  # the image alt text) and `)` (harmless here but defensive) so the generated
  # markdown always round-trips to the literal filename as alt text.
  defp escape_markdown_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace(")", "\\)")
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
