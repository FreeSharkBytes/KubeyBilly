defmodule Kubeybilly.Verification.PredicatesTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Verification.Predicates

  @baseline_pod %{
    "phase" => "Running",
    "ready" => true,
    "restart_counts" => %{"app" => 1},
    "node" => "worker-1"
  }

  @baseline %{
    "workload" => %{"kind" => "Deployment", "name" => "web", "namespace" => "demo"},
    "desired_replicas" => 3,
    "ready_replicas" => 3,
    "available_replicas" => 3,
    "revision" => "5",
    "pods" => %{
      "web-old-1" => @baseline_pod,
      "web-old-2" => @baseline_pod,
      "web-old-3" => @baseline_pod
    },
    "ready_pods" => ["web-old-1", "web-old-2", "web-old-3"],
    "services" => %{"web" => %{"ready_endpoints" => 3}}
  }

  defp restart_pod_action(pod \\ "web-old-1") do
    {:ok, action} = Action.new(:restart_pod, %{namespace: "demo", name: pod})
    action
  end

  defp rollback_action(to_revision \\ "4") do
    {:ok, action} =
      Action.new(:rollback_deployment, %{namespace: "demo", name: "web", to_revision: to_revision})

    action
  end

  defp scale_action(replicas \\ 4) do
    {:ok, action} =
      Action.new(:scale, %{namespace: "demo", kind: "Deployment", name: "web", replicas: replicas})

    action
  end

  defp obs_pod(overrides \\ %{}) do
    Map.merge(
      %{
        "phase" => "Running",
        "ready" => true,
        "restart_counts" => %{"app" => 1},
        "node" => "worker-1",
        "template_hash" => "oldhash",
        "terminating" => false
      },
      overrides
    )
  end

  defp healthy_observation(overrides \\ %{}) do
    Map.merge(
      %{
        "desired_replicas" => 3,
        "ready_replicas" => 3,
        "available_replicas" => 3,
        "revision" => "5",
        "pods" => %{
          "web-old-1" => obs_pod(),
          "web-old-2" => obs_pod(),
          "web-old-3" => obs_pod()
        },
        "services" => %{"web" => %{"ready_endpoints" => 3}},
        "replica_sets" => [],
        "newest_revision" => "5"
      },
      overrides
    )
  end

  defp settled_on(observation, action) do
    Predicates.settle(Predicates.initial_settle_state(), observation, action)
  end

  describe "settle/3" do
    test "a non-rollback action settles on the first observation" do
      state = settled_on(healthy_observation(), restart_pod_action())
      assert Predicates.settled?(state)

      assert state.reference_restarts == %{
               "web-old-1" => %{"app" => 1},
               "web-old-2" => %{"app" => 1},
               "web-old-3" => %{"app" => 1}
             }
    end

    test "a rollback does not settle before its ReplicaSet reports pods created" do
      observation =
        healthy_observation(%{
          "replica_sets" => [
            %{
              "name" => "web-good",
              "revision" => "4",
              "revision_history" => [],
              "template_hash" => "goodhash",
              "spec_replicas" => 3,
              "status_replicas" => 1,
              "ready_replicas" => 0,
              "available_replicas" => 0
            }
          ]
        })

      refute Predicates.settled?(settled_on(observation, rollback_action()))
    end

    test "a rollback does not settle while a rolled-to pod is unscheduled" do
      observation =
        healthy_observation(%{
          "pods" => %{
            "web-new-1" => obs_pod(%{"template_hash" => "goodhash", "node" => nil})
          },
          "replica_sets" => [scheduled_rolled_to_rs()]
        })

      refute Predicates.settled?(settled_on(observation, rollback_action()))
    end

    test "a rollback settles once the rolled-to ReplicaSet has scheduled pods" do
      observation =
        healthy_observation(%{
          "pods" => %{
            "web-new-1" =>
              obs_pod(%{"template_hash" => "goodhash", "restart_counts" => %{"app" => 2}})
          },
          "replica_sets" => [scheduled_rolled_to_rs()]
        })

      state = settled_on(observation, rollback_action())
      assert Predicates.settled?(state)
      assert state.reference_restarts == %{"web-new-1" => %{"app" => 2}}
    end

    test "a settled state stays settled and keeps its reference restarts" do
      state = settled_on(healthy_observation(), restart_pod_action())

      later =
        healthy_observation(%{
          "pods" => %{"web-old-1" => obs_pod(%{"restart_counts" => %{"app" => 9}})}
        })

      assert Predicates.settle(state, later, restart_pod_action()) == state
    end
  end

  describe "recovered?/4 and unmet/4" do
    test "all conditions met after settle is recovered" do
      state = settled_on(healthy_observation(), restart_pod_action())
      assert Predicates.recovered?(@baseline, healthy_observation(), restart_pod_action(), state)
      assert Predicates.unmet(@baseline, healthy_observation(), restart_pod_action(), state) == []
    end

    test "ready below desired is unmet" do
      state = settled_on(healthy_observation(), restart_pod_action())
      observation = healthy_observation(%{"ready_replicas" => 2})

      refute Predicates.recovered?(@baseline, observation, restart_pod_action(), state)

      assert :ready_replicas in Predicates.unmet(
               @baseline,
               observation,
               restart_pod_action(),
               state
             )
    end

    test "an unsettled action cannot be recovered" do
      state = Predicates.initial_settle_state()

      refute Predicates.recovered?(@baseline, healthy_observation(), restart_pod_action(), state)

      assert :action_settled in Predicates.unmet(
               @baseline,
               healthy_observation(),
               restart_pod_action(),
               state
             )
    end

    test "a restart since settle is unmet" do
      state = settled_on(healthy_observation(), restart_pod_action())

      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(%{"restart_counts" => %{"app" => 2}}),
            "web-old-2" => obs_pod(),
            "web-old-3" => obs_pod()
          }
        })

      refute Predicates.recovered?(@baseline, observation, restart_pod_action(), state)

      assert :no_restarts_since_settle in Predicates.unmet(
               @baseline,
               observation,
               restart_pod_action(),
               state
             )
    end

    test "a selecting service without a ready endpoint is unmet" do
      state = settled_on(healthy_observation(), restart_pod_action())
      observation = healthy_observation(%{"services" => %{"web" => %{"ready_endpoints" => 0}}})

      assert :service_endpoints in Predicates.unmet(
               @baseline,
               observation,
               restart_pod_action(),
               state
             )
    end

    test "a baseline service missing from the observation is unmet" do
      state = settled_on(healthy_observation(), restart_pod_action())
      observation = healthy_observation(%{"services" => %{}})

      assert :service_endpoints in Predicates.unmet(
               @baseline,
               observation,
               restart_pod_action(),
               state
             )
    end
  end

  describe "recovered?/4 rollback conditions" do
    test "recovered when the rolled-to ReplicaSet is available and the bad one is scaled to zero" do
      observation = rollback_recovered_observation()
      state = settled_on(observation, rollback_action())

      assert Predicates.recovered?(@baseline, observation, rollback_action(), state)
    end

    test "the rolled-to ReplicaSet is recognized by revision history after renumbering" do
      # kubectl-style undo renumbers the reused ReplicaSet: revision 4
      # becomes 6 and 4 lands in the history annotation.
      observation =
        rollback_recovered_observation(
          rolled_to: %{"revision" => "6", "revision_history" => ["2", "4"]}
        )

      state = settled_on(observation, rollback_action("4"))
      assert Predicates.recovered?(@baseline, observation, rollback_action("4"), state)
    end

    test "an unavailable rolled-to ReplicaSet is unmet" do
      observation = rollback_recovered_observation(rolled_to: %{"available_replicas" => 1})
      state = settled_on(observation, rollback_action())

      assert :rolled_to_available in Predicates.unmet(
               @baseline,
               observation,
               rollback_action(),
               state
             )
    end

    test "a missing rolled-to ReplicaSet is unmet" do
      observation = healthy_observation(%{"replica_sets" => []})
      state = %{Predicates.initial_settle_state() | settled: true, reference_restarts: %{}}

      assert :rolled_to_available in Predicates.unmet(
               @baseline,
               observation,
               rollback_action(),
               state
             )
    end

    test "a bad ReplicaSet still scaled up is unmet" do
      observation =
        rollback_recovered_observation(bad: %{"spec_replicas" => 1, "status_replicas" => 1})

      state = settled_on(observation, rollback_action())

      assert :bad_replica_set_scaled_down in Predicates.unmet(
               @baseline,
               observation,
               rollback_action(),
               state
             )
    end

    test "a deleted bad ReplicaSet counts as scaled away" do
      observation = rollback_recovered_observation(drop_bad: true)
      state = settled_on(observation, rollback_action())

      assert Predicates.recovered?(@baseline, observation, rollback_action(), state)
    end
  end

  describe "worse/5 ready drop" do
    test "ready replicas below the baseline is worse" do
      state = settled_on(healthy_observation(), restart_pod_action())
      observation = healthy_observation(%{"ready_replicas" => 2})

      assert {:worse, :ready_replicas_dropped} =
               Predicates.worse(@baseline, observation, restart_pod_action(), state)
    end

    test "ready replicas at the baseline is not worse" do
      state = settled_on(healthy_observation(), restart_pod_action())

      assert Predicates.worse(@baseline, healthy_observation(), restart_pod_action(), state) ==
               :ok
    end
  end

  describe "worse/5 blast radius" do
    test "a baseline-ready pod that was not an action target now failing is worse" do
      state = settled_on(healthy_observation(), restart_pod_action("web-old-1"))

      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(),
            "web-old-2" => obs_pod(%{"ready" => false}),
            "web-old-3" => obs_pod()
          }
        })

      assert {:worse, :blast_radius_spread} =
               Predicates.worse(@baseline, observation, restart_pod_action("web-old-1"), state)
    end

    test "a failed phase also counts as failing" do
      state = settled_on(healthy_observation(), restart_pod_action("web-old-1"))

      observation =
        healthy_observation(%{
          "pods" => %{"web-old-2" => obs_pod(%{"phase" => "Failed"})}
        })

      assert {:worse, :blast_radius_spread} =
               Predicates.worse(@baseline, observation, restart_pod_action("web-old-1"), state)
    end

    test "the action's own target pod failing is not spread" do
      state = settled_on(healthy_observation(), restart_pod_action("web-old-1"))

      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(%{"ready" => false}),
            "web-old-2" => obs_pod(),
            "web-old-3" => obs_pod()
          }
        })

      assert Predicates.worse(@baseline, observation, restart_pod_action("web-old-1"), state) ==
               :ok
    end

    test "a terminating pod is deletion, not failure" do
      state = settled_on(healthy_observation(), scale_action(2))

      observation =
        healthy_observation(%{
          "pods" => %{"web-old-2" => obs_pod(%{"ready" => false, "terminating" => true})}
        })

      assert Predicates.worse(@baseline, observation, scale_action(2), state) == :ok
    end

    test "a pod that disappeared entirely is not spread" do
      state = settled_on(healthy_observation(), scale_action(2))
      observation = healthy_observation(%{"pods" => %{}})

      assert Predicates.worse(@baseline, observation, scale_action(2), state) == :ok
    end

    test "a rollback treats the workload's baseline pods as targets, so their churn is expected" do
      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(%{"ready" => false}),
            "web-old-2" => obs_pod(%{"ready" => false})
          },
          "replica_sets" => [scheduled_rolled_to_rs()]
        })

      state = Predicates.initial_settle_state()

      assert Predicates.worse(@baseline, observation, rollback_action(), state) == :ok
    end
  end

  describe "worse/5 restart rate" do
    test "more restarts since settle than the pre-incident rate is worse" do
      state = settled_on(healthy_observation(), scale_action())

      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(%{"restart_counts" => %{"app" => 3}}),
            "web-old-2" => obs_pod(),
            "web-old-3" => obs_pod()
          }
        })

      assert {:worse, :restart_rate_exceeded} =
               Predicates.worse(@baseline, observation, scale_action(), state,
                 pre_incident_restarts: 1
               )
    end

    test "restarts within the pre-incident rate are tolerated" do
      state = settled_on(healthy_observation(), scale_action())

      observation =
        healthy_observation(%{
          "pods" => %{
            "web-old-1" => obs_pod(%{"restart_counts" => %{"app" => 2}}),
            "web-old-2" => obs_pod(),
            "web-old-3" => obs_pod()
          }
        })

      assert Predicates.worse(@baseline, observation, scale_action(), state,
               pre_incident_restarts: 1
             ) == :ok
    end

    test "a brand-new pod's restarts count in full" do
      state = settled_on(healthy_observation(), scale_action())

      observation =
        healthy_observation(%{
          "pods" => %{"web-new-9" => obs_pod(%{"restart_counts" => %{"app" => 2}})}
        })

      assert {:worse, :restart_rate_exceeded} =
               Predicates.worse(@baseline, observation, scale_action(), state,
                 pre_incident_restarts: 1
               )
    end

    test "restart counting begins only after the action settles" do
      state = Predicates.initial_settle_state()

      observation =
        healthy_observation(%{
          "pods" => %{"web-new-1" => obs_pod(%{"restart_counts" => %{"app" => 7}})},
          "replica_sets" => [
            Map.merge(scheduled_rolled_to_rs(), %{"status_replicas" => 1})
          ]
        })

      assert Predicates.worse(@baseline, observation, rollback_action(), state) == :ok
    end
  end

  describe "worse/5 new alert signature" do
    test "the injectable alert check defaults to never-worse" do
      state = settled_on(healthy_observation(), scale_action())

      assert Predicates.worse(@baseline, healthy_observation(), scale_action(), state) == :ok
    end

    test "a new distinct alert signature is worse" do
      state = settled_on(healthy_observation(), scale_action())

      assert {:worse, :new_alert_signature} =
               Predicates.worse(@baseline, healthy_observation(), scale_action(), state,
                 alert_check: fn -> true end
               )
    end
  end

  ## Rollback observation fixtures

  defp scheduled_rolled_to_rs do
    %{
      "name" => "web-good",
      "revision" => "4",
      "revision_history" => [],
      "template_hash" => "goodhash",
      "spec_replicas" => 3,
      "status_replicas" => 3,
      "ready_replicas" => 3,
      "available_replicas" => 3
    }
  end

  defp rollback_recovered_observation(opts \\ []) do
    rolled_to = Map.merge(scheduled_rolled_to_rs(), Keyword.get(opts, :rolled_to, %{}))

    bad =
      Map.merge(
        %{
          "name" => "web-bad",
          "revision" => "5",
          "revision_history" => [],
          "template_hash" => "badhash",
          "spec_replicas" => 0,
          "status_replicas" => 0,
          "ready_replicas" => 0,
          "available_replicas" => 0
        },
        Keyword.get(opts, :bad, %{})
      )

    replica_sets = if Keyword.get(opts, :drop_bad, false), do: [rolled_to], else: [rolled_to, bad]

    healthy_observation(%{
      "pods" => %{
        "web-new-1" => obs_pod(%{"template_hash" => "goodhash"}),
        "web-new-2" => obs_pod(%{"template_hash" => "goodhash"}),
        "web-new-3" => obs_pod(%{"template_hash" => "goodhash"})
      },
      "replica_sets" => replica_sets,
      "newest_revision" => rolled_to["revision"]
    })
  end
end
