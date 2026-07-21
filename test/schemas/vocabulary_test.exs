defmodule Schemas.VocabularyTest do
  @moduledoc """
  RLY-203: the lifecycle vocabularies are the run system's closed sets, defined once on the
  owning schema. These assertions are the regression teeth — each partition must cover (or be a
  subset of) its full `Ecto.Enum`, so a new enum value fails CI until it is consciously placed in
  a vocabulary function rather than silently misclassified.
  """
  use ExUnit.Case, async: true

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

  test "outcomes/0 equals the whole NodeExecution outcome enum" do
    assert Schemas.NodeExecution.outcomes() == Ecto.Enum.values(Schemas.NodeExecution, :outcome)
  end

  test "isolation_classes/0 equals the whole Flow isolation enum" do
    assert Schemas.Flow.isolation_classes() == Ecto.Enum.values(Schemas.Flow, :isolation)
  end

  test "runnable_types/0 is a subset of the Node type enum" do
    assert Enum.all?(
             Schemas.Flow.Node.runnable_types(),
             &(&1 in Ecto.Enum.values(Schemas.Flow.Node, :type))
           )
  end
end
