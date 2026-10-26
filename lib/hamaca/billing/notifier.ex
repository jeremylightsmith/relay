defmodule Hamaca.Billing.Notifier do
  @moduledoc """
  Billing emails (RE464, RE469): builds the card-declined and dropped-to-Free notices and
  delivers them through `Hamaca.Mailer`.

  `deliver/1` only sends when `:mail_enabled` (read through `Hamaca.Config`) is exactly `true`;
  otherwise it logs what it would have sent — a self-hosted install with no mail provider never
  fails because of email. `dispatch/1` runs a delivery off the caller's process under
  `Hamaca.Billing.TaskSupervisor`, so the billing clock never waits on (or fails because of) the
  mail provider.

  `notify_due/1` (the billing clock's last step) decides which of the two are due on a day and
  sends each **at most once per account and period**: a `Schemas.BillingNotice` row is inserted
  (`on_conflict: :nothing`) before the email is dispatched, and only an insert that created a row
  sends. The unique index `billing_notices_once`, not this code, is the guarantee. Notices are
  recorded even while mail is off, so switching a provider on later never sends a backlog.

  Links point at `billing_url/0`, built from the `:app_url` config (read through `Hamaca.Config`)
  rather than `HamacaWeb.Endpoint` — `Hamaca.Billing` may not depend on the web layer.
  """

  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias Hamaca.Billing
  alias Hamaca.Billing.Charging
  alias Hamaca.Billing.Standing
  alias Hamaca.Brand
  alias Hamaca.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingNotice
  alias Schemas.BillingPaymentAttempt
  alias Schemas.User

  require Logger

  @billing_path "/account/billing"
  @once_target [:billing_account_id, :kind, :period_key]

  @doc """
  Parses the `:mail_from` config (`"Hamaca <billing@example.com>"` or a bare
  `"billing@example.com"`) into Swoosh's `{name, address}`. Handing Swoosh the raw
  `"Name <addr>"` string makes the whole thing the address, which breaks every path that renders
  it (the `/dev/mailbox` preview punycodes the domain `example.com>`).
  """
  @spec sender(String.t()) :: {String.t(), String.t()}
  def sender(mail_from) when is_binary(mail_from) do
    case Regex.run(~r/^\s*(.*?)\s*<([^<>]+)>\s*$/, mail_from) do
      [_, name, address] -> {String.trim(name, "\""), String.trim(address)}
      nil -> {"", String.trim(mail_from)}
    end
  end

  @doc """
  Records and dispatches every billing email due on `today`, each at most once per account and
  period, and answers how many notices it newly recorded:

    * `:card_declined` (period `period_start`) — a `:failed` clock attempt for a period started
      within the last `Standing.grace_days/0` days; its retry shares the period, so one email;
    * `:dropped_to_free` (period `paid_through + grace_days() + 1`, the first Free day) — a paid
      plan whose renewal lapsed past the grace and now stands on `:free`. A never-paid account,
      a hold, a cancellation running out, and a comp never send.

  Each notice is isolated: one failing account is logged and never stops the rest, and this
  never raises into the clock.
  """
  @spec notify_due(Date.t()) :: non_neg_integer()
  def notify_due(%Date{} = today) do
    [&card_declined_due/1, &dropped_to_free_due/1]
    |> Enum.flat_map(&candidates(&1, today))
    |> Enum.count(&notify_isolated/1)
  end

  # Each candidate is `{account, decide}`; `decide` answers `{kind, period_key, email}` or nil.
  defp candidates(finder, today) do
    finder.(today)
  rescue
    error ->
      Logger.error("Billing.Notifier: finding due notices failed. " <> Exception.format(:error, error, __STACKTRACE__))
      []
  end

  defp card_declined_due(today) do
    from(p in BillingPaymentAttempt,
      where:
        p.status == :failed and p.source == :clock and p.period_start >= ^Date.add(today, -Standing.grace_days()) and
          p.period_start <= ^today,
      order_by: p.id,
      preload: [billing_account: :user]
    )
    |> Repo.all()
    |> Enum.map(fn %{billing_account: account} = attempt ->
      {account, fn -> {:card_declined, attempt.period_start, card_declined_email(account.user, attempt.amount_cents)} end}
    end)
  end

  # Pre-filtered in SQL so the hourly scan computes standing only for paid accounts past their grace.
  defp dropped_to_free_due(today) do
    lapsed_before = Date.add(today, -Standing.grace_days())

    from(a in BillingAccount,
      where: not a.comped and is_nil(a.held_on) and is_nil(a.cancelled_on) and a.paid_through < ^lapsed_before,
      preload: :user
    )
    |> Repo.all()
    |> Enum.map(fn account -> {account, fn -> dropped_to_free_notice(account, today) end} end)
  end

  defp dropped_to_free_notice(account, today) do
    if Standing.of(account, Charging.facts(account), today) == :free do
      first_free_day = Date.add(account.paid_through, Standing.grace_days() + 1)
      {:dropped_to_free, first_free_day, dropped_to_free_email(account.user)}
    end
  end

  defp notify_isolated({account, decide}) do
    case decide.() do
      nil -> false
      {kind, period_key, email} -> record_and_send(account, kind, period_key, email)
    end
  rescue
    error ->
      Logger.error(
        "Billing.Notifier: account #{account.id} was not notified. " <> Exception.format(:error, error, __STACKTRACE__)
      )

      false
  end

  # Inserted outside any transaction, so the row has committed before the delivery starts. A
  # conflict answers a row with a nil id: this notice was already sent.
  defp record_and_send(account, kind, period_key, email) do
    notice = %BillingNotice{billing_account_id: account.id, kind: kind, period_key: period_key}

    case Repo.insert(notice, on_conflict: :nothing, conflict_target: @once_target) do
      {:ok, %BillingNotice{id: nil}} ->
        false

      {:ok, %BillingNotice{}} ->
        dispatch(fn -> deliver(email) end)
        true
    end
  end

  @doc "The absolute URL of the Billing page every email links to."
  @spec billing_url() :: String.t()
  def billing_url, do: Hamaca.Config.get(:app_url) <> @billing_path

  @doc "The notice sent when charging `amount_cents` was declined."
  @spec card_declined_email(User.t(), pos_integer()) :: Swoosh.Email.t()
  def card_declined_email(%User{} = user, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    build(user, "We couldn't charge your card for #{Brand.name()}", [
      "We couldn't charge your card for #{Brand.name()} (#{Billing.format_cents(amount_cents)}). " <>
        "Update it today to keep your boards editable."
    ])
  end

  @doc "The notice sent when a lapsed paid plan drops the owner to Free."
  @spec dropped_to_free_email(User.t()) :: Swoosh.Email.t()
  def dropped_to_free_email(%User{} = user) do
    build(user, "Your #{Brand.name()} plan is now Free", [
      "We couldn't renew your #{Brand.name()} plan, so you're on Free now. Free includes one editable board; " <>
        "your other boards are read-only and nothing has been deleted. Upgrade any time to unlock them all: " <>
        billing_url()
    ])
  end

  @doc """
  Sends `email` through `Hamaca.Mailer` when `:mail_enabled` is `true`; otherwise logs that it
  was not sent. Always `:ok` — a failed or raising delivery is logged, never raised.
  """
  @spec deliver(Swoosh.Email.t()) :: :ok
  def deliver(%Swoosh.Email{} = email) do
    if Hamaca.Config.get(:mail_enabled, false) == true do
      send_now(email)
    else
      Logger.info(
        ~s(Billing.Notifier: no mail provider configured; not sending "#{email.subject}" to #{recipient(email)})
      )
    end

    :ok
  end

  @doc """
  Runs `fun` under `Hamaca.Billing.TaskSupervisor` (inline when the notifier config's `:async` is
  false, as in test). Never raises or exits into the caller.
  """
  @spec dispatch((-> any())) :: :ok
  def dispatch(fun) when is_function(fun, 0) do
    safely(fn -> dispatch_now(config(), fun) end)
  end

  # Read once at the boundary (ADR 0009 rule 1), like `Hamaca.Push.config/0`.
  defp config do
    env = Application.get_env(:hamaca, __MODULE__, [])

    %{
      async: Keyword.get(env, :async, true),
      task_supervisor: Keyword.get(env, :task_supervisor, Hamaca.Billing.TaskSupervisor)
    }
  end

  # `start_child` is a `GenServer.call` to the named supervisor, which *exits* if that process is
  # unavailable — so the whole decision runs under `safely/1`.
  defp dispatch_now(%{async: true} = config, fun) do
    Task.Supervisor.start_child(config.task_supervisor, fn -> safely(fun) end)
  end

  defp dispatch_now(%{async: false}, fun), do: fun.()

  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("Billing.Notifier: dispatch failed: #{Exception.format(:error, error, __STACKTRACE__)}")
      :ok
  catch
    kind, reason ->
      Logger.error("Billing.Notifier: dispatch #{kind}: #{inspect(reason)}")
      :ok
  end

  defp send_now(email) do
    case Hamaca.Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(~s(Billing.Notifier: sending "#{email.subject}" to #{recipient(email)} failed: #{inspect(reason)}))
    end
  rescue
    error ->
      Logger.error("Billing.Notifier: delivery raised: #{Exception.format(:error, error, __STACKTRACE__)}")
  catch
    kind, reason ->
      Logger.error("Billing.Notifier: delivery #{kind}: #{inspect(reason)}")
  end

  defp build(%User{email: address}, subject, paragraphs) do
    url = billing_url()

    new()
    |> to(address)
    |> Swoosh.Email.from(sender(Application.get_env(:hamaca, :mail_from)))
    |> subject(subject)
    |> text_body(Enum.join(paragraphs, "\n\n") <> "\n\nManage billing: #{url}\n")
    |> html_body(paragraphs_html(paragraphs, url))
  end

  defp paragraphs_html(paragraphs, url) do
    Enum.map_join(paragraphs, "\n", &"<p>#{escape(&1)}</p>") <>
      ~s(\n<p><a href="#{escape(url)}">Manage billing</a></p>\n)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address
  defp recipient(%Swoosh.Email{}), do: "nobody"
end
