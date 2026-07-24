defmodule Kubeybilly.Soundings.LabelSelector do
  @moduledoc """
  Label selector arithmetic shared by the collector and the baseline.

  Kubernetes expresses "which pods belong to this workload" and "which pods
  does this Service route to" as label maps; this module renders them as
  API selector strings and evaluates matches, in one place, so the two
  soundings modules cannot drift apart in how they interpret ownership.
  """

  @doc """
  Render a `matchLabels` map as a label selector string.

  Sorted for determinism, nil when there is nothing to select on, because
  an empty selector string would select everything, which is never what
  evidence collection wants.
  """
  @spec from_match_labels(map() | nil) :: String.t() | nil
  def from_match_labels(labels) when is_map(labels) and map_size(labels) > 0 do
    labels
    |> Enum.sort()
    |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)
  end

  def from_match_labels(_labels), do: nil

  @doc "The selector string of a workload's `spec.selector.matchLabels`."
  @spec workload_selector(map()) :: String.t() | nil
  def workload_selector(workload) do
    workload |> get_in(["spec", "selector", "matchLabels"]) |> from_match_labels()
  end

  @doc """
  Whether a Service-style selector selects the given labels.

  Every selector pair must be present; an empty or missing selector selects
  nothing (a selectorless Service points at external endpoints and is not
  part of the workload's blast radius).
  """
  @spec selects?(map() | nil, map()) :: boolean()
  def selects?(selector, labels) when is_map(selector) and map_size(selector) > 0 do
    Enum.all?(selector, fn {key, value} -> Map.get(labels, key) == value end)
  end

  def selects?(_selector, _labels), do: false
end
