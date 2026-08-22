defmodule RelayWeb.Api.CardJSON do
  @moduledoc "JSON representation of cards (shared across API controllers)."

  alias Relay.Cards

  @doc """
  The shared card shape. `board` supplies the ref + key; `stages` (the board's in-memory stage
  list) drives the derived `done`/`needs_you` facts, and `archived_at` the `archived` flag.
  Heavy acceptance_criteria/plan/spec live on show/1.
  """
  def data(board, card, stages) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      title: card.title,
      tag: card.tag,
      status: card.status,
      # RE198 — a genuine card fact the API never exposed. `archived_at` is already in the
      # `@list_card_fields` projection, so this costs nothing; `bin/relay search` marks
      # archived rows from it.
      archived: not is_nil(card.archived_at),
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
        # RE93 — both directions, single-card only. data/3 (the index/summary shape) is
        # deliberately NOT extended: it would be an N+1 per card and no consumer needs it there.
        |> Map.put(:depends_on, Enum.map(Cards.list_dependencies(board, card), &dependency/1))
        |> Map.put(:blocks, Enum.map(Cards.list_dependents(board, card), &dependent/1))
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

  # `text` is the rendered line for :action rows (`Relay.Activity`'s :text doc,
  # activity.ex:49) — `LogSink.row/2` writes the runner's real log line there while
  # hardcoding `meta: %{}` (log_sink.ex:156). Dropping it here is what made timelines
  # print `action {}`; `meta: %{}` is correct by design and is NOT the bug (RLY-177).
  # Fixing it in the serializer also fixes rows already stored.
  defp entry(%Schemas.Activity{} = a) do
    %{kind: "activity", type: a.type, text: a.text, meta: a.meta, author: author(a), inserted_at: a.inserted_at}
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

  # Both directions are mapped key-by-key rather than passed through, so the wire shape stays a
  # decision made here: `satisfied?` is the context's internal boolean-suffix convention and the
  # wire key is `satisfied`, and anything later added to the context's maps stays internal.
  defp dependency(%{ref: ref, title: title, satisfied?: satisfied}), do: %{ref: ref, title: title, satisfied: satisfied}

  defp dependent(%{ref: ref, title: title}), do: %{ref: ref, title: title}

  defp owner(%Schemas.CardOwner{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}

  defp owner(%Schemas.CardOwner{actor_type: :user, user: user}) do
    %{type: "user", id: user.id, name: user.name || user.email}
  end
end
