defmodule Kubeybilly.Verification.Poller do
  @moduledoc """
  The timing skeleton of a verification window, and nothing else.

  Judgment lives in the predicates and observation modules; this module
  only owns "poll a function on an interval until the window expires or
  the function reaches a decision". Keeping the loop free of cluster
  knowledge lets its deadline arithmetic be tested with millisecond
  intervals while the real verifier runs the same code at the plan's
  window-scaled cadence (a tenth of the window, floored at 2 seconds).
  """

  @typedoc "What the polled function returns: decide now, or carry state forward."
  @type decision(result, acc) :: {:halt, result} | {:cont, acc}

  @doc """
  Poll `fun` until it halts or the window expires.

  `fun` receives the 1-based poll number and the accumulator. Options:

    * `:window_ms` (required) - total window length
    * `:poll_interval_ms` - interval between polls, defaulting to
      `default_interval_ms(window_ms)`; tests shrink it to milliseconds

  The first poll happens immediately; a poll whose next sleep would end
  past the deadline expires instead, so the loop never outlives the
  window it was given.
  """
  @spec run(acc, (pos_integer(), acc -> decision(result, acc)), keyword()) ::
          {:halted, result, pos_integer()} | {:expired, acc, pos_integer()}
        when acc: term(), result: term()
  def run(acc, fun, opts) when is_function(fun, 2) do
    window_ms = Keyword.fetch!(opts, :window_ms)

    interval_ms =
      Keyword.get_lazy(opts, :poll_interval_ms, fn -> default_interval_ms(window_ms) end)

    deadline = System.monotonic_time(:millisecond) + window_ms
    loop(acc, fun, interval_ms, deadline, 1)
  end

  @doc """
  The plan's poll interval for a window: `max(window / 10, 2)` seconds.

  Scales down with the window (a 20 second demo window polls every 2
  seconds, the default 90 second window every 9) so both configurations
  see roughly ten polls.
  """
  @spec default_interval_ms(pos_integer()) :: pos_integer()
  def default_interval_ms(window_ms) do
    window_ms |> div(1000) |> div(10) |> max(2) |> Kernel.*(1000)
  end

  defp loop(acc, fun, interval_ms, deadline, poll) do
    case fun.(poll, acc) do
      {:halt, result} ->
        {:halted, result, poll}

      {:cont, acc} ->
        if System.monotonic_time(:millisecond) + interval_ms >= deadline do
          {:expired, acc, poll}
        else
          Process.sleep(interval_ms)
          loop(acc, fun, interval_ms, deadline, poll + 1)
        end
    end
  end
end
