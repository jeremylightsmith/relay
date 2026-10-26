defmodule HamacaWeb.TemplatePickerComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.TemplatePickerComponents

  defp picker(selected) do
    (&TemplatePickerComponents.template_picker/1)
    |> render_component(
      templates: Hamaca.Boards.templates(),
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
      |> render_component(templates: Hamaca.Boards.offered_templates(), selected: "bare-minimum")
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
    assert LazyHTML.attribute(icons, "data-type") != []
    assert icons |> LazyHTML.attribute("style") |> Enum.all?(&(&1 =~ "width:8px;height:8px"))
  end

  test "only the templates in examples link to a public example (RE444)" do
    doc =
      (&TemplatePickerComponents.template_picker/1)
      |> render_component(
        templates: Hamaca.Boards.templates(),
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
      Keyword.merge([templates: Hamaca.Boards.templates(), selected: TemplatePickerComponents.copy_option()], attrs)
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
    |> render_component(Keyword.merge([templates: Hamaca.Boards.templates(), selected: "bare-minimum"], attrs))
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

  # RE470 — first-run mode (card mockup "A — first-run picker over an empty Your boards, no way
  # out but Create or Sign out").

  defp first_run_picker do
    identity_picker(first_run: true, signed_in_as: "jeremy@example.com", name: "Jeremy's board", key: "JE")
  end

  test "RE470 1. first-run titles the picker Make your first board and drops the copy wording" do
    doc = first_run_picker()

    assert text(doc, "#template-picker-title") == "Make your first board"
    assert "text-[20px]" in classes(doc, "#template-picker-title")

    subtitle = squish(doc, "#template-picker-title + p")
    refute subtitle =~ "or copy a board"
    assert subtitle =~ "then start from a template. You get its stages and flows."

    assert subtitle ==
             "Name it, pick its card key, then start from a template. You get its stages and flows. " <>
               "Every prompt lives inside its flow, so it works in any repo with no .claude/ setup."
  end

  test "RE470 2. first-run has no close, no cancel and no copy card" do
    doc = first_run_picker()

    assert doc |> LazyHTML.query("#template-picker-close") |> Enum.count() == 0
    assert doc |> LazyHTML.query("#template-picker-cancel") |> Enum.count() == 0
    assert doc |> LazyHTML.query("#template-card-copy") |> Enum.count() == 0
  end

  test "RE470 3. first-run neither Escape nor a scrim click closes the picker" do
    doc = first_run_picker()

    assert present?(doc, "#template-picker")
    assert present?(doc, "#template-picker:not([phx-window-keydown]):not([phx-key])")
    assert present?(doc, "#template-picker .modal-scrim")
    assert present?(doc, "#template-picker .modal-scrim:not([phx-click])")
    assert attr(doc, "#template-picker .modal-scrim", "class") == ["modal-scrim"]
  end

  test "RE470 4. first-run footer reads Signed in as <email> · Sign out, linking DELETE /logout" do
    doc = first_run_picker()

    assert attr(doc, "#template-picker-sign-out", "href") == ["/logout"]
    assert attr(doc, "#template-picker-sign-out", "data-method") == ["delete"]
    assert text(doc, "#template-picker-sign-out") == "Sign out"
    assert ~w(link link-hover) -- classes(doc, "#template-picker-sign-out") == []

    span = LazyHTML.query(doc, "span:has(> #template-picker-sign-out)")
    assert Enum.count(span) == 1
    assert span |> LazyHTML.text() |> String.split() |> Enum.join(" ") == "Signed in as jeremy@example.com · Sign out"

    span_classes = span |> LazyHTML.attribute("class") |> hd() |> String.split()
    assert ~w(text-[12px] text-base-content/55) -- span_classes == []

    # Left of the spacer, then only Create.
    assert present?(doc, "span:has(> #template-picker-sign-out) + span.flex-1 + #template-picker-create")
  end

  test "RE470 5. first-run keeps the identity row and Create <name>" do
    doc = first_run_picker()

    assert text(doc, "#template-picker-create .pending-idle") == "Create Jeremy's board"
    assert attr(doc, "#template-picker-name", "value") == ["Jeremy's board"]
    assert attr(doc, "#template-picker-key", "value") == ["JE"]
    assert squish(doc, "#template-picker-key-preview") == "Cards will be JE1, JE2, JE3…"
  end

  test "RE470 6. by default the picker keeps New board, its ways out and the copy card, and no sign-out" do
    doc = identity_picker([])

    assert text(doc, "#template-picker-title") == "New board"
    assert present?(doc, "#template-picker-close")
    assert present?(doc, "#template-picker-cancel")
    assert present?(doc, "#template-card-copy")
    assert present?(doc, ~s(#template-picker[phx-window-keydown="close_template_picker"]))
    assert present?(doc, ~s(#template-picker .modal-scrim[phx-click="close_template_picker"]))
    refute present?(doc, "#template-picker-sign-out")
  end

  test "RE470 7. by default the subtitle still offers to copy a board" do
    doc = identity_picker([])

    assert squish(doc, "#template-picker-title + p") =~ "start from a template or copy a board"
  end

  describe "at the Free limit (RE472)" do
    @limit_attrs [
      templates: Hamaca.Boards.offered_templates(),
      selected: "design-led",
      name: "Acme Checkout",
      key: "AC",
      upgrade_required: true,
      upgrade_price: "$20",
      upgrade_create: true
    ]

    defp limit_picker(attrs \\ []), do: identity_picker(Keyword.merge(@limit_attrs, attrs))

    defp copy_line(doc), do: squish(doc, "#template-picker-upgrade .text-base-content\\/65")

    test "1. the footer names the board it will create and the template it starts from" do
      doc = limit_picker()

      assert text(doc, "#template-picker-upgrade .font-semibold") == "Free includes one board."

      assert copy_line(doc) ==
               "Upgrade for unlimited boards, $20/mo. We'll create Acme Checkout from Design-led as soon as you're back."

      assert text(doc, "b#template-picker-upgrade-name") == "Acme Checkout"
      assert text(doc, "b#template-picker-upgrade-source") == "Design-led"
    end

    test "2. Upgrade and create → is an enabled primary button beside Cancel, replacing Create" do
      doc = limit_picker()

      assert attr(doc, "#template-picker-upgrade-create", "type") == ["button"]
      assert attr(doc, "#template-picker-upgrade-create", "phx-click") == ["upgrade_and_create"]

      button = classes(doc, "#template-picker-upgrade-create")
      for class <- ~w(btn btn-primary btn-sm flex-1 sm:flex-none), do: assert(class in button)

      assert text(doc, "#template-picker-upgrade-create") == "Upgrade and create →"
      assert present?(doc, "#template-picker-upgrade-create")
      refute present?(doc, "#template-picker-upgrade-create[disabled]")
      assert present?(doc, "#template-picker-cancel")
      refute present?(doc, "#template-picker-create")
      refute present?(doc, "#template-picker-upgrade-link")
    end

    test "3. with no name typed the copy drops the We'll create sentence and the button is disabled" do
      doc = limit_picker(name: "   ")

      assert copy_line(doc) == "Upgrade for unlimited boards, $20/mo."
      refute present?(doc, "#template-picker-upgrade-name")
      assert present?(doc, "#template-picker-upgrade-create[disabled]")
    end

    test "4. on the copy option the source is the selected board's name" do
      doc =
        limit_picker(
          selected: "copy",
          copy_sources: [%{slug: "src", name: "Payments", key: "PA", stages: 3, flows: 1, files: []}],
          copy_from: "src"
        )

      assert text(doc, "#template-picker-upgrade-source") == "Payments"
    end

    test "5. on the copy option with no board to copy the button is disabled and nothing is promised" do
      doc = limit_picker(selected: "copy", copy_sources: [])

      assert present?(doc, "#template-picker-upgrade-create[disabled]")
      refute copy_line(doc) =~ "We'll create"
    end

    test "6. an incomplete key leaves the button clickable for the server to validate" do
      doc = limit_picker(name: "Acme", key: "A")

      assert present?(doc, "#template-picker-upgrade-create")
      refute present?(doc, "#template-picker-upgrade-create[disabled]")
    end

    test "7. embedded in the app the panel and Cancel render without Upgrade and create" do
      doc = limit_picker(upgrade_create: false)

      assert present?(doc, "#template-picker-upgrade")
      assert present?(doc, "#template-picker-cancel")
      refute present?(doc, "#template-picker-upgrade-create")
    end
  end

  # RE472 smoke — a declined Checkout reopens the picker AND flashes "That card was
  # declined."; the toast must stack above the picker overlay or it is unreadable.
  test "the flash toast stacks above the picker overlay" do
    z = fn doc, selector ->
      [class] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
      [_, n] = Regex.run(~r/(?:^|\s)z-\[?(\d+)\]?(?:\s|$)/, class)
      String.to_integer(n)
    end

    overlay = z.(picker("bare-minimum"), "#template-picker > div.fixed")

    flash =
      (&HamacaWeb.CoreComponents.flash/1)
      |> render_component(kind: :error, flash: %{"error" => "That card was declined."})
      |> LazyHTML.from_fragment()
      |> z.("#flash-error")

    assert flash > overlay
  end
end
