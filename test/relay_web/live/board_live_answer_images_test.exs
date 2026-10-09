defmodule RelayWeb.BoardLiveAnswerImagesTest do
  @moduledoc """
  RE428 — answering an agent takes images, per question. The needs-input stepper (and the single
  answer box) carry RE427's shared image control on `:answer_images`: each file uploads at once
  into an unlinked attachment, the server pushes `image_link_*` events so the `.ImagePaste` hook
  keeps an absolute `![name](…/attachments/<id>)` link in the answer text, and Send to AI posts
  one FROM ANSWER · Q<n> image note per question with images, atomically with the answer.
  LiveViewTest runs no JS, so these tests assert the push events;
  `RelayWeb.Browser.AnswerImagesTest` proves the hook.
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

  @text_form "#needs-input-text-form"
  @single_form "#needs-input-form"
  @box "needs-input-images"
  @over_cap "That’s #{Comment.max_images()} — the most one note can carry. Post this one and start another."

  @q1 %{"prompt" => "Which layout?", "options" => ["A", "B"]}
  @q2 %{"prompt" => "Where should the error show?", "options" => []}

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  defp park(%{code: code}, questions) do
    {:ok, card} = Cards.create_card(code, %{title: "Answer with a screenshot"})
    {:ok, card} = Cards.request_input(card, questions, :agent)
    card
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp open_card(%{conn: conn, board: board}, card),
    do: open(conn, ~p"/board/#{board.slug}?card=#{Cards.ref(board, card)}")

  # The two-question card, opened on step 1.
  defp open_stepper(ctx) do
    card = park(ctx, [@q1, @q2])
    {open_card(ctx, card), card}
  end

  # Picking "A" on step 1 commits it and moves on to step 2.
  defp to_step_2(view) do
    view |> element("#needs-input-option-0") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    view
  end

  defp png(name), do: %{name: name, content: "png bytes of #{name}", type: "image/png"}

  # Choosing files fires the form's phx-change with the new entries (as in the reject tests).
  defp choose(view, form, params, files) do
    upload = file_input(view, form, :answer_images, files)
    view |> form(form, params) |> render_change(upload)
    upload
  end

  defp choose_step(view, step, files, text \\ ""),
    do: choose(view, @text_form, %{answer: %{index: to_string(step), text: text}}, files)

  # One single-entry client per active entry (the progress callback consumes an entry as soon as
  # it is done, which would take a shared client down after the first file).
  defp upload_all(view, form, upload, percent \\ 100) do
    active = active_refs(view, form)

    for %{"ref" => ref} = entry <- upload.entries, ref in active do
      single =
        file_input(view, form, :answer_images, [%{name: entry["name"], content: entry["content"], type: entry["type"]}])

      single = %{single | entries: [Map.put(hd(single.entries), "ref", ref)]}
      render_upload(single, entry["name"], percent)
      entry
    end
  end

  defp attach_step(view, step, files, text \\ "") do
    upload = choose_step(view, step, files, text)
    upload_all(view, @text_form, upload)
  end

  defp active_refs(view, form) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{form} input[type=file]")
    |> LazyHTML.attribute("data-phx-active-refs")
    |> List.first("")
    |> String.split(",", trim: true)
  end

  defp thumbs(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[id^='#{@box}-pending-']") |> Enum.count()
  end

  defp attachments(card), do: Repo.all(from a in Attachment, where: a.card_id == ^card.id, order_by: a.inserted_at)

  defp answer_notes(card),
    do:
      Repo.all(
        from c in Comment,
          where: c.card_id == ^card.id and c.origin == :answer,
          order_by: [asc: c.inserted_at, asc: c.origin_question],
          preload: :images
      )

  defp answer_comment(card, body) do
    card
    |> Repo.reload!()
    |> Activity.list_timeline()
    |> Enum.find(&match?(%Comment{body: ^body}, &1))
  end

  defp link(attachment), do: "![#{attachment.filename}](" <> RelayWeb.attachment_url(attachment.id) <> ")"

  describe "1. where the control renders" do
    test "the box and 📎 sit inside the stepper's text form", ctx do
      {view, _card} = open_stepper(ctx)

      assert has_element?(view, "#{@text_form} ##{@box}")
      assert has_element?(view, "#{@text_form} ##{@box}-attach")
      assert has_element?(view, "#{@text_form} ##{@box}-hint")
    end

    test "the native embed has no 📎", %{conn: conn, board: board} = ctx do
      card = park(ctx, [@q1, @q2])
      view = open(conn, ~p"/cards/#{Cards.ref(board, card)}?board=#{board.slug}&embed=1")

      assert has_element?(view, "#needs-input-text")
      refute has_element?(view, "##{@box}-attach")
    end

    test "an options-only step has no image box", ctx do
      card = park(ctx, [%{"prompt" => "Pick", "options" => ["A", "B"], "allow_text" => false}])
      view = open_card(ctx, card)

      assert has_element?(view, "#needs-input-option-0")
      refute has_element?(view, "##{@box}")
    end
  end

  test "2. a chosen PNG on step 2 pushes a placeholder, then its link once uploaded", ctx do
    {view, card} = open_stepper(ctx)
    to_step_2(view)

    upload = choose_step(view, 1, [png("phone.png")])
    assert_push_event(view, "image_link_placeholder", %{box: @box, placeholder: "![Uploading phone.png…]()"})

    upload_all(view, @text_form, upload)
    [phone] = attachments(card)

    assert phone.comment_id == nil
    assert has_element?(view, "##{@box}-pending-#{phone.id}")
    markdown = link(phone)
    assert_push_event(view, "image_link_done", %{box: @box, markdown: ^markdown})
  end

  describe "3. while an image is in flight" do
    test "Back and Send are disabled on step 2 and Back is ignored", ctx do
      {view, _card} = open_stepper(ctx)
      to_step_2(view)
      upload = choose_step(view, 1, [png("slow.png")], "wait")
      upload_all(view, @text_form, upload, 50)

      assert has_element?(view, "#needs-input-send[disabled]")
      assert has_element?(view, "#needs-input-back[disabled]")

      render_click(view, "answer_back", %{})
      assert has_element?(view, "#needs-input-progress", "Question 2 of 2")
    end

    test "Next is disabled on step 1", ctx do
      {view, _card} = open_stepper(ctx)
      upload = choose_step(view, 0, [png("slow.png")], "see")
      upload_all(view, @text_form, upload, 50)

      assert has_element?(view, "#needs-input-next[disabled]")

      render_click(view, "answer_next", %{})
      assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    end

    test "an option click records but does not commit the step", ctx do
      {view, _card} = open_stepper(ctx)
      upload = choose_step(view, 0, [png("slow.png")])
      upload_all(view, @text_form, upload, 50)

      view |> element("#needs-input-option-1") |> render_click()

      assert has_element?(view, "#needs-input-option-1.needs-input-option-selected")
      assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    end

    test "Send to AI is refused", ctx do
      {view, card} = open_stepper(ctx)
      to_step_2(view)
      upload = choose_step(view, 1, [png("slow.png")], "wait")
      upload_all(view, @text_form, upload, 50)

      render_click(view, "answer_submit", %{})

      assert Repo.reload!(card).status == :needs_input
    end
  end

  test "4. Send to AI posts a FROM ANSWER · Q2 note with the answer", %{user: user} = ctx do
    {view, card} = open_stepper(ctx)
    to_step_2(view)
    attach_step(view, 1, [png("phone.png")])
    [phone] = attachments(card)
    text = "like this: " <> link(phone)

    view |> form(@text_form, answer: %{index: "1", text: text}) |> render_change()
    view |> element("#needs-input-send") |> render_click()

    assert Repo.reload!(card).status == :working

    assert [%Comment{origin: :answer, origin_question: 2, body: body, images: [%{id: id}]} = note] =
             answer_notes(card)

    assert body in [nil, ""]
    assert id == phone.id
    assert note.user_id == user.id
    assert answer_comment(card, "1. Which layout? → A\n2. Where should the error show? → " <> text)
  end

  test "5. images on both steps post one note per question, in order", ctx do
    {view, card} = open_stepper(ctx)
    attach_step(view, 0, [png("one.png")], "see")
    [one] = attachments(card)

    view |> element("#needs-input-next") |> render_click()
    attach_step(view, 1, [png("two.png")], "here")
    [_one, two] = attachments(card)

    view |> form(@text_form, answer: %{index: "1", text: "here"}) |> render_change()
    view |> element("#needs-input-send") |> render_click()

    assert [
             %Comment{origin_question: 1, images: [%{id: first}]},
             %Comment{origin_question: 2, images: [%{id: second}]}
           ] = answer_notes(card)

    assert first == one.id
    assert second == two.id
  end

  test "6. each step shows only its own thumbnails", ctx do
    {view, card} = open_stepper(ctx)
    to_step_2(view)
    attach_step(view, 1, [png("phone.png")])
    [phone] = attachments(card)

    view |> element("#needs-input-back") |> render_click()
    assert has_element?(view, "#needs-input-progress", "Question 1 of 2")
    refute has_element?(view, "##{@box}-pending")

    view |> element("#needs-input-next") |> render_click()
    assert has_element?(view, "##{@box}-pending-#{phone.id}")
  end

  test "7. a 7th image on a step is refused; another step still has room", ctx do
    {view, card} = open_stepper(ctx)
    to_step_2(view)
    attach_step(view, 1, for(n <- 1..Comment.max_images(), do: png("s#{n}.png")))
    attach_step(view, 1, [png("seventh.png")])

    assert thumbs(view) == Comment.max_images()
    assert has_element?(view, "##{@box}-hint p.text-error", @over_cap)

    view |> element("#needs-input-back") |> render_click()
    refute has_element?(view, "##{@box}-hint p.text-error")

    attach_step(view, 0, for(n <- 1..Comment.max_images(), do: png("t#{n}.png")), "see")

    assert thumbs(view) == Comment.max_images()
    assert length(attachments(card)) == 2 * Comment.max_images()
    refute has_element?(view, "##{@box}-hint p.text-error")
  end

  test "8. ✕ on an uploaded thumbnail drops it and pushes its link's removal", ctx do
    {view, card} = open_stepper(ctx)
    to_step_2(view)
    attach_step(view, 1, [png("phone.png")])
    [phone] = attachments(card)

    view |> element("##{@box}-pending-#{phone.id} button[title=Remove]") |> render_click()

    refute has_element?(view, "##{@box}-pending-#{phone.id}")
    markdown = link(phone)
    assert_push_event(view, "image_link_remove", %{box: @box, markdown: ^markdown})
  end

  describe "the single answer box" do
    setup ctx do
      card = park(ctx, "Ship it?")
      %{card: card, view: open_card(ctx, card)}
    end

    defp attach_single(view, files, body) do
      upload = choose(view, @single_form, %{answer: %{body: body}}, files)
      upload_all(view, @single_form, upload)
    end

    test "9. Send posts a FROM ANSWER · Q1 note with the answer", %{view: view, card: card} do
      assert has_element?(view, "#{@single_form} ##{@box}-attach")
      attach_single(view, [png("shot.png")], "yes")
      [shot] = attachments(card)
      body = "yes " <> link(shot)

      view |> form(@single_form, answer: %{body: body}) |> render_submit()

      assert [%Comment{origin: :answer, origin_question: 1, images: [%{id: id}]}] = answer_notes(card)
      assert id == shot.id
      assert answer_comment(card, body)
    end

    test "10. a blank answer posts nothing and keeps the pending image", %{view: view, card: card} do
      attach_single(view, [png("shot.png")], "")
      [shot] = attachments(card)

      view |> form(@single_form, answer: %{body: "   "}) |> render_submit()

      assert answer_notes(card) == []
      assert Repo.get!(Attachment, shot.id).comment_id == nil
      assert has_element?(view, "##{@box}-pending-#{shot.id}")
    end
  end
end
