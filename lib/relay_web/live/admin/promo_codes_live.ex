defmodule RelayWeb.Admin.PromoCodesLive do
  @moduledoc """
  The superadmin's **Promo codes** tab at `/admin/users/promo-codes` (RE462, ADR 0012; card
  mockup "Billing screens — pricing section, Billing page, past-due and read-only board,
  superadmin, iOS status", §4): every code newest first with its discount, months, how many
  accounts hold it over its cap, and its expiry; **New code** creates one
  (`Relay.Billing.create_promo_code/1`) and **Disable** stops new redemptions
  (`Relay.Billing.disable_promo_code/2`) while existing holders keep their months.

  The list is a plain assign re-read from `Relay.Billing.list_promo_codes/0` after each write —
  a handful of rows, no stream, no PubSub. Shares the `Users | Promo codes` tab bar
  (`RelayWeb.AdminComponents.user_tabs/1`) with `RelayWeb.Admin.UsersLive`. Gated by the
  `:admin` live_session.
  """
  use RelayWeb, :live_view

  import RelayWeb.AdminComponents, only: [user_tabs: 1]

  alias Relay.Billing
  alias Schemas.PromoCode

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Promo codes")
     |> assign(:form, nil)
     |> assign_codes()}
  end

  @impl true
  def handle_event("new_code", _params, socket) do
    {:noreply, assign(socket, :form, to_form(Billing.change_promo_code(%PromoCode{}, %{}), as: :promo_code))}
  end

  def handle_event("cancel_new", _params, socket), do: {:noreply, assign(socket, :form, nil)}

  def handle_event("validate", %{"promo_code" => params}, socket) do
    changeset = %PromoCode{} |> Billing.change_promo_code(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset, as: :promo_code))}
  end

  def handle_event("create", %{"promo_code" => params}, socket) do
    case Billing.create_promo_code(params) do
      {:ok, %PromoCode{code: code}} ->
        {:noreply,
         socket
         |> assign(:form, nil)
         |> assign_codes()
         |> put_flash(:info, "Created #{code}.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :promo_code))}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    case Billing.disable_promo_code(String.to_integer(id), DateTime.utc_now(:second)) do
      {:ok, %PromoCode{code: code}} ->
        {:noreply, socket |> assign_codes() |> put_flash(:info, "Disabled #{code}.")}

      {:error, :not_found} ->
        {:noreply, socket |> assign_codes() |> put_flash(:error, "That code no longer exists.")}
    end
  end

  defp assign_codes(socket), do: assign(socket, :codes, Billing.list_promo_codes())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl px-4 py-8">
        <.link
          navigate={~p"/admin"}
          id="admin-back"
          class="text-sm text-base-content/65 link link-hover"
        >
          ← Admin
        </.link>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <h1 class="text-2xl font-semibold">Users</h1>
          <span class="flex-1"></span>
          <.user_tabs active={:promo_codes} />
        </div>
        <p class="mt-1 text-sm text-base-content/65">
          Every promo code, newest first. One code per account, ever.
        </p>

        <div class="mt-6 overflow-x-auto rounded-box border border-base-200">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Code</th>
                <th>Discount</th>
                <th>Months</th>
                <th>Used</th>
                <th>Expires</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="admin-promo-codes">
              <tr :if={@codes == []} id="admin-promo-codes-empty">
                <td colspan="6" class="text-base-content/65">No codes yet.</td>
              </tr>
              <tr :for={%{promo_code: code, used: used} <- @codes} id={"promo-code-#{code.id}"}>
                <td class="font-mono">{code.code}</td>
                <td>{code.percent_off}%</td>
                <td>{code.months}</td>
                <td class="tabular-nums">{used} / {code.max_redemptions || "—"}</td>
                <td :if={code.expires_on} class="font-mono text-xs">
                  {Date.to_iso8601(code.expires_on)}
                </td>
                <td :if={!code.expires_on} class="text-base-content/45">never</td>
                <td class="text-right">
                  <.button
                    :if={!code.disabled_at}
                    id={"promo-code-#{code.id}-disable"}
                    phx-click="disable"
                    phx-value-id={code.id}
                    class="btn btn-ghost btn-xs"
                    data-confirm={"Disable #{code.code}? Accounts that already redeemed it keep their remaining months."}
                  >
                    Disable
                  </.button>
                  <span :if={code.disabled_at} class="badge badge-ghost badge-sm">disabled</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.button
          :if={!@form}
          id="promo-new-code"
          phx-click="new_code"
          class="btn btn-sm btn-outline mt-3"
        >
          New code
        </.button>

        <.form
          :if={@form}
          for={@form}
          id="promo-code-form"
          phx-change="validate"
          phx-submit="create"
          class="mt-4 max-w-md rounded-box border border-base-200 p-4"
        >
          <.input field={@form[:code]} label="Code" />
          <.input field={@form[:percent_off]} type="number" label="Percent off" />
          <.input field={@form[:months]} type="number" label="Months" />
          <.input field={@form[:max_redemptions]} type="number" label="Cap (optional)" />
          <.input field={@form[:expires_on]} type="date" label="Expires (optional)" />
          <div class="mt-2 flex gap-2">
            <.button id="promo-code-create" type="submit" class="btn btn-primary btn-sm">
              Create code
            </.button>
            <.button
              id="promo-code-cancel"
              type="button"
              phx-click="cancel_new"
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
