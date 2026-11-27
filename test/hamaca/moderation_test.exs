defmodule Hamaca.ModerationTest do
  @moduledoc "RE510 — content reports, auto-hide, the admin actions and suspension writes."

  use Hamaca.DataCase, async: true

  import Swoosh.TestAssertions

  alias Hamaca.Moderation
  alias Schemas.Card
  alias Schemas.Comment
  alias Schemas.ContentReport
  alias Schemas.User

  setup do
    board = insert(:board, public_enabled: true, name: "Acme Roadmap", key: "AC")
    stage = insert(:stage, board: board, category: :unstarted)
    poster = insert(:user)
    idea = insert(:card, stage: stage, posted_by_user_id: poster.id, title: "Dark mode please")

    [a, b, c] = insert_list(3, :user)
    admin = insert(:user, email: hd(Schemas.Scope.superadmin_emails()))

    private = insert(:board, public_enabled: false, key: "PR")
    private_stage = insert(:stage, board: private, category: :in_progress, type: :work)
    insert(:membership, board: private, user: a, email: a.email)
    insert(:membership, board: private, user: b, email: b.email)
    private_card = insert(:card, stage: private_stage)
    m = insert(:comment, card: private_card, user: a, body: "You are all idiots")
    g = insert(:comment, card: private_card)

    %{
      board: board,
      stage: stage,
      poster: poster,
      idea: idea,
      a: a,
      b: b,
      c: c,
      admin: admin,
      private: private,
      private_card: private_card,
      m: m,
      g: g
    }
  end

  defp ids(users), do: Enum.map(users, & &1.id)

  defp reports_for(:card, id), do: Repo.all(from(r in ContentReport, where: r.card_id == ^id, order_by: r.id))
  defp reports_for(:comment, id), do: Repo.all(from(r in ContentReport, where: r.comment_id == ^id, order_by: r.id))

  describe "report/3" do
    test "records a card report with a trimmed note and leaves the card visible", %{b: b, idea: idea} do
      assert {:ok, report} = Moderation.report(b, {:card, idea.id}, %{"reason" => "spam", "note" => "  buy now  "})

      assert report.reason == :spam
      assert report.note == "buy now"
      assert report.resolution == nil
      assert report.reporter_id == b.id
      assert report.card_id == idea.id
      assert Repo.reload!(idea).hidden_at == nil
    end

    test "a repeat report by the same person returns the first and changes nothing", %{b: b, idea: idea} do
      assert {:ok, first} = Moderation.report(b, {:card, idea.id}, %{"reason" => "spam"})
      assert_email_sent()

      assert {:ok, %ContentReport{id: id}} = Moderation.report(b, {:card, idea.id}, %{reason: :other})
      assert id == first.id

      assert [only] = reports_for(:card, idea.id)
      assert only.reason == :spam
      refute_email_sent()
    end

    test "auto-hides the item once auto_hide_threshold/0 distinct people report it", %{b: b, c: c, idea: idea} do
      reporters = Enum.take([b, c | insert_list(5, :user)], Moderation.auto_hide_threshold())
      {last, earlier} = List.pop_at(reporters, -1)

      for reporter <- earlier, do: {:ok, _} = Moderation.report(reporter, {:card, idea.id}, %{reason: :spam})
      assert Repo.reload!(idea).hidden_at == nil

      {:ok, _} = Moderation.report(last, {:card, idea.id}, %{reason: :spam})
      hidden = Repo.reload!(idea)
      assert hidden.hidden_reason == :auto_reports
      assert hidden.hidden_at
    end

    test "never lets a poster report their own idea", %{poster: poster, idea: idea} do
      assert {:error, :own_content} = Moderation.report(poster, {:card, idea.id}, %{reason: :spam})
    end

    test "refuses cards that are not on a live public board", %{b: b, board: board} do
      private_board = insert(:board, public_enabled: false)
      private_stage = insert(:stage, board: private_board, category: :unstarted)
      off_public = insert(:card, stage: private_stage)

      done_stage = insert(:stage, board: board, category: :complete, type: :done)
      done = insert(:card, stage: done_stage)

      unstarted = insert(:stage, board: board, category: :unstarted)
      archived = insert(:card, stage: unstarted, archived_at: ~U[2026-01-01 00:00:00Z])

      for card <- [off_public, done, archived] do
        assert {:error, :not_reportable} = Moderation.report(b, {:card, card.id}, %{reason: :spam})
      end
    end

    test "lets a member report another human's comment, and nothing else", %{a: a, b: b, c: c, m: m, g: g} do
      assert {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :harassment})
      assert {:error, :not_reportable} = Moderation.report(b, {:comment, g.id}, %{reason: :harassment})
      assert {:error, :own_content} = Moderation.report(a, {:comment, m.id}, %{reason: :harassment})
      assert {:error, :not_reportable} = Moderation.report(c, {:comment, m.id}, %{reason: :harassment})
    end

    test "an unknown reason string is a changeset error on :reason", %{b: b, idea: idea} do
      assert {:error, %Ecto.Changeset{} = changeset} = Moderation.report(b, {:card, idea.id}, %{reason: "bogus"})
      assert errors_on(changeset)[:reason]
    end

    test "a note over note_max_length/0 is a changeset error on :note", %{b: b, idea: idea} do
      note = String.duplicate("x", ContentReport.note_max_length() + 1)
      assert ContentReport.note_max_length() == 1000

      assert {:error, changeset} = Moderation.report(b, {:card, idea.id}, %{reason: :spam, note: note})
      assert errors_on(changeset)[:note]
    end

    test "a blank note is stored as nil", %{b: b, idea: idea} do
      assert {:ok, report} = Moderation.report(b, {:card, idea.id}, %{reason: :spam, note: "   "})
      assert Repo.reload!(report).note == nil
    end

    test "a suspended user cannot report", %{b: b, idea: idea} do
      b = suspend!(b)
      assert {:error, :suspended} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
    end
  end

  describe "hidden_for_reporter_ids/2" do
    test "names every item the user reported, whatever its resolution", %{b: b, idea: idea, m: m, admin: admin} do
      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :spam})

      assert Moderation.hidden_for_reporter_ids(b, :card) == MapSet.new([idea.id])
      assert Moderation.hidden_for_reporter_ids(b, :comment) == MapSet.new([m.id])
      assert Moderation.hidden_for_reporter_ids(nil, :card) == MapSet.new()

      {:ok, _} = Moderation.dismiss(admin, {:card, idea.id})
      assert MapSet.member?(Moderation.hidden_for_reporter_ids(b, :card), idea.id)
    end
  end

  describe "list_open/0" do
    test "groups open reports into one row per item", ctx do
      %{b: b, c: c, idea: idea, m: m, poster: poster, private: private, private_card: private_card} = ctx

      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam, note: "first"})
      {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :harassment})
      {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :other})

      rows = Moderation.list_open()
      assert length(rows) == 2

      idea_row = Enum.find(rows, &(&1.kind == :card))
      assert idea_row.key == "card-#{idea.id}"
      assert idea_row.target_id == idea.id
      assert idea_row.report_count == 2
      assert ids(idea_row.reporters) == [b.id, c.id]
      assert idea_row.latest_reason == :harassment
      assert idea_row.status == :auto_hidden
      assert idea_row.poster.id == poster.id
      assert [%{reporter: %User{id: reporter_id}, note: "first"}] = idea_row.notes
      assert reporter_id == b.id
      assert idea_row.due_at == DateTime.add(idea_row.first_reported_at, Moderation.response_sla_hours() * 3600)
      assert idea_row.board.name == "Acme Roadmap"
      assert idea_row.card_ref == Card.ref(ctx.board, idea)
      assert idea_row.resolution == nil
      assert idea_row.resolved_by == nil
      assert idea_row.resolved_at == nil
      assert idea_row.undo_report_id == nil

      comment_row = Enum.find(rows, &(&1.kind == :comment))
      assert comment_row.key == "comment-#{m.id}"
      assert comment_row.card_ref == Card.ref(private, private_card)
      assert comment_row.status == :reporter_only
      assert comment_row.full_text == m.body
      assert comment_row.poster.id == ctx.a.id

      assert Moderation.open_count() == 2
    end

    test "a card's excerpt is its title and public description", %{b: b, stage: stage, poster: poster} do
      card = insert(:card, stage: stage, posted_by_user_id: poster.id, title: "Title", public_description: "Body")
      {:ok, _} = Moderation.report(b, {:card, card.id}, %{reason: :spam})

      assert [%{excerpt: "Title — Body", full_text: "Title — Body"}] = Moderation.list_open()
    end

    test "cuts a long excerpt to 140 characters", %{b: b, private_card: private_card, a: a} do
      body = String.duplicate("a", 200)
      long = insert(:comment, card: private_card, user: a, body: body)
      {:ok, _} = Moderation.report(b, {:comment, long.id}, %{reason: :spam})

      assert [row] = Moderation.list_open()
      assert String.length(row.excerpt) == 140
      assert String.ends_with?(row.excerpt, "…")
      assert row.full_text == body
    end
  end

  describe "excerpt/1" do
    test "trims, and reads nil as empty" do
      assert Moderation.excerpt("  short  ") == "short"
      assert Moderation.excerpt(nil) == ""
    end
  end

  describe "dismiss/2 and undo/2" do
    test "dismiss resolves every open report and unhides the item", %{b: b, c: c, idea: idea, admin: admin} do
      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :spam})

      assert {:ok, 2} = Moderation.dismiss(admin, {:card, idea.id})
      assert Repo.reload!(idea).hidden_at == nil

      for report <- reports_for(:card, idea.id) do
        assert report.resolution == :dismissed
        assert report.resolved_by_id == admin.id
        assert report.resolved_at
        assert report.prior_hidden_reason == :auto_reports
      end

      assert Moderation.list_open() == []
      assert [row] = Moderation.list_resolved()
      assert row.resolution == :dismissed
      assert row.resolved_by.id == admin.id
      assert row.key == "card-#{idea.id}-#{DateTime.to_unix(row.resolved_at)}"
    end

    test "undo restores the item and reopens its reports", %{b: b, c: c, idea: idea, admin: admin} do
      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :spam})
      {:ok, 2} = Moderation.dismiss(admin, {:card, idea.id})
      [row] = Moderation.list_resolved()

      assert :ok = Moderation.undo(admin, row.undo_report_id)
      assert Repo.reload!(idea).hidden_reason == :auto_reports

      for report <- reports_for(:card, idea.id) do
        assert %{resolution: nil, resolved_by_id: nil, resolved_at: nil} = report
      end

      assert [%{kind: :card, target_id: target_id}] = Moderation.list_open()
      assert target_id == idea.id
      assert Moderation.list_resolved() == []
    end

    test "leaves an admin hide alone; it clears only an auto-hide", %{b: b, c: c, idea: idea, admin: admin} do
      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      {:ok, 1} = Moderation.hide(admin, {:card, idea.id})
      {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :spam})

      assert {:ok, 1} = Moderation.dismiss(admin, {:card, idea.id})

      hidden = Repo.reload!(idea)
      assert hidden.hidden_reason == :admin
      assert hidden.hidden_at
    end

    test "undo of a dismiss that cleared nothing leaves a later hide alone",
         %{b: b, c: c, idea: idea, admin: admin} do
      {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      {:ok, 1} = Moderation.dismiss(admin, {:card, idea.id})
      {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :spam})
      {:ok, 1} = Moderation.hide(admin, {:card, idea.id})

      dismissed = Enum.find(Moderation.list_resolved(), &(&1.resolution == :dismissed))
      assert :ok = Moderation.undo(admin, dismissed.undo_report_id)

      hidden = Repo.reload!(idea)
      assert hidden.hidden_reason == :admin
      assert hidden.hidden_at
    end
  end

  describe "hide/2" do
    test "hides the item for everyone, and undo restores its prior state", %{b: b, m: m, admin: admin} do
      {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :harassment})

      assert {:ok, 1} = Moderation.hide(admin, {:comment, m.id})
      assert Repo.reload!(m).hidden_reason == :admin

      [row] = Moderation.list_resolved()
      assert row.resolution == :hidden
      assert :ok = Moderation.undo(admin, row.undo_report_id)

      restored = Repo.reload!(m)
      assert restored.hidden_at == nil
      assert restored.hidden_reason == nil
    end
  end

  describe "suspend/2" do
    test "suspends the poster and hides the item; undo reverses both", %{a: a, b: b, m: m, admin: admin} do
      {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :harassment})

      assert {:ok, %User{} = user} = Moderation.suspend(admin, {:comment, m.id})
      assert user.id == a.id
      assert User.suspended?(user)
      assert Repo.reload!(a).suspended_by_id == admin.id
      assert Repo.reload!(m).hidden_reason == :admin

      assert [report] = reports_for(:comment, m.id)
      assert report.resolution == :suspended
      assert report.suspended_user_id == a.id

      [row] = Moderation.list_resolved()
      assert :ok = Moderation.undo(admin, row.undo_report_id)

      assert Repo.reload!(a).suspended_at == nil
      assert Repo.reload!(m).hidden_at == nil
      assert [%{resolution: nil}] = reports_for(:comment, m.id)
    end

    test "undo leaves a poster suspended who was already suspended before", %{a: a, b: b, m: m, admin: admin} do
      suspend!(a)
      {:ok, _} = Moderation.report(b, {:comment, m.id}, %{reason: :harassment})
      {:ok, _} = Moderation.suspend(admin, {:comment, m.id})

      assert [%{suspended_user_id: nil}] = reports_for(:comment, m.id)

      [row] = Moderation.list_resolved()
      :ok = Moderation.undo(admin, row.undo_report_id)
      assert User.suspended?(Repo.reload!(a))
    end

    test "refuses to suspend a superadmin and changes nothing", %{b: b, stage: stage, admin: admin} do
      card = insert(:card, stage: stage, posted_by_user_id: admin.id)
      {:ok, _} = Moderation.report(b, {:card, card.id}, %{reason: :spam})

      assert {:error, :cannot_suspend_superadmin} = Moderation.suspend(admin, {:card, card.id})
      refute User.suspended?(Repo.reload!(admin))
      assert Repo.reload!(card).hidden_at == nil
      assert [%{resolution: nil}] = reports_for(:card, card.id)
    end

    test "is :no_poster for a card with neither a poster nor a creator", %{b: b, stage: stage, admin: admin} do
      card = insert(:card, stage: stage)
      {:ok, _} = Moderation.report(b, {:card, card.id}, %{reason: :spam})

      assert {:error, :no_poster} = Moderation.suspend(admin, {:card, card.id})
    end
  end

  describe "refusals" do
    test "every admin action needs open reports, and undo needs a resolved one", %{b: b, idea: idea, admin: admin} do
      assert {:error, :no_open_reports} = Moderation.dismiss(admin, {:card, idea.id})
      assert {:error, :no_open_reports} = Moderation.hide(admin, {:card, idea.id})
      assert {:error, :no_open_reports} = Moderation.suspend(admin, {:card, idea.id})

      {:ok, open_report} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
      assert {:error, :not_resolved} = Moderation.undo(admin, open_report.id)
      assert {:error, :not_found} = Moderation.undo(admin, -1)
    end
  end

  test "a fresh report on a resolved item opens a new row and keeps the old one", %{b: b, c: c, idea: idea, admin: admin} do
    {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
    {:ok, 1} = Moderation.hide(admin, {:card, idea.id})

    {:ok, _} = Moderation.report(c, {:card, idea.id}, %{reason: :spam})

    assert [%{kind: :card, report_count: 1}] = Moderation.list_open()
    assert [%{resolution: :hidden}] = Moderation.list_resolved()
  end

  describe "hidden_for_everyone?/1" do
    test "reads hidden_at and a suspended author", %{idea: idea, poster: poster, stage: stage, m: m, a: a} do
      suspend!(poster)
      assert Moderation.hidden_for_everyone?(Repo.preload(idea, :posted_by_user))

      hidden = insert(:card, stage: stage, hidden_at: ~U[2026-01-01 00:00:00Z], hidden_reason: :admin)
      assert Moderation.hidden_for_everyone?(Repo.preload(hidden, :posted_by_user))

      untouched = insert(:card, stage: stage)
      refute Moderation.hidden_for_everyone?(Repo.preload(untouched, :posted_by_user))

      suspend!(a)
      assert Moderation.hidden_for_everyone?(Repo.preload(%Comment{} = m, :user))
    end
  end

  test "the policy numbers" do
    assert Moderation.auto_hide_threshold() == 2
    assert Moderation.response_sla_hours() == 24
    assert Moderation.due_soon_hours() == 6
    assert Moderation.resolved_limit() == 100
  end

  describe "Schemas.ContentReport vocabularies" do
    test "reasons, resolutions and hidden reasons, with labels" do
      assert ContentReport.reasons() == [:spam, :harassment, :sexual_violent, :other]

      assert Enum.map(ContentReport.reasons(), &ContentReport.reason_label/1) ==
               ["Spam", "Harassment or hate", "Sexual or violent", "Something else"]

      assert ContentReport.resolutions() == [:dismissed, :hidden, :suspended]

      assert Enum.map(ContentReport.resolutions(), &ContentReport.resolution_label/1) == [
               "Dismissed",
               "Hidden",
               "Suspended"
             ]

      assert ContentReport.hidden_reasons() == [:auto_reports, :admin]
    end
  end

  describe "content_reports table" do
    test "a report targets exactly one of a card or a comment", %{idea: idea, m: m} do
      assert %ContentReport{card_id: card_id, comment_id: nil} = insert(:content_report, card: idea)
      assert card_id == idea.id

      assert_raise Ecto.ConstraintError, ~r/content_reports_one_target/, fn ->
        insert(:content_report, card: idea, comment: m)
      end
    end
  end

  describe "Schemas.User.suspended?/1" do
    test "is true only with suspended_at set" do
      refute User.suspended?(nil)
      refute User.suspended?(%User{suspended_at: nil})
      assert User.suspended?(%User{suspended_at: ~U[2026-01-01 00:00:00Z]})
    end
  end

  defp suspend!(%User{} = user) do
    user |> Ecto.Changeset.change(suspended_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()
  end
end
