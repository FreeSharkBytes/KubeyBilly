defmodule Kubeybilly.Verification.RealTest do
  use ExUnit.Case, async: true

  import Mox

  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.K8sClient.Mock, as: Client
  alias Kubeybilly.Verification.Real

  setup :verify_on_exit!

  @fixtures "test/fixtures/incidents"
  @poll_event [:kubeybilly, :verification, :poll]
  @outcome_event [:kubeybilly, :verification, :outcome]

  setup do
    handler = "real-verifier-#{inspect(self())}"
    pid = self()

    :telemetry.attach_many(
      handler,
      [@poll_event, @outcome_event],
      fn event, measurements, metadata, _config ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp record(action, id \\ "oomkill-galley") do
    Record.new(%{
      id: id,
      group_key: "group",
      namespace: "demo",
      workload: %{kind: "Deployment", name: "galley", uid: "uid-1"},
      action: action
    })
  end

  defp restart_pod_action(pod) do
    {:ok, action} = Action.new(:restart_pod, %{namespace: "demo", name: pod})
    action
  end

  defp rollback_action(to_revision) do
    {:ok, action} =
      Action.new(:rollback_deployment, %{
        namespace: "demo",
        name: "galley",
        to_revision: to_revision
      })

    action
  end

  defp fixture_baseline do
    @fixtures
    |> Path.join("oomkill-galley/metrics/baseline.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp deployment(ready_replicas) do
    %{
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "galley",
        "annotations" => %{"deployment.kubernetes.io/revision" => "5"}
      },
      "spec" => %{
        "replicas" => 3,
        "selector" => %{"matchLabels" => %{"app" => "galley"}},
        "template" => %{"metadata" => %{"labels" => %{"app" => "galley"}}}
      },
      "status" => %{"readyReplicas" => ready_replicas, "availableReplicas" => ready_replicas}
    }
  end

  defp pod(name, opts) do
    ready = Keyword.get(opts, :ready, true)

    %{
      "kind" => "Pod",
      "metadata" => %{
        "name" => name,
        "labels" => %{
          "app" => "galley",
          "pod-template-hash" => Keyword.get(opts, :hash, "d7c6bc75c")
        }
      },
      "spec" => %{"nodeName" => Keyword.get(opts, :node, "kubeybilly-control-plane")},
      "status" => %{
        "phase" => Keyword.get(opts, :phase, "Running"),
        "conditions" => [%{"type" => "Ready", "status" => if(ready, do: "True", else: "False")}],
        "containerStatuses" => [
          %{"name" => "galley", "restartCount" => Keyword.get(opts, :restarts, 0)}
        ]
      }
    }
  end

  defp replica_set(name, opts) do
    %{
      "kind" => "ReplicaSet",
      "metadata" => %{
        "name" => name,
        "annotations" => %{"deployment.kubernetes.io/revision" => Keyword.fetch!(opts, :revision)},
        "labels" => %{"pod-template-hash" => Keyword.fetch!(opts, :hash)}
      },
      "spec" => %{"replicas" => Keyword.get(opts, :spec_replicas, 3)},
      "status" => %{
        "replicas" => Keyword.get(opts, :status_replicas, 3),
        "readyReplicas" => Keyword.get(opts, :ready_replicas, 3),
        "availableReplicas" => Keyword.get(opts, :available_replicas, 3)
      }
    }
  end

  @service %{
    "kind" => "Service",
    "metadata" => %{"name" => "galley"},
    "spec" => %{"selector" => %{"app" => "galley"}}
  }

  defp slices(ready_endpoints) do
    [
      %{
        "kind" => "EndpointSlice",
        "endpoints" => List.duplicate(%{"conditions" => %{"ready" => true}}, ready_endpoints)
      }
    ]
  end

  defp healthy_pods do
    [
      pod("galley-d7c6bc75c-drbdd", []),
      pod("galley-d7c6bc75c-fs89f", restarts: 2),
      pod("galley-d7c6bc75c-jz99q", [])
    ]
  end

  defp expect_observation(scene) do
    ready = Map.get(scene, :ready, 3)
    pods = Map.get(scene, :pods, healthy_pods())
    replica_sets = Map.get(scene, :replica_sets, [])
    endpoints = Map.get(scene, :endpoints, 3)

    expect(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, deployment(ready)} end)
    expect(Client, :list, fn "Pod", "demo", "app=galley" -> {:ok, pods} end)
    expect(Client, :list, fn "ReplicaSet", "demo", "app=galley" -> {:ok, replica_sets} end)
    expect(Client, :list, fn "Service", "demo", nil -> {:ok, [@service]} end)

    expect(Client, :list, fn "EndpointSlice", "demo", "kubernetes.io/service-name=galley" ->
      {:ok, slices(endpoints)}
    end)
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        window_seconds: 90,
        window_ms: 5_000,
        poll_interval_ms: 1,
        client: Client,
        incidents_root: @fixtures
      ],
      overrides
    )
  end

  describe "verify/3 recovered" do
    test "recovers after two stable polls, loading the baseline from the bundle" do
      expect_observation(%{})
      expect_observation(%{})

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 2}} =
               Real.verify(record, nil, opts())

      assert_receive {:telemetry, @outcome_event, %{polls: 2},
                      %{
                        incident_id: "oomkill-galley",
                        outcome: :recovered
                      }}
    end

    test "one stable poll is a candidate, not an outcome" do
      # Healthy, then a service blip, then healthy twice: stability resets.
      expect_observation(%{})
      expect_observation(%{endpoints: 0})
      expect_observation(%{})
      expect_observation(%{})

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 4}} =
               Real.verify(record, fixture_baseline(), opts())

      assert_receive {:telemetry, @outcome_event, %{polls: 4}, %{outcome: :recovered}}
    end
  end

  describe "verify/3 worse" do
    test "ready replicas dropping below the baseline is worse on the spot" do
      expect_observation(%{ready: 2})

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :worse, %{reason: :ready_replicas_dropped, unmet: [], polls: 1}} =
               Real.verify(record, fixture_baseline(), opts())

      assert_receive {:telemetry, @outcome_event, %{polls: 1},
                      %{
                        outcome: :worse,
                        reason: :ready_replicas_dropped
                      }}
    end

    test "a baseline-ready pod outside the action's targets failing is worse" do
      pods = [
        pod("galley-d7c6bc75c-drbdd", ready: false),
        pod("galley-d7c6bc75c-fs89f", restarts: 2),
        pod("galley-d7c6bc75c-jz99q", [])
      ]

      expect_observation(%{pods: pods})

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :worse, %{reason: :blast_radius_spread, unmet: []}} =
               Real.verify(record, fixture_baseline(), opts())

      assert_receive {:telemetry, @outcome_event, _measurements,
                      %{
                        outcome: :worse,
                        reason: :blast_radius_spread
                      }}
    end
  end

  describe "verify/3 unchanged" do
    test "window expiry without a verdict is unchanged, with the unmet conditions" do
      stub(Client, :get, fn "Deployment", "galley", "demo" -> {:ok, deployment(3)} end)

      stub(Client, :list, fn
        "Pod", "demo", _selector -> {:ok, healthy_pods()}
        "ReplicaSet", "demo", _selector -> {:ok, []}
        "Service", "demo", nil -> {:ok, [@service]}
        "EndpointSlice", "demo", _selector -> {:ok, slices(0)}
      end)

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :unchanged, %{reason: :window_expired, unmet: returned_unmet}} =
               Real.verify(record, fixture_baseline(), opts(window_ms: 30, poll_interval_ms: 5))

      assert :service_endpoints in returned_unmet

      assert_receive {:telemetry, @outcome_event, _measurements,
                      %{
                        outcome: :unchanged,
                        reason: :window_expired,
                        unmet: unmet
                      }}

      assert :service_endpoints in unmet

      # The caller and the telemetry consumer must read the same story;
      # a second computation could disagree with the logged one.
      assert returned_unmet == unmet
    end

    test "more than three consecutive failed polls give up as unchanged" do
      stub(Client, :get, fn "Deployment", "galley", "demo" ->
        {:error, {:conn, :cluster_down}}
      end)

      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      assert {:ok, :unchanged, %{reason: :polls_failed, polls: 4}} =
               Real.verify(record, fixture_baseline(), opts(window_ms: 60_000))

      assert_receive {:telemetry, @outcome_event, %{polls: 4},
                      %{
                        outcome: :unchanged,
                        reason: :polls_failed
                      }}

      assert_receive {:telemetry, @poll_event, %{poll: 1}, %{status: :inconclusive}}
    end

    test "a missing baseline cannot be judged and is unchanged" do
      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"), "no-such-incident")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :unchanged, %{reason: :no_baseline, unmet: [], polls: 0}} =
                   Real.verify(record, nil, opts())
        end)

      assert log =~ "no readable baseline"

      assert_receive {:telemetry, @outcome_event, %{polls: 0},
                      %{
                        outcome: :unchanged,
                        reason: :no_baseline
                      }}
    end
  end

  describe "verify/3 rollback self-rollout awareness" do
    test "settle churn does not read as worse, and recovery follows" do
      baseline = %{
        "workload" => %{"kind" => "Deployment", "name" => "galley", "namespace" => "demo"},
        "desired_replicas" => 3,
        "ready_replicas" => 1,
        "available_replicas" => 1,
        "revision" => "5",
        "pods" => %{
          "galley-bad-1" => %{
            "phase" => "Running",
            "ready" => true,
            "restart_counts" => %{"galley" => 4},
            "node" => "n1"
          },
          "galley-bad-2" => %{
            "phase" => "Running",
            "ready" => false,
            "restart_counts" => %{"galley" => 6},
            "node" => "n1"
          }
        },
        "ready_pods" => ["galley-bad-1"],
        "services" => %{"galley" => %{"ready_endpoints" => 1}}
      }

      churn_pods = [
        pod("galley-bad-1", hash: "badhash", restarts: 4),
        pod("galley-good-1", hash: "goodhash", ready: false, phase: "Pending", node: nil)
      ]

      churn_replica_sets = [
        replica_set("galley-good",
          revision: "4",
          hash: "goodhash",
          status_replicas: 1,
          ready_replicas: 0,
          available_replicas: 0
        ),
        replica_set("galley-bad",
          revision: "5",
          hash: "badhash",
          spec_replicas: 1,
          status_replicas: 1,
          ready_replicas: 1,
          available_replicas: 1
        )
      ]

      settled_pods = [
        pod("galley-good-1", hash: "goodhash"),
        pod("galley-good-2", hash: "goodhash"),
        pod("galley-good-3", hash: "goodhash")
      ]

      settled_replica_sets = [
        replica_set("galley-good", revision: "4", hash: "goodhash"),
        replica_set("galley-bad",
          revision: "5",
          hash: "badhash",
          spec_replicas: 0,
          status_replicas: 0,
          ready_replicas: 0,
          available_replicas: 0
        )
      ]

      # Poll 1: mid-rollout churn. Poll 2 and 3: settled and healthy.
      expect_observation(%{
        ready: 1,
        pods: churn_pods,
        replica_sets: churn_replica_sets,
        endpoints: 1
      })

      expect_observation(%{pods: settled_pods, replica_sets: settled_replica_sets})
      expect_observation(%{pods: settled_pods, replica_sets: settled_replica_sets})

      record = record(rollback_action("4"), "rollback-incident")

      assert {:ok, :recovered, %{reason: :recovered_sustained, unmet: [], polls: 3}} =
               Real.verify(record, baseline, opts())

      assert_receive {:telemetry, @outcome_event, %{polls: 3}, %{outcome: :recovered}}
    end
  end

  describe "pre_incident_restarts/2" do
    test "counts the bundle's BackOff events inside an equivalent pre-incident window" do
      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))

      # No BackOff in the 90 seconds before capture; two within 600.
      assert Real.pre_incident_restarts(record, incidents_root: @fixtures, window_seconds: 90) ==
               0

      assert Real.pre_incident_restarts(record,
               incidents_root: @fixtures,
               window_seconds: 600
             ) == 2
    end

    test "an explicit option short-circuits the bundle" do
      record = record(restart_pod_action("galley-d7c6bc75c-fs89f"))
      assert Real.pre_incident_restarts(record, pre_incident_restarts: 7) == 7
    end

    test "an unreadable bundle tolerates no restarts" do
      record = record(restart_pod_action("x"), "no-such-incident")
      assert Real.pre_incident_restarts(record, incidents_root: @fixtures) == 0
    end
  end
end
