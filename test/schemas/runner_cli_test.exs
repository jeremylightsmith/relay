defmodule Schemas.RunnerCliTest do
  @moduledoc """
  RE486: the CLI name a runner reports (`runner.cli`, sent since RE478) is a closed set defined
  once on `Schemas.Runner`, and its normalizer degrades anything else to nil without raising.
  """
  use ExUnit.Case, async: true

  alias Schemas.Runner

  describe "normalize_cli/1" do
    test "keeps a known CLI name" do
      assert Runner.normalize_cli("hamaca") == "hamaca"
      assert Runner.normalize_cli("relay") == "relay"
    end

    test "degrades nil, unknown strings and non-strings to nil without raising" do
      assert Runner.normalize_cli(nil) == nil
      assert Runner.normalize_cli("bogus") == nil
      assert Runner.normalize_cli(7) == nil
      assert Runner.normalize_cli(%{"x" => 1}) == nil
    end
  end

  describe "cli_names/0" do
    test "is the closed set, hamaca first" do
      assert Runner.cli_names() == ["hamaca", "relay"]
    end
  end
end
