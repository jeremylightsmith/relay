defmodule Relay.Factory do
  @moduledoc """
  ExMachina factories for tests. Boundary checks are disabled because
  this is test-only support code that may reach into any context.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use ExMachina.Ecto, repo: Relay.Repo

  def user_factory do
    %Relay.Accounts.User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: "Test User",
      avatar_url: "https://example.com/avatar.png",
      provider: "google",
      provider_uid: sequence(:provider_uid, &"google-uid-#{&1}")
    }
  end

  def board_factory do
    %Relay.Boards.Board{
      name: "My board",
      slug: sequence(:slug, &"board-#{&1}"),
      key: "RLY",
      owner: build(:user)
    }
  end

  def stage_factory do
    %Relay.Boards.Stage{
      name: sequence(:stage_name, &"Stage #{&1}"),
      position: sequence(:stage_position, & &1),
      category: :unstarted,
      owner: :human,
      board: build(:board)
    }
  end
end
