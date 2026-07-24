defmodule KubeybillyWeb.IncidentDetailLiveTest do
  use KubeybillyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kubeybilly.Incident.Record

  @id "20260724T010000Z-aaaa1111"
  @workload %{kind: "Deployment", name: "checkout", uid: "uid-1"}

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:kubeybilly, :incidents_dir)
    Application.put_env(:kubeybilly, :incidents_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:kubeybilly, :incidents_dir, previous) end)
    {:ok, bundle_dir: Path.join(tmp_dir, @id)}
  end

  @moduletag :tmp_dir

  defp write_record! do
    record =
      Record.new(%{
        id: @id,
        group_key: "gk-1",
        namespace: "demo",
        workload: @workload,
        signature: %{
          name: :crashloop_backoff,
          confidence: 0.92,
          rationale: "container restarted 7 times with the same exit code"
        },
        decision: %{
          verdict: :needs_approval,
          rule_id: "tier-auto",
          chain: ["kill-switch", "scope-namespace", "tier-auto"],
          reason: "tier \"rollback\" requires approval"
        },
        action: %{
          name: :rollback_deployment,
          params: %{namespace: "demo", name: "checkout", to_revision: 4},
          inverse_class: :invertible,
          inverse: %{name: :rollback_deployment, params: %{to_revision: 5}}
        },
        verification_outcome: :recovered
      })

    record =
      record
      |> Record.append(:opened, %{})
      |> Record.append(:evidence_sealed, %{files: 6})

    :ok = Record.to_disk(record)
    record
  end

  defp write_bundle!(bundle_dir) do
    File.mkdir_p!(Path.join(bundle_dir, "events"))

    manifest = %{
      "incident_id" => @id,
      "complete" => true,
      "files" => [%{"path" => "events/demo.json", "bytes" => 21, "sha256" => "aa"}],
      "gaps" => []
    }

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join([bundle_dir, "events", "demo.json"]), ~s({"kind":"EventList"}))
  end

  test "requires basic auth", %{conn: conn} do
    write_record!()
    conn = get(conn, ~p"/incidents/#{@id}")
    assert response(conn, 401)
  end

  test "renders the full record", %{conn: conn} do
    write_record!()

    {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

    # Identity and timeline
    assert html =~ @id
    assert html =~ "Deployment demo/checkout"
    assert html =~ "opened"
    assert html =~ "evidence_sealed"

    # Signature with confidence and rationale
    assert html =~ "crashloop_backoff"
    assert html =~ "0.92"
    assert html =~ "container restarted 7 times"

    # Decision rule chain
    assert html =~ "needs_approval"
    assert html =~ "kill-switch"
    assert html =~ "scope-namespace"
    assert html =~ "tier-auto"

    # Action and its inverse
    assert html =~ "rollback_deployment"
    assert html =~ "to_revision"
    assert html =~ "invertible"

    # Verification outcome
    assert html =~ "recovered"
  end

  test "an unknown incident redirects to the log", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(with_dashboard_auth(conn), ~p"/incidents/20990101T000000Z-ffffffff")
  end

  describe "evidence browser" do
    setup %{bundle_dir: bundle_dir} do
      write_record!()
      write_bundle!(bundle_dir)
      :ok
    end

    test "lists manifest files with sizes", %{conn: conn} do
      {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

      assert html =~ "events/demo.json"
      assert html =~ "21 B"
    end

    test "clicking a file shows its content inline", %{conn: conn} do
      {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

      html =
        view
        |> element(~s{button[phx-value-path="events/demo.json"]})
        |> render_click()

      assert html =~ "EventList"
    end

    test "a traversal path is rejected", %{conn: conn} do
      {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

      html = render_click(view, "select_file", %{"path" => "../../outside.txt"})
      assert html =~ "outside the bundle"
    end

    test "an oversized file is refused", %{conn: conn, bundle_dir: bundle_dir} do
      File.write!(Path.join(bundle_dir, "huge.txt"), String.duplicate("a", 100 * 1024 + 1))

      {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

      html = render_click(view, "select_file", %{"path" => "huge.txt"})
      assert html =~ "too large"
    end

    test "binary content is refused", %{conn: conn, bundle_dir: bundle_dir} do
      File.write!(Path.join(bundle_dir, "blob.bin"), <<0xFF, 0xFE, 0x00>>)

      {:ok, view, _html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")

      html = render_click(view, "select_file", %{"path" => "blob.bin"})
      assert html =~ "not a text file"
    end

    test "log.md is offered and rendered preformatted when present", %{
      conn: conn,
      bundle_dir: bundle_dir
    } do
      File.write!(Path.join(bundle_dir, "log.md"), "# Logbook\nAll hands accounted for.")

      {:ok, view, html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")
      assert html =~ "log.md"

      html =
        view
        |> element(~s{button[phx-value-path="log.md"]})
        |> render_click()

      assert html =~ "All hands accounted for."
      assert html =~ "<pre"
    end

    test "no log link when log.md is absent", %{conn: conn} do
      {:ok, _view, html} = live(with_dashboard_auth(conn), ~p"/incidents/#{@id}")
      refute html =~ ~s(phx-value-path="log.md")
    end
  end
end
