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
      assert doc["trigger"] == %{"pulls_from" => "Plan:Done", "works_in" => "Code", "lands_on" => "Review"}
      assert is_list(doc["nodes"])
      assert hd(doc["nodes"])["key"] == "branch"
      assert length(doc["nodes"]) == 18
      assert length(doc["edges"]) == 38
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
      assert node.model == nil
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

    test "keeps the trigger as stage names and allows nulls" do
      {:ok, attrs} = Document.decode(@minimal)
      assert attrs.trigger == %{pulls_from: "Next up", works_in: "Spec", lands_on: nil}
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
end
