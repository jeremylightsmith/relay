defmodule Relay.BrandTest do
  use ExUnit.Case, async: true

  alias Relay.Brand

  test "name/0 is the product name a person reads" do
    assert Brand.name() == "Hamaca"
  end

  test "agent_name/0 is the agent's display name" do
    assert Brand.agent_name() == "Hamaca AI"
  end
end
