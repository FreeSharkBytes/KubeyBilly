defmodule KubeybillyWeb.ApprovalsLiveTest do
  use KubeybillyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kubeybilly.Incident.Record

  @id "20260724T010000Z-aaaa1111"
  @workload %{kind: "Deployment", name: "checkout", uid: "uid-1"}

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:kubeybilly, :incidents_dir, previous) end)
    :ok
  end

  @moduletag :tmp_dir

  defp write_awaiting_record!(id \\ @id) do
    record =
      Record.new(%{
        id: id,
        group_key: "gk-#{id}",
        namespace: "demo",
        workload: @workload,
        signature: %{name: :crashloop_backoff, confidence: 0.92, rationale: "restarts"},
        decision: %{
          verdict: :needs_approval,
          rule_id: "tier-auto",
          chain: ["kill-switch", "scope-namespace", "tier-auto"],
          reason: "tier \"rollback\" requires approval"
        },
        action: %{
          name: :rollback_deployment,
          params: %{namespace: "demo", name: "checkout", to_revision: 4},
          inverse_class: :invertible
        }
      })

    record =
      record
      |> Record.append(:opened, %{})
      |> Record.append(:approval_requested, %{verdict: :needs_approval})

    :ok = Record.to_disk(record)
    record
  end

  # Stands in for the incident machine: registered under the machine's
  # registry key, so the LiveView's cast lands in this test's mailbox.
  defp register_as_machine!(id \\ @id) do
    {:ok, _owner} = Registry.register(Kubeybilly.Incident.Registry, {:incident, id}, nil)
    :ok
  end

  test "requires basic auth", %{conn: conn} do
    conn = get(conn, ~p"/approvals")
    assert response(conn, 401)
  end

  test "shows what would be approved before the buttons", %{conn: conn} do
    write_awaiting_record!()
    register_as_machine!()

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/approvals")

    assert html =~ @id
    assert html =~ "rollback_deployment"
    assert html =~ "to_revision"
    assert html =~ "kill-switch"
    assert html =~ "scope-namespace"
    assert html =~ "tier-auto"

    # The confirmation copy renders before the buttons in the document.
    {copy, _} = :binary.match(html, "rollback_deployment")
    {button, _} = :binary.match(html, ">Approve<")
    assert copy < button
  end

  test "an empty watch says so", %{conn: conn} do
    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/approvals")
    assert html =~ "Nothing awaiting approval"
  end

  test "an awaiting record without a live machine is not offered", %{conn: conn} do
    write_awaiting_record!()

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/approvals")
    refute html =~ ">Approve<"
  end

  test "a record not awaiting approval is not offered", %{conn: conn} do
    record =
      Record.new(%{id: @id, group_key: "gk", namespace: "demo", workload: @workload})
      |> Record.append(:opened, %{})

    :ok = Record.to_disk(record)
    register_as_machine!()

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/approvals")
    refute html =~ ">Approve<"
  end

  test "approve sends the machine's exact approval granted event", %{conn: conn} do
    write_awaiting_record!()
    register_as_machine!()

    {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/approvals")

    view
    |> element(~s{button[phx-click="approve"][phx-value-id="#{@id}"]})
    |> render_click()

    assert_receive {:"$gen_cast", {:approval, :granted}}
  end

  test "deny sends the machine's exact approval denied event", %{conn: conn} do
    write_awaiting_record!()
    register_as_machine!()

    {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/approvals")

    view
    |> element(~s{button[phx-click="deny"][phx-value-id="#{@id}"]})
    |> render_click()

    assert_receive {:"$gen_cast", {:approval, :denied}}
  end

  test "a transition broadcast reloads the list", %{conn: conn} do
    {:ok, view, html} = live(with_dashboard_auth(conn), ~p"/approvals")
    refute html =~ @id

    write_awaiting_record!()
    register_as_machine!()

    Phoenix.PubSub.broadcast(
      Kubeybilly.PubSub,
      "incidents",
      {:incident_transition, %{incident_id: @id}}
    )

    assert render(view) =~ @id
  end
end
