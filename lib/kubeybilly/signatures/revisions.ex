defmodule Kubeybilly.Signatures.Revisions do
  @moduledoc """
  Reads Deployment rollout history out of a bundle's captured ReplicaSets.

  Four signatures hinge on the same question, "what did the newest revision
  change relative to the one before it?", so the ReplicaSet bookkeeping
  (revision annotations, template images, creation timestamps, template
  hashes) lives here once instead of being re-derived in every matcher.
  """

  alias Kubeybilly.Signatures.LoadedBundle

  @revision_annotation "deployment.kubernetes.io/revision"
  @template_hash_label "pod-template-hash"

  @typedoc "The newest revision and its predecessor, with the owner they belong to."
  @type rollout :: %{owner: LoadedBundle.owner(), newest: map(), previous: map()}

  @doc """
  The newest and previous revision of the first owner with a usable history.

  `:error` means there is nothing to correlate against or roll back to: no
  owner, no revision list, or a single revision (an initial deploy has no
  known-good predecessor).
  """
  @spec newest_and_previous(LoadedBundle.t()) :: {:ok, rollout()} | :error
  def newest_and_previous(%LoadedBundle{owners: owners}) do
    Enum.find_value(owners, :error, fn owner ->
      case sorted_revisions(owner) do
        [newest, previous | _rest] ->
          {:ok, %{owner: owner, newest: newest, previous: previous}}

        _too_few ->
          nil
      end
    end)
  end

  @doc "The revision number from the ReplicaSet's Deployment annotation."
  @spec number(map()) :: integer() | nil
  def number(replica_set) do
    with annotation when is_binary(annotation) <-
           get_in(replica_set, ["metadata", "annotations", @revision_annotation]),
         {revision, ""} <- Integer.parse(annotation) do
      revision
    else
      _other -> nil
    end
  end

  @doc "The set of container images in the ReplicaSet's pod template."
  @spec images(map()) :: MapSet.t(String.t())
  def images(replica_set) do
    replica_set
    |> get_in(["spec", "template", "spec", "containers"])
    |> List.wrap()
    |> Enum.map(& &1["image"])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc "When the ReplicaSet was created, which is when its revision rolled out."
  @spec created_at(map()) :: {:ok, DateTime.t()} | :error
  def created_at(replica_set) do
    with stamp when is_binary(stamp) <-
           get_in(replica_set, ["metadata", "creationTimestamp"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
      {:ok, at}
    else
      _other -> :error
    end
  end

  @doc "The pod-template-hash label linking pods to their ReplicaSet."
  @spec template_hash(map()) :: String.t() | nil
  def template_hash(replica_set) do
    get_in(replica_set, ["metadata", "labels", @template_hash_label])
  end

  @doc "Ready replica count the ReplicaSet reported at capture time."
  @spec ready_replicas(map()) :: non_neg_integer()
  def ready_replicas(replica_set) do
    get_in(replica_set, ["status", "readyReplicas"]) || 0
  end

  defp sorted_revisions(%{revisions: revisions}) do
    revisions
    |> List.wrap()
    |> Enum.filter(&number/1)
    |> Enum.sort_by(&number/1, :desc)
  end
end
