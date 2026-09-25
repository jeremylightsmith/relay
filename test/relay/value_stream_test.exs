defmodule Relay.ValueStreamTest do
  use Relay.DataCase, async: true

  import Relay.ValueStreamFixtures

  alias Relay.ValueStream

  describe "stream_states/1" do
    test "RE's board yields the artboard's nine states, starting at Next up despite three queues" do
      s = re_board()
      states = ValueStream.stream_states(s.board.id)

      assert Enum.map(states, & &1.name) ==
               ["Next up", "Spec", "Spec · Review", "Spec · Done", "Plan", "Plan · Done", "Code", "Review", "Done"]

      assert Enum.map(states, & &1.kind) == [:queue, :flow, :gate, :queue, :flow, :queue, :flow, :gate, :done]
      assert hd(states).stage_id == s.next_up.id
      assert Enum.all?(states, &(&1.kind in ValueStream.kinds()))

      targets = Map.new(states, &{&1.name, &1.rework_target})
      assert targets["Spec · Review"] == s.spec.id
      assert targets["Review"] == s.code.id
      assert targets["Code"] == nil
      assert targets["Spec · Done"] == nil
    end

    test "a gate with no flow state before it has no rework target" do
      board = insert(:board)
      insert(:stage, board: board, name: "Next up", type: :queue, category: :unstarted, position: 1)
      insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 2)
      insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 3)

      assert board.id |> ValueStream.stream_states() |> Enum.map(&{&1.name, &1.rework_target}) ==
               [{"Next up", nil}, {"Review", nil}, {"Done", nil}]
    end

    test "decision_types/0 is the one closed set of gate-decision activity types" do
      assert ValueStream.decision_types() == [:approved, :rejected]
    end

    test "with no queue before the first work stage, the stream starts at that stage" do
      board = insert(:board)
      insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 1)
      insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 2)

      assert board.id |> ValueStream.stream_states() |> Enum.map(& &1.name) == ["Code", "Done"]
    end

    test "an AI stage no enabled flow works in is off-stream; a card's time there is a nobody queue span" do
      s = re_board()
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 10}, {s.review, 30}, {s.deploy, 40}, {s.done, 100}])

      refute Enum.any?(ValueStream.stream_states(s.board.id), &(&1.stage_id == s.deploy.id))

      deploy = Enum.find(ValueStream.card_stream(card).spans, &(&1.stage_id == s.deploy.id))
      assert %{kind: :queue, secs: 60, baton: %{agent: 0, human: 0, nobody: 60}} = deploy
    end

    test "with no enabled flows every work stage stays in the stream" do
      s = re_board()
      Relay.Repo.update_all(Ecto.Query.where(Schemas.Flow, board_id: ^s.board.id), set: [enabled: false])

      names = s.board.id |> ValueStream.stream_states() |> Enum.map(& &1.name)
      assert Enum.take(names, -3) == ["Review", "Deploy", "Done"]
    end

    test "a board with no stages has no stream" do
      assert ValueStream.stream_states(insert(:board).id) == []
    end
  end

  describe "card_stream/1 — the full RE path with a Request-changes loop" do
    setup do
      s = re_board()
      card = card_in(s.done, at(0))

      walk(card, [{s.backlog, 0}, {s.next_up, 10}, {s.spec, 100}, {s.spec_review, 160}, {s.spec, 200}])
      decided(card, :rejected, s.spec, s.spec, at(200))
      walk(card, [{s.spec, 200}, {s.spec_review, 260}, {s.spec_done, 300}])
      decided(card, :approved, s.spec_review, s.spec_done, at(300))

      walk(card, [
        {s.spec_done, 300},
        {s.plan, 400},
        {s.plan_done, 450},
        {s.code, 500},
        {s.review, 700},
        {s.done, 760}
      ])

      decided(card, :approved, s.review, s.done, at(760))

      %{s: s, card: card}
    end

    test "spans follow the transitions in order and Spec's second stay is visit 2", %{card: card} do
      stream = ValueStream.card_stream(card)

      assert stream.started_at == at(10)
      assert stream.done_at == at(760)

      assert Enum.map(stream.spans, &{&1.name, &1.kind, &1.visit, &1.secs}) == [
               {"Next up", :queue, 1, 90},
               {"Spec", :flow, 1, 60},
               {"Spec · Review", :gate, 1, 40},
               {"Spec", :flow, 2, 60},
               {"Spec · Review", :gate, 2, 40},
               {"Spec · Done", :queue, 1, 100},
               {"Plan", :flow, 1, 50},
               {"Plan · Done", :queue, 1, 50},
               {"Code", :flow, 1, 200},
               {"Review", :gate, 1, 60}
             ]

      assert hd(stream.spans).entered_at == at(10)
      assert List.last(stream.spans).left_at == at(760)
    end

    test "spans tile the lead time and every baton split sums to its span", %{card: card} do
      stream = ValueStream.card_stream(card)

      assert stream.lead_secs == 750
      assert stream.spans |> Enum.map(& &1.secs) |> Enum.sum() == stream.lead_secs

      for span <- stream.spans do
        assert span.baton.agent + span.baton.human + span.baton.nobody == span.secs
      end

      assert stream.baton_secs == %{agent: 0, human: 140, nobody: 610}
      assert stream.value_add_secs == 0
      assert stream.flow_efficiency == 0.0
      assert Decimal.equal?(stream.cost, Decimal.new(0))
    end

    test "states carry stream_summary's per-state shape over this one card (n = 1)", %{s: s, card: card} do
      stream = ValueStream.card_stream(card)

      assert Enum.map(stream.states, & &1.stage_id) ==
               Enum.map(ValueStream.stream_states(s.board.id), & &1.stage_id)

      spec = Enum.find(stream.states, &(&1.stage_id == s.spec.id))
      assert spec.mean_secs == 120.0
      assert spec.mean_first_secs == 60.0
      assert spec.mean_visits == 2.0
      assert spec.mean_cost == nil

      spec_review = Enum.find(stream.states, &(&1.stage_id == s.spec_review.id))
      assert spec_review.approve_rate == 0.5
      assert spec_review.rework_target == s.spec.id

      review = Enum.find(stream.states, &(&1.stage_id == s.review.id))
      assert review.approve_rate == 1.0
      assert review.rework_target == s.code.id

      assert Enum.find(stream.states, &(&1.stage_id == s.done.id)).wip == 1
      assert Enum.find(stream.states, &(&1.stage_id == s.next_up.id)).wip == 0

      assert stream.outside_secs == 0.0
      assert (stream.states |> Enum.map(& &1.mean_secs) |> Enum.sum()) + stream.outside_secs == stream.lead_secs
    end

    test "gate decisions are attributed to the gate the card left", %{s: s, card: card} do
      assert ValueStream.card_stream(card).gates == [
               %{stage_id: s.spec_review.id, approved: 1, rejected: 1},
               %{stage_id: s.review.id, approved: 1, rejected: 0}
             ]
    end
  end

  describe "card_stream/1 — baton split" do
    test "agent = union of executions, human = parks minus agent, nobody = the rest; open intervals clip" do
      s = re_board()
      card = card_in(s.done, at(0))

      walk(card, [{s.next_up, 0}, {s.code, 100}])
      parked(card, at(400))
      answered(card, at(500))
      parked(card, at(680))
      answered(card, at(750))
      walk(card, [{s.code, 100}, {s.review, 1000}, {s.done, 1100}])

      executed(card, "implement", at(150), at(300))
      # overlaps the first — counted once
      executed(card, "implement", at(250), at(400))
      executed(card, "implement", at(600), at(700))
      # never finished — clipped to the Code span's end
      executed(card, "implement", at(800), nil)

      code = card |> ValueStream.card_stream() |> Map.fetch!(:spans) |> Enum.find(&(&1.name == "Code"))

      assert code.secs == 900
      assert code.baton == %{agent: 550, human: 150, nobody: 200}
    end

    test "a work stage that is not ai_enabled is all human, whatever ran there" do
      s = re_board(code_ai_enabled: false)
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 100}, {s.review, 400}, {s.done, 500}])
      executed(card, "implement", at(150), at(200))

      code = card |> ValueStream.card_stream() |> Map.fetch!(:spans) |> Enum.find(&(&1.name == "Code"))

      assert code.baton == %{agent: 0, human: 300, nobody: 0}
    end
  end

  describe "card_stream/1 — stream start and off-stream time" do
    test "a card that skips Next up starts on its first entry into a later stream state" do
      s = re_board()
      card = card_in(s.done, at(0))
      walk(card, [{s.backlog, 0}, {s.spec, 50}, {s.done, 150}])

      stream = ValueStream.card_stream(card)

      assert stream.started_at == at(50)
      assert Enum.map(stream.spans, &{&1.name, &1.secs}) == [{"Spec", 100}]
      assert stream.lead_secs == 100
    end

    test "time back in Backlog after the clock started is a :queue span nobody holds" do
      s = re_board()
      card = card_in(s.done, at(0))

      walk(card, [
        {s.backlog, 0},
        {s.next_up, 10},
        {s.spec, 100},
        {s.backlog, 200},
        {s.next_up, 300},
        {s.spec, 350},
        {s.done, 400}
      ])

      stream = ValueStream.card_stream(card)

      assert Enum.map(stream.spans, &{&1.name, &1.kind, &1.visit, &1.secs}) == [
               {"Next up", :queue, 1, 90},
               {"Spec", :flow, 1, 100},
               {"Backlog", :queue, 1, 100},
               {"Next up", :queue, 2, 50},
               {"Spec", :flow, 2, 50}
             ]

      assert Enum.at(stream.spans, 2).baton == %{agent: 0, human: 0, nobody: 100}
      assert stream.lead_secs == 390
    end

    test "a stage that no longer exists keeps its snapshot name and counts as :queue" do
      s = re_board()
      card = card_in(s.done, at(0))

      insert(:activity,
        card: card,
        type: :moved,
        meta: %{
          "from_stage" => "Next up",
          "to_stage" => "Old stage",
          "from_stage_id" => s.next_up.id,
          "to_stage_id" => -1
        },
        inserted_at: at(100)
      )

      insert(:activity,
        card: card,
        type: :moved,
        meta: %{"from_stage" => "Old stage", "to_stage" => "Done", "from_stage_id" => -1, "to_stage_id" => s.done.id},
        inserted_at: at(200)
      )

      stream = ValueStream.card_stream(card)

      assert Enum.map(stream.spans, &{&1.name, &1.kind, &1.secs}) == [
               {"Next up", :queue, 100},
               {"Old stage", :queue, 100}
             ]
    end

    test "outside_secs is the card's off-stream time, so its states plus outside tile the lead" do
      s = re_board()
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 10}, {s.review, 30}, {s.deploy, 40}, {s.done, 100}])

      stream = ValueStream.card_stream(card)

      assert stream.outside_secs == 60.0
      assert (stream.states |> Enum.map(& &1.mean_secs) |> Enum.sum()) + stream.outside_secs == stream.lead_secs
    end

    test "a card that never entered the stream has no stream" do
      s = re_board()
      assert ValueStream.card_stream(card_in(s.backlog, at(0))) == nil
    end

    test "an unfinished card's last span runs to now and the spans still tile the lead time" do
      s = re_board()
      card = card_in(s.code, at(0), status: :working)
      walk(card, [{s.next_up, 0}, {s.code, 10}])

      stream = ValueStream.card_stream(card)

      assert stream.done_at == nil
      assert List.last(stream.spans).name == "Code"
      assert stream.spans |> Enum.map(& &1.secs) |> Enum.sum() == stream.lead_secs
    end

    test "an in-place approve at a terminal review stage ends the stream at the approval" do
      board = insert(:board)
      next_up = insert(:stage, board: board, name: "Next up", type: :queue, category: :unstarted, position: 1)

      code =
        insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 2, ai_enabled: true)

      done = insert(:stage, board: board, name: "Done", type: :review, category: :complete, position: 3)
      card = card_in(done, at(0))
      walk(card, [{next_up, 0}, {code, 100}, {done, 300}])
      decided(card, :approved, done, done, at(350))

      stream = ValueStream.card_stream(card)

      assert stream.done_at == at(350)
      assert stream.spans |> List.last() |> Map.take([:name, :kind, :secs]) == %{name: "Done", kind: :gate, secs: 50}
      assert List.last(stream.spans).baton == %{agent: 0, human: 50, nobody: 0}
      assert stream.lead_secs == 350
    end
  end

  describe "card_stream/1 — value-add and cost" do
    test "only :do nodes of the current flow count as value-add; cost sums every execution" do
      s = re_board()
      flow = code_flow(s.board)
      assert Schemas.Flow.node_roles(flow) == %{"implement" => :do, "spec_review" => :check, "fix" => :fix}

      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 100}, {s.done, 1000}])
      executed(card, "implement", at(200), at(300), cost: Decimal.new("1.50"))
      executed(card, "spec_review", at(300), at(350))
      executed(card, "fix", at(400), at(430), cost: Decimal.new("0.25"))
      # a node key the current flow no longer has is agent time, never value-add
      executed(card, "ghost", at(500), at(520))

      stream = ValueStream.card_stream(card)

      assert stream.baton_secs.agent == 200
      assert stream.value_add_secs == 100
      assert stream.lead_secs == 1000
      assert stream.flow_efficiency == stream.value_add_secs / stream.lead_secs
      assert stream.flow_efficiency == 0.1
      assert Decimal.equal?(stream.cost, Decimal.new("1.75"))
    end
  end

  describe "card_stream/1 — per-span cost (RE347)" do
    defp attributed(spans),
      do: spans |> Enum.map(&(&1.cost || Decimal.new(0))) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    test "a span sums the cost of executions that started inside it; the rest belong to no span" do
      s = re_board()
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 100}, {s.review, 400}, {s.done, 500}])
      # started before the stream began — unattributed
      executed(card, "implement", at(-10), at(5), cost: Decimal.new("5.00"))
      executed(card, "implement", at(50), at(60), cost: Decimal.new("0.10"))
      executed(card, "implement", at(150), at(250), cost: Decimal.new("1.00"))
      executed(card, "implement", at(260), at(300))
      # Review only ran an execution with no reported cost
      executed(card, "fix", at(450), at(460))
      # started at done_at — outside [entered_at, left_at) of every span
      executed(card, "implement", at(500), at(510), cost: Decimal.new("2.00"))

      stream = ValueStream.card_stream(card)
      costs = Map.new(stream.spans, &{&1.name, &1.cost})

      assert Decimal.equal?(costs["Next up"], Decimal.new("0.10"))
      assert Decimal.equal?(costs["Code"], Decimal.new("1.00"))
      assert costs["Review"] == nil
      assert Decimal.equal?(stream.cost, Decimal.new("8.10"))
      assert Decimal.compare(attributed(stream.spans), stream.cost) == :lt

      code = Enum.find(stream.states, &(&1.stage_id == s.code.id))
      assert Decimal.equal?(code.mean_cost, Decimal.new("1.00"))
    end

    test "Σ span.cost equals the card's cost when every execution started inside the stream" do
      s = re_board()
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 100}, {s.done, 300}])
      executed(card, "implement", at(150), at(200), cost: Decimal.new("1.25"))
      executed(card, "fix", at(210), at(250), cost: Decimal.new("0.75"))

      stream = ValueStream.card_stream(card)

      assert Decimal.equal?(stream.cost, Decimal.new("2.00"))
      assert Decimal.equal?(attributed(stream.spans), stream.cost)
    end
  end
end
