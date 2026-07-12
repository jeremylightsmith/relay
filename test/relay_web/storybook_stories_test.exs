defmodule RelayWeb.StorybookStoriesTest do
  use ExUnit.Case, async: true

  @dir Path.expand("../../storybook/core_components", __DIR__)

  defp read(name), do: File.read!(Path.join(@dir, name))

  test "every core_components story file parses" do
    for path <- Path.wildcard(Path.join(@dir, "*.story.exs")) do
      assert {:ok, _ast} = Code.string_to_quoted(File.read!(path)), "failed to parse #{path}"
    end
  end

  test "boxed_field story covers the new RLY-58 states" do
    src = read("boxed_field.story.exs")
    assert src =~ ":self_collapsed_preview"
    assert src =~ ":self_expanded_read"
    assert src =~ "collapsible: true"
    assert src =~ "accent: :primary"
    assert src =~ "toggle_event:"
  end

  test "a Controls gallery page story exists and is indexed" do
    controls = read("controls.story.exs")
    assert controls =~ "use PhoenixStorybook.Story, :page"
    assert controls =~ "Hand to AI"
    assert controls =~ "toggle toggle-primary"
    assert controls =~ "join"
    assert read("_core_components.index.exs") =~ ~s|def entry("controls")|
  end
end
