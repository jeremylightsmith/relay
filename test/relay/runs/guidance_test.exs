defmodule Relay.Runs.GuidanceTest do
  @moduledoc """
  RE358 Part 1: human guidance written while a card is being worked reaches every agent node.
  `Relay.Runs.guidance_for/2` derives it live from the card's comments (window: the earlier of
  the open rejection's `rejected_at` and the run's `inserted_at`), `render_guidance/2` renders
  it, `build_payload/4` carries it as `vars["guidance"]`, and the claim refreshes it.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Schemas.Card
  alias Schemas.CardRejection
  alias Schemas.Comment
  alias Schemas.NodeJob
  alias Schemas.User

  setup do
    start_engine!()
    FakeDispatcher.register(self())

    user = insert(:user, name: "Ada Lovelace")
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Guidance Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))

    {:ok, card} =
      Relay.Cards.create_card(stage, %{
        title: "Steer me",
        spec: "# Spec (pre-seeded — the spec flow's brainstorm declares it writes this, RE244)",
        acceptance_criteria: "1. It works."
      })

    %{user: user, board: board, flow: flow, card: card}
  end

  defp at(%DateTime{} = t, seconds), do: DateTime.add(t, seconds, :second)

  defp user_comment(card, user, body, inserted_at, kind \\ :comment) do
    insert(:comment, card: card, user: user, body: body, kind: kind, inserted_at: inserted_at, updated_at: inserted_at)
  end

  defp agent_comment(card, body, inserted_at, kind) do
    insert(:comment, card: card, body: body, kind: kind, inserted_at: inserted_at, updated_at: inserted_at)
  end

  defp bodies(comments), do: Enum.map(comments, & &1.body)

  defp reload_card(card), do: Repo.get!(Card, card.id)

  defp open_rejection(card, rejected_at) do
    card
    |> reload_card()
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:rejection, %CardRejection{note: "Use approach A", rejected_at: rejected_at})
    |> Repo.update!()
  end

  # A two-agent-node flow on the Spec stage, so a `succeeded` on the first node dispatches a
  # second job (scenario 8). A stage holds one flow, so the seeded "spec" flow is cleared first.
  defp two_node_flow(board, spec_flow) do
    {:ok, spec_flow} = Relay.Flows.disable_flow(spec_flow)
    {:ok, _deleted} = Relay.Flows.delete_flow(spec_flow)
    spec = Enum.find(board.stages, &(&1.name == "Spec"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "two-step",
        isolation: :shared_clean,
        stage_id: spec.id,
        nodes: [
          %{key: "first", type: :agent, run: "/first {ref}"},
          %{key: "second", type: :agent, run: "/second {ref}"}
        ],
        edges: [
          %{from: "start", to: "first"},
          %{from: "first", to: "second", on: :succeeded},
          %{from: "second", to: "done", on: :succeeded}
        ]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp runner(board) do
    {:ok, runner} =
      Runs.upsert_runner(board, %{
        "name" => "guidance-runner",
        "capacity" => %{"shared_clean" => 2, "exclusive" => 1},
        "version" => Runs.min_runner_version()
      })

    runner
  end

  describe "guidance_for/2 — the window" do
    # Scenario 1
    test "with no open rejection, only comments at or after the run's start count",
         %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      t = run.inserted_at

      user_comment(card, user, "before", at(t, -60))
      user_comment(card, user, "after", at(t, 10))

      assert ["after"] = card |> reload_card() |> Runs.guidance_for(run) |> bodies()
    end

    # Scenario 2
    test "an open rejection earlier than the run widens the window to rejected_at",
         %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      t = run.inserted_at

      card = open_rejection(card, at(t, -120))
      user_comment(card, user, "Use approach A", at(t, -120), :changes_requested)
      user_comment(card, user, "Actually, use approach B", at(t, -60))

      assert card |> Runs.guidance_for(run) |> bodies() == ["Use approach A", "Actually, use approach B"]
    end

    # Scenario 3
    test "agent comments and every question are excluded; any :changes_requested counts",
         %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      t = run.inserted_at

      agent_comment(card, "working on it", at(t, 1), :comment)
      agent_comment(card, "which one?", at(t, 2), :question)
      agent_comment(card, "reviewer says no", at(t, 3), :changes_requested)
      user_comment(card, user, "ok", at(t, 4))

      assert card |> reload_card() |> Runs.guidance_for(run) |> bodies() == ["reviewer says no", "ok"]
    end

    # Scenario 4
    test "comments in the same second come back in ascending id order",
         %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      t = at(run.inserted_at, 5)

      first = user_comment(card, user, "one", t)
      second = user_comment(card, user, "two", t)

      ids = card |> reload_card() |> Runs.guidance_for(run) |> Enum.map(& &1.id)
      assert ids == [first.id, second.id]
      assert first.id < second.id
    end

    test "each entry comes back with :user and :images preloaded", %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      user_comment(card, user, "hi", at(run.inserted_at, 1))

      assert [%Comment{user: %User{name: "Ada Lovelace"}, images: []}] =
               card |> reload_card() |> Runs.guidance_for(run)
    end
  end

  describe "render_guidance/2" do
    # Scenario 5
    test "no entries render to nil, and a fresh run's job carries a nil guidance var",
         %{flow: flow, card: card} do
      assert Runs.render_guidance([], "RE1") == nil

      {:ok, _run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{} = job}
      assert Map.has_key?(job.payload["vars"], "guidance")
      assert job.payload["vars"]["guidance"] == nil
    end

    # Scenario 6
    test "the header names the author, the UTC minute and the kind tag; the body follows verbatim",
         %{user: user} do
      comment = %Comment{
        actor_type: :user,
        kind: :changes_requested,
        body: "Use approach A",
        inserted_at: ~U[2026-10-11 21:04:05Z],
        user: user,
        images: []
      }

      assert Runs.render_guidance([comment], "RE7") ==
               "Ada Lovelace · 2026-10-11 21:04 UTC · CHANGES REQUESTED\nUse approach A"

      assert Runs.render_guidance([%{comment | kind: :steer}], "RE7") ==
               "Ada Lovelace · 2026-10-11 21:04 UTC · STEER\nUse approach A"

      assert Runs.render_guidance([%{comment | kind: :comment}], "RE7") ==
               "Ada Lovelace · 2026-10-11 21:04 UTC\nUse approach A"
    end

    test "the author falls back to the email, then to Relay AI for an agent row" do
      base = %Comment{kind: :comment, body: "x", inserted_at: ~U[2026-10-11 21:04:05Z], images: []}
      nameless = %User{name: nil, email: "ada@example.com"}

      assert Runs.render_guidance([%{base | actor_type: :user, user: nameless}], "RE7") ==
               "ada@example.com · 2026-10-11 21:04 UTC\nx"

      assert Runs.render_guidance([%{base | actor_type: :agent, user: nil, kind: :changes_requested}], "RE7") ==
               "Relay AI · 2026-10-11 21:04 UTC · CHANGES REQUESTED\nx"
    end

    test "entries are joined by one blank line", %{user: user} do
      a = %Comment{
        actor_type: :user,
        kind: :comment,
        body: "a",
        inserted_at: ~U[2026-10-11 21:04:05Z],
        user: user,
        images: []
      }

      b = %{a | body: "b", inserted_at: ~U[2026-10-11 21:05:00Z]}

      assert Runs.render_guidance([a, b], "RE7") ==
               "Ada Lovelace · 2026-10-11 21:04 UTC\na\n\nAda Lovelace · 2026-10-11 21:05 UTC\nb"
    end

    # Scenario 7
    test "images are named by count with a pointer to the card; a blank body adds no line",
         %{user: user, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      t = run.inserted_at

      with_text = user_comment(card, user, "see screenshot", at(t, 1))
      image_only = user_comment(card, user, "", at(t, 2))
      insert(:attachment, card: card, comment_id: with_text.id, position: 0)
      insert(:attachment, card: card, comment_id: with_text.id, position: 1)
      insert(:attachment, card: card, comment_id: image_only.id, position: 0)

      rendered = card |> reload_card() |> Runs.guidance_for(run) |> Runs.render_guidance("RE7")
      [first, second] = String.split(rendered, "\n\n")

      assert String.ends_with?(first, "see screenshot\n(2 images attached — see ./relay card RE7)")
      assert [header, "(1 image attached — see ./relay card RE7)"] = String.split(second, "\n")
      assert header =~ ~r/^Ada Lovelace · \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC$/
    end
  end

  describe "the job payload" do
    # Scenario 8
    test "guidance is derived live per job — a note added mid-run reaches the next job only",
         %{user: user, board: board, flow: spec_flow, card: card} do
      flow = two_node_flow(board, spec_flow)
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{node_key: "first"} = first}
      {:ok, first} = Runs.claim_job(first, "guidance-runner")

      user_comment(card, user, "late note", at(run.inserted_at, 1))
      {:ok, _run} = Runs.report_outcome(first, %{outcome: :succeeded, detail: "first done"})

      assert_receive {:dispatched, %NodeJob{node_key: "second"} = second}
      assert second.payload["vars"]["guidance"] =~ "late note"

      stored_first = Repo.get!(NodeJob, first.id)
      refute (stored_first.payload["vars"]["guidance"] || "") =~ "late note"
    end

    # Scenario 8a
    test "the claim refreshes a queued job's guidance and stores it on the row",
         %{user: user, board: board, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{} = queued}
      assert queued.payload["vars"]["guidance"] == nil

      user_comment(card, user, "added before pickup", at(run.inserted_at, 1))

      assert {:ok, %NodeJob{id: id} = claimed} = Runs.claim_next_job(runner(board))
      assert id == queued.id
      guidance = claimed.payload["vars"]["guidance"]
      assert guidance =~ "added before pickup"
      assert Repo.get!(NodeJob, id).payload["vars"]["guidance"] == guidance
    end

    # Scenario 8b
    test "a claimed talk job's payload is returned unchanged", %{board: board, card: card} do
      payload = %{"turn_id" => 1, "prompt" => "why is this stuck?"}
      talk = Runs.insert_talk_job!(card, payload, nil)

      assert {:ok, %NodeJob{id: id} = claimed} = Runs.claim_next_job(runner(board))
      assert id == talk.id
      assert claimed.payload == payload
      refute Map.has_key?(claimed.payload, "vars")
    end

    # Scenario 9
    test "placeholder-looking guidance reaches the payload literally",
         %{user: user, board: board, flow: flow, card: card} do
      {:ok, run} = Runs.start_run(card, flow)
      assert_receive {:dispatched, %NodeJob{}}

      user_comment(card, user, "please check {ref} and {branch}", at(run.inserted_at, 1))

      assert {:ok, %NodeJob{} = claimed} = Runs.claim_next_job(runner(board))
      assert claimed.payload["vars"]["guidance"] =~ "please check {ref} and {branch}"
    end
  end
end
