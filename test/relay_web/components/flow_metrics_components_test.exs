defmodule RelayWeb.FlowMetricsComponentsTest do
  @moduledoc """
  RE235: `verdict_bar/1` labels the same bar in two units. `:distribution` (flow scope) reads
  percentages; `:actual` (one card) reads raw counts, because "100% ok" over a single
  execution is the percentile mistake this card fixes.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.FlowMetricsComponents

  defp split(ok, needs, fail) do
    total = ok + needs + fail

    %{
      ok: ok,
      needs: needs,
      fail: fail,
      total: total,
      ok_pct: round(ok * 100 / total),
      needs_pct: round(needs * 100 / total),
      fail_pct: round(fail * 100 / total)
    }
  end

  defp bar(attrs) do
    render_component(&FlowMetricsComponents.verdict_bar/1, attrs)
  end

  test "defaults to :distribution and is byte-for-byte the pre-RE235 label" do
    html = bar(%{id: "vb", split: split(4, 0, 1)})

    assert html =~ "80% ok · 20% fail"
    assert html =~ ~s(title="80% succeeded · 0% needs input · 20% failed")
  end

  test ":distribution suppresses the fail tail at zero failures" do
    html = bar(%{id: "vb", split: split(3, 0, 0)})

    # the title tooltip always spells out "0% failed", so scope the "no fail tail" check to the
    # visible label span rather than the whole fragment (the title's wording is asserted below).
    assert html =~ ~r/>\s*100% ok\s*<\/span>/
  end

  test ":actual labels raw counts, singular case included" do
    assert bar(%{id: "vb", split: split(1, 0, 0), mode: :actual}) =~ "1 ok"
    assert bar(%{id: "vb", split: split(2, 0, 1), mode: :actual}) =~ "2 ok · 1 fail"
  end

  test ":actual suppresses the fail tail at zero failures and swaps the tooltip" do
    html = bar(%{id: "vb", split: split(2, 1, 0), mode: :actual})

    # same scoping as above: the label span omits the fail tail, independent of the title's wording.
    assert html =~ ~r/>\s*2 ok\s*<\/span>/
    assert html =~ ~s(title="2 succeeded · 1 needs input · 0 failed")
  end

  test "the bar geometry stays proportional in both modes" do
    for mode <- [:distribution, :actual] do
      html = bar(%{id: "vb", split: split(2, 0, 2), mode: mode})
      assert html =~ "width:50%;background:var(--color-success)"
      assert html =~ "width:50%;background:var(--color-error)"
    end
  end
end
