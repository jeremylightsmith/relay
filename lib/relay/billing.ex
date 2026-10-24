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
  cancelled or resumed, a card is saved, a promo code is redeemed, or a payment opens or settles).

  **Promo codes** (RE462): owns `Schemas.PromoCode`. An account redeems at most one code, ever
  (`redeem_code/3`, refused with one of `promo_refusals/0`); redeeming stores the code and
  `promo_months_left = months` on the account. The superadmin creates, lists and disables codes
  (`create_promo_code/1`, `list_promo_codes/0`, `disable_promo_code/2`); disabling stops new
  redemptions and never touches accounts that already hold the code.

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
  alias Relay.Billing.Periods
  alias Relay.Billing.Standing
  alias Relay.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingPaymentAttempt
  alias Schemas.Board
  alias Schemas.PromoCode
  alias Schemas.User

  require Logger

  @pubsub Relay.PubSub
  @default_price_cents 2000
  @promo_refusals [:already_redeemed, :unknown, :disabled, :expired, :full]
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

  @doc """
  `price_cents` with `percent_off` taken off: `price × (100 − percent) / 100`, rounded half-up to
  the cent. Only `next_charge/1` calls it — nothing else computes a discounted price.
  """
  @spec discounted_cents(pos_integer(), 1..100) :: non_neg_integer()
  def discounted_cents(price_cents, percent_off)
      when is_integer(price_cents) and price_cents > 0 and percent_off in 1..100,
      do: div(price_cents * (100 - percent_off) + 50, 100)

  @typedoc "What the account's next charge comes to, and the promo code (text and percent) it applies."
  @type next_charge :: %{amount_cents: non_neg_integer(), promo_code: String.t() | nil, percent_off: 1..100 | nil}

  @doc """
  **The** amount function: what `account`'s next charge comes to. While it holds a promo code
  with `promo_months_left > 0`, the code's percent off `price_cents/0` (`discounted_cents/2`) —
  even if the code has since been disabled; otherwise the full price with no code.
  `Relay.Billing.Charging` opens every attempt at this amount and `summary/2` previews it.
  """
  @spec next_charge(BillingAccount.t() | nil) :: next_charge()
  def next_charge(%BillingAccount{promo_code_id: promo_code_id, promo_months_left: months_left} = account)
      when is_integer(promo_code_id) and months_left > 0 do
    %PromoCode{code: code, percent_off: percent_off} = promo_code(account)
    %{amount_cents: discounted_cents(price_cents(), percent_off), promo_code: code, percent_off: percent_off}
  end

  def next_charge(_account), do: %{amount_cents: price_cents(), promo_code: nil, percent_off: nil}

  defp promo_code(%BillingAccount{promo_code: %PromoCode{} = promo_code}), do: promo_code
  defp promo_code(%BillingAccount{promo_code_id: id}), do: Repo.get!(PromoCode, id)

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

  @typedoc "Why `redeem_code/3` refused a code — one of `promo_refusals/0`."
  @type promo_refusal :: :already_redeemed | :unknown | :disabled | :expired | :full

  @doc "Every promo refusal, in the order `redeem_code/3` checks them (first match wins)."
  @spec promo_refusals() :: [promo_refusal()]
  def promo_refusals, do: @promo_refusals

  @doc """
  Redeems a promo code (trimmed, case-insensitive) on `user`'s account, creating the account and
  its trial first (`ensure_trial/2`). In one transaction the account row and then the code row
  are locked `FOR UPDATE` (always account, then code), so two redemptions can't both take a
  code's last slot. Refused, first match wins: the account already holds a code
  (`:already_redeemed`); no such code, or a blank one (`:unknown`); `disabled_at` set
  (`:disabled`); `today` after `expires_on` (`:expired` — the expiry day itself redeems);
  `max_redemptions` accounts already hold it (`:full`). Otherwise stores the code and
  `promo_months_left = months`, then broadcasts. A refusal writes and broadcasts nothing.
  """
  @spec redeem_code(User.t() | pos_integer(), String.t() | nil, Date.t()) ::
          {:ok, BillingAccount.t()} | {:error, promo_refusal()}
  def redeem_code(user, code, %Date{} = today) do
    {:ok, %BillingAccount{id: account_id}} = ensure_trial(user, today)

    redeemed =
      Repo.transact(fn ->
        account = Repo.one!(from a in BillingAccount, where: a.id == ^account_id, lock: "FOR UPDATE")
        promo_code = lock_promo_code(normalize_code(code))

        with :ok <- redeemable(account, promo_code, today) do
          account
          |> Ecto.Changeset.change(promo_code_id: promo_code.id, promo_months_left: promo_code.months)
          |> Repo.update()
        end
      end)

    with {:ok, account} <- redeemed do
      :ok = broadcast_changed(account.user_id)
      {:ok, account}
    end
  end

  defp normalize_code(code) when is_binary(code) do
    case code |> String.trim() |> String.upcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_code(nil), do: nil

  defp lock_promo_code(nil), do: nil
  defp lock_promo_code(code), do: Repo.one(from p in PromoCode, where: p.code == ^code, lock: "FOR UPDATE")

  # The checks run in `promo_refusals/0`'s order.
  defp redeemable(account, promo_code, today) do
    cond do
      account.promo_code_id -> {:error, :already_redeemed}
      is_nil(promo_code) -> {:error, :unknown}
      promo_code.disabled_at -> {:error, :disabled}
      promo_code.expires_on && Date.after?(today, promo_code.expires_on) -> {:error, :expired}
      promo_code.max_redemptions && redemptions(promo_code.id) >= promo_code.max_redemptions -> {:error, :full}
      true -> :ok
    end
  end

  defp redemptions(promo_code_id),
    do: Repo.aggregate(from(a in BillingAccount, where: a.promo_code_id == ^promo_code_id), :count)

  @doc """
  Every promo code for the superadmin, newest first (`inserted_at desc, id desc`), with `used` =
  how many billing accounts hold it. Unscoped on purpose: the gate is the `/admin` route. One
  query (aggregate subquery, no N+1).
  """
  @spec list_promo_codes() :: [%{promo_code: PromoCode.t(), used: non_neg_integer()}]
  def list_promo_codes do
    used =
      from a in BillingAccount,
        where: not is_nil(a.promo_code_id),
        group_by: a.promo_code_id,
        select: %{promo_code_id: a.promo_code_id, n: count(a.id)}

    Repo.all(
      from p in PromoCode,
        left_join: u in subquery(used),
        on: u.promo_code_id == p.id,
        order_by: [desc: p.inserted_at, desc: p.id],
        select: %{promo_code: p, used: coalesce(u.n, 0)}
    )
  end

  @doc "A changeset for a promo code form (`Schemas.PromoCode.changeset/2`)."
  @spec change_promo_code(PromoCode.t(), map()) :: Ecto.Changeset.t()
  def change_promo_code(%PromoCode{} = promo_code, attrs), do: PromoCode.changeset(promo_code, attrs)

  @doc "Creates a promo code from admin input (`Schemas.PromoCode.changeset/2`)."
  @spec create_promo_code(map()) :: {:ok, PromoCode.t()} | {:error, Ecto.Changeset.t()}
  def create_promo_code(attrs), do: %PromoCode{} |> PromoCode.changeset(attrs) |> Repo.insert()

  @doc """
  Disables a promo code at `at`, stopping new redemptions; accounts that already hold it keep
  their remaining months. An already disabled code keeps its original `disabled_at`.
  """
  @spec disable_promo_code(pos_integer(), DateTime.t()) :: {:ok, PromoCode.t()} | {:error, :not_found}
  def disable_promo_code(id, %DateTime{} = at) do
    case Repo.get(PromoCode, id) do
      nil ->
        {:error, :not_found}

      %PromoCode{disabled_at: nil} = promo_code ->
        promo_code |> Ecto.Changeset.change(disabled_at: DateTime.truncate(at, :second)) |> Repo.update()

      %PromoCode{} = promo_code ->
        {:ok, promo_code}
    end
  end

  @typedoc "What the Billing page shows (`summary/2`)."
  @type summary :: %{
          standing: Standing.t(),
          trial_ends_on: Date.t() | nil,
          trial_days_left: integer() | nil,
          first_charge_on: Date.t() | nil,
          amount_cents: non_neg_integer(),
          full_price_cents: pos_integer(),
          promo:
            nil
            | %{code: String.t(), percent_off: 1..100, months_left: non_neg_integer(), full_price_from: Date.t() | nil},
          paid_through: Date.t() | nil,
          renews_on: Date.t() | nil,
          card: nil | %{brand_label: String.t(), last4: String.t(), exp_month: integer(), exp_year: integer()},
          payments: [
            %{
              id: pos_integer(),
              paid_on: Date.t(),
              period_start: Date.t(),
              period_end: Date.t(),
              amount_cents: non_neg_integer(),
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

  @doc """
  What the Billing page shows for `user` on `today`. `amount_cents` is the next charge
  (`next_charge/1`), `full_price_cents` the undiscounted price. `promo` is nil unless the
  account holds a code; its `full_price_from` is the first charge date back at full price — the
  first charge (a trial) or the renewal (active) `months_left` periods on — and nil when no
  months are left or in any other standing.
  """
  @spec summary(User.t(), Date.t()) :: summary()
  def summary(%User{} = user, %Date{} = today) do
    account = user |> get_account() |> Repo.preload(:promo_code)
    standing = Standing.of(account, facts(account), today)
    trial_ends_on = account && account.trial_ends_on
    paid_through = account && account.paid_through
    trial? = standing == :trial and not is_nil(trial_ends_on)
    first_charge_on = if(trial?, do: Date.add(trial_ends_on, 1))
    renews_on = if(standing == :active, do: Periods.next_renewal(paid_through))

    %{
      standing: standing,
      trial_ends_on: trial_ends_on,
      trial_days_left: if(trial?, do: Date.diff(trial_ends_on, today)),
      first_charge_on: first_charge_on,
      amount_cents: next_charge(account).amount_cents,
      full_price_cents: price_cents(),
      promo: promo(account, first_charge_on, renews_on),
      paid_through: paid_through,
      renews_on: renews_on,
      card: card(account),
      payments: payments(account),
      cancellable?: Standing.cancellable?(standing),
      resumable?: Standing.resumable?(standing)
    }
  end

  defp promo(%BillingAccount{promo_code: %PromoCode{} = promo_code} = account, first_charge_on, renews_on) do
    months_left = account.promo_months_left

    %{
      code: promo_code.code,
      percent_off: promo_code.percent_off,
      months_left: months_left,
      full_price_from: full_price_from(months_left, first_charge_on, renews_on, account.billing_day)
    }
  end

  defp promo(_account, _first_charge_on, _renews_on), do: nil

  defp full_price_from(0, _first_charge_on, _renews_on, _billing_day), do: nil
  defp full_price_from(months_left, %Date{} = first, nil, _day), do: Periods.renewal_after(first, first.day, months_left)
  defp full_price_from(months_left, nil, %Date{} = renews_on, day), do: Periods.renewal_after(renews_on, day, months_left)
  defp full_price_from(_months_left, _first_charge_on, _renews_on, _billing_day), do: nil

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
