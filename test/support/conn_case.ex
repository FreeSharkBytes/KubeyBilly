defmodule KubeybillyWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use KubeybillyWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint KubeybillyWeb.Endpoint

      use KubeybillyWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KubeybillyWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Sign the connection in with the configured dashboard credentials.

  Every dashboard route sits behind basic auth; tests opt in explicitly
  so the unauthenticated 401 stays easy to assert.
  """
  def with_dashboard_auth(conn) do
    credentials = Application.fetch_env!(:kubeybilly, :dashboard_auth)
    encoded = Base.encode64("#{credentials[:username]}:#{credentials[:password]}")
    Plug.Conn.put_req_header(conn, "authorization", "Basic " <> encoded)
  end
end
