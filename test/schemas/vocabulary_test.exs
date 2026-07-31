defmodule Schemas.VocabularyTest do
  @moduledoc """
  RLY-203: the lifecycle vocabularies are the run system's closed sets, defined once on the
  owning schema. These assertions are the regression teeth — each partition must cover (or be a
  subset of) its full `Ecto.Enum`, so a new enum value fails CI until it is consciously placed in
  a vocabulary function rather than silently misclassified.
  """
  use ExUnit.Case, async: true

  alias Schemas.Flow.Edge

  test "run statuses partition exactly into active + terminal" do
    assert Enum.sort(Schemas.Run.active_statuses() ++ Schemas.Run.terminal_statuses()) ==
             Enum.sort(Ecto.Enum.values(Schemas.Run, :status))
  end

  test "run active and terminal sets are disjoint" do
    assert Schemas.Run.active_statuses() -- Schemas.Run.terminal_statuses() ==
             Schemas.Run.active_statuses()
  end

  test "active?/1 agrees with active_statuses/0 across the whole enum" do
    for status <- Ecto.Enum.values(Schemas.Run, :status) do
      assert Schemas.Run.active?(status) == status in Schemas.Run.active_statuses()
    end
  end

  test "node-job active and claimed states are subsets of the state enum" do
    values = Ecto.Enum.values(Schemas.NodeJob, :state)
    assert Schemas.NodeJob.active_states() -- values == []
    assert Schemas.NodeJob.claimed_states() -- values == []
  end

  test "claimed_states/0 is 'held by a live claim' — active minus :queued" do
    refute :queued in Schemas.NodeJob.claimed_states()
    assert Enum.all?(Schemas.NodeJob.claimed_states(), &(&1 in Schemas.NodeJob.active_states()))
  end

  test "every closed set is defined once, delegating to its Ecto.Enum" do
    for {module, fun, field} <- [
          {Schemas.Card, :statuses, :status},
          {Schemas.Stage, :categories, :category},
          {Schemas.Stage, :types, :type},
          {Schemas.Run, :statuses, :status},
          {Schemas.Run, :parked_reasons, :parked_reason},
          {Schemas.NodeJob, :states, :state},
          {Schemas.NodeExecution, :outcomes, :outcome},
          {Schemas.Flow, :isolation_classes, :isolation}
        ] do
      assert apply(module, fun, []) == Ecto.Enum.values(module, field),
             "#{inspect(module)}.#{fun}/0 must delegate to Ecto.Enum.values(#{inspect(module)}, #{inspect(field)})"
    end
  end

  test "runnable_types/0 is a subset of the Node type enum" do
    assert Enum.all?(
             Schemas.Flow.Node.runnable_types(),
             &(&1 in Ecto.Enum.values(Schemas.Flow.Node, :type))
           )
  end

  test "Node.fields/0 is exactly the embedded schema's field list" do
    assert Enum.sort(Schemas.Flow.Node.fields()) ==
             Enum.sort(Schemas.Flow.Node.__schema__(:fields))
  end

  test "Edge.fields/0 is exactly the embedded schema's field list" do
    assert Enum.sort(Edge.fields()) ==
             Enum.sort(Edge.__schema__(:fields))
  end

  test "expects_commits is in the node field list (RLY-241: copies of it used to omit it)" do
    assert :expects_commits in Schemas.Flow.Node.fields()
  end

  test "types/0 equals the whole Node type enum" do
    assert Schemas.Flow.Node.types() == Ecto.Enum.values(Schemas.Flow.Node, :type)
  end

  test "the edge `on` enum is the NodeExecution outcome set, not a second copy of it" do
    assert Ecto.Enum.values(Edge, :on) == Schemas.NodeExecution.outcomes()
  end

  test "the edge `when` enum equals when_values/0" do
    assert Ecto.Enum.values(Edge, :when) == Edge.when_values()
  end
end
