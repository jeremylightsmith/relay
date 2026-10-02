defmodule Relay.CardsMockupsTest do
  @moduledoc """
  RE370 — a card's `mockups`: a REPLACE-only list of HTML attachments on the same card, each with
  an optional caption. Validated on write so the drawer and the viewer only ever frame this
  card's own sandboxed HTML.
  """
  use Relay.DataCase, async: true

  alias Relay.Attachments
  alias Relay.Cards
  alias Schemas.Attachment
  alias Schemas.Card

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board)
    card = insert(:card, stage: stage)
    {:ok, board: board, stage: stage, card: card}
  end

  defp upload(card, filename, content_type \\ Attachment.html_type()) do
    {:ok, attachment} =
      Attachments.create_attachment(card, %{filename: filename, content_type: content_type, bytes: "<p>#{filename}</p>"})

    Attachment.path(attachment.id)
  end

  test "stores the entries in order, string-keyed, caption optional", %{card: card} do
    a = upload(card, "a.html")
    b = upload(card, "b.html")

    assert {:ok, %Card{mockups: mockups}} =
             Cards.set_mockups(card, [%{"url" => a, "caption" => "Empty state"}, %{"url" => b}])

    assert mockups == [%{"url" => a, "caption" => "Empty state"}, %{"url" => b, "caption" => nil}]
    assert Repo.get!(Card, card.id).mockups == mockups
  end

  test "a second set REPLACES the list; the old attachment stays in storage", %{card: card} do
    old = upload(card, "old.html")
    new = upload(card, "new.html")
    {:ok, card} = Cards.set_mockups(card, [%{"url" => old, "caption" => "Old"}])

    assert {:ok, %Card{mockups: [%{"url" => ^new, "caption" => "New"}]}} =
             Cards.set_mockups(card, [%{"url" => new, "caption" => "New"}])

    {:ok, old_id} = Attachment.id_from_path(old)
    assert %Attachment{} = Attachments.get_attachment(old_id)
  end

  test "an empty list clears to nil", %{card: card} do
    {:ok, card} = Cards.set_mockups(card, [%{"url" => upload(card, "a.html")}])
    assert {:ok, %Card{mockups: nil}} = Cards.set_mockups(card, [])
  end

  test "broadcasts the upsert so an open drawer updates live", %{card: card} do
    Relay.Events.subscribe(card.board_id)
    card_id = card.id
    {:ok, _card} = Cards.set_mockups(card, [%{"url" => upload(card, "a.html")}])

    assert_receive {:card_upserted, %Card{id: ^card_id, mockups: [_]}}
  end

  describe "refusals — nothing is written" do
    test "an HTML attachment on ANOTHER card", %{card: card, stage: stage} do
      other = insert(:card, stage: stage)
      url = upload(other, "theirs.html")

      assert {:error, {:invalid_mockups, message}} = Cards.set_mockups(card, [%{"url" => url}])
      assert message =~ "mockups[0]"
      assert message =~ "HTML attachment on this card"
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "a non-HTML attachment on this card", %{card: card} do
      url = upload(card, "shot.png", "image/png")

      assert {:error, {:invalid_mockups, message}} = Cards.set_mockups(card, [%{"url" => url}])
      assert message =~ "HTML attachment on this card"
    end

    test "a url that is not an attachment path", %{card: card} do
      for url <- ["https://example.com/mock.html", "/attachments/not-a-uuid", "/images/logo.png", nil] do
        assert {:error, {:invalid_mockups, message}} = Cards.set_mockups(card, [%{"url" => url}])
        assert message =~ "/attachments/"
      end
    end

    test "an unknown key, a non-string caption, a non-object entry", %{card: card} do
      url = upload(card, "a.html")

      assert {:error, {:invalid_mockups, unknown}} = Cards.set_mockups(card, [%{"url" => url, "image" => "x"}])
      assert unknown =~ ~s("image")
      assert unknown =~ ~s("url", "caption")

      assert {:error, {:invalid_mockups, caption}} = Cards.set_mockups(card, [%{"url" => url, "caption" => 3}])
      assert caption =~ ~s("caption" must be a string)

      assert {:error, {:invalid_mockups, entry}} = Cards.set_mockups(card, [url])
      assert entry =~ "mockups[0] must be an object"
    end

    test "the first bad entry is named by its index", %{card: card} do
      good = upload(card, "a.html")

      assert {:error, {:invalid_mockups, message}} =
               Cards.set_mockups(card, [%{"url" => good}, %{"url" => "https://example.com"}])

      assert message =~ "mockups[1]"
    end
  end

  describe "the writes contract (RE244)" do
    test ":mockups is a contract field, blank until set", %{card: card} do
      assert :mockups in Card.contract_fields()
      assert Cards.blank_contract_fields(card, [:mockups]) == [:mockups]

      {:ok, card} = Cards.set_mockups(card, [%{"url" => upload(card, "a.html")}])
      assert Cards.blank_contract_fields(card, [:mockups]) == []
    end
  end
end
