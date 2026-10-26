defmodule Schemas.UserTest do
  use ExUnit.Case, async: true

  alias Schemas.User

  describe "synthetic accounts (RE475)" do
    test "synthetic_providers/0 is the one list of dev and seed providers" do
      assert User.synthetic_providers() == ["dev", "seed"]
    end

    test "synthetic?/1 is true only for a synthetic provider" do
      assert User.synthetic?(%User{provider: "dev"})
      refute User.synthetic?(%User{provider: "google"})
      refute User.synthetic?(%User{provider: nil})
    end
  end
end
