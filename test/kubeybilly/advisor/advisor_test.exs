defmodule Kubeybilly.AdvisorTest do
  # The facade resolves its adapter from the application environment,
  # which these tests rewrite per case; async would race that global.
  use ExUnit.Case, async: false

  import Mox

  alias Kubeybilly.Advisor
  alias Kubeybilly.Advisor.AdapterMock
  alias Kubeybilly.Advisor.Proposal

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

  defp valid_raw(confidence) do
    %{
      "action" => "restart_pod",
      "params" => %{"namespace" => "demo", "name" => "galley-1"},
      "confidence" => confidence,
      "rationale" => "restart clears the wedged state"
    }
  end

  defp attach_telemetry(event) do
    name = "advisor-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      name,
      event,
      fn ^event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  describe "propose/1 with a well-formed adapter answer" do
    test "validates it into a proposal" do
      expect(AdapterMock, :propose, fn %{"signature" => "none"} ->
        {:ok, valid_raw(0.5)}
      end)

      assert {:ok, %Proposal{action: :restart_pod, confidence: 0.5}} =
               Advisor.propose(%{"signature" => "none"})
    end

    test "caps confidence at 0.7 regardless of the model's claim" do
      expect(AdapterMock, :propose, fn _summary -> {:ok, valid_raw(0.95)} end)

      assert {:ok, %Proposal{confidence: 0.7}} = Advisor.propose(%{})
    end

    test "caps a struct answer too, so no adapter can bypass the cap" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok,
         %Proposal{
           action: :cordon_node,
           params: %{name: "node-1"},
           confidence: 1.0,
           rationale: "node is NotReady"
         }}
      end)

      assert {:ok, %Proposal{action: :cordon_node, confidence: 0.7}} = Advisor.propose(%{})
    end

    test "leaves confidence below the cap untouched" do
      expect(AdapterMock, :propose, fn _summary -> {:ok, valid_raw(0.7)} end)

      assert {:ok, %Proposal{confidence: 0.7}} = Advisor.propose(%{})
    end

    test "emits telemetry with outcome :ok" do
      attach_telemetry([:kubeybilly, :advisor, :propose])
      expect(AdapterMock, :propose, fn _summary -> {:ok, valid_raw(0.95)} end)

      {:ok, _proposal} = Advisor.propose(%{})

      assert_receive {:telemetry, [:kubeybilly, :advisor, :propose], %{confidence: 0.7},
                      %{outcome: :ok, action: :restart_pod, adapter: AdapterMock}}
    end
  end

  describe "propose/1 with an invalid adapter answer" do
    test "an out-of-formulary action becomes the no_action fallback" do
      expect(AdapterMock, :propose, fn _summary ->
        {:ok, Map.put(valid_raw(0.5), "action", "delete_namespace")}
      end)

      assert {:ok, %Proposal{} = proposal} = Advisor.propose(%{})
      assert proposal.action == :no_action
      assert proposal.params == %{reason: "model_output_invalid"}
      assert proposal.confidence == 0.0
      assert proposal.rationale =~ "action"
    end

    test "a malformed shape becomes the no_action fallback" do
      expect(AdapterMock, :propose, fn _summary -> {:ok, "kubectl delete ns demo"} end)

      assert {:ok, %Proposal{action: :no_action, confidence: +0.0}} = Advisor.propose(%{})
    end

    test "an adapter that gave up after its retry becomes the no_action fallback" do
      expect(AdapterMock, :propose, fn _summary ->
        {:error, {:model_output_invalid, %{missing: [:action]}}}
      end)

      assert {:ok, %Proposal{} = proposal} = Advisor.propose(%{})
      assert proposal.action == :no_action
      assert proposal.params == %{reason: "model_output_invalid"}
      assert proposal.rationale =~ "missing"
    end

    test "emits telemetry with outcome :fallback" do
      attach_telemetry([:kubeybilly, :advisor, :propose])
      expect(AdapterMock, :propose, fn _summary -> {:ok, %{}} end)

      {:ok, _proposal} = Advisor.propose(%{})

      assert_receive {:telemetry, [:kubeybilly, :advisor, :propose], %{confidence: +0.0},
                      %{outcome: :fallback, action: :no_action}}
    end
  end

  describe "propose/1 with an adapter error" do
    test "passes transport-level errors through unchanged" do
      expect(AdapterMock, :propose, fn _summary -> {:error, :no_api_key} end)

      assert {:error, :no_api_key} = Advisor.propose(%{})
    end

    test "emits telemetry with outcome :error" do
      attach_telemetry([:kubeybilly, :advisor, :propose])
      expect(AdapterMock, :propose, fn _summary -> {:error, {:transport, :timeout}} end)

      {:error, _reason} = Advisor.propose(%{})

      assert_receive {:telemetry, [:kubeybilly, :advisor, :propose], %{confidence: +0.0},
                      %{outcome: :error, reason: {:transport, :timeout}}}
    end
  end

  describe "narrate/1" do
    test "passes a narrative through" do
      expect(AdapterMock, :narrate, fn %{"incident_id" => "inc-1"} ->
        {:ok, "The galley deployment crashed after the 14:02 rollout."}
      end)

      assert {:ok, "The galley deployment crashed" <> _rest} =
               Advisor.narrate(%{"incident_id" => "inc-1"})
    end

    test "rejects a non-binary narrative" do
      expect(AdapterMock, :narrate, fn _record -> {:ok, %{"story" => "nope"}} end)

      assert {:error, {:invalid_narrative, %{"story" => "nope"}}} = Advisor.narrate(%{})
    end

    test "passes errors through unchanged" do
      expect(AdapterMock, :narrate, fn _record -> {:error, :no_api_key} end)

      assert {:error, :no_api_key} = Advisor.narrate(%{})
    end

    test "emits telemetry on success and on failure" do
      attach_telemetry([:kubeybilly, :advisor, :narrate])

      expect(AdapterMock, :narrate, fn _record -> {:ok, "Short story."} end)
      {:ok, _narrative} = Advisor.narrate(%{})

      assert_receive {:telemetry, [:kubeybilly, :advisor, :narrate], %{bytes: 12},
                      %{outcome: :ok, adapter: AdapterMock}}

      expect(AdapterMock, :narrate, fn _record -> {:error, {:http_status, 500}} end)
      {:error, _reason} = Advisor.narrate(%{})

      assert_receive {:telemetry, [:kubeybilly, :advisor, :narrate], %{bytes: 0},
                      %{outcome: :error, reason: {:http_status, 500}}}
    end
  end

  describe "adapter resolution" do
    test "uses the stub configured as the default adapter" do
      original = Application.fetch_env!(:kubeybilly, :advisor)

      Application.put_env(
        :kubeybilly,
        :advisor,
        Keyword.put(original, :adapter, Kubeybilly.Advisor.Stub)
      )

      assert {:ok, %Proposal{action: :no_action} = proposal} = Advisor.propose(%{})
      assert proposal.rationale =~ "stub"
      assert {:ok, narrative} = Advisor.narrate(%{})
      assert narrative =~ "stub"
    end
  end
end
