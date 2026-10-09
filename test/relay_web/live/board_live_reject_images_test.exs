defmodule RelayWeb.BoardLiveRejectImagesTest do
  @moduledoc """
  RE428 — Request changes takes images the GitHub way. Each file uploads the moment it lands
  (RE427's shared image control, `:reject_images`) into an unlinked attachment shown as a pending
  thumbnail; the server pushes `image_link_*` events so the `.ImagePaste` hook keeps an absolute
  `![name](…/attachments/<id>)` link in the note. Reject posts the pending images as one
  FROM REJECTION image note, atomically with the rejection. LiveViewTest runs no JS, so these
  tests assert the push events; `RelayWeb.Browser.RejectImagesTest` proves the hook.
  """
  use RelayWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo
  alias Schemas.Attachment
  alias Schemas.Comment

  @form "#review-reject-form"
  @box "review-reject-images"
  @over_cap "That’s #{Comment.max_images()} — the most one note can carry. Post this one and start another."

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    plan = Enum.find(board.stages, &(&1.name == "Plan"))
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})
    {:ok, card} = Cards.set_status(card, %{status: :in_review})

    %{board: board, card: card, plan: plan}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp open_reject(%{conn: conn, board: board}) do
    view = open(conn, ~p"/board/#{board.slug}?card=MY1")
    view |> element("#review-request-changes") |> render_click()
    view
  end

  defp png(name), do: %{name: name, content: "png bytes of #{name}", type: "image/png"}

  # As in BoardLiveNoteAttachTest: choosing files fires the form's phx-change with the new
  # entries; auto_upload then sends only the entries the server still lists as active.
  defp choose(view, files, note \\ "") do
    upload = file_input(view, @form, :reject_images, files)
    view |> form(@form, reject: %{note: note}) |> render_change(upload)
    upload
  end

  # One single-entry client per active entry (the progress callback consumes an entry as soon as
  # it is done, which would take a shared client down after the first file).
  defp upload_all(view, upload, percent \\ 100) do
    active = active_refs(view)

    for %{"ref" => ref} = entry <- upload.entries, ref in active do
      single =
        file_input(view, @form, :reject_images, [%{name: entry["name"], content: entry["content"], type: entry["type"]}])

      single = %{single | entries: [Map.put(hd(single.entries), "ref", ref)]}
      render_upload(single, entry["name"], percent)
      entry
    end
  end

  defp attach(view, files, note \\ "") do
    upload = choose(view, files, note)
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
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[id^='#{@box}-pending-']")
  end

  defp note_value(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#review-request-note") |> LazyHTML.text()
  end

  defp attachments(card), do: Repo.all(from a in Attachment, where: a.card_id == ^card.id, order_by: a.inserted_at)

  defp rejection_notes(card),
    do: Repo.all(from c in Comment, where: c.card_id == ^card.id and c.origin == :rejection, preload: :images)

  defp placeholder(name), do: "![Uploading #{name}…]()"

  test "4. Request changes carries the image box and 📎 inside the reject form", ctx do
    view = open_reject(ctx)

    assert has_element?(view, "#{@form} ##{@box}")
    assert has_element?(view, "#{@form} ##{@box}-attach")
  end

  test "4. the native embed has neither", %{conn: conn, board: board} do
    view = open(conn, ~p"/cards/MY1?board=#{board.slug}&embed=1")
    render_click(view, "review_open_reject", %{})

    refute has_element?(view, "##{@box}")
    refute has_element?(view, "##{@box}-attach")
  end

  test "5. a chosen PNG pushes a placeholder, then its link once uploaded", ctx do
    view = open_reject(ctx)
    upload = choose(view, [png("shot.png")])

    assert_push_event(view, "image_link_placeholder", %{box: @box, placeholder: "![Uploading shot.png…]()"})

    upload_all(view, upload)
    [attachment] = attachments(ctx.card)

    assert attachment.filename == "shot.png"
    assert attachment.comment_id == nil
    assert has_element?(view, "##{@box}-pending-#{attachment.id}")

    markdown = "![shot.png](" <> RelayWeb.attachment_url(attachment.id) <> ")"

    assert_push_event(view, "image_link_done", %{
      box: @box,
      placeholder: "![Uploading shot.png…]()",
      markdown: ^markdown
    })
  end

  test "6. ✕ on an uploaded thumbnail drops it and pushes its link's removal", ctx do
    view = open_reject(ctx)
    attach(view, [png("a.png")])
    attach(view, [png("b.png")])
    [a, b] = attachments(ctx.card)

    view |> element("##{@box}-pending-#{a.id} button[title=Remove]") |> render_click()

    refute has_element?(view, "##{@box}-pending-#{a.id}")
    assert has_element?(view, "##{@box}-pending-#{b.id}")
    assert Enum.count(thumbs(view)) == 1

    markdown = "![a.png](" <> RelayWeb.attachment_url(a.id) <> ")"
    assert_push_event(view, "image_link_remove", %{box: @box, markdown: ^markdown})
  end

  test "6. ✕ on an in-flight thumbnail cancels it and pushes the placeholder's removal", ctx do
    view = open_reject(ctx)
    upload = choose(view, [png("slow.png")])
    [%{"ref" => ref}] = upload_all(view, upload, 50)

    view |> element("##{@box}-pending-#{ref} button[title=Remove]") |> render_click()

    refute has_element?(view, "##{@box}-pending-#{ref}")
    placeholder = placeholder("slow.png")
    assert_push_event(view, "image_link_failed", %{box: @box, placeholder: ^placeholder})
    assert attachments(ctx.card) == []
  end

  test "7. a wrong type and a 6 MB PNG are refused by name and the note is kept", ctx do
    view = open_reject(ctx)

    choose(
      view,
      [
        %{name: "clip.mov", content: "mov", type: "video/quicktime"},
        %{name: "big.png", content: String.duplicate("x", 6 * 1_048_576), type: "image/png"}
      ],
      "too tall on mobile:"
    )

    assert has_element?(view, "##{@box}-hint p.text-error", "clip.mov isn’t an image (PNG, JPEG, WebP or GIF).")
    assert has_element?(view, "##{@box}-hint p.text-error", "big.png is 6.0 MB — the limit is 5 MB.")
    refute_push_event(view, "image_link_placeholder", %{box: @box})
    assert String.trim(note_value(view)) == "too tall on mobile:"
  end

  test "8. a 7th image past six pending is refused with the over-cap error", ctx do
    view = open_reject(ctx)
    attach(view, for(n <- 1..Comment.max_images(), do: png("s#{n}.png")))
    attach(view, [png("seventh.png")])

    assert Enum.count(thumbs(view)) == Comment.max_images()
    assert length(attachments(ctx.card)) == Comment.max_images()
    assert has_element?(view, "##{@box}-hint p.text-error", @over_cap)
  end

  test "9. Reject posts a FROM REJECTION image note with the rejection", ctx do
    view = open_reject(ctx)
    attach(view, [png("shot.png")])
    [shot] = attachments(ctx.card)
    note = "too tall on mobile: ![shot.png](#{RelayWeb.attachment_url(shot.id)})"

    view |> form(@form, reject: %{note: note}) |> render_change()
    view |> form(@form, reject: %{note: note}) |> render_submit()

    card = Repo.get!(Schemas.Card, ctx.card.id)
    assert card.stage_id == ctx.plan.id
    assert card.rejection.note == note

    assert [%Comment{origin: :rejection, body: body, images: [%{id: id}]}] = rejection_notes(ctx.card)
    assert body in [nil, ""]
    assert id == shot.id
  end

  test "10. a blank note keeps the pending image and posts nothing", ctx do
    view = open_reject(ctx)
    attach(view, [png("shot.png")])
    [shot] = attachments(ctx.card)

    view |> form(@form, reject: %{note: ""}) |> render_submit()

    assert has_element?(view, "#review-note-error", "Add a note — the AI needs to know what to change.")
    assert rejection_notes(ctx.card) == []
    assert Repo.get!(Attachment, shot.id).comment_id == nil
    assert has_element?(view, "##{@box}-pending-#{shot.id}")
  end

  test "11. Reject is disabled and refused while an image is in flight", ctx do
    view = open_reject(ctx)
    upload = choose(view, [png("slow.png")], "wait")
    upload_all(view, upload, 50)

    assert has_element?(view, "#review-send-back[disabled]")

    view |> form(@form, reject: %{note: "wait"}) |> render_submit()

    card = Repo.get!(Schemas.Card, ctx.card.id)
    assert card.stage_id == ctx.card.stage_id
    assert card.status == :in_review
    assert Repo.all(from c in Comment, where: c.card_id == ^ctx.card.id) == []
  end

  test "12. Cancel then Request changes again starts with no pending thumbnail", ctx do
    view = open_reject(ctx)
    attach(view, [png("shot.png")])
    assert Enum.count(thumbs(view)) == 1

    view |> element("#review-cancel-reject") |> render_click()
    view |> element("#review-request-changes") |> render_click()

    assert Enum.empty?(thumbs(view))
  end

  test "13. the Notes list tags an image note's origin", ctx do
    {:ok, a} = Relay.Attachments.create_attachment(ctx.card, %{filename: "a.png", content_type: "image/png", bytes: "a"})
    {:ok, r} = Relay.Attachments.create_attachment(ctx.card, %{filename: "r.png", content_type: "image/png", bytes: "r"})
    {:ok, answer} = Activity.add_comment(ctx.card, %{actor: :agent, body: "", image_ids: [a.id], origin: {:answer, 2}})
    {:ok, rejection} = Activity.add_comment(ctx.card, %{actor: :agent, body: "", image_ids: [r.id], origin: :rejection})
    {:ok, plain} = Activity.add_comment(ctx.card, %{actor: :agent, body: "plain note"})

    view = open(ctx.conn, ~p"/board/#{ctx.board.slug}?card=MY1")

    assert has_element?(view, "#timeline-comment-#{answer.id}-origin", "FROM ANSWER · Q2")
    assert has_element?(view, "#timeline-comment-#{rejection.id}-origin", "FROM REJECTION")
    assert has_element?(view, "#timeline-comment-#{plain.id}")
    refute has_element?(view, "#timeline-comment-#{plain.id}-origin")
  end
end
