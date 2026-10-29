defmodule Schemas.FlowNodeContractTest do
  @moduledoc """
  `tasks` / `card.tasks` are the only flow-contract spellings (RE367). Since RE487 the old
  `sub_tasks` spellings are no longer rewritten anywhere: the changeset simply refuses them.
  """
  use ExUnit.Case, async: true

  alias Schemas.Flow.Node

  # Scenario 11
  test "a card.sub_tasks foreach is invalid" do
    changeset = Node.changeset(%Node{}, %{"key" => "a", "type" => "agent", "foreach" => "card.sub_tasks"})

    refute changeset.valid?
    assert {~s(must be "card.tasks"), _} = changeset.errors[:foreach]
  end

  test "sub_tasks in reads is invalid" do
    changeset = Node.changeset(%Node{}, %{"key" => "a", "type" => "agent", "reads" => ["sub_tasks"]})

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :reads)
  end

  test "the alias normalizer is gone" do
    Code.ensure_loaded!(Node)
    refute function_exported?(Node, :normalize_legacy, 1)
  end

  test "card.tasks is the only foreach source; anything else is rejected" do
    assert Node.foreach_sources() == ["card.tasks"]

    changeset = Node.changeset(%Node{}, %{key: "n", type: :agent, foreach: "card.bogus"})

    refute changeset.valid?
    assert {~s(must be "card.tasks"), _} = changeset.errors[:foreach]
  end

  test "tasks is a contract field and sub_tasks is not" do
    assert :tasks in Schemas.Card.contract_fields()
    refute :sub_tasks in Schemas.Card.contract_fields()
  end
end
