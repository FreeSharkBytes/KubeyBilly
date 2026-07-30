defmodule Kubeybilly.Logbook.DiagnosisTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Logbook.Diagnosis

  describe "reason_sentence/1" do
    test "explains every reason the verifier can land on" do
      for reason <- [
            :recovered_sustained,
            :window_expired,
            :polls_failed,
            :no_baseline,
            :verifier_timed_out,
            :ready_replicas_dropped,
            :blast_radius_spread,
            :restart_rate_exceeded,
            :new_alert_signature
          ] do
        sentence = Diagnosis.reason_sentence(reason)

        assert is_binary(sentence)
        refute sentence == ""
        refute sentence =~ "_"
      end
    end

    test "reads a reason that came back from disk as a string" do
      assert Diagnosis.reason_sentence("window_expired") ==
               Diagnosis.reason_sentence(:window_expired)
    end

    test "has nothing to say about a missing reason" do
      assert Diagnosis.reason_sentence(nil) == nil
      assert Diagnosis.reason_sentence("") == nil
    end

    test "prints an unrecognised reason plainly rather than hiding it" do
      assert Diagnosis.reason_sentence(:sunspots) == "sunspots"
    end
  end

  describe "unmet_lines/1" do
    test "keeps the condition name and adds the sentence beside it" do
      assert Diagnosis.unmet_lines([:rolled_to_available, "no_restarts_since_settle"]) == [
               "rolled_to_available: the ReplicaSet the rollback moved to never became " <>
                 "fully available",
               "no_restarts_since_settle: containers kept restarting after the action's own " <>
                 "rollout had settled"
             ]
    end

    test "explains every unmet condition the predicates can name" do
      conditions = [
        :action_settled,
        :ready_replicas,
        :no_restarts_since_settle,
        :service_endpoints,
        :rolled_to_available,
        :bad_replica_set_scaled_down,
        :no_successful_poll
      ]

      for {condition, line} <- Enum.zip(conditions, Diagnosis.unmet_lines(conditions)) do
        assert line =~ Atom.to_string(condition) <> ": "
        refute String.ends_with?(line, ": ")
      end
    end

    test "an unrecognised condition still gets a line" do
      assert Diagnosis.unmet_lines([:gremlins]) == ["gremlins"]
    end

    test "nothing unmet renders nothing" do
      assert Diagnosis.unmet_lines([]) == []
      assert Diagnosis.unmet_lines(nil) == []
    end
  end

  describe "poll_count/1" do
    test "counts polls in words a human would use" do
      assert Diagnosis.poll_count(1) == "1 poll"
      assert Diagnosis.poll_count(7) == "7 polls"
      assert Diagnosis.poll_count("3") == "3 polls"
    end

    test "no poll count is not a zero" do
      assert Diagnosis.poll_count(nil) == nil
      assert Diagnosis.poll_count(0) == nil
    end
  end
end
