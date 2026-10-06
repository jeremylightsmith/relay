defmodule RelayWeb.CardMediaTest do
  @moduledoc """
  RE390 — the one item shape every Mockups / Screenshots tile and the viewer render, built from a
  card's `mockups` and its `ai_result["screens"]`. Pure functions over plain data: no DB.
  """
  use ExUnit.Case, async: true

  alias RelayWeb.CardMedia

  @types %{"a1" => "text/html", "a2" => "image/png"}

  describe "kind/2" do
    test "HTML only for an /attachments/<id> whose content type is HTML; everything else is an image" do
      assert CardMedia.kind("/attachments/a1", @types) == :html
      assert CardMedia.kind("/attachments/a2", @types) == :image
      assert CardMedia.kind("/attachments/zz", @types) == :image
      assert CardMedia.kind("https://x.test/a.html", @types) == :image
      assert CardMedia.kind("data:image/png;base64,AA", @types) == :image
      assert CardMedia.kind("/images/logo.png", @types) == :image
    end
  end

  describe "screens/2" do
    test "reads every entry shape, keys the fetchable ones 1, 2, … and placeholders the rest" do
      ai_result = %{
        "screens" => [
          %{"url" => "/attachments/a2", "caption" => "Board"},
          "tmp/smoke/12-review.png",
          %{"url" => "https://x.test/b.png"},
          42
        ]
      }

      assert CardMedia.screens(ai_result, @types) == [
               %{key: 1, src: "/attachments/a2", caption: "Board", kind: :image},
               %{key: nil, src: nil, caption: "12-review.png", kind: :placeholder},
               %{key: 2, src: "https://x.test/b.png", caption: nil, kind: :image},
               %{key: nil, src: nil, caption: "42", kind: :placeholder}
             ]

      assert CardMedia.screenshot_items(ai_result, @types) == [
               %{key: 1, src: "/attachments/a2", caption: "Board", kind: :image},
               %{key: 2, src: "https://x.test/b.png", caption: nil, kind: :image}
             ]
    end

    test "a malformed ai_result never raises" do
      assert CardMedia.screens(nil, @types) == []
      assert CardMedia.screens("oops", @types) == []

      assert CardMedia.screens(%{"screens" => "a string url"}, @types) == [
               %{key: nil, src: nil, caption: "a string url", kind: :placeholder}
             ]

      assert CardMedia.screens(%{"screens" => %{"url" => 1}}, @types) == [
               %{key: nil, src: nil, caption: "Screenshot", kind: :placeholder}
             ]
    end
  end

  describe "mockup_items/2" do
    test "one item per mockup entry, in order, drawn by content type" do
      mockups = [%{"url" => "/attachments/a1", "caption" => "Empty"}, %{"url" => "/attachments/a2"}]

      assert CardMedia.mockup_items(mockups, @types) == [
               %{key: "a1", src: "/attachments/a1", caption: "Empty", kind: :html},
               %{key: "a2", src: "/attachments/a2", caption: nil, kind: :image}
             ]
    end
  end

  describe "fetchable_url?/1 and ai_list/1" do
    test "fetchable_url? accepts what this browser can load and nothing else" do
      assert CardMedia.fetchable_url?("https://x.test/a.png")
      assert CardMedia.fetchable_url?("/images/logo.png")
      assert CardMedia.fetchable_url?("/attachments/a1")
      refute CardMedia.fetchable_url?("/Users/jeremy/tmp/a.png")
      refute CardMedia.fetchable_url?("tmp/a.png")
      refute CardMedia.fetchable_url?(nil)
    end

    test "ai_list coerces any value to a list" do
      assert CardMedia.ai_list([1]) == [1]
      assert CardMedia.ai_list(nil) == []
      assert CardMedia.ai_list("") == []
      assert CardMedia.ai_list("x") == ["x"]
    end
  end
end
