defmodule Relay.AsyncBoardSlugsTest do
  @moduledoc """
  Guardrail: no two `async: true` test files insert a board with the same literal slug.

  `boards.slug` is unique across the whole table, and each async test's rows sit in an
  uncommitted sandbox transaction. A second insert of the same slug therefore blocks until the
  first test finishes. When two files insert two shared slugs in opposite orders, Postgres
  aborts one of them with `deadlock_detected`. That is how RE402's reverify gate failed: one
  test failed in roughly one of six suite runs. `boards_live_test.exs` created `zeta` and then
  `alpha`, while `all_controller_test.exs` inserted `alpha` and then `zeta`.

  Use `unique_slug/1` (from `Relay.DataCase`, also imported by `RelayWeb.ConnCase`) instead of a
  literal, and assert against the returned `board.slug`.

  The scan is deliberately narrow. It reads the three ways tests put a literal slug in the
  database:
  - `slug: "..."` on an `insert(:board, ...)` line;
  - a slug derived from `Boards.create_board(_, %{name: "..."})` with no explicit slug;
  - a literal third argument to a `*board*(user, "KEY", "slug")` helper, or such a helper's
    `slug \\\\ "..."` default.

  A slug used by only one file is fine: tests inside one module run one at a time.
  """
  use ExUnit.Case, async: true

  test "no literal board slug is shared by two async test files" do
    shared =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == Path.relative_to_cwd(__ENV__.file)))
      |> Enum.filter(&async?/1)
      |> Enum.flat_map(fn file -> file |> literal_slugs() |> Enum.map(&{&1, file}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {slug, files} -> {slug, files |> Enum.uniq() |> Enum.sort()} end)
      |> Map.filter(fn {_slug, files} -> length(files) > 1 end)

    assert shared == %{}, """
    These board slugs are hardcoded in more than one async test file. Concurrent inserts of the
    same slug block each other and can deadlock. Use unique_slug/1 instead:

    #{Enum.map_join(shared, "\n", fn {slug, files} -> "  #{slug}: #{Enum.join(files, ", ")}" end)}
    """
  end

  defp async?(file), do: File.read!(file) =~ ~r/async:\s*true/

  defp literal_slugs(file) do
    source = File.read!(file)

    created =
      for [_, body] <- Regex.scan(~r/create_board\([^,]+,\s*%\{([^}]*)\}/, source),
          not String.contains?(body, "slug:"),
          [_, name] <- ~r/name: "([^"#]+)"/ |> Regex.scan(body) |> Enum.take(1),
          do: slugify(name)

    explicit_create =
      for [_, body] <- Regex.scan(~r/create_board\([^,]+,\s*%\{([^}]*)\}/, source),
          [_, slug] <- Regex.scan(~r/slug: "([^"#]+)"/, body),
          do: slug

    inserted =
      for line <- String.split(source, "\n"),
          line =~ ~r/insert\(:board\b/,
          [_, slug] <- Regex.scan(~r/slug: "([^"#]+)"/, line),
          do: slug

    helper_args =
      for [_, slug] <- Regex.scan(~r/\w*board\w*\([^,()]+,\s*"[^"]*",\s*"([^"#]+)"/, source),
          do: slug

    helper_defaults =
      for [_, slug] <- Regex.scan(~r/defp?\s+\w+\([^)]*slug \\\\ "([^"]+)"/, source), do: slug

    Enum.uniq(created ++ explicit_create ++ inserted ++ helper_args ++ helper_defaults)
  end

  # Mirrors Relay.Boards' private slugify/1, which create_board/2 uses to derive a slug.
  defp slugify(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
      "" -> "board"
      slug -> slug
    end
  end
end
