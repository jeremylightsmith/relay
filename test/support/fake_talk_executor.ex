defmodule Relay.FakeTalkExecutor do
  @moduledoc """
  RE268 — the test seam ADR 0009 names: claims a talk job the way `relay execute` would and
  posts canned event batches through the real `Relay.Talk` API. No model, no HTTP, no worktree —
  it covers post -> claim -> append -> render, which is most of the feature's surface.
  """

  alias Relay.Runs
  alias Relay.Talk

  @doc """
  Claims the next job for `executor` and returns the talk turn it carries, or nil. Marks the
  turn `:claimed` exactly where `RelayWeb.Api.NodeJobController` does, so a test driving this
  seam sees the same turn status a real executor's claim produces.
  """
  def claim(executor) do
    case Runs.claim_next_job(executor) do
      {:ok, %{kind: :talk} = job} ->
        Talk.mark_claimed(job)
        Talk.get_turn(job.payload["turn_id"])

      _other ->
        nil
    end
  end

  @doc "Posts `lines` — `[{kind, text}]` — as one at-least-once batch, numbering `client_seq` from 1."
  def stream(turn, lines) do
    events =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {{kind, text}, i} ->
        %{"client_seq" => i, "kind" => to_string(kind), "text" => text, "dim" => kind == :tool}
      end)

    {:ok, stored} = Talk.append_events(turn, events)
    stored
  end

  @doc "Runs a whole turn: claim, stream, finish — the fast path most tests want."
  def run(executor, lines, session_id \\ "sess-fake") do
    turn = claim(executor)
    stream(turn, lines)
    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: session_id})
    done
  end
end
