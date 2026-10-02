defmodule Schemas.FlowNodeLegacyAliasTest do
  @moduledoc """
  RE367: `tasks` is the canonical flow-contract name for a card's plan units. The `sub_tasks`
  spellings are deprecated aliases that `Schemas.Flow.Node.normalize_legacy/1` rewrites wherever a
  flow enters the system — this file covers the changeset (Flow Editor / attrs) entry path.
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_field: 2]

  alias Schemas.Flow.Node

  describe "normalize_legacy/1" do
    test "rewrites every legacy alias in a string-keyed node map" do
      legacy = %{
        "key" => "impl",
        "foreach" => "card.sub_tasks",
        "reads" => ["spec", "sub_tasks"],
        "writes" => ["sub_tasks"],
        "run" => "Implement {sub_task_id} ({sub_task}): relay task show {ref} {sub_task_id}"
      }

      assert Node.normalize_legacy(legacy) == %{
               "key" => "impl",
               "foreach" => "card.tasks",
               "reads" => ["spec", "tasks"],
               "writes" => ["tasks"],
               "run" => "Implement {task_id} ({task}): relay task show {ref} {task_id}"
             }
    end

    test "rewrites atom keys and atom contract values" do
      legacy = %{
        key: "impl",
        foreach: "card.sub_tasks",
        reads: [:sub_tasks],
        writes: [:plan, :sub_tasks],
        run: "{sub_task}"
      }

      assert Node.normalize_legacy(legacy) ==
               %{key: "impl", foreach: "card.tasks", reads: [:tasks], writes: [:plan, :tasks], run: "{task}"}
    end

    test "leaves canonical input unchanged" do
      canonical = %{"foreach" => "card.tasks", "reads" => ["tasks"], "writes" => [:tasks], "run" => "{task} {task_id}"}
      assert Node.normalize_legacy(canonical) == canonical
    end

    test "leaves unrelated text alone — only the exact-brace placeholders are rewritten" do
      attrs = %{"key" => "sub_tasks", "run" => "the sub_tasks table, card.sub_tasks, {sub_tasks}, {ref}"}
      assert Node.normalize_legacy(attrs) == attrs
    end

    test "passes nil fields through" do
      attrs = %{"foreach" => nil, "reads" => nil, "writes" => nil, "run" => nil}
      assert Node.normalize_legacy(attrs) == attrs
    end
  end

  describe "changeset/2" do
    test "a legacy-spelled node is valid and comes out canonical" do
      changeset =
        Node.changeset(%Node{}, %{
          key: "impl",
          type: :agent,
          run: "do {sub_task_id}",
          foreach: "card.sub_tasks",
          reads: ["sub_tasks"],
          writes: [:sub_tasks]
        })

      assert changeset.valid?
      assert get_field(changeset, :foreach) == "card.tasks"
      assert get_field(changeset, :reads) == [:tasks]
      assert get_field(changeset, :writes) == [:tasks]
      assert get_field(changeset, :run) == "do {task_id}"
    end

    test "card.tasks is the only foreach source; anything else is still rejected" do
      assert Node.foreach_sources() == ["card.tasks"]

      changeset = Node.changeset(%Node{}, %{key: "n", type: :agent, foreach: "card.bogus"})

      refute changeset.valid?
      assert {~s(must be "card.tasks"), _} = changeset.errors[:foreach]
    end

    test "tasks is a contract field and sub_tasks no longer is" do
      assert :tasks in Schemas.Card.contract_fields()
      refute :sub_tasks in Schemas.Card.contract_fields()
    end
  end
end
