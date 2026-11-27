defmodule Hamaca.BrandTest do
  use ExUnit.Case, async: true

  alias Hamaca.Brand

  test "name/0 is the product name a person reads" do
    assert Brand.name() == "Hamaca"
  end

  test "agent_name/0 is the agent's display name" do
    assert Brand.agent_name() == "Hamaca AI"
  end

  test "support_email/0 is the address /privacy and /terms publish" do
    assert Brand.support_email() == "jeremy.lightsmith@gmail.com"
  end
end
