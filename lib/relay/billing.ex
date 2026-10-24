defmodule Relay.Billing do
  @moduledoc """
  Billing (RE460, [ADR 0012](docs/adr/0012-board-owners-pay-up-front.md)): a board owner pays
  one price a month, up front from their own billing date, after a no-card trial. A board's
  standing is its owner's; a paused owner's boards are read-only.

  Owns `Schemas.BillingAccount` (one per user), `Schemas.BillingPaymentAttempt` and
  `Schemas.BillingNotice` (one per billing email sent), the pure
  rules (`Relay.Billing.Standing`, `Relay.Billing.Periods`), the charging path
  (`Relay.Billing.Charging`, through the `Relay.Billing.Payments` seam), the Stripe webhook
  verifier (`Relay.Billing.Webhook`), the hourly `Relay.Billing.Clock`, and the
  `billing:<user_id>` PubSub topic (`{:billing_changed, user_id}`, broadcast when a plan is
  cancelled or resumed, a card is saved, or a payment opens or settles).

  **One off switch:** `enabled?/0` (`:billing_enabled`, read through `Relay.Config`). Off — a
  self-hosted install — nothing is paused or noticed and no trial is started.

  **Depends on `Relay.Config`, `Relay.Mailer`, `Relay.Repo` and `Schemas` only** — `Relay.Accounts`
  (trial at sign-up) and `Relay.Runs` call in, so a back-dependency would be a boundary cycle.
  Billing emails (`Relay.Billing.Notifier`, RE464) — trial ending, card declined, plan paused, each
  once per account and period, sent by `run_clock/2`'s last step — go out through the leaf
  `Relay.Mailer`. A board id is resolved to its owner by reading `Schemas.Board.owner_id` directly.
  """

  use Boundary, deps: [Relay.Config, Relay.Mailer, Relay.Repo, Schemas], exports: [Standing]

  import Ecto.Query

  alias Relay.Billing.Charging
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments
  alias Relay.Billing.Standing
  alias Relay.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt
  alias Schemas.Board
  alias Schemas.User

  require Logger

  @pubsub Relay.PubSub
  @default_price_cents 2000
  @brand_labels %{"visa" => "Visa", "mastercard" => "Mastercard", "amex" => "Amex", "discover" => "Discover"}

  @doc "True when billing is switched on (`:billing_enabled` is exactly `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Relay.Config.get(:billing_enabled, false) == true

  @doc "The monthly price, in cents."
  @spec price_cents() :: pos_integer()
  def price_cents, do: Relay.Config.get(:billing_price_cents, @default_price_cents)

  @doc ~S'Formats an amount in cents as dollars: `2000` → `"$20.00"`, `5` → `"$0.05"`.'
  @spec format_cents(non_neg_integer()) :: String.t()
  def format_cents(cents) when is_integer(cents) and cents >= 0 do
    "$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "The PubSub topic a user's billing changes are broadcast on."
  @spec topic(pos_integer()) :: String.t()
  def topic(user_id), do: "billing:#{user_id}"

  @doc "Subscribes the caller to `topic/1`."
  @spec subscribe(pos_integer()) :: :ok
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))

  @doc "Broadcasts `{:billing_changed, user_id}` on `topic/1`."
  @spec broadcast_changed(pos_integer()) :: :ok
  def broadcast_changed(user_id), do: Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:billing_changed, user_id})

  @doc "The user's billing account, or nil."
  @spec get_account(User.t() | pos_integer()) :: BillingAccount.t() | nil
  def get_account(user), do: Repo.get_by(BillingAccount, user_id: user_id(user))

  @doc """
  Gets or creates the user's account and, if it has no trial yet, starts one ending
  `Standing.trial_days()` after `today`. Never moves an existing date. Concurrency-safe: the
  insert ignores a conflict on `user_id` and the trial write only touches a nil date.
  """
  @spec ensure_trial(User.t() | pos_integer(), Date.t()) :: {:ok, BillingAccount.t()}
  def ensure_trial(user, %Date{} = today) do
    user_id = user_id(user)

    {:ok, _} = Repo.insert(%BillingAccount{user_id: user_id}, on_conflict: :nothing, conflict_target: :user_id)

    Repo.update_all(
      from(a in BillingAccount, where: a.user_id == ^user_id and is_nil(a.trial_ends_on)),
      set: [trial_ends_on: Date.add(today, Standing.trial_days()), updated_at: now()]
    )

    {:ok, Repo.get_by!(BillingAccount, user_id: user_id)}
  end

  @doc "The user's standing on `today`, derived from the account and its attempts (whether or not billing is enabled)."
  @spec standing(User.t() | pos_integer(), Date.t()) :: Standing.t()
  def standing(user, %Date{} = today) do
    account = get_account(user)
    Standing.of(account, facts(account), today)
  end

  @doc """
  True when the board's owner is paused. Always false while billing is disabled. An integer is a
  board id.
  """
  @spec board_paused?(Board.t() | pos_integer()) :: boolean()
  def board_paused?(board) do
    enabled?() and
      case board_owner_id(board) do
        nil -> false
        owner_id -> Standing.paused?(standing(owner_id, Date.utc_today()))
      end
  end

  @doc "The billing notice a board shows: `:paused`, `:past_due`, or nil (always nil while disabled)."
  @spec board_notice(Board.t()) :: nil | :past_due | :paused
  def board_notice(%Board{owner_id: owner_id}) do
    if enabled?() do
      case standing(owner_id, Date.utc_today()) do
        {:paused, _reason} -> :paused
        {:past_due, _until} -> :past_due
        _standing -> nil
      end
    end
  end

  @doc """
  Cancels the user's plan on `today`. Access continues through `trial_ends_on` (a trial) or
  `paid_through` (active or past due); nothing is refunded. Broadcasts on success.
  """
  @spec cancel(User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_cancellable}
  def cancel(user, %Date{} = today) do
    account = get_account(user)
    standing = Standing.of(account, facts(account), today)

    with true <- Standing.cancellable?(standing),
         %Date{} = access_until <- access_until(standing, account) do
      account
      |> Ecto.Changeset.change(cancelled_on: today, access_until: access_until)
      |> update_and_broadcast()
    else
      _not_cancellable -> {:error, :not_cancellable}
    end
  end

  @doc "Resumes a cancelled plan still inside its access window; the billing date is unchanged. Broadcasts on success."
  @spec resume(User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_resumable}
  def resume(user, %Date{} = today) do
    account = get_account(user)

    if Standing.resumable?(Standing.of(account, facts(account), today)) do
      account
      |> Ecto.Changeset.change(cancelled_on: nil, access_until: nil)
      |> update_and_broadcast()
    else
      {:error, :not_resumable}
    end
  end

  @typedoc "What the Billing page shows (`summary/2`)."
  @type summary :: %{
          standing: Standing.t(),
          trial_ends_on: Date.t() | nil,
          trial_days_left: integer() | nil,
          first_charge_on: Date.t() | nil,
          amount_cents: pos_integer(),
          paid_through: Date.t() | nil,
          renews_on: Date.t() | nil,
          card: nil | %{brand_label: String.t(), last4: String.t(), exp_month: integer(), exp_year: integer()},
          payments: [
            %{
              id: pos_integer(),
              paid_on: Date.t(),
              period_start: Date.t(),
              period_end: Date.t(),
              amount_cents: pos_integer(),
              receipt_url: String.t() | nil
            }
          ],
          cancellable?: boolean(),
          resumable?: boolean()
        }

  @doc """
  A Checkout (setup mode) URL to save `user`'s card, returning to `return_url`. Stores the Stripe
  customer it created on the account when the account had none.
  """
  @spec setup_checkout_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def setup_checkout_url(%User{} = user, return_url) do
    {:ok, account} = ensure_trial(user, Date.utc_today())

    with {:ok, %{url: url, customer_id: customer_id}} <-
           Payments.impl().create_setup_checkout(account.stripe_customer_id, user, return_url) do
      Repo.update_all(
        from(a in BillingAccount, where: a.id == ^account.id and is_nil(a.stripe_customer_id)),
        set: [stripe_customer_id: customer_id, updated_at: now()]
      )

      {:ok, url}
    end
  end

  @doc """
  Saves the card a completed setup (`cs_…` / `seti_…`, or a Local id) holds on its user's account
  and charges if the card-saved rule says so: a past-due account renews, a paused one pays a
  fresh month from `today`. `expected_user_id` (the signed-in user, from the return URL) must
  match the setup's user; the webhook passes nil. Safe to run twice for one setup — the return
  URL and the webhook both do — it charges at most once. Broadcasts.
  """
  @spec complete_setup(String.t(), pos_integer() | nil, Date.t()) ::
          {:ok, %{account: BillingAccount.t(), charged: :none | :paid | :declined | :unknown}}
          | {:error, :wrong_user | term()}
  def complete_setup(setup_id, expected_user_id, %Date{} = today) do
    with {:ok, setup} <- Payments.impl().fetch_setup(setup_id),
         :ok <- same_user(setup.user_id, expected_user_id),
         true <- Repo.exists?(from u in User, where: u.id == ^setup.user_id) || {:error, :not_found} do
      {:ok, _account} = ensure_trial(setup.user_id, today)
      Charging.save_card(setup, today)
    end
  end

  defp same_user(_user_id, nil), do: :ok
  defp same_user(user_id, user_id), do: :ok
  defp same_user(_user_id, _expected_user_id), do: {:error, :wrong_user}

  @doc """
  Handles a verified Stripe event: a setup-mode `checkout.session.completed` or a
  `setup_intent.succeeded` completes that setup (`complete_setup/3`, no expected user). Any other
  event is ignored. Always `:ok` — Stripe gets its 200 either way.
  """
  @spec handle_webhook_event(map()) :: :ok
  def handle_webhook_event(%{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"mode" => "setup", "id" => id}}
      }), do: complete_from_webhook(id)

  def handle_webhook_event(%{"type" => "setup_intent.succeeded", "data" => %{"object" => %{"id" => id}}}),
    do: complete_from_webhook(id)

  def handle_webhook_event(_event), do: :ok

  defp complete_from_webhook(id) when is_binary(id) do
    case complete_setup(id, nil, Date.utc_today()) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("Billing: webhook setup #{id} not completed: #{inspect(reason)}")
    end

    :ok
  end

  defp complete_from_webhook(_id), do: :ok

  @doc """
  Verifies a Stripe webhook request (`Relay.Billing.Webhook.verify/4`) against the
  `:stripe_webhook_secret`, read through `Relay.Config`, at the current time.
  """
  @spec verify_webhook(binary() | nil, String.t() | nil) :: {:ok, map()} | {:error, :invalid_signature}
  def verify_webhook(raw_body, signature_header) do
    Relay.Billing.Webhook.verify(
      raw_body || "",
      signature_header,
      Relay.Config.get(:stripe_webhook_secret) || "",
      System.os_time(:second)
    )
  end

  @doc """
  The billing clock for `today` (`Relay.Billing.Clock` runs it hourly), in order: (a) backfill —
  a trial for every user without one; (b) resolve — ask Stripe about every unknown attempt and
  every pending one older than `Charging.pending_overdue_minutes/0`; (c) charge — every account
  due a first charge, a renewal or (`final_pass?: true`, the day's last run) its one retry; (d)
  notify — `Relay.Billing.Notifier.notify_due/1` records and sends the trial-ending,
  card-declined and plan-paused emails due today, each once per account and period. A no-op
  answering zeros while billing is disabled.
  """
  @spec run_clock(Date.t(), final_pass?: boolean(), now: DateTime.t()) :: %{
          backfilled: non_neg_integer(),
          resolved: non_neg_integer(),
          charged: non_neg_integer(),
          notified: non_neg_integer()
        }
  def run_clock(%Date{} = today, opts \\ []) do
    if enabled?() do
      backfilled = backfill(today)
      resolved = Charging.resolve_open(Keyword.get(opts, :now, DateTime.utc_now()))
      charged = Charging.charge_due(today, Keyword.get(opts, :final_pass?, false))
      notified = Notifier.notify_due(today)
      %{backfilled: backfilled, resolved: resolved, charged: charged, notified: notified}
    else
      %{backfilled: 0, resolved: 0, charged: 0, notified: 0}
    end
  end

  # The launch backfill: users who signed up before billing (no account, or no trial date).
  defp backfill(today) do
    from(u in User,
      left_join: a in BillingAccount,
      on: a.user_id == u.id,
      where: is_nil(a.id) or is_nil(a.trial_ends_on),
      select: u.id
    )
    |> Repo.all()
    |> Enum.count(fn user_id -> match?({:ok, _account}, ensure_trial(user_id, today)) end)
  end

  @doc "What the Billing page shows for `user` on `today`."
  @spec summary(User.t(), Date.t()) :: summary()
  def summary(%User{} = user, %Date{} = today) do
    account = get_account(user)
    standing = Standing.of(account, facts(account), today)
    trial_ends_on = account && account.trial_ends_on
    paid_through = account && account.paid_through
    trial? = standing == :trial and not is_nil(trial_ends_on)

    %{
      standing: standing,
      trial_ends_on: trial_ends_on,
      trial_days_left: if(trial?, do: Date.diff(trial_ends_on, today)),
      first_charge_on: if(trial?, do: Date.add(trial_ends_on, 1)),
      amount_cents: price_cents(),
      paid_through: paid_through,
      renews_on: if(standing == :active, do: Relay.Billing.Periods.next_renewal(paid_through)),
      card: card(account),
      payments: payments(account),
      cancellable?: Standing.cancellable?(standing),
      resumable?: Standing.resumable?(standing)
    }
  end

  defp card(account) do
    if account && Standing.card_on_file?(account) do
      %{
        brand_label: brand_label(account.card_brand),
        last4: account.card_last4,
        exp_month: account.card_exp_month,
        exp_year: account.card_exp_year
      }
    end
  end

  defp payments(nil), do: []

  defp payments(%BillingAccount{id: id}) do
    from(p in BillingPaymentAttempt,
      where: p.billing_account_id == ^id and p.status == :succeeded,
      order_by: [desc: p.resolved_at, desc: p.id]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        id: p.id,
        paid_on: DateTime.to_date(p.resolved_at),
        period_start: p.period_start,
        period_end: p.period_end,
        amount_cents: p.amount_cents,
        receipt_url: p.receipt_url
      }
    end)
  end

  @doc ~s(A card brand as people read it: `"visa"` → `"Visa"`, `"amex"` → `"Amex"`; nil → `"Card"`.)
  @spec brand_label(String.t() | nil) :: String.t()
  def brand_label(nil), do: "Card"
  def brand_label(brand) when is_binary(brand), do: Map.get_lazy(@brand_labels, brand, fn -> String.capitalize(brand) end)

  # A trial (with no account or no trial date — pre-backfill) has no end to keep access through.
  defp access_until(_standing, nil), do: nil
  defp access_until(:trial, %BillingAccount{trial_ends_on: ends_on}), do: ends_on
  defp access_until(_active_or_past_due, %BillingAccount{paid_through: paid_through}), do: paid_through

  defp update_and_broadcast(changeset) do
    with {:ok, account} <- Repo.update(changeset) do
      :ok = broadcast_changed(account.user_id)
      {:ok, account}
    end
  end

  defp facts(account), do: Charging.facts(account)

  defp board_owner_id(%Board{owner_id: owner_id}), do: owner_id

  defp board_owner_id(board_id) when is_integer(board_id),
    do: Repo.one(from b in Board, where: b.id == ^board_id, select: b.owner_id)

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id), do: id

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
