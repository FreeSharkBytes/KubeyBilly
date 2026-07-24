defmodule KubeybillyWeb.AlertControllerTest do
  use KubeybillyWeb.ConnCase, async: false

  @moduledoc """
  The ingest door: Alertmanager v4 webhook payloads and the manual
  trigger both land here. The controller validates shape, checks the
  bearer token when one is configured, and forwards the group map to
  the correlator untouched.
  """

  @payload %{
    "version" => "4",
    "groupKey" => "{}:{alertname=\"PodCrashLooping\"}",
    "status" => "firing",
    "receiver" => "kubeybilly",
    "alerts" => [
      %{
        "status" => "firing",
        "labels" => %{"alertname" => "PodCrashLooping", "namespace" => "demo"},
        "annotations" => %{}
      }
    ]
  }

  setup do
    correlator = :"alert_controller_correlator_#{System.unique_integer([:positive])}"
    Process.register(self(), correlator)

    previous_correlator = Application.get_env(:kubeybilly, :correlator)
    previous_token = Application.get_env(:kubeybilly, :webhook_token)
    Application.put_env(:kubeybilly, :correlator, correlator)

    on_exit(fn ->
      restore(:correlator, previous_correlator)
      restore(:webhook_token, previous_token)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kubeybilly, key)
  defp restore(key, value), do: Application.put_env(:kubeybilly, key, value)

  defp post_alerts(conn, payload), do: post(conn, ~p"/api/v4/alerts", payload)

  describe "without a configured token" do
    setup do
      Application.put_env(:kubeybilly, :webhook_token, nil)
      :ok
    end

    test "accepts a valid payload and forwards the group to the correlator", %{conn: conn} do
      conn = post_alerts(conn, @payload)

      assert json_response(conn, 202) == %{"status" => "accepted"}
      assert_receive {:"$gen_cast", {:ingest, group}}
      assert group["groupKey"] == @payload["groupKey"]
      assert group["status"] == "firing"
      assert [%{"labels" => %{"alertname" => "PodCrashLooping"}}] = group["alerts"]
    end

    test "rejects a payload without a groupKey", %{conn: conn} do
      conn = post_alerts(conn, Map.delete(@payload, "groupKey"))

      assert %{"error" => "malformed_payload"} = json_response(conn, 400)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "rejects a payload with the wrong version", %{conn: conn} do
      conn = post_alerts(conn, %{@payload | "version" => "3"})

      assert %{"error" => "malformed_payload"} = json_response(conn, 400)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "rejects a payload with an unknown status", %{conn: conn} do
      conn = post_alerts(conn, %{@payload | "status" => "flapping"})

      assert %{"error" => "malformed_payload"} = json_response(conn, 400)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "rejects a payload whose alerts is not a list", %{conn: conn} do
      conn = post_alerts(conn, %{@payload | "alerts" => "nope"})

      assert %{"error" => "malformed_payload"} = json_response(conn, 400)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end
  end

  describe "with a configured token" do
    setup do
      Application.put_env(:kubeybilly, :webhook_token, "starboard-secret")
      :ok
    end

    test "accepts the payload with the right bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer starboard-secret")
        |> post_alerts(@payload)

      assert json_response(conn, 202) == %{"status" => "accepted"}
      assert_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "rejects the wrong bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong")
        |> post_alerts(@payload)

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "rejects a request with no authorization header", %{conn: conn} do
      conn = post_alerts(conn, @payload)

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end

    test "a malformed payload with a valid token is still a 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer starboard-secret")
        |> post_alerts(Map.delete(@payload, "alerts"))

      assert %{"error" => "malformed_payload"} = json_response(conn, 400)
      refute_receive {:"$gen_cast", {:ingest, _group}}
    end
  end
end
