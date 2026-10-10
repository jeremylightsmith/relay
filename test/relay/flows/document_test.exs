defmodule Relay.Flows.DocumentTest do
  @moduledoc """
  RLY-241 §1–2. Sparse out, dense in — and `decode ∘ encode` a fixed point, which is what
  makes pull → push unchanged a genuine no-op.
  """
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Flows.DefaultLibrary
  alias Relay.Flows.Document
  alias Schemas.Flow

  @minimal %{
    "key" => "tiny",
    "isolation" => "shared_clean",
    "trigger" => %{"pulls_from" => "Next up", "works_in" => "Spec", "lands_on" => nil},
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

    test "reads a legacy three-key trigger's works_in as the stage" do
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

    test "27. legacy triggers read works_in; stage wins; bad keys and values are refused" do
      legacy = %{"pulls_from" => "X", "works_in" => "Code", "lands_on" => "Y"}
      assert {:ok, %{trigger: %{stage: "Code"}}} = Document.decode(%{@minimal | "trigger" => legacy})

      both = %{"stage" => "Deploy", "works_in" => "Code"}
      assert {:ok, %{trigger: %{stage: "Deploy"}}} = Document.decode(%{@minimal | "trigger" => both})

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

  describe "legacy sub_tasks spellings (RE367)" do
    @legacy_node %{
      "key" => "a",
      "type" => "agent",
      "run" => "work {sub_task} ({sub_task_id})",
      "foreach" => "card.sub_tasks",
      "reads" => ["sub_tasks"],
      "writes" => ["plan", "sub_tasks"]
    }

    test "decode/1 normalizes every legacy alias to canonical" do
      assert {:ok, %{nodes: [node]}} = Document.decode(Map.put(@minimal, "nodes", [@legacy_node]))

      assert node.foreach == "card.tasks"
      assert node.reads == [:tasks]
      assert node.writes == [:plan, :tasks]
      assert node.run == "work {task} ({task_id})"
    end

    test "a legacy document, saved, encodes back canonical" do
      board = library_board()
      doc = @minimal |> Map.put("nodes", [@legacy_node]) |> Map.put("trigger", %{"stage" => "Deploy"})

      assert {:ok, :created, _flow} = Flows.upsert_from_document(board, "tiny", doc)

      encoded = encoded(board, "tiny")
      refute Jason.encode!(encoded) =~ "sub_task"

      assert [%{"foreach" => "card.tasks", "reads" => ["tasks"], "writes" => ["plan", "tasks"], "run" => run}] =
               encoded["nodes"]

      assert run == "work {task} ({task_id})"
    end
  end

  describe "legacy node model → llm (RE433)" do
    defp decoded_node(node) do
      {:ok, attrs} = Document.decode(put_in(@minimal, ["nodes"], [node]))
      hd(attrs.nodes)
    end

    # Scenario 13
    test "a pushed model is renamed to llm through the legacy table" do
      node = decoded_node(%{"key" => "a", "type" => "agent", "model" => "sonnet"})

      assert node.llm == "Claude Sonnet"
      refute Map.has_key?(node, :model)
    end

    test "encode emits llm and never model" do
      nodes = encoded(library_board(), "code")["nodes"]

      assert Enum.find(nodes, &(&1["key"] == "implement"))["llm"] == "Claude Opus"
      refute Enum.any?(nodes, &Map.has_key?(&1, "model"))
    end

    # Scenario 14
    test "an explicit llm wins over a legacy model" do
      assert decoded_node(%{"key" => "a", "type" => "agent", "model" => "opus", "llm" => "Codex GPT"}).llm == "Codex GPT"
    end

    test "a model outside the table is carried through verbatim, for validation to refuse" do
      assert decoded_node(%{"key" => "a", "type" => "agent", "model" => "gpt-4"}).llm == "gpt-4"
    end
  end
end
