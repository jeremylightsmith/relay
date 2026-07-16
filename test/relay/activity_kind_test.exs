defmodule Relay.ActivityKindTest do
  use ExUnit.Case, async: true

  alias Relay.Activity

  # The §03 mapping table. `kind` is DERIVED, never stored — which is what lets
  # every pre-RLY-112 row classify itself with no backfill.
  describe "kind/1" do
    test "runner chatter is :action" do
      assert Activity.kind(%Schemas.Activity{type: :action}) == :action
    end

    test "an agent failure is :failure" do
      assert Activity.kind(%Schemas.Activity{type: :failure}) == :failure
    end

    test "a move is :move" do
      assert Activity.kind(%Schemas.Activity{type: :moved}) == :move
    end

    for type <- [:approved, :rejected, :needs_input, :input_answered] do
      test "#{type} is :decision" do
        assert Activity.kind(%Schemas.Activity{type: unquote(type)}) == :decision
      end
    end

    # The legacy audit types keep rendering exactly as they do today (violet/quiet dots).
    for type <- [:created, :status_changed, :owners_changed, :archived, :unarchived, :commented] do
      test "the legacy #{type} audit row is :action" do
        assert Activity.kind(%Schemas.Activity{type: unquote(type)}) == :action
      end
    end
  end
end
