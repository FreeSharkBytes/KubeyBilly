defmodule Kubeybilly.Alerts.TargetTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Alerts.Target

  defp group(alerts) do
    %{"groupKey" => "{}:{alertname=\"X\"}", "status" => "firing", "alerts" => alerts}
  end

  defp alert(labels), do: %{"labels" => labels}

  test "extracts identity from namespace and deployment labels" do
    assert {:ok, target} =
             Target.extract(
               group([
                 alert(%{
                   "namespace" => "demo",
                   "deployment" => "web",
                   "pod" => "web-9f8d7c6b5-aaaaa",
                   "node" => "worker-1"
                 })
               ])
             )

    assert target.group_key == "{}:{alertname=\"X\"}"
    assert target.namespace == "demo"
    assert target.workload == %{kind: "Deployment", name: "web", uid: "demo/Deployment/web"}
    assert target.pods == ["web-9f8d7c6b5-aaaaa"]
    assert target.nodes == ["worker-1"]
  end

  test "prefers an explicit workload uid label" do
    assert {:ok, target} =
             Target.extract(
               group([
                 alert(%{
                   "namespace" => "demo",
                   "deployment" => "web",
                   "workload_uid" => "abc-123"
                 })
               ])
             )

    assert target.workload.uid == "abc-123"
  end

  test "derives the owner from the pod name when no deployment label exists" do
    assert {:ok, target} =
             Target.extract(
               group([alert(%{"namespace" => "demo", "pod" => "galley-d7c6bc75c-drbdd"})])
             )

    assert target.workload == %{
             kind: "Deployment",
             name: "galley",
             uid: "demo/Deployment/galley"
           }
  end

  test "collects unique pods and nodes across the group's alerts" do
    assert {:ok, target} =
             Target.extract(
               group([
                 alert(%{"namespace" => "demo", "deployment" => "web", "pod" => "web-a-1"}),
                 alert(%{"namespace" => "demo", "deployment" => "web", "pod" => "web-a-2"}),
                 alert(%{"namespace" => "demo", "deployment" => "web", "pod" => "web-a-1"})
               ])
             )

    assert target.pods == ["web-a-1", "web-a-2"]
    assert target.nodes == []
  end

  test "a group without alerts cannot be targeted" do
    assert {:error, {:target, :no_alerts}} =
             Target.extract(%{"groupKey" => "gk", "status" => "firing", "alerts" => []})

    assert {:error, {:target, :no_alerts}} = Target.extract(%{"groupKey" => "gk"})
  end

  test "a group without a namespace cannot be targeted" do
    assert {:error, {:target, :no_namespace}} =
             Target.extract(group([alert(%{"pod" => "web-9f8d7c6b5-aaaaa"})]))
  end

  test "a group whose pod name carries no owner shape cannot be targeted" do
    assert {:error, {:target, :no_workload}} =
             Target.extract(group([alert(%{"namespace" => "demo", "pod" => "standalone"})]))
  end
end
