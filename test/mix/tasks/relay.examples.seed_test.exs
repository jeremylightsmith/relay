defmodule Mix.Tasks.Relay.Examples.SeedTest do
  # Not async: `boards.example_template` is unique (see `Relay.ExamplesTest`).
  use Relay.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Relay.Examples.Seed

  # Scenario 12
  test "creates the three example boards, then skips them on a second run" do
    user = insert(:user)

    out = capture_io(fn -> Seed.run(["--owner", user.email]) end)
    assert String.split(out, "\n", trim: true) == ["created bare-minimum", "created design-led", "created three-brain"]

    again = capture_io(fn -> Seed.run(["--owner", user.email]) end)
    assert String.split(again, "\n", trim: true) == ["skipped bare-minimum", "skipped design-led", "skipped three-brain"]
  end

  test "--reset recreates the boards" do
    user = insert(:user)
    capture_io(fn -> Seed.run(["--owner", user.email]) end)

    out = capture_io(fn -> Seed.run(["--owner", user.email, "--reset"]) end)
    assert String.split(out, "\n", trim: true) == ["created bare-minimum", "created design-led", "created three-brain"]
  end

  # Scenario 13
  test "raises when the owner doesn't exist" do
    assert_raise Mix.Error, "no user with email ghost@example.com", fn ->
      Seed.run(["--owner", "ghost@example.com"])
    end
  end

  test "raises when --owner is missing" do
    assert_raise Mix.Error, "--owner <email> is required", fn -> Seed.run([]) end
  end

  # Scenario 14
  test "Relay.Release.seed_examples/2 returns the seed!/2 summary" do
    user = insert(:user)

    assert Relay.Release.seed_examples(user.email, []) == %{
             created: ["bare-minimum", "design-led", "three-brain"],
             skipped: []
           }
  end

  test "Relay.Release.seed_examples/2 raises ArgumentError for an unknown email" do
    assert_raise ArgumentError, fn -> Relay.Release.seed_examples("ghost@example.com", []) end
  end
end
