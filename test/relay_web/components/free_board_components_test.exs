defmodule RelayWeb.FreeBoardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.FreeBoardComponents

  defp boards do
    now = DateTime.utc_now()

    [
      %{id: 1, slug: "alpha", name: "Alpha", editable?: true, active_at: DateTime.add(now, -2, :hour)},
      %{id: 2, slug: "bravo", name: "Bravo", editable?: false, active_at: DateTime.add(now, -3, :day)},
      %{id: 3, slug: "charlie", name: "Charlie", editable?: false, active_at: DateTime.add(now, -14, :day)}
    ]
  end

  defp dialog(overrides \\ []) do
    attrs =
      Keyword.merge(
        [boards: boards(), selected: 1, editable_id: 1, upgrade_price: "$20", upgrade_href: "/account/billing"],
        overrides
      )

    (&FreeBoardComponents.free_board_dialog/1)
    |> render_component(attrs)
    |> LazyHTML.from_fragment()
  end

  defp confirm(attrs) do
    (&FreeBoardComponents.make_editable_confirm/1)
    |> render_component(attrs)
    |> LazyHTML.from_fragment()
  end

  defp classes(doc, selector) do
    [class] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
    String.split(class)
  end

  defp attr(doc, selector, name) do
    [value] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
    value
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  describe "free_board_dialog/1" do
    test "1. a daisyUI modal with the 480px panel, the copy, and one radio per board, the selected one checked" do
      doc = dialog()

      assert count(doc, ~s(#free-board-dialog.modal.modal-open[role="dialog"])) == 1

      panel = classes(doc, "#free-board-dialog .modal-box")

      for class <- ~w(w-full max-w-[480px] rounded-[18px] border border-base-300 bg-base-100 p-5 shadow-xl),
          do: assert(class in panel)

      title = classes(doc, "h2#free-board-dialog-title")
      for class <- ~w(text-[20px] font-semibold tracking-tight), do: assert(class in title)
      assert text(doc, "#free-board-dialog-title") == "Which board stays editable?"

      assert text(doc, "#free-board-dialog .modal-box > p.mt-1.text-\\[13\\.5px\\].text-base-content\\/65") ==
               "You're on Free now, which includes one board. The others become read-only, and nothing is deleted. Upgrade any time to unlock them all."

      radios = LazyHTML.query(doc, ~s(input.radio.radio-primary.radio-sm[type="radio"][name="board_id"]))
      assert LazyHTML.attribute(radios, "value") == ["1", "2", "3"]
      assert doc |> LazyHTML.query(~s(input[name="board_id"][checked])) |> LazyHTML.attribute("value") == ["1"]
    end

    test "1. each row is a label with the swatch and the name block" do
      doc = dialog()

      for id <- 1..3 do
        row = classes(doc, "label#free-board-dialog-option-#{id}")

        for class <- ~w(flex cursor-pointer items-center gap-3 rounded-[12px] px-3 py-2.5),
            do: assert(class in row)

        assert count(doc, "#free-board-dialog-option-#{id} span.size-\\[12px\\].rounded-\\[4px\\]") == 1
        assert count(doc, "#free-board-dialog-option-#{id} span.block.text-sm.font-semibold") == 1
      end

      swatch = "alpha" |> RelayWeb.CoreComponents.identity_hue() |> RelayWeb.CoreComponents.identity_color_for_hue()
      assert attr(doc, "#free-board-dialog-option-1 span.size-\\[12px\\]", "style") == "background:#{swatch};"
      assert text(doc, "#free-board-dialog-option-2 span.block.text-sm.font-semibold") == "Bravo"
    end

    test "2. the selected row carries the primary border and ring, the others a hairline; sub-lines read their age" do
      doc = dialog()

      selected = classes(doc, "#free-board-dialog-option-1")
      assert "border-2" in selected
      assert "border-primary" in selected

      assert attr(doc, "#free-board-dialog-option-1", "style") =~
               "color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100))"

      sub = "span.block.font-mono.text-\\[10\\.5px\\].text-base-content\\/55"
      assert text(doc, "#free-board-dialog-option-1 #{sub}") == "most active · updated 2h ago"

      other = classes(doc, "#free-board-dialog-option-2")
      for class <- ~w(m-px border border-base-300), do: assert(class in other)
      refute "border-2" in other
      assert doc |> LazyHTML.query("#free-board-dialog-option-2") |> LazyHTML.attribute("style") == []
      assert text(doc, "#free-board-dialog-option-2 #{sub}") == "updated 3d ago"

      assert text(doc, "#free-board-dialog-option-3 #{sub}") == "updated 14d ago"
    end

    test "3. the keep button names the selection; the footnote and 'most active' name the editable board" do
      doc = dialog(selected: 2, editable_id: 1)

      keep = classes(doc, ~s(button#free-board-dialog-keep[type="submit"]))
      for class <- ~w(btn btn-primary btn-sm), do: assert(class in keep)
      assert text(doc, "#free-board-dialog-keep") == "Keep Bravo editable"

      footnote = classes(doc, "p#free-board-dialog-footnote")
      for class <- ~w(mt-3 text-[11.5px] text-base-content/50), do: assert(class in footnote)

      assert text(doc, "#free-board-dialog-footnote") ==
               "Closing this keeps Alpha editable. You can switch any time, from Billing or from a read-only board's banner."

      assert text(doc, "#free-board-dialog-option-1") =~ "most active · updated"
      assert "border-2" in classes(doc, "#free-board-dialog-option-2")
      assert "border-primary" in classes(doc, "#free-board-dialog-option-2")
      refute "border-2" in classes(doc, "#free-board-dialog-option-1")
      assert doc |> LazyHTML.query(~s(input[name="board_id"][checked])) |> LazyHTML.attribute("value") == ["2"]
    end

    test "4. the upgrade link quotes the price and goes to Billing; no href, no link" do
      doc = dialog(upgrade_href: "/account/billing")

      upgrade = classes(doc, ~s(a#free-board-dialog-upgrade[href="/account/billing"]))
      for class <- ~w(btn btn-ghost btn-sm), do: assert(class in upgrade)
      assert text(doc, "#free-board-dialog-upgrade") == "Upgrade instead · $20/mo"

      assert count(dialog(upgrade_href: nil), "#free-board-dialog-upgrade") == 0
    end

    test "5. the form, ✕, Escape and the backdrop carry the dialog's events" do
      doc = dialog()

      assert attr(doc, "#free-board-dialog-form", "phx-change") == "select_free_board"
      assert attr(doc, "#free-board-dialog-form", "phx-submit") == "keep_free_board"

      close = classes(doc, "button#free-board-dialog-close")
      for class <- ~w(btn btn-ghost btn-sm btn-circle), do: assert(class in close)
      assert attr(doc, "#free-board-dialog-close", "phx-click") == "close_free_board_dialog"
      assert count(doc, "#free-board-dialog-close .hero-x-mark.size-4") == 1

      assert attr(doc, "#free-board-dialog", "phx-window-keydown") == "close_free_board_dialog"
      assert attr(doc, "#free-board-dialog", "phx-key") == "escape"
      assert attr(doc, "#free-board-dialog .modal-backdrop", "phx-click") == "close_free_board_dialog"
    end
  end

  describe "make_editable_confirm/1" do
    test "6. a daisyUI confirm naming both boards, sending the default events with the board id" do
      doc = confirm(board_id: 7, board_name: "Charlie", editable_name: "Bravo")

      assert count(doc, ~s(#make-editable-confirm.modal.modal-open[role="dialog"] .modal-box)) == 1
      assert text(doc, "#make-editable-confirm-title") == "Make Charlie editable?"
      assert text(doc, "#make-editable-confirm .modal-box p") == "Bravo becomes read-only. Nothing is deleted."

      assert text(doc, "#make-editable-confirm-cancel") == "Cancel"
      assert attr(doc, "#make-editable-confirm-cancel", "phx-click") == "cancel_make_editable"

      submit = classes(doc, "#make-editable-confirm-submit")
      assert "btn" in submit
      assert "btn-primary" in submit
      assert text(doc, "#make-editable-confirm-submit .pending-idle") == "Make editable"
      assert attr(doc, "#make-editable-confirm-submit", "phx-click") == "confirm_make_editable"
      assert attr(doc, "#make-editable-confirm-submit", "phx-value-board-id") == "7"

      assert attr(doc, "#make-editable-confirm .modal-backdrop", "phx-click") == "cancel_make_editable"
      assert attr(doc, "#make-editable-confirm", "phx-window-keydown") == "cancel_make_editable"
      assert attr(doc, "#make-editable-confirm", "phx-key") == "escape"
    end

    test "6. custom event names replace the defaults" do
      doc =
        confirm(
          board_id: 7,
          board_name: "Charlie",
          editable_name: "Bravo",
          confirm_event: "x_confirm",
          cancel_event: "x_cancel"
        )

      assert attr(doc, "#make-editable-confirm-submit", "phx-click") == "x_confirm"
      assert attr(doc, "#make-editable-confirm-cancel", "phx-click") == "x_cancel"
      assert attr(doc, "#make-editable-confirm .modal-backdrop", "phx-click") == "x_cancel"
      assert attr(doc, "#make-editable-confirm", "phx-window-keydown") == "x_cancel"
    end
  end
end
