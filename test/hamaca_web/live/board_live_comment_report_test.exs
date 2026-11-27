defmodule HamacaWeb.BoardLiveCommentReportTest do
  @moduledoc """
  RE510 — in the card drawer a member reports another human member's comment (⋯ → modal →
  confirmation), it collapses for them with "Show anyway", and a comment hidden by moderation (or
  written by a suspended user) renders only as "Hidden by Hamaca moderation." with no body sent.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hamaca.Activity
  alias Hamaca.Attachments
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Moderation
  alias Hamaca.Repo
  alias Schemas.ContentReport

  setup :register_and_log_in_user

  # `a` (the signed-in user) owns the board; `b` and `c` are members. Card MY1 carries `ca` by `a`,
  # `cb` by `b` and the agent comment `cg`.
  setup %{user: a} do
    board = Boards.get_or_create_default_board(a)
    review = Enum.find(board.stages, &(&1.name == "Review"))
    {:ok, card} = Cards.create_card(review, %{title: "Review me"})

    b = insert(:user, name: "Morgan Keys")
    c = insert(:user)
    insert(:membership, board: board, user: b, email: b.email)
    insert(:membership, board: board, user: c, email: c.email)

    ca = note(card, {:user, a.id}, "Agreed, after the theme tokens land.")
    cb = note(card, {:user, b.id}, "This whole board is a joke, honestly.")
    cg = note(card, :agent, "Done, see the PR.")

    %{board: board, card: card, a: a, b: b, c: c, ca: ca, cb: cb, cg: cg}
  end

  defp note(card, actor, body, image_ids \\ []) do
    {:ok, comment} = Activity.add_comment(card, %{actor: actor, body: body, image_ids: image_ids})
    comment
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp open_drawer(%{conn: conn, board: board}), do: open(conn, ~p"/board/#{board.slug}?card=MY1")

  defp entry(comment), do: "#timeline-comment-#{comment.id}"

  defp click_report(view, comment), do: view |> element("#{entry(comment)}-report") |> render_click()

  defp submit_report(view, reason), do: view |> form("#report-form", report: %{reason: reason}) |> render_submit()

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp report_exists?(user, comment),
    do: Repo.exists?(from(r in ContentReport, where: r.reporter_id == ^user.id and r.comment_id == ^comment.id))

  defp images!(card, names) do
    for name <- names do
      {:ok, image} =
        Attachments.create_attachment(card, %{filename: name, content_type: "image/png", bytes: "png #{name}"})

      image
    end
  end

  defp suspend!(user, at), do: user |> Ecto.Changeset.change(suspended_at: at) |> Repo.update!()

  describe "the comment ⋯ menu" do
    test "2. another member's comment gets Report; your own and the agent's get no ⋯", ctx do
      view = open_drawer(ctx)

      assert has_element?(view, "#{entry(ctx.cb)}-menu.dropdown.ml-auto")
      assert has_element?(view, "#{entry(ctx.cb)}-report[phx-value-kind='comment'][phx-value-id='#{ctx.cb.id}']")
      assert text(view, "#{entry(ctx.cb)}-report") == "⚑Report comment"
      refute has_element?(view, "#{entry(ctx.ca)}-menu")
      refute has_element?(view, "#{entry(ctx.cg)}-menu")
    end
  end

  describe "reporting a comment" do
    test "3. Report opens the modal, and sending it confirms and records the report", ctx do
      view = open_drawer(ctx)

      click_report(view, ctx.cb)

      assert has_element?(view, "#report-modal h3", "Report comment")
      assert has_element?(view, "#report-modal", "“#{Moderation.excerpt(ctx.cb.body)}”")
      assert has_element?(view, "#report-submit[disabled]")

      submit_report(view, "harassment")

      assert has_element?(view, "#report-sent", "The comment is hidden for you in the meantime.")
      assert report_exists?(ctx.a, ctx.cb)
    end

    test "4. after Done the comment collapses for the reporter, and Show anyway reveals it", ctx do
      view = open_drawer(ctx)
      click_report(view, ctx.cb)
      submit_report(view, "harassment")

      view |> element("#report-done") |> render_click()

      refute has_element?(view, "#report-modal")
      assert has_element?(view, "#{entry(ctx.cb)}-reported", "You reported this comment.")
      refute render(view) =~ ctx.cb.body

      view |> element("#{entry(ctx.cb)}-reported-show") |> render_click()

      refute has_element?(view, "#{entry(ctx.cb)}-reported")
      assert has_element?(view, entry(ctx.cb), ctx.cb.body)
    end

    test "5. a comment the viewer reported earlier opens collapsed", ctx do
      {:ok, _report} = Moderation.report(ctx.a, {:comment, ctx.cb.id}, %{reason: :spam})

      view = open_drawer(ctx)

      assert has_element?(view, "#{entry(ctx.cb)}-reported", "You reported this comment.")
      refute render(view) =~ ctx.cb.body
    end

    test "9. the native card host gets Report too", ctx do
      view = open(ctx.conn, ~p"/cards/MY1?board=#{ctx.board.slug}")

      click_report(view, ctx.cb)
      submit_report(view, "spam")

      assert has_element?(view, "#report-sent")
      assert report_exists?(ctx.a, ctx.cb)
    end

    test "10. a forged open_report for a comment on another board opens nothing", ctx do
      elsewhere = insert(:comment, card: insert(:card), user: insert(:user))
      view = open_drawer(ctx)

      render_click(view, "open_report", %{"kind" => "comment", "id" => to_string(elsewhere.id)})

      refute has_element?(view, "#report-modal")
    end

    test "10. a forged open_report for your own or an agent's comment opens nothing", ctx do
      view = open_drawer(ctx)

      for comment <- [ctx.ca, ctx.cg] do
        render_click(view, "open_report", %{"kind" => "comment", "id" => to_string(comment.id)})
        refute has_element?(view, "#report-modal")
      end
    end
  end

  describe "the moderation placeholder" do
    test "6. an admin-hidden comment renders only the placeholder, and the count is unchanged", ctx do
      before = open_drawer(ctx)
      count = text(before, "#card-drawer-note-count")

      {:ok, _report} = Moderation.report(ctx.c, {:comment, ctx.cb.id}, %{reason: :harassment})
      {:ok, 1} = Moderation.hide(insert(:user), {:comment, ctx.cb.id})

      view = open_drawer(ctx)

      assert text(view, "#{entry(ctx.cb)}-moderated") == "Hidden by #{Hamaca.Brand.name()} moderation."

      assert has_element?(
               view,
               "#{entry(ctx.cb)}-moderated.rounded-lg.border.border-dashed.border-base-300.px-3.py-2.text-xs"
             )

      refute render(view) =~ ctx.cb.body
      refute has_element?(view, "#{entry(ctx.cb)}-menu")
      refute has_element?(view, "#{entry(ctx.cb)} button")
      assert text(view, "#card-drawer-note-count") == count
    end

    test "7. a suspended author's comment renders as the placeholder until they're unsuspended", ctx do
      suspended = suspend!(ctx.b, DateTime.utc_now(:second))

      view = open_drawer(ctx)

      assert has_element?(view, "#{entry(ctx.cb)}-moderated", "Hidden by #{Hamaca.Brand.name()} moderation.")
      refute render(view) =~ ctx.cb.body

      suspend!(suspended, nil)

      view = open_drawer(ctx)

      refute has_element?(view, "#{entry(ctx.cb)}-moderated")
      assert has_element?(view, entry(ctx.cb), ctx.cb.body)
      assert has_element?(view, "#{entry(ctx.cb)}-report")
    end

    test "8. a hidden comment's images render no thumbnail", ctx do
      images =
        for name <- ~w(one.png two.png) do
          {:ok, image} =
            Attachments.create_attachment(ctx.card, %{filename: name, content_type: "image/png", bytes: "png #{name}"})

          image
        end

      cd = note(ctx.card, {:user, ctx.b.id}, "with pictures", Enum.map(images, & &1.id))
      {:ok, _report} = Moderation.report(ctx.c, {:comment, cd.id}, %{reason: :spam})
      {:ok, 1} = Moderation.hide(insert(:user), {:comment, cd.id})

      view = open_drawer(ctx)

      assert has_element?(view, "#{entry(cd)}-moderated")

      for image <- images do
        refute has_element?(view, "#{entry(cd)} img[src='#{HamacaWeb.attachment_path(image.id)}']")
      end

      refute has_element?(view, "#{entry(cd)}-images")
    end

    test "8. a hidden comment's images never reach the images viewer", ctx do
      [shown, hidden] = images!(ctx.card, ~w(shown.png hidden.png))
      note(ctx.card, {:user, ctx.a.id}, "visible", [shown.id])
      cd = note(ctx.card, {:user, ctx.b.id}, "hidden", [hidden.id])
      {:ok, _report} = Moderation.report(ctx.c, {:comment, cd.id}, %{reason: :spam})
      {:ok, 1} = Moderation.hide(insert(:user), {:comment, cd.id})

      view = open(ctx.conn, ~p"/board/#{ctx.board.slug}?card=MY1&image=#{shown.id}")

      assert has_element?(view, "#mockup-viewer")
      assert text(view, "#mockup-viewer-mockups .section-label") == "Images · 1"
      refute render(view) =~ HamacaWeb.attachment_path(hidden.id)
      refute render(view) =~ "hidden.png"

      view = open(ctx.conn, ~p"/board/#{ctx.board.slug}?card=MY1&image=#{hidden.id}")

      refute has_element?(view, "#mockup-viewer")
      refute render(view) =~ HamacaWeb.attachment_path(hidden.id)
    end

    test "8. a reported comment's images leave the viewer until Show anyway", ctx do
      [shown, reported] = images!(ctx.card, ~w(shown.png reported.png))
      note(ctx.card, {:user, ctx.a.id}, "visible", [shown.id])
      cd = note(ctx.card, {:user, ctx.b.id}, "reported", [reported.id])
      {:ok, _report} = Moderation.report(ctx.a, {:comment, cd.id}, %{reason: :spam})

      view = open(ctx.conn, ~p"/board/#{ctx.board.slug}?card=MY1&image=#{reported.id}")
      refute has_element?(view, "#mockup-viewer")

      view = open(ctx.conn, ~p"/board/#{ctx.board.slug}?card=MY1&image=#{shown.id}")
      assert text(view, "#mockup-viewer-mockups .section-label") == "Images · 1"
      refute render(view) =~ HamacaWeb.attachment_path(reported.id)

      view |> element("#{entry(cd)}-reported-show") |> render_click()

      assert text(view, "#mockup-viewer-mockups .section-label") == "Images · 2"
      assert render(view) =~ HamacaWeb.attachment_path(reported.id)
    end
  end
end
