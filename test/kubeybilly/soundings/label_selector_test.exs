defmodule Kubeybilly.Soundings.LabelSelectorTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Soundings.LabelSelector

  describe "from_match_labels/1" do
    test "renders labels sorted and comma separated" do
      assert LabelSelector.from_match_labels(%{"tier" => "web", "app" => "shop"}) ==
               "app=shop,tier=web"
    end

    test "is nil for empty or missing labels" do
      assert LabelSelector.from_match_labels(%{}) == nil
      assert LabelSelector.from_match_labels(nil) == nil
    end
  end

  describe "workload_selector/1" do
    test "reads the matchLabels of a workload" do
      workload = %{"spec" => %{"selector" => %{"matchLabels" => %{"app" => "web"}}}}

      assert LabelSelector.workload_selector(workload) == "app=web"
    end

    test "is nil when the workload has no selector" do
      assert LabelSelector.workload_selector(%{"spec" => %{}}) == nil
    end
  end

  describe "selects?/2" do
    test "true when every selector label matches" do
      assert LabelSelector.selects?(%{"app" => "web"}, %{"app" => "web", "tier" => "frontend"})
    end

    test "false on mismatch or empty selector" do
      refute LabelSelector.selects?(%{"app" => "other"}, %{"app" => "web"})
      refute LabelSelector.selects?(%{}, %{"app" => "web"})
      refute LabelSelector.selects?(nil, %{"app" => "web"})
    end
  end
end
