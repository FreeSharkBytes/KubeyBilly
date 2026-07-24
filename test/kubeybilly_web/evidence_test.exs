defmodule KubeybillyWeb.EvidenceTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias KubeybillyWeb.Evidence

  @moduletag :tmp_dir

  defp write_manifest!(dir, files) do
    File.mkdir_p!(dir)

    manifest = %{
      "incident_id" => "20260724T010000Z-aaaa1111",
      "complete" => true,
      "files" => files,
      "gaps" => []
    }

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
  end

  describe "files/1" do
    test "lists path and size from the manifest", %{tmp_dir: dir} do
      write_manifest!(dir, [
        %{"path" => "events/demo.json", "bytes" => 120, "sha256" => "aa"},
        %{"path" => "pods/demo/x/logs-current.txt", "bytes" => 2048, "sha256" => "bb"}
      ])

      assert {:ok, files} = Evidence.files(dir)

      assert files == [
               %{path: "events/demo.json", bytes: 120},
               %{path: "pods/demo/x/logs-current.txt", bytes: 2048}
             ]
    end

    test "a bundle without a manifest reports so", %{tmp_dir: dir} do
      assert {:error, :no_manifest} = Evidence.files(Path.join(dir, "nope"))
    end

    test "a corrupt manifest reports so", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.json"), "{broken")

      assert {:error, :invalid_manifest} = Evidence.files(dir)
    end
  end

  describe "read/2" do
    test "reads a text file inside the bundle", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "events"))
      File.write!(Path.join(dir, "events/demo.json"), ~s({"kind":"EventList"}))

      assert {:ok, ~s({"kind":"EventList"})} = Evidence.read(dir, "events/demo.json")
    end

    test "rejects any path containing dot-dot", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      assert {:error, :traversal} = Evidence.read(dir, "../outside.txt")
      assert {:error, :traversal} = Evidence.read(dir, "events/../../outside.txt")
      assert {:error, :traversal} = Evidence.read(dir, "..")
    end

    test "rejects absolute paths that resolve outside the bundle", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      outside = Path.join(Path.dirname(dir), "outside.txt")
      File.write!(outside, "secret")

      assert {:error, :traversal} = Evidence.read(dir, outside)
      assert {:error, :traversal} = Evidence.read(dir, "/etc/passwd")
    end

    test "a missing file is not found", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      assert {:error, :not_found} = Evidence.read(dir, "missing.txt")
    end

    test "caps content at 100KB", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "huge.txt"), String.duplicate("a", 100 * 1024 + 1))

      assert {:error, :too_large} = Evidence.read(dir, "huge.txt")
    end

    test "exactly 100KB still reads", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "full.txt"), String.duplicate("a", 100 * 1024))

      assert {:ok, content} = Evidence.read(dir, "full.txt")
      assert byte_size(content) == 100 * 1024
    end

    test "refuses binary content", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "blob.bin"), <<0xFF, 0xFE, 0x00, 0x01>>)

      assert {:error, :binary} = Evidence.read(dir, "blob.bin")
    end
  end

  describe "log_path/1" do
    test "returns the path when log.md exists", %{tmp_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "log.md"), "# Log entry")

      assert Evidence.log_present?(dir)
    end

    test "false when absent", %{tmp_dir: dir} do
      refute Evidence.log_present?(Path.join(dir, "nope"))
    end
  end
end
