defmodule Schemas.StageTest do
  use Relay.DataCase, async: true

  alias Schemas.Stage

  require Stage

  defp main_changeset(attrs), do: Stage.changeset(%Stage{board_id: 1}, attrs)

  defp classify(t) when Stage.is_work_type(t), do: :work
  defp classify(_t), do: :other

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
    # RLY-57: a review stage only holds :in_review — a :ready card moved in snaps to :in_review
    # so it is reviewable/rejectable, not parked as "already approved".
    refute Stage.valid_status?(:ready, :review)
    refute Stage.valid_status?(:working, :done)
    assert Stage.valid_status?(:ready, :done)

    # RLY-133: :queued is the pre-run "capacity-blocked, waiting for a runner" marker, valid only
    # where a flow pulls from — a queue stage (Next up) or a done sub-lane (Spec:Done, Plan:Done).
    assert Stage.valid_status?(:queued, :queue)
    assert Stage.valid_status?(:queued, :done)
    refute Stage.valid_status?(:queued, :work)
    refute Stage.valid_status?(:queued, :planning)
    refute Stage.valid_status?(:queued, :review)
  end

  test "arrival_status keeps a status valid for the type, else takes the type's default (ADR 0003)" do
    # valid → kept
    assert Stage.arrival_status(:ready, :queue) == :ready
    assert Stage.arrival_status(:queued, :queue) == :queued
    assert Stage.arrival_status(:ready, :work) == :ready
    assert Stage.arrival_status(:needs_input, :planning) == :needs_input
    assert Stage.arrival_status(:in_review, :review) == :in_review
    assert Stage.arrival_status(:ready, :done) == :ready

    # invalid → the type's default
    assert Stage.arrival_status(:working, :queue) == :ready
    assert Stage.arrival_status(:in_review, :work) == :working
    assert Stage.arrival_status(:queued, :planning) == :working
    assert Stage.arrival_status(:ready, :review) == :in_review
    assert Stage.arrival_status(:working, :done) == :ready
  end

  test "ai_enabled is not a stage field — the changeset ignores it (RE409)" do
    changeset = main_changeset(%{name: "X", position: 1, category: :in_progress, type: :work, ai_enabled: true})

    assert changeset.valid?
    assert Map.has_key?(Ecto.Changeset.apply_changes(changeset), :ai_enabled) == false
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

  test "terminal_types/0 is exactly [:done]" do
    assert Stage.terminal_types() == [:done]
  end

  test "a child stage must be review or done" do
    child = %Stage{board_id: 1, parent_id: 1}
    bad = Stage.changeset(child, %{name: "X", position: 2, category: :in_progress, type: :work})
    refute bad.valid?
    assert %{type: ["sub-lane stages must be review or done"]} = errors_on(bad)

    good = Stage.changeset(child, %{name: "X", position: 2, category: :in_progress, type: :review})
    assert good.valid?
  end

  describe "sub-lane vocabulary (RE385)" do
    test "sublane_types/0 is exactly review then done" do
      assert Stage.sublane_types() == [:review, :done]
    end

    test "sublane_rank/1 orders review, done, then anything else" do
      assert Stage.sublane_rank(:review) == 0
      assert Stage.sublane_rank(:done) == 1
      assert Stage.sublane_rank(:work) == 2
    end
  end

  describe "is_work_type/1 guard (RE415)" do
    test "is true for every work type" do
      assert Enum.all?(Stage.work_types(), &Stage.is_work_type(&1))
    end

    test "is false for every non-work stage type" do
      non_work = Stage.types() -- Stage.work_types()
      assert non_work != []
      refute Enum.any?(non_work, &Stage.is_work_type(&1))
    end

    test "works in a function head" do
      assert classify(:planning) == :work
      assert classify(:review) == :other
    end

    test "is false for non-type inputs" do
      refute Stage.is_work_type(nil)
      refute Stage.is_work_type("work")
    end
  end

  describe "order_stages/1" do
    defp stage(id, name, position, parent_id \\ nil, type \\ :work) do
      %Stage{id: id, name: name, position: position, parent_id: parent_id, type: type}
    end

    test "orders mains by position, each followed by its Review then Done substage" do
      stages = [
        stage(1, "A", 2),
        stage(2, "B", 1),
        stage(3, "A:Done", 9, 1, :done),
        stage(4, "A:Review", 10, 1, :review)
      ]

      for permutation <- [stages, Enum.reverse(stages), Enum.shuffle(stages)] do
        assert permutation |> Stage.order_stages() |> Enum.map(& &1.name) == ["B", "A", "A:Review", "A:Done"]
      end
    end

    test "returns [] for []" do
      assert Stage.order_stages([]) == []
    end

    test "appends a child whose parent is not in the list, dropping nothing" do
      stages = [stage(10, "X:Review", 2, 999, :review), stage(1, "A", 1)]

      assert stages |> Stage.order_stages() |> Enum.map(& &1.name) == ["A", "X:Review"]
    end
  end
end
