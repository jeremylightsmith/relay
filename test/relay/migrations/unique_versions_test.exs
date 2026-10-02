defmodule Relay.Migrations.UniqueVersionsTest do
  @moduledoc """
  Two branches can each pick the same migration timestamp and merge cleanly (different file
  names), but Ecto refuses to migrate a fresh database with a duplicated version. A long-lived
  dev/test DB that already records the version hides it — Ecto only checks *pending*
  migrations — so the clash first surfaced on main's CI (RE370 vs RE367, 20261001130000).
  Check the files directly so `mix precommit` catches it on any machine.
  """
  use ExUnit.Case, async: true

  test "every migration in priv/repo/migrations has a unique version" do
    duplicates =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.group_by(&(&1 |> String.split("_", parts: 2) |> hd()))
      |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
      |> Map.new()

    assert duplicates == %{},
           "duplicated migration versions (renumber the newer one): #{inspect(duplicates)}"
  end
end
