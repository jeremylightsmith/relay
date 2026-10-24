defmodule Relay.ReleaseExampleTemplatePartsTest do
  @moduledoc "`Relay.Release.example_template_parts/1`, behind `prod pull-demo-flows`."
  # Not async: `boards.example_template` is unique (see Relay.ExamplesTest).
  use Relay.DataCase, async: false

  alias Relay.Boards
  alias Relay.Examples
  alias Relay.Release

  test "returns each named template's example board parts, keyed by slug" do
    Examples.seed!(insert(:user), [])
    {:ok, pantry} = Boards.get_example_board("design-led")
    {:ok, streaks} = Boards.get_example_board("bare-minimum")

    assert Release.example_template_parts(["design-led", "bare-minimum"]) == %{
             "design-led" => Boards.template_parts(pantry),
             "bare-minimum" => Boards.template_parts(streaks)
           }
  end

  test "raises for a template with no example board" do
    assert_raise ArgumentError, ~r/no example board for template "design-led"/, fn ->
      Release.example_template_parts(["design-led"])
    end
  end
end
