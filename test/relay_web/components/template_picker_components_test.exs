defmodule RelayWeb.TemplatePickerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.TemplatePickerComponents

  defp picker(selected) do
    (&TemplatePickerComponents.template_picker/1)
    |> render_component(
      templates: Relay.Boards.templates(),
      selected: selected
    )
    |> LazyHTML.from_fragment()
  end

  defp classes(doc, selector) do
    [class] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
    String.split(class)
  end

  test "12. phone stacks the cards, desktop sets them side by side in a 1080px panel" do
    doc = picker("bare-minimum")

    grid = classes(doc, "#template-picker-grid")
    assert "grid-cols-1" in grid
    assert "md:grid-cols-3" in grid

    assert "sm:max-w-[1080px]" in classes(doc, "#template-picker-panel")

    create = classes(doc, "#template-picker-create")
    assert "btn-primary" in create
    assert "w-full" in create
    assert "sm:w-auto" in create
  end

  test "the selected card carries the primary border and ring, the others a hairline" do
    doc = picker("design-led")

    selected = classes(doc, "#template-card-design-led")
    assert "border-2" in selected
    assert "border-primary" in selected

    [style] = doc |> LazyHTML.query("#template-card-design-led") |> LazyHTML.attribute("style")
    assert style =~ "box-shadow:0 0 0 4px color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100))"

    unselected = classes(doc, "#template-card-bare-minimum")
    assert "border-base-300" in unselected
    assert "m-px" in unselected
    refute "border-primary" in unselected
  end

  test "each radio posts its slug under the name template" do
    doc = picker("bare-minimum")

    for slug <- ~w(bare-minimum design-led three-brain) do
      assert doc |> LazyHTML.query(~s(#template-radio-#{slug}[name="template"][value="#{slug}"])) |> Enum.count() == 1
    end
  end

  test "the stage strip draws each type with the shared 8px stage_type_icon" do
    doc = picker("bare-minimum")

    icons = LazyHTML.query(doc, "#template-stages-bare-minimum .stage-type-icon")
    assert LazyHTML.attribute(icons, "data-type") == ~w(queue planning work review work done)
    assert icons |> LazyHTML.attribute("style") |> Enum.all?(&(&1 =~ "width:8px;height:8px"))
  end

  test "only the templates in examples link to a public example (RE444)" do
    doc =
      (&TemplatePickerComponents.template_picker/1)
      |> render_component(
        templates: Relay.Boards.templates(),
        selected: "bare-minimum",
        examples: %{"three-brain" => "Tiny Dungeon (three-brain)"}
      )
      |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query(~s([id^="template-example-"])) |> LazyHTML.attribute("id") == [
             "template-example-three-brain"
           ]

    assert doc |> LazyHTML.query("#template-example-three-brain") |> LazyHTML.text() =~
             "See the public example: Tiny Dungeon (three-brain)"
  end
end
