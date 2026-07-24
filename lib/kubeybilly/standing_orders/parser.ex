defmodule Kubeybilly.StandingOrders.Parser do
  @moduledoc """
  Parses and validates the standing orders YAML into a `Policy`.

  The policy file is the safety contract, so parsing is strict: unknown
  keys anywhere are rejected rather than ignored (a typo like
  `deny_kind:` must never silently weaken the policy), every action must
  come from the formulary, and an action may belong to exactly one tier
  so a decision always has one unambiguous rule path. Omitted sections
  get the documented defaults from `Policy`.

  Every failure is `{:error, {:policy, detail}}` where detail names the
  offending path and value, because a rejected policy must be fixable
  from the error alone.
  """

  alias Kubeybilly.StandingOrders.Policy

  @top_keys ~w(scope tiers budgets deny_kinds freeze_when verification approval mode)
  @scope_keys ~w(namespaces_include namespaces_exclude)
  @tier_keys ~w(actions auto min_confidence max_delta)
  @modes %{"dry_run" => :dry_run, "approve" => :approve, "auto" => :auto}

  @budget_defaults %{actions_per_incident: 2, actions_per_hour: 10, max_pods_touched: 20}
  @freeze_defaults %{rollout_in_progress: true, maintenance_window: false}
  @verification_defaults %{window_seconds: 90}
  @approval_defaults %{timeout_seconds: 300}

  @type error :: {:error, {:policy, term()}}

  @doc "Read a policy file from disk and parse it."
  @spec load(Path.t()) :: {:ok, Policy.t()} | error()
  def load(path) do
    case File.read(path) do
      {:ok, yaml} -> parse(yaml)
      {:error, reason} -> {:error, {:policy, {:unreadable, path, reason}}}
    end
  end

  @doc "Parse a policy from a YAML string."
  @spec parse(String.t()) :: {:ok, Policy.t()} | error()
  def parse(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} when is_map(doc) -> build(doc)
      {:ok, other} -> {:error, {:policy, {:invalid_document, other}}}
      {:error, error} -> {:error, {:policy, {:invalid_yaml, Exception.message(error)}}}
    end
  end

  ## Assembly

  defp build(doc) do
    with :ok <- known_keys(doc, [], @top_keys),
         {:ok, scope} <- parse_scope(Map.get(doc, "scope")),
         {:ok, tiers} <- parse_tiers(Map.get(doc, "tiers")),
         {:ok, budgets} <- section(doc, "budgets", @budget_defaults),
         {:ok, deny_kinds} <- parse_deny_kinds(Map.get(doc, "deny_kinds")),
         {:ok, freeze_when} <- section(doc, "freeze_when", @freeze_defaults),
         {:ok, verification} <- section(doc, "verification", @verification_defaults),
         {:ok, approval} <- section(doc, "approval", @approval_defaults),
         {:ok, mode} <- parse_mode(Map.get(doc, "mode")) do
      {:ok,
       %Policy{
         scope: scope,
         tiers: tiers,
         budgets: budgets,
         deny_kinds: deny_kinds,
         freeze_when: freeze_when,
         verification: verification,
         approval: approval,
         mode: mode
       }}
    end
  end

  ## Scope

  defp parse_scope(nil), do: {:ok, %{namespaces_include: [], namespaces_exclude: []}}

  defp parse_scope(scope) when is_map(scope) do
    with :ok <- known_keys(scope, ["scope"], @scope_keys),
         {:ok, include} <- namespace_list(scope, "namespaces_include"),
         {:ok, exclude} <- namespace_list(scope, "namespaces_exclude") do
      {:ok, %{namespaces_include: include, namespaces_exclude: exclude}}
    end
  end

  defp parse_scope(other), do: invalid(["scope"], other)

  defp namespace_list(scope, key) do
    case Map.get(scope, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: invalid(["scope", key], list)

      other ->
        invalid(["scope", key], other)
    end
  end

  ## Tiers

  defp parse_tiers(nil), do: {:ok, %{"read" => Policy.default_read_tier()}}

  defp parse_tiers(tiers) when is_map(tiers) do
    with {:ok, parsed} <- reduce_tiers(tiers) do
      check_duplicate_actions(parsed)
    end
  end

  defp parse_tiers(other), do: invalid(["tiers"], other)

  defp reduce_tiers(tiers) do
    Enum.reduce_while(tiers, {:ok, %{}}, fn {name, raw}, {:ok, acc} ->
      case parse_tier(name, raw) do
        {:ok, tier} -> {:cont, {:ok, Map.put(acc, name, tier)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_tier(name, raw) when is_map(raw) do
    with :ok <- known_keys(raw, ["tiers", name], @tier_keys),
         {:ok, actions} <- tier_actions(name, Map.get(raw, "actions")),
         {:ok, auto} <- tier_auto(name, Map.get(raw, "auto", false)),
         {:ok, min_confidence} <- tier_min_confidence(name, Map.get(raw, "min_confidence")),
         {:ok, max_delta} <- tier_max_delta(name, Map.get(raw, "max_delta")) do
      {:ok, %{actions: actions, auto: auto, min_confidence: min_confidence, max_delta: max_delta}}
    end
  end

  defp parse_tier(name, other), do: invalid(["tiers", name], other)

  defp tier_actions(name, actions) when is_list(actions) and actions != [] do
    Enum.reduce_while(actions, {:ok, []}, fn raw, {:ok, acc} ->
      case formulary_action(raw) do
        {:ok, action} -> {:cont, {:ok, acc ++ [action]}}
        :error -> {:halt, {:error, {:policy, {:unknown_action, name, raw}}}}
      end
    end)
  end

  defp tier_actions(name, other), do: invalid(["tiers", name, "actions"], other)

  defp formulary_action(raw) when is_binary(raw) do
    Enum.find_value(Policy.formulary_actions(), :error, fn action ->
      if Atom.to_string(action) == raw, do: {:ok, action}
    end)
  end

  defp formulary_action(_raw), do: :error

  defp tier_auto(_name, auto) when is_boolean(auto), do: {:ok, auto}
  defp tier_auto(name, other), do: invalid(["tiers", name, "auto"], other)

  defp tier_min_confidence(_name, nil), do: {:ok, nil}

  defp tier_min_confidence(_name, confidence)
       when is_number(confidence) and confidence >= 0 and confidence <= 1 do
    {:ok, confidence / 1}
  end

  defp tier_min_confidence(name, other), do: invalid(["tiers", name, "min_confidence"], other)

  defp tier_max_delta(_name, nil), do: {:ok, nil}
  defp tier_max_delta(_name, delta) when is_integer(delta) and delta > 0, do: {:ok, delta}
  defp tier_max_delta(name, other), do: invalid(["tiers", name, "max_delta"], other)

  # Plan/04 rule 5: an action must belong to exactly one tier, so a
  # decision has a single unambiguous rule path.
  defp check_duplicate_actions(tiers) do
    duplicate =
      tiers
      |> Enum.flat_map(fn {name, %{actions: actions}} -> Enum.map(actions, &{&1, name}) end)
      |> Enum.group_by(fn {action, _name} -> action end, fn {_action, name} -> name end)
      |> Enum.find(fn {_action, names} -> length(names) > 1 end)

    case duplicate do
      nil -> {:ok, tiers}
      {action, names} -> {:error, {:policy, {:duplicate_action, action, Enum.sort(names)}}}
    end
  end

  ## Deny kinds

  defp parse_deny_kinds(nil), do: {:ok, []}

  defp parse_deny_kinds(kinds) when is_list(kinds) do
    if Enum.all?(kinds, &is_binary/1),
      do: {:ok, kinds},
      else: invalid(["deny_kinds"], kinds)
  end

  defp parse_deny_kinds(other), do: invalid(["deny_kinds"], other)

  ## Mode

  defp parse_mode(nil), do: {:ok, :dry_run}

  defp parse_mode(mode) do
    case Map.fetch(@modes, mode) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:policy, {:invalid_mode, mode}}}
    end
  end

  ## Flat sections (budgets, freeze_when, verification, approval)

  # A flat section is a map of scalars whose defaults define both the
  # allowed keys and the expected type: integers stay positive integers,
  # booleans stay booleans.
  defp section(doc, key, defaults) do
    case Map.get(doc, key) do
      nil -> {:ok, defaults}
      raw when is_map(raw) -> merge_section(raw, key, defaults)
      other -> invalid([key], other)
    end
  end

  defp merge_section(raw, key, defaults) do
    allowed = Enum.map(Map.keys(defaults), &Atom.to_string/1)

    with :ok <- known_keys(raw, [key], allowed) do
      Enum.reduce_while(defaults, {:ok, %{}}, &collect_section_value(raw, key, &1, &2))
    end
  end

  defp collect_section_value(raw, key, {field, default}, {:ok, acc}) do
    case section_value(raw, key, field, default) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
      error -> {:halt, error}
    end
  end

  defp section_value(raw, key, field, default) do
    case Map.get(raw, Atom.to_string(field), default) do
      value when is_boolean(default) and is_boolean(value) -> {:ok, value}
      value when is_integer(default) and is_integer(value) and value > 0 -> {:ok, value}
      other -> invalid([key, Atom.to_string(field)], other)
    end
  end

  ## Shared

  defp known_keys(map, path, allowed) do
    case Enum.sort(Map.keys(map) -- allowed) do
      [] -> :ok
      unknown -> {:error, {:policy, {:unknown_keys, path, unknown}}}
    end
  end

  defp invalid(path, value), do: {:error, {:policy, {:invalid_value, path, value}}}
end
