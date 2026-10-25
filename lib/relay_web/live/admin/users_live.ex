defmodule RelayWeb.Admin.UsersLive do
  @moduledoc """
  The table of every user at `/admin/users` (RE353, RE463): name, email, board count, the
  billing columns — Members, Plan, Paid through, Rate, Code — and created date, newest first,
  under a summary line (`N users · N paying · $N/mo · N on Free`). Rows come from
  `Relay.Billing.list_admin_users/1` (one query) and the summary from
  `Relay.Billing.admin_summary/1`, as of today — a snapshot at mount (no PubSub), re-read after
  each admin write. Gated by the `:admin` live_session. Its header carries the `Users | Promo codes` tab bar
  (`RelayWeb.AdminComponents.user_tabs/1`, RE462) shared with `RelayWeb.Admin.PromoCodesLive`.

  **Row side panel** (RE463, modelled on Throughway's `/admin?org=<id>` org panel): clicking a row
  patches to `?user=<id>`, which opens `#admin-user-panel` from `Relay.Billing.admin_detail/2` —
  state, facts, the actions (Comp / Uncomp, Hold / Lift hold, Extend, Retry charge now, Open in
  Stripe), payment history and admin history. An unparsable or unknown id opens nothing. Each
  action calls one `Relay.Billing.admin_*` write with the signed-in superadmin as the actor; on
  `{:ok, _}` the rows are re-streamed, the summary recomputed and the panel reloaded; on a
  refusal the flash carries `refusal_message/1` and nothing else changes. The owner's open boards
  update through the write's own `billing:<user_id>` broadcast.
  """
  use RelayWeb, :live_view

  import RelayWeb.AdminComponents, only: [outcome_badge: 1, plan_badge: 1, user_tabs: 1]

  alias Phoenix.HTML.Form
  alias Relay.Billing

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Users")
     |> assign(:detail, nil)
     |> assign(:action_form, nil)
     |> load_users()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:action_form, nil)
     |> assign(:detail, params |> Map.get("user") |> user_id_param() |> detail())}
  end

  @impl true
  def handle_event("comp", _params, socket), do: apply_write(socket, "Comped.", &Billing.admin_comp(&1, &2, &3))

  def handle_event("uncomp", _params, socket), do: apply_write(socket, "Comp removed.", &Billing.admin_uncomp(&1, &2, &3))

  def handle_event("lift_hold", _params, socket),
    do: apply_write(socket, "Hold lifted.", &Billing.admin_lift_hold(&1, &2, &3))

  def handle_event("retry_charge", _params, socket) do
    apply_write(
      socket,
      fn {:ok, outcome} -> "Charge retried: #{retry_label(outcome)}." end,
      &Billing.admin_retry_charge(&1, &2, &3)
    )
  end

  def handle_event("show_hold", _params, socket),
    do: {:noreply, assign(socket, :action_form, {:hold, to_form(%{"reason" => ""}, as: :hold)})}

  def handle_event("show_extend", _params, socket),
    do: {:noreply, assign(socket, :action_form, {:extend, to_form(%{"days" => "7", "reason" => ""}, as: :extend)})}

  def handle_event("cancel_form", _params, socket), do: {:noreply, assign(socket, :action_form, nil)}

  def handle_event("hold", %{"hold" => %{"reason" => reason}}, socket),
    do: apply_write(socket, "Held.", &Billing.admin_hold(&1, &2, reason, &3))

  def handle_event("extend", %{"extend" => %{"days" => days, "reason" => reason}}, socket) do
    days = days_param(days)
    apply_write(socket, "Extended #{days} days.", &Billing.admin_extend(&1, &2, days, reason, &3))
  end

  # Runs one admin write for the open panel's user, as the signed-in superadmin.
  defp apply_write(%{assigns: %{detail: %{user_id: user_id}}} = socket, message, write) do
    case write.(user_id, socket.assigns.current_scope.user, Date.utc_today()) do
      {:ok, _result} = ok ->
        {:noreply,
         socket
         |> put_flash(:info, if(is_function(message), do: message.(ok), else: message))
         |> assign(:action_form, nil)
         |> assign(:detail, detail(user_id))
         |> load_users()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal_message(reason))}
    end
  end

  defp apply_write(socket, _message, _write), do: {:noreply, socket}

  defp load_users(socket) do
    users = Billing.list_admin_users(Date.utc_today())

    socket
    |> assign(:summary, Billing.admin_summary(users))
    |> stream(:users, users, dom_id: &"admin-user-#{&1.id}", reset: true)
  end

  defp detail(nil), do: nil
  defp detail(user_id), do: Billing.admin_detail(user_id, Date.utc_today())

  defp user_id_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _not_an_id -> nil
    end
  end

  defp user_id_param(_value), do: nil

  # An unparsable day count is 0, which `admin_extend/5` refuses as `:invalid_days`.
  defp days_param(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} -> days
      _not_a_number -> 0
    end
  end

  defp days_param(_value), do: 0

  defp retry_label(:none), do: "nothing to charge"
  defp retry_label(:not_charged), do: "not charged"
  defp retry_label(outcome), do: Atom.to_string(outcome)

  @doc false
  # The ONE place the admin refusal copy lives — one message per `Relay.Billing.admin_refusals/0`.
  @spec refusal_message(Billing.admin_refusal()) :: String.t()
  def refusal_message(:already_comped), do: "This account is already comped."
  def refusal_message(:not_comped), do: "This account isn't comped."
  def refusal_message(:reason_required), do: "Give a reason."
  def refusal_message(:already_held), do: "This account is already on hold."
  def refusal_message(:not_held), do: "This account isn't on hold."

  def refusal_message(:invalid_days), do: "Extend by a whole number of days, 1 to #{Billing.admin_extend_max_days()}."

  def refusal_message(:no_paid_through), do: "This account has never paid, so there's no paid-through date to extend."
  def refusal_message(:not_retryable), do: "There's no charge to retry: it needs a card and a past-due or paused plan."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="mx-auto max-w-6xl px-4 py-8">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm text-base-content/65 link link-hover"
        >
          ← Admin
        </.link>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold">Users</h1>
          <span id="admin-users-summary" class="text-sm text-base-content/65">
            {@summary.users} users · {@summary.paying} paying ·
            <span class="text-success">{Billing.format_dollars(@summary.mrr_cents)}/mo</span>
            · {@summary.free} on Free
          </span>
          <span class="flex-1"></span>
          <.user_tabs active={:users} />
        </div>
        <p class="mt-1 text-sm text-base-content/65">Every user, newest first.</p>

        <div class="mt-6 overflow-x-auto rounded-box border border-base-200">
          <table id="admin-users-table" class="table table-sm">
            <thead>
              <tr>
                <th>Name</th>
                <th>Email</th>
                <th class="text-right">Boards</th>
                <th class="text-right">Members</th>
                <th>Plan</th>
                <th>Paid through</th>
                <th>Rate</th>
                <th>Code</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody id="admin-users" phx-update="stream">
              <tr
                :for={{dom_id, user} <- @streams.users}
                id={dom_id}
                phx-click={JS.patch(~p"/admin/users?user=#{user.id}")}
                class="cursor-pointer hover:bg-base-200"
              >
                <td class="font-medium whitespace-nowrap">{user.name || "—"}</td>
                <td class="whitespace-nowrap">{user.email}</td>
                <td id={"#{dom_id}-boards"} class="text-right tabular-nums">{user.board_count}</td>
                <.value_cell
                  id={"#{dom_id}-members"}
                  value={if(user.plan != :member_only, do: user.member_count)}
                  class="text-right tabular-nums"
                  empty_class="text-right"
                />
                <td id={"#{dom_id}-plan"} class="whitespace-nowrap">
                  <.plan_badge plan={user.plan} />
                </td>
                <.value_cell
                  id={"#{dom_id}-paid-through"}
                  value={user.paid_through_shown && Date.to_iso8601(user.paid_through_shown)}
                  class="font-mono text-xs whitespace-nowrap"
                />
                <.value_cell
                  id={"#{dom_id}-rate"}
                  value={user.rate_cents && Billing.format_dollars(user.rate_cents)}
                  class="font-mono text-xs whitespace-nowrap"
                />
                <.value_cell id={"#{dom_id}-code"} value={user.code_label} class="font-mono text-xs" />
                <td class="font-mono text-xs whitespace-nowrap text-base-content/65">
                  {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <.user_panel :if={@detail} detail={@detail} action_form={@action_form} />
    </Layouts.app>
    """
  end

  # The row side panel (`?user=<id>`): header, state, facts, actions, then the two histories.
  attr :detail, :map, required: true
  attr :action_form, :any, required: true

  defp user_panel(assigns) do
    ~H"""
    <aside
      id="admin-user-panel"
      class="fixed inset-y-0 right-0 z-40 flex w-full max-w-md flex-col border-l border-base-300 bg-base-100 shadow-xl"
    >
      <header class="flex items-start gap-3 border-b border-base-300 px-5 py-4">
        <div class="min-w-0 flex-1">
          <h2 class="truncate text-lg font-semibold">{@detail.name || @detail.email}</h2>
          <p class="truncate text-sm text-base-content/65">{@detail.email}</p>
        </div>
        <.link
          id="admin-user-panel-close"
          patch={~p"/admin/users"}
          class="btn btn-ghost btn-sm btn-square"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.link>
      </header>

      <div class="flex-1 space-y-6 overflow-y-auto px-5 py-5">
        <section>
          <.panel_title>State</.panel_title>
          <div class="flex items-center gap-2">
            <span id="admin-user-panel-plan"><.plan_badge plan={@detail.plan} /></span>
            <span :if={@detail.held?} class="text-sm text-base-content/65">
              Held: {@detail.hold_reason}
            </span>
          </div>
        </section>

        <dl id="admin-user-panel-facts" class="grid grid-cols-2 gap-3">
          <.fact
            label="Paid through"
            value={@detail.paid_through && Date.to_iso8601(@detail.paid_through)}
          />
          <.fact label="Billing day" value={@detail.billing_day} />
          <.fact
            label="Card"
            value={@detail.card && "#{@detail.card.brand_label} ·· #{@detail.card.last4}"}
          />
          <.fact label="Code" value={@detail.code_label} />
        </dl>

        <section>
          <.panel_title>Actions</.panel_title>
          <div class="flex flex-wrap gap-2">
            <.button
              :if={!@detail.comped?}
              id="admin-user-comp"
              phx-click="comp"
              class="btn btn-sm btn-outline"
              data-confirm="Comp this account? Its boards stay editable without paying."
            >
              Comp
            </.button>
            <.button
              :if={@detail.comped?}
              id="admin-user-uncomp"
              phx-click="uncomp"
              class="btn btn-sm btn-outline"
              data-confirm="Remove the comp? The plan's standing is then derived as usual."
            >
              Uncomp
            </.button>
            <.button
              :if={!@detail.held?}
              id="admin-user-hold"
              phx-click="show_hold"
              class="btn btn-sm btn-outline"
            >
              Hold
            </.button>
            <.button
              :if={@detail.held?}
              id="admin-user-lift-hold"
              phx-click="lift_hold"
              class="btn btn-sm btn-outline"
              data-confirm="Lift the hold?"
            >
              Lift hold
            </.button>
            <.button
              :if={@detail.paid_through}
              id="admin-user-extend"
              phx-click="show_extend"
              class="btn btn-sm btn-outline"
            >
              Extend
            </.button>
            <.button
              :if={@detail.retryable?}
              id="admin-user-retry"
              phx-click="retry_charge"
              class="btn btn-sm btn-outline"
              data-confirm="Charge the card on file now?"
            >
              Retry charge now
            </.button>
            <a
              :if={@detail.stripe_url}
              id="admin-user-stripe"
              href={@detail.stripe_url}
              target="_blank"
              rel="noopener"
              class="btn btn-sm btn-ghost"
            >
              Open in Stripe <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
          </div>

          <.hold_form :if={match?({:hold, _form}, @action_form)} form={elem(@action_form, 1)} />
          <.extend_form :if={match?({:extend, _form}, @action_form)} form={elem(@action_form, 1)} />
        </section>

        <section>
          <.panel_title>Payment history</.panel_title>
          <ul id="admin-user-attempts" class="divide-y divide-base-300 text-sm">
            <li
              :if={@detail.attempts == []}
              id="admin-user-attempts-empty"
              class="py-2 text-base-content/65"
            >
              No payment attempts.
            </li>
            <li
              :for={attempt <- @detail.attempts}
              id={"admin-attempt-#{attempt.id}"}
              class="flex items-center gap-2 py-2"
            >
              <span class="font-mono text-xs">{Date.to_iso8601(attempt.date)}</span>
              <span class="flex-1 text-base-content/65">
                {Date.to_iso8601(attempt.period_start)} – {Date.to_iso8601(attempt.period_end)}
              </span>
              <span class="font-mono text-xs">{Billing.format_cents(attempt.amount_cents)}</span>
              <.outcome_badge outcome={attempt.outcome} />
            </li>
          </ul>
        </section>

        <section>
          <.panel_title>Admin history</.panel_title>
          <ul id="admin-user-entries" class="divide-y divide-base-300 text-sm">
            <li
              :if={@detail.entries == []}
              id="admin-user-entries-empty"
              class="py-2 text-base-content/65"
            >
              No admin actions.
            </li>
            <li :for={entry <- @detail.entries} id={"admin-entry-#{entry.id}"} class="py-2">
              <div class="flex items-center gap-2">
                <span class="font-medium">{action_label(entry)}</span>
                <span class="flex-1"></span>
                <span class="font-mono text-xs text-base-content/65">
                  {Calendar.strftime(entry.inserted_at, "%Y-%m-%d")}
                </span>
              </div>
              <p class="text-base-content/65">
                {entry.actor_email || "deleted admin"}<span :if={entry.reason}> · {entry.reason}</span>
              </p>
            </li>
          </ul>
        </section>
      </div>
    </aside>
    """
  end

  slot :inner_block, required: true

  defp panel_title(assigns) do
    ~H"""
    <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/65">
      {render_slot(@inner_block)}
    </h3>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp fact(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 px-3 py-2">
      <dt class="text-xs text-base-content/65">{@label}</dt>
      <dd :if={@value} class="font-mono text-sm">{@value}</dd>
      <dd :if={!@value} class="text-sm text-base-content/45">—</dd>
    </div>
    """
  end

  attr :form, Form, required: true

  defp hold_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="admin-hold-form"
      phx-submit="hold"
      class="mt-3 rounded-box border border-base-300 p-3"
    >
      <.input field={@form[:reason]} type="text" label="Reason" placeholder="e.g. chargeback" />
      <div class="mt-2 flex justify-end gap-2">
        <.button type="button" phx-click="cancel_form" class="btn btn-sm btn-ghost">Cancel</.button>
        <.button
          id="admin-hold-submit"
          type="submit"
          class="btn btn-sm btn-primary"
          data-confirm="Hold this account? Its boards go read-only."
        >
          Hold
        </.button>
      </div>
    </.form>
    """
  end

  attr :form, Form, required: true

  defp extend_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="admin-extend-form"
      phx-submit="extend"
      class="mt-3 rounded-box border border-base-300 p-3"
    >
      <div class="grid grid-cols-[6rem_1fr] gap-2">
        <.input
          field={@form[:days]}
          type="number"
          label="Days"
          min="1"
          max={Billing.admin_extend_max_days()}
        />
        <.input field={@form[:reason]} type="text" label="Reason" placeholder="e.g. outage" />
      </div>
      <div class="mt-2 flex justify-end gap-2">
        <.button type="button" phx-click="cancel_form" class="btn btn-sm btn-ghost">Cancel</.button>
        <.button
          id="admin-extend-submit"
          type="submit"
          class="btn btn-sm btn-primary"
          data-confirm="Extend this account's paid-through date? Nothing is charged."
        >
          Extend
        </.button>
      </div>
    </.form>
    """
  end

  defp action_label(%{action: :comp}), do: "Comped"
  defp action_label(%{action: :uncomp}), do: "Comp removed"
  defp action_label(%{action: :hold}), do: "Held"
  defp action_label(%{action: :lift_hold}), do: "Hold lifted"
  defp action_label(%{action: :extend, days: days}), do: "Extended #{days} days"
  defp action_label(%{action: :retry_charge}), do: "Retried charge"

  # A table cell showing `value` in `class`, or a muted `—` when it is nil.
  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, required: true
  attr :empty_class, :string, default: nil

  defp value_cell(%{value: nil} = assigns) do
    ~H"""
    <td id={@id} class={[@empty_class, "text-base-content/45"]}>—</td>
    """
  end

  defp value_cell(assigns) do
    ~H"""
    <td id={@id} class={@class}>{@value}</td>
    """
  end
end
