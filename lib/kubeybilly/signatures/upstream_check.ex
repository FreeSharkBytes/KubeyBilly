defmodule Kubeybilly.Signatures.UpstreamCheck do
  @moduledoc """
  Refuses to treat victims of an upstream outage as patients.

  Before any signature verdict stands, triage asks one extra deterministic
  question: does the failing workload depend on something that is itself
  down? Restarting or rolling back a service that is crashing because its
  database has no endpoints makes the outage worse, not better, so an
  upstream hit forces `no_action` regardless of what the signature
  proposed.

  This is deliberately not a matcher: it has no signature of its own and
  no confidence, it is a veto. The heuristic reads pod env values (the
  conventional way in-cluster addresses travel) and flags any value naming
  a Service the baseline's namespace-wide readiness map recorded with
  zero ready endpoints.
  """

  alias Kubeybilly.Signatures.LoadedBundle

  @doc """
  Check the bundle for a dead upstream dependency.

  Returns `:clear` when nothing referenced is down, or when the bundle
  carries no baseline to consult; a missing baseline cannot prove an
  outage, and the check must fail open or every gapped capture would be
  paralyzed.
  """
  @spec check(LoadedBundle.t()) :: {:upstream_down, String.t()} | :clear
  def check(%LoadedBundle{} = bundle) do
    down_services = zero_endpoint_services(bundle.baseline)

    if MapSet.size(down_services) == 0 do
      :clear
    else
      find_reference(bundle.pods, down_services)
    end
  end

  defp zero_endpoint_services(%{"namespace_services" => services}) when is_map(services) do
    for {name, %{"ready_endpoints" => 0}} <- services, into: MapSet.new(), do: name
  end

  defp zero_endpoint_services(_baseline), do: MapSet.new()

  defp find_reference(pods, down_services) do
    Enum.find_value(pods, :clear, fn pod ->
      case referenced_down_service(pod, down_services) do
        nil -> nil
        {env_name, service} -> {:upstream_down, reason(pod, env_name, service)}
      end
    end)
  end

  defp referenced_down_service(pod, down_services) do
    pod.spec
    |> Kernel.||(%{})
    |> get_in(["spec", "containers"])
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1["env"]))
    |> Enum.find_value(fn env ->
      if is_binary(env["value"]) and MapSet.member?(down_services, env["value"]) do
        {env["name"], env["value"]}
      end
    end)
  end

  defp reason(pod, env_name, service) do
    "Pod #{pod.namespace}/#{pod.name} depends on Service \"#{service}\" via env " <>
      "#{env_name}, and the baseline recorded it with zero ready endpoints. " <>
      "Acting on the victim of an upstream outage makes things worse; the upstream " <>
      "must recover first."
  end
end
