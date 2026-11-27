defmodule HamacaWeb.ReportFlowTest do
  use ExUnit.Case, async: true

  alias HamacaWeb.ReportFlow

  describe "collapsed?/2" do
    test "is true for a reported id the visitor hasn't chosen to show, false otherwise" do
      assigns = %{reported_ids: MapSet.new([1, 2]), shown_reported_ids: MapSet.new([2])}

      assert ReportFlow.collapsed?(assigns, 1) == true
      assert ReportFlow.collapsed?(assigns, 2) == false
      assert ReportFlow.collapsed?(assigns, 3) == false
    end
  end
end
