defmodule Kubeybilly.Signatures.TriageTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.LoadedBundle
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.Signatures.Triage

  # Every recorded bundle replays through triage on every run; a real
  # incident that mismatches drops into this corpus and becomes a
  # regression test.
  @replay_corpus %{
    "oomkill-galley" => :oomkilled,
    "imagepull-post-rollout" => :imagepull_post_rollout,
    "imagepull-no-rollout" => :imagepull_no_rollout,
    "crashloop-post-rollout" => :crashloop_post_rollout,
    "crashloop-stable" => :crashloop_stable,
    "readiness-post-rollout" => :readiness_post_rollout,
    "unschedulable" => :unschedulable,
    "node-not-ready" => :node_not_ready,
    "missing-config" => :missing_config,
    "upstream-down" => :upstream_down,
    "triage-priority" => :crashloop_post_rollout
  }

  describe "run/1 replay corpus" do
    for {fixture, expected} <- @replay_corpus do
      test "#{fixture} triages to #{expected}" do
        bundle = FixtureBundles.load!(unquote(fixture))

        assert {:match, %Signature{name: unquote(expected)}} = Triage.run(bundle)
      end
    end
  end

  describe "run/1 priority" do
    test "post-rollout signatures are tried before stable ones" do
      names = Enum.map(Triage.matchers(), &inspect/1)

      post_rollout_positions =
        for {name, index} <- Enum.with_index(names), name =~ "PostRollout", do: index

      stable_positions =
        for {name, index} <- Enum.with_index(names),
            name =~ "Stable" or name =~ "NoRollout",
            do: index

      assert Enum.max(post_rollout_positions) < Enum.min(stable_positions)
    end

    test "a bundle matching two signatures yields the higher-priority one" do
      bundle = FixtureBundles.load!("triage-priority")

      assert {:match, %Signature{name: :crashloop_post_rollout}} = Triage.run(bundle)
    end
  end

  describe "run/1 upstream forcing" do
    test "a dead upstream forces no_action over the signature verdict" do
      bundle = FixtureBundles.load!("upstream-down")

      assert {:match, %Signature{} = signature} = Triage.run(bundle)
      assert signature.name == :upstream_down
      assert signature.proposed_action == %{action: :no_action, params: %{}}
      assert signature.rationale =~ "zero ready endpoints"
      assert signature.evidence_refs == ["metrics/baseline.json"]
    end
  end

  describe "run/1 no match" do
    @tag :tmp_dir
    test "an empty bundle routes to the advisor as :no_match", %{tmp_dir: tmp_dir} do
      {:ok, bundle} = LoadedBundle.load(tmp_dir)

      assert Triage.run(bundle) == :no_match
    end
  end

  describe "run/1 telemetry" do
    setup do
      handler_id = "triage-test-#{inspect(self())}"

      :telemetry.attach_many(
        handler_id,
        [
          [:kubeybilly, :signatures, :matcher],
          [:kubeybilly, :signatures, :triage]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "emits one event per matcher evaluation and a triage event with the match" do
      bundle = FixtureBundles.load!("oomkill-galley")

      assert {:match, %Signature{name: :oomkilled}} = Triage.run(bundle)

      assert_received {:telemetry, [:kubeybilly, :signatures, :matcher], %{duration: _},
                       %{
                         matcher: Kubeybilly.Signatures.ImagepullPostRollout,
                         result: :no_match,
                         incident_id: "m1-20260724T050431Z"
                       }}

      assert_received {:telemetry, [:kubeybilly, :signatures, :matcher], %{duration: _},
                       %{matcher: Kubeybilly.Signatures.Oomkilled, result: :match}}

      assert_received {:telemetry, [:kubeybilly, :signatures, :triage],
                       %{matchers_evaluated: evaluated},
                       %{matched: :oomkilled, incident_id: "m1-20260724T050431Z"}}

      assert evaluated > 0
    end

    test "an unmatched bundle emits a triage event with :no_match" do
      {:ok, bundle} = LoadedBundle.load("test/fixtures/incidents/node-not-ready")
      bundle = %{bundle | nodes: %{}}

      assert Triage.run(bundle) == :no_match

      assert_received {:telemetry, [:kubeybilly, :signatures, :triage], _measurements,
                       %{matched: :no_match}}
    end
  end
end
