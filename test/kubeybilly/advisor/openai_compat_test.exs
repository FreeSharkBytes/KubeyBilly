defmodule Kubeybilly.Advisor.OpenAICompatTest do
  # The adapter reads its endpoint from the application environment and
  # its key from a real env var; both are globals, so no async.
  use ExUnit.Case, async: false

  alias Kubeybilly.Advisor.OpenAICompat
  alias Kubeybilly.Advisor.Proposal

  @req_test OpenAICompat
  @api_key_env "ADVISOR_TEST_API_KEY"

  @summary %{"signature" => "none", "namespace" => "demo", "workload" => "galley"}
  @record %{"incident_id" => "inc-1", "verdict" => "rolled back"}

  @valid_content %{
    "action" => "restart_pod",
    "params" => %{"namespace" => "demo", "name" => "galley-1"},
    "confidence" => 0.6,
    "rationale" => "the pod is wedged and a restart clears it"
  }

  setup do
    original = Application.fetch_env!(:kubeybilly, :advisor)

    Application.put_env(:kubeybilly, :advisor,
      adapter: OpenAICompat,
      base_url: "https://advisor.test/v1",
      model: "test-model",
      api_key_env: @api_key_env,
      timeout_ms: 50,
      req_options: [plug: {Req.Test, @req_test}]
    )

    System.put_env(@api_key_env, "test-key")

    on_exit(fn ->
      Application.put_env(:kubeybilly, :advisor, original)
      System.delete_env(@api_key_env)
    end)

    :ok
  end

  defp completion(conn, content) do
    Req.Test.json(conn, %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
    })
  end

  defp decoded_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  describe "propose/1 with a valid response" do
    test "returns the validated proposal" do
      Req.Test.stub(@req_test, fn conn ->
        completion(conn, Jason.encode!(@valid_content))
      end)

      assert {:ok, %Proposal{action: :restart_pod, confidence: 0.6}} =
               OpenAICompat.propose(@summary)
    end

    test "sends one JSON-mode chat completion with the formulary constraint" do
      parent = self()

      Req.Test.stub(@req_test, fn conn ->
        send(
          parent,
          {:request, conn.method, conn.request_path, conn.req_headers, decoded_body(conn)}
        )

        completion(conn, Jason.encode!(@valid_content))
      end)

      {:ok, _proposal} = OpenAICompat.propose(@summary)

      assert_receive {:request, "POST", "/v1/chat/completions", headers, body}
      assert {"authorization", "Bearer test-key"} in headers
      assert body["model"] == "test-model"
      assert body["response_format"] == %{"type" => "json_object"}

      assert [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => user}] =
               body["messages"]

      for action <- Proposal.formulary() do
        assert system =~ Atom.to_string(action)
      end

      assert system =~ "ONLY"
      assert system =~ "confidence"
      assert user =~ "galley"
    end
  end

  describe "propose/1 retry discipline" do
    test "an invalid response is retried once with the validation error appended" do
      parent = self()

      Req.Test.expect(@req_test, fn conn ->
        completion(conn, "not json at all")
      end)

      Req.Test.expect(@req_test, fn conn ->
        send(parent, {:retry_body, decoded_body(conn)})
        completion(conn, Jason.encode!(@valid_content))
      end)

      assert {:ok, %Proposal{action: :restart_pod}} = OpenAICompat.propose(@summary)

      assert_receive {:retry_body, body}
      assert [_system, _user, assistant, correction] = body["messages"]
      assert assistant == %{"role" => "assistant", "content" => "not json at all"}
      assert correction["role"] == "user"
      assert correction["content"] =~ "invalid_json"
    end

    test "a schema-invalid retry carries the named schema faults" do
      parent = self()

      Req.Test.expect(@req_test, fn conn ->
        completion(conn, Jason.encode!(%{"action" => "delete_namespace"}))
      end)

      Req.Test.expect(@req_test, fn conn ->
        send(parent, {:retry_body, decoded_body(conn)})
        completion(conn, Jason.encode!(@valid_content))
      end)

      assert {:ok, %Proposal{}} = OpenAICompat.propose(@summary)

      assert_receive {:retry_body, body}
      assert [_system, _user, _assistant, correction] = body["messages"]
      assert correction["content"] =~ "action"
    end

    test "two invalid responses give up with model_output_invalid, never a third call" do
      counter = :counters.new(1, [])

      Req.Test.stub(@req_test, fn conn ->
        :counters.add(counter, 1, 1)
        completion(conn, "still not json")
      end)

      assert {:error, {:model_output_invalid, {:invalid_json, _detail}}} =
               OpenAICompat.propose(@summary)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "propose/1 transport and endpoint failures" do
    test "an HTTP 500 is an error, not a retry" do
      counter = :counters.new(1, [])

      Req.Test.stub(@req_test, fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 500, "upstream exploded")
      end)

      assert {:error, {:http_status, 500}} = OpenAICompat.propose(@summary)
      assert :counters.get(counter, 1) == 1
    end

    test "a timeout surfaces as a transport error" do
      Req.Test.stub(@req_test, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transport, :timeout}} = OpenAICompat.propose(@summary)
    end

    test "a missing API key never makes an HTTP call" do
      System.delete_env(@api_key_env)

      Req.Test.stub(@req_test, fn _conn ->
        flunk("no HTTP call may happen without a key")
      end)

      assert {:error, :no_api_key} = OpenAICompat.propose(@summary)
    end

    test "an empty API key counts as missing" do
      System.put_env(@api_key_env, "")

      assert {:error, :no_api_key} = OpenAICompat.propose(@summary)
    end

    test "a response without choices gives up after the retry" do
      Req.Test.stub(@req_test, fn conn ->
        Req.Test.json(conn, %{"choices" => []})
      end)

      assert {:error, {:model_output_invalid, :missing_content}} =
               OpenAICompat.propose(@summary)
    end
  end

  describe "narrate/1" do
    test "returns the completion content as the narrative" do
      Req.Test.stub(@req_test, fn conn ->
        completion(conn, "The galley deployment crashed after the 14:02 rollout.")
      end)

      assert {:ok, "The galley deployment crashed" <> _rest} = OpenAICompat.narrate(@record)
    end

    test "sends a plain prose request without JSON mode" do
      parent = self()

      Req.Test.stub(@req_test, fn conn ->
        send(parent, {:request_body, decoded_body(conn)})
        completion(conn, "Short story.")
      end)

      {:ok, _narrative} = OpenAICompat.narrate(@record)

      assert_receive {:request_body, body}
      refute Map.has_key?(body, "response_format")
      assert [%{"role" => "system"}, %{"role" => "user", "content" => user}] = body["messages"]
      assert user =~ "inc-1"
    end

    test "a missing API key never makes an HTTP call" do
      System.delete_env(@api_key_env)

      assert {:error, :no_api_key} = OpenAICompat.narrate(@record)
    end

    test "an HTTP 500 is an error" do
      Req.Test.stub(@req_test, fn conn ->
        Plug.Conn.send_resp(conn, 500, "upstream exploded")
      end)

      assert {:error, {:http_status, 500}} = OpenAICompat.narrate(@record)
    end

    test "a response without content is model_output_invalid" do
      Req.Test.stub(@req_test, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"role" => "assistant"}}]})
      end)

      assert {:error, {:model_output_invalid, :missing_content}} = OpenAICompat.narrate(@record)
    end
  end
end
