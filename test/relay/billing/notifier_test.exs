defmodule Relay.Billing.NotifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Relay.Factory
  import Swoosh.TestAssertions

  alias Relay.Billing.Notifier

  @billing_url "http://localhost:4000/account/billing"

  setup do
    %{user: build(:user, email: "owner@example.com")}
  end

  test "billing_url/0 is the app URL plus the billing page path" do
    assert Notifier.billing_url() == @billing_url
  end

  describe "sender/1" do
    test "splits a display name from the address" do
      assert Notifier.sender("Relay <billing@relay.example>") == {"Relay", "billing@relay.example"}
      assert Notifier.sender(~s( "Relay Billing"  <billing@relay.example> )) == {"Relay Billing", "billing@relay.example"}
    end

    test "takes a bare address as the address with no name" do
      assert Notifier.sender(" billing@relay.example ") == {"", "billing@relay.example"}
    end
  end

  describe "trial_ending_email/2" do
    test "tells the owner when the trial ends and links to billing", %{user: user} do
      email = Notifier.trial_ending_email(user, ~D[2026-04-03])

      assert recipients(email) == ["owner@example.com"]
      assert email.from == {"Relay", "billing@localhost"}
      assert email.subject == "Your Relay trial ends in 3 days"
      assert email.text_body =~ "Your Relay trial ends on April 3, 2026."
      assert email.text_body =~ "nothing is deleted"
      assert email.text_body =~ "\n\nManage billing: #{@billing_url}"
      assert email.html_body =~ ~s(href="#{@billing_url}")
      assert email.html_body =~ "<p>Your Relay trial ends on April 3, 2026."
    end
  end

  describe "card_declined_email/2" do
    test "names the amount that could not be charged", %{user: user} do
      email = Notifier.card_declined_email(user, 2000)

      assert recipients(email) == ["owner@example.com"]
      assert email.subject == "We couldn't charge your card for Relay"

      assert email.text_body =~
               "We couldn't charge your card for Relay ($20.00). Update it today to keep your boards editable."

      assert email.text_body =~ @billing_url
      assert email.html_body =~ ~s(href="#{@billing_url}")
    end
  end

  describe "paused_email/1" do
    test "says the boards are read-only and nothing is deleted", %{user: user} do
      email = Notifier.paused_email(user)

      assert recipients(email) == ["owner@example.com"]
      assert email.subject == "Your Relay plan is paused"
      assert email.text_body =~ "Nothing's been deleted."
      assert email.text_body =~ @billing_url
    end

    test "escapes the HTML body and carries no styling", %{user: user} do
      html = Notifier.paused_email(user).html_body

      assert html =~ "Nothing&#39;s been deleted."
      refute html =~ "Nothing's"
      refute html =~ "style="
      refute html =~ "class="
      assert html =~ ~s(<p><a href="#{@billing_url}">Manage billing</a></p>)
    end
  end

  describe "deliver/1" do
    test "sends the email through the mailer when mail is enabled", %{user: user} do
      assert Notifier.deliver(Notifier.paused_email(user)) == :ok

      assert_email_sent(subject: "Your Relay plan is paused", to: "owner@example.com")
    end
  end

  describe "dispatch/1" do
    test "never raises into the caller" do
      log =
        capture_log(fn ->
          assert Notifier.dispatch(fn -> raise "boom" end) == :ok
        end)

      assert log =~ "boom"
    end

    test "runs the function inline in test" do
      test_pid = self()

      assert Notifier.dispatch(fn -> send(test_pid, :ran) end) == :ok
      assert_received :ran
    end
  end

  defp recipients(%Swoosh.Email{to: to}), do: Enum.map(to, fn {_name, address} -> address end)
end

defmodule Relay.Billing.NotifierDisabledLogTest do
  # `async: false`: config/test.exs logs warnings and up, and Erlang's primary level filters before
  # Elixir's process level — so letting the notifier's info line reach `capture_log` takes a
  # VM-wide module level. It only widens what is logged (never steers the code under test), and is
  # removed on exit.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Relay.Factory
  import Swoosh.TestAssertions

  alias Relay.Billing.Notifier

  setup do
    Logger.put_module_level(Notifier, :info)
    on_exit(fn -> Logger.delete_module_level(Notifier) end)
  end

  test "deliver/1 only logs when no mail provider is configured" do
    Process.put(:mail_enabled, false)
    user = build(:user, email: "owner@example.com")

    log =
      capture_log([level: :info], fn ->
        assert Notifier.deliver(Notifier.paused_email(user)) == :ok
      end)

    assert_no_email_sent()
    assert log =~ "no mail provider configured"
    assert log =~ ~s(not sending "Your Relay plan is paused" to owner@example.com)
  end
end
