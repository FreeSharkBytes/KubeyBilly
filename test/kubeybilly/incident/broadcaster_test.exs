defmodule Kubeybilly.Incident.BroadcasterTest do
  use ExUnit.Case, async: false

  alias Kubeybilly.Incident.Broadcaster

  test "the topic is the documented incidents topic" do
    assert Broadcaster.topic() == "incidents"
  end

  test "attach is idempotent" do
    assert Broadcaster.attach() == :ok
    assert Broadcaster.attach() == :ok
  end

  test "a machine transition is broadcast to subscribers" do
    Broadcaster.attach()
    Phoenix.PubSub.subscribe(Kubeybilly.PubSub, Broadcaster.topic())

    meta = %{
      incident_id: "20260724T010000Z-aaaa1111",
      from: :gating,
      to: :awaiting_approval,
      event: :approval_requested,
      status: :open,
      outcome: nil
    }

    :telemetry.execute(
      [:kubeybilly, :incident, :transition],
      %{system_time: System.system_time()},
      meta
    )

    assert_receive {:incident_transition, ^meta}
  end

  test "a monitor interruption is broadcast to subscribers" do
    Broadcaster.attach()
    Phoenix.PubSub.subscribe(Kubeybilly.PubSub, Broadcaster.topic())

    meta = %{incident_id: "20260724T010000Z-bbbb2222"}

    :telemetry.execute(
      [:kubeybilly, :incident, :interrupted],
      %{system_time: System.system_time()},
      meta
    )

    assert_receive {:incident_transition, ^meta}
  end
end
