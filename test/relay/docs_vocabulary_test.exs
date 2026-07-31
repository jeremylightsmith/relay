defmodule Relay.DocsVocabularyTest do
  @moduledoc """
  ADR 0008's site carve-out lets a user-facing page restate a closed vocabulary in its own words —
  but not drift from it. Every table that enumerates one is tagged with an HTML comment naming the
  function that owns the set (`<!-- vocab: Schemas.Card.statuses/0 -->`), and this test holds the
  tagged table to that function's values. Prose gets a test; the generated table in `state.md`
  gets `mix relay.gen_vocab`.
  """
  use ExUnit.Case, async: true

  @marker ~r/<!--\s*vocab:\s*([A-Za-z0-9_.]+)\.([a-z_0-9]+)\/0\s*-->/

  # `priv/docs/*.md` is deliberately non-recursive: `priv/docs/architecture` and
  # `priv/docs/runbooks` are symlinks into `docs/`, already covered by the first wildcard.
  defp doc_paths, do: Path.wildcard("docs/**/*.md") ++ Path.wildcard("priv/docs/*.md")

  # {path, module, fun, values listed in the first column of the table after the marker}
  defp tagged_tables do
    for path <- doc_paths(),
        lines = path |> File.read!() |> String.split("\n"),
        {line, index} <- Enum.with_index(lines),
        [_full, module, fun] <- Regex.scan(@marker, line) do
      {path, Module.concat([module]), String.to_atom(fun), table_values(Enum.drop(lines, index + 1))}
    end
  end

  # The first column of the first markdown table after the marker, header + separator dropped.
  defp table_values(lines) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(&normalize/1)
  end

  defp normalize(row) do
    row
    |> String.split("|", trim: true)
    |> List.first("")
    |> String.replace(["`", "*"], "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
  end

  test "the docs carry vocab markers at all" do
    # Without this, a typo'd marker would silently make every assertion below vacuous.
    assert length(tagged_tables()) >= 3,
           "expected at least three `<!-- vocab: … -->` markers across the docs"
  end

  test "every vocab marker names a function that actually exists" do
    for {path, module, fun, _values} <- tagged_tables() do
      assert Code.ensure_loaded?(module), "#{path}: no such module #{inspect(module)}"

      assert function_exported?(module, fun, 0),
             "#{path}: #{inspect(module)}.#{fun}/0 is not exported"
    end
  end

  test "every tagged table lists exactly the values its function owns" do
    for {path, module, fun, listed} <- tagged_tables() do
      expected = module |> apply(fun, []) |> MapSet.new(&to_string/1)
      actual = MapSet.new(listed)

      missing = expected |> MapSet.difference(actual) |> Enum.sort()
      extra = actual |> MapSet.difference(expected) |> Enum.sort()

      assert missing == [],
             "#{path}: the table under `#{inspect(module)}.#{fun}/0` is missing #{inspect(missing)}"

      assert extra == [],
             "#{path}: the table under `#{inspect(module)}.#{fun}/0` lists unknown values #{inspect(extra)}"
    end
  end
end
