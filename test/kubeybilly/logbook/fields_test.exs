defmodule Kubeybilly.Logbook.FieldsTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Logbook.Fields
  alias Kubeybilly.Signatures.Signature

  describe "get/2" do
    test "reads a struct field" do
      signature =
        Signature.new(%{
          name: :oomkilled,
          confidence: 0.8,
          proposed_action: %{action: :no_action, params: %{}},
          rationale: "the kubelet already restarts it",
          evidence_refs: []
        })

      assert Fields.get(signature, :name) == :oomkilled
    end

    test "reads atom- and string-keyed maps alike" do
      assert Fields.get(%{name: "web"}, :name) == "web"
      assert Fields.get(%{"name" => "web"}, :name) == "web"
    end

    test "prefers the atom key when both are present" do
      assert Fields.get(%{:name => "atom", "name" => "string"}, :name) == "atom"
    end

    test "is nil for nil, absent keys, and non-map values" do
      assert Fields.get(nil, :name) == nil
      assert Fields.get(%{}, :name) == nil
      assert Fields.get("not a map", :name) == nil
      assert Fields.get(42, :name) == nil
    end
  end

  describe "text/1" do
    test "atoms and their string forms render identically" do
      assert Fields.text(:permit_auto) == "permit_auto"
      assert Fields.text("permit_auto") == "permit_auto"
    end

    test "numbers render as plain decimals" do
      assert Fields.text(0.9) == "0.9"
      assert Fields.text(3) == "3"
    end

    test "nil renders empty" do
      assert Fields.text(nil) == ""
    end

    test "anything else falls back to inspect" do
      assert Fields.text([1, 2]) == "[1, 2]"
      assert Fields.text({:ok, 1}) == "{:ok, 1}"
    end
  end
end
