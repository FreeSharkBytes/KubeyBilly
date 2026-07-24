defmodule KubeybillyWeb.FormatTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Incident.Record
  alias KubeybillyWeb.Format

  @workload %{kind: "Deployment", name: "checkout", uid: "uid-1"}

  defp record(fields \\ %{}) do
    Record.new(
      Map.merge(
        %{
          id: "20260724T010000Z-aaaa1111",
          group_key: "gk",
          namespace: "demo",
          workload: @workload
        },
        fields
      )
    )
  end

  describe "field/2" do
    test "reads string keys, as deserialized records carry" do
      assert Format.field(%{"name" => "crashloop"}, :name) == "crashloop"
    end

    test "reads atom keys, as live structs carry" do
      assert Format.field(%{name: "crashloop"}, :name) == "crashloop"
    end

    test "nil container is nil" do
      assert Format.field(nil, :name) == nil
    end

    test "missing key is nil" do
      assert Format.field(%{"other" => 1}, :name) == nil
    end
  end

  describe "workload/1" do
    test "kind and namespaced name" do
      assert Format.workload(record()) == "Deployment demo/checkout"
    end

    test "tolerates a record without a workload" do
      assert Format.workload(record(%{workload: %{kind: nil, name: nil, uid: nil}})) ==
               "unknown workload"
    end
  end

  describe "stamp/1" do
    test "UTC timestamps render sortable" do
      assert Format.stamp(~U[2026-07-24 03:15:00Z]) == "2026-07-24 03:15:00Z"
    end

    test "nil renders as a dash" do
      assert Format.stamp(nil) == "-"
    end
  end

  describe "label/1" do
    test "atoms render as their name" do
      assert Format.label(:awaiting_approval) == "awaiting_approval"
    end

    test "nil renders as a dash" do
      assert Format.label(nil) == "-"
    end

    test "strings pass through" do
      assert Format.label("recovered") == "recovered"
    end
  end

  describe "detail/1" do
    test "maps render as compact JSON" do
      assert Format.detail(%{"reason" => "oom"}) == ~s({"reason":"oom"})
    end

    test "empty detail renders empty" do
      assert Format.detail(%{}) == ""
      assert Format.detail(nil) == ""
    end

    test "unencodable detail falls back to inspect" do
      assert Format.detail({:a, 1}) == "{:a, 1}"
    end
  end

  describe "bytes/1" do
    test "small sizes stay in bytes" do
      assert Format.bytes(512) == "512 B"
    end

    test "kilobytes round to one decimal" do
      assert Format.bytes(1536) == "1.5 KB"
    end

    test "megabytes round to one decimal" do
      assert Format.bytes(2_621_440) == "2.5 MB"
    end
  end
end
