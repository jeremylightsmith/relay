defmodule RelayWeb.SessionPolicyTest do
  use ExUnit.Case, async: true

  alias RelayWeb.SessionPolicy

  test "the session window is 7 days" do
    assert SessionPolicy.max_age() == 60 * 60 * 24 * 7
    assert SessionPolicy.max_age() == 604_800
  end

  test "the refresh throttle is one day, well inside the window" do
    assert SessionPolicy.refresh_after() == 60 * 60 * 24
    assert SessionPolicy.refresh_after() < SessionPolicy.max_age()
  end
end
