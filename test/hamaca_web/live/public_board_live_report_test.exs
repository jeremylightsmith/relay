defmodule HamacaWeb.PublicBoardLiveReportTest do
  @moduledoc "RE510 — reporting ideas on the public board, hidden-for-you, `?idea=` and the footer."

  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Hamaca.Moderation
  alias Hamaca.Repo
  alias Schemas.ContentReport

  setup do
    board = insert(:board, public_enabled: true)
    unstarted = insert(:stage, board: board, category: :unstarted)
    poster = insert(:user)
    x = insert(:card, stage: unstarted, title: "Dark mode", posted_by_user_id: poster.id)
    y = insert(:card, stage: unstarted, title: "Export to CSV")
    [a, b] = insert_list(2, :user)

    %{board: board, poster: poster, x: x, y: y, a: a, b: b}
  end

  defp visit(conn, board, user \\ nil, query \\ "") do
    conn = if user, do: log_in_user(conn, user), else: conn
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/public" <> query)
    view
  end

  defp open_report(view, card), do: view |> element("#public-card-report-#{card.id}") |> render_click()

  defp submit_report(view, params), do: view |> form("#report-form", report: params) |> render_submit()

  defp report_rows(user, card),
    do: Repo.all(from(r in ContentReport, where: r.reporter_id == ^user.id and r.card_id == ^card.id))

  describe "the ⋯ menu" do
    test "a signed-in visitor gets ⋯ → Report this idea on someone else's idea", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)

      assert has_element?(view, "#public-card-menu-#{ctx.x.id}.dropdown")
      assert has_element?(view, "#public-card-report-#{ctx.x.id}", "Report this idea")
    end

    test "the poster gets no Report item on their own idea, but does on others'", ctx do
      view = visit(ctx.conn, ctx.board, ctx.poster)

      refute has_element?(view, "#public-card-report-#{ctx.x.id}")
      assert has_element?(view, "#public-card-report-#{ctx.y.id}")
    end

    test "the menu sits outside the idea's open-detail click target", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)

      refute has_element?(view, "#public-card-open-#{ctx.x.id} #public-card-menu-#{ctx.x.id}")
      assert has_element?(view, "#public-card-open-#{ctx.x.id}", "Dark mode")
    end
  end

  describe "reporting an idea" do
    test "Report opens the modal on the form step with submit disabled until a reason is chosen", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)

      open_report(view, ctx.x)

      assert has_element?(view, "#report-modal", "“Dark mode”")
      assert has_element?(view, "#report-modal h3", "Report this idea")
      assert has_element?(view, "#report-submit[disabled]")
      refute has_element?(view, "#public-card-modal")

      view |> form("#report-form", report: %{reason: "spam"}) |> render_change()

      assert has_element?(view, "#report-submit")
      refute has_element?(view, "#report-submit[disabled]")
    end

    test "sending a report confirms it, records it and emails the operator", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)
      open_report(view, ctx.x)

      submit_report(view, %{reason: "spam", note: "junk"})

      assert has_element?(view, "#report-sent", "Thanks, we got your report")
      assert has_element?(view, "#report-sent", "within #{Moderation.response_sla_hours()} hours")
      assert [%ContentReport{note: "junk", reason: :spam}] = report_rows(ctx.b, ctx.x)
      assert_email_sent()
    end

    test "Done collapses the idea for the reporter, and Show anyway brings it back", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)
      open_report(view, ctx.x)
      submit_report(view, %{reason: "spam", note: "junk"})

      view |> element("#report-done") |> render_click()

      refute has_element?(view, "#report-modal")

      assert has_element?(
               view,
               "#public-card-#{ctx.x.id} #public-card-reported-#{ctx.x.id}",
               "You reported this idea. It's hidden for you while we review it."
             )

      refute has_element?(view, "#public-card-#{ctx.x.id}", "Dark mode")

      view |> element("#public-card-reported-#{ctx.x.id}-show") |> render_click()

      assert has_element?(view, "#public-card-#{ctx.x.id}", "Dark mode")
      refute has_element?(view, "#public-card-reported-#{ctx.x.id}")
    end

    test "submitting with no reason stays on the form and records nothing", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)
      open_report(view, ctx.x)

      # The disabled Send button can't be clicked with no reason, so push the event directly.
      render_submit(view, "submit_report", %{"report" => %{"reason" => "", "note" => ""}})

      assert has_element?(view, "#report-form")
      refute has_element?(view, "#report-sent")
      assert report_rows(ctx.b, ctx.x) == []
    end

    test "Cancel closes the modal without reporting", ctx do
      view = visit(ctx.conn, ctx.board, ctx.b)
      open_report(view, ctx.x)

      view |> element("#report-cancel") |> render_click()

      refute has_element?(view, "#report-modal")
      assert report_rows(ctx.b, ctx.x) == []
    end

    test "a forged open_report for a card not on this board opens nothing", ctx do
      other = insert(:card, title: "Elsewhere")
      view = visit(ctx.conn, ctx.board, ctx.b)

      render_click(view, "open_report", %{"kind" => "card", "id" => Integer.to_string(other.id)})
      render_click(view, "open_report", %{"kind" => "comment", "id" => Integer.to_string(ctx.x.id)})

      refute has_element?(view, "#report-modal")
    end
  end

  describe "hidden for the reporter" do
    test "an idea reported earlier renders collapsed on a fresh mount; Show anyway isn't persisted", ctx do
      {:ok, _report} = Moderation.report(ctx.b, {:card, ctx.x.id}, %{reason: :spam})

      view = visit(ctx.conn, ctx.board, ctx.b)
      assert has_element?(view, "#public-card-reported-#{ctx.x.id}")
      refute has_element?(view, "#public-card-#{ctx.x.id}", "Dark mode")

      view |> element("#public-card-reported-#{ctx.x.id}-show") |> render_click()
      assert has_element?(view, "#public-card-#{ctx.x.id}", "Dark mode")

      fresh = visit(ctx.conn, ctx.board, ctx.b)
      assert has_element?(fresh, "#public-card-reported-#{ctx.x.id}")
    end
  end

  describe "signed out" do
    test "Report opens the sign-in modal titled Sign in to report, never the report modal", ctx do
      view = visit(ctx.conn, ctx.board)

      open_report(view, ctx.x)

      assert has_element?(view, "#public-signin-modal h3", "Sign in to report")
      refute has_element?(view, "#report-modal")
    end
  end

  describe "hidden for everyone" do
    test "auto_hide_threshold distinct reporters hide an idea from the public board but not the board", ctx do
      assert Moderation.auto_hide_threshold() == 2

      for reporter <- [ctx.a, ctx.b], do: {:ok, _} = Moderation.report(reporter, {:card, ctx.x.id}, %{reason: :spam})

      signed_out = visit(ctx.conn, ctx.board)
      refute has_element?(signed_out, "#public-card-#{ctx.x.id}")
      assert has_element?(signed_out, "#public-card-#{ctx.y.id}")

      owner = Repo.preload(ctx.board, :owner).owner
      owner_view = visit(build_conn(), ctx.board, owner)
      refute has_element?(owner_view, "#public-card-#{ctx.x.id}")

      assert Repo.reload(ctx.x).archived_at == nil
    end
  end

  describe "?idea=" do
    test "opens that idea's detail modal", ctx do
      view = visit(ctx.conn, ctx.board, nil, "?idea=#{ctx.y.id}")

      assert has_element?(view, "#public-card-modal h3", "Export to CSV")
    end

    test "an unknown or non-integer id mounts with no modal", ctx do
      refute has_element?(visit(ctx.conn, ctx.board, nil, "?idea=999999"), "#public-card-modal")
      refute has_element?(visit(build_conn(), ctx.board, nil, "?idea=abc"), "#public-card-modal")
    end

    test "an idea hidden for everyone is ignored", ctx do
      for reporter <- [ctx.a, ctx.b], do: {:ok, _} = Moderation.report(reporter, {:card, ctx.x.id}, %{reason: :spam})

      refute has_element?(visit(ctx.conn, ctx.board, nil, "?idea=#{ctx.x.id}"), "#public-card-modal")
    end
  end

  describe "the support footer" do
    test "renders on the public board with links to /support", ctx do
      view = visit(ctx.conn, ctx.board)

      assert has_element?(view, "#public-board-footer", "Powered by Hamaca")
      assert has_element?(view, ~s|#public-footer-report[href="/support#reporting"]|)
      assert has_element?(view, ~s|#public-footer-contact[href="/support#contact"]|)
    end
  end
end
