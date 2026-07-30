defmodule Kubeybilly.LogbookTest do
  # The narrative tests rewrite the advisor adapter and the narrate flag
  # in the application environment; async would race those globals.
  use ExUnit.Case, async: false

  @moduletag :integration

  import Mox

  alias Kubeybilly.Advisor.AdapterMock
  alias Kubeybilly.Formulary.Action
  alias Kubeybilly.Incident.Record
  alias Kubeybilly.Logbook
  alias Kubeybilly.Signatures.Signature
  alias Kubeybilly.StandingOrders.Decision

  @golden_root "test/fixtures/logbook"

  setup :verify_on_exit!

  setup do
    root =
      System.tmp_dir!()
      |> Path.join("kubeybilly-logbook-#{System.unique_integer([:positive])}")
      |> String.replace("\\", "/")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  ## Synthetic records

  defp at(time, seconds \\ 0) do
    DateTime.new!(~D[2026-07-24], Time.add(time, seconds), "Etc/UTC")
  end

  defp recovered_rollback_record do
    inverse = %Action{
      name: :rollback_deployment,
      params: %{namespace: "demo", name: "web", to_revision: "2"},
      inverse_class: :invertible
    }

    action = %Action{
      name: :rollback_deployment,
      params: %{namespace: "demo", name: "web", to_revision: 1},
      inverse: inverse,
      inverse_class: :invertible,
      blast_estimate: 2,
      facts: %{current_revision: "2"}
    }

    signature =
      Signature.new(%{
        name: :imagepull_post_rollout,
        confidence: 0.9,
        proposed_action: %{
          action: :rollback_deployment,
          params: %{namespace: "demo", name: "web", revision: 1}
        },
        rationale:
          "Containers are waiting on ImagePullBackOff and the newest ReplicaSet " <>
            "revision changed the image; the bad image arrived with the rollout.",
        evidence_refs: [
          "pods/demo/web-9f8d7c6b5-aaaaa/status.json",
          "owners/demo/web-revisions.json"
        ]
      })

    decision = %Decision{
      verdict: :permit_auto,
      rule_id: "tier-auto",
      chain: ["kill-switch", "mode", "scope", "deny-kinds", "budgets", "tier-auto"],
      reason: "the rollback tier permits automatic action at confidence 0.9",
      mode: :auto,
      budgets: %{actions_per_incident: 2, actions_per_hour: 10}
    }

    %Record{
      id: "20260724T100000Z-a1b2c3d4",
      group_key: "gk-demo-web",
      namespace: "demo",
      workload: %{kind: "Deployment", name: "web", uid: "uid-web-1"},
      pods: ["web-9f8d7c6b5-aaaaa"],
      nodes: [],
      timeline: [
        {at(~T[10:00:00]), :opened, %{}},
        {at(~T[10:00:02]), :evidence_sealed, %{}},
        {at(~T[10:00:03]), :permitted,
         %{
           verdict: :permit_auto,
           rule_id: "tier-auto",
           reason: "the rollback tier permits automatic action at confidence 0.9"
         }},
        {at(~T[10:00:04]), :executed, %{result: %{dry_run: false}}},
        {at(~T[10:01:34]), :verified_recovered,
         %{reason: :recovered_sustained, unmet: [], polls: 3}}
      ],
      signature: signature,
      decision: decision,
      action: action,
      verification_outcome: :recovered,
      status: :closed,
      outcome: :recovered
    }
  end

  defp upstream_down_record do
    rationale =
      "Pod demo/web-6c5d4b3a2-fffff depends on Service \"backend\" via env " <>
        "DATABASE_HOST, and the baseline recorded it with zero ready endpoints. " <>
        "Acting on the victim of an upstream outage makes things worse; the " <>
        "upstream must recover first."

    signature =
      Signature.new(%{
        name: :upstream_down,
        confidence: 0.9,
        proposed_action: %{action: :no_action, params: %{}},
        rationale: rationale,
        evidence_refs: ["metrics/baseline.json"]
      })

    decision = %Decision{
      verdict: :permit_auto,
      rule_id: "tier-auto",
      chain: ["kill-switch", "mode", "scope", "deny-kinds", "budgets", "tier-auto"],
      reason: "no_action is always permitted",
      mode: :dry_run,
      budgets: %{actions_per_incident: 2, actions_per_hour: 10}
    }

    action = %Action{
      name: :no_action,
      params: %{reason: rationale},
      inverse_class: :null
    }

    %Record{
      id: "20260724T110000Z-b2c3d4e5",
      group_key: "gk-demo-web-upstream",
      namespace: "demo",
      workload: %{kind: "Deployment", name: "web", uid: "uid-web-2"},
      pods: ["web-6c5d4b3a2-fffff"],
      nodes: [],
      timeline: [
        {at(~T[11:00:00]), :opened, %{}},
        {at(~T[11:00:02]), :evidence_sealed, %{}},
        {at(~T[11:00:03]), :no_action, %{rationale: rationale}}
      ],
      signature: signature,
      decision: decision,
      action: action,
      verification_outcome: nil,
      status: :closed,
      outcome: :escalated
    }
  end

  defp install_manifest(root, record, golden_dir) do
    destination = Path.join(root, record.id)
    File.mkdir_p!(destination)

    File.cp!(
      Path.join([@golden_root, golden_dir, "manifest.json"]),
      Path.join(destination, "manifest.json")
    )
  end

  defp golden(golden_dir) do
    File.read!(Path.join([@golden_root, golden_dir, "log.md"]))
  end

  ## Golden snapshots

  describe "golden logs" do
    test "a recovered rollback renders byte-identically to its golden file",
         %{root: root} do
      record = recovered_rollback_record()
      install_manifest(root, record, "recovered-rollback")

      assert {:ok, markdown} = Logbook.generate(record, root: root)
      assert markdown == golden("recovered-rollback")
      assert File.read!(Logbook.path(record.id, root: root)) == markdown
    end

    test "a declined upstream-down incident renders byte-identically to its golden file",
         %{root: root} do
      record = upstream_down_record()
      install_manifest(root, record, "declined-upstream-down")

      assert {:ok, markdown} = Logbook.generate(record, root: root)
      assert markdown == golden("declined-upstream-down")
      assert File.read!(Logbook.path(record.id, root: root)) == markdown
    end

    test "the golden logs contain no em dashes" do
      refute golden("recovered-rollback") =~ "—"
      refute golden("declined-upstream-down") =~ "—"
    end
  end

  ## Determinism across the disk round trip

  test "a record read back from disk renders the same log", %{root: root} do
    record = recovered_rollback_record()
    install_manifest(root, record, "recovered-rollback")

    assert :ok = Record.to_disk(record, root: root)
    assert {:ok, reloaded} = Record.from_disk(record.id, root: root)

    assert {:ok, from_memory} = Logbook.generate(record, root: root)
    assert {:ok, from_disk} = Logbook.generate(reloaded, root: root)
    assert from_disk == from_memory
  end

  ## Edge cases

  test "refuses an open record" do
    record = %{recovered_rollback_record() | status: :open, outcome: nil}
    assert {:error, :record_open} = Logbook.generate(record, root: "irrelevant")
  end

  test "a missing manifest is reported inside the log, not an error",
       %{root: root} do
    record = recovered_rollback_record()

    assert {:ok, markdown} = Logbook.generate(record, root: root)
    assert markdown =~ "No manifest was found"
    assert markdown =~ "Treat the evidence as incomplete."
  end

  test "capture gaps surface in soundings and as an open question", %{root: root} do
    record = %{
      upstream_down_record()
      | signature: nil,
        decision: nil,
        action: nil,
        timeline: [
          {at(~T[11:00:00]), :opened, %{}},
          {at(~T[11:00:02]), :evidence_incomplete,
           %{gaps: [%{path: "pods/demo/web-1/logs-previous.txt", reason: "http_404"}]}}
        ]
    }

    destination = Path.join(root, record.id)
    File.mkdir_p!(destination)

    manifest = %{
      "incident_id" => record.id,
      "captured_at" => "2026-07-24T11:00:01Z",
      "complete" => false,
      "files" => [],
      "gaps" => [%{"path" => "pods/demo/web-1/logs-previous.txt", "reason" => "http_404"}]
    }

    File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))

    assert {:ok, markdown} = Logbook.generate(record, root: root)
    assert markdown =~ "The capture recorded gaps:"
    assert markdown =~ "path: pods/demo/web-1/logs-previous.txt; reason: http_404"
    assert markdown =~ "The capture recorded 1 gap(s)"
    assert markdown =~ "No signature matched this incident."
    assert markdown =~ "No policy decision was reached."
    assert markdown =~ "No action was validated."
  end

  test "a budget refusal becomes an open question", %{root: root} do
    record = %{
      recovered_rollback_record()
      | decision: %Decision{
          verdict: :deny,
          rule_id: "budget-actions-per-incident",
          chain: ["kill-switch", "mode", "scope", "budget-actions-per-incident"],
          reason: "the incident spent its action budget"
        },
        verification_outcome: nil,
        outcome: :declined,
        timeline: [
          {at(~T[10:00:00]), :opened, %{}},
          {at(~T[10:00:02]), :evidence_sealed, %{}},
          {at(~T[10:00:03]), :policy_denied, %{rule_id: "budget-actions-per-incident"}}
        ]
    }

    assert {:ok, markdown} = Logbook.generate(record, root: root)
    assert markdown =~ "Rule budget-actions-per-incident refused the action"
    assert markdown =~ "No verification ran"
  end

  ## The verification diagnosis

  defp unchanged_record do
    %{
      recovered_rollback_record()
      | verification_outcome: :unchanged,
        outcome: :escalated,
        timeline: [
          {at(~T[10:00:00]), :opened, %{}},
          {at(~T[10:00:02]), :evidence_sealed, %{}},
          {at(~T[10:00:04]), :executed, %{result: %{dry_run: false}}},
          {at(~T[10:01:34]), :verified_unchanged,
           %{
             reason: :window_expired,
             unmet: [:no_restarts_since_settle, :rolled_to_available],
             polls: 7
           }}
        ]
    }
  end

  test "the verification section states the reason in prose", %{root: root} do
    assert {:ok, markdown} = Logbook.generate(unchanged_record(), root: root)

    assert markdown =~ "closed at 2026-07-24 10:01:34 (UTC), after 7 polls."
    assert markdown =~ "Why: the window expired before recovery was reached."
  end

  test "the verification section lists the unmet conditions by name", %{root: root} do
    assert {:ok, markdown} = Logbook.generate(unchanged_record(), root: root)

    assert markdown =~ "Recovery conditions still unmet when the window closed:"

    assert markdown =~
             "- no_restarts_since_settle: containers kept restarting after the action's " <>
               "own rollout had settled"

    assert markdown =~
             "- rolled_to_available: the ReplicaSet the rollback moved to never became " <>
               "fully available"
  end

  test "a recovered verification says why it was believed", %{root: root} do
    assert {:ok, markdown} = Logbook.generate(recovered_rollback_record(), root: root)

    assert markdown =~ "closed at 2026-07-24 10:01:34 (UTC), after 3 polls."
    assert markdown =~ "Why: recovery held for two consecutive polls."
    refute markdown =~ "Recovery conditions still unmet"
  end

  test "the timeline names an empty diagnosis list rather than trailing off",
       %{root: root} do
    assert {:ok, markdown} = Logbook.generate(recovered_rollback_record(), root: root)

    assert markdown =~
             "| verified recovered | polls: 3; reason: recovered_sustained; unmet: none |"
  end

  test "the escalation open question explains the verdict, not an empty parenthetical",
       %{root: root} do
    assert {:ok, markdown} = Logbook.generate(unchanged_record(), root: root)

    refute markdown =~ "()"

    assert markdown =~
             "The incident escalated on \"verified unchanged\": the window expired " <>
               "before recovery was reached, with 2 recovery conditions still unmet " <>
               "(listed under Verification). A human needs to take it from here; the " <>
               "evidence above is the handoff."
  end

  test "an escalation whose closing event carries no detail drops the parenthetical",
       %{root: root} do
    record = %{
      recovered_rollback_record()
      | verification_outcome: nil,
        outcome: :escalated,
        timeline: [
          {at(~T[10:00:00]), :opened, %{}},
          {at(~T[10:00:03]), :no_signature_match, %{}}
        ]
    }

    assert {:ok, markdown} = Logbook.generate(record, root: root)
    refute markdown =~ "()"

    assert markdown =~
             "The incident escalated on \"no signature match\". A human needs to take it " <>
               "from here"
  end

  ## Declined incidents

  defp declined_record do
    reason = "the rollback tier needs confidence 0.8 and the signature offered 0.55"

    %{
      recovered_rollback_record()
      | decision: %Decision{
          verdict: :deny,
          rule_id: "tier-min-confidence",
          chain: ["kill-switch", "mode", "scope", "deny-kinds", "budgets", "tier-min-confidence"],
          reason: reason
        },
        verification_outcome: nil,
        outcome: :declined,
        timeline: [
          {at(~T[10:00:00]), :opened, %{}},
          {at(~T[10:00:02]), :evidence_sealed, %{}},
          {at(~T[10:00:03]), :policy_denied,
           %{verdict: :deny, rule_id: "tier-min-confidence", reason: reason}}
        ]
    }
  end

  test "a declined incident hands the decision back to a human", %{root: root} do
    assert {:ok, markdown} = Logbook.generate(declined_record(), root: root)

    assert markdown =~
             "- Rule tier-min-confidence refused the proposed rollback_deployment, so " <>
               "nothing on the cluster was touched: the rollback tier needs confidence " <>
               "0.8 and the signature offered 0.55. A human decides whether to proceed " <>
               "by hand; nothing here will act on this incident again."
  end

  test "a declined incident's open questions are not only capture gaps", %{root: root} do
    assert {:ok, markdown} = Logbook.generate(declined_record(), root: root)

    refute markdown =~ "None. Nothing here is waiting on a human decision."
    assert markdown =~ "tier-min-confidence"
  end

  test "an approval denial is already a human decision, so it asks nothing",
       %{root: root} do
    record = %{
      declined_record()
      | decision: %Decision{
          verdict: :needs_approval,
          rule_id: "tier-approval",
          chain: ["tier-approval"],
          reason: "the rollback tier asks a human at confidence 0.9"
        },
        timeline: [
          {at(~T[10:00:00]), :opened, %{}},
          {at(~T[10:00:03]), :approval_requested, %{verdict: :needs_approval}},
          {at(~T[10:00:40]), :approval_denied, %{}}
        ]
    }

    assert {:ok, markdown} = Logbook.generate(record, root: root)
    refute markdown =~ "A human decides whether to proceed by hand"
  end

  ## The narrative section

  describe "narrative" do
    setup do
      original = Application.fetch_env!(:kubeybilly, :advisor)

      Application.put_env(
        :kubeybilly,
        :advisor,
        Keyword.put(original, :adapter, AdapterMock)
      )

      on_exit(fn ->
        Application.put_env(:kubeybilly, :advisor, original)
        Application.delete_env(:kubeybilly, :advisor_narrate)
      end)

      :ok
    end

    test "is appended when enabled and the advisor answers", %{root: root} do
      Application.put_env(:kubeybilly, :advisor_narrate, true)
      record = recovered_rollback_record()

      expect(AdapterMock, :narrate, fn record_map ->
        # The advisor sees the record exactly as it is persisted to disk.
        assert record_map["id"] == record.id
        assert record_map["status"] == "closed"
        {:ok, "The web deployment recovered after a rollback."}
      end)

      assert {:ok, markdown} = Logbook.generate(record, root: root)
      assert markdown =~ "## Narrative (advisor)"
      assert markdown =~ "This narrative was generated by a model."
      assert markdown =~ "The web deployment recovered after a rollback."
    end

    test "is omitted entirely when the advisor errors", %{root: root} do
      Application.put_env(:kubeybilly, :advisor_narrate, true)

      expect(AdapterMock, :narrate, fn _record_map -> {:error, {:http_status, 500}} end)

      assert {:ok, markdown} = Logbook.generate(recovered_rollback_record(), root: root)
      refute markdown =~ "Narrative"
    end

    test "is off by default: the advisor is never consulted", %{root: root} do
      assert {:ok, markdown} = Logbook.generate(recovered_rollback_record(), root: root)
      refute markdown =~ "Narrative"
    end
  end
end
