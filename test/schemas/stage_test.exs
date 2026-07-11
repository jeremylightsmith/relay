defmodule Schemas.StageTest do
  use Relay.DataCase, async: true

  alias Schemas.Stage

  defp main_changeset(attrs), do: Stage.changeset(%Stage{board_id: 1}, attrs)

  test "type is required" do
    changeset = main_changeset(%{name: "X", position: 1, category: :unstarted})
    refute changeset.valid?
    assert %{type: ["can't be blank"]} = errors_on(changeset)
  end

  test "default_type maps each category" do
    assert Stage.default_type(:unstarted) == :queue
    assert Stage.default_type(:planning) == :planning
    assert Stage.default_type(:in_progress) == :work
    assert Stage.default_type(:complete) == :done
  end

  test "default_status and valid_status? follow the RLY-48 matrix" do
    assert Stage.default_status(:queue) == :ready
    assert Stage.default_status(:work) == :working
    assert Stage.default_status(:planning) == :working
    assert Stage.default_status(:review) == :in_review
    assert Stage.default_status(:done) == :ready

    assert Stage.valid_status?(:ready, :queue)
    refute Stage.valid_status?(:working, :queue)
    assert Stage.valid_status?(:working, :work)
    assert Stage.valid_status?(:ready, :planning)
    assert Stage.valid_status?(:needs_input, :work)
    refute Stage.valid_status?(:in_review, :work)
    assert Stage.valid_status?(:in_review, :review)
    assert Stage.valid_status?(:ready, :review)
    refute Stage.valid_status?(:working, :done)
    assert Stage.valid_status?(:ready, :done)
  end

  test "ai_enabled is forced false unless the type is work or planning" do
    for type <- [:work, :planning] do
      changeset = main_changeset(%{name: "X", position: 1, category: :in_progress, type: type, ai_enabled: true})
      assert Ecto.Changeset.get_field(changeset, :ai_enabled) == true
    end

    for type <- [:queue, :review, :done] do
      changeset = main_changeset(%{name: "X", position: 1, category: :unstarted, type: type, ai_enabled: true})
      assert Ecto.Changeset.get_field(changeset, :ai_enabled) == false
    end
  end

  test "changeset casts reject_to_stage_id" do
    changeset =
      main_changeset(%{name: "Review", position: 4, category: :in_progress, type: :review, reject_to_stage_id: 2})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :reject_to_stage_id) == 2
  end

  test "reject_to_stage_id defaults to nil and may be cleared" do
    changeset =
      main_changeset(%{name: "Review", position: 4, category: :in_progress, type: :review, reject_to_stage_id: nil})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :reject_to_stage_id) == nil
  end

  test "a child stage must be review or done" do
    child = %Stage{board_id: 1, parent_id: 1}
    bad = Stage.changeset(child, %{name: "X", position: 2, category: :in_progress, type: :work})
    refute bad.valid?
    assert %{type: ["sub-lane stages must be review or done"]} = errors_on(bad)

    good = Stage.changeset(child, %{name: "X", position: 2, category: :in_progress, type: :review})
    assert good.valid?
  end
end
