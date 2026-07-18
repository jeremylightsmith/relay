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

  def membership_factory do
    %Schemas.Membership{
      email: sequence(:membership_email, &"member#{&1}@example.com"),
      board: build(:board),
      user: build(:user)
    }
  end

  def device_token_factory do
    %Schemas.DeviceToken{
      token: sequence(:device_token, &"apns-device-token-#{&1}"),
      platform: :ios,
      last_registered_at: DateTime.truncate(DateTime.utc_now(), :second),
      user: build(:user)
    }
  end

  # A persisted key whose raw token is intentionally unknown — use
  # Relay.ApiKeys.create_key/2 in tests that need the raw secret.
  def api_key_factory do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %Schemas.ApiKey{
      name: "Board API key",
      token_prefix: sequence(:token_prefix, &String.pad_leading("#{&1}", 12, "0")),
      token_hash: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
      last_four: String.slice(secret, -4, 4),
      board: build(:board),
      created_by: build(:user)
    }
  end

  # A persisted user token whose raw token is intentionally unknown — use
  # Relay.Accounts.create_user_api_token/2 in tests that need the raw secret.
  def user_api_token_factory do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %Schemas.UserApiToken{
      context: "mobile",
      token_prefix: sequence(:user_token_prefix, &String.pad_leading("#{&1}", 12, "0")),
      token_hash: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
      last_four: String.slice(secret, -4, 4),
      user: build(:user)
    }
  end

  def stage_factory do
    %Schemas.Stage{
      name: sequence(:stage_name, &"Stage #{&1}"),
      position: sequence(:stage_position, & &1),
      category: :unstarted,
      type: :queue,
      ai_enabled: false,
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

  # Full-control factory: `board` (when overridden) must be persisted. Trigger stage ids and
  # `enabled` are set explicitly by the caller.
  def flow_factory(attrs) do
    {board, attrs} = Map.pop_lazy(attrs, :board, fn -> insert(:board) end)

    flow = %Schemas.Flow{
      board_id: board.id,
      key: sequence(:flow_key, &"flow-#{&1}"),
      enabled: false,
      isolation: :shared_clean,
      nodes: [],
      edges: []
    }

    flow |> merge_attributes(attrs) |> evaluate_lazy_attributes()
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
  def sub_task_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)

    sub_task = %Schemas.SubTask{
      card_id: card.id,
      title: sequence(:sub_task_title, &"Sub-task #{&1}"),
      done: false,
      position: sequence(:sub_task_position, & &1)
    }

    sub_task |> merge_attributes(attrs) |> evaluate_lazy_attributes()
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

  # Full-control factory: `card` (when overridden) must be a persisted card.
  def run_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)

    run = %Schemas.Run{
      card_id: card.id,
      flow_key: "code",
      status: :running,
      current_node: "implement",
      started_at: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -300, :second)
    }

    run |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  # Full-control factory: `run` (when overridden) must be a persisted run.
  # `:node` and `:duration_s` are convenience params, not schema fields —
  # `:node` maps onto `Schemas.NodeExecution`'s `node_key`, and `:duration_s`
  # derives `started_at`/`finished_at` (the schema has no stored duration
  # column; the read side sums the timestamp gap instead).
  def node_execution_factory(attrs) do
    {run, attrs} = Map.pop_lazy(attrs, :run, fn -> insert(:run) end)
    {node_key, attrs} = pop_first(attrs, [:node_key, :node], "implement")
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)

    started_at = DateTime.truncate(DateTime.utc_now(), :second)
    finished_at = duration_s && DateTime.add(started_at, duration_s, :second)

    node_execution = %Schemas.NodeExecution{
      run_id: run.id,
      node_key: node_key,
      visit: 1,
      attempt: 1,
      outcome: :succeeded,
      started_at: started_at,
      finished_at: finished_at
    }

    node_execution |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  defp pop_first(attrs, [], default), do: {default, attrs}

  defp pop_first(attrs, [key | rest], default) do
    if Map.has_key?(attrs, key) do
      Map.pop(attrs, key)
    else
      pop_first(attrs, rest, default)
    end
  end

  # Full-control factory: `card` (when overridden) must be a persisted card.
  # Metadata only — no bytes are written to storage by the factory.
  def attachment_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)

    attachment = %Schemas.Attachment{
      card_id: card.id,
      filename: sequence(:attachment_filename, &"shot-#{&1}.png"),
      content_type: "image/png",
      byte_size: 1024,
      storage_key: Ecto.UUID.generate()
    }

    attachment |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end
end
