defmodule Relay.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Relay.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Relay.DataCase
      import Relay.Factory

      alias Relay.Repo
    end
  end

  setup tags do
    Relay.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Relay.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc ~S"""
  Grants `pid` access to the calling test's sandbox connection and returns it, so it composes
  with `start_supervised!/1` (ADR 0009 rule 2):

      pruner = allow!(start_supervised!({Pruner, name: :"pruner_#{System.unique_integer([:positive])}"}))

  Use this whenever the test itself holds the pid of a process that touches the database. When a
  `DynamicSupervisor` severs the chain and the test never sees the pid, use `$callers`
  propagation instead (`Relay.Runs.Instance.adopt_callers/1`).

  Tolerates a process that is already an owner or already allowed, and the shared-mode case, so
  the call is safe in a module that is still `async: false`.
  """
  def allow!(pid) when is_pid(pid) do
    case Sandbox.allow(Relay.Repo, self(), pid) do
      :ok -> pid
      {:already, _owner_or_allowed} -> pid
      # Shared mode (`async: false`): the caller holds no checkout of its own, so there is
      # nothing to grant — every process in the VM already shares the owner's connection.
      :not_found -> pid
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
