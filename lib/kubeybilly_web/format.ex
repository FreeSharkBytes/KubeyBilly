defmodule KubeybillyWeb.Format do
  @moduledoc """
  Pure display helpers shared by the dashboard LiveViews.

  Records read from disk carry structured fields as string-keyed maps
  while live structs carry atoms, so every accessor here tolerates
  both: the dashboard renders whatever the record holds and never
  crashes on shape.
  """

  alias Kubeybilly.Incident.Record

  @doc "Read a field from a map that may be atom keyed or string keyed."
  @spec field(map() | nil, atom()) :: term()
  def field(nil, _key), do: nil

  def field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  @doc "One line naming the incident's target workload."
  @spec workload(Record.t()) :: String.t()
  def workload(%Record{workload: %{kind: kind, name: name}, namespace: namespace})
      when is_binary(kind) and is_binary(name) do
    "#{kind} #{namespace}/#{name}"
  end

  def workload(%Record{}), do: "unknown workload"

  @doc "A sortable UTC timestamp, or a dash for none."
  @spec stamp(DateTime.t() | nil) :: String.t()
  def stamp(nil), do: "-"

  def stamp(%DateTime{} = at) do
    Calendar.strftime(at, "%Y-%m-%d %H:%M:%SZ")
  end

  @doc "Atoms and strings as plain labels, nil as a dash."
  @spec label(atom() | String.t() | nil) :: String.t()
  def label(nil), do: "-"
  def label(value) when is_atom(value), do: Atom.to_string(value)
  def label(value) when is_binary(value), do: value

  @doc "Timeline detail as compact JSON, falling back to inspect."
  @spec detail(term()) :: String.t()
  def detail(nil), do: ""
  def detail(detail) when detail == %{}, do: ""

  def detail(detail) do
    Jason.encode!(detail)
  rescue
    _unencodable -> inspect(detail)
  end

  @doc "Human readable file sizes for the evidence browser."
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(count) when count < 1024, do: "#{count} B"
  def bytes(count) when count < 1024 * 1024, do: "#{Float.round(count / 1024, 1)} KB"
  def bytes(count), do: "#{Float.round(count / (1024 * 1024), 1)} MB"
end
