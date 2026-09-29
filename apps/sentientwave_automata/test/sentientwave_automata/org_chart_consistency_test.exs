defmodule SentientwaveAutomata.OrgChartConsistencyTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.OrgChart.Consistency

  describe "diff/2 (pure store-diff used by reconciliation)" do
    test "strays are active-in-matrix but not expected" do
      diff = Consistency.diff(["alice", "bob", "stray.gone"], ["alice", "bob"])
      assert "stray.gone" in diff.strays
      assert diff.missing == []
    end

    test "missing are expected but not active in matrix" do
      diff = Consistency.diff(["alice"], ["alice", "new.hire"])
      assert diff.strays == []
      assert diff.missing == ["new.hire"]
    end

    test "fully consistent stores produce empty diff" do
      both = ["alice", "bob", "carol"]
      diff = Consistency.diff(both, both)
      assert diff.strays == [] and diff.missing == []
    end
  end
end
