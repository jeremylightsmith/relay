defmodule Hamaca.CardsMockupsTest do
  @moduledoc """
  RE370 — a card's `mockups`: a REPLACE-only list of HTML (or, RE390, image) attachments on the same card, each with
  an optional caption. Validated on write so the drawer and the viewer only ever frame this
  card's own attachments.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Attachments
  alias Hamaca.Cards
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

  test "an image attachment on this card is a mockup (RE390)", %{card: card} do
    url = upload(card, "shot.png", "image/png")

    assert {:ok, %Card{mockups: mockups}} = Cards.set_mockups(card, [%{"url" => url, "caption" => "Empty state"}])
    assert mockups == [%{"url" => url, "caption" => "Empty state"}]
  end

  test "an empty list clears to nil", %{card: card} do
    {:ok, card} = Cards.set_mockups(card, [%{"url" => upload(card, "a.html")}])
    assert {:ok, %Card{mockups: nil}} = Cards.set_mockups(card, [])
  end

  test "broadcasts the upsert so an open drawer updates live", %{card: card} do
    Hamaca.Events.subscribe(card.board_id)
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
      assert message =~ "HTML or image attachment on this card"
      assert message =~ "upload it with `hamaca mockups`"
      refute message =~ "relay mockups"
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "an image attachment on ANOTHER card (RE390)", %{card: card, stage: stage} do
      other = insert(:card, stage: stage)
      url = upload(other, "theirs.png", "image/png")

      assert {:error, {:invalid_mockups, message}} = Cards.set_mockups(card, [%{"url" => url}])
      assert message =~ "mockups[0]"
      assert message =~ "HTML or image attachment on this card"
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "a url that is not an attachment path", %{card: card} do
      for url <- ["https://example.com/mock.html", "/attachments/not-a-uuid", "/images/logo.png", nil] do
        assert {:error, {:invalid_mockups, message}} = Cards.set_mockups(card, [%{"url" => url}])
        assert message =~ "/attachments/"
        assert message =~ "upload the file with `hamaca mockups`"
        refute message =~ "relay mockups"
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

  # RE499 — append and remove one mockup without re-sending the list, atomically under a lock
  # on the card row (so a stale %Card{} never clobbers a concurrent write).
  describe "append_mockups/2" do
    setup %{card: card} do
      {:ok, a: upload(card, "a.html"), b: upload(card, "b.html"), c: upload(card, "c.html")}
    end

    test "appends after the existing entries", %{card: card, a: a, b: b, c: c} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a, "caption" => "One"}, %{"url" => b, "caption" => "Two"}])

      expected = [
        %{"url" => a, "caption" => "One"},
        %{"url" => b, "caption" => "Two"},
        %{"url" => c, "caption" => "Three"}
      ]

      assert {:ok, %Card{mockups: ^expected}} = Cards.append_mockups(card, [%{"url" => c, "caption" => "Three"}])
      assert Repo.get!(Card, card.id).mockups == expected
    end

    test "onto no mockups, in request order, a blank caption is nil", %{card: card, a: a, b: b} do
      assert {:ok, %Card{mockups: mockups}} =
               Cards.append_mockups(card, [%{"url" => a}, %{"url" => b, "caption" => "  "}])

      assert mockups == [%{"url" => a, "caption" => nil}, %{"url" => b, "caption" => nil}]
    end

    test "a stale struct re-reads the locked row and does not clobber", %{card: stale, a: a, b: b} do
      assert stale.mockups == nil
      {:ok, _card} = Cards.append_mockups(stale, [%{"url" => a}])
      {:ok, _card} = Cards.append_mockups(stale, [%{"url" => b}])

      assert Repo.get!(Card, stale.id).mockups == [%{"url" => a, "caption" => nil}, %{"url" => b, "caption" => nil}]
    end

    test "an attachment already in the list is refused", %{card: card, a: a} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a}])

      assert {:error, {:invalid_mockups, message}} = Cards.append_mockups(card, [%{"url" => a}])
      assert message =~ "mockups[0]"
      assert message =~ a
      assert Repo.get!(Card, card.id).mockups == [%{"url" => a, "caption" => nil}]
    end

    test "the same attachment twice in one request names the later index", %{card: card, b: b} do
      assert {:error, {:invalid_mockups, message}} = Cards.append_mockups(card, [%{"url" => b}, %{"url" => b}])
      assert message =~ "mockups[1]"
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "an HTML attachment on ANOTHER card is refused", %{card: card, stage: stage, a: a} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a}])
      theirs = upload(insert(:card, stage: stage), "theirs.html")

      assert {:error, {:invalid_mockups, message}} = Cards.append_mockups(card, [%{"url" => theirs}])
      assert message =~ "mockups[0]"
      assert message =~ "attachment on this card"
      assert Repo.get!(Card, card.id).mockups == [%{"url" => a, "caption" => nil}]
    end

    test "an unknown key is refused with set_mockups/2's message", %{card: card, a: a, b: b} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a}])

      assert {:error, {:invalid_mockups, message}} = Cards.append_mockups(card, [%{"url" => b, "image" => "x"}])
      assert message =~ ~s(unknown key "image")
      assert Repo.get!(Card, card.id).mockups == [%{"url" => a, "caption" => nil}]
    end

    test "nothing to add is refused", %{card: card} do
      assert {:error, {:invalid_mockups, _message}} = Cards.append_mockups(card, [])
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "an append and a remove each broadcast the upsert", %{card: card, a: a} do
      Hamaca.Events.subscribe(card.board_id)
      card_id = card.id
      {:ok, a_id} = Attachment.id_from_path(a)

      {:ok, card} = Cards.append_mockups(card, [%{"url" => a}])
      assert_receive {:card_upserted, %Card{id: ^card_id, mockups: [_]}}

      {:ok, _card} = Cards.remove_mockup(card, a_id)
      assert_receive {:card_upserted, %Card{id: ^card_id, mockups: nil}}
    end
  end

  describe "remove_mockup/2" do
    setup %{card: card} do
      a = upload(card, "a.html")
      b = upload(card, "b.html")
      c = upload(card, "c.html")
      ids = for url <- [a, b, c], do: url |> Attachment.id_from_path() |> elem(1)
      [a_id, b_id, c_id] = ids
      {:ok, a: a, b: b, c: c, a_id: a_id, b_id: b_id, c_id: c_id}
    end

    test "unlists one entry; the attachment stays in storage", %{card: card, a: a, b: b, c: c, b_id: b_id} do
      {:ok, card} =
        Cards.set_mockups(card, [
          %{"url" => a, "caption" => "One"},
          %{"url" => b, "caption" => "Two"},
          %{"url" => c, "caption" => "Three"}
        ])

      expected = [%{"url" => a, "caption" => "One"}, %{"url" => c, "caption" => "Three"}]
      assert {:ok, %Card{mockups: ^expected}} = Cards.remove_mockup(card, b_id)
      assert Repo.get!(Card, card.id).mockups == expected
      assert %Attachment{} = Attachments.get_attachment(b_id)
    end

    test "removing the last entry stores nil", %{card: card, a: a, a_id: a_id} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a}])

      assert {:ok, %Card{mockups: nil}} = Cards.remove_mockup(card, a_id)
      assert Repo.get!(Card, card.id).mockups == nil
    end

    test "an id not in the list, or not a uuid, is not_found", %{card: card, a: a} do
      {:ok, card} = Cards.set_mockups(card, [%{"url" => a}])

      assert {:error, :not_found} = Cards.remove_mockup(card, Ecto.UUID.generate())
      assert {:error, :not_found} = Cards.remove_mockup(card, "not-a-uuid")
      assert Repo.get!(Card, card.id).mockups == [%{"url" => a, "caption" => nil}]
    end

    test "a stale struct re-reads the locked row", %{card: card, a: a, b: b, c: c, a_id: a_id} do
      {:ok, stale} = Cards.set_mockups(card, [%{"url" => a}, %{"url" => b}])
      {:ok, _fresh} = Cards.append_mockups(Repo.get!(Card, card.id), [%{"url" => c}])

      {:ok, _card} = Cards.remove_mockup(stale, a_id)
      assert Repo.get!(Card, card.id).mockups == [%{"url" => b, "caption" => nil}, %{"url" => c, "caption" => nil}]
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
