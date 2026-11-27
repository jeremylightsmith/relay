defmodule Hamaca.Moderation.NotifierTest do
  @moduledoc "RE510 — the operator's email for every new content report."

  use Hamaca.DataCase, async: true

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Hamaca.Moderation
  alias Hamaca.Moderation.Notifier

  setup do
    board = insert(:board, public_enabled: true, name: "Acme Roadmap")
    stage = insert(:stage, board: board, category: :unstarted)
    poster = insert(:user, name: "Pat Poster")
    idea = insert(:card, stage: stage, posted_by_user_id: poster.id, title: "Dark mode please")
    b = insert(:user, name: "Bea Reporter")

    %{idea: idea, poster: poster, b: b}
  end

  test "a new report emails every superadmin", %{idea: idea, poster: poster, b: b} do
    assert {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam, note: "first"})

    assert_email_sent(fn email ->
      assert email.subject == "New report: Spam on Acme Roadmap"
      assert email.to == [{"", hd(Schemas.Scope.superadmin_emails())}]
      assert email.text_body =~ "Dark mode please"
      assert email.text_body =~ poster.email
      assert email.text_body =~ b.email
      assert email.text_body =~ "first"
      assert email.text_body =~ "/admin/reports"
      assert email.html_body =~ "Dark mode please"
      assert email.html_body =~ "/admin/reports"
    end)
  end

  test "with mail off the report still lands and nothing is sent", %{idea: idea, b: b} do
    Process.put(:mail_enabled, false)

    assert {:ok, _} = Moderation.report(b, {:card, idea.id}, %{reason: :spam})
    refute_email_sent()
  end

  test "dispatch never raises into its caller" do
    log = capture_log(fn -> assert :ok = Notifier.dispatch(fn -> raise "boom" end) end)
    assert log =~ "boom"
  end
end
