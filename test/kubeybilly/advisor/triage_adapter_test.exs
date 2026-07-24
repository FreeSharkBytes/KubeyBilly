defmodule Kubeybilly.Advisor.TriageAdapterTest do
  # The facade resolves its adapter from the application environment,
  # which these tests rewrite per case; async would race that global.
  use ExUnit.Case, async: false

  import Mox

  alias Kubeybilly.Advisor.AdapterMock
  alias Kubeybilly.Advisor.TriageAdapter
  alias Kubeybilly.FixtureBundles
  alias Kubeybilly.Signatures.Signature

  setup :verify_on_exit!

  setup do
    original = Application.fetch_env!(:kubeybilly, :advisor)

    Application.put_env(
      :kubeybilly,
      :advisor,
      Keyword.put(original, :adapter, AdapterMock)
    )

    on_exit(fn -> Application.put_env(:kubeybilly, :advisor, original) end)
    :ok
  end

  defp raw(action, params, confidence \\ 0.6) do
    %{
      "action" => action,
      "params" => params,
      "confidence" => confidence,
      "rationale" => "the model saw a wedge"
    }
  end

  describe "the bundle summary" do
    test "carries compact facts and never raw logs" do
      bundle = FixtureBundles.load!("imagepull-post-rollout")
      log_content = bundle.pods |> hd() |> Map.fetch!(:logs_current)
      parent = self()

      expect(AdapterMock, :propose, fn summary ->
        send(parent, {:summary, summary})
        {:error, :not_under_test}
      end)

      assert :no_match = TriageAdapter.advise(bundle)
      assert_receive {:summary, summary}

      assert summary.namespace == "demo"
      assert summary.workload == %{kind: "Deployment", name: "web", namespace: "demo"}
      assert "ImagePullBackOff" in summary.waiting_reasons
      assert %{"web-9f8d7c6b5-aaaaa" => 0} = summary.restart_counts
      assert is_list(summary.recent_event_reasons)
      assert "Scheduled" in summary.recent_event_reasons
      assert summary.gaps == []

      refute inspect(summary) =~ String.slice(log_content || "", 0, 20)
    end

    test "caps the event reasons list" do
      bundle = FixtureBundles.load!("imagepull-post-rollout")

      noisy = %{
        bundle
        | events: %{
            "demo" => for(n <- 1..100, do: %{"reason" => "Reason#{n}", "type" => "Warning"})
          }
      }

      expect(AdapterMock, :propose, fn summary ->
        assert length(summary.recent_event_reasons) <= 20
        {:error, :not_under_test}
      end)

      assert :no_match = TriageAdapter.advise(noisy)
    end

    test "reports capture gaps from the manifest" do
      bundle = FixtureBundles.load!("imagepull-post-rollout")

      gapped =
        put_in(bundle.manifest["gaps"], [%{"path" => "pods/demo/web-1/logs-previous.txt"}])

      expect(AdapterMock, :propose, fn summary ->
        assert summary.gaps == ["pods/demo/web-1/logs-previous.txt"]
        {:error, :not_under_test}
      end)

      assert :no_match = TriageAdapter.advise(gapped)
    end
  end

  describe "converting proposals to the machine's seam" do
    test "a mitigation proposal becomes an advisor_proposed signature" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok, raw("cordon_node", %{"node" => "worker-1"}, 0.95)}
      end)

      bundle = FixtureBundles.load!("imagepull-post-rollout")

      assert {:match, %Signature{} = signature} = TriageAdapter.advise(bundle)
      assert signature.name == :advisor_proposed
      # The facade caps model confidence at 0.7; the seam must not undo that.
      assert signature.confidence == 0.7
      assert signature.proposed_action == %{action: :cordon_node, params: %{node: "worker-1"}}
      assert signature.rationale == "advisor: the model saw a wedge"
    end

    test "known param keys are atomized so the intent adapter understands them" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok,
         raw("rollback_deployment", %{
           "namespace" => "demo",
           "name" => "web",
           "revision" => 1
         })}
      end)

      bundle = FixtureBundles.load!("imagepull-post-rollout")

      assert {:match, %Signature{proposed_action: proposed}} = TriageAdapter.advise(bundle)
      assert proposed.params == %{namespace: "demo", name: "web", revision: 1}
    end

    test "unknown param keys stay strings, so validation can reject them" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok, raw("cordon_node", %{"node" => "worker-1", "force" => true})}
      end)

      bundle = FixtureBundles.load!("imagepull-post-rollout")

      assert {:match, %Signature{proposed_action: proposed}} = TriageAdapter.advise(bundle)
      assert proposed.params == %{:node => "worker-1", "force" => true}
    end

    test "a no_action proposal is :no_match" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok, raw("no_action", %{"reason" => "nothing safe to do"})}
      end)

      assert :no_match =
               TriageAdapter.advise(FixtureBundles.load!("imagepull-post-rollout"))
    end

    test "a malformed model answer collapses to :no_match via the facade fallback" do
      expect(AdapterMock, :propose, fn _summary -> {:ok, "kubectl delete ns demo"} end)

      assert :no_match =
               TriageAdapter.advise(FixtureBundles.load!("imagepull-post-rollout"))
    end

    test "a transport error is :no_match" do
      expect(AdapterMock, :propose, fn _summary -> {:error, {:transport, :timeout}} end)

      assert :no_match =
               TriageAdapter.advise(FixtureBundles.load!("imagepull-post-rollout"))
    end
  end
end
