defmodule HamacaWeb.Admin.ReportsLiveTest do
  @moduledoc """
  RE510 — the operator's `/admin/reports` queue: one row per reported item (reason, kind, board,
  due-in countdown, excerpt, poster, reporters, notes, status) on the Open tab, resolved batches on
  the Resolved tab, and Dismiss · Hide content · Suspend · Undo.
  """
  use HamacaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Moderation
  alias Hamaca.Repo
  alias HamacaWeb.Admin.ReportsLive
  alias Schemas.ContentReport
  alias Schemas.Scope

  @path "/admin/reports"

  # `x` is a public idea on "Acme Roadmap" by Dana, reported by Sam (:spam, with a note) and then
  # Lee (:harassment), which auto-hides it. `m` is Morgan's comment on MY1 of the private "Team"
  # board, reported by member Jeremy (:spam). The admin is not a member of "Team".
  setup %{conn: conn} do
    admin = insert(:user, email: hd(Scope.superadmin_emails()), name: "Ops Admin")

    acme = insert(:board, public_enabled: true, name: "Acme Roadmap", key: "AC")
    idea_stage = insert(:stage, board: acme, category: :unstarted)
    dana = insert(:user, name: "Dana V.", email: "dana@example.com")
    x = insert(:card, stage: idea_stage, posted_by_user_id: dana.id, title: "Dark mode please")

    sam = insert(:user, name: "Sam Rivera")
    lee = insert(:user, name: "Lee Park")
    {:ok, _} = Moderation.report(sam, {:card, x.id}, %{reason: :spam, note: "Insulting the team"})
    {:ok, _} = Moderation.report(lee, {:card, x.id}, %{reason: :harassment})

    team = insert(:board, public_enabled: false, name: "Team", key: "MY")
    team_stage = insert(:stage, board: team, category: :in_progress, type: :work)
    morgan = insert(:user, name: "Morgan Keys")
    jeremy = insert(:user, name: "Jeremy L.")
    insert(:membership, board: team, user: morgan, email: morgan.email)
    insert(:membership, board: team, user: jeremy, email: jeremy.email)
    my1 = insert(:card, stage: team_stage, ref_number: 1, title: "Private card")
    m = insert(:comment, card: my1, user: morgan, body: String.trim(String.duplicate("You are all idiots. ", 10)))
    {:ok, _} = Moderation.report(jeremy, {:comment, m.id}, %{reason: :spam})

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      acme: acme,
      idea_stage: idea_stage,
      dana: dana,
      x: x,
      sam: sam,
      lee: lee,
      team: team,
      morgan: morgan,
      m: m
    }
  end

  defp open(conn, path \\ @path) do
    {:ok, view, _html} = live(conn, path)
    view
  end

  defp row(:card, card), do: "#report-row-card-#{card.id}"
  defp row(:comment, comment), do: "#report-row-comment-#{comment.id}"

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp public_ids(board), do: Enum.map(Boards.list_public_cards(board), & &1.id)

  # Moves every report on `target` back so the first was filed `seconds` ago.
  defp reported_ago(field, id, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
    Repo.update_all(from(r in ContentReport, where: field(r, ^field) == ^id), set: [inserted_at: at])
  end

  describe "the Open tab" do
    test "1. lists one row per reported item with reason, kind, board, poster, reporters, notes and status",
         %{conn: conn, x: x, m: m} do
      view = open(conn)

      assert text(view, "#reports-open-count") == "2"
      assert has_element?(view, "#reports-open-count.badge.badge-warning.badge-sm")

      idea = text(view, row(:card, x))
      assert idea =~ "Harassment or hate"
      assert idea =~ "Public idea"
      assert idea =~ "Acme Roadmap"
      assert idea =~ "2 reports"
      assert idea =~ "Dana V. · dana@example.com"
      assert idea =~ "Sam Rivera, Lee Park"
      assert idea =~ "Note from Sam Rivera: Insulting the team"
      assert has_element?(view, "#{row(:card, x)} .badge.badge-warning", "Harassment or hate")
      assert text(view, "#{row(:card, x)}-status") == "Auto-hidden for everyone (2 reports)"

      comment = text(view, row(:comment, m))
      assert comment =~ "Comment"
      assert comment =~ "Team · MY1"
      refute comment =~ "reports"
      assert text(view, "#{row(:comment, m)}-status") == "Hidden for reporter only"
      assert has_element?(view, "#{row(:comment, m)} .badge.badge-ghost", "Spam")
      refute has_element?(view, "#{row(:comment, m)} .badge.badge-warning", "Spam")
    end

    test "renders the breadcrumb, header and tab chrome", %{conn: conn} do
      view = open(conn)

      assert has_element?(view, "#admin-reports-page h1.text-2xl.font-semibold", "Reports")
      assert has_element?(view, "#admin-reports-page nav.flex.items-center.gap-2.text-sm")
      assert has_element?(view, "#admin-reports-page nav span.font-semibold", Hamaca.Brand.name())
      assert has_element?(view, ~s(#admin-reports-page nav a.link.text-base-content\\/65[href="/admin"]), "Admin")
      assert has_element?(view, "#admin-reports-page nav span.font-semibold", "Reports")
      assert has_element?(view, "#admin-reports-page nav span.text-base-content\\/40", "/")

      assert text(view, "#admin-reports-page") =~
               "Respond within #{Moderation.response_sla_hours()} hours. Every new report also emails the operator."

      assert has_element?(view, ~s(#reports-tab-open.btn.btn-sm.join-item.btn-active[href="/admin/reports"]))
      assert has_element?(view, ~s(#reports-tab-resolved.btn.join-item[href="/admin/reports?tab=resolved"]))
      refute has_element?(view, "#reports-tab-resolved.btn-active")
    end

    test "2. the due-in countdown warns when the deadline is within due_soon_hours", %{conn: conn, x: x, m: m} do
      reported_ago(:card_id, x.id, 21 * 3600 + 30)
      reported_ago(:comment_id, m.id, 2 * 3600 + 30)

      view = open(conn)

      assert text(view, "#{row(:card, x)}-due") == "due in 3h"
      assert has_element?(view, "#{row(:card, x)}-due.text-warning")
      assert has_element?(view, "article#{row(:card, x)}.border-warning\\/50")
      assert text(view, row(:card, x)) =~ "· reported 21h ago · 2 reports"

      assert text(view, "#{row(:comment, m)}-due") == "due in 22h"
      refute has_element?(view, "#{row(:comment, m)}-due.text-warning")
      refute has_element?(view, "article#{row(:comment, m)}.border-warning\\/50")
      assert has_element?(view, "article#{row(:comment, m)}.border-base-300")
    end

    test "4. a non-member admin sees a comment's full text and no View in context",
         %{conn: conn, x: x, m: m, acme: acme} do
      view = open(conn)

      refute has_element?(view, "#{row(:comment, m)}-context")
      assert text(view, "#{row(:comment, m)} blockquote") == "“#{m.body}”"

      assert has_element?(
               view,
               ~s(#{row(:card, x)}-context[href="/board/#{acme.slug}/public?idea=#{x.id}"][target="_blank"])
             )
    end

    test "4. a member admin gets View in context into the private board and the excerpt",
         %{conn: conn, admin: admin, team: team, m: m} do
      insert(:membership, board: team, user: admin, email: admin.email)

      view = open(conn)

      assert has_element?(view, ~s(#{row(:comment, m)}-context[href="/board/#{team.slug}?card=MY1"]))
      assert text(view, "#{row(:comment, m)} blockquote") == "“#{Moderation.excerpt(m.body)}”"
    end

    test "9. with no reports it shows the empty state and a zero count", %{conn: conn} do
      Repo.delete_all(ContentReport)

      view = open(conn)

      assert text(view, "#admin-reports-empty") == "No open reports. Nice."
      assert text(view, "#reports-open-count") == "0"
    end

    test "10. an item with no poster reads — and offers no Suspend", %{conn: conn, idea_stage: stage, sam: sam} do
      orphan = insert(:card, stage: stage, title: "Owner-made idea")
      {:ok, _} = Moderation.report(sam, {:card, orphan.id}, %{reason: :other})

      view = open(conn)

      assert has_element?(view, "#{row(:card, orphan)} dt", "Posted by")
      assert has_element?(view, "#{row(:card, orphan)} dd", "—")
      refute has_element?(view, "#{row(:card, orphan)}-suspend")
    end
  end

  describe "the admin actions" do
    test "5. Hide content resolves the row and hides the comment for everyone",
         %{conn: conn, m: m} do
      reported_ago(:comment_id, m.id, 2 * 3600 + 30)
      view = open(conn)

      view |> element("#{row(:comment, m)}-hide") |> render_click()

      refute has_element?(view, row(:comment, m))
      assert text(view, "#reports-open-count") == "1"
      assert Repo.reload(m).hidden_reason == :admin

      view |> element("#reports-tab-resolved") |> render_click()
      assert has_element?(view, "#reports-tab-resolved.btn-active")
      [resolved] = Moderation.list_resolved()

      assert text(view, "#report-row-#{resolved.key}") =~ "Hidden by Ops Admin · 2h after report"
      assert text(view, "#report-row-#{resolved.key}") =~ "“#{Moderation.excerpt(m.body)}” on Team"
      assert has_element?(view, "#report-row-#{resolved.key}-undo", "Undo")
    end

    test "6. Undo on a resolved row unhides the item and reopens its reports", %{conn: conn, admin: admin, m: m} do
      {:ok, _} = Moderation.hide(admin, {:comment, m.id})
      [resolved] = Moderation.list_resolved()
      view = open(conn, "#{@path}?tab=resolved")

      view |> element("#report-row-#{resolved.key}-undo") |> render_click()

      assert Repo.reload(m).hidden_at == nil
      refute has_element?(view, "#report-row-#{resolved.key}")

      view |> element("#reports-tab-open") |> render_click()
      assert has_element?(view, row(:comment, m))
      assert text(view, "#{row(:comment, m)}-status") == "Hidden for reporter only"
    end

    test "7. Dismiss clears the auto-hide and its Undo restores it", %{conn: conn, x: x} do
      view = open(conn)

      view |> element("#{row(:card, x)}-dismiss") |> render_click()

      assert Repo.reload(x).hidden_at == nil
      view |> element("#reports-tab-resolved") |> render_click()
      [resolved] = Moderation.list_resolved()
      assert text(view, "#report-row-#{resolved.key}") =~ "Dismissed by Ops Admin"

      view |> element("#report-row-#{resolved.key}-undo") |> render_click()
      assert Repo.reload(x).hidden_reason == :auto_reports
    end

    # `x` is auto-hidden before the suspension, so Undo puts it back to that state (not to public);
    # Dana's other, unreported idea `y` shows the suspension itself being lifted.
    test "8. Suspend locks the poster out, disconnects their sockets, and Undo lifts it",
         %{conn: conn, x: x, dana: dana, acme: acme, idea_stage: stage} do
      y = insert(:card, stage: stage, posted_by_user_id: dana.id, title: "Unreported idea")
      assert y.id in public_ids(acme)
      HamacaWeb.Endpoint.subscribe("users_sessions:#{dana.id}")
      view = open(conn)

      assert text(view, "#{row(:card, x)}-suspend") == "Suspend Dana V."
      view |> element("#{row(:card, x)}-suspend") |> render_click()

      assert Repo.reload(dana).suspended_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute x.id in public_ids(acme)
      refute y.id in public_ids(acme)

      view |> element("#reports-tab-resolved") |> render_click()
      [resolved] = Moderation.list_resolved()
      assert text(view, "#report-row-#{resolved.key}") =~ "Suspended by Ops Admin"

      view |> element("#report-row-#{resolved.key}-undo") |> render_click()
      assert Repo.reload(dana).suspended_at == nil
      assert y.id in public_ids(acme)
      assert Repo.reload(x).hidden_reason == :auto_reports
    end

    test "Suspend refuses a superadmin poster with a flash", %{conn: conn, admin: admin, team: team, m: m} do
      insert(:membership, board: team, user: admin, email: admin.email)
      boss = insert(:comment, card: Repo.preload(m, :card).card, user: admin, body: "Superadmin speaking")
      reporter = insert(:user)
      insert(:membership, board: team, user: reporter, email: reporter.email)
      {:ok, _} = Moderation.report(reporter, {:comment, boss.id}, %{reason: :other})
      view = open(conn)

      html = view |> element("#{row(:comment, boss)}-suspend") |> render_click()

      assert html =~ "Superadmins can&#39;t be suspended."
      assert has_element?(view, row(:comment, boss))
    end

    test "ignores an action whose id is not an integer", %{conn: conn, x: x} do
      view = open(conn)

      render_click(view, "hide", %{"kind" => "card", "id" => "nope"})
      render_click(view, "undo", %{"report-id" => "nope"})

      assert has_element?(view, row(:card, x))
      assert text(view, "#reports-open-count") == "2"
    end
  end

  describe "due_label/2" do
    test "3. rounds the remaining or elapsed hours up" do
      due = ~U[2026-01-02 00:00:00Z]

      assert ReportsLive.due_label(due, ~U[2026-01-01 21:00:00Z]) == "due in 3h"
      assert ReportsLive.due_label(due, ~U[2026-01-01 22:59:00Z]) == "due in 2h"
      assert ReportsLive.due_label(due, ~U[2026-01-02 00:30:00Z]) == "overdue 1h"
    end
  end

  describe "elapsed_label/2" do
    test "3. floors to minutes, hours or days" do
      t = ~U[2026-01-01 00:00:00Z]

      assert ReportsLive.elapsed_label(t, DateTime.add(t, 4 * 3600)) == "4h"
      assert ReportsLive.elapsed_label(t, DateTime.add(t, 90)) == "1m"
      assert ReportsLive.elapsed_label(t, DateTime.add(t, 3 * 86_400)) == "3d"
    end
  end
end
