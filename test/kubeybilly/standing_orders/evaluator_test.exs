defmodule Kubeybilly.StandingOrders.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.StandingOrders.Decision
  alias Kubeybilly.StandingOrders.Evaluator
  alias Kubeybilly.StandingOrders.Parser

  @fixture Path.expand("../../fixtures/standing_orders/demo.yaml", __DIR__)

  @full_chain [
    "kill-switch",
    "scope-namespace",
    "deny-kinds",
    "freeze-rollout",
    "freeze-maintenance",
    "tier-lookup",
    "tier-min-confidence",
    "tier-constraints",
    "budget-actions-per-incident",
    "budget-actions-per-hour",
    "budget-max-pods",
    "tier-auto"
  ]

  setup_all do
    {:ok, policy} = Parser.load(@fixture)
    %{policy: policy}
  end

  defp intent(overrides \\ %{}) do
    Map.merge(
      %{
        action: :restart_pod,
        params: %{},
        confidence: 0.95,
        blast_estimate: 1,
        target_kind: "Deployment",
        namespace: "demo",
        owner_kinds: ["ReplicaSet", "Deployment"]
      },
      overrides
    )
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        kill_switch_engaged: false,
        rollout_in_progress: false,
        expected_rollout: false,
        maintenance_window: false,
        actions_this_incident: 0,
        actions_this_hour: 0,
        mode: :auto
      },
      overrides
    )
  end

  describe "permits" do
    test "an auto-tier action above min confidence permits with the full chain", %{
      policy: policy
    } do
      assert %Decision{verdict: :permit_auto, rule_id: "tier-auto", chain: @full_chain} =
               Evaluator.evaluate(policy, intent(), context())
    end

    test "dry_run mode does not change the verdict", %{policy: policy} do
      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(), context(%{mode: :dry_run}))
    end

    test "approve mode downgrades permit_auto to needs_approval", %{policy: policy} do
      assert %Decision{verdict: :needs_approval, rule_id: "tier-auto", chain: @full_chain} =
               Evaluator.evaluate(policy, intent(), context(%{mode: :approve}))
    end

    test "a tier with auto false routes to approval even in auto mode", %{policy: policy} do
      rollback = intent(%{action: :rollback_deployment, confidence: 0.95})

      assert %Decision{verdict: :needs_approval, rule_id: "tier-auto", chain: @full_chain} =
               Evaluator.evaluate(policy, rollback, context())
    end

    test "a tier without min_confidence accepts any confidence", %{policy: policy} do
      cordon = intent(%{action: :cordon_node, confidence: 0.0, target_kind: "Node"})

      assert %Decision{verdict: :needs_approval, chain: chain} =
               Evaluator.evaluate(policy, cordon, context())

      assert "tier-min-confidence" in chain
    end

    test "an empty include list scopes nothing out" do
      {:ok, policy} =
        Parser.parse("tiers:\n  restart: { actions: [restart_pod], auto: true }\n")

      anywhere = intent(%{namespace: "somewhere-else"})

      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, anywhere, context())
    end

    test "every decision carries the mode and budgets it was evaluated under", %{
      policy: policy
    } do
      budgets = policy.budgets

      assert %Decision{mode: :dry_run, budgets: ^budgets} =
               Evaluator.evaluate(policy, intent(), context(%{mode: :dry_run}))

      assert %Decision{verdict: :deny, mode: :auto, budgets: ^budgets} =
               Evaluator.evaluate(policy, intent(), context(%{kill_switch_engaged: true}))

      assert %Decision{mode: :auto, budgets: ^budgets} =
               Evaluator.evaluate(policy, intent(%{action: :no_action}), context())
    end
  end

  describe "kill-switch" do
    test "an engaged kill switch denies everything mutating", %{policy: policy} do
      assert %Decision{verdict: :deny, rule_id: "kill-switch", chain: [], reason: reason} =
               Evaluator.evaluate(policy, intent(), context(%{kill_switch_engaged: true}))

      assert reason =~ "kill switch"
    end
  end

  describe "scope-namespace" do
    test "an excluded namespace denies", %{policy: policy} do
      assert %Decision{verdict: :deny, rule_id: "scope-namespace", chain: ["kill-switch"]} =
               Evaluator.evaluate(policy, intent(%{namespace: "kube-system"}), context())
    end

    test "a namespace outside the include list denies", %{policy: policy} do
      assert %Decision{verdict: :deny, rule_id: "scope-namespace"} =
               Evaluator.evaluate(policy, intent(%{namespace: "prod"}), context())
    end
  end

  describe "deny-kinds" do
    test "a denied target kind denies", %{policy: policy} do
      denied = intent(%{target_kind: "StatefulSet"})

      assert %Decision{
               verdict: :deny,
               rule_id: "deny-kinds",
               chain: ["kill-switch", "scope-namespace"]
             } = Evaluator.evaluate(policy, denied, context())
    end

    test "a denied kind in the owner chain denies", %{policy: policy} do
      owned = intent(%{owner_kinds: ["StatefulSet"]})

      assert %Decision{verdict: :deny, rule_id: "deny-kinds", reason: reason} =
               Evaluator.evaluate(policy, owned, context())

      assert reason =~ "StatefulSet"
    end
  end

  describe "freeze rules" do
    test "a foreign rollout in progress freezes", %{policy: policy} do
      assert %Decision{
               verdict: :deny,
               rule_id: "freeze-rollout",
               chain: ["kill-switch", "scope-namespace", "deny-kinds"]
             } =
               Evaluator.evaluate(policy, intent(), context(%{rollout_in_progress: true}))
    end

    test "the incident's own rollout is exempt", %{policy: policy} do
      own_rollout = context(%{rollout_in_progress: true, expected_rollout: true})

      assert %Decision{verdict: :permit_auto, chain: chain} =
               Evaluator.evaluate(policy, intent(), own_rollout)

      assert "freeze-rollout" in chain
    end

    test "a policy that does not freeze on rollouts lets them through" do
      yaml = """
      tiers:
        restart: { actions: [restart_pod], auto: true }
      freeze_when:
        rollout_in_progress: false
      """

      {:ok, policy} = Parser.parse(yaml)

      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(), context(%{rollout_in_progress: true}))
    end

    test "a maintenance window freezes when the policy says so" do
      yaml = """
      tiers:
        restart: { actions: [restart_pod], auto: true }
      freeze_when:
        maintenance_window: true
      """

      {:ok, policy} = Parser.parse(yaml)

      assert %Decision{verdict: :deny, rule_id: "freeze-maintenance", chain: chain} =
               Evaluator.evaluate(policy, intent(), context(%{maintenance_window: true}))

      assert chain == ["kill-switch", "scope-namespace", "deny-kinds", "freeze-rollout"]
    end

    test "the demo policy does not freeze on maintenance windows", %{policy: policy} do
      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(), context(%{maintenance_window: true}))
    end
  end

  describe "tier-lookup" do
    test "an action in no tier denies" do
      {:ok, policy} =
        Parser.parse("tiers:\n  restart: { actions: [restart_pod], auto: true }\n")

      cordon = intent(%{action: :cordon_node, target_kind: "Node"})

      assert %Decision{verdict: :deny, rule_id: "tier-lookup", chain: chain} =
               Evaluator.evaluate(policy, cordon, context())

      assert chain == [
               "kill-switch",
               "scope-namespace",
               "deny-kinds",
               "freeze-rollout",
               "freeze-maintenance"
             ]
    end
  end

  describe "tier-min-confidence" do
    test "confidence below the tier floor denies", %{policy: policy} do
      shaky = intent(%{confidence: 0.5})

      assert %Decision{verdict: :deny, rule_id: "tier-min-confidence", chain: chain} =
               Evaluator.evaluate(policy, shaky, context())

      assert List.last(chain) == "tier-lookup"
    end

    test "confidence exactly at the floor passes", %{policy: policy} do
      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(%{confidence: 0.8}), context())
    end
  end

  describe "tier-constraints" do
    test "a scale delta beyond max_delta denies", %{policy: policy} do
      jump = intent(%{action: :scale, params: %{replicas: 10, current_replicas: 2}})

      assert %Decision{verdict: :deny, rule_id: "tier-constraints", reason: reason} =
               Evaluator.evaluate(policy, jump, context())

      assert reason =~ "max_delta"
    end

    test "a scale without current replica knowledge denies", %{policy: policy} do
      blind = intent(%{action: :scale, params: %{replicas: 4}})

      assert %Decision{verdict: :deny, rule_id: "tier-constraints"} =
               Evaluator.evaluate(policy, blind, context())
    end

    test "a scale within max_delta proceeds to approval", %{policy: policy} do
      gentle = intent(%{action: :scale, params: %{replicas: 4, current_replicas: 2}})

      assert %Decision{verdict: :needs_approval, rule_id: "tier-auto", chain: @full_chain} =
               Evaluator.evaluate(policy, gentle, context())
    end
  end

  describe "budgets" do
    test "an exhausted per-incident budget denies", %{policy: policy} do
      spent = context(%{actions_this_incident: 2})

      assert %Decision{verdict: :deny, rule_id: "budget-actions-per-incident", chain: chain} =
               Evaluator.evaluate(policy, intent(), spent)

      assert List.last(chain) == "tier-constraints"
    end

    test "one action already taken still leaves budget for the revert", %{policy: policy} do
      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(), context(%{actions_this_incident: 1}))
    end

    test "an exhausted hourly budget denies", %{policy: policy} do
      busy = context(%{actions_this_hour: 10})

      assert %Decision{verdict: :deny, rule_id: "budget-actions-per-hour", chain: chain} =
               Evaluator.evaluate(policy, intent(), busy)

      assert List.last(chain) == "budget-actions-per-incident"
    end

    test "a blast estimate beyond max_pods_touched denies", %{policy: policy} do
      wide = intent(%{blast_estimate: 21})

      assert %Decision{verdict: :deny, rule_id: "budget-max-pods", chain: chain} =
               Evaluator.evaluate(policy, wide, context())

      assert List.last(chain) == "budget-actions-per-hour"
    end

    test "a blast estimate exactly at the cap passes", %{policy: policy} do
      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, intent(%{blast_estimate: 20}), context())
    end
  end

  describe "no_action" do
    test "no_action always permits through the read tier", %{policy: policy} do
      hopeless =
        context(%{
          kill_switch_engaged: true,
          rollout_in_progress: true,
          maintenance_window: true,
          actions_this_incident: 99,
          actions_this_hour: 99
        })

      decline =
        intent(%{
          action: :no_action,
          params: %{reason: "nothing to do"},
          namespace: "kube-system",
          target_kind: "StatefulSet"
        })

      assert %Decision{
               verdict: :permit_auto,
               rule_id: "tier-auto",
               chain: ["tier-lookup", "tier-auto"],
               reason: reason
             } = Evaluator.evaluate(policy, decline, hopeless)

      assert reason =~ "no_action"
    end

    test "no_action stays permit_auto in approve mode", %{policy: policy} do
      decline = intent(%{action: :no_action})

      assert %Decision{verdict: :permit_auto} =
               Evaluator.evaluate(policy, decline, context(%{mode: :approve}))
    end
  end

  describe "telemetry" do
    test "every evaluation emits a decision event", %{policy: policy} do
      ref = make_ref()
      handler_id = "evaluator-test-#{inspect(ref)}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:kubeybilly, :standing_orders, :decision],
          fn _event, measurements, metadata, _config ->
            send(parent, {ref, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Evaluator.evaluate(policy, intent(), context())

      assert_receive {^ref, %{rules_passed: 12},
                      %{
                        verdict: :permit_auto,
                        rule_id: "tier-auto",
                        action: :restart_pod,
                        namespace: "demo"
                      }}

      Evaluator.evaluate(policy, intent(), context(%{kill_switch_engaged: true}))

      assert_receive {^ref, %{rules_passed: 0}, %{verdict: :deny, rule_id: "kill-switch"}}
    end
  end
end
