defmodule HamacaWeb.DevMailboxTest do
  # Not async: Swoosh's Local adapter keeps one global in-memory mailbox.
  use HamacaWeb.ConnCase, async: false

  import Hamaca.Factory

  alias Hamaca.Billing.Notifier
  alias Swoosh.Adapters.Local.Storage.Memory

  setup do
    Memory.delete_all()
    on_exit(&Memory.delete_all/0)
  end

  test "GET /dev/mailbox previews sent mail", %{conn: conn} do
    conn = get(conn, "/dev/mailbox")

    assert conn.status == 200
  end

  test "GET /dev/mailbox renders a delivered billing email", %{conn: conn} do
    email = Notifier.dropped_to_free_email(build(:user, email: "owner@example.com"))
    {:ok, _} = Swoosh.Adapters.Local.deliver(email, [])

    # The index redirects to the newest message, whose page lists every recipient and sender.
    message_path = redirected_to(get(conn, "/dev/mailbox"), 302)
    page = html_response(get(build_conn(), message_path), 200)

    assert page =~ email.subject
    assert page =~ "billing@localhost"
    assert json_response(get(build_conn(), "/dev/mailbox/json"), 200)["data"] != []
  end
end
