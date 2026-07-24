defmodule Kubeybilly.Logbook.Fields do
  @moduledoc """
  Reads record fields whether they are live structs or disk maps.

  The logbook is generated at close time from in-memory structs, but a
  record read back from `record.json` carries the same facts as plain
  string-keyed maps (Record's serialization is honest about that
  lossiness). One accessor that understands both keeps every section
  renderer free of shape checks, and means a log regenerated from disk
  is byte-identical to the one written at close.
  """

  @doc "Fetch a field from a struct, an atom-keyed map, or a string-keyed map."
  @spec get(term(), atom()) :: term()
  def get(nil, _key), do: nil
  def get(term, key) when is_struct(term), do: Map.get(term, key)

  def get(term, key) when is_map(term) do
    Map.get(term, key, Map.get(term, Atom.to_string(key)))
  end

  def get(_term, _key), do: nil

  @doc "Render a scalar as log text; atoms and strings come out identical."
  @spec text(term()) :: String.t()
  def text(nil), do: ""
  def text(value) when is_binary(value), do: value
  def text(value) when is_atom(value), do: Atom.to_string(value)
  def text(value) when is_number(value), do: to_string(value)
  def text(value), do: inspect(value)
end
