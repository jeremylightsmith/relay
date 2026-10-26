defmodule HamacaWeb.ConnCase do
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
  by setting `use HamacaWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use HamacaWeb, :verified_routes

      import Hamaca.DataCase,
        only: [
          allow!: 1,
          start_capacity!: 0,
          start_engine!: 0,
          start_engine!: 1,
          restart_engine!: 0,
          restart_engine!: 1,
          refuse_run_server_starts!: 0,
          unique_slug: 1
        ]

      import Hamaca.Factory
      import HamacaWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn

      # The default endpoint for testing
      @endpoint HamacaWeb.Endpoint

      # Import conveniences for testing with connections
    end
  end

  setup tags do
    Hamaca.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Logs the given user (or a freshly inserted factory user) into the
  test session, so requests hit routes as an authenticated user
  without touching real Google.
  """
  def log_in_user(conn, user \\ nil) do
    user = user || Hamaca.Factory.insert(:user)
    Plug.Test.init_test_session(conn, user_id: user.id)
  end

  @doc """
  Setup helper that inserts a user and logs it in:

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = Hamaca.Factory.insert(:user)
    %{conn: log_in_user(conn, user), user: user}
  end
end
