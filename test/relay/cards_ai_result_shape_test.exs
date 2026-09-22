defmodule Relay.CardsAiResultShapeTest do
  @moduledoc """
  The `ai_result` blob has exactly one documented shape (relay.md § "The AI result blob"),
  and the drawer reads exactly those keys. Agents that invented their own spelling —
  `screens[].image`, `screens[].shot`, a `deploy_url` — uploaded the screenshots fine and
  then rendered nothing, silently, for a whole card. `update_ai_result/2` refuses an
  unrecognised shape so the agent that wrote it finds out at the write, not a human days later.
  """
  use Relay.DataCase, async: true

  alias Relay.Cards

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board, name: "Code", type: :work, position: 1)
    %{card: insert(:card, stage: stage)}
  end

  defp refusal(card, blob) do
    assert {:error, {:invalid_ai_result, message}} = Cards.update_ai_result(card, blob)
    message
  end

  test "the documented shape is accepted whole", %{card: card} do
    blob = %{
      "summary" => "- **One door** for everyone",
      "changes" => ["Adds a summary to the card drawer"],
      "screens" => [%{"url" => "/attachments/#{Ecto.UUID.generate()}", "caption" => "The door"}]
    }

    assert {:ok, card} = Cards.update_ai_result(card, blob)
    assert card.ai_result == blob
  end

  test "an empty blob is accepted — the writes contract, not the shape, is what requires content",
       %{card: card} do
    assert {:ok, card} = Cards.update_ai_result(card, %{})
    assert card.ai_result == %{}
  end

  test "a caption is optional and a screen may carry only its url", %{card: card} do
    assert {:ok, _card} =
             Cards.update_ai_result(card, %{"screens" => [%{"url" => "https://example.com/a.png"}]})
  end

  test "an unknown top-level key names itself and the keys that exist", %{card: card} do
    message = refusal(card, %{"summary" => "ok", "deploy_url" => "https://staging.example.com"})

    assert message =~ ~s("deploy_url")
    assert message =~ ~s("summary")
    assert message =~ ~s("changes")
    assert message =~ ~s("screens")
  end

  test "summary must be a string", %{card: card} do
    assert refusal(card, %{"summary" => ["a", "b"]}) =~ ~s("summary")
  end

  test "changes must be a list of strings", %{card: card} do
    assert refusal(card, %{"changes" => "Adds a thing"}) =~ ~s("changes")
    assert refusal(card, %{"changes" => [%{"change" => "Adds a thing", "file" => "x.ex"}]}) =~ ~s("changes")
  end

  test "screens must be a list of objects", %{card: card} do
    assert refusal(card, %{"screens" => "/attachments/one.png"}) =~ ~s("screens")
    assert refusal(card, %{"screens" => ["tmp/smoke/12-review.png"]}) =~ "screens[0]"
  end

  test "a screen key the drawer never reads is refused, named, with the two it does read",
       %{card: card} do
    # TH153 verbatim: the screenshot went into `image`, and `url` carried the deployed page,
    # so the drawer drew twelve broken images pointed at an HTML document.
    screen = %{
      "name" => "Sign in · the door",
      "caption" => "One email field",
      "image" => "/attachments/#{Ecto.UUID.generate()}",
      "url" => "https://staging.throughway.app/login"
    }

    message = refusal(card, %{"screens" => [screen]})

    assert message =~ "screens[0]"
    assert message =~ ~s("image")
    assert message =~ ~s("name")
    assert message =~ ~s("url")
    assert message =~ ~s("caption")
  end

  test "a screen without a url is refused — it would render as a blank placeholder", %{card: card} do
    assert refusal(card, %{"screens" => [%{"caption" => "The door"}]}) =~ ~s("url")
  end

  test "a screen's url and caption must be strings", %{card: card} do
    assert refusal(card, %{"screens" => [%{"url" => 12}]}) =~ ~s("url")
    assert refusal(card, %{"screens" => [%{"url" => "/a.png", "caption" => %{"text" => "hi"}}]}) =~ ~s("caption")
  end

  test "the allowed key sets are readable, so the prompt and the validator can't drift" do
    assert Cards.ai_result_keys() == ~w(summary changes screens)
    assert Cards.ai_result_screen_keys() == ~w(url caption)
  end
end
