defmodule Kubeybilly.K8sClient.Conn do
  @moduledoc """
  Holds the single `K8s.Conn` used by the real client.

  The connection is built once and cached, because conn construction reads
  files (kubeconfig or the mounted service account) and should not happen on
  every API call. Resolution is lazy and a failure is never cached, so a
  cluster that becomes reachable later does not require a restart.

  Source selection: the mounted service account wins when its token file
  exists (the in-cluster path Kapsule exercises), otherwise the `KUBECONFIG`
  environment variable, otherwise `~/.kube/config` (the dev path).
  """

  use GenServer

  @default_service_account_dir "/var/run/secrets/kubernetes.io/serviceaccount"

  @type source :: {:service_account, path :: String.t()} | {:kubeconfig, path :: String.t()}

  ## Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Fetch the cached connection, resolving it on first use."
  @spec get(GenServer.server()) :: {:ok, K8s.Conn.t()} | {:error, {:conn, term()}}
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  end

  @doc "Inject a prebuilt connection, replacing any cached one. Used by tests and tooling."
  @spec put(GenServer.server(), K8s.Conn.t()) :: :ok
  def put(server \\ __MODULE__, %K8s.Conn{} = conn) do
    GenServer.call(server, {:put, conn})
  end

  @doc """
  Decide where the connection should come from, without building it.

  Pure given its options, so the selection logic is testable with no cluster:
  `:service_account_dir` overrides the mounted path and `:env` overrides the
  process environment.
  """
  @spec source(keyword()) :: source()
  def source(opts \\ []) do
    sa_dir = Keyword.get(opts, :service_account_dir, @default_service_account_dir)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    if File.exists?(Path.join(sa_dir, "token")) do
      {:service_account, sa_dir}
    else
      {:kubeconfig, Map.get(env, "KUBECONFIG", Path.join(System.user_home!(), ".kube/config"))}
    end
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok, %{conn: nil, opts: opts}}
  end

  @impl true
  def handle_call(:get, _from, %{conn: %K8s.Conn{} = conn} = state) do
    {:reply, {:ok, conn}, state}
  end

  def handle_call(:get, _from, %{conn: nil, opts: opts} = state) do
    case build(source(opts)) do
      {:ok, conn} -> {:reply, {:ok, conn}, %{state | conn: conn}}
      {:error, reason} -> {:reply, {:error, {:conn, reason}}, state}
    end
  end

  def handle_call({:put, conn}, _from, state) do
    {:reply, :ok, %{state | conn: conn}}
  end

  defp build({:service_account, dir}), do: K8s.Conn.from_service_account(dir)
  defp build({:kubeconfig, path}), do: K8s.Conn.from_file(path)
end
