defmodule Relay.FakeTalkRunner do
  @moduledoc """
  RE268 — the test seam ADR 0009 names: claims a talk job the way `relay start` would and
  posts canned event batches through the real `Relay.Talk` API. No model, no HTTP, no worktree —
  it covers post -> claim -> append -> render, which is most of the feature's surface.
  """

  alias Relay.Runs
  alias Relay.Talk

  @doc """
  Claims the next job for `runner` and returns the talk turn it carries, or nil. Marks the
  turn `:claimed` exactly where `RelayWeb.Api.NodeJobController` does, so a test driving this
  seam sees the same turn status a real runner's claim produces.
  """
  def claim(runner) do
    case Runs.claim_next_job(runner) do
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
  def run(runner, lines, session_id \\ "sess-fake") do
    turn = claim(runner)
    stream(turn, lines)
    {:ok, done} = Talk.finish_turn(turn, :done, %{session_id: session_id})
    done
  end
end
