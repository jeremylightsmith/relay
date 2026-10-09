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

  test "note_image_row story covers two images and a single wide image and is indexed (RE427)" do
    src = read("note_image_row.story.exs")

    for id <- ~w(:two_images :single_wide), do: assert(src =~ "id: #{id}", "note_image_row story is missing #{id}")

    assert src =~ "&RelayWeb.CoreComponents.note_image_row/1"
    assert read("_core_components.index.exs") =~ ~s|def entry("note_image_row")|
  end

  test "note_origin_tag story covers both origins and is indexed (RE428)" do
    src = read("note_origin_tag.story.exs")

    for id <- ~w(:from_answer :from_rejection), do: assert(src =~ "id: #{id}", "note_origin_tag story is missing #{id}")

    assert src =~ "&RelayWeb.CoreComponents.note_origin_tag/1"
    assert read("_core_components.index.exs") =~ ~s|def entry("note_origin_tag")|
  end

  test "the review panel and drawer stories show the RE428 image states" do
    assert read("card_review_panel.story.exs") =~ "id: :drawer_reject_with_images"
    assert read("card_drawer.story.exs") =~ "id: :notes_with_origin_tags"
  end

  test "the needs-input panel story shows the RE428 answer images" do
    assert read("needs_input_panel.story.exs") =~ "id: :question_stepper_with_images"
  end

  test "image_attach_box story covers every image-control state and is indexed (RE427)" do
    src = read("image_attach_box.story.exs")

    for id <- ~w(:empty :uploading :with_thumbnails :over_cap :wrong_type :too_large :drag_over) do
      assert src =~ "id: #{id}", "image_attach_box story is missing variation #{id}"
    end

    assert src =~ "&RelayWeb.CoreComponents.image_attach_box/1"

    for name <- ~w(image_attach_box image_attach_button image_attach_hint) do
      assert read("_core_components.index.exs") =~ ~s|def entry("#{name}")|
    end
  end

  test "button story covers the RE394 pending and forced-pressed states" do
    src = read("button.story.exs")
    assert src =~ ~r/id: :pending,.*pending: "Approving…"/s
    assert src =~ ~r/id: :pending_pressed,.*class: "[^"]*phx-click-loading[^"]*"/s

    [_, new_variations] = String.split(src, "id: :pending,", parts: 2)
    refute new_variations =~ ~r/\b(?:bg|text|border)-(?:emerald|slate|gray|zinc|red|green|blue|amber|violet|white|black)/
  end

  test "notification_settings and notification_toast stories cover their states and are indexed (RE399)" do
    settings = read("notification_settings.story.exs")

    for id <- ~w(:default :granted :denied :unsupported) do
      assert settings =~ "id: #{id}", "notification_settings story is missing variation #{id}"
    end

    toast = read("notification_toast.story.exs")

    for id <- ~w(:needs_input :in_review) do
      assert toast =~ "id: #{id}", "notification_toast story is missing variation #{id}"
    end

    refute toast =~ "board_name", "the toast no longer names a board (RE404)"

    index = read("_core_components.index.exs")
    assert index =~ ~s|def entry("notification_settings")|
    assert index =~ ~s|def entry("notification_toast")|
  end
end
