defmodule Kubeybilly.Verification.PollerTest do
  use ExUnit.Case, async: true

  alias Kubeybilly.Verification.Poller

  describe "default_interval_ms/1" do
    test "is a tenth of the window in whole seconds" do
      assert Poller.default_interval_ms(90_000) == 9_000
      assert Poller.default_interval_ms(100_000) == 10_000
    end

    test "floors at 2 seconds so short demo windows still poll sanely" do
      assert Poller.default_interval_ms(20_000) == 2_000
      assert Poller.default_interval_ms(5_000) == 2_000
      assert Poller.default_interval_ms(1_000) == 2_000
    end
  end

  describe "run/3 early decision" do
    test "halts on the first poll when the function decides immediately" do
      assert {:halted, :decided, 1} =
               Poller.run(:acc, fn 1, :acc -> {:halt, :decided} end,
                 window_ms: 1_000,
                 poll_interval_ms: 1
               )
    end

    test "threads the accumulator between polls and halts mid-window" do
      fun = fn
        poll, acc when poll < 3 -> {:cont, acc + 1}
        3, acc -> {:halt, {:done, acc}}
      end

      assert {:halted, {:done, 2}, 3} =
               Poller.run(0, fun, window_ms: 10_000, poll_interval_ms: 1)
    end
  end

  describe "run/3 expiry" do
    test "expires with the last accumulator when no poll decides" do
      assert {:expired, acc, polls} =
               Poller.run(0, fn _poll, acc -> {:cont, acc + 1} end,
                 window_ms: 40,
                 poll_interval_ms: 10
               )

      assert acc == polls
      assert polls >= 2
    end

    test "a window shorter than one interval still gets exactly one poll" do
      assert {:expired, 1, 1} =
               Poller.run(0, fn _poll, acc -> {:cont, acc + 1} end,
                 window_ms: 5,
                 poll_interval_ms: 50
               )
    end

    test "never sleeps past the deadline" do
      started = System.monotonic_time(:millisecond)

      {:expired, _acc, _polls} =
        Poller.run(0, fn _poll, acc -> {:cont, acc + 1} end,
          window_ms: 50,
          poll_interval_ms: 10
        )

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 500
    end
  end
end
