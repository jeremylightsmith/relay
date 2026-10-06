defmodule RelayWeb.FeedbackTest do
  use ExUnit.Case, async: true

  alias RelayWeb.Feedback

  @public_board "https://relayboard.fly.dev/board/relay/public"

  describe "normalize/1" do
    test "returns a non-blank URL unchanged" do
      assert Feedback.normalize(@public_board) == @public_board
    end

    test "returns nil for nil, empty and whitespace-only input" do
      for blank <- [nil, "", "   "] do
        assert Feedback.normalize(blank) == nil, "expected nil for #{inspect(blank)}"
      end
    end
  end

  describe "url/1" do
    test "an assigned :feedback_url wins" do
      assert Feedback.url(%{feedback_url: "https://example.com/ideas"}) == "https://example.com/ideas"
    end

    test "an explicit nil or blank :feedback_url key wins over config and returns nil" do
      assert Feedback.url(%{feedback_url: nil}) == nil
      assert Feedback.url(%{feedback_url: "  "}) == nil
    end

    test "with no :feedback_url key it falls back to config, which test leaves unset" do
      assert Feedback.url() == nil
      assert Feedback.url(%{}) == nil
    end
  end
end
