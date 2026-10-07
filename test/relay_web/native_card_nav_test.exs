defmodule RelayWeb.NativeCardNavTest do
  use ExUnit.Case, async: true

  alias RelayWeb.NativeCardNav

  describe "parse/1" do
    test "both directions" do
      assert NativeCardNav.parse(%{"nav" => "prev,next"}) == %{prev?: true, next?: true}
    end

    test "one direction" do
      assert NativeCardNav.parse(%{"nav" => "next"}) == %{prev?: false, next?: true}
    end

    test "trims tokens and ignores unknown ones" do
      assert NativeCardNav.parse(%{"nav" => " prev , bogus"}) == %{prev?: true, next?: false}
    end

    test "no known token is nil" do
      assert NativeCardNav.parse(%{"nav" => "bogus"}) == nil
    end

    test "blank is nil" do
      assert NativeCardNav.parse(%{"nav" => ""}) == nil
    end

    test "absent is nil" do
      assert NativeCardNav.parse(%{}) == nil
    end

    test "a non-binary value is nil" do
      assert NativeCardNav.parse(%{"nav" => ["prev"]}) == nil
    end
  end

  describe "to_param/1" do
    test "both directions in directions/0 order" do
      assert NativeCardNav.to_param(%{prev?: true, next?: true}) == [nav: "prev,next"]
    end

    test "only the true directions" do
      assert NativeCardNav.to_param(%{prev?: false, next?: true}) == [nav: "next"]
    end

    test "nil is no param" do
      assert NativeCardNav.to_param(nil) == []
    end
  end

  test "the bridge handler name and direction tokens" do
    assert NativeCardNav.handler() == "relayCardNav"
    assert NativeCardNav.directions() == ["prev", "next"]
  end
end
