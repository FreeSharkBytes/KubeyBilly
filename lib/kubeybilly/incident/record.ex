defmodule Kubeybilly.Incident.Record do
  @moduledoc """
  The durable record of one incident, and the source of truth for boot
  recovery.

  Everything the state machine learns lands here first: the timeline of
  transitions, the matched signature, the policy decision, the validated
  action with its recorded inverse, and the verification outcome. The
  record is rewritten to `record.json` inside the incident's bundle
  directory on every transition, because the plan's crash rule
  ("KubeyBilly never resumes a mutation it cannot prove the state of")
  only works if disk always holds the latest truth: a crashed process is
  judged by what it persisted, not by what it remembered.

  Serialization is honest about lossiness: structs (signature, decision,
  action) come back from disk as plain maps and timeline details as
  decoded JSON, because a record read at boot is evidence to report, not
  runtime state to resume.
  """

  @enforce_keys [:id, :group_key, :namespace, :workload]
  defstruct [
    :id,
    :group_key,
    :namespace,
    :workload,
    pods: [],
    nodes: [],
    timeline: [],
    signature: nil,
    decision: nil,
    action: nil,
    verification_outcome: nil,
    status: :open,
    outcome: nil
  ]

  @typedoc "The workload this incident targets, keyed for the registry."
  @type workload :: %{kind: String.t(), name: String.t(), uid: String.t()}

  @typedoc "One timeline entry: when, what, and the supporting detail."
  @type event :: {DateTime.t(), atom(), term()}

  @type status :: :open | :closed
  @type outcome ::
          nil
          | :recovered
          | :escalated
          | :declined
          | :interrupted
          | :killed
          | :resolved_before_action

  @type t :: %__MODULE__{
          id: String.t(),
          group_key: String.t(),
          namespace: String.t(),
          workload: workload(),
          pods: [String.t()],
          nodes: [String.t()],
          timeline: [event()],
          signature: term(),
          decision: term(),
          action: term(),
          verification_outcome: atom() | nil,
          status: status(),
          outcome: outcome()
        }

  @outcomes [
    :recovered,
    :escalated,
    :declined,
    :interrupted,
    :killed,
    :resolved_before_action
  ]

  @statuses %{"open" => :open, "closed" => :closed}
  @outcome_names Map.new(@outcomes, &{Atom.to_string(&1), &1})
  @verification_outcomes %{
    "recovered" => :recovered,
    "unchanged" => :unchanged,
    "worse" => :worse
  }

  @record_file "record.json"

  @doc "Open a new record; enforced keys make an anonymous incident impossible."
  @spec new(map()) :: t()
  def new(fields) when is_map(fields) do
    struct!(__MODULE__, Map.merge(%{status: :open, outcome: nil}, fields))
  end

  @doc "Append a timestamped event to the timeline."
  @spec append(t(), atom(), term()) :: t()
  def append(%__MODULE__{} = record, event, detail) when is_atom(event) do
    entry = {DateTime.utc_now(:second), event, detail}
    %{record | timeline: record.timeline ++ [entry]}
  end

  @doc "Close the record with one of the documented outcomes."
  @spec close(t(), outcome()) :: t()
  def close(%__MODULE__{} = record, outcome) when outcome in @outcomes do
    %{record | status: :closed, outcome: outcome}
  end

  @doc "Whether the incident is still open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: status}), do: status == :open

  @doc """
  Persist the record as `record.json` in the incident's bundle directory.

  The root defaults to `config :kubeybilly, :incidents_dir`; pass `:root`
  to override, as tests and the recovery pass do.
  """
  @spec to_disk(t(), keyword()) :: :ok | {:error, File.posix()}
  def to_disk(%__MODULE__{} = record, opts \\ []) do
    path = record_path(record.id, opts)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(serialize(record), pretty: true))
    end
  end

  @doc """
  Read an incident's record back from disk.

  Structured fields captured from structs come back as plain maps; the
  enums (`status`, `outcome`, `verification_outcome`) and timeline event
  names come back as the atoms the machine wrote.
  """
  @spec from_disk(String.t(), keyword()) ::
          {:ok, t()} | {:error, {:record, term()}}
  def from_disk(id, opts \\ []) when is_binary(id) do
    path = record_path(id, opts)

    case File.read(path) do
      {:error, _reason} ->
        {:error, {:record, :not_found}}

      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, decoded} -> deserialize(decoded)
          {:error, _reason} -> {:error, {:record, {:invalid_json, path}}}
        end
    end
  end

  @doc "The on-disk path of an incident's record file."
  @spec record_path(String.t(), keyword()) :: Path.t()
  def record_path(id, opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Application.get_env(:kubeybilly, :incidents_dir, "incidents")
      end)

    Path.join([root, id, @record_file])
  end

  ## Serialization

  defp serialize(record) do
    %{
      "id" => record.id,
      "group_key" => record.group_key,
      "namespace" => record.namespace,
      "workload" => json_safe(record.workload),
      "pods" => record.pods,
      "nodes" => record.nodes,
      "timeline" => Enum.map(record.timeline, &serialize_event/1),
      "signature" => json_safe(record.signature),
      "decision" => json_safe(record.decision),
      "action" => json_safe(record.action),
      "verification_outcome" => json_safe(record.verification_outcome),
      "status" => Atom.to_string(record.status),
      "outcome" => json_safe(record.outcome)
    }
  end

  defp serialize_event({at, event, detail}) do
    [DateTime.to_iso8601(at), Atom.to_string(event), json_safe(detail)]
  end

  # Anything the machine attaches must land on disk without surprises:
  # structs flatten to maps, tuples to lists, atoms to strings.
  defp json_safe(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp json_safe(%_struct{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_safe(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(other), do: other

  ## Deserialization

  defp deserialize(%{"id" => id} = decoded) when is_binary(id) do
    with {:ok, status} <- decode_enum(@statuses, decoded["status"], :invalid_status),
         {:ok, outcome} <- decode_enum(@outcome_names, decoded["outcome"], :invalid_outcome) do
      {:ok,
       %__MODULE__{
         id: id,
         group_key: decoded["group_key"],
         namespace: decoded["namespace"],
         workload: decode_workload(decoded["workload"]),
         pods: List.wrap(decoded["pods"]),
         nodes: List.wrap(decoded["nodes"]),
         timeline: decoded["timeline"] |> List.wrap() |> Enum.map(&decode_event/1),
         signature: decoded["signature"],
         decision: decoded["decision"],
         action: decoded["action"],
         verification_outcome: Map.get(@verification_outcomes, decoded["verification_outcome"]),
         status: status,
         outcome: outcome
       }}
    end
  end

  defp deserialize(decoded), do: {:error, {:record, {:invalid_record, decoded}}}

  defp decode_enum(_names, nil, _tag), do: {:ok, nil}

  defp decode_enum(names, value, tag) do
    case Map.fetch(names, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:record, {tag, value}}}
    end
  end

  defp decode_workload(%{"kind" => kind, "name" => name, "uid" => uid}) do
    %{kind: kind, name: name, uid: uid}
  end

  defp decode_workload(_other), do: nil

  defp decode_event([stamp, event, detail]) do
    {:ok, at, _offset} = DateTime.from_iso8601(stamp)
    {at, decode_event_name(event), detail}
  end

  # Event names written by this application always name existing atoms;
  # a foreign or hand-edited record keeps the string rather than failing.
  defp decode_event_name(event) when is_binary(event) do
    String.to_existing_atom(event)
  rescue
    ArgumentError -> event
  end
end
