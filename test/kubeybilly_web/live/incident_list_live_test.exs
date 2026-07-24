defmodule KubeybillyWeb.IncidentListLiveTest do
  use KubeybillyWeb.ConnCase, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest

  alias Kubeybilly.Incident.Record

  @workload %{kind: "Deployment", name: "checkout", uid: "uid-1"}

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:kubeybilly, :incidents_dir, previous) end)
    :ok
  end

  @moduletag :tmp_dir

  defp write_record!(id, fields \\ %{}) do
    {events, fields} = Map.pop(fields, :events, [])

    record =
      Record.new(
        Map.merge(
          %{id: id, group_key: "gk-#{id}", namespace: "demo", workload: @workload},
          fields
        )
      )

    record = Enum.reduce(events, record, &Record.append(&2, &1, %{}))
    :ok = Record.to_disk(record)
    record
  end

  test "the dashboard requires basic auth", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert response(conn, 401)
  end

  test "wrong credentials are rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Basic " <> Base.encode64("billy:wrong"))
      |> get(~p"/")

    assert response(conn, 401)
  end

  test "renders incidents from disk, newest first", %{conn: conn} do
    write_record!("20260724T010000Z-aaaa1111", %{
      signature: %{name: :crashloop_backoff, confidence: 0.9},
      status: :closed,
      outcome: :recovered
    })

    write_record!("20260724T020000Z-bbbb2222", %{events: [:opened]})

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/")

    assert html =~ "The Log"
    assert html =~ "20260724T010000Z-aaaa1111"
    assert html =~ "20260724T020000Z-bbbb2222"
    assert html =~ "Deployment demo/checkout"
    assert html =~ "crashloop_backoff"
    assert html =~ "recovered"

    # Newest first: the later id appears before the earlier one.
    {newer, _} = :binary.match(html, "20260724T020000Z-bbbb2222")
    {older, _} = :binary.match(html, "20260724T010000Z-aaaa1111")
    assert newer < older
  end

  test "an empty log says so", %{conn: conn} do
    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/")
    assert html =~ "No incidents in the log"
  end

  test "rows link to the incident detail page", %{conn: conn} do
    write_record!("20260724T010000Z-aaaa1111")

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/")
    assert html =~ ~s(href="/incidents/20260724T010000Z-aaaa1111")
  end

  test "a transition broadcast reloads the list", %{conn: conn} do
    {:ok, view, html} = live(with_dashboard_auth(conn), ~p"/")
    refute html =~ "20260724T030000Z-cccc3333"

    write_record!("20260724T030000Z-cccc3333")

    Phoenix.PubSub.broadcast(
      Kubeybilly.PubSub,
      "incidents",
      {:incident_transition, %{incident_id: "20260724T030000Z-cccc3333"}}
    )

    assert render(view) =~ "20260724T030000Z-cccc3333"
  end
end
