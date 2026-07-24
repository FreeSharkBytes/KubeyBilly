defmodule Kubeybilly.Soundings.BundleTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Soundings.Bundle

  describe "new/2 and directories" do
    test "roots the bundle in the configured incidents directory by default" do
      bundle = Bundle.new("20260725T031500Z-a1b2c3d4")

      assert bundle.incident_id == "20260725T031500Z-a1b2c3d4"
      assert bundle.root == "incidents"
      assert Bundle.dir(bundle) == Path.join("incidents", "20260725T031500Z-a1b2c3d4")
    end

    test "accepts a root override" do
      bundle = Bundle.new("id", root: "/tmp/incidents")

      assert Bundle.dir(bundle) == "/tmp/incidents/id"
    end

    test "absolute/2 joins a relative artifact path onto the bundle directory" do
      bundle = Bundle.new("id", root: "/tmp/incidents")

      assert Bundle.absolute(bundle, "manifest.json") == "/tmp/incidents/id/manifest.json"
    end
  end

  describe "artifact path layout per plan/06" do
    test "pod artifacts" do
      assert Bundle.pod_spec_path("demo", "web-abc") == "pods/demo/web-abc/spec.json"
      assert Bundle.pod_status_path("demo", "web-abc") == "pods/demo/web-abc/status.json"

      assert Bundle.pod_logs_current_path("demo", "web-abc") ==
               "pods/demo/web-abc/logs-current.txt"

      assert Bundle.pod_logs_previous_path("demo", "web-abc") ==
               "pods/demo/web-abc/logs-previous.txt"
    end

    test "namespace events" do
      assert Bundle.events_path("demo") == "events/demo.json"
    end

    test "owner and revision history" do
      assert Bundle.owner_path("demo", "web") == "owners/demo/web.json"
      assert Bundle.owner_revisions_path("demo", "web") == "owners/demo/web-revisions.json"
    end

    test "nodes, baseline, and manifest" do
      assert Bundle.node_path("worker-1") == "nodes/worker-1.json"
      assert Bundle.baseline_path() == "metrics/baseline.json"
      assert Bundle.manifest_path() == "manifest.json"
    end
  end

  describe "incident_id/2" do
    test "is sortable timestamp plus eight hex chars of the group key hash" do
      at = ~U[2026-07-25 03:15:00Z]
      id = Bundle.incident_id("{}/{alertname=\"OOMDemo\"}", at)

      assert ["20260725T031500Z", hash] = String.split(id, "-")
      assert hash =~ ~r/^[0-9a-f]{8}$/
    end

    test "is stable for the same group key and differs across keys" do
      at = ~U[2026-07-25 03:15:00Z]

      assert Bundle.incident_id("group-a", at) == Bundle.incident_id("group-a", at)
      refute Bundle.incident_id("group-a", at) == Bundle.incident_id("group-b", at)
    end
  end
end
