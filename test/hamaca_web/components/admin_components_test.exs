defmodule HamacaWeb.AdminComponentsTest do
  @moduledoc """
  RE475 — the Usage tab's reusable pieces in `HamacaWeb.AdminComponents`: the `usage_strip/1` day
  cells (card mockups "Usage tab — people (blue) + their agents (violet)" and "User panel —
  visits, time, agent runs, shipped"), the `stacked_bars/1` people/agents chart, and the
  `user_tabs/1` bar gaining the Usage tab.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HamacaWeb.AdminComponents

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
  defp attrs(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "usage_strip/1" do
    test ":sm renders one small cell per day state, colored by state (scenario 13)" do
      doc =
        doc(render_component(&AdminComponents.usage_strip/1, days: [:none, :human, :agent, :both], size: :sm))

      assert count(doc, "div.flex.gap-\\[3px\\].items-center") == 1
      assert count(doc, "div.flex.gap-\\[3px\\].items-center > span.h-4.w-2\\.5.rounded-sm") == 4

      assert attrs(doc, "div.flex.gap-\\[3px\\].items-center > span", "data-state") ==
               ["none", "human", "agent", "both"]

      assert count(doc, ~s(span[data-state="none"].bg-base-300)) == 1
      assert count(doc, ~s(span[data-state="human"].bg-primary)) == 1
      assert count(doc, ~s(span[data-state="agent"].bg-secondary)) == 1

      both = ~s(span[data-state="both"].overflow-hidden.flex.flex-col)
      assert count(doc, both) == 1
      assert count(doc, "#{both} > span.flex-1") == 2
      assert count(doc, "#{both} > span.flex-1.bg-primary:first-child") == 1
      assert count(doc, "#{both} > span.flex-1.bg-secondary:last-child") == 1
    end

    test ":lg renders tall flexible cells in a wider-gapped row (scenario 13)" do
      doc =
        doc(render_component(&AdminComponents.usage_strip/1, days: [:none, :human, :agent, :both], size: :lg))

      assert count(doc, "div.flex.gap-1\\.5.items-center > span.h-10.flex-1.rounded-md[data-state]") == 4
      assert count(doc, "span.h-4") == 0
    end

    test "carries an optional id on the row" do
      doc = doc(render_component(&AdminComponents.usage_strip/1, days: [:none], id: "strip-x"))

      assert count(doc, "div#strip-x.flex") == 1
    end
  end

  describe "stacked_bars/1" do
    test "scales each segment to the series' busiest day, agents above people (scenario 14)" do
      series = [
        %{date: ~D[2026-10-24], people: 1, agents: 1},
        %{date: ~D[2026-10-25], people: 2, agents: 0}
      ]

      doc = doc(render_component(&AdminComponents.stacked_bars/1, series: series, id: "c"))

      assert count(doc, "div.mt-4.flex.h-40.items-end.gap-1.border-b.border-base-300") == 1

      bar = "#c-bar-2026-10-24.flex-1.flex.flex-col.justify-end.h-full.gap-px"
      assert count(doc, bar) == 1
      assert attrs(doc, "#c-bar-2026-10-24", "data-people") == ["1"]
      assert attrs(doc, "#c-bar-2026-10-24", "data-agents") == ["1"]
      assert attrs(doc, "#c-bar-2026-10-24 > div.bg-secondary.rounded-t-sm:first-child", "style") == ["height:50%"]
      assert attrs(doc, "#c-bar-2026-10-24 > div.bg-primary:last-child", "style") == ["height:50%"]

      assert attrs(doc, "#c-bar-2026-10-25", "data-people") == ["2"]
      assert attrs(doc, "#c-bar-2026-10-25", "data-agents") == ["0"]
      assert attrs(doc, "#c-bar-2026-10-25 > div.bg-primary", "style") == ["height:100%"]
      assert attrs(doc, "#c-bar-2026-10-25 > div.bg-secondary", "style") == ["height:0%"]
    end

    test "an all-zero series renders every segment at 0% (scenario 14)" do
      series = [%{date: ~D[2026-10-24], people: 0, agents: 0}, %{date: ~D[2026-10-25], people: 0, agents: 0}]

      doc = doc(render_component(&AdminComponents.stacked_bars/1, series: series, id: "z"))

      assert attrs(doc, "[id^=z-bar-] > div", "style") == List.duplicate("height:0%", 4)
    end
  end

  describe "user_tabs/1" do
    test "renders Users, Usage, Promo codes, Renewals with only Usage active (scenario 15)" do
      doc = doc(render_component(&AdminComponents.user_tabs/1, active: :usage))

      assert doc |> LazyHTML.query(~s(a[role="tab"])) |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
               ["Users", "Usage", "Promo codes", "Renewals"]

      assert attrs(doc, ".tab-active", "id") == ["admin-tab-usage"]
      assert attrs(doc, "#admin-tab-usage", "href") == ["/admin/users/usage"]
    end
  end
end
