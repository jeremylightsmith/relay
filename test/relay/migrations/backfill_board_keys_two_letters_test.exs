Code.require_file("priv/repo/migrations/20260722173857_backfill_board_keys_two_letters.exs")

defmodule Relay.Migrations.BackfillBoardKeysTwoLettersTest do
  use ExUnit.Case, async: true

  alias Relay.Repo.Migrations.BackfillBoardKeysTwoLetters, as: Migration

  test "derives the first two letters of the name, uppercased" do
    assert Migration.derive_key("My board") == "MY"
    assert Migration.derive_key("payments") == "PA"
  end

  test "falls back to RL when the name yields fewer than two letters" do
    assert Migration.derive_key("7!") == "RL"
    assert Migration.derive_key("") == "RL"
    assert Migration.derive_key("X") == "RL"
  end
end
