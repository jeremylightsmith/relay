defmodule Hamaca.ReleaseExampleTemplatePartsTest do
  @moduledoc "`Hamaca.Release.example_template_parts/1`, behind `prod pull-demo-flows`."
  # Not async: `boards.example_template` is unique (see Hamaca.ExamplesTest).
  use Hamaca.DataCase, async: false

  alias Hamaca.Boards
  alias Hamaca.Examples
  alias Hamaca.Release

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
