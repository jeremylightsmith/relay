defmodule Hamaca.Flows.DocumentTest do
  @moduledoc """
  RLY-241 §1–2. Sparse out, dense in — and `decode ∘ encode` a fixed point, which is what
  makes pull → push unchanged a genuine no-op.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Boards
  alias Hamaca.Flows
  alias Hamaca.Flows.DefaultLibrary
  alias Hamaca.Flows.Document
  alias Schemas.Flow

  @minimal %{
    "key" => "tiny",
    "isolation" => "shared_clean",
    "trigger" => %{"stage" => "Spec"},
    "nodes" => [%{"key" => "a", "type" => "agent", "run" => "/x {ref}"}],
    "edges" => [%{"from" => "start", "to" => "a"}, %{"from" => "a", "to" => "done", "on" => "succeeded"}]
  }

  defp library_board do
    user = insert(:user)
    {:ok, board} = Boards.create_board(user, %{name: "Doc board"})
    board
  end

  defp encoded(board, key), do: board |> Flows.get_flow_with_stages(key) |> Document.encode()

  describe "encode/1" do
    test "emits key, version, enabled, isolation, an ordered node list, and stage NAMES" do
      doc = encoded(library_board(), "code")

      assert doc["key"] == "code"
      assert doc["version"] == 1
      assert doc["enabled"] == false
      assert doc["isolation"] == "exclusive"
      assert doc["trigger"] == %{"stage" => "Code"}
      assert is_list(doc["nodes"])
      assert hd(doc["nodes"])["key"] == "branch"
      assert length(doc["nodes"]) == 21
      assert length(doc["edges"]) == 44
    end

    test "is sparse: nil fields and schema defaults are omitted" do
      doc = encoded(library_board(), "code")
      implement = Enum.find(doc["nodes"], &(&1["key"] == "implement"))
      precommit = Enum.find(doc["nodes"], &(&1["key"] == "precommit"))

      assert implement["expects_commits"] == true
      refute Map.has_key?(precommit, "expects_commits")
      refute Map.has_key?(precommit, "model")
      refute Map.has_key?(precommit, "agent")

      start_edge = Enum.find(doc["edges"], &(&1["from"] == "start"))
      refute Map.has_key?(start_edge, "on")
    end

    test "atoms are emitted as strings" do
      doc = encoded(library_board(), "code")
      assert Enum.find(doc["nodes"], &(&1["key"] == "precommit"))["type"] == "gate"

      guarded = Enum.filter(doc["edges"], &(&1["from"] == "quality_review" and &1["on"] == "succeeded"))
      assert Enum.sort(Enum.map(guarded, & &1["when"])) == ["foreach_exhausted", "foreach_remaining"]
    end

    test "raises rather than silently emitting a triggerless document when stages aren't preloaded" do
      board = library_board()

      assert_raise ArgumentError, ~r/preloaded/, fn ->
        Document.encode(Flows.get_flow!(board, "code"))
      end
    end
  end

  describe "decode/1" do
    test "is dense: every node and edge field is present, absent input filling the schema default" do
      {:ok, attrs} = Document.decode(@minimal)

      [node] = attrs.nodes
      assert Enum.sort(Map.keys(node)) == Enum.sort(Flow.Node.fields())
      assert node.expects_commits == false
      assert node.llm == nil
      refute Map.has_key?(node, :model)
      assert node.max_retries == nil

      assert Enum.all?(attrs.edges, &(Enum.sort(Map.keys(&1)) == Enum.sort(Flow.Edge.fields())))
    end

    # A hand-edited document is this card's headline workflow, and JSON has two ways to say
    # "nothing here". An explicit null that stored nil instead of the schema's `false` would
    # make `customized?/1` read nil != false and flag the flow as customized forever.
    test "is dense: an explicit null fills the schema default too, not just an absent key" do
      nulled = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "expects_commits" => nil}])

      {:ok, attrs} = Document.decode(nulled)

      [node] = attrs.nodes
      assert node.expects_commits == false
    end

    test "converts enums to atoms via the schemas' source functions" do
      {:ok, attrs} = Document.decode(@minimal)
      assert attrs.isolation == :shared_clean
      assert hd(attrs.nodes).type == :agent
      assert Enum.at(attrs.edges, 1).on == :succeeded
      assert hd(attrs.edges).on == nil
    end

    test "reads the trigger's stage" do
      {:ok, attrs} = Document.decode(@minimal)
      assert attrs.trigger == %{stage: "Spec"}
    end

    test "omits key / enabled / version / trigger when the document omits them" do
      {:ok, attrs} = Document.decode(Map.drop(@minimal, ["key", "trigger"]))
      refute Map.has_key?(attrs, :key)
      refute Map.has_key?(attrs, :trigger)
      refute Map.has_key?(attrs, :enabled)
      refute Map.has_key?(attrs, :version)
    end

    test "surfaces key, enabled and version when present" do
      doc = Map.merge(@minimal, %{"enabled" => true, "version" => 7})
      {:ok, attrs} = Document.decode(doc)
      assert attrs.key == "tiny"
      assert attrs.enabled == true
      assert attrs.version == 7
    end

    test "rejects each invalid enum value by name, without minting an atom" do
      assert {:error, msg} = Document.decode(%{@minimal | "isolation" => "sandboxed"})
      assert msg =~ "sandboxed"

      bad_type = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "wizard"}])
      assert {:error, msg} = Document.decode(bad_type)
      assert msg =~ "wizard"

      bad_on = put_in(@minimal, ["edges"], [%{"from" => "a", "to" => "done", "on" => "maybe"}])
      assert {:error, msg} = Document.decode(bad_on)
      assert msg =~ "maybe"

      bad_when = put_in(@minimal, ["edges"], [%{"from" => "a", "to" => "done", "on" => "succeeded", "when" => "later"}])
      assert {:error, msg} = Document.decode(bad_when)
      assert msg =~ "later"

      # RE308: `blocked` is a real outcome, but only the runner reports it and the engine parks
      # on it before any edge is consulted — a flow must not be able to route around that park.
      on_blocked = put_in(@minimal, ["edges"], [%{"from" => "a", "to" => "done", "on" => "blocked"}])
      assert {:error, msg} = Document.decode(on_blocked)
      assert msg =~ ~s(on "blocked")
    end

    test "rejects unknown keys rather than silently dropping a typo" do
      assert {:error, msg} = Document.decode(Map.put(@minimal, "nodez", []))
      assert msg =~ "nodez"

      bad_node = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "retries" => 2}])
      assert {:error, msg} = Document.decode(bad_node)
      assert msg =~ "retries"

      assert {:error, msg} = Document.decode(put_in(@minimal, ["trigger"], %{"from" => "Next up"}))
      assert msg =~ "from"
    end

    test "rejects a document that isn't an object, or whose collections aren't lists" do
      assert {:error, _} = Document.decode("nope")
      assert {:error, msg} = Document.decode(%{@minimal | "nodes" => %{"a" => %{}}})
      assert msg =~ "array"
    end

    test "requires isolation, and requires key/type on a node" do
      assert {:error, msg} = Document.decode(Map.delete(@minimal, "isolation"))
      assert msg =~ "isolation"

      assert {:error, msg} = Document.decode(put_in(@minimal, ["nodes"], [%{"type" => "agent"}]))
      assert msg =~ "key"
    end

    test "decode!/1 raises on an invalid document" do
      assert_raise ArgumentError, fn -> Document.decode!(%{}) end
    end
  end

  describe "the one-stage trigger (RE429)" do
    test "26. encode emits {stage: name} and decode reads it back as a fixed point" do
      doc = encoded(library_board(), "code")
      assert doc["trigger"] == %{"stage" => "Code"}

      assert {:ok, %{trigger: %{stage: "Code"}}} = Document.decode(doc)

      # Re-encoding the decoded trigger reproduces the same document's trigger.
      reencoded = Document.encode(%{Flows.get_flow_with_stages(library_board(), "code") | key: "code"})
      assert reencoded["trigger"] == doc["trigger"]
      assert Document.decode!(reencoded) == Document.decode!(doc)
    end

    test "27. bad trigger keys and values are refused" do
      assert {:error, "unknown trigger key: from"} = Document.decode(%{@minimal | "trigger" => %{"from" => "X"}})

      assert {:error, "trigger.stage must be a stage name or null"} =
               Document.decode(%{@minimal | "trigger" => %{"stage" => 3}})

      assert {:ok, %{trigger: %{stage: nil}}} = Document.decode(%{@minimal | "trigger" => nil})
    end
  end

  # RE429: the API ships a read-only `derived` block beside the document; a pull carries it,
  # so a push must accept it and drop it on the floor.
  describe "the derived block (RE429)" do
    test "28. decode accepts a derived block and drops it from the attrs" do
      doc = Map.put(@minimal, "derived", %{"pulls_from" => "A", "lands_on" => "B"})

      assert {:ok, attrs} = Document.decode(doc)
      refute Map.has_key?(attrs, :derived)
      assert attrs == Document.decode!(@minimal)
    end

    test "29. derived/1 names the flow's worked-out pickup and drop-off stages" do
      flow = %Flow{
        pulls_from_stage: %Schemas.Stage{name: "Plan:Done"},
        lands_on_stage: %Schemas.Stage{name: "Code:Done"}
      }

      assert Document.derived(flow) == %{"pulls_from" => "Plan:Done", "lands_on" => "Code:Done"}
    end

    test "30. derived/1 is nil at either end of the board" do
      assert Document.derived(%Flow{pulls_from_stage: nil, lands_on_stage: nil}) ==
               %{"pulls_from" => nil, "lands_on" => nil}
    end

    test "31. encode/1 never emits derived — it stays the canonical document" do
      refute Map.has_key?(encoded(library_board(), "code"), "derived")
    end

    # RE430: the API puts the read-only `problem` beside the document too.
    test "a pulled document carrying derived and problem decodes, dropping problem" do
      doc = Map.put(encoded(library_board(), "code"), "derived", %{"pulls_from" => "A", "lands_on" => "B"})

      for problem <- [nil, %{"kind" => "no_upstream"}] do
        assert {:ok, attrs} = Document.decode(Map.put(doc, "problem", problem))
        refute Map.has_key?(attrs, :problem)
      end
    end

    test "encode/1 never emits problem" do
      refute Map.has_key?(encoded(library_board(), "code"), "problem")
    end
  end

  describe "the fixed point" do
    test "decode(encode(flow)) equals the shipped library's definition attrs, for all three flows" do
      board = library_board()
      library = Map.new(DefaultLibrary.all(), &{&1.key, &1})

      for key <- ~w(spec plan code) do
        round_tripped =
          board
          |> Flows.get_flow_with_stages(key)
          |> Document.encode()
          |> Document.decode!()
          |> Map.drop([:version, :enabled])

        assert round_tripped == Map.fetch!(library, key),
               "#{key} did not survive encode → decode unchanged"
      end
    end
  end

  describe "the card contract (RE244)" do
    test "encodes as string lists and omits an empty contract" do
      spec = encoded(library_board(), "spec")
      brainstorm = Enum.find(spec["nodes"], &(&1["key"] == "brainstorm"))

      assert brainstorm["reads"] == ["description"]
      assert brainstorm["writes"] == ["spec", "acceptance_criteria"]

      code = encoded(library_board(), "code")
      precommit = Enum.find(code["nodes"], &(&1["key"] == "precommit"))
      refute Map.has_key?(precommit, "reads")
      refute Map.has_key?(precommit, "writes")
    end

    test "decodes field names to atoms through the card vocabulary" do
      doc =
        put_in(@minimal, ["nodes"], [
          %{"key" => "a", "type" => "agent", "reads" => ["spec"], "writes" => ["plan"]}
        ])

      assert {:ok, attrs} = Document.decode(doc)
      assert [%{reads: [:spec], writes: [:plan]}] = attrs.nodes
    end

    test "a node may declare mockups; a misspelling is refused (RE370)" do
      ok =
        put_in(@minimal, ["nodes"], [
          %{"key" => "design", "type" => "agent", "writes" => ["mockups"], "reads" => ["mockups"]}
        ])

      assert {:ok, %{nodes: [%{reads: [:mockups], writes: [:mockups]}]}} = Document.decode(ok)

      typo = put_in(@minimal, ["nodes"], [%{"key" => "design", "type" => "agent", "writes" => ["mockupz"]}])
      assert {:error, msg} = Document.decode(typo)
      assert msg =~ "mockupz"
    end

    test "an unknown contract field is an error naming it, never a minted atom" do
      doc =
        put_in(@minimal, ["nodes"], [
          %{"key" => "a", "type" => "agent", "writes" => ["nonsense_field"]}
        ])

      assert {:error, msg} = Document.decode(doc)
      assert msg =~ "nonsense_field"
    end

    # Both "absent" and "explicit null" must land on the schema default, or a sparse library
    # map compares unequal to the dense struct and customized?/1 flags the flow forever.
    test "an absent or null contract decodes to []" do
      absent = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent"}])
      assert {:ok, %{nodes: [%{reads: [], writes: []}]}} = Document.decode(absent)

      nulled = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "reads" => nil}])
      assert {:ok, %{nodes: [%{reads: [], writes: []}]}} = Document.decode(nulled)
    end

    test "a non-list contract is rejected" do
      doc = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "reads" => "spec"}])
      assert {:error, msg} = Document.decode(doc)
      assert msg =~ "reads must be an array"
    end
  end

  describe "node role (RE346)" do
    @roles_doc %{
      "key" => "roles",
      "isolation" => "shared_clean",
      "nodes" => [
        %{"key" => "a", "type" => "agent", "role" => "do"},
        %{"key" => "b", "type" => "agent", "role" => "check"},
        %{"key" => "c", "type" => "agent", "role" => "fix"},
        %{"key" => "d", "type" => "agent"}
      ],
      "edges" => [
        %{"from" => "start", "to" => "a"},
        %{"from" => "a", "to" => "b", "on" => "succeeded"},
        %{"from" => "b", "to" => "c", "on" => "succeeded"},
        %{"from" => "c", "to" => "d", "on" => "succeeded"},
        %{"from" => "d", "to" => "done", "on" => "succeeded"}
      ]
    }

    test "decodes every role to an atom through Schemas.Flow.Node.roles/0" do
      assert {:ok, attrs} = Document.decode(@roles_doc)
      assert Enum.map(attrs.nodes, & &1.role) == [:do, :check, :fix, nil]
    end

    test "an absent or null role decodes to nil" do
      nulled = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "role" => nil}])
      assert {:ok, %{nodes: [%{role: nil}]}} = Document.decode(nulled)
      assert {:ok, %{nodes: [%{role: nil}]}} = Document.decode(@minimal)
    end

    test "a junk role is an error naming it, never a minted atom" do
      bad = put_in(@minimal, ["nodes"], [%{"key" => "a", "type" => "agent", "role" => "review"}])
      assert {:error, msg} = Document.decode(bad)
      assert msg =~ ~s(role "review")
    end

    test "encode emits an authored role as a string and omits an unset one" do
      flow = %Flow{
        key: "roles",
        version: 1,
        enabled: false,
        isolation: :shared_clean,
        stage: nil,
        nodes: [
          %Flow.Node{key: "a", type: :agent, role: :check},
          %Flow.Node{key: "b", type: :agent, role: :fix},
          %Flow.Node{key: "c", type: :agent}
        ],
        edges: []
      }

      doc = Document.encode(flow)
      assert Enum.map(doc["nodes"], &Map.get(&1, "role")) == ["check", "fix", nil]
      refute Map.has_key?(Enum.at(doc["nodes"], 2), "role")

      assert doc |> Document.decode!() |> Map.fetch!(:nodes) |> Enum.map(& &1.role) == [:check, :fix, nil]
    end

    test "import keeps every authored role, and export → re-import preserves them" do
      board = library_board()

      # Deploy is the default board's one flow-free work stage (RE429: one flow per stage).
      roles_doc = Map.put(@roles_doc, "trigger", %{"stage" => "Deploy"})
      assert {:ok, :created, _flow} = Flows.upsert_from_document(board, "roles", roles_doc)

      exported = encoded(board, "roles")
      assert Enum.map(exported["nodes"], &Map.get(&1, "role")) == ["do", "check", "fix", nil]
      refute Map.has_key?(Enum.at(exported["nodes"], 3), "role")

      assert {:ok, :updated, reimported} =
               Flows.upsert_from_document(board, "roles", Map.drop(exported, ["version", "enabled"]))

      assert Enum.map(reimported.nodes, & &1.role) == [:do, :check, :fix, nil]
    end

    test "importing a junk role is rejected with an error on role" do
      bad = put_in(@roles_doc, ["nodes"], [%{"key" => "a", "type" => "agent", "role" => "review"}])

      assert {:error, {:invalid_document, msg}} =
               Flows.upsert_from_document(library_board(), "roles", bad)

      assert msg =~ ~s(role "review")
    end
  end

  # RE487: a renamed spelling is refused with a message naming old → canonical, never rewritten.
  describe "renamed spellings are refused" do
    defp decode_node(node), do: Document.decode(%{@minimal | "nodes" => [node]})
    defp decode_trigger(trigger), do: Document.decode(%{@minimal | "trigger" => trigger})

    # Scenario 3
    test "a node model names its rename to llm" do
      assert Document.decode(%{@minimal | "nodes" => [%{"key" => "a", "type" => "agent", "model" => "opus"}]}) ==
               {:error, ~s|nodes[0]: node field "model" was renamed to "llm" (an agent name, e.g. "Claude Opus")|}
    end

    # Scenario 4
    test "sub_tasks in reads or writes names its rename to tasks" do
      assert decode_node(%{"key" => "a", "type" => "agent", "reads" => ["sub_tasks"]}) ==
               {:error, ~s(nodes[0]: "sub_tasks" in reads was renamed to "tasks")}

      assert decode_node(%{"key" => "a", "type" => "agent", "writes" => ["plan", "sub_tasks"]}) ==
               {:error, ~s(nodes[0]: "sub_tasks" in writes was renamed to "tasks")}
    end

    # Scenario 5
    test "a card.sub_tasks foreach names its rename to card.tasks" do
      assert decode_node(%{"key" => "a", "type" => "agent", "foreach" => "card.sub_tasks"}) ==
               {:error, ~s(nodes[0]: foreach "card.sub_tasks" was renamed to "card.tasks")}
    end

    # Scenario 6
    test "an exact-brace sub_task placeholder in run names its rename" do
      assert decode_node(%{"key" => "a", "type" => "agent", "run" => "show {sub_task_id}"}) ==
               {:error, ~s(nodes[0]: run placeholder "{sub_task_id}" was renamed to "{task_id}")}

      assert decode_node(%{"key" => "a", "type" => "agent", "run" => "show {sub_task}"}) ==
               {:error, ~s(nodes[0]: run placeholder "{sub_task}" was renamed to "{task}")}
    end

    test "sub_tasks in run prose is not a placeholder, so it decodes" do
      assert {:ok, _attrs} = decode_node(%{"key" => "a", "type" => "agent", "run" => "the sub_tasks table"})
    end

    # Scenario 7
    test "a parallel node type names its rename to fan_out" do
      assert decode_node(%{"key" => "a", "type" => "parallel"}) ==
               {:error, ~s(nodes[0]: node type "parallel" was renamed to "fan_out")}
    end

    # Scenario 8
    test "a works_in trigger names its rename to stage" do
      assert decode_trigger(%{"works_in" => "Code"}) == {:error, ~s(trigger key "works_in" was renamed to "stage")}
    end

    test "a pulls_from or lands_on trigger key is refused as removed" do
      assert decode_trigger(%{"stage" => "Code", "pulls_from" => "X"}) ==
               {:error, ~s(trigger key "pulls_from" was removed — pickup is derived from board order; use "stage")}

      assert decode_trigger(%{"stage" => "Code", "lands_on" => "Y"}) ==
               {:error, ~s(trigger key "lands_on" was removed — drop-off is derived from board order; use "stage")}
    end

    test "a stage-only trigger decodes" do
      assert {:ok, %{trigger: %{stage: "Code"}}} = decode_trigger(%{"stage" => "Code"})
    end

    test "encode emits llm and never model" do
      nodes = encoded(library_board(), "code")["nodes"]

      assert Enum.find(nodes, &(&1["key"] == "implement"))["llm"] == "Claude Opus"
      refute Enum.any?(nodes, &Map.has_key?(&1, "model"))
    end
  end

  # RE437: a fan_out panel round-trips through the document.
  describe "fan_out panel (RE437)" do
    defp string_keyed(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), json_scalar(v)} end)
    defp json_scalar(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
    defp json_scalar(v), do: v

    defp panel_doc(nodes) do
      %{
        "key" => "panel",
        "isolation" => "shared_clean",
        "trigger" => %{"stage" => "Deploy"},
        "nodes" => Enum.map(nodes, &string_keyed/1),
        "edges" => Enum.map(Hamaca.FanOutFixtures.panel_edges(), &string_keyed/1)
      }
    end

    test "a saved panel encodes fan_out, with max_parallel only when set" do
      board = library_board()

      assert {:ok, :created, _flow} =
               Flows.upsert_from_document(board, "panel", panel_doc(Hamaca.FanOutFixtures.panel_nodes()))

      nodes = encoded(board, "panel")["nodes"]

      assert Enum.find(nodes, &(&1["key"] == "fo")) == %{"key" => "fo", "type" => "fan_out"}
      refute Enum.any?(nodes, &Map.has_key?(&1, "max_parallel"))

      capped = Hamaca.FanOutFixtures.put_node(Hamaca.FanOutFixtures.panel_nodes(), "fo", %{max_parallel: 2})
      assert {:ok, :updated, _flow} = Flows.upsert_from_document(board, "panel", panel_doc(capped))

      assert %{"type" => "fan_out", "max_parallel" => 2} =
               Enum.find(encoded(board, "panel")["nodes"], &(&1["key"] == "fo"))
    end

    test "decode ∘ encode of the panel is a fixed point" do
      board = library_board()

      assert {:ok, :created, _flow} =
               Flows.upsert_from_document(board, "panel", panel_doc(Hamaca.FanOutFixtures.panel_nodes()))

      once = encoded(board, "panel")
      assert {:ok, _tag, _flow} = Flows.upsert_from_document(board, "panel", once)
      twice = encoded(board, "panel")

      assert twice |> Document.decode!() |> Map.delete(:version) == once |> Document.decode!() |> Map.delete(:version)
      assert Map.delete(twice, "version") == Map.delete(once, "version")
    end
  end
end
