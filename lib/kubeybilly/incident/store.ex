defmodule Kubeybilly.Incident.Store do
  @moduledoc """
  The read side of the incidents directory, for the dashboard.

  Disk is the source of truth (plan/01): every machine transition
  rewrites `record.json`, so a scan over the directory already includes
  open incidents and needs no merge with process state. The store is
  pure reads over `Kubeybilly.Incident.Record`; unreadable or foreign
  entries are skipped because a dashboard must render whatever survives,
  not crash on what does not.
  """

  alias Kubeybilly.Incident.Record

  # Events that end a stay in awaiting_approval (plan/04: a human yes,
  # a human no, or the timeout that escalates).
  @approval_exits [:approval_granted, :approval_denied, :approval_timeout]

  @doc """
  All records under the incidents directory, newest first.

  Incident ids sort chronologically by construction, so the order needs
  no timestamp parsing. `:root` overrides the configured directory.
  """
  @spec list(keyword()) :: [Record.t()]
  def list(opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Application.get_env(:kubeybilly, :incidents_dir, "incidents")
      end)

    case File.ls(root) do
      {:ok, entries} -> entries |> Enum.sort(:desc) |> Enum.flat_map(&readable(root, &1))
      {:error, _reason} -> []
    end
  end

  defp readable(root, id) do
    case Record.from_disk(id, root: root) do
      {:ok, record} -> [record]
      {:error, _reason} -> []
    end
  end

  @doc """
  Whether the record describes an incident sitting in awaiting_approval.

  True when the record is open and its latest approval-shaped event is a
  request: alert updates may append behind the request without changing
  the state, but a grant, deny, or timeout ends the wait.
  """
  @spec awaiting_approval?(Record.t()) :: boolean()
  def awaiting_approval?(%Record{status: :open, timeline: timeline}) do
    # Tagged on purpose: a bare false would read as "keep searching" to
    # find_value and let an older request shadow the grant that ended it.
    timeline
    |> Enum.reverse()
    |> Enum.find_value({:decided, false}, fn
      {_at, :approval_requested, _detail} -> {:decided, true}
      {_at, event, _detail} when event in @approval_exits -> {:decided, false}
      {_at, _event, _detail} -> nil
    end)
    |> elem(1)
  end

  def awaiting_approval?(%Record{}), do: false

  @doc "When the record last changed: the latest timeline timestamp."
  @spec updated_at(Record.t()) :: DateTime.t() | nil
  def updated_at(%Record{timeline: []}), do: nil

  def updated_at(%Record{timeline: timeline}) do
    {at, _event, _detail} = List.last(timeline)
    at
  end
end
