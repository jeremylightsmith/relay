defmodule Relay.VendorWiringTest do
  @moduledoc """
  Guards the wiring of the vendored `dagre_ex` library (RE332). A path dependency is covered by
  none of the root project's `format`, `credo` or `test`, and CI never builds the Dockerfile, so
  each of these can rot silently unless a test pins it.
  """
  use ExUnit.Case, async: true

  @library_precommit "cmd --cd vendor/dagre_ex env MIX_ENV=test mix do deps.get + precommit"

  test "relay depends on dagre_ex by path" do
    assert {:dagre_ex, path: "vendor/dagre_ex"} in Mix.Project.config()[:deps]
  end

  test "the root precommit runs the library's own precommit before the root test step" do
    precommit = Mix.Project.config()[:aliases][:precommit]

    assert @library_precommit in precommit
    assert Enum.find_index(precommit, &(&1 == @library_precommit)) < Enum.find_index(precommit, &(&1 == "test"))
  end

  test "the root formatter leaves vendor/ alone — the library formats itself" do
    refute File.read!(".formatter.exs") =~ "vendor"
    assert File.exists?("vendor/dagre_ex/.formatter.exs")
  end

  test "the Dockerfile copies vendor/ before fetching deps, since path deps resolve from disk" do
    dockerfile = File.read!("Dockerfile")

    assert {copy, _} = :binary.match(dockerfile, "\nCOPY vendor vendor\n")
    assert {fetch, _} = :binary.match(dockerfile, "\nRUN mix deps.get")
    assert copy < fetch
  end
end
