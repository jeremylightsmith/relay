defmodule Relay.CardsComposeAnswerTest do
  use Relay.DataCase, async: true

  alias Relay.Cards

  test "composes the numbered Q->A block the web stepper produces" do
    questions = [
      %{"prompt" => "Which region?", "options" => ["us", "eu"], "allow_text" => false},
      %{"prompt" => "Ship it?", "options" => [], "allow_text" => true}
    ]

    assert Cards.compose_answer(questions, %{0 => "eu", 1 => "yes"}) ==
             "1. Which region? → eu\n2. Ship it? → yes"
  end

  test "a skipped question composes an empty answer" do
    questions = [%{"prompt" => "Which region?", "options" => [], "allow_text" => true}]

    assert Cards.compose_answer(questions, %{}) == "1. Which region? → "
  end

  test "latest_questions returns the card's newest structured questions, else nil" do
    code = insert(:stage, type: :work, ai_enabled: true)
    card = insert(:card, stage: code, status: :working)

    refute Cards.latest_questions(card)

    {:ok, _} = Cards.request_input(card, "plain string question", :agent)
    refute Cards.latest_questions(card)

    {:ok, _} =
      Cards.request_input(card, [%{"prompt" => "Newest?", "options" => [], "allow_text" => true}], :agent)

    assert Cards.latest_questions(card) ==
             [%{"prompt" => "Newest?", "options" => [], "allow_text" => true}]
  end
end
