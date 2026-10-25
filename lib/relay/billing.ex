defmodule Relay.Billing do
  @moduledoc """
  Billing (RE460, [ADR 0012](docs/adr/0012-board-owners-pay-up-front.md)): a board owner pays
  one price a month, up front from their own billing date, for unlimited boards; until then —
  and again after a lapsed or cancelled plan — they are on **Free** (RE469). A board's standing
  is its owner's.

  **Free** (RE469): `free_board_limit/0` counted boards (owned, not archived, not an example
  board) stay editable. The editable one is computed, never stored (`editable_board_id/1`: the
  newest activity wins); the owner's other counted boards are read-only. `board_paused?/1` is
  THE gate every write path honours — true for a held owner's boards and for a read-only-on-Free
  board; `board_notice/1` is the banner value; `can_add_board?/1` the create / unarchive check;
  `free_status/2` the Free read model; `upgrade_without_card/2` the $0 upgrade (a 100% code).

  Owns `Schemas.BillingAccount` (one per user), `Schemas.BillingPaymentAttempt`,
  `Schemas.BillingNotice` (one per billing email sent) and `Schemas.BillingAdminEntry` (the
  superadmin's history, one per admin action), the pure
  rules (`Relay.Billing.Standing`, `Relay.Billing.Periods`), the charging path
  (`Relay.Billing.Charging`, through the `Relay.Billing.Payments` seam), the Stripe webhook
  verifier (`Relay.Billing.Webhook`), the hourly `Relay.Billing.Clock`, and the
  `billing:<user_id>` PubSub topic (`{:billing_changed, user_id}`, broadcast when a plan is
  cancelled or resumed, a card is saved, a promo code is redeemed, a payment opens or settles, or the
  superadmin comps, un-comps, holds, lifts a hold, extends or retries the charge).

  **Promo codes** (RE462): owns `Schemas.PromoCode`. An account redeems at most one code, ever
  (`redeem_code/3`, refused with one of `promo_refusals/0`); redeeming stores the code and
  `promo_months_left = months` on the account. The superadmin creates, lists and disables codes
  (`create_promo_code/1`, `list_promo_codes/0`, `disable_promo_code/2`); disabling stops new
  redemptions and never touches accounts that already hold the code.

  **Admin read model** (RE463): `list_admin_users/1` — every user with their board counts and
  billing standing for `/admin/users`, in one query, standing derived in memory — and its pure
  helpers `admin_plan/2` (closed set `admin_plans/0`), `admin_summary/1` (`paying_plans/0`) and
  `format_dollars/1`. It reads `Schemas.User`, `Schemas.Board` and `Schemas.Membership` directly.

  **Admin writes** (RE463): `admin_comp/3`, `admin_uncomp/3`, `admin_hold/4`, `admin_lift_hold/3`,
  `admin_extend/5` and `admin_retry_charge/3` delegate to the internal `Relay.Billing.Admin`. Each
  `{:ok, _}` writes exactly one `Schemas.BillingAdminEntry` (by the superadmin `actor`, a
  `%Schemas.User{}` handed in by the web layer) and broadcasts; each refusal (`admin_refusals/0`)
  writes and broadcasts nothing. The retry charges through `Relay.Billing.Charging` as an
  `:admin` attempt. `admin_detail/2` is the row side panel's read model (payment history with
  `attempt_outcome/1`, admin history, `stripe_customer_url/1`). `renewal_log/1` is the
  **Renewals** tab's read model: every payment attempt across accounts, newest first, filterable
  by outcome, capped at `renewal_log_limit/0` rows, in one query.

  **One off switch:** `enabled?/0` (`:billing_enabled`, read through `Relay.Config`). Off — a
  self-hosted install — there is no limit, nothing is read-only or noticed, and no account is
  opened at sign-up.

  **Depends on `Relay.Config`, `Relay.Mailer`, `Relay.Repo` and `Schemas` only** — `Relay.Accounts`
  (the account at sign-up) and `Relay.Runs` call in, so a back-dependency would be a boundary
  cycle. Billing emails (`Relay.Billing.Notifier`, RE464) — card declined, dropped to Free, each
  once per account and period, sent by `run_clock/2`'s last step — go out through the leaf
  `Relay.Mailer`. A board is resolved to its owner, and a Free owner's boards counted, by reading
  `Schemas.Board` and `Schemas.Card` directly.
  """

  use Boundary, deps: [Relay.Config, Relay.Mailer, Relay.Repo, Schemas], exports: [Standing]

  import Ecto.Query

  alias Relay.Billing.Admin
  alias Relay.Billing.Charging
  alias Relay.Billing.Notifier
  alias Relay.Billing.Payments
  alias Relay.Billing.Periods
  alias Relay.Billing.Standing
  alias Relay.Repo
  alias Schemas.BillingAccount
  alias Schemas.BillingAdminEntry
  alias Schemas.BillingPaymentAttempt
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Membership
  alias Schemas.PromoCode
  alias Schemas.User

  require Logger

  @pubsub Relay.PubSub
  @default_price_cents 2000
  @free_board_limit 1
  @promo_refusals [:already_redeemed, :unknown, :disabled, :expired, :full]
  @paying_plans [:active, :past_due]
  @admin_refusals [
    :already_comped,
    :not_comped,
    :reason_required,
    :already_held,
    :not_held,
    :invalid_days,
    :no_paid_through,
    :not_retryable
  ]
  # The ONE attempt status → admin outcome map; `attempt_outcome/1` and `attempt_statuses_for/1` read it.
  @attempt_outcomes [:paid, :declined, :unknown, :not_charged]
  @outcome_of_status %{
    pending: :unknown,
    succeeded: :paid,
    failed: :declined,
    unknown: :unknown,
    not_charged: :not_charged
  }
  @renewal_log_limit 500
  @stripe_dashboard "https://dashboard.stripe.com"
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
  Gets or creates the user's account. Concurrency-safe: the insert ignores a conflict on
  `user_id`. Writes no date — every new account stands on Free.
  """
  @spec ensure_account(User.t() | pos_integer()) :: {:ok, BillingAccount.t()}
  def ensure_account(user) do
    user_id = user_id(user)
    {:ok, _} = Repo.insert(%BillingAccount{user_id: user_id}, on_conflict: :nothing, conflict_target: :user_id)
    {:ok, Repo.get_by!(BillingAccount, user_id: user_id)}
  end

  @doc "The user's standing on `today`, derived from the account and its attempts (whether or not billing is enabled)."
  @spec standing(User.t() | pos_integer(), Date.t()) :: Standing.t()
  def standing(user, %Date{} = today) do
    account = get_account(user)
    Standing.of(account, facts(account), today)
  end

  @doc "How many counted boards a Free owner may edit: THE Free limit."
  @spec free_board_limit() :: pos_integer()
  def free_board_limit, do: @free_board_limit

  @doc """
  The id of `owner_id`'s editable board, whatever their standing: of their **counted** boards
  (owned, not archived, not an example board), the one with the newest activity —
  `coalesce(max(cards.updated_at), boards.updated_at)`, every card counted, archived or not —
  ties to the higher id. Nil when they have no counted board. One query.
  """
  @spec editable_board_id(pos_integer()) :: pos_integer() | nil
  def editable_board_id(owner_id) when is_integer(owner_id) do
    case editable_board(owner_id) do
      nil -> nil
      %{id: id} -> id
    end
  end

  defp editable_board(owner_id), do: owner_id |> counted_boards() |> limit(1) |> Repo.one()

  # The owner's counted boards, most active first (so the editable board leads). One grouped query.
  defp counted_boards(owner_id) do
    from b in Board,
      left_join: c in Card,
      on: c.board_id == b.id,
      where: b.owner_id == ^owner_id and is_nil(b.archived_at) and is_nil(b.example_template),
      group_by: b.id,
      order_by: [desc: coalesce(max(c.updated_at), b.updated_at), desc: b.id],
      select: %{id: b.id, slug: b.slug, name: b.name}
  end

  defp counted_board_count(owner_id) do
    Repo.aggregate(
      from(b in Board, where: b.owner_id == ^owner_id and is_nil(b.archived_at) and is_nil(b.example_template)),
      :count
    )
  end

  @typedoc "A Free owner's boards against the limit (`free_status/2`)."
  @type free_status :: %{
          limit: pos_integer(),
          boards: [%{id: pos_integer(), slug: String.t(), name: String.t(), editable?: boolean()}],
          editable_board_id: pos_integer() | nil,
          over_limit?: boolean()
        }

  @doc """
  A Free owner's counted boards on `today`, the editable one first and the rest by activity
  (newest first), with whether they are over `free_board_limit/0`. Nil unless billing is enabled
  and the owner's standing is `:free`.
  """
  @spec free_status(User.t() | pos_integer(), Date.t()) :: nil | free_status()
  def free_status(user, %Date{} = today) do
    if enabled?() and standing(user, today) == :free do
      boards = user |> user_id() |> counted_boards() |> Repo.all()
      editable_id = boards |> List.first(%{}) |> Map.get(:id)

      %{
        limit: @free_board_limit,
        boards: Enum.map(boards, &Map.put(&1, :editable?, &1.id == editable_id)),
        editable_board_id: editable_id,
        over_limit?: length(boards) > @free_board_limit
      }
    end
  end

  @doc """
  Whether the user may create (or unarchive) a board: false only while billing is enabled and
  they are held, or on Free with `free_board_limit/0` counted boards already.
  """
  @spec can_add_board?(User.t() | pos_integer()) :: boolean()
  def can_add_board?(user) do
    not enabled?() or
      case standing(user, Date.utc_today()) do
        :free -> counted_board_count(user_id(user)) < @free_board_limit
        standing -> Standing.unlimited?(standing)
      end
  end

  @doc """
  THE gate every write path honours: true when the board's owner is held, or the board is
  read-only on Free (the owner is on Free, the board is counted, and it is not the editable one).
  Always false while billing is disabled. An integer is a board id. The editable board is only
  looked up for a Free owner, so a paying owner costs no extra query.
  """
  @spec board_paused?(Board.t() | pos_integer()) :: boolean()
  def board_paused?(board) do
    enabled?() and
      case gate_board(board) do
        nil -> false
        gate_board -> closed?(gate(gate_board))
      end
  end

  @doc """
  The billing notice a board shows: `:paused` (the owner is held), `:past_due`,
  `{:free_read_only, editable_board_name}` (read-only on Free), or nil. Always nil while disabled.
  """
  @spec board_notice(Board.t()) :: nil | :past_due | :paused | {:free_read_only, String.t()}
  def board_notice(%Board{} = board) do
    if enabled?() do
      case gate(gate_board(board)) do
        :held -> :paused
        :past_due -> :past_due
        {:free_read_only, name} -> {:free_read_only, name}
        :open -> nil
      end
    end
  end

  defp closed?(:held), do: true
  defp closed?({:free_read_only, _editable_name}), do: true
  defp closed?(_past_due_or_open), do: false

  # What the owner's standing makes of one board: `:held`, `{:free_read_only, editable_name}`,
  # `:past_due` or `:open`.
  defp gate(%{owner_id: owner_id} = board) do
    standing = standing(owner_id, Date.utc_today())

    cond do
      Standing.paused?(standing) -> :held
      Standing.kind(standing) == :past_due -> :past_due
      Standing.unlimited?(standing) -> :open
      true -> free_gate(board)
    end
  end

  defp free_gate(%{archived_at: nil, example_template: nil} = board) do
    case editable_board(board.owner_id) do
      %{id: id, name: name} when id != board.id -> {:free_read_only, name}
      _editable_or_none -> :open
    end
  end

  defp free_gate(_uncounted_board), do: :open

  defp gate_board(%Board{} = board), do: Map.take(board, [:id, :owner_id, :archived_at, :example_template])

  defp gate_board(board_id) when is_integer(board_id) do
    Repo.one(
      from b in Board,
        where: b.id == ^board_id,
        select: %{id: b.id, owner_id: b.owner_id, archived_at: b.archived_at, example_template: b.example_template}
    )
  end

  @doc """
  Cancels the user's plan on `today`: only an active or past-due plan (`Standing.cancellable?/1`).
  Unlimited boards continue through `paid_through`, then the owner drops to Free; nothing is
  refunded. Broadcasts on success.
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
  Redeems a promo code (trimmed, case-insensitive) on `user`'s account, creating the account
  first (`ensure_account/1`). In one transaction the account row and then the code row
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
    {:ok, %BillingAccount{id: account_id}} = ensure_account(user)

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

  @typedoc "A user's plan on `/admin/users`: their standing's kind, or `:member_only` when they own no boards."
  @type admin_plan :: :free | :active | :past_due | :cancelled | :comped | :paused | :member_only

  @typedoc "One `/admin/users` row (`list_admin_users/1`)."
  @type admin_user :: %{
          id: pos_integer(),
          name: String.t() | nil,
          email: String.t(),
          inserted_at: DateTime.t(),
          board_count: non_neg_integer(),
          owned_board_count: non_neg_integer(),
          member_count: non_neg_integer(),
          account: BillingAccount.t() | nil,
          standing: Standing.t(),
          plan: admin_plan(),
          paid_through_shown: Date.t() | nil,
          rate_cents: non_neg_integer() | nil,
          code_label: String.t() | nil
        }

  @doc "Every admin plan: the standing kinds (`Standing.kinds/0`), then `:member_only`."
  @spec admin_plans() :: [admin_plan()]
  def admin_plans, do: Standing.kinds() ++ [:member_only]

  @doc "The admin plans that pay: they count as paying, and toward the monthly total, in `admin_summary/1`."
  @spec paying_plans() :: [:active | :past_due]
  def paying_plans, do: @paying_plans

  @doc "A user's admin plan: `:member_only` when they own no boards, else `Standing.kind/1` of their standing."
  @spec admin_plan(Standing.t(), non_neg_integer()) :: admin_plan()
  def admin_plan(_standing, 0), do: :member_only
  def admin_plan(standing, owned_board_count) when is_integer(owned_board_count), do: Standing.kind(standing)

  @doc """
  Every user for the superadmin `/admin/users` table (RE353, RE463), newest first
  (`inserted_at desc, id desc`), with their billing standing on `today`. `board_count` counts the
  user's memberships; `owned_board_count` the boards they own; `member_count` the distinct people
  on those boards, the owner included (0 when they own none). `plan` is `admin_plan/2`;
  `paid_through_shown` is `paid_through` (nil for a never-paid owner); `rate_cents` is
  the next charge (`next_charge/1`), 0 when comped; `code_label` reads `"<code> <used>/<months>"`.
  A member-only row has no paid through, rate or code.

  Unscoped on purpose: the gate is the `/admin` route. **One query** — counts and declined
  attempts come from aggregate subqueries, the account and its promo code from left joins — and
  the standing is derived in memory (`Charging.facts/2`, `Standing.of/3`), never per user.
  """
  @spec list_admin_users(Date.t()) :: [admin_user()]
  def list_admin_users(%Date{} = today) do
    from(u in User,
      left_join: bc in subquery(membership_counts()),
      on: bc.user_id == u.id,
      left_join: ob in subquery(owned_board_counts()),
      on: ob.owner_id == u.id,
      left_join: a in BillingAccount,
      on: a.user_id == u.id,
      left_join: p in PromoCode,
      on: p.id == a.promo_code_id,
      left_join: d in subquery(declined_accounts()),
      on: d.billing_account_id == a.id,
      order_by: [desc: u.inserted_at, desc: u.id],
      select: %{
        id: u.id,
        name: u.name,
        email: u.email,
        inserted_at: u.inserted_at,
        board_count: coalesce(bc.n, 0),
        owned_board_count: coalesce(ob.n, 0),
        member_count: coalesce(ob.members, 0),
        account: a,
        promo_code: p,
        declined?: not is_nil(d.billing_account_id)
      }
    )
    |> Repo.all()
    |> Enum.map(&admin_user(&1, today))
  end

  defp membership_counts do
    from m in Membership,
      where: not is_nil(m.user_id),
      group_by: m.user_id,
      select: %{user_id: m.user_id, n: count(m.id)}
  end

  # Per owner: boards owned, and the distinct people on them — every other member, plus the owner.
  defp owned_board_counts do
    from b in Board,
      left_join: m in Membership,
      on: m.board_id == b.id and m.user_id != b.owner_id,
      group_by: b.owner_id,
      select: %{owner_id: b.owner_id, n: count(b.id, :distinct), members: count(m.user_id, :distinct) + 1}
  end

  defp declined_accounts do
    from p in BillingPaymentAttempt,
      where: p.status == :failed,
      distinct: true,
      select: %{billing_account_id: p.billing_account_id}
  end

  defp admin_user(row, today) do
    {promo_code, row} = Map.pop!(row, :promo_code)
    {declined?, row} = Map.pop!(row, :declined?)
    account = row.account && %{row.account | promo_code: promo_code}
    standing = Standing.of(account, Charging.facts(account, declined?), today)
    plan = admin_plan(standing, row.owned_board_count)

    Map.merge(row, %{
      account: account,
      standing: standing,
      plan: plan,
      paid_through_shown: paid_through_shown(plan, account),
      rate_cents: rate_cents(plan, account),
      code_label: code_label(plan, account)
    })
  end

  defp paid_through_shown(:member_only, _account), do: nil
  defp paid_through_shown(_plan, nil), do: nil
  defp paid_through_shown(_plan, account), do: account.paid_through

  defp rate_cents(:member_only, _account), do: nil
  defp rate_cents(:comped, _account), do: 0
  defp rate_cents(_plan, account), do: next_charge(account).amount_cents

  defp code_label(:member_only, _account), do: nil

  defp code_label(_plan, %BillingAccount{promo_code: %PromoCode{code: code, months: months}, promo_months_left: left}),
    do: "#{code} #{months - left}/#{months}"

  defp code_label(_plan, _account), do: nil

  @doc """
  The `/admin/users` summary line, from its rows (pure): `users` rows; `paying` rows on one of
  `paying_plans/0`; `mrr_cents` the sum of those rows' `rate_cents`; `free` rows on `:free`.
  """
  @spec admin_summary([admin_user()]) :: %{
          users: non_neg_integer(),
          paying: non_neg_integer(),
          mrr_cents: non_neg_integer(),
          free: non_neg_integer()
        }
  def admin_summary(rows) when is_list(rows) do
    paying = Enum.filter(rows, &(&1.plan in @paying_plans))

    %{
      users: length(rows),
      paying: length(paying),
      mrr_cents: paying |> Enum.map(& &1.rate_cents) |> Enum.sum(),
      free: Enum.count(rows, &(&1.plan == :free))
    }
  end

  @doc ~S'Formats cents as dollars, dropping whole-dollar cents and grouping thousands: `1000` → `"$10"`, `1250` → `"$12.50"`, `125000` → `"$1,250"`.'
  @spec format_dollars(non_neg_integer()) :: String.t()
  def format_dollars(cents) when is_integer(cents) and cents >= 0 do
    dollars = cents |> div(100) |> Integer.to_string() |> group_thousands()

    case rem(cents, 100) do
      0 -> "$#{dollars}"
      rest -> "$#{dollars}.#{rest |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  @typedoc "Why an admin write refused — one of `admin_refusals/0`."
  @type admin_refusal ::
          :already_comped
          | :not_comped
          | :reason_required
          | :already_held
          | :not_held
          | :invalid_days
          | :no_paid_through
          | :not_retryable

  @doc "Every refusal an admin write (`admin_comp/3` … `admin_retry_charge/3`) can answer."
  @spec admin_refusals() :: [admin_refusal()]
  def admin_refusals, do: @admin_refusals

  @doc """
  Comps `user_id`'s account (creating it if missing), recording one `:comp` entry
  by `actor` and broadcasting. Refused with `:already_comped`.
  """
  @spec admin_comp(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :already_comped}
  defdelegate admin_comp(user_id, actor, today), to: Admin, as: :comp

  @doc """
  Un-comps the account — its standing is then derived as usual (a never-paid account, or one
  past `paid_through` + grace, is on `:free`).
  Records one `:uncomp` entry and broadcasts. Refused with `:not_comped`.
  """
  @spec admin_uncomp(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_comped}
  defdelegate admin_uncomp(user_id, actor, today), to: Admin, as: :uncomp

  @doc """
  Holds the account (`held_on: today`, `hold_reason:` the trimmed reason) — `{:paused, :hold}`
  until lifted, and never charged meanwhile. Records one `:hold` entry with the reason and
  broadcasts. Refused with `:reason_required` (blank) or `:already_held`.
  """
  @spec admin_hold(pos_integer(), User.t(), String.t() | nil, Date.t()) ::
          {:ok, BillingAccount.t()} | {:error, :reason_required | :already_held}
  defdelegate admin_hold(user_id, actor, reason, today), to: Admin, as: :hold

  @doc "Lifts the hold (clears `held_on` and `hold_reason`), records one `:lift_hold` entry and broadcasts. Refused with `:not_held`."
  @spec admin_lift_hold(pos_integer(), User.t(), Date.t()) :: {:ok, BillingAccount.t()} | {:error, :not_held}
  defdelegate admin_lift_hold(user_id, actor, today), to: Admin, as: :lift_hold

  @doc """
  Moves `paid_through` on by `days` (1..`admin_extend_max_days/0`); the billing day is untouched
  and nothing is charged. Records one `:extend` entry (days, reason, `paid_through` before and
  after) and broadcasts. Checked in order: `:invalid_days`, `:reason_required`, `:no_paid_through`.
  """
  @spec admin_extend(pos_integer(), User.t(), integer(), String.t() | nil, Date.t()) ::
          {:ok, BillingAccount.t()} | {:error, :invalid_days | :reason_required | :no_paid_through}
  defdelegate admin_extend(user_id, actor, days, reason, today), to: Admin, as: :extend

  @doc "The most days one `admin_extend/5` may add."
  @spec admin_extend_max_days() :: 365
  defdelegate admin_extend_max_days, to: Admin, as: :extend_max_days

  @doc """
  Charges the account now through the one charging path, as an `:admin` attempt (the card-saved
  rule: a past-due account renews, a Free one pays a fresh month), when `admin_retryable?/2`
  holds on a fresh read. Records one `:retry_charge` entry and broadcasts. Refused with
  `:not_retryable`. An admin decline sends no email and never spends the clock's grace retry.
  """
  @spec admin_retry_charge(pos_integer(), User.t(), Date.t()) ::
          {:ok, :paid | :declined | :unknown | :none} | {:error, :not_retryable}
  defdelegate admin_retry_charge(user_id, actor, today), to: Admin, as: :retry_charge

  @doc "True when the superadmin may retry the charge: a card on file, and past due or on Free (never a hold)."
  @spec admin_retryable?(BillingAccount.t() | nil, Standing.t()) :: boolean()
  def admin_retryable?(nil, _standing), do: false

  def admin_retryable?(%BillingAccount{} = account, standing) do
    Standing.card_on_file?(account) and
      case standing do
        {:past_due, _until} -> true
        :free -> true
        _other -> false
      end
  end

  @typedoc "What a payment attempt came to, as the admin pages show it (`attempt_outcomes/0`)."
  @type attempt_outcome :: :paid | :declined | :unknown | :not_charged

  @doc "Every attempt outcome, in display order."
  @spec attempt_outcomes() :: [attempt_outcome()]
  def attempt_outcomes, do: @attempt_outcomes

  @doc "An attempt status's outcome: succeeded → paid, failed → declined, pending or unknown → unknown, not charged → not charged."
  @spec attempt_outcome(:pending | :succeeded | :failed | :unknown | :not_charged) :: attempt_outcome()
  def attempt_outcome(status), do: Map.fetch!(@outcome_of_status, status)

  @doc "The attempt statuses that come to `outcome` (the inverse of `attempt_outcome/1`), in `BillingPaymentAttempt.statuses/0` order."
  @spec attempt_statuses_for(attempt_outcome()) :: [:pending | :succeeded | :failed | :unknown | :not_charged]
  def attempt_statuses_for(outcome) when outcome in @attempt_outcomes,
    do: Enum.filter(BillingPaymentAttempt.statuses(), &(@outcome_of_status[&1] == outcome))

  @doc """
  The Stripe dashboard page of a customer — the test-mode dashboard while `:stripe_secret_key`
  is a test key (`sk_test_…`). Nil for no customer.
  """
  @spec stripe_customer_url(String.t() | nil) :: String.t() | nil
  def stripe_customer_url(nil), do: nil

  def stripe_customer_url(customer_id) when is_binary(customer_id) do
    case Relay.Config.get(:stripe_secret_key) do
      "sk_test_" <> _rest -> "#{@stripe_dashboard}/test/customers/#{customer_id}"
      _live_or_unset -> "#{@stripe_dashboard}/customers/#{customer_id}"
    end
  end

  @typedoc "The `/admin/users` side panel's view of one user (`admin_detail/2`)."
  @type admin_detail :: %{
          user_id: pos_integer(),
          name: String.t() | nil,
          email: String.t(),
          standing: Standing.t(),
          plan: admin_plan(),
          comped?: boolean(),
          held?: boolean(),
          hold_reason: String.t() | nil,
          paid_through: Date.t() | nil,
          billing_day: integer() | nil,
          card: nil | %{brand_label: String.t(), last4: String.t()},
          code_label: String.t() | nil,
          retryable?: boolean(),
          stripe_url: String.t() | nil,
          attempts: [
            %{
              id: pos_integer(),
              date: Date.t(),
              period_start: Date.t(),
              period_end: Date.t(),
              amount_cents: non_neg_integer(),
              outcome: attempt_outcome(),
              stripe_payment_intent_id: String.t() | nil
            }
          ],
          entries: [
            %{
              id: pos_integer(),
              action: atom(),
              reason: String.t() | nil,
              days: integer() | nil,
              actor_email: String.t() | nil,
              inserted_at: DateTime.t()
            }
          ]
        }

  @doc """
  The `/admin/users` side panel for `user_id` on `today` (RE463): the billing facts, the plan
  (`admin_plan/2`), whether a retry is allowed, the Stripe link, every payment attempt and every
  admin history entry, newest first. Nil for an unknown user.
  """
  @spec admin_detail(pos_integer(), Date.t()) :: admin_detail() | nil
  def admin_detail(user_id, %Date{} = today) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      nil -> nil
      %User{} = user -> build_admin_detail(user, today)
    end
  end

  defp build_admin_detail(user, today) do
    account = user |> get_account() |> Repo.preload(:promo_code)
    standing = Standing.of(account, facts(account), today)
    plan = admin_plan(standing, Repo.aggregate(from(b in Board, where: b.owner_id == ^user.id), :count))

    %{
      user_id: user.id,
      name: user.name,
      email: user.email,
      standing: standing,
      plan: plan,
      comped?: (account && account.comped) || false,
      held?: not is_nil(account && account.held_on),
      hold_reason: account && account.hold_reason,
      paid_through: account && account.paid_through,
      billing_day: account && account.billing_day,
      card: account |> card() |> admin_card(),
      code_label: code_label(plan, account),
      retryable?: admin_retryable?(account, standing),
      stripe_url: stripe_customer_url(account && account.stripe_customer_id),
      attempts: admin_attempts(account),
      entries: admin_entries(account)
    }
  end

  defp admin_card(nil), do: nil
  defp admin_card(card), do: Map.take(card, [:brand_label, :last4])

  defp admin_attempts(nil), do: []

  defp admin_attempts(%BillingAccount{id: id}) do
    from(p in BillingPaymentAttempt,
      where: p.billing_account_id == ^id,
      order_by: [desc: p.inserted_at, desc: p.id]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        id: p.id,
        date: attempt_date(p),
        period_start: p.period_start,
        period_end: p.period_end,
        amount_cents: p.amount_cents,
        outcome: attempt_outcome(p.status),
        stripe_payment_intent_id: p.stripe_payment_intent_id
      }
    end)
  end

  # THE date an attempt shows on the admin pages: when it settled, else when it opened.
  defp attempt_date(%BillingPaymentAttempt{resolved_at: resolved_at, inserted_at: inserted_at}),
    do: DateTime.to_date(resolved_at || inserted_at)

  @typedoc "One line of the cross-account renewal log (`renewal_log/1`)."
  @type renewal_row :: %{
          id: pos_integer(),
          date: Date.t(),
          user: %{id: pos_integer(), name: String.t() | nil, email: String.t()},
          period_start: Date.t(),
          period_end: Date.t(),
          amount_cents: non_neg_integer(),
          code: String.t() | nil,
          outcome: attempt_outcome(),
          stripe_payment_intent_id: String.t() | nil
        }

  @doc "The most rows `renewal_log/1` returns."
  @spec renewal_log_limit() :: 500
  def renewal_log_limit, do: @renewal_log_limit

  @doc """
  Every payment attempt across accounts for the superadmin's **Renewals** tab (RE463), newest
  first (`inserted_at desc, id desc`), at most `renewal_log_limit/0` rows, in one query. Nil
  lists every outcome; an outcome keeps the attempts whose status is in
  `attempt_statuses_for/1`. `code` is the promo code text the attempt recorded when it opened
  (ADR 0012), not the account's current code. Unscoped on purpose: the gate is the `/admin` route.
  """
  @spec renewal_log(attempt_outcome() | nil) :: [renewal_row()]
  def renewal_log(outcome) when is_nil(outcome) or outcome in @attempt_outcomes do
    from(p in BillingPaymentAttempt,
      join: a in BillingAccount,
      on: a.id == p.billing_account_id,
      join: u in User,
      on: u.id == a.user_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: @renewal_log_limit,
      select: {p, %{id: u.id, name: u.name, email: u.email}}
    )
    |> where_outcome(outcome)
    |> Repo.all()
    |> Enum.map(fn {p, user} ->
      %{
        id: p.id,
        date: attempt_date(p),
        user: user,
        period_start: p.period_start,
        period_end: p.period_end,
        amount_cents: p.amount_cents,
        code: p.promo_code,
        outcome: attempt_outcome(p.status),
        stripe_payment_intent_id: p.stripe_payment_intent_id
      }
    end)
  end

  defp where_outcome(query, nil), do: query
  defp where_outcome(query, outcome), do: where(query, [p], p.status in ^attempt_statuses_for(outcome))

  defp admin_entries(nil), do: []

  defp admin_entries(%BillingAccount{id: id}) do
    Repo.all(
      from e in BillingAdminEntry,
        left_join: u in User,
        on: u.id == e.actor_id,
        where: e.billing_account_id == ^id,
        order_by: [desc: e.inserted_at, desc: e.id],
        select: %{
          id: e.id,
          action: e.action,
          reason: e.reason,
          days: e.days,
          actor_email: u.email,
          inserted_at: e.inserted_at
        }
    )
  end

  @typedoc "What the Billing page shows (`summary/2`)."
  @type summary :: %{
          standing: Standing.t(),
          free: nil | free_status(),
          upgrade_free?: boolean(),
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
    {:ok, account} = ensure_account(user)

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
      {:ok, _account} = ensure_account(setup.user_id)
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
  The billing clock for `today` (`Relay.Billing.Clock` runs it hourly), in order: (a) resolve —
  ask Stripe about every unknown attempt and every pending one older than
  `Charging.pending_overdue_minutes/0`; (b) charge — every paid account due a renewal or
  (`final_pass?: true`, the day's last run) its one retry (a Free account is never charged by the
  clock: it pays by upgrading); (c) notify — `Relay.Billing.Notifier.notify_due/1` records and
  sends the card-declined and dropped-to-Free emails due today, each once per account and period.
  A no-op answering zeros while billing is disabled.
  """
  @spec run_clock(Date.t(), final_pass?: boolean(), now: DateTime.t()) :: %{
          resolved: non_neg_integer(),
          charged: non_neg_integer(),
          notified: non_neg_integer()
        }
  def run_clock(%Date{} = today, opts \\ []) do
    if enabled?() do
      resolved = Charging.resolve_open(Keyword.get(opts, :now, DateTime.utc_now()))
      charged = Charging.charge_due(today, Keyword.get(opts, :final_pass?, false))
      notified = Notifier.notify_due(today)
      %{resolved: resolved, charged: charged, notified: notified}
    else
      %{resolved: 0, charged: 0, notified: 0}
    end
  end

  @doc """
  What the Billing page shows for `user` on `today`. `amount_cents` is the next charge
  (`next_charge/1`), `full_price_cents` the undiscounted price. `free` is `free_status/2` (nil
  unless on Free); `upgrade_free?` is true on Free when the next charge is $0 (a 100% code:
  `upgrade_without_card/2` needs no card). `promo` is nil unless the account holds a code; its
  `full_price_from` is the first charge date back at full price — from an upgrade today (Free)
  or from the renewal (active), `months_left` periods on — and nil when no months are left or
  in any other standing.
  """
  @spec summary(User.t(), Date.t()) :: summary()
  def summary(%User{} = user, %Date{} = today) do
    account = user |> get_account() |> Repo.preload(:promo_code)
    standing = Standing.of(account, facts(account), today)
    paid_through = account && account.paid_through
    renews_on = if(standing == :active, do: Periods.next_renewal(paid_through))
    upgrade_on = if(standing == :free, do: today)
    amount_cents = next_charge(account).amount_cents

    %{
      standing: standing,
      free: free_status(user, today),
      upgrade_free?: standing == :free and amount_cents == 0,
      amount_cents: amount_cents,
      full_price_cents: price_cents(),
      promo: promo(account, upgrade_on, renews_on),
      paid_through: paid_through,
      renews_on: renews_on,
      card: card(account),
      payments: payments(account),
      cancellable?: Standing.cancellable?(standing),
      resumable?: Standing.resumable?(standing)
    }
  end

  defp promo(%BillingAccount{promo_code: %PromoCode{} = promo_code} = account, upgrade_on, renews_on) do
    months_left = account.promo_months_left

    %{
      code: promo_code.code,
      percent_off: promo_code.percent_off,
      months_left: months_left,
      full_price_from: full_price_from(months_left, upgrade_on, renews_on, account.billing_day)
    }
  end

  defp promo(_account, _upgrade_on, _renews_on), do: nil

  defp full_price_from(0, _upgrade_on, _renews_on, _billing_day), do: nil

  defp full_price_from(months_left, %Date{} = upgrade_on, nil, _day),
    do: Periods.renewal_after(upgrade_on, upgrade_on.day, months_left)

  defp full_price_from(months_left, nil, %Date{} = renews_on, day), do: Periods.renewal_after(renews_on, day, months_left)
  defp full_price_from(_months_left, _upgrade_on, _renews_on, _billing_day), do: nil

  @doc """
  Upgrades a Free `user` whose next charge is $0 (a 100% promo code) without a card: a fresh $0
  month from `today` through `Relay.Billing.Charging` (an `:upgrade` attempt that never reaches
  Stripe). Any other standing, or a priced next charge, is `{:error, :checkout_required}` — the
  caller sends the owner to the setup Checkout (`setup_checkout_url/2`), and saving the card
  charges the upgrade.
  """
  @spec upgrade_without_card(User.t(), Date.t()) :: {:ok, :paid} | {:error, :checkout_required}
  def upgrade_without_card(%User{} = user, %Date{} = today) do
    with %BillingAccount{id: account_id} <- get_account(user),
         :paid <- Charging.upgrade(account_id, today) do
      {:ok, :paid}
    else
      _no_account_or_not_free -> {:error, :checkout_required}
    end
  end

  @typedoc "The plan status the native app's Settings shows (`native_status/2`)."
  @type native_status :: %{
          enabled: boolean(),
          standing: :free | :active | :past_due | :cancelled | :comped | :paused | nil,
          through: Date.t() | nil
        }

  @doc """
  The plan status the native app shows `user` on `today` (RE466): the standing's kind and the
  date the plan runs through. `through` is `paid_through` while active or past due,
  `access_until` once cancelled, and nil on Free, comped or paused. With billing disabled it is `%{enabled: false, standing: nil, through: nil}`, read
  without touching the database.
  """
  @spec native_status(User.t() | pos_integer(), Date.t()) :: native_status()
  def native_status(user, %Date{} = today) do
    if enabled?() do
      account = get_account(user)
      standing = Standing.of(account, facts(account), today)
      %{enabled: true, standing: Standing.kind(standing), through: through(standing, account)}
    else
      %{enabled: false, standing: nil, through: nil}
    end
  end

  defp through(:active, account), do: account.paid_through
  defp through({:past_due, _grace_until}, account), do: account.paid_through
  defp through({:cancelled, access_until}, _account), do: access_until
  defp through(_free_comped_or_paused, _account), do: nil

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

  # Only an active or past-due plan is cancellable: access runs through what it has paid for.
  defp access_until(_active_or_past_due, %BillingAccount{paid_through: paid_through}), do: paid_through

  defp update_and_broadcast(changeset) do
    with {:ok, account} <- Repo.update(changeset) do
      :ok = broadcast_changed(account.user_id)
      {:ok, account}
    end
  end

  defp facts(account), do: Charging.facts(account)

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id), do: id

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
