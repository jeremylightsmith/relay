defmodule Schemas.FlowNodeRoleTest do
  @moduledoc """
  RE346: every flow node has a role — Do / Check / Fix. An authored `role` always wins;
  `Schemas.Flow.node_roles/1` guesses the rest. Display-only.
  """
  use ExUnit.Case, async: true

  alias Schemas.Flow
  alias Schemas.Flow.Node

  describe "Node role field" do
    test "roles/0 is the closed vocabulary" do
      assert Node.roles() == [:do, :check, :fix]
    end

    test "casts every role from its string form" do
      for role <- Node.roles() do
        changeset = Node.changeset(%Node{}, %{key: "n", type: :agent, role: Atom.to_string(role)})
        assert changeset.valid?, "#{role} should cast"
        assert Ecto.Changeset.get_field(changeset, :role) == role
      end
    end

    test "rejects a junk role" do
      for junk <- ["review", "FIX"] do
        changeset = Node.changeset(%Node{}, %{key: "n", type: :agent, role: junk})
        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :role)
      end
    end

    test "role is optional and valid on every node type" do
      assert Node.changeset(%Node{}, %{key: "n", type: :agent}).valid?

      for type <- Node.types(), role <- Node.roles() do
        assert Node.changeset(%Node{}, %{key: "n", type: type, role: role}).valid?,
               "role #{role} should be valid on a #{type} node"
      end
    end

    test "role is one of the node fields" do
      assert :role in Node.fields()
    end
  end

  describe "node_roles/1 guesses an unset role" do
    # a → g (gate) → m → done; a and g both fail into f; f loops back to a on success and
    # fails into m. m is reached by one succeeded and one failed edge.
    setup do
      nodes = [
        %{key: "a", type: :agent},
        %{key: "g", type: :gate},
        %{key: "f", type: :agent},
        %{key: "m", type: :agent}
      ]

      edges = [
        %{from: "start", to: "a"},
        %{from: "a", to: "g", on: :succeeded},
        %{from: "a", to: "f", on: :failed},
        %{from: "g", to: "m", on: :succeeded},
        %{from: "g", to: "f", on: :failed},
        %{from: "f", to: "a", on: :succeeded},
        %{from: "f", to: "m", on: :failed},
        %{from: "m", to: "done", on: :succeeded},
        %{from: "m", to: "needs_input", on: :failed}
      ]

      {changeset, flow} = build(nodes, edges)
      assert changeset.valid?, inspect(changeset.errors)
      %{roles: Flow.node_roles(flow)}
    end

    test "every inbound edge on: :failed → :fix", %{roles: roles} do
      assert roles["f"] == :fix
    end

    test "mixed inbound (one succeeded, one failed) → not :fix", %{roles: roles} do
      assert roles["m"] == :do
    end

    test "a gate → :check", %{roles: roles} do
      assert roles["g"] == :check
    end

    test "an unannotated agent → :do", %{roles: roles} do
      assert roles["a"] == :do
    end

    test "returns a role for every node and nothing else", %{roles: roles} do
      assert Enum.sort(Map.keys(roles)) == ["a", "f", "g", "m"]
    end

    test "the start edge counts as inbound and is never :failed, so the start node is never :fix" do
      # x's only non-start inbound edge is on: :failed — without the start edge it would guess :fix.
      {changeset, flow} =
        build(
          [%{key: "x", type: :agent}, %{key: "y", type: :agent}],
          [
            %{from: "start", to: "x"},
            %{from: "x", to: "y", on: :succeeded},
            %{from: "y", to: "x", on: :failed},
            %{from: "y", to: "done", on: :succeeded}
          ]
        )

      assert changeset.valid?, inspect(changeset.errors)
      assert Flow.node_roles(flow) == %{"x" => :do, "y" => :do}
    end
  end

  describe "node_roles/1 — an authored role always wins" do
    # a: reached only by on: :failed edges, authored :check
    # b: a gate, authored :do
    # c: reached only by a succeeded edge, authored :fix
    setup do
      nodes = [
        %{key: "s", type: :agent},
        %{key: "a", type: :agent, role: :check},
        %{key: "b", type: :gate, role: :do},
        %{key: "c", type: :agent, role: :fix}
      ]

      edges = [
        %{from: "start", to: "s"},
        %{from: "s", to: "a", on: :failed},
        %{from: "s", to: "b", on: :succeeded},
        %{from: "b", to: "c", on: :succeeded},
        %{from: "b", to: "a", on: :failed},
        %{from: "a", to: "s", on: :succeeded},
        %{from: "c", to: "done", on: :succeeded}
      ]

      {changeset, flow} = build(nodes, edges)
      %{changeset: changeset, roles: Flow.node_roles(flow)}
    end

    test "the flow changeset stays valid — an authored role never conflicts", %{changeset: changeset} do
      assert changeset.valid?, inspect(changeset.errors)
    end

    test "role: :check on an all-failed-inbound node → :check", %{roles: roles} do
      assert roles["a"] == :check
    end

    test "role: :do on a gate → :do", %{roles: roles} do
      assert roles["b"] == :do
    end

    test "role: :fix on a node with only succeeded inbound edges → :fix", %{roles: roles} do
      assert roles["c"] == :fix
    end

    test "unannotated nodes are still guessed", %{roles: roles} do
      assert roles["s"] == :do
    end
  end

  defp build(nodes, edges) do
    changeset =
      Flow.changeset(%Flow{board_id: 1}, %{key: "roles", isolation: :shared_clean, nodes: nodes, edges: edges})

    {changeset, Ecto.Changeset.apply_changes(changeset)}
  end
end
