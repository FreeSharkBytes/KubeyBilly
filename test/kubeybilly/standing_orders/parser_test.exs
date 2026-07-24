defmodule Kubeybilly.StandingOrders.ParserTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.StandingOrders.Parser
  alias Kubeybilly.StandingOrders.Policy

  @fixture Path.expand("../../fixtures/standing_orders/demo.yaml", __DIR__)

  describe "parse/1 round-trips the plan example document" do
    test "parses every section of the demo fixture exactly" do
      assert {:ok, %Policy{} = policy} = Parser.parse(File.read!(@fixture))

      assert policy.scope == %{
               namespaces_include: ["demo", "shop"],
               namespaces_exclude: ["kube-system", "kubeybilly"]
             }

      assert policy.tiers == %{
               "read" => %{
                 actions: [:no_action],
                 auto: true,
                 min_confidence: nil,
                 max_delta: nil
               },
               "restart" => %{
                 actions: [:restart_pod, :restart_workload],
                 auto: true,
                 min_confidence: 0.8,
                 max_delta: nil
               },
               "rollback" => %{
                 actions: [:rollback_deployment],
                 auto: false,
                 min_confidence: 0.9,
                 max_delta: nil
               },
               "scale" => %{
                 actions: [:scale],
                 auto: false,
                 min_confidence: nil,
                 max_delta: 2
               },
               "node" => %{
                 actions: [:cordon_node],
                 auto: false,
                 min_confidence: nil,
                 max_delta: nil
               }
             }

      assert policy.budgets == %{
               actions_per_incident: 2,
               actions_per_hour: 10,
               max_pods_touched: 20
             }

      assert policy.deny_kinds == [
               "PersistentVolumeClaim",
               "PersistentVolume",
               "StatefulSet",
               "Namespace",
               "CustomResourceDefinition"
             ]

      assert policy.freeze_when == %{rollout_in_progress: true, maintenance_window: false}
      assert policy.verification == %{window_seconds: 90}
      assert policy.approval == %{timeout_seconds: 300}
      assert policy.mode == :dry_run
    end
  end

  describe "parse/1 defaults" do
    test "an empty document yields the documented defaults" do
      assert {:ok, %Policy{} = policy} = Parser.parse("{}")

      assert policy.scope == %{namespaces_include: [], namespaces_exclude: []}
      assert policy.tiers == %{"read" => Policy.default_read_tier()}

      assert policy.budgets == %{
               actions_per_incident: 2,
               actions_per_hour: 10,
               max_pods_touched: 20
             }

      assert policy.deny_kinds == []
      assert policy.freeze_when == %{rollout_in_progress: true, maintenance_window: false}
      assert policy.verification == %{window_seconds: 90}
      assert policy.approval == %{timeout_seconds: 300}
      assert policy.mode == :dry_run
    end

    test "mode defaults to dry_run when omitted" do
      assert {:ok, %Policy{mode: :dry_run}} =
               Parser.parse("tiers:\n  read: { actions: [no_action], auto: true }\n")
    end

    test "tier auto defaults to false when omitted" do
      assert {:ok, %Policy{tiers: %{"node" => %{auto: false}}}} =
               Parser.parse("tiers:\n  node: { actions: [cordon_node] }\n")
    end
  end

  describe "parse/1 mode" do
    test "accepts each declared mode" do
      for {raw, mode} <- [{"dry_run", :dry_run}, {"approve", :approve}, {"auto", :auto}] do
        assert {:ok, %Policy{mode: ^mode}} = Parser.parse("mode: #{raw}\n")
      end
    end

    test "rejects an unknown mode" do
      assert {:error, {:policy, {:invalid_mode, "yolo"}}} = Parser.parse("mode: yolo\n")
    end
  end

  describe "parse/1 rejections" do
    test "rejects unknown top-level keys" do
      assert {:error, {:policy, {:unknown_keys, [], ["surprise"]}}} =
               Parser.parse("surprise: true\n")
    end

    test "rejects unknown keys inside a section" do
      assert {:error, {:policy, {:unknown_keys, ["scope"], ["cluster"]}}} =
               Parser.parse("scope:\n  cluster: prod\n")
    end

    test "rejects unknown keys inside a tier" do
      yaml = "tiers:\n  read: { actions: [no_action], blast: 3 }\n"

      assert {:error, {:policy, {:unknown_keys, ["tiers", "read"], ["blast"]}}} =
               Parser.parse(yaml)
    end

    test "rejects a tier referencing an unknown action" do
      yaml = "tiers:\n  read: { actions: [drain_node], auto: true }\n"

      assert {:error, {:policy, {:unknown_action, "read", "drain_node"}}} = Parser.parse(yaml)
    end

    test "rejects an action appearing in more than one tier" do
      yaml = """
      tiers:
        restart: { actions: [restart_pod], auto: true }
        chaos:   { actions: [restart_pod], auto: false }
      """

      assert {:error, {:policy, {:duplicate_action, :restart_pod, tiers}}} = Parser.parse(yaml)
      assert Enum.sort(tiers) == ["chaos", "restart"]
    end

    test "rejects a tier without actions" do
      assert {:error, {:policy, {:invalid_value, ["tiers", "read", "actions"], nil}}} =
               Parser.parse("tiers:\n  read: { auto: true }\n")
    end

    test "rejects a non-numeric budget" do
      assert {:error, {:policy, {:invalid_value, ["budgets", "actions_per_hour"], "plenty"}}} =
               Parser.parse("budgets:\n  actions_per_hour: plenty\n")
    end

    test "rejects a non-boolean freeze flag" do
      assert {:error, {:policy, {:invalid_value, ["freeze_when", "maintenance_window"], "maybe"}}} =
               Parser.parse("freeze_when:\n  maintenance_window: maybe\n")
    end

    test "rejects a min_confidence outside the unit interval" do
      yaml = "tiers:\n  restart: { actions: [restart_pod], min_confidence: 1.5 }\n"

      assert {:error, {:policy, {:invalid_value, ["tiers", "restart", "min_confidence"], 1.5}}} =
               Parser.parse(yaml)
    end

    test "rejects a non-list scope include" do
      assert {:error, {:policy, {:invalid_value, ["scope", "namespaces_include"], "demo"}}} =
               Parser.parse("scope:\n  namespaces_include: demo\n")
    end

    test "rejects a scope that is not a map" do
      assert {:error, {:policy, {:invalid_value, ["scope"], "everywhere"}}} =
               Parser.parse("scope: everywhere\n")
    end

    test "rejects a scope list with non-string entries" do
      assert {:error, {:policy, {:invalid_value, ["scope", "namespaces_exclude"], [1, 2]}}} =
               Parser.parse("scope:\n  namespaces_exclude: [1, 2]\n")
    end

    test "rejects a tiers section that is not a map" do
      assert {:error, {:policy, {:invalid_value, ["tiers"], "loose"}}} =
               Parser.parse("tiers: loose\n")
    end

    test "rejects a tier that is not a map" do
      assert {:error, {:policy, {:invalid_value, ["tiers", "read"], "open"}}} =
               Parser.parse("tiers:\n  read: open\n")
    end

    test "rejects a non-string action" do
      assert {:error, {:policy, {:unknown_action, "read", 7}}} =
               Parser.parse("tiers:\n  read: { actions: [7] }\n")
    end

    test "rejects a non-boolean tier auto" do
      assert {:error, {:policy, {:invalid_value, ["tiers", "read", "auto"], "yep"}}} =
               Parser.parse("tiers:\n  read: { actions: [no_action], auto: yep }\n")
    end

    test "rejects a non-positive max_delta" do
      yaml = "tiers:\n  scale: { actions: [scale], max_delta: 0 }\n"

      assert {:error, {:policy, {:invalid_value, ["tiers", "scale", "max_delta"], 0}}} =
               Parser.parse(yaml)
    end

    test "rejects deny_kinds that is not a list" do
      assert {:error, {:policy, {:invalid_value, ["deny_kinds"], "Namespace"}}} =
               Parser.parse("deny_kinds: Namespace\n")
    end

    test "rejects deny_kinds with non-string entries" do
      assert {:error, {:policy, {:invalid_value, ["deny_kinds"], [42]}}} =
               Parser.parse("deny_kinds: [42]\n")
    end

    test "rejects a flat section that is not a map" do
      assert {:error, {:policy, {:invalid_value, ["budgets"], "unlimited"}}} =
               Parser.parse("budgets: unlimited\n")
    end

    test "rejects a non-positive budget" do
      assert {:error, {:policy, {:invalid_value, ["budgets", "actions_per_incident"], 0}}} =
               Parser.parse("budgets:\n  actions_per_incident: 0\n")
    end

    test "rejects malformed yaml" do
      assert {:error, {:policy, {:invalid_yaml, _reason}}} = Parser.parse(": : :\n\t-")
    end

    test "rejects a document whose root is not a map" do
      assert {:error, {:policy, {:invalid_document, ["just", "a", "list"]}}} =
               Parser.parse("- just\n- a\n- list\n")
    end
  end

  describe "load/1" do
    test "loads the fixture from disk" do
      assert {:ok, %Policy{mode: :dry_run}} = Parser.load(@fixture)
    end

    test "returns a tagged error for a missing file" do
      assert {:error, {:policy, {:unreadable, path, :enoent}}} =
               Parser.load(Path.join(Path.dirname(@fixture), "missing.yaml"))

      assert String.ends_with?(path, "missing.yaml")
    end
  end
end
