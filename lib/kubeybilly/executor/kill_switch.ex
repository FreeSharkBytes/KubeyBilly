defmodule Kubeybilly.Executor.KillSwitch do
  @moduledoc """
  Mirrors the on-disk kill switch into `:persistent_term`.

  The Helm chart mounts the killswitch ConfigMap key `engaged` as a file
  (plan/04); this process polls it and mirrors the answer into a single
  `:persistent_term` key so the check on every write path is a free read
  rather than file IO or a GenServer call. Only this module writes the
  key: everyone else asks `engaged?/0`.

  A file containing `true` (trimmed) engages the switch. A missing file,
  an unreadable file, or no configured path all read as disengaged,
  because an operator who has not mounted a switch has not engaged one;
  engaging is always an explicit act.
  """

  use GenServer

  require Logger

  @key {Kubeybilly, :killswitch}
  @poll_ms 2_000
  @flip_event [:kubeybilly, :executor, :kill_switch]

  @doc """
  Start the poller.

  Options: `:path` overrides `config :kubeybilly, :killswitch_path`,
  `:poll_ms` overrides the 2 second poll, `:name` overrides (or with
  nil, suppresses) registration, as tests running beside the
  application-started instance need.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Whether the kill switch is engaged; a free `:persistent_term` read."
  @spec engaged?() :: boolean()
  def engaged?, do: :persistent_term.get(@key, false)

  @impl GenServer
  def init(opts) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Application.get_env(:kubeybilly, :killswitch_path)
      end)

    state = %{path: path, poll_ms: Keyword.get(opts, :poll_ms, @poll_ms)}
    mirror(path)
    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    mirror(state.path)
    schedule(state)
    {:noreply, state}
  end

  # No path, nothing to poll: the switch was mirrored disengaged once at
  # init and stays that way until a configured instance says otherwise.
  defp schedule(%{path: nil}), do: :ok
  defp schedule(%{poll_ms: poll_ms}), do: Process.send_after(self(), :poll, poll_ms)

  # Write only on change: `:persistent_term.put` triggers a global scan,
  # so a steady switch must cost nothing beyond the file read.
  defp mirror(path) do
    engaged = read(path)

    if engaged != engaged?() do
      :persistent_term.put(@key, engaged)
      Logger.warning("kill switch #{if engaged, do: "engaged", else: "disengaged"}")

      :telemetry.execute(@flip_event, %{system_time: System.system_time()}, %{
        engaged: engaged,
        path: path
      })
    end

    :ok
  end

  defp read(nil), do: false

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents) == "true"
      {:error, _reason} -> false
    end
  end
end
