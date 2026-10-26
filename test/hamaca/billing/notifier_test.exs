defmodule Hamaca.Billing.NotifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Hamaca.Factory
  import Swoosh.TestAssertions

  alias Hamaca.Billing.Notifier

  @billing_url "http://localhost:4000/account/billing"

  setup do
    %{user: build(:user, email: "owner@example.com")}
  end

  test "billing_url/0 is the app URL plus the billing page path" do
    assert Notifier.billing_url() == @billing_url
  end

  describe "sender/1" do
    test "splits a display name from the address" do
      assert Notifier.sender("Hamaca <billing@relay.example>") == {"Hamaca", "billing@relay.example"}

      assert Notifier.sender(~s( "Hamaca Billing"  <billing@relay.example> )) ==
               {"Hamaca Billing", "billing@relay.example"}
    end

    # RE477 scenario 9
    test "the configured sender's display name is Hamaca" do
      assert {"Hamaca", _address} = Notifier.sender(Application.get_env(:hamaca, :mail_from))
    end

    test "takes a bare address as the address with no name" do
      assert Notifier.sender(" billing@relay.example ") == {"", "billing@relay.example"}
    end
  end

  test "the trial-ending email and its lead time are gone" do
    Code.ensure_loaded!(Notifier)
    refute function_exported?(Notifier, :trial_ending_email, 2)
    refute function_exported?(Notifier, :trial_notice_days_before, 0)
    refute function_exported?(Notifier, :paused_email, 1)
  end

  describe "card_declined_email/2" do
    test "names the amount that could not be charged", %{user: user} do
      email = Notifier.card_declined_email(user, 2000)

      assert recipients(email) == ["owner@example.com"]
      assert email.subject == "We couldn't charge your card for Hamaca"

      assert email.text_body =~
               "We couldn't charge your card for Hamaca ($20.00). Update it today to keep your boards editable."

      assert email.text_body =~ @billing_url
      assert email.html_body =~ ~s(href="#{@billing_url}")
    end
  end

  @dropped_to_free_text "We couldn't renew your Hamaca plan, so you're on Free now. Free includes one editable board; " <>
                          "your other boards are read-only and nothing has been deleted. Upgrade any time to unlock them all:"

  describe "dropped_to_free_email/1" do
    test "says the owner is on Free, what that means, and links to upgrade", %{user: user} do
      email = Notifier.dropped_to_free_email(user)

      assert recipients(email) == ["owner@example.com"]
      assert email.subject == "Your Hamaca plan is now Free"
      assert String.starts_with?(email.text_body, "We couldn't renew your Hamaca plan, so you're on Free now.")
      assert email.text_body =~ @dropped_to_free_text <> " " <> @billing_url
      assert email.html_body =~ ~s(href="#{@billing_url}")
    end

    test "escapes the HTML body and carries no styling", %{user: user} do
      html = Notifier.dropped_to_free_email(user).html_body

      assert html =~ "so you&#39;re on Free now."
      refute html =~ "you're"
      refute html =~ "style="
      refute html =~ "class="
      assert html =~ ~s(<p><a href="#{@billing_url}">Manage billing</a></p>)
    end
  end

  describe "deliver/1" do
    test "sends the email through the mailer when mail is enabled", %{user: user} do
      assert Notifier.deliver(Notifier.dropped_to_free_email(user)) == :ok

      assert_email_sent(subject: "Your Hamaca plan is now Free", to: "owner@example.com")
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

defmodule Hamaca.Billing.NotifierDisabledLogTest do
  # `async: false`: config/test.exs logs warnings and up, and Erlang's primary level filters before
  # Elixir's process level — so letting the notifier's info line reach `capture_log` takes a
  # VM-wide module level. It only widens what is logged (never steers the code under test), and is
  # removed on exit.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Hamaca.Factory
  import Swoosh.TestAssertions

  alias Hamaca.Billing.Notifier

  setup do
    Logger.put_module_level(Notifier, :info)
    on_exit(fn -> Logger.delete_module_level(Notifier) end)
  end

  test "deliver/1 only logs when no mail provider is configured" do
    Process.put(:mail_enabled, false)
    user = build(:user, email: "owner@example.com")

    log =
      capture_log([level: :info], fn ->
        assert Notifier.deliver(Notifier.dropped_to_free_email(user)) == :ok
      end)

    assert_no_email_sent()
    assert log =~ "no mail provider configured"
    assert log =~ ~s(not sending "Your Hamaca plan is now Free" to owner@example.com)
  end
end
