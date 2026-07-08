defmodule Relay.Factory do
  @moduledoc """
  ExMachina factories for tests. Boundary checks are disabled because
  this is test-only support code that may reach into any context.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use ExMachina.Ecto, repo: Relay.Repo

  def user_factory do
    %Schemas.User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: "Test User",
      avatar_url: "https://example.com/avatar.png",
      provider: "google",
      provider_uid: sequence(:provider_uid, &"google-uid-#{&1}")
    }
  end

  def board_factory do
    %Schemas.Board{
      name: "My board",
      slug: sequence(:slug, &"board-#{&1}"),
      key: "RLY",
      owner: build(:user)
    }
  end

  def stage_factory do
    %Schemas.Stage{
      name: sequence(:stage_name, &"Stage #{&1}"),
      position: sequence(:stage_position, & &1),
      category: :unstarted,
      owner: :human,
      board: build(:board)
    }
  end

  # Full-control factory: `stage` (when overridden) must be a *persisted*
  # stage — the card's `stage_id`/`board_id` are derived from it so card and
  # stage always share a board. When no stage is given one is inserted, so
  # even `build(:card)` touches the database.
  def card_factory(attrs) do
    {stage, attrs} = Map.pop_lazy(attrs, :stage, fn -> insert(:stage) end)

    card = %Schemas.Card{
      title: sequence(:card_title, &"Card #{&1}"),
      tag: nil,
      position: sequence(:card_position, &(&1 + 1)),
      ref_number: sequence(:card_ref_number, &(&1 + 1)),
      stage_id: stage.id,
      board_id: stage.board_id
    }

    card |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, builds a human owner; without, the single AI agent owner.
  def card_owner_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    owner = %Schemas.CardOwner{
      card_id: card.id,
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id
    }

    owner |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, a human comment; without, an agent ("Relay AI") comment.
  def comment_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    comment = %Schemas.Comment{
      card_id: card.id,
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id,
      body: sequence(:comment_body, &"Comment #{&1}")
    }

    comment |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, a human actor; without, the agent. Defaults to a :moved
  # entry with a sample string-keyed meta.
  def activity_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    activity = %Schemas.Activity{
      card_id: card.id,
      type: :moved,
      meta: %{"from_stage" => "Spec", "to_stage" => "Code"},
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id
    }

    activity |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end
end
