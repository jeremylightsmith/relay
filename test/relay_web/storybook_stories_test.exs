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

  test "board_card story renders a busiest meta-row variant at real lane width (RE321)" do
    src = read("board_card.story.exs")
    assert src =~ "id: :busiest_meta_row"
    assert src =~ "blocked_count: 3"
    assert src =~ "vote_count: 12"
    assert src =~ "category: :unstarted"
    assert src =~ ~s(style="width:214px;")
    assert src =~ "<.psb-variation/>"
  end

  test "plan_tasks story covers the RE356 states and is indexed" do
    src = read("plan_tasks.story.exs")

    for id <- ~w(:collapsed :in_flight_open :long_body_clamped :clamp_released :done_task :body_less :empty) do
      assert src =~ "id: #{id}", "plan_tasks story is missing variation #{id}"
    end

    assert src =~ "&RelayWeb.CoreComponents.plan_tasks/1"
    assert read("_core_components.index.exs") =~ ~s|def entry("plan_tasks")|
  end

  test "button story covers the RE394 pending and forced-pressed states" do
    src = read("button.story.exs")
    assert src =~ ~r/id: :pending,.*pending: "Approving…"/s
    assert src =~ ~r/id: :pending_pressed,.*class: "[^"]*phx-click-loading[^"]*"/s

    [_, new_variations] = String.split(src, "id: :pending,", parts: 2)
    refute new_variations =~ ~r/\b(?:bg|text|border)-(?:emerald|slate|gray|zinc|red|green|blue|amber|violet|white|black)/
  end
end
