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

    assert "md:col-span-3" in classes(doc, "#template-card-copy")

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

  test "two templates stretch across two columns, the copy card spanning both" do
    doc =
      (&TemplatePickerComponents.template_picker/1)
      |> render_component(templates: Relay.Boards.offered_templates(), selected: "bare-minimum")
      |> LazyHTML.from_fragment()

    grid = classes(doc, "#template-picker-grid")
    assert "md:grid-cols-2" in grid
    refute "md:grid-cols-3" in grid

    copy = classes(doc, "#template-card-copy")
    assert "md:col-span-2" in copy
    refute "md:col-span-3" in copy
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

  # RE447 — the 4th option, "Copy from a board I have access to".

  @relay %{slug: "relay", name: "Relay", key: "RE", stages: 9, flows: 4, files: []}
  @acme %{slug: "acme", name: "Acme web", key: "ACM", stages: 7, flows: 3, files: []}

  defp copy_picker(attrs) do
    (&TemplatePickerComponents.template_picker/1)
    |> render_component(
      Keyword.merge([templates: Relay.Boards.templates(), selected: TemplatePickerComponents.copy_option()], attrs)
    )
    |> LazyHTML.from_fragment()
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  defp present?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count() == 1

  defp files(names), do: Enum.map(names, &%{kind: :agent, name: &1, paths: [".claude/agents/#{&1}.md"], used_by: []})

  @nine ~w(plan-implementer spec-reviewer quality-reviewer final-fixer rebaser smoke-tester acceptance-tester final-reviewer ci-fixer)

  test "RE447 1. the copy card renders unselected beneath the templates, without its source list" do
    doc = copy_picker(selected: "bare-minimum", copy_sources: [])

    card = classes(doc, "#template-card-copy")
    assert "md:col-span-3" in card
    assert "border-base-300" in card
    refute "border-primary" in card

    card_text = text(doc, "#template-card-copy")
    assert card_text =~ "Copy from a board I have access to"
    assert card_text =~ "Same stages and flows as one of your boards."

    assert card_text =~
             "A plain copy: stages, flows and WIP limits, no cards. It doesn't remember where it came from and never picks up later changes."

    refute present?(doc, "#template-copy-search")

    assert TemplatePickerComponents.copy_option() == "copy"

    assert doc |> LazyHTML.query("#template-radio-copy") |> LazyHTML.attribute("value") == [
             TemplatePickerComponents.copy_option()
           ]

    assert doc |> LazyHTML.query("#template-radio-copy") |> LazyHTML.attribute("name") == ["template"]
  end

  test "RE447 2. selected, the copy card lists the sources and the button names the chosen one" do
    doc = copy_picker(copy_from: "relay", copy_sources: [@relay, @acme])

    card = classes(doc, "#template-card-copy")
    assert "border-2" in card
    assert "border-primary" in card

    assert "bg-base-200" in classes(doc, "#copy-source-relay")
    refute "bg-base-200" in classes(doc, "#copy-source-acme")

    relay_text = text(doc, "#copy-source-relay")
    assert relay_text =~ "Relay"
    assert relay_text =~ "RE"
    assert relay_text =~ "9 stages · 4 flows"
    assert text(doc, "#copy-source-acme") =~ "7 stages · 3 flows"

    assert present?(doc, ~s(#copy-source-radio-relay[name="copy_from"][value="relay"][checked]))
    refute present?(doc, "#copy-source-radio-acme[checked]")

    assert text(doc, "#template-picker-create .pending-idle") == "Copy Relay"
    refute present?(doc, "#template-copy-warning")
  end

  test "RE447 3. a source whose flows name repo files warns with the first five names and +N more" do
    doc = copy_picker(copy_from: "relay", copy_sources: [%{@relay | files: files(@nine)}, @acme])

    warning = text(doc, "#template-copy-warning")
    assert warning =~ "Relay's flows name 9 files that live in its repo, not on the board."
    assert warning =~ "stub it, inline it into the flow, or drop the node"

    assert text(doc, "#template-copy-warning-files") ==
             "plan-implementer · spec-reviewer · quality-reviewer · final-fixer · rebaser · +4 more"
  end

  test "RE447 4. one file reads singular; exactly five lists all five with no +0 more" do
    one = copy_picker(copy_from: "relay", copy_sources: [%{@relay | files: files(["plan-implementer"])}])

    assert text(one, "#template-copy-warning") =~ "Relay's flows name 1 file that lives in its repo, not on the board."
    assert text(one, "#template-copy-warning-files") == "plan-implementer"

    five = copy_picker(copy_from: "relay", copy_sources: [%{@relay | files: files(Enum.take(@nine, 5))}])

    assert text(five, "#template-copy-warning-files") ==
             "plan-implementer · spec-reviewer · quality-reviewer · final-fixer · rebaser"
  end

  test "RE447 5. the search filters sources by name or key, case-insensitively" do
    ac = copy_picker(copy_from: "relay", copy_query: "ac", copy_sources: [@relay, @acme])
    assert present?(ac, "#copy-source-acme")
    refute present?(ac, "#copy-source-relay")

    re = copy_picker(copy_from: "relay", copy_query: "re", copy_sources: [@relay, @acme])
    assert present?(re, "#copy-source-relay")
    refute present?(re, "#copy-source-acme")

    none = copy_picker(copy_from: "relay", copy_query: "zzz", copy_sources: [@relay, @acme])
    refute present?(none, "#copy-source-relay")
    refute present?(none, "#copy-source-acme")
    assert text(none, "#template-copy-empty") == "No boards match."

    assert present?(re, ~s(#template-copy-search[name="copy_query"][value="re"][placeholder="Search your boards…"]))
  end

  test "RE447 smoke: many sources scroll inside a capped list, and the panel wraps its content" do
    many = for i <- 1..250, do: %{@acme | slug: "board-#{i}", name: "Board #{i}", key: "B#{i}"}
    doc = copy_picker(copy_from: "board-1", copy_sources: [%{hd(many) | files: files(@nine)} | tl(many)])

    list = classes(doc, "#template-copy-list")
    assert "max-h-[240px]" in list
    assert "overflow-y-auto" in list

    # The panel is a flex child of the scrolling max-h-screen wrapper: it must
    # size to its content (not stretch to, and stop at, the viewport).
    panel = classes(doc, "#template-picker-panel")
    assert "self-start" in panel
    assert "shrink-0" in panel

    assert present?(doc, "#template-copy-warning")
  end

  test "RE447 6. with no boards to copy, the button is disabled and names no board" do
    doc = copy_picker(copy_from: nil, copy_sources: [])

    assert present?(doc, "#template-picker-create[disabled]")
    assert text(doc, "#template-picker-create .pending-idle") == "Copy a board"
  end

  # RE455 — board name + card key, required, at the top of the picker (card mockup A).

  defp identity_picker(attrs) do
    (&TemplatePickerComponents.template_picker/1)
    |> render_component(Keyword.merge([templates: Relay.Boards.templates(), selected: "bare-minimum"], attrs))
    |> LazyHTML.from_fragment()
  end

  defp squish(doc, selector), do: doc |> text(selector) |> String.split() |> Enum.join(" ")
  defp attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "RE455 4. empty, the identity row sits above Start from and the grid, and Create is disabled" do
    doc = identity_picker(name: "", key: "", show_required: false)

    assert present?(doc, "#template-picker-identity ~ #template-picker-start-from ~ #template-picker-grid")
    assert text(doc, "#template-picker-start-from") == "Start from"

    name = classes(doc, "#template-picker-name")
    for c <- ~w(input input-sm w-full bg-base-100), do: assert(c in name)
    assert attr(doc, "#template-picker-name", "maxlength") == ["80"]
    assert attr(doc, "#template-picker-name", "name") == ["name"]

    key = classes(doc, "#template-picker-key")
    for c <- ~w(font-mono uppercase tracking-[0.15em]), do: assert(c in key)
    refute "input-error" in key
    assert attr(doc, "#template-picker-key", "maxlength") == ["2"]
    assert attr(doc, "#template-picker-key", "autocapitalize") == ["characters"]
    assert attr(doc, "#template-picker-key", "phx-hook") == ["CardKeyInput"]
    assert attr(doc, "#template-picker-key", "name") == ["key"]

    assert text(doc, "#template-picker-key-hint") == "2 letters · A–Z"
    assert "text-base-content/50" in classes(doc, "#template-picker-key-hint")

    refute present?(doc, "#template-picker-key-preview")
    refute present?(doc, "#template-picker-name-hint")
    assert present?(doc, "#template-picker-create[disabled]")

    assert squish(doc, "#template-picker-title + p") =~
             ~r/^Name it, pick its card key, then start from a template or copy a board\./
  end

  test "RE455 5. a name and a complete key preview the refs and enable Create <name>" do
    doc = identity_picker(name: "Acme Checkout", key: "AC")

    assert squish(doc, "#template-picker-key-preview") == "Cards will be AC1, AC2, AC3…"

    span = LazyHTML.query(doc, "#template-picker-key-preview span.font-mono")
    assert String.trim(LazyHTML.text(span)) == "AC1, AC2, AC3…"
    assert "text-base-content/80" in (span |> LazyHTML.attribute("class") |> hd() |> String.split())

    assert text(doc, "#template-picker-create .pending-idle") == "Create Acme Checkout"
    refute present?(doc, "#template-picker-create[disabled]")
  end

  test "RE455 5b. a blank name labels the button Create board" do
    doc = identity_picker(name: "  ", key: "AC")

    assert text(doc, "#template-picker-create .pending-idle") == "Create board"
    assert present?(doc, "#template-picker-create[disabled]")
  end

  test "RE455 6. a one-letter key reads Needs 2 letters in error and keeps Create disabled" do
    doc = identity_picker(name: "Acme Checkout", key: "A")

    assert text(doc, "#template-picker-key-hint") == "Needs 2 letters"
    assert "text-error" in classes(doc, "#template-picker-key-hint")
    assert "input-error" in classes(doc, "#template-picker-key")
    refute present?(doc, "#template-picker-key-preview")
    assert present?(doc, "#template-picker-create[disabled]")
  end

  test "RE455 7. copy with show_required and empty fields flags both and keeps Copy <source> disabled" do
    doc =
      copy_picker(copy_from: "relay", copy_sources: [@relay], name: "", key: "", show_required: true)

    assert text(doc, "#template-picker-name-hint") == "Required"
    assert "text-error" in classes(doc, "#template-picker-name-hint")
    assert "input-error" in classes(doc, "#template-picker-name")
    assert text(doc, "#template-picker-key-hint") == "Needs 2 letters"
    assert text(doc, "#template-picker-create .pending-idle") == "Copy Relay"
    assert present?(doc, "#template-picker-create[disabled]")

    filled = copy_picker(copy_from: "relay", copy_sources: [@relay], name: "Copy Test", key: "CT")
    refute present?(filled, "#template-picker-create[disabled]")
    assert text(filled, "#template-picker-create .pending-idle") == "Copy Relay"

    none = copy_picker(copy_from: nil, copy_sources: [], name: "Copy Test", key: "CT")
    assert text(none, "#template-picker-create .pending-idle") == "Copy a board"
    assert present?(none, "#template-picker-create[disabled]")
  end

  test "RE455 8. a server key error replaces the key hint" do
    doc = identity_picker(name: "Acme", key: "AC", errors: %{key: ["must be exactly 2 letters"]})

    assert text(doc, "#template-picker-key-hint") == "must be exactly 2 letters"
    assert "text-error" in classes(doc, "#template-picker-key-hint")
  end

  test "RE455 8b. a server name error shows under the name" do
    doc = identity_picker(name: "", key: "AC", errors: %{name: ["can't be blank"]})

    assert text(doc, "#template-picker-name-hint") == "can't be blank"
    assert "text-error" in classes(doc, "#template-picker-name-hint")
    assert "input-error" in classes(doc, "#template-picker-name")
  end
end
