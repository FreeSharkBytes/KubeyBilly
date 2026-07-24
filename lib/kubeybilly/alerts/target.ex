defmodule Kubeybilly.Alerts.Target do
  @moduledoc """
  Extracts a workload identity from an Alertmanager alert group.

  The correlator needs a stable target to enforce one open incident per
  workload, so the extraction is a pure function over the group's alert
  labels: explicit `namespace` and `deployment` labels first, then the
  owner heuristic of stripping the ReplicaSet hash and pod suffix off a
  Deployment-shaped pod name. When labels carry no `workload_uid`, the
  identity string `namespace/kind/name` stands in: it is exactly as
  unique as the registry key needs and derivable from any redelivery of
  the same alerts.
  """

  @typedoc "The extracted target of one alert group."
  @type t :: %{
          group_key: String.t(),
          namespace: String.t(),
          workload: %{kind: String.t(), name: String.t(), uid: String.t()},
          pods: [String.t()],
          nodes: [String.t()]
        }

  @type error :: {:error, {:target, :no_alerts | :no_namespace | :no_workload}}

  @doc "Extract the target from an alertmanager-shaped group map."
  @spec extract(map()) :: {:ok, t()} | error()
  def extract(%{"groupKey" => group_key, "alerts" => [_ | _] = alerts})
      when is_binary(group_key) do
    labels = Enum.map(alerts, &Map.get(&1, "labels", %{}))

    with {:ok, namespace} <- namespace(labels),
         {:ok, {kind, name}} <- workload(labels) do
      {:ok,
       %{
         group_key: group_key,
         namespace: namespace,
         workload: %{kind: kind, name: name, uid: uid(labels, namespace, kind, name)},
         pods: values(labels, "pod"),
         nodes: values(labels, "node")
       }}
    end
  end

  def extract(_group), do: {:error, {:target, :no_alerts}}

  defp namespace(labels) do
    case first(labels, "namespace") do
      nil -> {:error, {:target, :no_namespace}}
      namespace -> {:ok, namespace}
    end
  end

  defp workload(labels) do
    deployment = first(labels, "deployment")
    owner = owner_from_pod(first(labels, "pod"))

    cond do
      deployment != nil -> {:ok, {"Deployment", deployment}}
      owner != nil -> {:ok, {"Deployment", owner}}
      true -> {:error, {:target, :no_workload}}
    end
  end

  # Deployment pods are named <deployment>-<replicaset hash>-<suffix>;
  # anything without that shape gets no guessed owner.
  defp owner_from_pod(nil), do: nil

  defp owner_from_pod(pod) do
    case String.split(pod, "-") do
      segments when length(segments) >= 3 ->
        segments |> Enum.drop(-2) |> Enum.join("-")

      _too_few ->
        nil
    end
  end

  defp uid(labels, namespace, kind, name) do
    first(labels, "workload_uid") || "#{namespace}/#{kind}/#{name}"
  end

  defp first(labels, key), do: Enum.find_value(labels, &Map.get(&1, key))

  defp values(labels, key) do
    labels
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
