defmodule Relay.MarkdownTest do
  use ExUnit.Case, async: true

  alias Relay.Markdown

  describe "to_html/1" do
    test "renders bold markdown to a <strong> element" do
      {:safe, html} = Markdown.to_html("**bold**")
      assert html =~ "<strong>bold</strong>"
    end

    test "renders a heading and a list" do
      {:safe, html} = Markdown.to_html("# Title\n\n- one\n- two")
      assert html =~ "<h1>Title</h1>"
      assert html =~ "<li>one</li>"
    end

    test "nil renders to an empty safe string" do
      assert Markdown.to_html(nil) == {:safe, ""}
    end

    test "always returns a Phoenix.HTML safe value" do
      assert {:safe, _} = Markdown.to_html("plain text")
    end

    test "strips a raw <script> tag and its content (XSS guard)" do
      {:safe, html} = Markdown.to_html("hello <script>alert('xss')</script> world")
      refute html =~ "<script"
      refute html =~ "alert('xss')"
      assert html =~ "hello"
    end
  end
end
