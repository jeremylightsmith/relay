defmodule Relay.Billing.NotifierAppUrlTest do
  @moduledoc """
  RE480 scenario 5: the billing mail's link follows the configured `:app_url`, so flipping it to
  hamaca.app moves every billing email with it.

  The override is a `Process.put/2` read through `Relay.Config` (ADR 0009: a test never writes
  the app env), so this module can stay in the async pool.
  """
  use ExUnit.Case, async: true

  alias Relay.Billing.Notifier

  test "billing_url/0 follows the configured :app_url" do
    Process.put(:app_url, "https://hamaca.app")

    assert Notifier.billing_url() == "https://hamaca.app/account/billing"
  end
end
