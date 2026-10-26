defmodule Hamaca.ExamplesTest do
  @moduledoc "RE444: the public example boards — content, seeding, and their Boards/Accounts reads."
  # Not async: `boards.example_template` is unique, so two modules seeding at once would only
  # queue on each other's uncommitted rows.
  use Hamaca.DataCase, async: false

  import Ecto.Query

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Examples
  alias Hamaca.Flows
  alias Hamaca.Repo
  alias Schemas.Board
  alias Schemas.Card

  @slugs ["bare-minimum", "design-led", "three-brain"]

  defp seed!(user \\ insert(:user)) do
    summary = Examples.seed!(user, [])
    {user, summary}
  end

  defp example_board!(slug) do
    {:ok, board} = Boards.get_example_board(slug)
    board
  end

  defp counts_by_stage(board) do
    names = Map.new(board.stages, &{&1.id, &1.name})

    board
    |> Cards.list_cards()
    |> Enum.frequencies_by(&Map.fetch!(names, &1.stage_id))
  end

  defp card!(board, ref), do: Cards.get_card_by_ref(board, ref)

  describe "seed!/2" do
    # Scenario 1
    test "creates the three marked boards with their names and keys" do
      {_user, summary} = seed!()

      assert summary == %{created: @slugs, skipped: []}

      assert Boards.example_boards() == %{
               "bare-minimum" => "Streaks (bare-minimum)",
               "design-led" => "Pantry (design-led)",
               "three-brain" => "Tiny Dungeon (three-brain)"
             }

      assert Enum.map(@slugs, &example_board!(&1).key) == ["ST", "PA", "DU"]
    end

    # Scenario 2
    test "puts the mockups' cards in each stage and sub-lane" do
      seed!()

      assert counts_by_stage(example_board!("bare-minimum")) == %{
               "Backlog" => 5,
               "Plan" => 2,
               "Implement" => 2,
               "Review" => 1,
               "Deploy" => 1,
               "Done" => 3
             }

      assert counts_by_stage(example_board!("design-led")) == %{
               "Backlog" => 4,
               "Next up" => 1,
               "Design" => 1,
               "Design:Review" => 1,
               "Plan:Review" => 1,
               "Code" => 2,
               "Review" => 2,
               "Deploy" => 1,
               "Done" => 3
             }

      assert counts_by_stage(example_board!("three-brain")) == %{
               "Backlog" => 5,
               "Plan" => 1,
               "Plan:Review" => 1,
               "Implement" => 1,
               "Review" => 1,
               "Deploy" => 1,
               "Done" => 3
             }

      totals = Enum.map(@slugs, &(&1 |> example_board!() |> counts_by_stage() |> Map.values() |> Enum.sum()))
      assert totals == [14, 16, 13]
    end

    # Scenario 3
    test "gives each card its status, baton, question, tasks and tag" do
      {user, _summary} = seed!()
      board = example_board!("bare-minimum")

      st11 = card!(board, "ST11")
      assert st11.status == :needs_input
      assert [%{actor_type: :agent}] = st11.owners
      assert Cards.needs_input_questions(board)[st11.id] == "Should weeks start on Sunday or Monday?"

      st9 = card!(board, "ST9")
      assert st9.status == :in_review
      user_id = user.id
      assert [%{actor_type: :user, user_id: ^user_id}] = st9.owners

      assert card!(board, "ST1").status == :ready

      tasks = Cards.list_tasks(card!(board, "ST10"))
      assert length(tasks) == 4
      assert Enum.count(tasks, & &1.done) == 1

      assert card!(board, "ST14").tag == "stats"
    end

    # Scenario 4
    test "keeps the mockups' ref numbers and top-to-bottom order" do
      seed!()

      seqs = Enum.map(@slugs, &example_board!(&1).card_seq)
      assert seqs == [18, 34, 44]

      board = example_board!("bare-minimum")
      backlog = Enum.find(board.stages, &(&1.name == "Backlog"))

      refs =
        for %Card{stage_id: stage_id} = card <- Cards.list_cards(board), stage_id == backlog.id do
          "ST#{card.ref_number}"
        end

      assert refs == ["ST14", "ST15", "ST16", "ST17", "ST18"]
    end

    # Scenario 5
    test "leaves every flow disabled" do
      seed!()

      flows = Enum.flat_map(@slugs, &Flows.list_flows(example_board!(&1)))
      assert flows != []
      assert Enum.all?(flows, &(&1.enabled == false))
    end

    # Scenario 6
    test "skips boards that already exist and touches nothing" do
      {user, _summary} = seed!()
      before = {Repo.aggregate(Board, :count), Repo.aggregate(Card, :count)}

      assert Examples.seed!(user, []) == %{created: [], skipped: @slugs}
      assert {Repo.aggregate(Board, :count), Repo.aggregate(Card, :count)} == before
    end

    # Scenario 7
    test "reset: true deletes and recreates each board" do
      {user, _summary} = seed!()
      old_ids = Enum.map(@slugs, &example_board!(&1).id)
      st18 = card!(example_board!("bare-minimum"), "ST18")
      {1, _} = Repo.update_all(from(c in Card, where: c.id == ^st18.id), set: [title: "edited"])
      board_count = Repo.aggregate(Board, :count)

      assert Examples.seed!(user, reset: true) == %{created: @slugs, skipped: []}

      new_ids = Enum.map(@slugs, &example_board!(&1).id)
      assert Enum.all?(Enum.zip(old_ids, new_ids), fn {old, new} -> old != new end)

      for slug <- @slugs do
        assert Repo.aggregate(from(b in Board, where: b.example_template == ^slug), :count) == 1
      end

      assert card!(example_board!("bare-minimum"), "ST18").title == "Export streaks to CSV"
      assert Repo.aggregate(Board, :count) == board_count
    end
  end

  describe "content" do
    # Scenario 10
    test "all/0 follows the template order and carries each flow's selected node" do
      assert Enum.map(Examples.all(), & &1.template) == Enum.map(Boards.templates(), & &1.slug)
      assert Examples.get("three-brain").flows["three-brain-plan"].selected == "gpt_plan"
      assert Examples.get("nope") == nil
    end

    test "every card stage and note key is one of its template's stages" do
      templates = Map.new(Boards.templates(), &{&1.slug, &1})

      for example <- Examples.all() do
        stage_names = Enum.map(Map.fetch!(templates, example.template).stages, & &1.name)

        for card <- example.cards, do: assert(card.stage in stage_names)
        for {name, _note} <- example.notes, do: assert(name in stage_names)
      end
    end

    test "note kinds and baton sides are the closed sets" do
      assert Examples.note_kinds() == [:full, :why]
      assert Examples.batons() == [:ai, :human]
    end
  end

  describe "Boards" do
    # Scenario 8
    test "no example boards before seeding" do
      assert Boards.get_example_board("bare-minimum") == :error
      assert Boards.get_example_board("nope") == :error
      assert Boards.example_boards() == %{}
    end

    # Scenario 9
    test "mark_example/2 refuses an unknown template and leaves the column nil" do
      board = insert(:board)

      assert Boards.mark_example(board, "nope") == {:error, :unknown_template}
      assert Repo.reload!(board).example_template == nil
    end

    test "mark_example/2 refuses a template another board already holds" do
      assert {:ok, %Board{example_template: "bare-minimum"}} = Boards.mark_example(insert(:board), "bare-minimum")

      assert {:error, %Ecto.Changeset{} = changeset} = Boards.mark_example(insert(:board), "bare-minimum")
      assert errors_on(changeset)[:example_template]
    end

    test "Board.changeset/2 never casts example_template" do
      changeset = Board.changeset(%Board{}, %{example_template: "bare-minimum"})

      assert Ecto.Changeset.get_field(changeset, :example_template) == nil
    end

    test "get_example_board/1 preloads the stages in hierarchical order" do
      seed!()
      board = example_board!("design-led")

      assert Enum.map(board.stages, & &1.name) == [
               "Backlog",
               "Next up",
               "Design",
               "Design:Review",
               "Design:Done",
               "Plan",
               "Plan:Review",
               "Plan:Done",
               "Code",
               "Review",
               "Deploy",
               "Done"
             ]
    end
  end

  describe "Accounts" do
    # Scenario 11
    test "get_user_by_email/1 matches case-insensitively" do
      user = insert(:user, email: "Ada@Example.com")

      assert Accounts.get_user_by_email("ada@example.com").id == user.id
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end
  end
end
