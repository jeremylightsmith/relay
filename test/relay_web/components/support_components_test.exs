defmodule RelayWeb.SupportComponentsTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RelayWeb.CoreComponents

  describe "support_badge/1" do
    test "pill variant, voted: violet fill + white text + arrow and count" do
      html = render_component(&support_badge/1, %{count: 12, voted: true, variant: :pill})
      assert html =~ "oklch(0.60 0.14 250)"
      assert html =~ "↑"
      assert html =~ "12"
    end

    test "pill variant, not voted: outlined violet" do
      html = render_component(&support_badge/1, %{count: 3, voted: false, variant: :pill})
      assert html =~ "oklch(0.48 0.10 250)"
      assert html =~ "1px solid oklch(0.86 0.05 250)"
    end

    test "count variant: muted internal card-face label" do
      html = render_component(&support_badge/1, %{count: 7, variant: :count})
      assert html =~ "oklch(0.56 0.02 255)"
      assert html =~ ~s(title="Public supporters")
      assert html =~ "↑"
      assert html =~ "7"
    end
  end

  describe "supporters_row/1" do
    test "renders faces, the count label, and a +more line when total exceeds shown" do
      supporters = [%{name: "Maya L.", email: "maya@example.com"}, %{name: "Dana K.", email: "dana@example.com"}]
      html = render_component(&supporters_row/1, %{supporters: supporters, total: 5})
      assert html =~ "5 supporters"
      assert html =~ "+ 3 more"
      assert html =~ "ML"
    end

    test "singular label and no +more when total == shown" do
      html = render_component(&supporters_row/1, %{supporters: [%{name: "Sam Y.", email: "s@example.com"}], total: 1})
      assert html =~ "1 supporter"
      refute html =~ "more"
    end
  end
end
