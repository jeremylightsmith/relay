defmodule Relay.CardsPublicIdeaTest do
  use Relay.DataCase, async: true

  import Ecto.Query
  import Relay.Factory

  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Votes
  alias Schemas.Card

  defp public_board(_ctx) do
    board = insert(:board)
    stage = insert(:stage, board: board, category: :unstarted, type: :queue, name: "Unstarted")
    # Set the intake stage programmatically for the test fixture.
    {:ok, board} =
      board
      |> Ecto.Changeset.change(public_enabled: true, public_intake_stage_id: stage.id)
      |> Repo.update()

    %{board: board, stage: stage}
  end

  # Insert a public post directly with a controlled inserted_at, for window tests.
  defp post_at(user, board, stage, seconds_ago) do
    card = insert(:card, stage: stage, board: board, posted_by_user_id: user.id)

    ago =
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

    {1, _} = Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [inserted_at: ago])
    card
  end

  describe "post_public_idea/3" do
    setup :public_board

    test "creates a card in the intake stage with the poster's first vote", %{board: board, stage: stage} do
      user = insert(:user)

      {:ok, card} =
        Cards.post_public_idea(board, user, %{
          "title" => "Dark mode",
          "public_description" => "A dim theme for night owls."
        })

      assert card.title == "Dark mode"
      assert card.public_description == "A dim theme for night owls."
      assert card.stage_id == stage.id
      assert card.posted_by_user_id == user.id
      assert Votes.count(card.id) == 1
      assert Votes.voted?(user, card)
    end

    test "blank public description stores nil", %{board: board} do
      user = insert(:user)
      {:ok, card} = Cards.post_public_idea(board, user, %{"title" => "Just a title", "public_description" => "  "})
      assert is_nil(card.public_description)
    end

    test "unset intake stage → {:error, :no_intake_stage}, no card created", %{board: board} do
      user = insert(:user)

      {:ok, board} =
        board |> Ecto.Changeset.change(public_intake_stage_id: nil) |> Repo.update()

      assert {:error, :no_intake_stage} = Cards.post_public_idea(board, user, %{"title" => "Nope"})
      assert Repo.aggregate(from(c in Card, where: c.posted_by_user_id == ^user.id), :count) == 0
    end

    test "blank title → {:error, changeset}, no card created", %{board: board} do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{} = cs} = Cards.post_public_idea(board, user, %{"title" => "   "})
      refute cs.valid?
      assert Repo.aggregate(from(c in Card, where: c.posted_by_user_id == ^user.id), :count) == 0
    end

    test "over the hourly cap → {:error, :rate_limited}", %{board: board} do
      user = insert(:user)
      # hour_max read from the single source of truth (AC #8), never a literal.
      [{_hour_window, hour_max} | _] = Cards.public_post_limits()

      for n <- 1..hour_max do
        assert {:ok, _} = Cards.post_public_idea(board, user, %{"title" => "Idea #{n}"})
      end

      assert {:error, :rate_limited} = Cards.post_public_idea(board, user, %{"title" => "One too many"})

      # No extra card beyond the cap.
      assert Repo.aggregate(from(c in Card, where: c.posted_by_user_id == ^user.id), :count) == hour_max
    end
  end

  describe "public_post_limits/0" do
    test "is the single source of truth for the caps" do
      assert Cards.public_post_limits() == [{3600, 5}, {86_400, 20}]
    end
  end

  describe "within_public_post_limit?/1" do
    setup :public_board

    test "counts only the user's own posts, respecting the hour window", %{board: board, stage: stage} do
      user = insert(:user)
      other = insert(:user)
      [{hour_window, hour_max}, {_day_window, _day_max}] = Cards.public_post_limits()

      # Another user's posts never count against this user.
      for _ <- 1..hour_max, do: post_at(other, board, stage, 10)
      assert Cards.within_public_post_limit?(user)

      # hour_max - 1 recent posts → still within.
      for _ <- 1..(hour_max - 1), do: post_at(user, board, stage, 10)
      assert Cards.within_public_post_limit?(user)

      # One more recent post reaches the cap → no longer within.
      post_at(user, board, stage, 10)
      refute Cards.within_public_post_limit?(user)

      # Posts older than the hour window don't count toward the hour cap: a fresh user
      # with hour_max posts all aged past the window is still within limit.
      fresh = insert(:user)
      for _ <- 1..hour_max, do: post_at(fresh, board, stage, hour_window + 60)
      assert Cards.within_public_post_limit?(fresh)
    end

    test "counts posts across all of the user's boards", %{board: board_a, stage: stage_a} do
      user = insert(:user)
      [{_hour_window, hour_max} | _] = Cards.public_post_limits()

      board_b = insert(:board)
      stage_b = insert(:stage, board: board_b, category: :unstarted, type: :queue)

      # Split the hourly cap across two boards; the count is global.
      for _ <- 1..(hour_max - 1), do: post_at(user, board_a, stage_a, 5)
      post_at(user, board_b, stage_b, 5)

      refute Cards.within_public_post_limit?(user)
    end
  end
end
