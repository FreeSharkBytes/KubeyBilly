defmodule Kubeybilly.Soundings.BundleWriterTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Soundings.Bundle
  alias Kubeybilly.Soundings.BundleWriter

  setup do
    root =
      Path.join(System.tmp_dir!(), "kubeybilly-bundles-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    bundle = Bundle.new("20260725T031500Z-a1b2c3d4", root: root)
    %{bundle: bundle, root: root}
  end

  defp read_manifest(bundle) do
    bundle |> Bundle.absolute(Bundle.manifest_path()) |> File.read!() |> Jason.decode!()
  end

  describe "start_link/1" do
    test "creates the incident directory with a manifest stub", %{bundle: bundle} do
      start_supervised!({BundleWriter, bundle: bundle})

      manifest = read_manifest(bundle)

      assert manifest["incident_id"] == bundle.incident_id
      assert manifest["complete"] == false
      assert manifest["files"] == []
      assert manifest["gaps"] == []
      assert {:ok, _at, 0} = DateTime.from_iso8601(manifest["captured_at"])
    end
  end

  describe "write_artifact/3" do
    test "writes the file and appends a hashed manifest entry", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle})
      content = ~s({"kind":"Pod"})
      path = Bundle.pod_spec_path("demo", "web-abc")

      assert :ok = BundleWriter.write_artifact(writer, path, content)

      assert File.read!(Bundle.absolute(bundle, path)) == content

      expected_sha =
        :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

      assert [entry] = read_manifest(bundle)["files"]
      assert entry["path"] == path
      assert entry["sha256"] == expected_sha
      assert entry["bytes"] == byte_size(content)
    end

    test "emits a telemetry event per artifact", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle})
      handler_id = "artifact-telemetry-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:kubeybilly, :soundings, :artifact],
        fn _event, measurements, metadata, pid ->
          send(pid, {:artifact, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok = BundleWriter.write_artifact(writer, "nodes/worker-1.json", "{}")

      assert_receive {:artifact, %{bytes: 2}, %{path: "nodes/worker-1.json", incident_id: id}}
      assert id == bundle.incident_id
    end
  end

  describe "failure branches" do
    test "an unwritable bundle directory refuses to start", %{root: root} do
      File.mkdir_p!(root)
      blocking_file = Path.join(root, "not-a-dir")
      File.write!(blocking_file, "in the way")

      bundle = Bundle.new("blocked/incident", root: blocking_file)

      Process.flag(:trap_exit, true)
      assert {:error, {:mkdir, _reason}} = BundleWriter.start_link(bundle: bundle)
    end

    test "a failed artifact write is reported and recorded as a gap", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle})

      # manifest.json exists as a file, so a path beneath it cannot be created.
      bad_path = "manifest.json/child.json"

      assert {:error, _reason} = BundleWriter.write_artifact(writer, bad_path, "{}")

      assert [%{"path" => ^bad_path}] = read_manifest(bundle)["gaps"]
    end
  end

  describe "record_gap/3" do
    test "records the failure without crashing the writer", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle})
      path = Bundle.pod_logs_previous_path("demo", "web-abc")

      assert :ok = BundleWriter.record_gap(writer, path, {:api, "NotFound", "no previous"})

      assert [gap] = read_manifest(bundle)["gaps"]
      assert gap["path"] == path
      assert gap["reason"] =~ "NotFound"
    end
  end

  describe "record_absence/3" do
    test "records the gap and waives the requirement", %{bundle: bundle} do
      path = Bundle.pod_logs_current_path("demo", "web-abc")

      writer =
        start_supervised!({BundleWriter, bundle: bundle, required: [path, "events/demo.json"]})

      :ok = BundleWriter.write_artifact(writer, "events/demo.json", "[]")

      assert :ok =
               BundleWriter.record_absence(
                 writer,
                 path,
                 {:api, "BadRequest", "container is waiting to start: ErrImageNeverPull"}
               )

      assert {:ok, manifest} = BundleWriter.seal(writer)
      assert manifest["complete"] == true
      assert [gap] = manifest["gaps"]
      assert gap["path"] == path
      assert gap["reason"] =~ "waiting to start"
    end
  end

  describe "seal/1" do
    test "is complete when every required artifact was written", %{bundle: bundle} do
      writer =
        start_supervised!({BundleWriter, bundle: bundle, required: ["events/demo.json"]})

      :ok = BundleWriter.write_artifact(writer, "events/demo.json", "[]")

      assert {:ok, manifest} = BundleWriter.seal(writer)
      assert manifest["complete"] == true
      assert manifest["gaps"] == []
      assert read_manifest(bundle)["complete"] == true
    end

    test "is incomplete when a required artifact is missing", %{bundle: bundle} do
      writer =
        start_supervised!(
          {BundleWriter, bundle: bundle, required: ["events/demo.json", "nodes/worker-1.json"]}
        )

      :ok = BundleWriter.write_artifact(writer, "events/demo.json", "[]")

      assert {:ok, manifest} = BundleWriter.seal(writer)
      assert manifest["complete"] == false
      assert [%{"path" => "nodes/worker-1.json"}] = manifest["gaps"]
    end

    test "an optional gap does not break completeness", %{bundle: bundle} do
      writer =
        start_supervised!({BundleWriter, bundle: bundle, required: ["events/demo.json"]})

      :ok = BundleWriter.write_artifact(writer, "events/demo.json", "[]")

      :ok =
        BundleWriter.record_gap(
          writer,
          Bundle.pod_logs_previous_path("demo", "web-abc"),
          {:api, "BadRequest", "no previous container"}
        )

      assert {:ok, manifest} = BundleWriter.seal(writer)
      assert manifest["complete"] == true
      assert [%{"path" => "pods/demo/web-abc/logs-previous.txt"}] = manifest["gaps"]
    end

    test "a gap on a required artifact makes the bundle incomplete", %{bundle: bundle} do
      writer =
        start_supervised!({BundleWriter, bundle: bundle, required: ["events/demo.json"]})

      :ok = BundleWriter.record_gap(writer, "events/demo.json", {:transport, :timeout})

      assert {:ok, manifest} = BundleWriter.seal(writer)
      assert manifest["complete"] == false
      assert [%{"path" => "events/demo.json"}] = manifest["gaps"]
    end

    test "seal is a barrier: no writes after, no double seal", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle})

      assert {:ok, _manifest} = BundleWriter.seal(writer)
      assert {:error, :sealed} = BundleWriter.write_artifact(writer, "events/demo.json", "[]")
      assert {:error, :sealed} = BundleWriter.record_gap(writer, "events/demo.json", :late)
      assert {:error, :already_sealed} = BundleWriter.seal(writer)
    end

    test "emits a telemetry event on seal", %{bundle: bundle} do
      writer = start_supervised!({BundleWriter, bundle: bundle, required: ["a.json"]})
      handler_id = "seal-telemetry-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:kubeybilly, :soundings, :seal],
        fn _event, measurements, metadata, pid -> send(pid, {:seal, measurements, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _manifest} = BundleWriter.seal(writer)

      assert_receive {:seal, %{files: 0, gaps: 1}, %{complete: false, incident_id: id}}
      assert id == bundle.incident_id
    end
  end
end
