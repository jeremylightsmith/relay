defmodule Mix.Tasks.Relay.GenVocabTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Relay.GenVocab

  describe "render/1" do
    test "renders a markdown table with a header and one row per vocabulary" do
      table = GenVocab.render([{"Card status", {Schemas.Card, :statuses}}])

      assert table =~ "| Vocabulary | Values | Owner |"
      assert table =~ "| --- | --- | --- |"
      assert table =~ "| Card status |"
      assert table =~ "`ready`"
      assert table =~ "`failed`"
      assert table =~ "`Schemas.Card.statuses/0`"
    end

    test "row order is deterministic regardless of source order" do
      a =
        GenVocab.render([
          {"Run status", {Schemas.Run, :statuses}},
          {"Card status", {Schemas.Card, :statuses}}
        ])

      b =
        GenVocab.render([
          {"Card status", {Schemas.Card, :statuses}},
          {"Run status", {Schemas.Run, :statuses}}
        ])

      assert a == b
    end

    test "every registered vocabulary renders every one of its values" do
      table = GenVocab.render(GenVocab.vocabularies())

      for {label, {module, fun}} <- GenVocab.vocabularies() do
        assert table =~ "| #{label} |", "the table is missing the #{label} row"

        for value <- apply(module, fun, []) do
          assert table =~ "`#{value}`", "#{label} is missing the value `#{value}`"
        end
      end
    end

    test "the registry covers all seven closed sets" do
      labels = GenVocab.vocabularies() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert labels == [
               "Card status",
               "Node outcome",
               "Node-job state",
               "Run parked reason",
               "Run status",
               "Stage category",
               "Stage type"
             ]
    end
  end

  describe "splice/2" do
    test "replaces only the vocabularies block, leaving the run-transitions block alone" do
      doc = """
      # State

      <!-- BEGIN generated: vocabularies -->
      stale vocab
      <!-- END generated: vocabularies -->

      <!-- BEGIN generated: run-transitions -->
      the other generated block
      <!-- END generated: run-transitions -->
      """

      assert {:ok, spliced} = GenVocab.splice(doc, "fresh table")

      assert spliced =~ "fresh table"
      refute spliced =~ "stale vocab"
      assert spliced =~ "the other generated block"
      assert spliced =~ "<!-- BEGIN generated: vocabularies -->"
      assert spliced =~ "<!-- END generated: vocabularies -->"
      assert spliced =~ "<!-- BEGIN generated: run-transitions -->"
    end

    test "returns :error when the markers are absent" do
      assert :error = GenVocab.splice("no markers here", "body")
    end
  end

  describe "the committed state.md is in sync with the schemas (drift gate)" do
    test "the vocabularies block matches what the schemas currently render" do
      doc = File.read!("docs/architecture/state.md")
      {:ok, expected} = GenVocab.splice(doc, GenVocab.render(GenVocab.vocabularies()))

      assert doc == expected,
             "docs/architecture/state.md is out of date — run `mix relay.gen_vocab` and commit the result."
    end
  end
end
