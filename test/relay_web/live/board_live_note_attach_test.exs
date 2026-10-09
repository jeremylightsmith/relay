defmodule RelayWeb.BoardLiveNoteAttachTest do
  @moduledoc """
  RE427 — the Notes composer takes images (📎, paste, drop). Each file uploads the moment it
  lands (LiveView `auto_upload`) into an unlinked `Schemas.Attachment` shown as a removable
  pending thumbnail; **Add note** links them to the note. Limits render inline under the box and
  never lose the typed text. The native embed is view-only.
  """
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Attachment
  alias Schemas.Comment

  @form "#card-drawer-comment-form"
  @box "#card-drawer-note-images"
  @pending "#card-drawer-note-images-pending"
  @over_cap "That’s #{Comment.max_images()} — the most one note can carry. Post this one and start another."

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Attach to me"})
    {:ok, other} = Cards.create_card(review, %{title: "Another card"})

    %{board: board, card: card, other: other}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp open_drawer(%{conn: conn, board: board}), do: open(conn, ~p"/board/#{board.slug}?card=MY1")

  defp png(name), do: %{name: name, content: "png bytes of #{name}", type: "image/png"}

  # Mirrors the browser: selecting files fires the form's phx-change (validate_comment) with the
  # new entries, then auto_upload preflights and sends the chunks of the entries the server still
  # holds — the browser only preflights entries the re-rendered input lists as active
  # (`data-phx-active-refs`), so entries validate_comment cancelled are skipped here too.
  defp choose(view, files, body \\ "") do
    upload = file_input(view, @form, :note_images, files)
    view |> form(@form, comment: %{body: body}) |> render_change(upload)
    upload
  end

  # LiveViewTest's upload client is linked to every entry's upload channel, and the progress
  # callback consumes an entry (closing its channel) as soon as it is done — which takes the
  # whole client down after the first file. So each active entry is sent by its own one-entry
  # client carrying the same entry ref; the server sees the same entries either way.
  defp upload_all(view, upload, percent \\ 100) do
    active = active_refs(view)

    for %{"ref" => ref} = entry <- upload.entries, ref in active do
      single =
        file_input(view, @form, :note_images, [%{name: entry["name"], content: entry["content"], type: entry["type"]}])

      single = %{single | entries: [Map.put(hd(single.entries), "ref", ref)]}
      render_upload(single, entry["name"], percent)
      entry
    end
  end

  defp attach(view, files, body \\ "") do
    upload = choose(view, files, body)
    upload_all(view, upload)
  end

  defp active_refs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} input[type=file]")
    |> LazyHTML.attribute("data-phx-active-refs")
    |> List.first("")
    |> String.split(",", trim: true)
  end

  defp thumbs(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[id^='card-drawer-note-images-pending-']")
  end

  defp body_value(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#card-drawer-comment-input")
    |> LazyHTML.text()
  end

  defp attachments(card), do: Repo.all(from a in Attachment, where: a.card_id == ^card.id, order_by: a.inserted_at)

  defp comment_image_ids(comment) do
    comment |> Repo.preload(:images, force: true) |> Map.fetch!(:images) |> Enum.map(& &1.id)
  end

  test "1. two PNGs become two pending thumbnails backed by unlinked attachments", ctx do
    view = open_drawer(ctx)
    attach(view, [png("a.png"), png("b.png")])

    assert Enum.count(thumbs(view)) == 2

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s|#{@pending} img[src^="/attachments/"]|)
           |> Enum.count() == 2

    rows = attachments(ctx.card)
    assert length(rows) == 2
    assert Enum.all?(rows, &is_nil(&1.comment_id))
    assert rows |> Enum.map(& &1.filename) |> Enum.sort() == ["a.png", "b.png"]
  end

  test "2. posting links the pending images in upload order and clears the composer", ctx do
    view = open_drawer(ctx)
    attach(view, [png("a.png")])
    attach(view, [png("b.png")])
    [a, b] = attachments(ctx.card)

    view |> form(@form, comment: %{body: "see screenshots"}) |> render_submit()

    assert [comment] = Repo.all(Comment)
    assert comment.body == "see screenshots"
    assert comment_image_ids(comment) == [a.id, b.id]
    assert has_element?(view, "#timeline-comment-#{comment.id}-images img.h-\\[108px\\]")
    assert view |> thumbs() |> Enum.count() == 0
    assert String.trim(body_value(view)) == ""
  end

  test "3. an image-only note posts without a can't be blank error", ctx do
    view = open_drawer(ctx)
    attach(view, [png("only.png")])

    html = view |> form(@form, comment: %{body: ""}) |> render_submit()

    assert [comment] = Repo.all(Comment)
    assert length(comment_image_ids(comment)) == 1
    refute html =~ "can&#39;t be blank"
    refute html =~ "can't be blank"
  end

  test "4. selecting 7 at once attaches 6, shows the over-cap error and keeps the text", ctx do
    view = open_drawer(ctx)
    files = for n <- 1..(Comment.max_images() + 1), do: png("shot-#{n}.png")
    attach(view, files, "before/after")

    assert Enum.count(thumbs(view)) == Comment.max_images()
    assert length(attachments(ctx.card)) == Comment.max_images()
    assert has_element?(view, "#card-drawer-note-images-hint p.text-error", @over_cap)
    assert String.trim(body_value(view)) == "before/after"
  end

  test "5. with 6 already pending, one more is refused with the over-cap error", ctx do
    view = open_drawer(ctx)
    attach(view, for(n <- 1..Comment.max_images(), do: png("s#{n}.png")))
    attach(view, [png("one-more.png")])

    assert Enum.count(thumbs(view)) == Comment.max_images()
    assert length(attachments(ctx.card)) == Comment.max_images()
    assert has_element?(view, "#card-drawer-note-images-hint p.text-error", @over_cap)
  end

  test "6. a wrong type and a too-large file are refused by name; the valid PNG attaches", ctx do
    view = open_drawer(ctx)

    attach(
      view,
      [
        %{name: "recording.mov", content: "mov", type: "video/quicktime"},
        %{name: "huge.png", content: String.duplicate("x", 9_542_042), type: "image/png"},
        png("ok.png")
      ],
      "typed text"
    )

    assert [%{filename: "ok.png"}] = attachments(ctx.card)
    assert Enum.count(thumbs(view)) == 1

    types = Enum.join(Attachment.image_type_names(), ", ")
    [last | rest] = types |> String.split(", ") |> Enum.reverse()
    named = Enum.join(Enum.reverse(rest), ", ") <> " or " <> last
    assert types =~ "PNG"

    assert has_element?(view, "#card-drawer-note-images-hint p.text-error", "recording.mov isn’t an image (#{named}).")
    assert has_element?(view, "#card-drawer-note-images-hint p.text-error", "huge.png is 9.1 MB — the limit is 5 MB.")
    assert String.trim(body_value(view)) == "typed text"
  end

  test "7. removing a pending image leaves it unlinked and posts only the rest", ctx do
    view = open_drawer(ctx)
    attach(view, [png("a.png")])
    attach(view, [png("b.png")])
    [a, b] = attachments(ctx.card)

    view |> element("#card-drawer-note-images-pending-#{a.id} button[title=Remove]") |> render_click()
    view |> form(@form, comment: %{body: "just b"}) |> render_submit()

    assert [comment] = Repo.all(Comment)
    assert comment_image_ids(comment) == [b.id]
    assert Repo.get!(Attachment, a.id).comment_id == nil
  end

  test "8. Add note refuses to post while an image is still uploading", ctx do
    view = open_drawer(ctx)
    upload = choose(view, [png("slow.png")], "wait for it")
    upload_all(view, upload, 50)

    assert has_element?(view, "#{@form} button[type=submit][disabled]")

    view |> form(@form, comment: %{body: "wait for it"}) |> render_submit()

    assert Repo.all(Comment) == []
    assert String.trim(body_value(view)) == "wait for it"
  end

  test "9. cancelling an in-flight image drops it without creating an attachment", ctx do
    view = open_drawer(ctx)
    upload = choose(view, [png("slow.png")])
    [%{"ref" => ref}] = upload_all(view, upload, 50)

    assert has_element?(view, "#card-drawer-note-images-pending-#{ref}")
    view |> element("#card-drawer-note-images-pending-#{ref} button[title=Remove]") |> render_click()

    refute has_element?(view, "#card-drawer-note-images-pending-#{ref}")
    assert attachments(ctx.card) == []
  end

  test "10. switching cards drops the pending thumbnails and errors", ctx do
    view = open_drawer(ctx)
    attach(view, [png("a.png")])
    attach(view, [%{name: "clip.mov", content: "mov", type: "video/quicktime"}])
    assert has_element?(view, "#card-drawer-note-images-hint p.text-error")

    render_patch(view, ~p"/board/#{ctx.board.slug}?card=MY2")
    render_async(view)

    assert Enum.empty?(thumbs(view))
    refute has_element?(view, "#card-drawer-note-images-hint p.text-error")
  end

  test "11. the native embed composer is view-only", %{conn: conn, board: board} do
    view = open(conn, ~p"/cards/MY1?board=#{board.slug}")

    assert has_element?(view, @form)
    refute has_element?(view, "#card-drawer-note-images-attach")
    refute has_element?(view, "#{@form} input[type=file]")
    refute has_element?(view, "#{@box}[phx-drop-target]")
    assert has_element?(view, "#card-drawer-note-images-hint", "Attach images from the web app.")
    refute has_element?(view, "#card-drawer-note-images-hint", "Paste, drop")
  end

  test "12. the desktop composer has the paperclip, the drop target, the paste hook and both hints", ctx do
    view = open_drawer(ctx)
    attach_btn = "label#card-drawer-note-images-attach"

    assert has_element?(view, ~s|#{attach_btn}[title="Attach images (or paste / drop)"].hidden.drawer\\:inline-flex|)
    assert has_element?(view, "#{attach_btn} input[type=file][multiple]")
    assert has_element?(view, "#{@box}[phx-drop-target]")
    assert view |> element(@box) |> render() =~ ~s(phx-hook="RelayWeb.CoreComponents.ImagePaste")

    assert has_element?(view, "#card-drawer-note-images-hint p.hidden.drawer\\:block", "Paste, drop, or 📎")
    assert has_element?(view, "#card-drawer-note-images-hint p.drawer\\:hidden", "Attach images from the web app.")
  end

  test "13. an archived card has no composer and no file input", ctx do
    {:ok, _card} = Cards.archive_card(ctx.card)
    view = open_drawer(ctx)

    refute has_element?(view, @form)
    refute has_element?(view, "input[type=file]")
  end
end
